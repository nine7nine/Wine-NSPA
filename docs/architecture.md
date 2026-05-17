# Wine-NSPA -- Architecture Overview

This page is the system map for Wine-NSPA. Use it to understand the major layers, where each bypass sits, and which responsibilities still remain in wineserver.

## Table of Contents

1. [What Wine-NSPA is](#1-what-wine-nspa-is)
2. [Layered architecture](#2-layered-architecture)
3. [Subsystem map](#3-subsystem-map)
    - 3.1 [Synchronization and priority inheritance](#31-synchronization-and-priority-inheritance)
    - 3.2 [Wineserver IPC](#32-wineserver-ipc)
    - 3.3 [NT-local stubs](#33-nt-local-stubs)
    - 3.4 [Client scheduler](#34-client-scheduler)
    - 3.5 [Message dispatch](#35-message-dispatch)
    - 3.6 [Shared-state query bypass](#36-shared-state-query-bypass)
    - 3.7 [Hook chains](#37-hook-chains)
    - 3.8 [File I/O](#38-file-io)
    - 3.9 [Memory and shared-memory backing](#39-memory-and-shared-memory-backing)
    - 3.10 [Audio](#310-audio)
4. [Bypass topology](#4-bypass-topology)
5. [Wineserver residual design](#5-wineserver-residual-design)
6. [RT priority mapping](#6-rt-priority-mapping)
7. [Subsystem summary](#7-subsystem-summary)
8. [Document index](#8-document-index)

---

## 1. What Wine-NSPA is

Wine-NSPA is a PREEMPT_RT-tuned fork of Wine 11.8. It targets
`PREEMPT_RT_FULL` Linux kernels, grafts kernel-level priority inheritance onto
every Win32 sync primitive, replaces Wine's single-threaded wineserver event
loop in the hot path with kernel-mediated channels and bounded shmem rings, and
ships a custom `ntsync` kernel module that gives `/dev/ntsync`
Windows-faithful priority semantics with PI boost.

Scope covers latency-sensitive and correctness-sensitive Wine surfaces on PREEMPT_RT: synchronization, wineserver IPC, UI dispatch, startup and steady-state file I/O, hook dispatch, timer delivery, and audio callback paths. Audio workloads are part of the validation matrix, but the architecture is not audio-specific.

NSPA is not an acronym. The current 11.x line is a reimplementation of earlier Wine 8.x and 10.x RT branches, updated to use NTSync (introduced upstream in Wine 9.x and Linux 6.10) instead of the older shmem-dispatcher-based design.

The whole project is a small Linux kernel module (~3 kLOC of `ntsync.{c,h}` deltas on top of upstream) plus a Wine fork that increasingly bypasses wineserver through bounded shmem rings, client-local tables, and scheduler hosts. `NSPA_RT_PRIO` is the master RT gate: when unset, the PI and RT-owned paths stand down and Wine behaves byte-identically to upstream. A few non-RT follow-ons keep their own narrower A/B toggles, but there is no zero-config tax for users who do not opt in.

---

## 2. Layered architecture

The architecture has three layers: a kernel layer (NTSync, io_uring,
librtpi-style PI futexes, RT scheduler), a wineserver layer (gamma channel
dispatcher + main loop + handler tables), and a client layer (ntdll, win32u,
NT-local stubs, the spawn-main-derived scheduler hosts, audio drivers,
application/PE code). Most NSPA bypasses route around the wineserver layer
entirely on the common case, falling back only when the bypass envelope is
exceeded.

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
  <text x="40" y="94" class="lbl-mut">application code, ntdll, win32u, local state, sched hosts, drivers</text>

  <rect x="40"  y="105" width="120" height="40" class="box"/>
  <text x="100" y="123" text-anchor="middle" class="lbl-sm">application code</text>
  <text x="100" y="137" text-anchor="middle" class="lbl-mut">PE side</text>

  <rect x="170" y="105" width="150" height="40" class="box"/>
  <text x="245" y="123" text-anchor="middle" class="lbl-sm">ntdll</text>
  <text x="245" y="137" text-anchor="middle" class="lbl-mut">unix sync + waits + TEB hot path</text>

  <rect x="330" y="105" width="150" height="40" class="box"/>
  <text x="405" y="123" text-anchor="middle" class="lbl-sm">win32u + nspa</text>
  <text x="405" y="137" text-anchor="middle" class="lbl-mut">msg-ring + TEB caches + empty-poll cache</text>

  <rect x="490" y="105" width="160" height="40" class="box-hot"/>
  <text x="570" y="123" text-anchor="middle" class="lbl-yel">NT-local stubs</text>
  <text x="570" y="137" text-anchor="middle" class="lbl-mut">file / section / event / timer</text>

  <rect x="660" y="105" width="130" height="40" class="box"/>
  <text x="725" y="123" text-anchor="middle" class="lbl-sm">shared-state readers</text>
  <text x="725" y="137" text-anchor="middle" class="lbl-mut">thread/process query + zero-time waits</text>

  <rect x="800" y="105" width="140" height="40" class="box"/>
  <text x="870" y="123" text-anchor="middle" class="lbl-sm">winejack + nspaASIO</text>
  <text x="870" y="137" text-anchor="middle" class="lbl-mut">audio, MIDI, direct callback</text>

  <rect x="40"  y="155" width="220" height="35" class="box"/>
  <text x="150" y="172" text-anchor="middle" class="lbl-sm">CS-PI v2.3 (RTL_CRITICAL_SECTION)</text>
  <text x="150" y="184" text-anchor="middle" class="lbl-mut">FUTEX_LOCK_PI on LockSemaphore</text>

  <rect x="270" y="155" width="220" height="35" class="box"/>
  <text x="380" y="172" text-anchor="middle" class="lbl-sm">condvar PI requeue (SleepCondVarCS)</text>
  <text x="380" y="184" text-anchor="middle" class="lbl-mut">FUTEX_WAIT_REQUEUE_PI</text>

  <rect x="500" y="155" width="180" height="35" class="box"/>
  <text x="590" y="172" text-anchor="middle" class="lbl-sm">hook tier 1+2 cache</text>
  <text x="590" y="184" text-anchor="middle" class="lbl-mut">shmem, server publishes invalidations</text>

  <rect x="690" y="155" width="250" height="35" class="box"/>
  <text x="815" y="172" text-anchor="middle" class="lbl-sm">wine-sched hosts</text>
  <text x="815" y="184" text-anchor="middle" class="lbl-mut">close queue + RT timers + timer dispatch</text>

  <!-- Wineserver layer -->
  <rect x="20" y="220" width="940" height="130" class="layer-s"/>
  <text x="40" y="240" class="lbl-pur">WINESERVER (RT request plane + residual authority)</text>
  <text x="40" y="254" class="lbl-mut">gamma dispatcher, handler tables, lifecycle, cross-process state</text>

  <rect x="40"  y="265" width="200" height="70" class="box-hot"/>
  <text x="140" y="283" text-anchor="middle" class="lbl-yel">gamma aggregate-wait dispatcher</text>
  <text x="140" y="297" text-anchor="middle" class="lbl-mut">per-process channel + uring</text>
  <text x="140" y="311" text-anchor="middle" class="lbl-mut">aggregate-wait -&gt; RECV2 -&gt; TRY_RECV2</text>
  <text x="140" y="325" text-anchor="middle" class="lbl-cy">same-thread CQE drain + REPLY</text>

  <rect x="260" y="265" width="180" height="70" class="box"/>
  <text x="350" y="283" text-anchor="middle" class="lbl-sm">main loop / epoll / timers</text>
  <text x="350" y="297" text-anchor="middle" class="lbl-mut">residual fd + timeout work</text>
  <text x="350" y="311" text-anchor="middle" class="lbl-mut">global_lock (PI-aware)</text>
  <text x="350" y="325" text-anchor="middle" class="lbl-mut">openat lock-drop</text>

  <rect x="460" y="265" width="200" height="70" class="box"/>
  <text x="560" y="283" text-anchor="middle" class="lbl-sm">handler tables</text>
  <text x="560" y="297" text-anchor="middle" class="lbl-mut">req_handlers[]</text>
  <text x="560" y="311" text-anchor="middle" class="lbl-mut">file / proc / thread /</text>
  <text x="560" y="325" text-anchor="middle" class="lbl-mut">sync / hooks / queue</text>

  <rect x="680" y="265" width="240" height="70" class="box"/>
  <text x="800" y="283" text-anchor="middle" class="lbl-sm">cross-process state</text>
  <text x="800" y="297" text-anchor="middle" class="lbl-mut">handle table + snapshot publish</text>
  <text x="800" y="311" text-anchor="middle" class="lbl-mut">named-object registry</text>
  <text x="800" y="325" text-anchor="middle" class="lbl-mut">lifecycle / fork tracking</text>

  <!-- Kernel layer -->
  <rect x="20" y="370" width="940" height="190" class="layer-k"/>
  <text x="40" y="390" class="lbl-blu">KERNEL (PREEMPT_RT_FULL)</text>
  <text x="40" y="404" class="lbl-mut">6.19.11-rt1-1-nspa</text>

  <rect x="40"  y="415" width="200" height="120" class="box-hot"/>
  <text x="140" y="434" text-anchor="middle" class="lbl-yel">ntsync.ko</text>
  <text x="140" y="450" text-anchor="middle" class="lbl-mut">NT sync object driver</text>
  <text x="140" y="464" text-anchor="middle" class="lbl-cy">PI waits + channel transport</text>
  <text x="140" y="478" text-anchor="middle" class="lbl-cy">thread-token pass-through</text>
  <text x="140" y="492" text-anchor="middle" class="lbl-cy">aggregate-wait + TRY_RECV2</text>
  <text x="140" y="506" text-anchor="middle" class="lbl-cy">snapshot + dedicated slab caches</text>
  <text x="140" y="520" text-anchor="middle" class="lbl-cy">wait-q cache + lockless SEND_PI</text>

  <rect x="260" y="415" width="200" height="120" class="box"/>
  <text x="360" y="434" text-anchor="middle" class="lbl-sm">PI futex layer</text>
  <text x="360" y="452" text-anchor="middle" class="lbl-mut">FUTEX_LOCK_PI</text>
  <text x="360" y="468" text-anchor="middle" class="lbl-mut">FUTEX_WAIT_REQUEUE_PI</text>
  <text x="360" y="484" text-anchor="middle" class="lbl-mut">FUTEX_CMP_REQUEUE_PI</text>
  <text x="360" y="502" text-anchor="middle" class="lbl-mut">rt_mutex chain (transitive)</text>
  <text x="360" y="518" text-anchor="middle" class="lbl-mut">vendored librtpi userspace</text>

  <rect x="480" y="415" width="200" height="120" class="box"/>
  <text x="580" y="434" text-anchor="middle" class="lbl-sm">io_uring</text>
  <text x="580" y="452" text-anchor="middle" class="lbl-mut">regular file I/O</text>
  <text x="580" y="468" text-anchor="middle" class="lbl-mut">async CreateFile + sockets</text>
  <text x="580" y="484" text-anchor="middle" class="lbl-mut">SINGLE_ISSUER + COOP_TASKRUN</text>
  <text x="580" y="500" text-anchor="middle" class="lbl-mut">ALERTED-state interception</text>
  <text x="580" y="518" text-anchor="middle" class="lbl-cy">same-thread CQE drain + socket SQEs</text>

  <rect x="700" y="415" width="240" height="120" class="box"/>
  <text x="820" y="434" text-anchor="middle" class="lbl-sm">RT scheduler + VM</text>
  <text x="820" y="452" text-anchor="middle" class="lbl-mut">SCHED_FIFO 1..98</text>
  <text x="820" y="468" text-anchor="middle" class="lbl-mut">priority-ordered wakeup</text>
  <text x="820" y="484" text-anchor="middle" class="lbl-mut">rt_mutex PI propagation</text>
  <text x="820" y="500" text-anchor="middle" class="lbl-mut">mlockall + auto hugetlb promotion</text>
  <text x="820" y="518" text-anchor="middle" class="lbl-mut">heap-arena hugetlb backing</text>

  <text x="490" y="555" text-anchor="middle" class="lbl-mut">--- bypass routes (dashed orange) skip the wineserver layer entirely ---</text>

  <!-- Bypass routes: client -> kernel directly -->
  <path d="M570 145 L570 360 L140 360 L140 415" class="ln-by"/>
  <path d="M570 145 L570 380 L580 380 L580 415" class="ln-by"/>
  <path d="M150 190 L150 360 L360 360 L360 415" class="ln-by"/>
  <line x1="380" y1="190" x2="360" y2="415" class="ln-by"/>

  <!-- Wineserver routes: client -> server -->
  <path d="M405 145 L405 225 L140 225 L140 265" class="ln"/>
  <line x1="590" y1="190" x2="560" y2="265" class="ln"/>

  <!-- Server -> kernel -->
  <line x1="140" y1="335" x2="140" y2="415" class="ln"/>
  <path d="M180 335 L180 380 L580 380 L580 415" class="ln"/>
  <line x1="350" y1="335" x2="360" y2="415" class="ln"/>

  <!-- Legend -->
  <line x1="40"  y1="585" x2="80"  y2="585" class="ln"/>
  <text x="90"  y="589" class="lbl-mut">canonical wineserver path</text>
  <line x1="280" y1="585" x2="320" y2="585" class="ln-by"/>
  <text x="330" y="589" class="lbl-mut">NSPA bypass route (skips wineserver)</text>
  <rect x="600" y="578" width="20" height="14" class="box-hot"/>
  <text x="630" y="589" class="lbl-mut">hot path / NSPA-introduced</text>
</svg>
</div>

The diagram defines the routing boundaries. Vanilla Wine routes these surfaces through wineserver, which serializes most handlers under `global_lock`. NSPA adds kernel-mediated and client-local bypasses that remove wineserver from the common path while preserving wineserver ownership of cross-process naming, lifecycle, and residual server-managed state.

---

## 3. Subsystem map

Each subsection here is a one-paragraph (sometimes two) sketch of the subsystem; the deep design is in a dedicated page linked at the end of each section.

### 3.1 Synchronization and priority inheritance

NSPA implements priority inheritance along four independent paths so that no Win32 sync surface is left as a priority-inversion source. CS-PI repurposes `RTL_CRITICAL_SECTION::LockSemaphore` as a `FUTEX_LOCK_PI` futex word, giving every critical section the kernel's transitive PI chain semantics. NTSync direct routes `NtWaitForSingleObject` and friends through `/dev/ntsync` ioctls, where the kernel overlay implements priority-ordered waiter queues and per-task PI boost across mutex chains. Vendored librtpi provides `pi_cond_wait` for unix-side condition variables built on `FUTEX_WAIT_REQUEUE_PI`. Win32 condvar PI extends that up into the Win32 surface so `SleepConditionVariableCS` is also PI-clean.

The kernel side is where the heavy lifting happens. The `ntsync.ko`
module sits at `/dev/ntsync` and implements NT sync object semantics
natively in the kernel, with PI-aware mutexes, priority-ordered waiter
queues, a channel transport that serves the gamma dispatcher, a
thread-token return path, an aggregate-wait primitive for
heterogeneous waits, and `TRY_RECV2` for post-dispatch burst drain. The
userspace half also includes the client-created anonymous sync path
for mutexes, semaphores, and events, so the design is a kernel overlay
plus a Wine-side in-process sync layer rather than “just a driver.”

All four paths are gated on `NSPA_RT_PRIO`. When unset, every PI code path short-circuits and Wine behaves byte-for-byte like upstream. **Detail: see [NTSync PI Kernel](ntsync-pi-driver.gen.html), [NTSync Userspace Sync](ntsync-userspace.gen.html), [cs-pi](cs-pi.gen.html), [condvar-pi-requeue](condvar-pi-requeue.gen.html).**

### 3.2 Wineserver IPC

The classical Wine IPC architecture has every client thread `read()`/`write()` over a unix socket pair to the wineserver process, which dispatches under `global_lock`. The earlier NSPA work (Torge Matthies's 2022 patch, forward-ported as the v1.5 line) replaced the socket round-trip with a per-thread shmem region and a futex signal, served by a pool of pthread dispatchers inside the server. That worked but had its own pile of correctness rough edges; it has been superseded by the **gamma channel dispatcher**.

The gamma dispatcher uses the ntsync channel object to deliver a
per-process kernel-mediated request/reply queue. The client thread
issues `NTSYNC_IOC_CHANNEL_SEND_PI`; the dispatcher receives via
`CHANNEL_RECV2` and replies via `CHANNEL_REPLY`. On current kernels it
blocks in `NTSYNC_IOC_AGGREGATE_WAIT` over the channel plus its
per-process uring eventfd and shutdown eventfd, then follows each
reply with non-blocking `TRY_RECV2` burst drain until the queue is
empty. The dispatcher path also carries a small hot-path tuning
pack: inline request / queue helpers, lighter fences, and no production
allocator poison overhead. The channel object also returns a
thread-token so the kernel knows which client thread sent the request,
letting the server-side request path resolve the sender without a
second userspace lookup. The legacy
shmem-IPC path (`shmem-ipc.gen.html`) is **historical and superseded**
and retained as reference material only.

**Detail: see [gamma-channel-dispatcher](gamma-channel-dispatcher.gen.html). Historical: [shmem-ipc](shmem-ipc.gen.html) (superseded).**

### 3.3 NT-local stubs

The NT-local stubs pattern moves NT-API state from wineserver-resident storage
into client-resident storage. The pattern: the client maintains its own state
for a class of NT objects (file handles, local sections, anonymous events,
timers, WM_TIMER tuples), processes operations locally, and lazily promotes the
state back to a server-visible handle only when an API genuinely needs
server-side handle semantics (`DuplicateHandle`, `CreateProcess` inheritance,
cross-process visibility). The stub answers the common case locally; the server
stays the authority for the long tail.

Active NT-local surfaces include `nspa_local_file`, local sections,
anonymous local events, `nspa_local_timer`, and `nspa_local_wm_timer`.
The timer work is also extended so anonymous timers piggyback on the
local-event base and the timer dispatchers can run on the shared RT
scheduler host instead of dedicated helper threads. The same general
client-side move is also what made the async local-file close queue
worth centralizing on the scheduler host instead of minting yet another
long-lived helper thread.

**Detail: see [nt-local-stubs](nt-local-stubs.gen.html), [nspa-local-file-architecture](nspa-local-file-architecture.gen.html), [local-section-architecture](local-section-architecture.gen.html).**

### 3.4 Client scheduler

The client-side scheduler is its own architectural layer inside the process.
Upstream spawn-main split the Unix bootstrap thread from the Win32 app main
thread; Wine-NSPA uses that split to host `ntdll_sched` on a per-process
default-class thread (`wine-sched`) plus a lazy RT-class thread
(`wine-sched-rt`). One current consumer is the async local-file close
queue, and the RT-class consumers are the migrated `local_timer` and
`local_wm_timer` dispatchers.

This is not a replacement for gamma or wineserver dispatch. It is the client
helper-thread consolidation layer: a place to host small loops, close queues,
observability sampling, and RT timer work without a fresh per-subsystem
dedicated thread.

**Detail: see [client-scheduler-architecture](client-scheduler-architecture.gen.html).**

### 3.5 Message dispatch

The Win32 message pump is the second-hottest source of wineserver round-trips (after `NtCreateFile`, which `nspa_local_file` already drains). A typical Win32 application calls `GetMessage` / `PeekMessage` on every UI tick; cross-thread `PostMessage` and `SendMessage` go through the server even when sender and receiver are in the same process; `RedrawWindow` and `InvalidateRect` push paint flags into the server.

NSPA's msg-ring v1 ships a per-thread bounded MPMC shmem ring for cross-thread
same-process `PostMessage` / `SendMessage` / reply, signalled via NTSync
events. The same substrate also carries the `redraw_window` push ring, the
paint-cache fast path, and a `get_message` empty-poll cache. That
cache keeps a per-thread snapshot of the last empty filter tuple plus
`queue_shm->nspa_change_seq`; if the same filter comes back before the sequence
changes, Wine returns `STATUS_PENDING` locally instead of paying another
wineserver round-trip. The message path also reads its hot per-thread caches
through `TEB->Win32ClientInfo` instead of repeated
`pthread_getspecific()` calls. On the current 2026-05-16 layout, the forward
msg ring and the co-located timer/redraw rings also keep hot producer and
consumer indices on separate cachelines so the writer's `head` updates and the
reader's `tail` advances do not false-share the same line.

Three pre-existing wine-userspace bugs in `dlls/win32u/nspa/msg_ring.c` were found and fixed in the 2026-04-27 audit (MR1 reply-slot ABA, MR2 `FUTEX_PRIVATE` on `MAP_SHARED` memfd, MR4 POST wake-loss on dual-signal-fail rollback), all of the silent-contract-violation class.

**Detail: see [msg-ring-architecture](msg-ring-architecture.gen.html).**

### 3.6 Shared-state query bypass

Wine-NSPA publishes read-mostly thread and process snapshots into shared
objects so a set of `NtQueryInformationThread()` and
`NtQueryInformationProcess()` classes can answer locally. The current coverage
is seven thread classes, six process classes, the zero-time
`WaitForSingleObject(process, 0)` liveness poll, and the zero-time
`WaitForSingleObject(thread, 0)` liveness poll. The client path uses a seqlock
read discipline over server-published snapshots; if the snapshot is missing or
the information class still needs server-side transformation, the original RPC
path remains in place.

This is intentionally not a general "all query classes are local" claim.
`ThreadBasicInformation` still stays on the server path because the existing
reply transform does more than dump raw kernel state. The current path is the
read-mostly slice that was safe to publish and validate independently.

**Detail: see [thread-and-process-shared-state](thread-and-process-shared-state.gen.html).**

### 3.7 Hook chains

Win32 hook chains (`WH_KEYBOARD`, `WH_MOUSE`, `WH_GETMESSAGE`, `WH_CALLWNDPROC`, etc.) get queried on every dispatch in vanilla Wine, even when the chain is empty. On a busy UI tick that is one server round-trip per hook type per `GetMessage` iteration, which adds up: an Ableton 165s capture showed 26,700 hook lookups across the run.

NSPA caches the hook chain in a per-process shmem region (Tier 1 = "is there any hook of type X at all?"; Tier 2 = "here's the full list"). The wineserver publishes invalidations on chain mutation. Hot-path lookups become an O(1) shmem read. Steady-state validation: 26,700 / 26,700 cache hits, server-side `get_hook_info` dropped to 0.

**Detail: see [hook-cache](hook-cache.gen.html).**

### 3.8 File I/O

File I/O is two related stories. The **open path** is owned by `nspa_local_file`
(see §3.3): a bounded set of regular-file and explicit-directory `NtCreateFile`
calls are serviced client-side via `stat()` / `lstat()` + `open()`, with
sharing arbitration preserved through a server-published
`(dev, inode) -> sharing-state` shmem region. Only API surfaces that genuinely
need a server-visible file handle trigger lazy promotion, and eligible unnamed
file-backed sections can stay local too.

The **data-plane path** is owned by `io_uring`: regular-file reads and writes
submit directly to a per-thread ring, async `CreateFile` routes through the
per-process dispatcher-owned ring, and the deferred async socket path uses
true `RECVMSG` / `SENDMSG` SQEs. `io_uring` composes with `nspa_local_file`
because the unix fd held by the local-file table is the same fd the ring path
operates on, and local sections reduce the matching mapping-side RPC churn
that used to sit adjacent to those opens.

What remains outside `io_uring` is the genuinely server-managed surface:
named pipes, named events, cross-process section / handle boundaries, and the
parts of the async model that still depend on server-owned pseudo-fds or object
naming.

**Detail: see [io_uring-architecture](io_uring-architecture.gen.html), [nspa-local-file-architecture](nspa-local-file-architecture.gen.html), [local-section-architecture](local-section-architecture.gen.html).**

### 3.9 Memory and shared-memory backing

Wine-NSPA's memory surface is broader than "large pages exist." The current
tree has four memory stories that matter architecturally: client-side local
sections, RT-keyed page locking and automatic hugetlb promotion, current-process
`QueryWorkingSetEx()` reporting plus working-set quota bookkeeping, and the
selective use of dedicated `memfd` backends for bypass state such as msg-ring,
shared-state snapshots, and local-file inode arbitration.

Those pieces are related because they all change how Wine exposes or backs
memory, but they are not the same mechanism. Local sections are about keeping
common file-backed views client-side. RT-keyed `mlockall()`, automatic
hugetlb promotion, and heap-arena hugetlb backing are about page locking and
page size on the hot RT path. Working-set support is about what the Win32
memory surface reports and stores. `memfd` is about where bypass-owned shared
state lives.
Keeping those roles separate makes the design easier to reason about and avoids
the common mistake of treating every shared region as "just more session shmem."

**Detail: see [memory-and-large-pages](memory-and-large-pages.gen.html), [local-section-architecture](local-section-architecture.gen.html), [msg-ring-architecture](msg-ring-architecture.gen.html), [nspa-local-file-architecture](nspa-local-file-architecture.gen.html).**

### 3.10 Audio

Audio is delivered through `winejack.drv`, which routes both JACK-backed MIDI and WASAPI audio. `nspaASIO` layers ASIO on top of the same transport and provides the low-latency path: zero-latency `bufferSwitch` dispatch **inside** the JACK RT callback so the ASIO host and JACK callback execute on the same period boundary.

The audio thread typically runs at NT band 31 / `TIME_CRITICAL`, which under `NSPA_RT_PRIO=80` maps to SCHED_FIFO 80. JACK's own callback runs at FIFO 88-89 (above NSPA's ceiling but below the `99 (reserved)` kernel-thread band). Wineserver runs at FIFO 64 (auto-derived `NSPA_RT_PRIO - 16`) -- below the entire RT band, so dispatcher contention can never preempt the audio path.

**Detail: see [audio-stack](audio-stack.gen.html).**

---

## 4. Bypass topology

Each bypass moves a specific class of NT-API state or I/O work out of wineserver and into client-local state, bounded shared memory, or kernel-mediated primitives. Every path is independently bounded, validated, and revertible.

The current topology covers the active bypass surfaces plus the
residual wineserver floor (process/thread lifecycle, cross-process
naming, path resolution, handle inheritance). As of 2026-05-16, the
default-on set includes sync primitives, hook caching,
thread/process shared-state readers, zero-time process and thread wait polling,
NT-local file and section handling, local events, sched-hosted timer dispatch,
the client scheduler substrate, `io_uring` regular-file I/O, gamma's
aggregate-wait + `TRY_RECV2` dispatcher path, async `CreateFile`,
socket `RECVMSG` / `SENDMSG`, msg-ring v1 same-process send/reply,
the `redraw_window` push ring, the paint cache fast path, the
`get_message` empty-poll cache, and the RT-keyed memory follow-ons
(`mlockall()`, automatic hugetlb promotion, heap-arena hugetlb backing).
The main remaining server-managed surfaces are the harder cross-process,
named-object, device-IRP, and message classes that do not fit those local
envelopes.

This staging keeps regression scope local and rebase cost bounded. The active
paths already remove measurable server traffic while still falling back cleanly
whenever a call leaves the local envelope or an explicit A/B toggle is used.

---

## 5. Wineserver residual design

The decomposition plan for wineserver is mostly about the residual
server-owned timer, fd-poll, routing, and lock-partitioning work that remains
after the bypass set above. Timer splitting becomes tractable after
`nspa_local_timer` reduces server ownership. fd-poll splitting becomes
tractable after `io_uring` absorbs the regular-file and socket surfaces. Lock
partitioning becomes tractable only after the residual lock holders are a
small, auditable set. The shared-state readers, zero-time waits, and
message-pump empty-poll cache reduced that residual further by draining
read-mostly query traffic and repeated empty queue polls before they ever
became wineserver work; the later hot-path carries then lowered the cost of
those already-local paths further through TEB-relative state, cacheline
layout work, helper inlining, and x86_64 AVX2 string / Unicode fast windows.

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

App-facing RT promotions intentionally do **not** set Linux's sticky
`SCHED_RESET_ON_FORK` flag. Wine threads are created with
`pthread_create` / `clone3(CLONE_THREAD)`, not `fork(2)`, so the flag does not
protect the threading model NSPA actually uses. Omitting it keeps later
application-side demotion calls such as `SetThreadPriority(NORMAL)` symmetric
instead of tripping the kernel's `-EPERM` rule for clearing the sticky flag.

**Detail: see [current-state](current-state.gen.html) for the live mapping; per-path PI mechanism in [cs-pi](cs-pi.gen.html), [NTSync PI Kernel](ntsync-pi-driver.gen.html), and [NTSync Userspace Sync](ntsync-userspace.gen.html).**

---

## 7. Status reference

The canonical status board lives at **[current-state](current-state.gen.html)**. It tracks active surfaces, current defaults, validation totals, and the current dispatcher and memory tuning notes.

This document describes system structure. `current-state.md` records current validation and default polarity.

---

## 8. Document index

Master overview (this doc) plus dedicated subsystem pages.

| Doc | Subject |
|---|---|
| `architecture.gen.html` (this doc) | Master overview -- shape and structure |
| `current-state.gen.html` | Live state board -- active surfaces, remaining work, validation totals, recent arc |
| `aggregate-wait-and-async-completion.gen.html` | Aggregate-wait plus same-thread async completion architecture |
| `client-scheduler-architecture.gen.html` | spawn-main + `ntdll_sched`, default-class and RT-class sched hosts, and their consumers |
| `wineserver-decomposition.gen.html` | Long-horizon wineserver decomposition plan |
| `gamma-channel-dispatcher.gen.html` | Per-process kernel-mediated wineserver IPC (gamma dispatcher) |
| `nt-local-stubs.gen.html` | NT-local stubs architectural pattern |
| `local-section-architecture.gen.html` | client-side unnamed file-backed sections on top of local-file handles |
| `nspa-local-file-architecture.gen.html` | NT-local file path for bounded regular-file and explicit-directory opens |
| `msg-ring-architecture.gen.html` | Same-process message rings, redraw push ring, paint cache, and the `get_message` empty-poll cache |
| `memory-and-large-pages.gen.html` | large pages, working-set reporting, automatic hugetlb promotion, quota bookkeeping, and shared-memory backing choices |
| `hot-path-optimizations.gen.html` | cross-cutting optimization choices: published-state caching, TEB-relative hot state, cache/slab layout, helper inlining, SIMD string/Unicode loops, and GUI flush trims |
| `thread-and-process-shared-state.gen.html` | server-published thread/process snapshots, query bypass coverage, and zero-time process/thread waits |
| `hook-cache.gen.html` | Tier 1+2 Win32 hook-chain cache |
| `ntsync-pi-driver.gen.html` | NTSync PI kernel overlay: PI baseline, channel transport, aggregate-wait, and later kernel hardening |
| `ntsync-userspace.gen.html` | Wine in-process sync path: handle-to-fd cache, client-created sync objects, direct wait/signal helpers, and dispatcher-facing wrappers |
| `cs-pi.gen.html` | Critical Section Priority Inheritance (Path A; v2.3) |
| `condvar-pi-requeue.gen.html` | `RtlSleepConditionVariableCS` with `FUTEX_WAIT_REQUEUE_PI` (Path D) |
| `io_uring-architecture.gen.html` | `io_uring` file I/O, async `CreateFile`, and socket SQEs |
| `audio-stack.gen.html` | winejack.drv + nspaASIO low-latency audio path |
| `nspa-x11-embed-protocol.gen.html` | Wine-NSPA atomic X11 embed contract for winelib hosts |
| `juce-nspa.gen.html` | JUCE-NSPA framework substrate for Linux winelib Windows-plugin hosts |
| `element-plugin-host.gen.html` | Element-NSPA application port with JACK-first MIDI routing |
| `yabridge-nspa.gen.html` | Yabridge-NSPA bridge alignment for native Linux DAWs hosting Windows plugins |
| `nspa-rt-test.gen.html` | nspa_rt_test PE harness reference |
| `decoration-loop-investigation.gen.html` | X11 decoration-loop bug 57955 case study |
| `sync-primitives-research.gen.html` | Background research on sync-primitive selection |
| `shmem-ipc.gen.html` | Historical -- legacy shmem dispatcher (superseded by gamma) |

The live defaults, current overlay, and exact validation
totals are maintained on `current-state.gen.html` rather than repeated
here.

---

*Master overview updated 2026-05-17. Per-subsystem detail is in the dedicated pages linked above; live state is in `current-state.gen.html`.*
