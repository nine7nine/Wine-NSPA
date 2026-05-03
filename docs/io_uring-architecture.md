# Wine-NSPA -- io_uring I/O Architecture

This page explains where `io_uring` fits in Wine-NSPA, what has already landed
for file and socket I/O, and which surfaces remain outside the `io_uring`
boundary because they are still fundamentally server-managed.

## Table of Contents

1. [Overview](#1-overview)
2. [Integration boundary](#2-integration-boundary)
3. [Design Principles](#3-design-principles)
4. [I/O Architecture: Before and After](#4-io-architecture-before-and-after)
5. [File I/O bypass](#5-file-io-bypass)
6. [Socket recv/send path](#6-socket-recvsend-path)
7. [What stays outside `io_uring`](#7-what-stays-outside-iouring)
8. [File Manifest](#8-file-manifest)
9. [Implementation summary](#9-implementation-summary)

---

## 1. Overview

The `io_uring` story is now broader than the original file-I/O landing.
Three pieces are shipped in production:

- sync poll replacement plus async file read/write on the PE side
- dispatcher-owned async `CreateFile` on the per-process server ring
- PE-side socket `RECVMSG` / `SENDMSG`, default on via
  `NSPA_URING_RECV=1` and `NSPA_URING_SEND=1`

The important boundary correction from 2026-05-02 is that `io_uring` does
**not** subsume named-pipe or named-event completion. Those remain
server-managed surfaces and compose with the local-event fix instead of
replacing it.

### Shipped surface summary

| Surface | Status | Default | Notes |
|-------|--------|---------|-------|
| Sync poll + async file I/O | **Shipped** | On | `NtReadFile` / `NtWriteFile` async bypass + sync poll replacement; pool allocator (TLS, 32 ops); CQE drain at `server_select` / `server_wait` |
| Dispatcher-owned async `CreateFile` | **Shipped** | On | `NSPA_ENABLE_ASYNC_CREATE_FILE=1`; routes `CreateFile` through the per-process ring and removes the `open()` lock-drop CS from the audio xrun path |
| Socket recv | **Shipped** | On | `NSPA_URING_RECV=1`; `recv_socket` submits `IORING_OP_RECVMSG` on the deferred path |
| Socket send | **Shipped** | On | `NSPA_URING_SEND=1`; `send_socket` submits `IORING_OP_SENDMSG` on the deferred path |
| `NtFlushBuffersFile` FSYNC | **Dropped** | -- | disk path is already synchronous `fsync()`; no meaningful `io_uring` win |
| anonymous pipes / inotify | **Dropped** | -- | both blocked by existing server-managed infrastructure shape |

### Boundary changes since the first public draft

- The original sync poll replacement and async file I/O work now read
  as one shipped file-I/O slice.
- Socket work is no longer theoretical follow-on work. The data path is
  shipped on the PE side via `RECVMSG` / `SENDMSG`.
- Pipes and named events did **not** become `io_uring` work. Their remaining
  completion story is handled by other server-managed mechanisms.

---

## 2. Integration boundary

This document is the `io_uring` design and implementation reference for
Wine-NSPA. It covers the integration boundary, per-thread ring model,
the shipped file / socket paths, and the surfaces that remain outside the
`io_uring` boundary. For project-wide context, see the architecture overview.

This design addresses two bottlenecks:

1. **Syscall overhead.** 4+ kernel transitions per async file read
   (register + epoll + alert + read). io_uring collapses this to 1
   (`io_uring_enter`).
2. **Global lock contention.** Every fd in server epoll extends
   `global_lock` hold time. Fewer server-monitored fds = shorter hold =
   less contention for shmem dispatchers.

### Relationship to Existing NSPA Infrastructure

| NSPA Component | io_uring Interaction |
|----------------|---------------------|
| Shmem IPC (gamma channel + msg-ring v2) | **Orthogonal.** Shmem handles request/reply IPC. io_uring handles file/socket I/O. Different fd sets, no conflict. |
| PI global_lock | **Indirect benefit.** Fewer fds in server epoll = shorter main loop iterations = shorter global_lock hold. |
| ntsync (/dev/ntsync) | **Integrated.** ntsync `uring_fd` extension wakes threads blocked in ntsync waits when io_uring CQEs arrive. The `pad` field in `ntsync_wait_args` carries the io_uring eventfd; kernel returns `NTSYNC_INDEX_URING_READY` on CQE. Required for sync socket-style waits to drain CQEs inline. |
| CS-PI (FUTEX_LOCK_PI) | **No conflict.** io_uring operations happen client-side in ntdll, never acquiring server locks. |
| RT scheduling (SCHED_FIFO/RR) | **Compatible.** `COOP_TASKRUN` ensures completions run in the submitting thread's context, preserving RT priority. |

### Prior art: `archive/iouring`

Rémi Bernon's 2021-2022 `archive/iouring` branch attempted direct
replacement of wineserver's epoll loop. That design touched core server
files (`server/fd.c`, `request.c`, `thread.c`) and depended on an
earlier io_uring feature set.

Wine-NSPA uses a different integration boundary. The shmem and gamma
paths already remove request/reply IPC from the hot path, so io_uring is
applied client-side to file and socket I/O. The bulk of the
implementation remains isolated in `dlls/ntdll/unix/io_uring.c`, with
thin call-site conditionals in existing files.

---

## 3. Design Principles

- **Per-thread rings.** Each ntdll thread lazily initializes its own
  io_uring ring with `IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_COOP_TASKRUN`.
  No cross-thread submission, no locking.
- **RT-safe completions.** `COOP_TASKRUN` ensures CQE processing happens
  in the submitting thread's context -- preserving SCHED_FIFO priority.
  No kernel worker threads at default priority.
- **Transparent fallback.** Every io_uring function returns `-ENOSYS`
  if the ring is unavailable. Callers fall back to the existing code
  path. Wine apps see identical behavior whether io_uring is present
  or not.
- **fd lifetime safety.** Async operations `dup()` the unix fd before
  submitting to the ring. The duplicate is owned by the in-flight SQE
  and closed on CQE completion. Prevents use-after-close if the
  server-side handle table changes during the operation.
- **Cooperative completion drain.** CQEs are processed at
  `server_select()` and `server_wait()` entry points -- the natural
  places where a thread is about to block. Completions are delivered
  promptly without adding threads or signals.
- **Minimal rebase surface.** The bulk of the code lives in a new file
  (`io_uring.c`, ~794 lines). Existing files get thin conditionals.
- **RT-safe allocation.** Pre-allocated TLS pool of 32 `uring_async_op`
  structs. Freelist-based O(1) alloc/free -- no malloc/free in the
  submit path. Initialized once at ring setup.

### Per-Thread Ring Architecture

<div class="diagram-container">
<svg width="100%" viewBox="0 0 780 320" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ur-box { fill: #24283b; stroke: #9aa5ce; stroke-width: 1.5; rx: 6; }
    .ur-box-new { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 6; }
    .ur-box-pool { fill: #1a1a2a; stroke: #7aa2f7; stroke-width: 1.5; rx: 6; }
    .ur-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .ur-label-sm { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .ur-label-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ur-label-yellow { fill: #e0af68; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .ur-label-cyan { fill: #7dcfff; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .ur-arrow { stroke: #9aa5ce; stroke-width: 1.5; fill: none; }
    .ur-arrow-green { stroke: #9ece6a; stroke-width: 2; fill: none; }
  </style>

  <text x="390" y="20" class="ur-label-yellow" text-anchor="middle">Per-Thread io_uring Ring + Pool Allocator (TLS)</text>

  <rect x="15" y="35" width="750" height="130" rx="6" fill="none" stroke="#3b4261" stroke-width="1" stroke-dasharray="5,3"/>
  <text x="35" y="55" class="ur-label-yellow">Thread N (TLS)</text>

  <rect x="30" y="65" width="180" height="85" rx="6" class="ur-box-new"/>
  <text x="120" y="85" class="ur-label-green" text-anchor="middle">thread_ring</text>
  <text x="120" y="100" class="ur-label-sm" text-anchor="middle">SINGLE_ISSUER</text>
  <text x="120" y="113" class="ur-label-sm" text-anchor="middle">COOP_TASKRUN</text>
  <text x="120" y="126" class="ur-label-sm" text-anchor="middle">SQ: 32 entries</text>
  <text x="120" y="139" class="ur-label-sm" text-anchor="middle">CQ: 64 entries</text>

  <rect x="240" y="65" width="230" height="85" rx="6" class="ur-box-pool"/>
  <text x="355" y="85" class="ur-label-cyan" text-anchor="middle">op_pool[32] (TLS static)</text>
  <text x="355" y="100" class="ur-label-sm" text-anchor="middle">uring_async_op structs</text>
  <text x="355" y="115" class="ur-label-sm" text-anchor="middle">op_free_head -> [0]->[1]->...->[31]->NULL</text>
  <text x="355" y="130" class="ur-label-green" text-anchor="middle">O(1) alloc: pop head</text>
  <text x="355" y="143" class="ur-label-green" text-anchor="middle">O(1) free: push head</text>

  <rect x="500" y="65" width="250" height="85" rx="6" class="ur-box"/>
  <text x="625" y="82" class="ur-label" text-anchor="middle">ring_initialized (bool)</text>
  <text x="625" y="95" class="ur-label-sm" text-anchor="middle">ring_init_failed (bool)</text>
  <text x="625" y="108" class="ur-label-green" text-anchor="middle">ring_efd (eventfd for dispatcher-owned completion)</text>
  <text x="625" y="123" class="ur-label-sm" text-anchor="middle">ensure_ring(): lazy init</text>
  <text x="625" y="136" class="ur-label-sm" text-anchor="middle">+ op_pool_init() + eventfd()</text>
  <text x="625" y="146" class="ur-label-sm" text-anchor="middle">+ IORING_REGISTER_EVENTFD</text>

  <rect x="30" y="190" width="130" height="40" rx="6" class="ur-box"/>
  <text x="95" y="207" class="ur-label-sm" text-anchor="middle">NtReadFile</text>
  <text x="95" y="221" class="ur-label-sm" text-anchor="middle">(async path)</text>

  <line x1="160" y1="210" x2="190" y2="210" class="ur-arrow"/>

  <rect x="195" y="190" width="120" height="40" rx="6" class="ur-box-pool"/>
  <text x="255" y="207" class="ur-label-cyan" text-anchor="middle">op_pool_alloc()</text>
  <text x="255" y="221" class="ur-label-sm" text-anchor="middle">zero malloc</text>

  <line x1="315" y1="210" x2="345" y2="210" class="ur-arrow"/>

  <rect x="350" y="190" width="110" height="40" rx="6" class="ur-box-new"/>
  <text x="405" y="207" class="ur-label-green" text-anchor="middle">dup(fd)</text>
  <text x="405" y="221" class="ur-label-sm" text-anchor="middle">lifetime safety</text>

  <line x1="460" y1="210" x2="490" y2="210" class="ur-arrow-green"/>

  <rect x="495" y="190" width="130" height="40" rx="6" class="ur-box-new"/>
  <text x="560" y="207" class="ur-label-green" text-anchor="middle">io_uring_submit()</text>
  <text x="560" y="221" class="ur-label-sm" text-anchor="middle">1 syscall</text>

  <line x1="625" y1="210" x2="655" y2="210" class="ur-arrow"/>

  <rect x="660" y="190" width="100" height="40" rx="6" class="ur-box"/>
  <text x="710" y="207" class="ur-label" text-anchor="middle">kernel</text>
  <text x="710" y="221" class="ur-label-sm" text-anchor="middle">async I/O</text>

  <rect x="30" y="260" width="180" height="40" rx="6" class="ur-box"/>
  <text x="120" y="277" class="ur-label-sm" text-anchor="middle">server_wait() / server_select()</text>
  <text x="120" y="291" class="ur-label-sm" text-anchor="middle">entry point</text>

  <line x1="210" y1="280" x2="245" y2="280" class="ur-arrow-green"/>

  <rect x="250" y="260" width="200" height="40" rx="6" class="ur-box-new"/>
  <text x="350" y="277" class="ur-label-green" text-anchor="middle">process_completions()</text>
  <text x="350" y="291" class="ur-label-sm" text-anchor="middle">drain CQ, complete_uring_op()</text>

  <line x1="450" y1="280" x2="485" y2="280" class="ur-arrow"/>

  <rect x="490" y="260" width="135" height="40" rx="6" class="ur-box"/>
  <text x="557" y="277" class="ur-label-sm" text-anchor="middle">complete</text>
  <text x="557" y="291" class="ur-label-sm" text-anchor="middle">IOSB + event/IOCP</text>

  <line x1="625" y1="280" x2="655" y2="280" class="ur-arrow"/>

  <rect x="660" y="260" width="100" height="40" rx="6" class="ur-box-pool"/>
  <text x="710" y="277" class="ur-label-cyan" text-anchor="middle">op_pool_free()</text>
  <text x="710" y="291" class="ur-label-sm" text-anchor="middle">+ close(dup_fd)</text>
</svg>
</div>

---

## 4. I/O Architecture: Before and After

### Vanilla Wine: Server-Mediated Async File I/O

    Client Thread                    Wineserver
    -------------                    ----------
    NtReadFile(async)
      server_get_unix_fd()    ---->   get_handle_fd
      register_async()        ---->   register_async
                                        queue_async(&fd->read_q)
                                        set_fd_events(POLLIN)
      return STATUS_PENDING
      ...                            main_loop_epoll():
      (thread does other work)         global_lock.lock()
                                       epoll_pwait2() -> fd ready
                                       fd_poll_event -> async_wake_up
                                       global_lock.unlock()
      (thread enters alertable wait)
      async_read_proc():
        server_get_unix_fd()  ---->   get_handle_fd (again)
        read(fd, buf, len)
        set IOSB, signal event

**Syscalls per async read:** 2 server round-trips (register + get_fd) +
epoll_wait + read = **4+ kernel transitions**

### Wine-NSPA with io_uring: Client-Side Async File I/O

    Client Thread                    Wineserver
    -------------                    ----------
    NtReadFile(async)
      server_get_unix_fd()    ---->   get_handle_fd (cached, usually no trip)
      dup(unix_fd) -> ring_fd
      io_uring_prep_read(ring_fd, buf, len)
      io_uring_submit()                (server never sees this I/O)
      return STATUS_PENDING
      ...
      (thread enters server_wait)
      ntdll_io_uring_process_completions():
        CQE ready -> bytes_read
        file_complete_async()
        close(ring_fd)

**Syscalls per async read:** 1 `io_uring_enter` (submit+wait batched) =
**1 kernel transition**

The server is bypassed for the I/O monitoring and data transfer. It
still handles the initial fd lookup (usually cached) and completion
port notifications if needed.

### Synchronous I/O: poll() Replacement

    Before:                          After:
      poll(fd, POLLIN, timeout)        ntdll_io_uring_poll(fd, POLLIN, timeout)
      read(fd, buf, len)               read(fd, buf, len)  <- unchanged

The `read()`/`write()` still goes through `virtual_locked_read()` for
write-watch safety. Only the poll wait is replaced.

---

## 5. File I/O bypass

**Shipped, default-on.** Single combined implementation covering sync poll
replacement and async `NtReadFile` / `NtWriteFile` bypass.

### What Changed

In `NtReadFile` and `NtWriteFile`:

- The synchronous blocking path replaces `poll(fd, events, timeout)`
  with `ntdll_io_uring_poll()`.
- The async path tries io_uring before falling back to the server
  `register_async` round-trip:

      if (!ntdll_io_uring_submit_file_read(unix_fd, ...)) {
          return STATUS_PENDING;  /* CQE will complete later */
      }
      /* fallback: register_async with server */

### fd Lifetime Safety

`dup()` the unix fd before submission. The duplicate is owned by the
`uring_async_op` struct and closed on CQE completion or cancellation.

### Completion Delivery

CQEs are drained cooperatively in `server_select()` and `server_wait()`
entry points:

    unsigned int server_select(...) {
        ntdll_io_uring_process_completions();
        ...
    }
    unsigned int server_wait(...) {
        ntdll_io_uring_process_completions();
        ...
    }

When a CQE arrives, `complete_uring_op()` translates the result to
NTSTATUS and calls `file_complete_async()` -- the same function used
by Wine's normal async completion path. This handles:

- IO_STATUS_BLOCK update
- Event signaling (`NtSetEvent`)
- APC queuing (`NtQueueApcThread`)
- Completion port notification (via `add_completion()`)

### EFAULT Handling

If io_uring's kernel read hits EFAULT (buffer in a write-watched page),
the CQE result is `-EFAULT`. The completion handler frees the operation;
the caller retries through the server async path, which uses
`virtual_locked_read()` with proper page fault handling. Graceful
fallback for an edge case that rarely occurs in practice.

### Integration Points

| File | Change | LOC |
|------|--------|-----|
| `dlls/ntdll/unix/file.c` | `NtReadFile` sync wait + async bypass | ~25 |
| `dlls/ntdll/unix/file.c` | `NtWriteFile` sync wait + async bypass | ~25 |
| `dlls/ntdll/unix/server.c` | Completion drain in `server_select`/`server_wait` | +2 |
| `dlls/ntdll/unix/thread.c` | Ring cleanup in `pthread_exit_wrapper()` | +1 |

---

## 6. Socket recv/send path

**Shipped, default-on.**

The socket path now uses true socket SQEs on the deferred async path:

- `NSPA_URING_RECV=1` routes recv completion through `IORING_OP_RECVMSG`
- `NSPA_URING_SEND=1` routes send completion through `IORING_OP_SENDMSG`

The integration boundary is still the same as the earlier ALERTED-state work:
the server remains authoritative for the async lifecycle and socket state
machine, while the client owns readiness monitoring and the data move itself.

### Shipped shape

1. server returns an ALERTED async
2. client intercepts before restarting the async on the server
3. E2 bitmap excludes the fd from server poll ownership
4. client submits the socket SQE
5. CQE completion feeds the same Wine completion helpers and reports the final
   result back once

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .sr-bg { fill: #1a1b26; }
    .sr-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.5; rx: 8; }
    .sr-srv { fill: #2a1f35; stroke: #bb9af7; stroke-width: 2; rx: 8; }
    .sr-cli { fill: #1a2235; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .sr-kern { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 8; }
    .sr-note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .sr-t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .sr-s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .sr-h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .sr-v { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
    .sr-g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .sr-y { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .sr-line { stroke: #c0caf5; stroke-width: 1.5; fill: none; }
  </style>
  <defs>
    <marker id="srArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="940" height="420" class="sr-bg"/>
  <text x="470" y="28" text-anchor="middle" class="sr-h">Shipped socket path on the deferred async case</text>

  <rect x="50" y="92" width="220" height="84" class="sr-srv"/>
  <text x="160" y="120" text-anchor="middle" class="sr-v">server async lifecycle</text>
  <text x="160" y="142" text-anchor="middle" class="sr-s">returns ALERTED async + wait handle</text>
  <text x="160" y="160" text-anchor="middle" class="sr-s">retains protocol-state authority</text>

  <rect x="360" y="92" width="220" height="84" class="sr-cli"/>
  <text x="470" y="120" text-anchor="middle" class="sr-t">client interception</text>
  <text x="470" y="142" text-anchor="middle" class="sr-s">set E2 bitmap, keep async ALERTED</text>
  <text x="470" y="160" text-anchor="middle" class="sr-s">submit RECVMSG / SENDMSG SQE</text>

  <rect x="670" y="92" width="220" height="84" class="sr-kern"/>
  <text x="780" y="120" text-anchor="middle" class="sr-g">kernel `io_uring`</text>
  <text x="780" y="142" text-anchor="middle" class="sr-s">socket readiness and data move</text>
  <text x="780" y="160" text-anchor="middle" class="sr-s">CQE fires on completion</text>

  <path d="M270 134 L360 134" class="sr-line" marker-end="url(#srArrow)"/>
  <path d="M580 134 L670 134" class="sr-line" marker-end="url(#srArrow)"/>

  <rect x="210" y="236" width="520" height="62" class="sr-note"/>
  <text x="470" y="262" text-anchor="middle" class="sr-y">Single completion path</text>
  <text x="470" y="280" text-anchor="middle" class="sr-s">the CQE handler feeds Wine's normal async completion helpers and reports the final result once</text>
</svg>
</div>

### Validation

The 2026-05-02 default-on flip was backed by:

- `socket-io` deferred path: `+6.5%` throughput
- `socket-io` deferred path: `-6.8%` p99 latency
- `socket-io`: `0/2000` failures
- Ableton boot, library scan, and playback: clean with `63` threads and zero
  new errors versus the Phase 4.6 baseline

### Why this stays server-correct

The client is not bypassing the socket state machine. It is bypassing the
monitoring and data-transfer part of the async path once the server has already
established the async object and its completion contract.

That is why the current shape is viable:

- completion still flows through `set_async_direct_result`
- event and IOCP signaling still happen through the normal Wine completion path
- the server still owns the socket object and its protocol-visible state

---

## 7. What stays outside `io_uring`

Not every async surface is an `io_uring` candidate.

| Surface | Current reason it stays outside |
|---|---|
| named pipes | server-owned pseudo-fd architecture; no real PE-side kernel fd to submit against |
| named events | server-side naming / object-directory semantics, not an fd-monitoring problem |
| anonymous-pipe follow-on | current Win32 `CreatePipe` route still sits on the named-pipe pseudo-fd infrastructure |
| directory notify via inotify | current inotify state is one server-process-wide facility, not a per-PE resource |

The 2026-05-02 correction is that these are not "Phase 4.8 pending" in the
same sense that sockets used to be pending. Named-pipe and named-event
completion now compose with the **local-event** server-registration path, not
with `io_uring`.

---

## 8. File Manifest

### New Files

| File | Lines | Purpose |
|------|-------|---------|
| `dlls/ntdll/unix/io_uring.c` | ~794 | Per-thread ring management, all phase functions, pool allocator |

### Modified Files

| File | Changed Lines | Purpose |
|------|--------------|---------|
| `dlls/ntdll/unix/unix_private.h` | +30 | io_uring function declarations, bitmap helpers |
| `dlls/ntdll/unix/file.c` | ~30 | sync poll + async read/write bypass |
| `dlls/ntdll/unix/socket.c` | ~120 | shipped socket path: ALERTED interception, RECVMSG / SENDMSG CQE handlers, bitmap set/clear |
| `dlls/ntdll/unix/sync.c` | ~40 | ntsync uring_fd retry loop, deferred completion flush |
| `dlls/ntdll/unix/server.c` | +2 | Completion drain at server_select/server_wait |
| `dlls/ntdll/unix/thread.c` | +1 | Ring cleanup at thread exit |
| `server/sock.c` | ~40 | E2 bitmap check in `sock_get_poll_events` |
| `dlls/ntdll/Makefile.in` | +2 | `io_uring.c` source + `URING_LIBS` |
| `configure.ac` | +8 | liburing detection |

### Build Dependency

`liburing.so.2` (system package). Available as `liburing` in Arch Linux
`[extra]`. Detected at configure time via
`AC_CHECK_LIB(uring, io_uring_queue_init)`.

---

## 9. Implementation summary

| Component | Status | Notes |
|-----------|--------|-------|
| io_uring ring management | Shipped | Per-thread, lazy init |
| Pool allocator (TLS, 32 ops) | Shipped | RT-safe, zero malloc in submit path |
| sync poll + async file I/O | Shipped, default-on | `NtReadFile` / `NtWriteFile` |
| async `CreateFile` via dispatcher ring | Shipped, default-on | `NSPA_ENABLE_ASYNC_CREATE_FILE=1`; server-side consumer on the per-process ring |
| socket I/O (deferred path) | Shipped, default-on | `NSPA_URING_RECV=1`, `NSPA_URING_SEND=1`; validated on `socket-io` and Ableton |
| dropped follow-ons | Dropped | not worthwhile or blocked by server-managed architecture |
| E2 bitmap (server `sock.c`) | Shipped | engaged when the client-owned socket poll path is active |
| ntsync `uring_fd` extension | Shipped (kernel patch) | Wakes ntsync waits on CQE |
| ntsync PI v2 + audit fixes | Shipped (kernel patch) | Module srcversion `10124FB81FDC76797EF1F91` |
| Audit §4.1 retry-loop hardening | Shipped (wine) | Superproject `a7e34c7` |

### Next Actions

1. Publish a fresh full-suite run against the 2026-05-02 stack so the socket
   default-on flip sits beside a new matrix result, not just targeted validation.
2. Profile server epoll hold-time reduction under heavier socket load than the
   current `socket-io` harness.
3. Keep named-pipe and named-event follow-on work on the server-managed track,
   not on the `io_uring` roadmap.
