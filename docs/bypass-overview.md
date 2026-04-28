# Wine-NSPA -- Bypass Overview: Trajectories Out of Wineserver

Wine 11.6 + NSPA RT patchset | Kernel 6.19.x-rt with NTSync PI | 2026-04-28
Author: jordan Johnston

## Table of Contents

1. [What this doc is](#1-what-this-doc-is)
2. [Strategy: bypasses as a strangler pattern](#2-strategy-bypasses-as-a-strangler-pattern)
3. [The trajectory map](#3-the-trajectory-map)
4. [Trajectory profiles](#4-trajectory-profiles)
    - 4.1 [File I/O via io_uring (Phase 1)](#41-file-io-via-io_uring-phase-1)
    - 4.2 [Synchronization primitives via direct NTSync](#42-synchronization-primitives-via-direct-ntsync)
    - 4.3 [Hook chains (Tier 1+2 cache)](#43-hook-chains-tier-12-cache)
    - 4.4 [NtCreateFile via local_file stub](#44-ntcreatefile-via-local_file-stub)
    - 4.5 [NtSetTimer / WM_TIMER via local timer dispatchers](#45-ntsettimer--wm_timer-via-local-timer-dispatchers)
    - 4.6 [PostMessage / SendMessage via msg-ring v1](#46-postmessage--sendmessage-via-msg-ring-v1)
    - 4.7 [Paint cache fastpath (msg-ring v2 B1.0)](#47-paint-cache-fastpath-msg-ring-v2-b10)
    - 4.8 [redraw_window push ring (msg-ring v2 Phase A)](#48-redraw_window-push-ring-msg-ring-v2-phase-a)
    - 4.9 [GetMessage bypass (msg-ring v2 Phase C)](#49-getmessage-bypass-msg-ring-v2-phase-c)
    - 4.10 [Sechost device-IRP poll](#410-sechost-device-irp-poll)
    - 4.11 [Socket/pipe I/O via io_uring (Phase 2/3)](#411-socketpipe-io-via-io_uring-phase-23)
    - 4.12 [Wineserver process+thread lifecycle](#412-wineserver-processthread-lifecycle)
5. [What MUST stay in wineserver](#5-what-must-stay-in-wineserver)
6. [Composition: how the trajectories compose toward decomposition](#6-composition-how-the-trajectories-compose-toward-decomposition)
7. [State of the trajectory map (2026-04-28)](#7-state-of-the-trajectory-map-2026-04-28)
8. [Connection to recent work](#8-connection-to-recent-work)
9. [Trajectory map diagram](#9-trajectory-map-diagram)

---

## 1. What this doc is

NSPA ships a lot of specific bypasses -- file I/O, sync primitives, hooks, message queues, paint flushing, timers, file inode arbitration. Each one is independently useful: it eliminates a class of wineserver round-trips, which usually translates into a measurable startup-time or latency win, and sometimes into an end of priority-inversion that was costing the RT audio path real xruns.

That framing -- "individual optimizations" -- is the wrong lens. Each bypass is a step along a much longer trajectory: progressively moving NT-API state OUT of wineserver, until what remains is small enough to decompose with surgery instead of with a rewrite. This document is the bird's-eye view: every trajectory NSPA is currently driving, where each one stands, and the strategic argument for why this approach beats a from-scratch wineserver replacement.

It complements `nt-local-stubs.gen.html` (the architectural pattern that lets handlers run inside the client process) by enumerating the concrete bypasses, where each one fits, and which trajectories are still ahead of us.

If you have read any individual bypass doc (`io_uring-architecture`, `ntsync-driver`, `nspa-local-file-architecture`, `msg-ring-architecture`, `hook-cache`) and wondered "wait, is this just a pile of point optimizations or is there a coherent direction?" -- this is the doc that answers that question.

---

## 2. Strategy: bypasses as a strangler pattern

Wine's classical architecture pins a lot of NT semantics to a single privileged process: `wineserver`. Every Win32 process talks to it over a request channel; the server holds a global lock around almost every handler; and the server is the source of truth for handles, sync objects, windows, the message bus, file inode-sharing arbitration, hooks, timers, IOCP, and so on.

That architecture is excellent for correctness (single source of truth, cross-process semantics free) and historically fine for performance (round-trip cost was small relative to whatever the app was doing). It is hostile to a hard-RT workload running an audio callback at FIFO 80+ that needs deterministic latency from any thread that might call into Wine. The server's `global_lock` and its `poll()` loop are a single point of serialization for every Win32 process running on the system.

Two ways to address that:

1. **Rewrite wineserver.** Architecturally clean. Massive in scope. Every handler has to be re-implemented, every cross-process semantic re-validated, every regression risk concentrated in one mega-change. The user (jordan Johnston) had stalled on this exact path: trying to land the decomposition directly was premature, because the surface that needed re-implementing was still enormous.

2. **Strangle wineserver.** Ship bypasses incrementally. Each bypass moves one class of state out of the server entirely (or routes one fast path around the global_lock). Each is independently valuable, independently revertible, gated behind an env var until it has been validated against real workloads. Cumulatively, the wineserver footprint shrinks until what remains is a thin metadata service rather than an application server. At that point the decomposition stops being "rewrite the architecture" and becomes "fold the remaining handlers into nt-local stubs and turn off the wineserver process for normal apps."

NSPA picked path 2. This doc documents the trajectories along that path.

The key property of a strangler bypass is: **it doesn't have to replace the server's logic, it just has to handle the common case so well that the server is left with the long tail**. The fallback to the server stays intact for everything outside the bypass envelope -- pathological inputs, cross-process scenarios the bypass can't model, anything still incomplete. The bypass earns its keep on the workload that matters (Ableton startup, plugin scans, message pumps, paint storms, drum-track-load-while-playing) and the server quietly handles whatever's left.

This is the same pattern as Martin Fowler's strangler-fig migration, applied to a userspace IPC architecture rather than a web service. Each trajectory is a strangler: started behind a default-off env var, validated under real workloads, flipped default-on after passing, ultimately becoming the de facto path with the server as tail-fallback.

There are three properties that make this approach work where a direct rewrite wouldn't:

- **Each bypass is independently revertible.** If a bypass exposes a regression -- correctness, performance, or stability -- the env-var gate flips back off and the server path takes over again. Compare the cost of reverting a single bypass to the cost of reverting one chunk of a unified rewrite.
- **Each bypass is independently valuable.** Even if the long arc never lands -- if NSPA stopped shipping new bypasses today -- the bypasses already shipped are concrete wins (28k file opens off Ableton's startup path, hook lookups dropped to zero on the wire, sync-object PI working end-to-end). A rewrite has no intermediate value: it ships when it ships.
- **Each bypass shrinks the residual.** The smaller the surface that wineserver still authoritatively serves, the smaller the eventual decomposition has to be. After enough trajectories ship, "decompose wineserver" stops looking like a research project and starts looking like a small set of mechanical splits.

The cost is paid in design uniformity: each trajectory has its own envelope, its own fallback rules, its own lazy-promotion path back to the server when the bypass envelope is exceeded. The trajectories are similar in shape but not identical, and "consolidate them all into one framework" is a tempting but premature unification. We don't want a framework yet -- we want shipped bypasses.

---

## 3. The trajectory map

Each row is a class of NT-API state that NSPA either has moved or is moving out of wineserver. "Default" is the runtime polarity in the current `nspa-rt` branch.

| # | Trajectory | Shipped | Default | Doc |
|---|---|---|---|---|
| 1 | File I/O via io_uring (Phase 1) | YES | on | `io_uring-architecture.gen.html` |
| 2 | Synchronization primitives (mutex/event/sem) via direct NTSync ioctls | YES | on | `ntsync-driver.gen.html` |
| 3 | Hook chains (Tier 1+2 cache) | YES | on | `hook-cache.gen.html` (new) |
| 4 | NtCreateFile (read-only regular files) via local_file stub | YES | on | `nspa-local-file-architecture.gen.html` |
| 5 | NtSetTimer / WM_TIMER via local timer dispatchers | YES | on | `nt-local-stubs.gen.html` |
| 6 | PostMessage / SendMessage (cross-thread same-process) via msg-ring v1 | YES | on | `msg-ring-architecture.gen.html` |
| 7 | Paint cache fastpath (msg-ring v2 B1.0) | shipped, validating | OFF (env opt-in `NSPA_ENABLE_PAINT_CACHE=1`) | `msg-ring-architecture.gen.html` |
| 8 | redraw_window push ring (msg-ring v2 Phase A) | YES | on | `msg-ring-architecture.gen.html` |
| 9 | GetMessage bypass (msg-ring v2 Phase C) | paused mid-development | n/a | `msg-ring-architecture.gen.html` |
| 10 | Sechost device-IRP poll | not yet | n/a | (future) |
| 11 | Socket/pipe I/O via io_uring (Phase 2/3) | not yet | n/a | `io_uring-architecture.gen.html` |
| 12 | Wineserver process+thread lifecycle | wineserver-resident (cannot bypass) | -- | (architectural floor) |

Read this table from the top: the first six rows are state that's actually been moved out and is on by default in normal NSPA operation. Rows 7-9 are the message-ring v2 finish line -- partially shipped, in active development. Rows 10-11 are queued, multi-session pieces. Row 12 is the floor: the irreducible part of wineserver that no honest design can remove.

The trajectories don't all move the same *amount* of state. Trajectory 2 (sync primitives) eliminates a wide class of wineserver round-trips at single-call granularity. Trajectory 4 (NtCreateFile) eliminates ~28,500 server round-trips on Ableton startup alone. Trajectory 9 (GetMessage), once it lands, removes the single hottest RPC in the entire Win32 message-pump path. Each row is sized differently, but each one moves a coherent class of state, with a coherent fallback story when the bypass can't apply.

---

## 4. Trajectory profiles

Each section is a brief profile: what state is being moved, what shape the bypass takes, current status, and where it sits in the larger picture.

### 4.1 File I/O via io_uring (Phase 1)

Move target: regular-file read/write/sync system calls issued by `NtReadFile`, `NtWriteFile`, `NtFlushBuffersFile`, `NtSetInformationFile` (truncate/rename/delete), and friends. Vanilla Wine routes these through the wineserver-side `read_request_shm` plus a synchronous `pread`/`pwrite` syscall, all under `global_lock`. With io_uring Phase 1 enabled, the unix-side ntdll thread submits the syscall directly to the kernel's `io_uring` ring and reaps the completion locally, never visiting the server.

Status: shipped, default-on. Independently valuable because most data-plane file I/O is regular-file traffic, and the server is no longer the bottleneck for it. Composes with trajectory 4 (NtCreateFile bypass) -- once the local_file stub gives the client the unix fd directly, the io_uring fast path uses it without ever round-tripping for the open either.

Long-arc role: every byte of file I/O through Wine eventually goes through io_uring or its phase-2/3 successor. The `read_request_shm` line-item in wineserver perf (~2-3% in steady-state Ableton) drops accordingly.

### 4.2 Synchronization primitives via direct NTSync

Move target: `NtWaitForSingleObject`, `NtWaitForMultipleObjects`, `NtReleaseMutant`, `NtSetEvent`, `NtReleaseSemaphore`, and the rest of the Win32 sync object family. Vanilla Wine round-trips to the server for every wait and every signal -- the server is the canonical place where sync object state lives, and it's the only place a cross-process `\BaseNamedObjects\Foo` can be looked up.

NSPA's NTSync driver (in-tree as `ntsync-patches/`) is a Linux kernel driver that implements NT sync object semantics natively. NSPA's userspace path issues ioctls directly to `/dev/ntsync` for the create / wait / signal operations. The wineserver still maintains the registration table that maps Win32 handles to NTSync objects (so cross-process named-object lookup still works), but it's no longer in the data path of any wait or signal.

Status: shipped, default-on. The kernel driver also implements priority inheritance natively, which is a strict superset of what wineserver could provide -- the server has no kernel-level PI tools to begin with.

Long-arc role: this trajectory is the one that gives NSPA its hard-RT character. Without native PI on sync objects, `RTL_CRITICAL_SECTION` PI (see `cs-pi.gen.html`) and Win32 condvar PI (see `condvar-pi-requeue.gen.html`) have nothing to compose with -- you'd have one PI-clean primitive in a sea of priority-inverting ones. With NTSync, the entire NT sync surface is PI-aware end-to-end.

### 4.3 Hook chains (Tier 1+2 cache)

Move target: WH_KEYBOARD / WH_MOUSE / WH_GETMESSAGE / WH_CALLWNDPROC and other thread-local Win32 hook chains. Vanilla Wine asks the server for the full hook chain on every dispatch (via `get_hook_info`), even when the chain is known to be empty or unchanged. On a busy UI tick this is one server round-trip per hook *type* per `GetMessage` iteration.

NSPA caches the chain in a per-process shmem region (Tier 1 = "is there any hook of type X at all?", Tier 2 = "here's the full list"). The server publishes invalidations on chain mutation (install / remove / process-attach). Hot-path lookups become `if (cache_says_empty) return early` and never touch the wire.

Status: shipped 2026-04-25, default-on. Validated under Ableton: ~26,700 / 26,700 hook lookups serviced from cache, server-side `get_hook_info` dropped to 0 in the steady-state 165s capture. (See `project_shmem_shape_a_rollback.md` and the architecture doc.)

Long-arc role: hooks were a death-by-a-thousand-cuts contributor to wineserver dispatch volume. Drained, now they cost the server nothing on the hot path.

### 4.4 NtCreateFile via local_file stub

Move target: read-only regular-file `NtCreateFile` calls. Vanilla Wine sends every open through the server, which arbitrates sharing (`FILE_SHARE_*`), allocates a `struct file` and tracks the inode, and returns a handle that the server owns. Every subsequent I/O on that handle is another round-trip to retrieve the unix fd.

NSPA's `local_file` bypass services eligible opens entirely client-side: `stat()` + per-process inode-table lookup + `open()` + return a handle in a private high range. Sharing arbitration is preserved by a server-published `(dev, inode) -> sharing-state` shmem region that every client reads under a PI mutex. When an API genuinely needs a server-visible handle (`NtQueryInformationFile`, `NtDuplicateObject`, `NtCreateSection`), the bypass lazily promotes the local handle on demand.

Status: shipped, default-on. Reference workload (Ableton 12 Lite startup) does ~28,500 file opens; with the bypass, almost all of them are serviced without ever touching the server. The remainder fall back transparently.

Long-arc role: this is a textbook strangler. The server still implements the full create_file path; the bypass just outpaces it on the common case. Composes with io_uring Phase 1 (4.1) -- the unix fd held by the local_file table is the same fd the io_uring path operates on. Composes with trajectory 11 (sechost / Phase 2/3 io_uring) for completion-port and async I/O extensions.

### 4.5 NtSetTimer / WM_TIMER via local timer dispatchers

Move target: `NtSetTimer` (and the `SetTimer` / `WM_TIMER` Win32 paths that route through it). Vanilla Wine arms a server-side timer; the server's main loop computes `get_next_timeout()` on every iteration and processes expirations in the poll loop.

NSPA's nt-local stubs (see `nt-local-stubs.gen.html`) implement timer arming and dispatching client-side. A per-thread local timer dispatcher manages expirations using `clock_nanosleep` / `timerfd`; expiring timers post `WM_TIMER` directly into the local message queue, which composes with msg-ring v1 (4.6).

Status: shipped, default-on. Removes the timer-driven wakeups from the server's `get_next_timeout` path -- 2-3% of wineserver CPU in steady-state, structurally it conflated time-driven with event-driven dispatch in a single `poll()`. After this bypass, the server's poll only wakes for fd readiness.

Long-arc role: precondition for trajectory-class moves further down the stack. The `wineserver-decomposition-plan.md` Phase 3 timer-thread split is *easier* once timer state has already migrated client-side -- there's less left to put in a dedicated timer thread, and what remains is at least bounded.

### 4.6 PostMessage / SendMessage via msg-ring v1

Move target: cross-thread same-process Win32 message posts. Vanilla Wine routes both `PostMessage` and `SendMessage` through the server, even when sender and receiver are in the same process. The server demultiplexes to the receiver's queue and signals it.

NSPA's msg-ring v1 maintains a per-thread shmem ring for incoming messages. Same-process cross-thread `PostMessage` writes directly into the receiver's ring and signals it via NTSync event. The server is bypassed entirely on the common case (same-process). Cross-process post still goes through the server because that's where cross-process queue identity lives.

Status: shipped, default-on. Foundation for the v2 work that's now in flight (4.7-4.9).

Long-arc role: without v1 in place, v2 has nothing to extend. v1 proved the per-thread ring shape works under realistic Win32 message-pump load; v2 broadens it to cover the receive side and the high-volume paint-flag traffic.

### 4.7 Paint cache fastpath (msg-ring v2 B1.0)

Move target: paint-flag query traffic from `nspa_get_update_flags_try_fastpath`. Vanilla Wine asks the server "does this window have paint pending?" on every UI tick of every visible window. With v2 B1.0, the server caches the answer in a per-window shmem flag; the client reads the flag locally; only on transitions does the server get involved.

Status: shipped, **default-off** (`NSPA_ENABLE_PAINT_CACHE=1` to opt in). Default-off because the original 2026-04-26 default-on flip exposed an unrelated host lockup at the 5-min mark in Ableton. The lockup turned out to be a kernel-side ntsync RT-allocation bug (`project_ntsync_kfree_under_raw_spinlock.md`), not B1.0's logic. Fixed in `ntsync-patches/1006`. Subsequent Ableton runs (run-3, run-4 on 2026-04-28) cleared the threshold cleanly with paint-cache=1, suggesting B1.0 is fine and the default flip is unblocked. One more long-soak validation run is wanted before flipping.

Long-arc role: B1.0 is one of two msg-ring v2 sender-side changes (the other is 4.8). Together with the receive-side Phase C (4.9), they take window-message traffic out of the server entirely on the common case.

### 4.8 redraw_window push ring (msg-ring v2 Phase A)

Move target: `RedrawWindow` and `InvalidateRect` style invalidation flows. The mark-dirty operation used to traverse the server. With Phase A, the client pushes invalidations into a shmem ring that the server drains lazily.

Status: shipped, default-on. Smaller scope than B1.0 (4.7) -- this is the sender-side push, not the receiver-side query. Validated separately and was clean from the start.

Long-arc role: paired with 4.7 and 4.9 in the v2 family. After all three are default-on, the canonical paint cycle (invalidate -> dirty-flag set -> next pump iteration sees flag -> WM_PAINT delivered) happens entirely in shmem. The server only sees mutations.

### 4.9 GetMessage bypass (msg-ring v2 Phase C)

Move target: `GetMessage` / `PeekMessage` -- the receive side of the message pump. Today, even with v1 sending into a local ring, the receive call still does a `wineserver` RPC to drain. Phase C bypasses that: the pump pulls directly from the per-thread ring, falling back to the server only when the ring is empty *and* wake-bits indicate something legacy is pending.

Status: paused mid-development. Design notes in `wine/nspa/docs/msg-ring-v2-phase-bc-handoff.md`. The pause was originally driven by the same ntsync host-lockup that paused B1.0 -- with that resolved (`project_ntsync_kfree_under_raw_spinlock.md`, then 1007-1011 follow-ups, then 4 kernel fixes shipped 2026-04-27), Phase C is the natural next bypass to land.

Long-arc role: this is the headline RPC. `GetMessage` is called on every UI tick of every Win32 message pump everywhere. Bypassing it is the single biggest reduction in wineserver dependence available short of the full decomposition. After C lands, the v2 family is complete and the entire common-case window-message path is server-free: invalidate via 4.8, paint-flag via 4.7, deliver via msg-ring, drain via Phase C.

### 4.10 Sechost device-IRP poll

Move target: `wine_sechost_service`'s ~530/s device-IRP poll. The sechost service polls a Win32 device handle for incoming IRPs and demultiplexes them to subscribers. Each poll is a server round-trip (`get_next_device_request`); over a 60-second Ableton run, ~63,000 of these add up to a measurable chunk of wineserver wall-clock.

Status: not yet shipped. Audit `Q2` in `project_nspa_bypass_audit.md` (payload-distribution at receive points) is the gating step -- before designing a bypass, we want to know what fraction of the 530/s polls actually return an IRP vs. wake spuriously, and what the IRP-payload distribution looks like for the ones that do. Instrumentation for this is now safe to add post-1006.

Long-arc role: independent trajectory, similar shape to msg-ring v2 (server publishes events into a ring, client drains locally). After this lands, `wine_sechost_service` is no longer a steady-state contributor to wineserver wakeups.

### 4.11 Socket/pipe I/O via io_uring (Phase 2/3)

Move target: socket I/O, pipe I/O, named-pipe IPC, and IOCP completion ports. These all currently route through the server-mediated async path. io_uring has the kernel primitives (`IORING_OP_READ`/`OP_WRITE` against socket fds, `IORING_OP_POLL_ADD` for readiness) to handle most of this client-side, mirroring what Phase 1 did for regular files.

Status: not yet shipped. Multi-session piece. Phase 2 = sockets and pipes, Phase 3 = IOCP integration.

Long-arc role: completes the io_uring move-out. After Phase 1+2+3, the `read_request_shm` and async I/O machinery on the server side are reduced to setup-time only -- no ongoing per-byte traffic. Composes with trajectory 4 (local_file) for any unix fd shared between paths, and with named-event sync (trajectory 2) for cross-process notification on completion.

### 4.12 Wineserver process+thread lifecycle

Cannot be bypassed. Process create/exit and thread create/exit are NT semantics that require a single source of truth -- which fork created which Wine process, what's the parent-child Win32 PID relationship, when does the last thread of a process leaving trigger process exit. Wineserver IS that source of truth, and the integration with Linux `fork`/`execve` happens through wineserver's child-tracking machinery.

This is the architectural floor. Every other trajectory in this doc moves state out *of* wineserver; this one stays in. The endgame wineserver still runs lifecycle, plus a small set of cross-process metadata services (see §5).

---

## 5. What MUST stay in wineserver

Honest list. These are the things that have no realistic home outside the server and are not on any trajectory:

- **Cross-process object naming.** `\BaseNamedObjects\Foo` works across Wine processes. Someone has to be the registry. Wineserver is.
- **Process / thread lifecycle.** As above (§4.12). Process create/exit, thread create/exit, parent-child relationships, NT semantics for `WaitForSingleObject(processHandle)` returning when the child dies.
- **Handle table coordination across handle inheritance.** `DuplicateHandle`, `CreateProcess` with `bInheritHandles=TRUE`, etc. The handle inheritance set has to be coordinated server-side at process creation.
- **Cross-process synchronisation primitive registration.** The kernel side moved to NTSync (4.2), but the wineserver-side mapping table remains -- it's the source of truth for "what Win32 handle in this process maps to which NTSync kernel object". Without this, named-object cross-process sharing breaks.
- **NT-specific path resolution.** `\??\` paths, NT object directory hierarchy, some reparse-point semantics, 8.3-name handling, case-insensitive on case-sensitive FS. Linux primitives don't model these natively.

These are *small* relative to what can move. Compare the size of "registration tables for cross-process named objects + lifecycle bookkeeping + path-resolution helpers" with the surface that's already gone or about to go (file I/O, sync primitives, hooks, message queues, paint, timers, sockets, sechost IRPs). The endgame wineserver is a metadata service. It still exists -- we never claimed otherwise -- but it stops being on the hot path of any normal application's main loop.

---

## 6. Composition: how the trajectories compose toward decomposition

The trajectories aren't independent point-optimizations. They compose, and each one shipped earns the right to land subsequent decomposition steps cheaply.

**Composition #1: io_uring + local_file.** Once trajectory 4 hands the unix fd directly to the client (no server-issued handle), io_uring (trajectory 1) operates on that fd without ever consulting the server. No round-trip on the open, no round-trip on the read, no round-trip on the close. Two trajectories shipped independently produce a third combined fast-path with zero additional code.

**Composition #2: NTSync + every other bypass that needs to wake threads.** Trajectory 2 doesn't just remove sync-object round-trips; it provides the wake primitive for every subsequent ring-based bypass. msg-ring v1 (4.6) signals via NTSync events. Phase A (4.8), B1.0 (4.7), Phase C (4.9), and a hypothetical Sechost ring (4.10) all do too. A bypass that delivers data via shmem still needs *something* to wake the receiver; NTSync is that something. (Without NTSync, the wake itself would round-trip through the server, and the bypass wouldn't actually bypass anything in the latency-sensitive case.)

**Composition #3: hook cache + msg-ring + nt-local timers.** The `GetMessage` fast path (the receive side of trajectory 9) needs to also satisfy hook lookups (4.3) and timer expirations (4.5). In vanilla Wine, every UI tick checks all three -- hooks, timers, queue -- via the server. With trajectories 3, 5, and 6/9 shipped, all three checks are local: hook cache is local, timer dispatcher is local, message ring is local. The compose form is "the entire body of `GetMessage` runs without touching the server in the common case."

**Composition #4: shrunk surface unblocks Phase 3 splits.** The `wineserver-decomposition-plan.md` proposes splits of the wineserver process itself (timer thread, FD poll thread, router/handler split, lock partitioning). Each split is *easier* to land once trajectories have already pruned the relevant subsystem to its minimum viable footprint. Timer-thread split is trivial when most timer state has already migrated client-side via 4.5. FD poll thread split is trivial when most file I/O has migrated via 4.1 and 4.11. Lock partitioning becomes feasible only after enough handlers have left the server that the remaining lock-holders are auditable as a small set.

**The decomposition becomes mechanical.** Once the bypasses ship, decomposition stops looking like "rewrite the architecture" and starts looking like "fold the remaining handlers into nt-local stubs and turn off the wineserver process for normal apps." The Phase 3 splits (timer thread, aggregate-wait, FD poll thread) become feasible. Phase 4 (router/handler split, lock partitioning) becomes the natural endgame.

The user previously stalled on the decomposition because trying to land it directly was premature -- every bypass shipped *first* is one less handler the decomposition has to re-implement, one less subsystem the lock-partitioning audit has to cover, one less data-path the timer-thread split has to keep correct. The bypass-first sequencing isn't an alternative to decomposition; it's the precondition that makes decomposition cheap.

**Composition #5: bypasses fund their own kernel work.** Trajectory 2 (NTSync) is the most striking case -- the kernel driver wasn't just dropped in; it was incrementally hardened across five major patch series (1003 PI, 1005 thread-token, 1006 RT-alloc-hoist, 1007-1011 channel safety, the four 2026-04-27 fixes). Each round of bypass shipping surfaced new RT-correctness requirements on the driver, which got fixed, which earned the next round of shipping. The kernel side and the userspace bypasses co-evolved: validation under real workload (Ableton, plugin scans, message storms) revealed kernel-side issues that bench microbenchmarks would never have hit. None of those fixes were predictable in advance -- they came from running the bypasses against real apps, which is the same reason a green-field wineserver rewrite would have shipped with whichever subset of those bugs the rewriter happened to think to test for.

The composition-flavoured picture: bypasses don't just substitute for decomposition. They co-design with the kernel, with NT-local stubs, with shmem layout choices, with PI plumbing. Each bypass shipped is a forcing function on the layers below it, and the layers below it are now (post-2026-04-28) genuinely solid in a way they weren't before any bypass had pressure-tested them.

---

## 7. State of the trajectory map (2026-04-28)

Roughly halfway through the bypass tier:

- **7 of ~10 trajectories shipped default-on** (rows 1-6 + 8 in §3). These are the foundations -- file I/O, sync, hooks, NtCreateFile, timers, msg-ring v1 send, redraw_window push.
- **Paint-cache (B1.0) shipped, validating.** Today's two clean Ableton runs (run-3 default-config, run-4 with `NSPA_ENABLE_PAINT_CACHE=1` exercising the historical 5-min lockup window) are a strong signal. One more long-soak validation run wanted before the default flip.
- **Phase C (`get_message`) is the next single-piece bypass to resume.** Paused mid-development; design notes are in tree; both prerequisites that originally blocked it (host lockup, in-handler instrumentation rule) are resolved. Once C lands, the v2 message-ring family is complete.
- **io_uring 2/3 + sechost are pending multi-session pieces.** Independent trajectories, similar shape to existing bypasses. Each is one design pass plus one implementation push.
- **Phase 3 splits start after enough state migrates out.** Once C, sechost, and io_uring 2/3 ship, the wineserver-decomposition-plan Phase 3 (timer thread + aggregate-wait + FD poll thread) becomes the natural next focus -- not before. There's no point splitting the timer thread when timer state is still server-resident; the split has to follow the state migration, not lead it.

Concretely, the trajectory map (in the order most likely to land):

    [shipped, default-on]    1, 2, 3, 4, 5, 6, 8
    [validating]             7  (paint-cache; 1 more run before default flip)
    [paused, resume next]    9  (GetMessage / Phase C)
    [queued]                 10 (sechost), 11 (io_uring 2/3)
    [post-bypass, Phase 3]   wineserver-decomposition splits
    [floor]                  12 (lifecycle stays)

---

## 8. Connection to recent work

The 2026-04-26 -> 2026-04-28 investigation arc looks, on the surface, like a detour from feature work. It wasn't.

Sequence of events:

1. 2026-04-26: paint-cache (4.7) flipped default-on. Ableton ran clean for ~5 minutes, then host-locked under paint-storm conditions.
2. Investigation found the lockup was inside `ntsync.ko` -- not in the paint-cache logic. Specifically, six PREEMPT_RT-illegal slab alloc/free sites under `raw_spinlock_t` that had been latent in the 1003 PI patch and the 1005 thread-token patch. Shipped as `1006-ntsync-rt-alloc-hoist.patch`.
3. Subsequent investigation surfaced more ntsync issues over 2026-04-27 -- channel-recv hang, channel REPLY UAF, EVENT_SET_PI deferred-boost, channel_entry refcount UAF. Four kernel patches shipped (1007 + 1008 + 1009 + cleanup), validated under a debug kernel with KASAN, then re-validated on the production kernel.
4. 2026-04-28: focused 1576-LOC walk of `dlls/win32u/nspa/msg_ring.c` found three pre-existing wine-userspace bugs of the silent-contract-violation class: MR1 (reply-slot ABA), MR2 (FUTEX_PRIVATE on MAP_SHARED memfd), MR4 (POST dual-signal-fail wake-loss). All three shipped to `nspa-rt`.
5. Two clean Ableton runs to close out the day: paint-cache off baseline (run-3) and paint-cache on under the historical 5-min lockup config (run-4).

What that arc looks like out of context: a giant detour from shipping Phase C. What it actually is: every remaining bypass on the trajectory map (Phase C, sechost, io_uring 2/3) calls into the same RT-sync path that had the bugs. The bugs were going to surface regardless -- the question was only whether they'd be attributed to the RT-sync layer (where they live and where they were eventually fixed) or to whichever bypass happened to be shipping the day they fired.

Better paid now on a contained surface (with KASAN-debug kernel, isolated reproduction, ~370M ops of validation) than mid-Phase-C with two failure surfaces overlapping.

The infrastructure is now solid. The trajectory map can resume.

---

## 9. Trajectory map diagram

Vertical bars: relative wineserver footprint over time, as bypasses ship. Each bar shows what's still in the server. The trajectory above the bar is the move that drops the next slab of state out.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 560" xmlns="http://www.w3.org/2000/svg">
  <style>
    .bg { fill: #1a1b26; }
    .axis { stroke: #3b4261; stroke-width: 1; }
    .tick { stroke: #3b4261; stroke-width: 1; stroke-dasharray: 2,3; }
    .bar-shipped { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.5; }
    .bar-current { fill: #2a2438; stroke: #e0af68; stroke-width: 2; }
    .bar-future  { fill: #1f2535; stroke: #565f89; stroke-width: 1; stroke-dasharray: 4,3; }
    .bar-floor   { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; }
    .label       { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .label-sm    { fill: #c0caf5; font-size: 9px;  font-family: 'JetBrains Mono', monospace; }
    .label-blue  { fill: #7aa2f7; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-yel   { fill: #e0af68; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-grn   { fill: #9ece6a; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-mut   { fill: #565f89; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .label-cyan  { fill: #7dcfff; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .label-pur   { fill: #bb9af7; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .arrow       { stroke: #7dcfff; stroke-width: 1.5; fill: none; }
    .title       { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
  </style>

  <rect x="0" y="0" width="940" height="560" class="bg"/>
  <text x="470" y="26" text-anchor="middle" class="title">Wineserver footprint shrinking as bypasses ship</text>

  <!-- y-axis -->
  <line x1="80" y1="60" x2="80" y2="500" class="axis"/>
  <text x="40" y="65"  class="label-mut">100%</text>
  <text x="40" y="170" class="label-mut">75%</text>
  <text x="40" y="280" class="label-mut">50%</text>
  <text x="40" y="390" class="label-mut">25%</text>
  <text x="40" y="500" class="label-mut">floor</text>

  <line x1="80" y1="60"  x2="900" y2="60"  class="tick"/>
  <line x1="80" y1="170" x2="900" y2="170" class="tick"/>
  <line x1="80" y1="280" x2="900" y2="280" class="tick"/>
  <line x1="80" y1="390" x2="900" y2="390" class="tick"/>
  <line x1="80" y1="500" x2="900" y2="500" class="tick"/>

  <!-- x-axis baseline -->
  <line x1="80" y1="500" x2="900" y2="500" class="axis"/>

  <!-- Stage 1: Vanilla Wine (everything in server) -->
  <rect x="100" y="60" width="80" height="440" class="bar-shipped" opacity="0.4"/>
  <text x="140" y="520" text-anchor="middle" class="label-blue">Vanilla</text>
  <text x="140" y="535" text-anchor="middle" class="label-mut">baseline</text>

  <!-- Stage 2: + io_uring 1 + NTSync + hooks -->
  <rect x="200" y="170" width="80" height="330" class="bar-shipped"/>
  <text x="240" y="520" text-anchor="middle" class="label-blue">+ 1, 2, 3</text>
  <text x="240" y="535" text-anchor="middle" class="label-mut">io_uring1 + ntsync + hooks</text>
  <text x="240" y="160" text-anchor="middle" class="label-cyan">file I/O + sync + hooks out</text>

  <!-- Stage 3: + local_file + timers + msg-ring v1 -->
  <rect x="300" y="240" width="80" height="260" class="bar-shipped"/>
  <text x="340" y="520" text-anchor="middle" class="label-blue">+ 4, 5, 6</text>
  <text x="340" y="535" text-anchor="middle" class="label-mut">local_file + timers + v1</text>
  <text x="340" y="230" text-anchor="middle" class="label-cyan">28.5k/start opens out</text>

  <!-- Stage 4: + redraw push + paint-cache (current; shipped + validating) -->
  <rect x="400" y="290" width="80" height="210" class="bar-current"/>
  <text x="440" y="520" text-anchor="middle" class="label-yel">+ 7, 8</text>
  <text x="440" y="535" text-anchor="middle" class="label-mut">paint-cache + redraw push</text>
  <text x="440" y="280" text-anchor="middle" class="label-yel">CURRENT (validating)</text>

  <!-- Stage 5: + Phase C get_message (paused, queued) -->
  <rect x="500" y="340" width="80" height="160" class="bar-future"/>
  <text x="540" y="520" text-anchor="middle" class="label-pur">+ 9</text>
  <text x="540" y="535" text-anchor="middle" class="label-mut">GetMessage bypass</text>
  <text x="540" y="330" text-anchor="middle" class="label-pur">paused, resume next</text>

  <!-- Stage 6: + sechost + io_uring 2/3 -->
  <rect x="600" y="400" width="80" height="100" class="bar-future"/>
  <text x="640" y="520" text-anchor="middle" class="label-pur">+ 10, 11</text>
  <text x="640" y="535" text-anchor="middle" class="label-mut">sechost + io_uring 2/3</text>
  <text x="640" y="390" text-anchor="middle" class="label-pur">queued</text>

  <!-- Stage 7: + Phase 3 splits (decomposition) -->
  <rect x="700" y="450" width="80" height="50" class="bar-future"/>
  <text x="740" y="520" text-anchor="middle" class="label-pur">+ Phase 3</text>
  <text x="740" y="535" text-anchor="middle" class="label-mut">timer + agg-wait + fd-thr</text>
  <text x="740" y="440" text-anchor="middle" class="label-pur">post-bypass</text>

  <!-- Stage 8: floor -->
  <rect x="800" y="490" width="80" height="10" class="bar-floor"/>
  <text x="840" y="520" text-anchor="middle" class="label-grn">floor</text>
  <text x="840" y="535" text-anchor="middle" class="label-mut">lifecycle + naming</text>
  <text x="840" y="480" text-anchor="middle" class="label-grn">cannot bypass</text>

  <!-- arrow above stages indicating progression -->
  <line x1="140" y1="46" x2="840" y2="46" class="arrow"/>
  <text x="490" y="42" text-anchor="middle" class="label-mut">time / trajectory progression</text>
</svg>
</div>

The bar at "Vanilla" is everything in the server. Each subsequent bar drops a slab as the trajectories above it ship. The yellow bar ("CURRENT") is roughly where NSPA stands today: trajectories 1-6 + 8 shipped default-on, B1.0 (7) shipped and validating. The purple bars ahead are paused / queued. The green bar at the bottom is the floor: lifecycle + cross-process naming, irreducible.

The visual point: by the time the purple bars are filled in (Phase C, sechost, io_uring 2/3), wineserver is doing very little on the hot path of any normal application. Phase 3 of the decomposition plan -- timer thread split, aggregate-wait, FD poll thread split -- is the natural follow-up, and it's a much smaller piece of work once the trajectories have already pruned the surface.

---

## Cross-references

- `wineserver-decomposition-plan.md` (in-tree at `wine/nspa/docs/`) -- the long-arc plan whose Phase 3 / Phase 4 splits this doc enables.
- `nt-local-stubs.gen.html` -- the architectural pattern for moving NT-API state into client-resident stubs. Trajectories 5, 6, 7, 8, 9 all instantiate this pattern.
- `io_uring-architecture.gen.html` -- trajectory 1 + 11.
- `ntsync-driver.gen.html` -- trajectory 2.
- `hook-cache.gen.html` -- trajectory 3.
- `nspa-local-file-architecture.gen.html` -- trajectory 4.
- `msg-ring-architecture.gen.html` -- trajectories 6, 7, 8, 9.
- `cs-pi.gen.html`, `condvar-pi-requeue.gen.html` -- the CS-PI and condvar-PI work that trajectory 2 (NTSync) provides the kernel substrate for.
- `architecture.gen.html` -- the integrated architecture overview, of which this doc is the strangler-pattern lens.
