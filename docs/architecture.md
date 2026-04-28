# Wine-NSPA -- Architecture Overview

Wine 11.6 + NSPA RT patchset | Kernel 6.19.x-rt with NTSync PI | 2026-04-28
Author: Jordan Johnston

## Table of Contents

1. [What Wine-NSPA is](#1-what-wine-nspa-is)
2. [Layered architecture](#2-layered-architecture)
3. [Subsystem map](#3-subsystem-map)
    - 3.1 [Synchronization and priority inheritance](#31-synchronization-and-priority-inheritance)
    - 3.2 [Wineserver IPC](#32-wineserver-ipc)
    - 3.3 [NT-local stubs](#33-nt-local-stubs)
    - 3.4 [Message dispatch](#34-message-dispatch)
    - 3.5 [Hook chains](#35-hook-chains)
    - 3.6 [File I/O](#36-file-io)
    - 3.7 [Audio](#37-audio)
4. [Bypass topology](#4-bypass-topology)
5. [Wineserver residual design](#5-wineserver-residual-design)
6. [RT priority mapping](#6-rt-priority-mapping)
7. [Status reference](#7-status-reference)
8. [Document index](#8-document-index)

---

## 1. What Wine-NSPA is

Wine-NSPA is a PREEMPT_RT-tuned fork of Wine 11.x. It targets `PREEMPT_RT_FULL` Linux kernels, grafts kernel-level priority inheritance onto every Win32 sync primitive, replaces Wine's single-threaded wineserver event loop in the hot path with kernel-mediated channels and bounded shmem rings, and ships a custom `ntsync` kernel module that gives `/dev/ntsync` Windows-faithful priority semantics with PI boost.

Scope covers latency-sensitive and correctness-sensitive Wine surfaces on PREEMPT_RT: synchronization, wineserver IPC, UI dispatch, startup and steady-state file I/O, hook dispatch, timer delivery, and audio callback paths. Audio workloads are part of the validation matrix, but the architecture is not audio-specific.

NSPA is not an acronym. The current 11.x line is a reimplementation of earlier Wine 8.x and 10.x RT branches, updated to use NTSync (introduced upstream in Wine 9.x and Linux 6.10) instead of the older shmem-dispatcher-based design.

The whole project is a small Linux kernel module (~3 kLOC of `ntsync.{c,h}` deltas on top of upstream) plus a Wine fork that increasingly bypasses wineserver through bounded shmem rings, all gated behind a single env var (`NSPA_RT_PRIO`). When `NSPA_RT_PRIO` is unset, every NSPA code path short-circuits to upstream Wine and behaviour is byte-identical. There is no zero-config tax for users who don't opt in.

---

## 2. Layered architecture

The architecture has three layers: a kernel layer (NTSync, io_uring, librtpi-style PI futexes, RT scheduler), a wineserver layer (gamma channel dispatcher + main loop + handler tables), and a client layer (ntdll, win32u, NT-local stubs, audio drivers, application/PE code). Most NSPA bypasses route around the wineserver layer entirely on the common case, falling back only when the bypass envelope is exceeded.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 620" xmlns="http://www.w3.org/2000/svg">
  <style>
    .bg       { fill: #1a1b26; }
    .layer    { fill: #1f2535; stroke: #3b4261; stroke-width: 1; }
    .layer-k  { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.5; }
    .layer-s  { fill: #2a1f35; stroke: #bb9af7; stroke-width: 1.5; }
    .layer-c  { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.5; }
    .box      { fill: #24283b; stroke: #3b4261; stroke-width: 1; }
    .box-hot  { fill: #2a2438; stroke: #e0af68; stroke-width: 1.5; }
    .box-cold { fill: #1f2535; stroke: #565f89; stroke-width: 1; stroke-dasharray: 4,3; }
    .lbl      { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .lbl-sm   { fill: #c0caf5; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .lbl-mut  { fill: #8c92b3; font-size: 9px;  font-family: 'JetBrains Mono', monospace; }
    .lbl-blu  { fill: #7aa2f7; font-size: 12px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .lbl-pur  { fill: #bb9af7; font-size: 12px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .lbl-grn  { fill: #9ece6a; font-size: 12px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .lbl-yel  { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .lbl-cy   { fill: #7dcfff; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .ln       { stroke: #7dcfff; stroke-width: 1.5; fill: none; }
    .ln-by    { stroke: #e0af68; stroke-width: 1.5; stroke-dasharray: 5,3; fill: none; }
    .title    { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
  </style>

  <rect x="0" y="0" width="980" height="620" class="bg"/>
  <text x="490" y="26" text-anchor="middle" class="title">Wine-NSPA layered architecture (with bypass routes)</text>

  <!-- Client layer -->
  <rect x="20" y="60" width="940" height="140" class="layer-c"/>
  <text x="40" y="80" class="lbl-grn">CLIENT (PE process)</text>
  <text x="40" y="94" class="lbl-mut">application code, ntdll, win32u, drivers</text>

  <rect x="40"  y="105" width="120" height="40" class="box"/>
  <text x="100" y="123" text-anchor="middle" class="lbl-sm">application code</text>
  <text x="100" y="137" text-anchor="middle" class="lbl-mut">PE side</text>

  <rect x="170" y="105" width="120" height="40" class="box"/>
  <text x="230" y="123" text-anchor="middle" class="lbl-sm">ntdll</text>
  <text x="230" y="137" text-anchor="middle" class="lbl-mut">PE + unix</text>

  <rect x="300" y="105" width="120" height="40" class="box"/>
  <text x="360" y="123" text-anchor="middle" class="lbl-sm">win32u + nspa</text>
  <text x="360" y="137" text-anchor="middle" class="lbl-mut">message ring v1+v2</text>

  <rect x="430" y="105" width="180" height="40" class="box-hot"/>
  <text x="520" y="123" text-anchor="middle" class="lbl-yel">NT-local stubs</text>
  <text x="520" y="137" text-anchor="middle" class="lbl-mut">file / timer / wm_timer / sync</text>

  <rect x="620" y="105" width="120" height="40" class="box"/>
  <text x="680" y="123" text-anchor="middle" class="lbl-sm">winejack.drv</text>
  <text x="680" y="137" text-anchor="middle" class="lbl-mut">audio + MIDI</text>

  <rect x="750" y="105" width="120" height="40" class="box"/>
  <text x="810" y="123" text-anchor="middle" class="lbl-sm">nspaASIO</text>
  <text x="810" y="137" text-anchor="middle" class="lbl-mut">Phase F bridge</text>

  <rect x="40"  y="155" width="240" height="35" class="box"/>
  <text x="160" y="172" text-anchor="middle" class="lbl-sm">CS-PI v2.3 (RTL_CRITICAL_SECTION)</text>
  <text x="160" y="184" text-anchor="middle" class="lbl-mut">FUTEX_LOCK_PI on LockSemaphore</text>

  <rect x="290" y="155" width="240" height="35" class="box"/>
  <text x="410" y="172" text-anchor="middle" class="lbl-sm">condvar PI requeue (SleepCondVarCS)</text>
  <text x="410" y="184" text-anchor="middle" class="lbl-mut">FUTEX_WAIT_REQUEUE_PI</text>

  <rect x="540" y="155" width="200" height="35" class="box"/>
  <text x="640" y="172" text-anchor="middle" class="lbl-sm">hook tier 1+2 cache</text>
  <text x="640" y="184" text-anchor="middle" class="lbl-mut">shmem, server publishes invalidations</text>

  <rect x="750" y="155" width="120" height="35" class="box"/>
  <text x="810" y="172" text-anchor="middle" class="lbl-sm">vDSO preloader</text>
  <text x="810" y="184" text-anchor="middle" class="lbl-mut">Jinoh Kang port</text>

  <!-- Wineserver layer -->
  <rect x="20" y="220" width="940" height="130" class="layer-s"/>
  <text x="40" y="240" class="lbl-pur">WINESERVER (single-threaded supervisor)</text>
  <text x="40" y="254" class="lbl-mut">handle table, cross-process naming, lifecycle, NT path resolution</text>

  <rect x="40"  y="265" width="180" height="70" class="box-hot"/>
  <text x="130" y="283" text-anchor="middle" class="lbl-yel">gamma channel dispatcher</text>
  <text x="130" y="297" text-anchor="middle" class="lbl-mut">per-process kernel-mediated</text>
  <text x="130" y="311" text-anchor="middle" class="lbl-mut">request/reply via ntsync 1004</text>
  <text x="130" y="325" text-anchor="middle" class="lbl-cy">replaces legacy shmem dispatcher</text>

  <rect x="240" y="265" width="180" height="70" class="box"/>
  <text x="330" y="283" text-anchor="middle" class="lbl-sm">main_loop / poll() / epoll</text>
  <text x="330" y="297" text-anchor="middle" class="lbl-mut">global_lock (PI-aware)</text>
  <text x="330" y="311" text-anchor="middle" class="lbl-mut">FIFO at NSPA_RT_PRIO-16</text>
  <text x="330" y="325" text-anchor="middle" class="lbl-mut">openat lock-drop (Phase B)</text>

  <rect x="440" y="265" width="180" height="70" class="box"/>
  <text x="530" y="283" text-anchor="middle" class="lbl-sm">handler tables</text>
  <text x="530" y="297" text-anchor="middle" class="lbl-mut">req_handlers[]</text>
  <text x="530" y="311" text-anchor="middle" class="lbl-mut">file / proc / thread /</text>
  <text x="530" y="325" text-anchor="middle" class="lbl-mut">sync / hooks / queue</text>

  <rect x="640" y="265" width="180" height="70" class="box"/>
  <text x="730" y="283" text-anchor="middle" class="lbl-sm">cross-process state</text>
  <text x="730" y="297" text-anchor="middle" class="lbl-mut">handle table</text>
  <text x="730" y="311" text-anchor="middle" class="lbl-mut">named-object registry</text>
  <text x="730" y="325" text-anchor="middle" class="lbl-mut">lifecycle / fork tracking</text>

  <rect x="840" y="265" width="100" height="70" class="box-cold"/>
  <text x="890" y="290" text-anchor="middle" class="lbl-mut">decomposition</text>
  <text x="890" y="304" text-anchor="middle" class="lbl-mut">Phase 1-4</text>
  <text x="890" y="318" text-anchor="middle" class="lbl-mut">future</text>

  <!-- Kernel layer -->
  <rect x="20" y="370" width="940" height="190" class="layer-k"/>
  <text x="40" y="390" class="lbl-blu">KERNEL (PREEMPT_RT_FULL)</text>
  <text x="40" y="404" class="lbl-mut">6.19.11-rt1-1-nspa</text>

  <rect x="40"  y="415" width="200" height="120" class="box-hot"/>
  <text x="140" y="434" text-anchor="middle" class="lbl-yel">ntsync.ko</text>
  <text x="140" y="450" text-anchor="middle" class="lbl-mut">NT sync object driver</text>
  <text x="140" y="464" text-anchor="middle" class="lbl-cy">1003 priority inheritance</text>
  <text x="140" y="478" text-anchor="middle" class="lbl-cy">1004 channels (gamma)</text>
  <text x="140" y="492" text-anchor="middle" class="lbl-cy">1005 thread-token</text>
  <text x="140" y="506" text-anchor="middle" class="lbl-cy">1006 RT alloc-hoist</text>
  <text x="140" y="520" text-anchor="middle" class="lbl-cy">1007 channel exclusive recv</text>

  <rect x="260" y="415" width="200" height="120" class="box"/>
  <text x="360" y="434" text-anchor="middle" class="lbl-sm">PI futex layer</text>
  <text x="360" y="452" text-anchor="middle" class="lbl-mut">FUTEX_LOCK_PI</text>
  <text x="360" y="468" text-anchor="middle" class="lbl-mut">FUTEX_WAIT_REQUEUE_PI</text>
  <text x="360" y="484" text-anchor="middle" class="lbl-mut">FUTEX_CMP_REQUEUE_PI</text>
  <text x="360" y="502" text-anchor="middle" class="lbl-mut">rt_mutex chain (transitive)</text>
  <text x="360" y="518" text-anchor="middle" class="lbl-mut">vendored librtpi userspace</text>

  <rect x="480" y="415" width="200" height="120" class="box"/>
  <text x="580" y="434" text-anchor="middle" class="lbl-sm">io_uring</text>
  <text x="580" y="452" text-anchor="middle" class="lbl-mut">Phase 1: regular file I/O</text>
  <text x="580" y="468" text-anchor="middle" class="lbl-mut">SINGLE_ISSUER + COOP_TASKRUN</text>
  <text x="580" y="484" text-anchor="middle" class="lbl-mut">ALERTED-state interception</text>
  <text x="580" y="500" text-anchor="middle" class="lbl-mut">ntsync uring_fd extension</text>
  <text x="580" y="518" text-anchor="middle" class="lbl-cy">Phase 2/3 pending</text>

  <rect x="700" y="415" width="240" height="120" class="box"/>
  <text x="820" y="434" text-anchor="middle" class="lbl-sm">RT scheduler (PREEMPT_RT_FULL)</text>
  <text x="820" y="452" text-anchor="middle" class="lbl-mut">SCHED_FIFO 1..98</text>
  <text x="820" y="468" text-anchor="middle" class="lbl-mut">priority-ordered wakeup</text>
  <text x="820" y="484" text-anchor="middle" class="lbl-mut">rt_mutex PI propagation</text>
  <text x="820" y="500" text-anchor="middle" class="lbl-mut">raw_spinlock_t hardening</text>
  <text x="820" y="518" text-anchor="middle" class="lbl-mut">no kfree under raw spinlock</text>

  <text x="490" y="555" text-anchor="middle" class="lbl-mut">--- bypass routes (dashed orange) skip the wineserver layer entirely ---</text>

  <!-- Bypass routes: client -> kernel directly -->
  <line x1="520" y1="145" x2="140" y2="415" class="ln-by"/>
  <line x1="520" y1="145" x2="580" y2="415" class="ln-by"/>
  <line x1="160" y1="190" x2="360" y2="415" class="ln-by"/>
  <line x1="410" y1="190" x2="360" y2="415" class="ln-by"/>

  <!-- Wineserver routes: client -> server -->
  <line x1="360" y1="145" x2="130" y2="265" class="ln"/>
  <line x1="640" y1="190" x2="530" y2="265" class="ln"/>

  <!-- Server -> kernel -->
  <line x1="130" y1="335" x2="140" y2="415" class="ln"/>
  <line x1="330" y1="335" x2="360" y2="415" class="ln"/>

  <!-- Legend -->
  <line x1="40"  y1="585" x2="80"  y2="585" class="ln"/>
  <text x="90"  y="589" class="lbl-mut">canonical wineserver path</text>
  <line x1="280" y1="585" x2="320" y2="585" class="ln-by"/>
  <text x="330" y="589" class="lbl-mut">NSPA bypass route (skips wineserver)</text>
  <rect x="600" y="578" width="20" height="14" class="box-hot"/>
  <text x="630" y="589" class="lbl-mut">hot path / NSPA-introduced</text>
  <rect x="800" y="578" width="20" height="14" class="box-cold"/>
  <text x="830" y="589" class="lbl-mut">future / pending</text>
</svg>
</div>

The diagram defines the routing boundaries. Vanilla Wine routes these surfaces through wineserver, which serializes most handlers under `global_lock`. NSPA adds kernel-mediated and client-local bypasses that remove wineserver from the common path while preserving wineserver ownership of cross-process naming, lifecycle, and residual server-managed state.

---

## 3. Subsystem map

Each subsection here is a one-paragraph (sometimes two) sketch of the subsystem; the deep design is in a dedicated page linked at the end of each section.

### 3.1 Synchronization and priority inheritance

NSPA implements priority inheritance along four independent paths so that no Win32 sync surface is left as a priority-inversion source. CS-PI (Path A) repurposes `RTL_CRITICAL_SECTION::LockSemaphore` as a `FUTEX_LOCK_PI` futex word, giving every critical section the kernel's transitive PI chain semantics. NTSync direct (Path B) routes `NtWaitForSingleObject` and friends through `/dev/ntsync` ioctls, where the kernel module's 1003 patch implements priority-ordered waiter queues and per-task PI boost across mutex chains. Vendored librtpi (Path C) provides `pi_cond_wait` for unix-side condition variables built on `FUTEX_WAIT_REQUEUE_PI`. Win32 condvar PI (Path D) extends Path C up into the Win32 surface so `SleepConditionVariableCS` is also PI-clean.

The kernel side is where the heavy lifting happens. The `ntsync.ko` module sits at `/dev/ntsync` and implements NT sync object semantics natively in the kernel, with PI-aware mutexes, priority-ordered waiter queues, and a channel object (1004 patch) that serves as the gamma dispatcher's transport. The patch stack runs from 1003 (priority inheritance) through 1009 (channel_entry refcount UAF fix); the 2026-04-27 cycle hardened the driver against four discovered RT-correctness bugs and validated cleanly against ~370M ops with zero KASAN splats.

All four paths are gated on `NSPA_RT_PRIO`. When unset, every PI code path short-circuits and Wine behaves byte-for-byte like upstream. **Detail: see [ntsync-driver](ntsync-driver.gen.html), [cs-pi](cs-pi.gen.html), [condvar-pi-requeue](condvar-pi-requeue.gen.html).**

### 3.2 Wineserver IPC

The classical Wine IPC architecture has every client thread `read()`/`write()` over a unix socket pair to the wineserver process, which dispatches under `global_lock`. The earlier NSPA work (Torge Matthies's 2022 patch, forward-ported as the v1.5 line) replaced the socket round-trip with a per-thread shmem region and a futex signal, served by a pool of pthread dispatchers inside the server. That worked but had its own pile of correctness rough edges; it has been superseded by the **gamma channel dispatcher**.

The gamma dispatcher uses the ntsync 1004 channel object to deliver a per-process kernel-mediated request/reply queue. The client thread `ioctl(NTSYNC_CHANNEL_SEND, request)`; the wineserver dispatcher thread `ioctl(NTSYNC_CHANNEL_RECV)`s the request, runs the handler, and `ioctl(NTSYNC_CHANNEL_REPLY)`s the result. The channel object carries a 1005 thread-token so the kernel knows which client thread sent the request (used to drive 2026-era PI boost decisions on the dispatcher). T1+T2+T3 thread-token consumption is shipped default-on. The legacy shmem-IPC path (`shmem-ipc.gen.html`) is **historical and superseded** and retained as reference material only.

**Detail: see [gamma-channel-dispatcher](gamma-channel-dispatcher.gen.html). Historical: [shmem-ipc](shmem-ipc.gen.html) (superseded).**

### 3.3 NT-local stubs

The NT-local stubs pattern moves NT-API state from wineserver-resident storage into client-resident storage. The pattern: the client maintains its own state for a class of NT objects (timers, regular-file handles, WM_TIMER tuples), processes operations locally, and lazily promotes the state back to a server-visible handle only when an API genuinely needs server-side handle semantics (`DuplicateHandle`, `CreateProcess` inheritance, `NtCreateSection` from a file handle). The stub answers the common case in shmem; the server stays the authority for the long tail.

Three stubs are shipped: `nspa_local_file` (NT-local file for read-only regular files; eliminates ~28,500 server round-trips on Ableton 12 Lite startup), `nspa_local_timer` (NT timer object resolution at the client, removes timer wakeups from the wineserver `get_next_timeout` path), and `nspa_local_wm_timer` (`SetTimer`/`WM_TIMER` userspace path with `(window, id, msg)` tuple as built-in ABA discriminator).

**Detail: see [nt-local-stubs](nt-local-stubs.gen.html), [nspa-local-file-architecture](nspa-local-file-architecture.gen.html).**

### 3.4 Message dispatch

The Win32 message pump is the second-hottest source of wineserver round-trips (after `NtCreateFile`, which `nspa_local_file` already drains). A typical Win32 application calls `GetMessage` / `PeekMessage` on every UI tick; cross-thread `PostMessage` and `SendMessage` go through the server even when sender and receiver are in the same process; `RedrawWindow` and `InvalidateRect` push paint flags into the server.

NSPA's msg-ring v1 ships a per-thread bounded MPMC shmem ring for cross-thread same-process `PostMessage`/`SendMessage`/reply, signalled via NTSync events. Msg-ring v2 extends this with three further pieces: **Phase A** (a redraw-window push ring drained lazily by the server), **B1.0 paint cache** (a per-window shmem flag for `nspa_get_update_flags_try_fastpath`, gated default-off behind `NSPA_ENABLE_PAINT_CACHE=1` pending a second long-soak validation run), and **Phase C** (a `GetMessage` bypass that pulls directly from the per-thread ring; currently deferred).

Three pre-existing wine-userspace bugs in `dlls/win32u/nspa/msg_ring.c` were found and fixed in the 2026-04-27 audit (MR1 reply-slot ABA, MR2 `FUTEX_PRIVATE` on `MAP_SHARED` memfd, MR4 POST wake-loss on dual-signal-fail rollback), all of the silent-contract-violation class.

**Detail: see [msg-ring-architecture](msg-ring-architecture.gen.html).**

### 3.5 Hook chains

Win32 hook chains (`WH_KEYBOARD`, `WH_MOUSE`, `WH_GETMESSAGE`, `WH_CALLWNDPROC`, etc.) get queried on every dispatch in vanilla Wine, even when the chain is empty. On a busy UI tick that is one server round-trip per hook type per `GetMessage` iteration, which adds up: an Ableton 165s capture showed 26,700 hook lookups across the run.

NSPA caches the hook chain in a per-process shmem region (Tier 1 = "is there any hook of type X at all?"; Tier 2 = "here's the full list"). The wineserver publishes invalidations on chain mutation. Hot-path lookups become an O(1) shmem read. Steady-state validation: 26,700 / 26,700 cache hits, server-side `get_hook_info` dropped to 0.

**Detail: see [hook-cache](hook-cache.gen.html).**

### 3.6 File I/O

File I/O is two related stories. The **open path** is owned by `nspa_local_file` (see §3.3): regular-file `NtCreateFile` calls are serviced client-side via `stat() + open()`, with sharing arbitration preserved through a server-published `(dev, inode) -> sharing-state` shmem region. Only API surfaces that genuinely need a server-visible handle trigger lazy promotion.

The **data-plane path** is owned by io_uring Phase 1: `NtReadFile`, `NtWriteFile`, `NtFlushBuffersFile`, and the rest of the regular-file data ops submit directly to a per-thread `io_uring` instance (`IORING_SETUP_SINGLE_ISSUER | COOP_TASKRUN`), with completion reaped locally and the wineserver never visited. Phase 1 composes with `nspa_local_file`: the unix fd held by the local-file table is the same fd the io_uring path operates on. Phase 2 (sockets, pipes) and Phase 3 (IOCP integration) are queued multi-session pieces.

The wineserver `read_request_shm` path -- the canonical Wine I/O machinery -- shrinks to setup-time only after Phase 2/3 ship.

**Detail: see [io_uring-architecture](io_uring-architecture.gen.html), [nspa-local-file-architecture](nspa-local-file-architecture.gen.html).**

### 3.7 Audio

Audio is delivered through `winejack.drv`, with Phase 1 MIDI and Phase 2 WASAPI audio both routed through JACK. `nspaASIO` layers ASIO on top of the same transport and provides Phase F: zero-latency `bufferSwitch` dispatch **inside** the JACK RT callback so the ASIO host and JACK callback execute on the same period boundary.

The audio thread typically runs at NT band 31 / `TIME_CRITICAL`, which under `NSPA_RT_PRIO=80` maps to SCHED_FIFO 80. JACK's own callback runs at FIFO 88-89 (above NSPA's ceiling but below the `99 (reserved)` kernel-thread band). Wineserver runs at FIFO 64 (auto-derived `NSPA_RT_PRIO - 16`) -- below the entire RT band, so dispatcher contention can never preempt the audio path.

**Detail: see [audio-stack](audio-stack.gen.html).**

---

## 4. Bypass topology

Each bypass moves a specific class of NT-API state or I/O work out of wineserver and into client-local state, bounded shared memory, or kernel-mediated primitives. Every path is independently gated, validated, and revertible.

The current topology covers eleven concrete bypass surfaces plus the residual wineserver floor (process/thread lifecycle, cross-process naming, path resolution, handle inheritance). As of 2026-04-28, the shipped/default-on set includes sync primitives, hook caching, NT-local regular-file open, io_uring Phase 1 regular-file I/O, timers, msg-ring v1 same-process send/reply, and redraw-window push. Paint-cache (B1.0) remains in validation. Phase C (`GetMessage`), sechost device-IRP poll, and io_uring socket/pipe work remain pending.

This staging keeps regression scope local and rebase cost bounded. The shipped paths already remove measurable server traffic while preserving an immediate fallback to the canonical wineserver path when a gate is disabled.

---

## 5. Wineserver residual design

The decomposition plan for wineserver itself is phased: Phase 1 audits and partitions the lock surface, Phase 2 introduces the ntsync extensions needed for safe delegation, Phase 3 splits the process into subsystem threads (timer, fd-poll, aggregate-wait), and Phase 4 separates routing from handlers and further partitions the remaining lock surface.

Phase 3 depends on prior client-side migration. Timer splitting becomes tractable after `nspa_local_timer` reduces server ownership. fd-poll splitting becomes tractable after io_uring absorbs the regular-file and socket surfaces. Lock partitioning becomes tractable only after the residual lock holders are a small, auditable set.

The target is not elimination of wineserver. Process and thread lifecycle, cross-process named-object registration, NT path resolution (`\??\`, NT object directory, 8.3 names, case-insensitive behavior on case-sensitive filesystems), and handle-inheritance coordination at `CreateProcess` time remain centralized. The objective is to reduce wineserver to the authoritative metadata and lifecycle surfaces that cannot be safely decentralized.

**Detail: see [wineserver-decomposition](wineserver-decomposition.gen.html).**

---

## 6. RT priority mapping

Win32 thread priorities map to Linux `SCHED_FIFO` priorities through a single formula:

    fifo_prio = nspa_rt_prio_base - (31 - nt_band)
    clamped to [1..98]

`NSPA_RT_PRIO` (default 80) is the **ceiling**, not a midpoint. NT band 31 (`TIME_CRITICAL` in the REALTIME priority class) maps to exactly the ceiling; lower NT bands scale linearly below it. The wineserver `main_loop` auto-derives its own priority at `NSPA_RT_PRIO - 16` (=64 by default), placing it below the entire RT band so dispatcher contention can never preempt an RT audio thread.

| Win32 label | Win32 value | NT band | FIFO priority (with `NSPA_RT_PRIO=80`) |
|---|---|---|---|
| **TIME_CRITICAL** (REALTIME class)  | +15 | 31 | **80** (ceiling) |
| (band 30) | +6  | 30 | 79 |
| HIGHEST   | +2  | 26 | 75 |
| ABOVE_NORMAL | +1 | 25 | 74 |
| NORMAL (REALTIME class)  | 0  | 24 | 73 |
| BELOW_NORMAL | -1 | 23 | 72 |
| LOWEST    | -2  | 22 | 71 |
| IDLE (REALTIME class)    | -15 | 16 | 65 |
| --- | --- | --- | --- |
| `wineserver` main loop | -- | -- | **64** (`NSPA_RT_PRIO - 16`) |
| (unused) | -- | -- | 1..63 |

The `99 (reserved)` band is kernel-thread only and intentionally unreachable from userspace. JACK / PipeWire RT callbacks typically run at FIFO 88-89, **above** the NSPA Win32 ceiling -- this is correct, because the audio backend has tighter latency requirements than any single client's audio thread.

The mapping is governed by these env vars:

| Var | Default | Effect |
|---|---|---|
| `NSPA_RT_PRIO` | unset (RT dormant) | Master gate. Sets the FIFO ceiling and activates all four PI paths. When unset, NSPA is byte-identical to upstream Wine. |
| `NSPA_RT_POLICY` | `FF` | `SCHED_FIFO` vs `RR` for NT bands [16..30]. Same-prio RR quantum-slices the audio thread; FIFO eliminates. TIME_CRITICAL (NT 31) is always FIFO. |
| `NSPA_SRV_RT_PRIO` | `NSPA_RT_PRIO - 16` | Override wineserver's FIFO priority. Auto-derive is correct -- do not set manually. |
| `NSPA_SRV_RT_POLICY` | `FF` | Wineserver scheduler policy. |

`THREAD_PRIORITY_TIME_CRITICAL` is special-cased at the client side: even if a process didn't first call `SetPriorityClass(REALTIME)`, a `SetThreadPriority(thread, TIME_CRITICAL)` call is treated as a ceiling promotion. This covers the common audio pattern where apps set TIME_CRITICAL without first lifting the process class -- a Win32-API quirk that NSPA accommodates leniently for the ceiling band only.

**Detail: see [current-state](current-state.gen.html) for the live mapping; per-path PI mechanism in [cs-pi](cs-pi.gen.html) and [ntsync-driver](ntsync-driver.gen.html).**

---

## 7. Status reference

The canonical status board lives at **[current-state](current-state.gen.html)**. It tracks shipped vs gated vs pending features, the ntsync patch stack (1003-1009), validation totals against the production kernel (~370M ops, zero errors, zero KASAN splats, two clean Ableton runs on 2026-04-28), and the active env-var matrix per subsystem.

This document describes system structure. `current-state.md` records current validation and default polarity.

---

## 8. Document index

Master overview (this doc) plus dedicated subsystem pages.

| Doc | Subject |
|---|---|
| `architecture.gen.html` (this doc) | Master overview -- shape and structure |
| `current-state.gen.html` | Live state board -- what's shipped, what's pending, validation totals, recent arc |
| `wineserver-decomposition.gen.html` | Long-horizon plan -- Phase 1-4 wineserver process decomposition |
| `gamma-channel-dispatcher.gen.html` | Per-process kernel-mediated wineserver IPC (gamma dispatcher) |
| `nt-local-stubs.gen.html` | NT-local stubs architectural pattern |
| `nspa-local-file-architecture.gen.html` | NT-local file (read-only regular-file `NtCreateFile` bypass) |
| `msg-ring-architecture.gen.html` | msg-ring v1 + v2 design (POST/SEND/REPLY, Phase A, B1.0, Phase C, MR1/MR2/MR4) |
| `hook-cache.gen.html` | Tier 1+2 Win32 hook-chain cache |
| `ntsync-driver.gen.html` | NTSync kernel driver, patch stack 1003-1009 |
| `cs-pi.gen.html` | Critical Section Priority Inheritance (Path A; v2.3) |
| `condvar-pi-requeue.gen.html` | `RtlSleepConditionVariableCS` with `FUTEX_WAIT_REQUEUE_PI` (Path D) |
| `io_uring-architecture.gen.html` | io_uring Phase 1 (regular-file I/O) + ALERTED-state interception |
| `audio-stack.gen.html` | winejack.drv + nspaASIO Phase F |
| `nspa-rt-test.gen.html` | nspa_rt_test PE harness reference |
| `decoration-loop-investigation.gen.html` | Wine 11.6 X11 decoration-loop bug 57955 case study |
| `sync-primitives-research.gen.html` | Background research on sync-primitive selection |
| `shmem-ipc.gen.html` | Historical -- legacy shmem dispatcher (superseded by gamma) |

For commit-level history, the wine submodule is at `wine-rt-claude/wine` (HEAD `ac823311aba` as of this writing); the kernel `ntsync` source is at `linux-nspa/src/linux-6.19.11/drivers/misc/ntsync.{c,h}`.

---

*Master overview generated 2026-04-28. Wine submodule `ac823311aba`, ntsync `srcversion A250A77651C8D5DAB719FE2`, kernel `6.19.11-rt1-1-nspa`. Per-subsystem detail in the dedicated pages linked above; live state in `current-state.gen.html`.*
