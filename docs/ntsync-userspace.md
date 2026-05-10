# Wine-NSPA -- NTSync Userspace Sync

This page documents the Wine-side ntsync integration: handle-to-fd
caching, client-created sync objects, direct wait / signal helpers, and
the current zero-time wait fast paths that sit above them. The kernel half
lives on [NTSync PI Kernel](ntsync-pi-driver.gen.html).

## Table of Contents

1. [Overview](#1-overview)
2. [Two userspace consumer shapes](#2-two-userspace-consumer-shapes)
3. [Server-owned sync handles](#3-server-owned-sync-handles)
4. [Client-created anonymous sync handles](#4-client-created-anonymous-sync-handles)
5. [Wait and signal execution](#5-wait-and-signal-execution)
6. [`linux_wait_objs`](#6-linux_wait_objs)
7. [`linux_set_event_obj_pi`](#7-linux_set_event_obj_pi)
8. [Channel ioctl wrappers](#8-channel-ioctl-wrappers)
9. [`alloc_client_handle`](#9-alloc_client_handle)
10. [PE-side wait coverage](#10-pe-side-wait-coverage)
11. [References](#11-references)

---

## 1. Overview

Wine-NSPA's ntsync userspace integration lives primarily in
`dlls/ntdll/unix/sync.c`, with the server-owned bridge in
`server/inproc_sync.c`. This is the half of the story the kernel-side
patches do not show by themselves: the kernel provides
`/dev/ntsync` and the ioctl set; Wine has to decide which Win32
handles can resolve to an ntsync fd, where that fd comes from, and how
to keep the resulting `(handle -> fd)` mapping coherent with handle
reuse and process exit.

Steady state for a supported sync object on Wine-NSPA is:
`NtWaitForSingleObject` / `NtSetEvent` / `NtReleaseSemaphore` /
`NtReleaseMutant` go straight to `/dev/ntsync` with no wineserver
round-trip. The first wait or signal on a handle resolves the handle to
an fd; subsequent operations hit the local cache.

That steady state has two important fast-path refinements above it:

- single-handle zero-time waits on process handles can answer from
  `process_shm`
- single-handle zero-time waits on thread handles can answer from
  `thread_shm`

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 360" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ov-bg { fill: #1a1b26; }
    .ov-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .ov-fast { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .ov-mid { fill: #1f2535; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .ov-kernel { fill: #1a1a2a; stroke: #bb9af7; stroke-width: 2; rx: 8; }
    .ov-t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .ov-s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .ov-h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .ov-g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .ov-v { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
    .ov-line-b { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .ov-line-v { stroke: #bb9af7; stroke-width: 1.2; fill: none; }
    .ov-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="940" height="360" class="ov-bg"/>
  <text x="470" y="28" text-anchor="middle" class="ov-h">Userspace ntsync integration: layers and steady-state flow</text>

  <rect x="40" y="64" width="220" height="88" class="ov-box"/>
  <text x="150" y="90" text-anchor="middle" class="ov-t">Win32 caller</text>
  <text x="150" y="110" text-anchor="middle" class="ov-s">NtWait* / NtSetEvent / NtReleaseSemaphore</text>
  <text x="150" y="126" text-anchor="middle" class="ov-s">SignalObjectAndWait, queue wake,</text>
  <text x="150" y="142" text-anchor="middle" class="ov-s">async completion wake</text>

  <rect x="290" y="64" width="220" height="88" class="ov-mid"/>
  <text x="400" y="90" text-anchor="middle" class="ov-v">ntdll inproc_sync layer</text>
  <text x="400" y="110" text-anchor="middle" class="ov-s">cache lookup, type+access check,</text>
  <text x="400" y="126" text-anchor="middle" class="ov-s">handle-to-fd resolution,</text>
  <text x="400" y="142" text-anchor="middle" class="ov-s">close-bit + refcount discipline</text>

  <rect x="540" y="64" width="220" height="88" class="ov-fast"/>
  <text x="650" y="90" text-anchor="middle" class="ov-g">linux_wait_objs / direct signal</text>
  <text x="650" y="110" text-anchor="middle" class="ov-s">issues NTSYNC_IOC_WAIT_ANY / WAIT_ALL,</text>
  <text x="650" y="126" text-anchor="middle" class="ov-s">EVENT_SET / EVENT_SET_PI,</text>
  <text x="650" y="142" text-anchor="middle" class="ov-s">SEM_RELEASE, MUTEX_UNLOCK</text>

  <rect x="790" y="64" width="120" height="88" class="ov-kernel"/>
  <text x="850" y="90" text-anchor="middle" class="ov-v">/dev/ntsync</text>
  <text x="850" y="110" text-anchor="middle" class="ov-s">drivers/misc/ntsync.c</text>
  <text x="850" y="126" text-anchor="middle" class="ov-s">PI baseline +</text>
  <text x="850" y="142" text-anchor="middle" class="ov-s">channel + agg-wait</text>

  <line x1="260" y1="108" x2="290" y2="108" class="ov-line-b"/>
  <line x1="510" y1="108" x2="540" y2="108" class="ov-line-v"/>
  <line x1="760" y1="108" x2="790" y2="108" class="ov-line-g"/>

  <rect x="40" y="190" width="380" height="74" class="ov-mid"/>
  <text x="230" y="214" text-anchor="middle" class="ov-v">server-owned path (named / inherited / cross-process)</text>
  <text x="230" y="236" text-anchor="middle" class="ov-s">first use: SERVER_REQ get_inproc_sync_fd -> fd cached</text>
  <text x="230" y="252" text-anchor="middle" class="ov-s">subsequent waits / signals bypass wineserver entirely</text>

  <rect x="450" y="190" width="460" height="74" class="ov-fast"/>
  <text x="680" y="214" text-anchor="middle" class="ov-g">client-created path (anonymous mutex / semaphore / event)</text>
  <text x="680" y="236" text-anchor="middle" class="ov-s">alloc_client_handle() + NTSYNC_IOC_CREATE_* in ntdll itself</text>
  <text x="680" y="252" text-anchor="middle" class="ov-s">no wineserver round-trip to mint the object; cache populated immediately</text>

  <rect x="180" y="296" width="580" height="50" class="ov-box"/>
  <text x="470" y="320" text-anchor="middle" class="ov-t">both paths converge on the same wait / signal helpers in dlls/ntdll/unix/sync.c</text>
  <text x="470" y="336" text-anchor="middle" class="ov-s">linux_wait_objs(), linux_set_event_obj_pi(), and the matching unlock / release ioctls</text>
</svg>
</div>

---

## 2. Two userspace consumer shapes

There are two distinct userspace shapes:

- **server-owned sync handles**: named objects, inherited objects,
  cross-process objects, and any handle that still originates in
  wineserver. The first wait or signal does a one-time
  `get_inproc_sync_fd` request; after that, ntdll caches the fd and
  goes direct.
- **client-created anonymous sync handles**: anonymous mutexes,
  anonymous semaphores, and anonymous events. These never need
  wineserver to mint the fd in the first place; ntdll allocates a
  client-range handle, issues the ntsync create ioctl itself, and
  populates the cache immediately.

The two shapes share the same `inproc_sync` cache layout and the same
wait / signal helpers downstream. They differ only in where the fd
comes from on the first reference.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 470" xmlns="http://www.w3.org/2000/svg">
  <style>
    .bg { fill: #1a1b26; }
    .lane { fill: #24283b; stroke: #6b7398; stroke-width: 1.2; rx: 10; }
    .srv { fill: #1f2535; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .cli { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .mid { fill: #2a1f35; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .v { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
    .y { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .line-b { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .line-v { stroke: #bb9af7; stroke-width: 1.2; fill: none; }
    .line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
    .guide { stroke: #6b7398; stroke-width: 1; stroke-dasharray: 6,4; }
  </style>

  <rect x="0" y="0" width="980" height="470" class="bg"/>
  <text x="490" y="26" text-anchor="middle" class="h">Server-owned vs. client-created handle paths</text>

  <rect x="40" y="56" width="420" height="324" class="lane"/>
  <text x="250" y="82" text-anchor="middle" class="v">server-owned handle path</text>

  <rect x="80" y="104" width="340" height="60" class="srv"/>
  <text x="250" y="128" text-anchor="middle" class="t">named / inherited / cross-process Win32 sync handle</text>
  <text x="250" y="146" text-anchor="middle" class="s">wineserver remains the authority that created the object</text>

  <line x1="250" y1="164" x2="250" y2="192" class="line-b"/>

  <rect x="80" y="192" width="340" height="70" class="mid"/>
  <text x="250" y="216" text-anchor="middle" class="t">server inproc_sync object + ntsync fd</text>
  <text x="250" y="234" text-anchor="middle" class="s">server/inproc_sync.c owns the fd, exposes it via get_inproc_sync_fd</text>
  <text x="250" y="252" text-anchor="middle" class="s">one-time wineserver lookup on first consumer-side use</text>

  <line x1="250" y1="262" x2="250" y2="292" class="line-v"/>

  <rect x="80" y="292" width="340" height="60" class="srv"/>
  <text x="250" y="316" text-anchor="middle" class="t">ntdll inproc_sync cache entry</text>
  <text x="250" y="334" text-anchor="middle" class="s">later waits and signals bypass wineserver and reuse the cached fd</text>

  <rect x="520" y="56" width="420" height="324" class="lane"/>
  <text x="730" y="82" text-anchor="middle" class="g">client-created anonymous path</text>

  <rect x="560" y="104" width="340" height="60" class="cli"/>
  <text x="730" y="128" text-anchor="middle" class="t">anonymous NtCreateMutex / NtCreateSemaphore / NtCreateEvent</text>
  <text x="730" y="146" text-anchor="middle" class="s">anonymous events use this client-created path by default</text>

  <line x1="730" y1="164" x2="730" y2="192" class="line-g"/>

  <rect x="560" y="192" width="340" height="70" class="cli"/>
  <text x="730" y="216" text-anchor="middle" class="t">ntdll allocates client-range handle and issues NTSYNC_IOC_CREATE_*</text>
  <text x="730" y="234" text-anchor="middle" class="s">fd is cached immediately; no wineserver round-trip to mint the object</text>
  <text x="730" y="252" text-anchor="middle" class="s">anonymous events also register their fd with wineserver for async completion</text>

  <line x1="730" y1="262" x2="730" y2="292" class="line-g"/>

  <rect x="560" y="292" width="340" height="60" class="cli"/>
  <text x="730" y="316" text-anchor="middle" class="t">same ntdll inproc_sync cache shape</text>
  <text x="730" y="334" text-anchor="middle" class="s">waits and signals go straight to /dev/ntsync from the first operation</text>

  <line x1="250" y1="380" x2="250" y2="410" class="guide"/>
  <line x1="730" y1="380" x2="730" y2="410" class="guide"/>
  <line x1="250" y1="410" x2="730" y2="410" class="guide"/>

  <rect x="220" y="402" width="540" height="52" class="note"/>
  <text x="490" y="426" text-anchor="middle" class="y">both paths converge on the same wait / signal helpers</text>
  <text x="490" y="442" text-anchor="middle" class="s">dlls/ntdll/unix/sync.c drives the same /dev/ntsync ioctls in both cases</text>
</svg>
</div>

---

## 3. Server-owned sync handles

Server-owned sync objects still exist because some Win32 handles are
not purely local: named objects, inherited handles, and cross-process
objects all need wineserver as the authoritative creator and
bookkeeper. That does **not** mean every wait on those objects keeps
round-tripping through wineserver.

`server/inproc_sync.c` attaches an ntsync-backed
`struct inproc_sync` object to the server object and keeps the fd
alive there. On the client side, `get_inproc_sync()` first tries a
lock-free cache lookup. On a miss, ntdll enters the protected
`fd_cache_mutex` section, asks wineserver for `get_inproc_sync_fd`,
receives the fd once, and then caches `(handle -> fd, type, access)`
locally.

The important steady-state property is: **server-owned does not mean
server-waited**. Once the fd is cached, `NtWaitForSingleObject`,
`NtWaitForMultipleObjects`, `NtSetEvent`, `NtReleaseSemaphore`, and
the other supported paths all go straight to `/dev/ntsync`.

### Cache structure

`dlls/ntdll/unix/sync.c` keeps a flat array indexed by handle of
`struct inproc_sync`:

    struct __attribute__((aligned(64))) inproc_sync {
        int           fd;
        unsigned int  refcount;
        unsigned char closed;
        unsigned char type;       /* enum inproc_sync_type as short */
        ACCESS_MASK   access;
        ...
    };

    #define INPROC_SYNC_CACHE_BLOCK_BYTES  (256 * 1024)
    #define INPROC_SYNC_CACHE_BLOCK_SIZE   (INPROC_SYNC_CACHE_BLOCK_BYTES / sizeof(struct inproc_sync))
    static struct inproc_sync *inproc_sync_cache[INPROC_SYNC_CACHE_ENTRIES];
    static struct inproc_sync inproc_sync_cache_initial_block[INPROC_SYNC_CACHE_BLOCK_SIZE];

The cache is laid out as an array of blocks; block 0 is statically
allocated, later blocks are `mmap`ed as handles climb. Each entry
carries a refcount and a `closed` bit.

The current layout is deliberately cacheline-shaped:

- each entry is padded to 64 bytes so refcount `LOCK` traffic on one handle
  does not false-share with unrelated handles
- block bytes were widened to 256 KiB so total cacheable handle capacity
  stays at `524288` after the padding change

### Lookup discipline

`get_inproc_sync()`:

1. Lock-free cache lookup via `get_cached_inproc_sync()` -- single
   relaxed atomic load on the entry plus an acquire fence to pair
   with the cache writer.
2. On miss: `server_enter_uninterrupted_section(&fd_cache_mutex, ...)`,
   re-check the cache (another thread may have populated it), then
   `SERVER_REQ get_inproc_sync_fd` to receive the fd. Cache it via
   `cache_inproc_sync()`.
3. Refcount drop on release; the entry stays in the array but its
   `closed` bit prevents handing the same fd back after close.

The miss path is protected by `fd_cache_mutex` plus the uninterrupted
section so fd receipt cannot race with handle close or concurrent fd
caching by another thread.

---

## 4. Client-created anonymous sync handles

For anonymous objects, Wine-NSPA can skip wineserver even at creation
time.

`alloc_client_handle()` hands out values from a client-private handle
range that is disjoint from server handles. ntdll then issues the
kernel create ioctl itself:

- `NTSYNC_IOC_CREATE_MUTEX`
- `NTSYNC_IOC_CREATE_SEM`
- `NTSYNC_IOC_CREATE_EVENT`

and stores the returned fd directly in the same `inproc_sync` cache
that the server-owned path uses.

The rules are:

- anonymous mutexes: client-created
- anonymous semaphores: client-created
- anonymous events: client-created by default, using the same cache
  and direct wait/signal helpers as anonymous mutexes and semaphores
- named or inheritable objects: stay on the server path

### Two extra pieces of bookkeeping

#### Client-mutex list -- abandoned-mutex semantics on thread exit

Win32 mutexes have abandoned semantics: a thread that holds a mutex
and exits without releasing it leaves the mutex in an abandoned state
that the next acquirer observes as `WAIT_ABANDONED`. The kernel
ntsync driver implements this via `NTSYNC_IOC_MUTEX_KILL`, which marks
the mutex as abandoned by a TID.

Wineserver normally tracks ownership by walking a thread's owned
objects on death. Client-created mutexes are not visible to
wineserver, so ntdll has to track them itself:

    static struct list client_mutex_list = LIST_INIT( client_mutex_list );

Each `NTSYNC_IOC_CREATE_MUTEX` from `alloc_client_handle` registers a
`client_mutex_entry` in this list. On thread exit, ntdll walks the
list and issues `NTSYNC_IOC_MUTEX_KILL` for any mutex still owned by
the dying TID. That preserves Win32 abandoned-mutex semantics for
client-created mutexes.

#### Anonymous-event fd registration with wineserver

A server-side async completion (file I/O, RPC, etc.) needs to signal
the consumer's event. Server code holds a Win32 handle, not an fd.
When the consumer's event is client-created the server cannot resolve
the handle -- the handle is in the client-private range.

Client-created events register their fd with wineserver after creation
so server-side async completion can signal them directly. The
registration carries `(handle, fd)`; the server stashes the fd against
the handle's existing async completion machinery.

---

## 5. Wait and signal execution

The steady-state wait helper is `inproc_wait()`. It resolves each
handle to an fd with `get_inproc_sync()`, collects an optional alert
fd, adds the optional `io_uring` eventfd, and then calls
`linux_wait_objs()`.

Two special cases sit above that common helper:

- `WaitForSingleObject(process, 0)` can answer from `process_shm.exit_code`
  before any ntsync wait path runs
- `WaitForSingleObject(thread, 0)` can answer from
  `THREAD_SHM_FLAG_TERMINATED` before any ntsync wait path runs

The ordinary blocking and multi-object wait shapes still go through the ntsync
path described here.

The full wait path is therefore a *userspace + kernel* design:

- ntdll does handle-to-fd resolution and cache management
- `linux_wait_objs()` issues `NTSYNC_IOC_WAIT_ANY` / `WAIT_ALL`
- if ntsync wakes because the `io_uring` eventfd fired, ntdll drains
  CQEs and re-enters the wait

Signal-side helpers follow the same shape. `inproc_signal_and_wait()`
releases or signals the source object directly with the matching
ioctl, then waits on the destination object with the same in-process
wait path.

For cross-thread wakeups inside Wine,
`wine_server_signal_internal_sync()` is the high-level entry point.
If the current thread is running with an RT policy and priority, it
calls `linux_set_event_obj_pi()` (which issues
`NTSYNC_IOC_EVENT_SET_PI`); otherwise it falls back to plain
`linux_set_event()` (which issues `NTSYNC_IOC_EVENT_SET`). That is
the userspace half of the kernel's deferred-boost behaviour from
patch 1008.

### 5.1 Zero-time process and thread waits

The current zero-time wait fast paths are a small but important extension of
the in-process sync model. By the time a process or thread handle has resolved
to an ntsync-backed wait object, Wine also already has the published shared
object that can answer the liveness question directly.

| Handle type | Shared-state predicate | Local result |
|---|---|---|
| Process | `process_shm.exit_code == STILL_ACTIVE` | alive -> `STATUS_TIMEOUT`, dead -> `STATUS_WAIT_0` |
| Thread | `THREAD_SHM_FLAG_TERMINATED` | clear -> `STATUS_TIMEOUT`, set -> `STATUS_WAIT_0` |

The thread case uses the termination flag instead of `exit_code != 0` because a
thread exit code begins at `0`, which is a valid user result.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 370" xmlns="http://www.w3.org/2000/svg">
  <style>
    .zw-bg { fill: #1a1b26; }
    .zw-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .zw-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .zw-purple { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.7; rx: 8; }
    .zw-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.7; rx: 8; }
    .zw-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .zw-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .zw-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .zw-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .zw-tag-p { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .zw-tag-y { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .zw-line-b { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .zw-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
    .zw-line-p { stroke: #bb9af7; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="370" class="zw-bg"/>
  <text x="480" y="26" text-anchor="middle" class="zw-title">Zero-time waits short-circuit before the ntsync ioctl</text>

  <rect x="50" y="76" width="220" height="92" class="zw-box"/>
  <text x="160" y="102" text-anchor="middle" class="zw-label">single-handle `WaitForSingleObject(..., 0)`</text>
  <text x="160" y="124" text-anchor="middle" class="zw-small">non-alertable only</text>
  <text x="160" y="140" text-anchor="middle" class="zw-small">ordinary waits still go through `linux_wait_objs()`</text>

  <rect x="320" y="76" width="250" height="104" class="zw-green"/>
  <text x="445" y="102" text-anchor="middle" class="zw-tag-g">process handle</text>
  <text x="445" y="124" text-anchor="middle" class="zw-small">read `process_shm.exit_code`</text>
  <text x="445" y="144" text-anchor="middle" class="zw-small">alive -> `STATUS_TIMEOUT`</text>
  <text x="445" y="160" text-anchor="middle" class="zw-small">dead -> `STATUS_WAIT_0`</text>

  <rect x="620" y="76" width="250" height="104" class="zw-purple"/>
  <text x="745" y="102" text-anchor="middle" class="zw-tag-p">thread handle</text>
  <text x="745" y="124" text-anchor="middle" class="zw-small">read `THREAD_SHM_FLAG_TERMINATED`</text>
  <text x="745" y="144" text-anchor="middle" class="zw-small">clear -> `STATUS_TIMEOUT`</text>
  <text x="745" y="160" text-anchor="middle" class="zw-small">set -> `STATUS_WAIT_0`</text>

  <line x1="270" y1="122" x2="320" y2="122" class="zw-line-g"/>
  <line x1="570" y1="122" x2="620" y2="122" class="zw-line-p"/>

  <rect x="200" y="232" width="560" height="86" class="zw-yellow"/>
  <text x="480" y="258" text-anchor="middle" class="zw-tag-y">measured synthetic poll cost</text>
  <text x="480" y="280" text-anchor="middle" class="zw-small">process handles: `~10000 ns/poll -> ~144 ns/poll`</text>
  <text x="480" y="296" text-anchor="middle" class="zw-small">thread handles: `~11940 ns/poll -> ~164 ns/poll`</text>
</svg>
</div>

### 5.2 Current cache layout on the hot path

The `inproc_sync` cache itself is also part of the current userspace sync
story. Hot waits and signals increment entry refcounts constantly, so false
sharing across unrelated handles showed up as distributed coherence cost.

The layout uses one cacheline per entry and keeps the original
`524288`-handle capacity by widening each cache block instead of shrinking the
cache.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .bg { fill: #1a1b26; }
    .box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .fast { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .mid { fill: #1f2535; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .v { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
    .y { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .line-b { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .line-v { stroke: #bb9af7; stroke-width: 1.2; fill: none; }
    .line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="980" height="430" class="bg"/>
  <text x="490" y="26" text-anchor="middle" class="h">Userspace wait / signal path on top of ntsync</text>

  <rect x="80" y="76" width="240" height="78" class="box"/>
  <text x="200" y="102" text-anchor="middle" class="t">Win32 call site</text>
  <text x="200" y="124" text-anchor="middle" class="s">NtWait*, SignalObjectAndWait, queue wake, async completion wake</text>

  <rect x="370" y="76" width="240" height="78" class="mid"/>
  <text x="490" y="102" text-anchor="middle" class="v">ntdll inproc_sync layer</text>
  <text x="490" y="124" text-anchor="middle" class="s">cache lookup, access/type check, optional server fd fetch on miss</text>

  <rect x="660" y="76" width="240" height="78" class="fast"/>
  <text x="780" y="102" text-anchor="middle" class="g">linux_wait_objs() / direct signal helper</text>
  <text x="780" y="124" text-anchor="middle" class="s">issues WAIT_ANY / WAIT_ALL / EVENT_SET(_PI) / unlock / release ioctls</text>

  <line x1="320" y1="115" x2="370" y2="115" class="line-b"/>
  <line x1="610" y1="115" x2="660" y2="115" class="line-v"/>

  <rect x="180" y="224" width="220" height="86" class="box"/>
  <text x="290" y="248" text-anchor="middle" class="t">wait side</text>
  <text x="290" y="268" text-anchor="middle" class="s">optional alert fd</text>
  <text x="290" y="286" text-anchor="middle" class="s">optional io_uring eventfd</text>

  <rect x="430" y="224" width="220" height="86" class="mid"/>
  <text x="540" y="248" text-anchor="middle" class="t">kernel wake result</text>
  <text x="540" y="268" text-anchor="middle" class="s">object signaled, alert fired, or STATUS_URING_COMPLETION</text>
  <text x="540" y="286" text-anchor="middle" class="s">CQE wake loops back through ntdll drain and re-wait</text>

  <rect x="680" y="224" width="220" height="86" class="fast"/>
  <text x="790" y="248" text-anchor="middle" class="g">signal side</text>
  <text x="790" y="268" text-anchor="middle" class="s">direct event set / mutex unlock / semaphore release</text>
  <text x="790" y="286" text-anchor="middle" class="s">EVENT_SET_PI used when caller is RT and priority-known</text>

  <line x1="490" y1="154" x2="490" y2="188" class="line-v"/>
  <line x1="490" y1="188" x2="290" y2="188" class="line-v"/>
  <line x1="290" y1="188" x2="290" y2="224" class="line-v"/>
  <line x1="780" y1="154" x2="780" y2="188" class="line-g"/>
  <line x1="780" y1="188" x2="790" y2="188" class="line-g"/>
  <line x1="790" y1="188" x2="790" y2="224" class="line-g"/>
  <line x1="400" y1="266" x2="430" y2="266" class="line-b"/>

  <rect x="200" y="340" width="580" height="56" class="note"/>
  <text x="490" y="364" text-anchor="middle" class="y">steady state is direct once a handle resolves to an ntsync fd</text>
  <text x="490" y="380" text-anchor="middle" class="s">waits and signals bypass wineserver until close</text>
</svg>
</div>

---

## 6. `linux_wait_objs`

The wait wrapper is largely unchanged from upstream. NSPA's only
addition is the `uring_fd` parameter (passed via the repurposed `pad`
field of `struct ntsync_wait_args`) that lets a single `WAIT_ANY` call
wake on either an ntsync object signal or an `io_uring` CQE.

    static NTSTATUS linux_wait_objs(int device, DWORD count, const int *objs,
                                    WAIT_TYPE type, int alert_fd, int uring_fd,
                                    const LARGE_INTEGER *timeout)
    {
        struct ntsync_wait_args args = {0};
        ...
        args.objs  = (uintptr_t)objs;
        args.count = count;
        args.owner = GetCurrentThreadId();
        args.alert = alert_fd;
        args.pad   = uring_fd > 0 ? uring_fd : 0;

        request = (type != WaitAll || count == 1) ? NTSYNC_IOC_WAIT_ANY
                                                  : NTSYNC_IOC_WAIT_ALL;
        do { ret = ioctl(device, request, &args); }
        while (ret < 0 && errno == EINTR);
        ...
    }

The user-space code is deliberately oblivious to the kernel-side
`EVENT_SET_PI` staging machinery (patch 1008) and the field-snapshot
fix (patch 1012). Wine just calls `WAIT_ANY` / `WAIT_ALL`; the kernel
handles boost consumption and entry lifetime transparently. No
Wine-side change was needed for those carries.

---

## 7. `linux_set_event_obj_pi`

The cross-thread priority-intent setter is a thin ioctl wrapper:

    static NTSTATUS linux_set_event_obj_pi(int obj, unsigned int policy,
                                           unsigned int prio)
    {
        struct ntsync_event_set_pi_args args = {
            .flags  = 0,
            .policy = policy,
            .prio   = prio,
            .__pad  = 0
        };
        if (ioctl(obj, NTSYNC_IOC_EVENT_SET_PI, &args) < 0)
            return errno_to_status(errno);
        return STATUS_SUCCESS;
    }

This is called from the gamma dispatcher path when an RT audio thread
signals a queue event to the dispatcher pthread. The audio thread
passes its own `(SCHED_FIFO, prio)`; the kernel stages the boost on
the event; the dispatcher consumes the signal in its `WAIT_ANY` and
gets boosted at wait-return.

After patch 1008, the path is bulletproof against the fast-path race:
even if the dispatcher pthread takes `obj_lock` first and sees
`signaled=true`, it consumes the staged boost in the unqueue loop on
its way out.

---

## 8. Channel ioctl wrappers

The wineserver dispatcher uses the channel ioctls directly via
`ioctl()` calls; there is no portable `linux_channel_*` helper at the
Wine ntdll layer because channels are wineserver-process-private (they
do not cross the wineserver / client boundary as Win32 handles).

The dispatcher loop calls:

    ioctl(channel_fd, NTSYNC_IOC_CHANNEL_RECV2, &args);
    /* dispatch using args.thread_token */
    ioctl(channel_fd, NTSYNC_IOC_CHANNEL_REPLY, &args.entry_id);

On the current kernel/userspace pair, the dispatcher uses
`RECV2` for dequeue, follows each reply with `TRY_RECV2` until the
channel returns empty, and uses `NTSYNC_IOC_AGGREGATE_WAIT` to block on
the channel + uring eventfd + shutdown eventfd in one syscall.

The client-side `SEND_PI` is invoked from the wineserver
request-marshalling fast path; the client's RT thread blocks in the
kernel until reply.

---

## 9. `alloc_client_handle`

Client-side ntsync object creation uses
`InterlockedDecrement(&client_handle_next)` to allocate client-range
handles that do not collide with server-allocated handles. The
client-private range starts at a large constant
(`INPROC_SYNC_CACHE_TOTAL`) and counts down, while server handles
count up from low values; the two ranges never meet for typical Wine
processes.

Wait operations (`NtWaitForSingleObject`) resolve the handle to a
cached fd via `inproc_wait()`, then call `linux_wait_objs()` which
issues the kernel ioctl directly.

Currently enabled for anonymous mutexes, semaphores, and events.

---

## 10. PE-side wait coverage

The userspace ntsync surface is exercised by both Layer 1 native
ntsync tests and the Layer 2 PE matrix. The split is:

- **PE-side wait coverage** exercises the userspace path described
  above. The `nspa_rt_test.exe ntsync` harness creates Win32 mutexes,
  semaphores, and events, resolves them through `inproc_wait()`, and
  then hits `linux_wait_objs()` / the direct signal helpers.
- **Queue-wake and local-event coverage** exercises the direct event
  signal path (`wine_server_signal_internal_sync()` and the registered
  event-fd path used by async completion).
- **Native ntsync tests** exercise raw kernel behaviour that the Win32
  surface cannot reach directly: staged `EVENT_SET_PI`, channel
  races, aggregate-wait source ordering, and the hardening bugs from
  1007-1009 / 1012 / 1014a.

Layer 2 current archived full-suite boundary is
`32 PASS / 0 FAIL / 0 TIMEOUT` on the PE matrix; Layer 1 native
sanity is `3 PASS / 0 FAIL / 0 SKIP`. The cross-build production-kernel runs
advanced from the earlier post-1009 baseline through aggregate-wait,
burst drain, the later receive-snapshot and dedicated-cache hardening,
and the current cache-isolated overlay -- with zero syscall errors and
zero dmesg splats at every step.

---

## 11. References

### Wine source

- `dlls/ntdll/unix/sync.c` -- `linux_wait_objs()`,
  `linux_set_event_obj_pi()`, `linux_set_event()`,
  `linux_release_semaphore()`, `linux_unlock_mutex()`,
  the `inproc_sync` cache (`get_cached_inproc_sync()`,
  `cache_inproc_sync()`, `release_inproc_sync()`,
  `get_server_inproc_sync()`), `alloc_client_handle()`, the
  `client_mutex_list` thread-exit walker, and the client-created
  anonymous-event path in `NtCreateEvent`.
- `server/inproc_sync.c` -- the server-side `struct inproc_sync` that
  attaches an ntsync fd to a wineserver object, plus the
  `get_inproc_sync_fd` request handler.

### Kernel surface

- `include/uapi/linux/ntsync.h` -- ioctl numbers,
  `ntsync_wait_args`, `NTSYNC_INDEX_URING_READY`, channel and
  thread-token ioctl arg structs.
- `drivers/misc/ntsync.c` -- the kernel implementation; see the
  [NTSync PI Kernel](ntsync-pi-driver.gen.html) page for the
  patch-by-patch walkthrough.

### Cross-references

- [NTSync PI Kernel](ntsync-pi-driver.gen.html) -- the kernel half:
  PI primitives, channel transport, aggregate-wait, post-1011 carries.
- [Gamma Channel Dispatcher](gamma-channel-dispatcher.gen.html) --
  how the wineserver dispatcher uses the channel ioctls and consumes
  the thread-token, with TRY_RECV2 burst drain on top of
  aggregate-wait.
- [Aggregate-Wait and Async Completion](aggregate-wait-and-async-completion.gen.html)
  -- the heterogeneous wait surface and its same-thread async
  completion consumer.
- [librtpi (PI mutex / condvar)](librtpi.gen.html) -- the
  Wine-internal librtpi shim that closes Wine's userspace PI-mutex
  gap, complementary to the ntsync object-PI path documented here.
