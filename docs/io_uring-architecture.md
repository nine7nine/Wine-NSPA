# Wine-NSPA -- io_uring I/O Architecture

**Date:** 2026-04-28
**Author:** Jordan Johnston
**Kernel:** `6.19.11-rt1-1-nspa` (PREEMPT_RT_FULL)
**Wine:** 11.6 + NSPA RT patchset

## Table of Contents

1. [Status as of 2026-04-28](#1-status-as-of-2026-04-28)
2. [Overview](#2-overview)
3. [Design Principles](#3-design-principles)
4. [I/O Architecture: Before and After](#4-io-architecture-before-and-after)
5. [Phase 1: File I/O Bypass (shipped)](#5-phase-1-file-io-bypass-shipped)
6. [Phase 2: Socket I/O Bypass (pending)](#6-phase-2-socket-io-bypass-pending)
7. [Phase 3: Pipes and Named Events (pending)](#7-phase-3-pipes-and-named-events-pending)
8. [File Manifest](#8-file-manifest)
9. [Status Summary](#9-status-summary)

---

## 1. Status as of 2026-04-28

The original three-phase plan from 2026-04-15 has been re-scoped. Phase 1
(synchronous poll replacement + async file I/O bypass) shipped default-on
and has been stable through the 2026-04 audit cycle. Phases 2 and 3 are
multi-session work, gated against the post-audit ntsync module
(`srcversion A250A77651C8D5DAB719FE2`) and the audit §4.1 retry-loop
hardening that closes silent-contract bugs in the shmem ring path.

The architecture itself -- per-thread rings, the E2 bitmap, ALERTED-state
interception, and the ntsync `uring_fd` extension -- is settled. What
remains is socket and pipe surface area, plus retesting against the
current kernel + ring code.

### Phase Status Table

| Phase | Surface | Status | Default | Notes |
|-------|---------|--------|---------|-------|
| Phase 1 | Sync poll + async file I/O | **Shipped** | On | `NtReadFile` / `NtWriteFile` async bypass + sync poll replacement; pool allocator (TLS, 32 ops); CQE drain at `server_select` / `server_wait` |
| Phase 2 | Sockets (sync + overlapped) | **Pending** | -- | E2 bitmap + ALERTED interception design validated; socket-io PE test passed historically; needs revalidation against post-audit ntsync + audit §4.1 retry-loop hardening |
| Phase 3 | Pipes + named events | **Pending** | -- | Not yet designed; expected to reuse Phase 2 ALERTED-interception pattern with object-class-specific completion paths |

### What changed vs the 2026-04-15 doc

- Phases 1 and 2 of the 2026-04-15 plan (sync poll replacement, async
  file I/O bypass) have collapsed into a single shipped Phase 1.
- The 2026-04-15 Phase 3 (sockets) is now Phase 2, deferred to a focused
  re-validation session.
- A new Phase 3 has been carved out for pipe and named-event surfaces,
  which were previously not on the roadmap.

---

## 2. Overview

This document is the deep-dive companion to the Wine-NSPA architecture
overview. It covers the design decisions, tradeoffs, and implementation
details of io_uring integration. For background on Wine's I/O model and
why io_uring matters for RT audio, see the architecture page.

The two bottlenecks targeted by this work:

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

### Reference: rbernon's Archived Attempt

Rémi Bernon attempted a full wineserver main-loop replacement with
io_uring circa 2021-2022 (`gitlab.winehq.org/rbernon/wine`, branch
`archive/iouring`). It was abandoned because io_uring was immature at
the time -- missing features, kernel bugs, API instability. That
approach replaced the server's epoll entirely (~500 LOC across
`server/fd.c`, `request.c`, `thread.c`).

Wine-NSPA's approach is fundamentally different: with the shmem fast
path already handling request/reply IPC, the server main loop is **no
longer the bottleneck**. Instead, we target the remaining
server-dependent paths -- file and socket I/O -- from the **client
side**, keeping changes isolated in a new `io_uring.c` file with minimal
modifications to existing code.

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
  <text x="625" y="108" class="ur-label-green" text-anchor="middle">ring_efd (eventfd, Phase 2/3)</text>
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

## 5. Phase 1: File I/O Bypass (shipped)

**Status: Shipped, default-on. Single combined phase covering sync poll
replacement and async `NtReadFile`/`NtWriteFile` bypass.**

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

## 6. Phase 2: Socket I/O Bypass (pending)

**Status: Pending revalidation. Architecture (E2 bitmap + ALERTED-state
interception) is settled; the existing socket-io PE test path passed
under the prior ntsync module, but socket bypass needs a focused
re-test against the post-audit module
(`srcversion A250A77651C8D5DAB719FE2`) and the audit §4.1 retry-loop
hardening.**

### The Challenge

Socket I/O (`sock_recv` / `sock_send`) is tightly coupled with the
server's async lifecycle:

- Server creates `wait_handle` for the async operation
- Server tracks socket state (connect, listen, accept, shutdown)
- Server manages AFD poll state (`pending_events`, `reported_events`)
- Client uses `set_async_direct_result()` to report completion
- `sock_get_poll_events()` in server decides what to monitor

Unlike file I/O (where the server's only role is fd monitoring), the
socket code has the server actively participating in the protocol
state machine.

### Approach: E2 Bitmap + ALERTED-State Interception

| Option | Description | Verdict |
|--------|-------------|---------|
| **B1: Server flag** | Add `client_poll` flag to recv/send. Server skips epoll. | Evaluated, not used |
| **B2: Both poll** | Server + client both monitor. First wins. | Rejected (no global_lock benefit) |
| **E2: Shared bitmap** | Process-level bitmap. Client sets bit per fd. Server checks in `sock_get_poll_events()`. | **Selected** |
| **C: Full bypass** | Skip server entirely for connected TCP. | Rejected (breaks socket state machine) |

### How It Works

The key is **ALERTED-state interception** -- intercepting in the
ALERTED block *before* `set_async_direct_result` is called:

    Server: recv_socket -> STATUS_ALERTED + wait_handle
    Client: try_recv(fd) -> EAGAIN (not ready)
                                                  <- interception point
      BEFORE: set_async_direct_result(PENDING)    <- would restart on server
      NOW:    set bitmap + io_uring POLL_ADD      <- async stays ALERTED
              return STATUS_PENDING
      ... io_uring monitors fd ...
    CQE fires:
      try_recv(fd) -> SUCCESS (data available)
      set_async_direct_result(SUCCESS, bytes)     <- server accepts
      Server: completes async, signals event/IOCP

<div class="diagram-container">
<svg width="100%" viewBox="0 0 880 720" xmlns="http://www.w3.org/2000/svg">
  <style>
    .p3-box-server { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 6; }
    .p3-box-old { fill: #2a1a1a; stroke: #f7768e; stroke-width: 2; rx: 6; }
    .p3-box-new { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 6; }
    .p3-box-uring { fill: #1a1a2a; stroke: #7dcfff; stroke-width: 2; rx: 6; }
    .p3-box-intercept { fill: #2a2418; stroke: #e0af68; stroke-width: 2.5; rx: 6; }
    .p3-box-neutral { fill: #24283b; stroke: #9aa5ce; stroke-width: 1.5; rx: 6; }
    .p3-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .p3-label-sm { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .p3-label-blue { fill: #7aa2f7; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .p3-label-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .p3-label-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .p3-label-cyan { fill: #7dcfff; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .p3-label-yellow { fill: #e0af68; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .p3-label-muted { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .p3-arrow { stroke: #9aa5ce; stroke-width: 1.5; fill: none; }
    .p3-arrow-blue { stroke: #7aa2f7; stroke-width: 2; fill: none; }
    .p3-arrow-green { stroke: #9ece6a; stroke-width: 2; fill: none; }
    .p3-arrow-red { stroke: #f7768e; stroke-width: 1.5; fill: none; }
    .p3-arrow-cyan { stroke: #7dcfff; stroke-width: 2; fill: none; }
    .p3-arrow-yellow { stroke: #e0af68; stroke-width: 2; fill: none; }
  </style>

  <text x="440" y="22" class="p3-label-yellow" text-anchor="middle" font-size="13">ALERTED-State Interception Flow (Phase 2)</text>

  <rect x="240" y="38" width="400" height="38" rx="6" class="p3-box-server"/>
  <text x="440" y="55" class="p3-label-blue" text-anchor="middle">Server: recv_socket()</text>
  <text x="440" y="69" class="p3-label-sm" text-anchor="middle">returns STATUS_ALERTED + wait_handle</text>

  <line x1="440" y1="76" x2="440" y2="96" class="p3-arrow-blue"/>

  <rect x="240" y="98" width="400" height="38" rx="6" class="p3-box-neutral"/>
  <text x="440" y="115" class="p3-label" text-anchor="middle">Client: try_recv(fd)</text>
  <text x="440" y="129" class="p3-label-muted" text-anchor="middle">returns EAGAIN (data not ready yet)</text>

  <line x1="440" y1="136" x2="440" y2="160" class="p3-arrow-yellow"/>

  <rect x="140" y="162" width="600" height="32" rx="6" class="p3-box-intercept"/>
  <text x="440" y="183" class="p3-label-yellow" text-anchor="middle">INTERCEPTION POINT  --  before set_async_direct_result()</text>

  <text x="230" y="208" class="p3-label-red" text-anchor="middle">OLD PATH</text>
  <text x="560" y="208" class="p3-label-green" text-anchor="middle">NEW PATH (NSPA)</text>

  <line x1="230" y1="194" x2="300" y2="240" class="p3-arrow-red"/>
  <line x1="560" y1="194" x2="580" y2="240" class="p3-arrow-green"/>

  <rect x="100" y="242" width="400" height="50" rx="6" class="p3-box-old"/>
  <text x="300" y="260" class="p3-label-red" text-anchor="middle">set_async_direct_result(PENDING)</text>
  <text x="300" y="274" class="p3-label-sm" text-anchor="middle">server restarts async</text>
  <text x="300" y="287" class="p3-label-muted" text-anchor="middle">async re-queued, server monitors via epoll</text>

  <line x1="300" y1="292" x2="230" y2="316" class="p3-arrow-red"/>

  <rect x="60" y="318" width="340" height="38" rx="6" class="p3-box-old"/>
  <text x="230" y="335" class="p3-label-red" text-anchor="middle">Server: epoll monitors fd</text>
  <text x="230" y="349" class="p3-label-muted" text-anchor="middle">global_lock held during dispatch</text>

  <line x1="230" y1="356" x2="230" y2="380" class="p3-arrow-red"/>

  <rect x="60" y="382" width="340" height="38" rx="6" class="p3-box-old"/>
  <text x="230" y="399" class="p3-label-red" text-anchor="middle">Server: async_wake_up(ALERTED)</text>
  <text x="230" y="413" class="p3-label-muted" text-anchor="middle">client callback, re-fetches fd, completes</text>

  <rect x="60" y="432" width="300" height="32" rx="6" fill="#2a1a1a" stroke="#f7768e" stroke-width="1"/>
  <text x="230" y="452" class="p3-label-red" text-anchor="middle">2 server round-trips + epoll cycle</text>

  <rect x="480" y="222" width="380" height="62" rx="6" class="p3-box-new"/>
  <text x="670" y="244" class="p3-label-green" text-anchor="middle">set E2 bitmap bit for fd</text>
  <text x="670" y="260" class="p3-label-green" text-anchor="middle">io_uring POLL_ADD(fd, POLLIN)</text>
  <text x="670" y="274" class="p3-label-sm" text-anchor="middle">async stays ALERTED (frozen on server)</text>
  <text x="670" y="282" class="p3-label-muted" text-anchor="middle">return STATUS_PENDING</text>

  <line x1="640" y1="284" x2="640" y2="334" class="p3-arrow-cyan"/>

  <rect x="480" y="336" width="340" height="48" rx="6" class="p3-box-uring"/>
  <text x="640" y="355" class="p3-label-cyan" text-anchor="middle">io_uring monitors fd in kernel</text>
  <text x="640" y="369" class="p3-label-sm" text-anchor="middle">no server involvement</text>
  <text x="640" y="380" class="p3-label-muted" text-anchor="middle">no global_lock contention</text>

  <line x1="640" y1="384" x2="640" y2="414" class="p3-arrow-cyan"/>

  <rect x="480" y="416" width="340" height="38" rx="6" class="p3-box-uring"/>
  <text x="640" y="433" class="p3-label-cyan" text-anchor="middle">CQE fires: fd ready</text>
  <text x="640" y="447" class="p3-label-muted" text-anchor="middle">eventfd wakes ntsync wait (sync) or drain (async)</text>

  <line x1="640" y1="454" x2="640" y2="480" class="p3-arrow-green"/>

  <rect x="480" y="482" width="340" height="38" rx="6" class="p3-box-new"/>
  <text x="640" y="499" class="p3-label-green" text-anchor="middle">try_recv(fd) -- SUCCESS</text>
  <text x="640" y="513" class="p3-label-sm" text-anchor="middle">data available, read completes</text>

  <line x1="640" y1="520" x2="640" y2="546" class="p3-arrow-green"/>

  <rect x="460" y="548" width="380" height="48" rx="6" class="p3-box-new"/>
  <text x="640" y="566" class="p3-label-green" text-anchor="middle">set_async_direct_result(SUCCESS, bytes)</text>
  <text x="640" y="582" class="p3-label-sm" text-anchor="middle">single server call with final result</text>
  <text x="640" y="592" class="p3-label-muted" text-anchor="middle">ALERTED state preserved -- server accepts</text>

  <line x1="640" y1="596" x2="640" y2="622" class="p3-arrow-blue"/>

  <rect x="480" y="624" width="340" height="38" rx="6" class="p3-box-server"/>
  <text x="640" y="641" class="p3-label-blue" text-anchor="middle">Server: completes async</text>
  <text x="640" y="655" class="p3-label-sm" text-anchor="middle">signals event / IOCP</text>

  <rect x="490" y="672" width="300" height="24" rx="6" fill="#1a2a1a" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="640" y="689" class="p3-label-green" text-anchor="middle">1 server call (completion only)</text>
</svg>
</div>

**Why this works:** When an async is ALERTED on the server,
`terminated=1` and `async_waiting()` returns false. The server does
*not* monitor the fd via epoll. The bitmap provides additional safety
(`sock_get_poll_events` returns -1). Only one call to
`set_async_direct_result` ever happens -- from the CQE handler with the
final result.

**Why previous approaches failed (4 attempts):**

1. **CQ drain inline NtSetEvent:** Signal reentrancy crash --
   `NtSetEvent` requires Wine signal manipulation, unsafe from CQ
   drain context.
2. **Deferred completion flush:** Deadlock -- event must be signaled
   *during* the wait to wake `inproc_wait`, not after.
3. **Direct ntsync ioctl:** Double completion --
   `set_async_direct_result(PENDING)` restarted the async, server
   monitored via epoll AND io_uring monitored -> race.
4. **Bitmap after `set_async_direct_result`:** Same race -- bitmap set
   too late, async already restarted.

### Sync vs Overlapped Path

| | Sync | Overlapped |
|---|------|-----------|
| ALERTED block | Intercept, submit POLL_ADD | Same |
| Return | `wait_async(wait_handle)` -- blocks | `STATUS_PENDING` -- returns immediately |
| CQE wakeup | ntsync `uring_fd` -> retry loop drains CQ -> `set_async_direct_result` -> ntsync signals wait_handle | `set_async_direct_result` -> server signals event/IOCP |
| Fallback (EAGAIN in CQE) | `set_async_direct_result(PENDING)` -> server restarts async -> epoll | Same |

### What's Pending

The architecture and code are landed in `dlls/ntdll/unix/socket.c`,
`dlls/ntdll/unix/sync.c`, and `server/sock.c`. What's pending is a
focused validation session against:

- The post-audit ntsync module (`A250A77651C8D5DAB719FE2`).
- The audit §4.1 retry-loop hardening shipped in superproject
  `a7e34c7` (closes silent shmem-ring contract violations that the
  socket interception path also touches).
- The current socket-io PE test (Phase A immediate + Phase B
  overlapped) under both baseline and RT modes.

Until that session lands, treat Phase 2 as un-validated against
current kernel + ring code.

---

## 7. Phase 3: Pipes and Named Events (pending)

**Status: Pending. Not yet designed.**

Pipe I/O (`NtReadFile` / `NtWriteFile` on `FILE_PIPE` handles) and named
events (`NtCreateNamedPipeFile`, `NtCreateEvent` with name) currently
take the same server-mediated async path as sockets. They share the
same `register_async`/epoll-monitor/`async_wake_up` lifecycle.

The expected design reuses Phase 2's ALERTED-state interception with
object-class-specific completion paths:

- **Pipe handles:** `IORING_OP_READ` / `IORING_OP_WRITE` directly on
  the unix fd (analogous to file I/O). Need to handle pipe-specific
  EOF and EPIPE semantics.
- **Named events:** No fd to poll -- this is a server-side naming
  question, not an io_uring question. May fold into the gamma channel
  bypass instead.

This work has not been scheduled. It is captured here for completeness
of the bypass roadmap.

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
| `dlls/ntdll/unix/file.c` | ~30 | Phase 1: sync poll + async read/write bypass |
| `dlls/ntdll/unix/socket.c` | ~120 | Phase 2: ALERTED interception, CQE handler, bitmap set/clear |
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

## 9. Status Summary

| Component | Status | Notes |
|-----------|--------|-------|
| io_uring ring management | Shipped | Per-thread, lazy init |
| Pool allocator (TLS, 32 ops) | Shipped | RT-safe, zero malloc in submit path |
| Phase 1: sync poll + async file I/O | Shipped, default-on | `NtReadFile` / `NtWriteFile` |
| Phase 2: socket I/O (sync + overlapped) | Pending revalidation | Architecture settled; needs re-test against post-audit ntsync + §4.1 ring hardening |
| Phase 3: pipes + named events | Pending design | Not scheduled |
| E2 bitmap (server `sock.c`) | Shipped | Engaged when Phase 2 client-poll bit is set |
| ntsync `uring_fd` extension | Shipped (kernel patch) | Wakes ntsync waits on CQE |
| ntsync PI v2 + audit fixes | Shipped (kernel patch) | Module srcversion `A250A77651C8D5DAB719FE2` |
| Audit §4.1 retry-loop hardening | Shipped (wine) | Superproject `a7e34c7` |

### Next Actions

1. Phase 2 revalidation session: run `socket-io` PE test under current
   ntsync + audit-hardened ring code; flip Phase 2 default-on if clean.
2. Phase 3 design pass: enumerate pipe + named-event server paths and
   decide whether to reuse Phase 2's ALERTED interception or fold into
   the gamma channel bypass.
3. Profile: measure server epoll fd reduction and global_lock hold
   time under socket load.
4. Investigate multishot recv + provided buffers for streaming socket
   optimization.
