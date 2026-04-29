# Wine-NSPA -- Aggregate-Wait and Async Completion

Wine 11.6 + NSPA RT patchset | Design / implementation plan | 2026-04-29
Author: Jordan Johnston

This doc covers two linked pieces of work that share one architectural
goal: add a PI-aware heterogeneous wait primitive to ntsync, then use
it to restructure gamma-dispatcher async completion so the same RT
thread submits, drains, and replies.

**Status:** Design draft. Work not yet started. Supersedes the earlier
cross-thread Phase C shape because that design introduced main-thread
timing variance on reply completion, which is the wrong architecture
for this path.

**Two deliverables, one design:**

1. **Kernel — `NTSYNC_IOC_AGGREGATE_WAIT` (PI-aware)**: the unified
   completion-handling primitive Wine has been missing.  Heterogeneous
   wait over N ntsync objects + M fds + optional timer, atomic, with
   PI propagation for object sources.  Per `wineserver-decomposition-plan.md`
   §2.2 spec.  Patch 1010 in the existing ntsync series.  Many
   immediate consumers (Phase C re-port, decomp §3.1/§3.3, IOCP, etc.).

2. **Userspace — gamma dispatcher restructure**: make Phase C's
   async-completing handler path work correctly by waiting atomically
   on (channel, io_uring CQE) via aggregate-wait, replacing the
   broken cross-thread bridge.  Per-process io_uring owned by the
   dispatcher, drain inline on the same RT thread.

**Why both together:** the userspace restructure is the immediate
consumer that justifies landing the kernel primitive, and the kernel
primitive is what unblocks the userspace restructure.  They're one
piece of architectural work.

**The bigger story:** `aggregate-wait` is the completion-handling
primitive Wine has lacked.  Many adjacent uses become incremental
small commits afterward (see §8.6).  The userspace dispatcher
restructure for Phase C is just the first consumer.

---

## Table of contents

1. [Why this needs to exist](#1-why-this-needs-to-exist)
2. [What's wrong with the current Phase C bridge](#2-whats-wrong-with-the-current-phase-c-bridge)
3. [Target architecture](#3-target-architecture)
4. [Kernel work — `NTSYNC_IOC_AGGREGATE_WAIT` (PI-aware)](#4-kernel-work--ntsync_ioc_aggregate_wait-pi-aware)
5. [Userspace restructure — per-process ring](#5-userspace-restructure--per-process-ring)
6. [Migration phasing](#6-migration-phasing)
7. [Validation strategy](#7-validation-strategy)
8. [Wider architectural implications](#8-wider-architectural-implications)
9. [Open questions and recommendations](#9-open-questions-and-recommendations)
10. [Implementer's quick-reference](#10-implementers-quick-reference)
11. [References](#11-references)

---

## 1. Why this needs to exist

The gamma channel (kernel patch 1004) was designed for **synchronous
handlers**: each request RECV'd by the dispatcher pthread runs to
completion (handler finishes, REPLY signalled) before the next RECV.
This is the model `server/nspa/shmem_channel.c::nspa_shmem_channel_pthread`
implements today.

That model has a hard ceiling on dispatcher throughput: one in-flight
request per process, gated by handler latency.  For most handlers this
is fine — handler latency is microseconds.  But for handlers that
wrap blocking syscalls (`openat` on cold-cache files, network mounts,
`realpath`, `readlink`), handler latency spikes to milliseconds, and
the dispatcher is unavailable for unrelated requests during the spike.

NSPA Phase B (`server/nspa/fd_lockdrop.c`) released `global_lock`
across the syscall, allowing other dispatchers to run their handlers
concurrently — but only if those handlers ran on different processes'
dispatcher pthreads.  The originating dispatcher remained blocked on
its own slow handler.

Phase C introduced the next step: make the dispatcher's handler itself
async-completing.  Submit the syscall to io_uring, return to RECV
immediately, complete the reply when the CQE arrives.

The first cut put the CQE drain on `main_loop_epoll` (because that's
the simplest place to add a fd to a waitset).  That works structurally
but introduces a cross-thread reply path the gamma channel was never
designed for, with consequences described in §2.

**This document specifies the structurally correct integration**: each
gamma dispatcher pthread owns its own io_uring, drains CQEs inline,
and waits atomically on `(channel request, in-flight CQEs)` via
`NTSYNC_IOC_AGGREGATE_WAIT`. Same RT thread submits, drains, and
replies. No cross-thread bridge.

## 2. What's wrong with the current Phase C bridge

Architecture today (gate ON):

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 500" xmlns="http://www.w3.org/2000/svg">
  <style>
    .cw-bg { fill: #1a1b26; }
    .cw-lane { stroke: #3b4261; stroke-width: 1; stroke-dasharray: 6,4; }
    .cw-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .cw-main { fill: #2a1a1a; stroke: #f7768e; stroke-width: 2; rx: 8; }
    .cw-note { fill: #2a1f14; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .cw-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .cw-small { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .cw-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cw-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cw-yellow { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cw-line { stroke: #c0caf5; stroke-width: 1.4; }
  </style>
  <defs>
    <marker id="cwArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="940" height="500" class="cw-bg"/>
  <text x="470" y="28" text-anchor="middle" class="cw-title">Current cross-thread Phase C bridge</text>

  <text x="220" y="66" text-anchor="middle" class="cw-label">Process A dispatcher pthread</text>
  <text x="720" y="66" text-anchor="middle" class="cw-red">Wineserver main thread</text>
  <line x1="220" y1="80" x2="220" y2="430" class="cw-lane"/>
  <line x1="720" y1="80" x2="720" y2="430" class="cw-lane"/>

  <rect x="110" y="104" width="220" height="58" class="cw-box"/>
  <text x="220" y="128" text-anchor="middle" class="cw-label">CHANNEL_RECV2</text>
  <text x="220" y="146" text-anchor="middle" class="cw-small">dispatcher owns request entry</text>

  <rect x="110" y="196" width="220" height="74" class="cw-box"/>
  <text x="220" y="220" text-anchor="middle" class="cw-label">handler submits SQE</text>
  <text x="220" y="238" text-anchor="middle" class="cw-small">async create/open path defers reply</text>
  <text x="220" y="256" text-anchor="middle" class="cw-small">dispatcher returns to RECV loop</text>

  <rect x="610" y="104" width="220" height="58" class="cw-main"/>
  <text x="720" y="128" text-anchor="middle" class="cw-red">main_loop_epoll</text>
  <text x="720" y="146" text-anchor="middle" class="cw-small">poll / epoll owns uring wake</text>

  <rect x="610" y="196" width="220" height="92" class="cw-main"/>
  <text x="720" y="220" text-anchor="middle" class="cw-label">CQE arrives later</text>
  <text x="720" y="238" text-anchor="middle" class="cw-small">main thread drains CQE</text>
  <text x="720" y="256" text-anchor="middle" class="cw-small">callback writes reply</text>
  <text x="720" y="274" text-anchor="middle" class="cw-small">CHANNEL_REPLY issued from different thread</text>

  <line x1="330" y1="232" x2="610" y2="232" class="cw-line" marker-end="url(#cwArrow)"/>
  <line x1="610" y1="304" x2="330" y2="340" class="cw-line" marker-end="url(#cwArrow)"/>

  <rect x="160" y="324" width="120" height="42" class="cw-box"/>
  <text x="220" y="350" text-anchor="middle" class="cw-label">reply observed</text>

  <rect x="140" y="396" width="660" height="64" class="cw-note"/>
  <text x="470" y="422" text-anchor="middle" class="cw-yellow">Problem surface</text>
  <text x="470" y="440" text-anchor="middle" class="cw-small">submission, completion, and reply cross thread boundaries; CQE-to-reply latency is now gated by main-thread wake timing and contention rather than dispatcher availability</text>
</svg>
</div>

The dispatcher pthread submits an SQE.  The CQE is delivered (later)
to the wineserver main thread via the io_uring fd in epoll.  The main
thread runs the CQE callback, writes the reply, and signals
`CHANNEL_REPLY`.

What goes wrong:

1. **Cross-thread latency is variable.**  The main thread might be
   blocked in `epoll_pwait2`, processing other events, or running its
   own handler dispatch.  CQE-to-completion delay is bounded only by
   the main thread's wakeup and global_lock contention, not by
   dispatcher pthread availability.  Per-thread reply latency varies
   in a way the gamma channel was never designed for.

2. **Reply ordering across threads is no longer in the dispatcher's
   control.**  Same-thread is preserved (each client thread blocks on
   its own SEND_PI), but cross-client-thread reply delivery diverges
   from sync — the order in which replies arrive can flip.

3. **`current` save/restore window is wide.**  The CQE callback restores
   `current` to the requesting thread, but the main loop has its own
   handler dispatch interleaved.  This was solved correctly in the
   current implementation, but adds reasoning surface for every future
   handler that wants to async-complete.

4. **RT-priority discipline is split.**  The dispatcher pthread is
   `SCHED_FIFO @ nspa_srv_rt_prio`.  The main loop is the same priority
   but it's a different thread queue with different cache state.
   The full async path crosses RT scheduling boundaries.

5. **Empirically observed in Ableton gate-ON validation
   (2026-04-29):** despite all wineserver-level operations succeeding
   (set_fd_disp_info=0, set_fd_name_info=0 on the relevant files),
   Ableton's Undo subsystem hits an internal timeout and displays
   "Failed to access Undo history file" + falls back to memory-based
   undo.  No correctness violation at the wineserver layer — but the
   timing variance trips an Ableton-side assumption.

The cross-thread bridge is the "simplest possible architecture" that
got Phase C off the ground for validation.  It's not the architecture
that works under real workloads.

## 3. Target architecture

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 540" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ta-bg { fill: #1a1b26; }
    .ta-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .ta-fast { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 8; }
    .ta-wait { fill: #1f2535; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .ta-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .ta-small { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .ta-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ta-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ta-violet { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ta-line { stroke: #c0caf5; stroke-width: 1.4; }
  </style>
  <defs>
    <marker id="taArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="940" height="540" class="ta-bg"/>
  <text x="470" y="28" text-anchor="middle" class="ta-title">Target architecture: aggregate-wait + inline CQE drain on the same RT thread</text>

  <rect x="260" y="70" width="420" height="78" class="ta-wait"/>
  <text x="470" y="96" text-anchor="middle" class="ta-violet">NTSYNC_IOC_AGGREGATE_WAIT</text>
  <text x="470" y="118" text-anchor="middle" class="ta-label">source[0] = channel object, source[1] = uring eventfd</text>
  <text x="470" y="136" text-anchor="middle" class="ta-small">one waiter, same dispatcher thread, PI-visible on the channel source</text>

  <rect x="80" y="198" width="300" height="132" class="ta-box"/>
  <text x="230" y="224" text-anchor="middle" class="ta-label">channel fired</text>
  <text x="230" y="248" text-anchor="middle" class="ta-small">1. CHANNEL_RECV2 consumes entry</text>
  <text x="230" y="266" text-anchor="middle" class="ta-small">2. run handler under existing global_lock discipline</text>
  <text x="230" y="284" text-anchor="middle" class="ta-small">3. sync handler replies immediately</text>
  <text x="230" y="302" text-anchor="middle" class="ta-small">4. async handler submits SQE and returns to wait</text>

  <rect x="560" y="198" width="300" height="132" class="ta-fast"/>
  <text x="710" y="224" text-anchor="middle" class="ta-green">uring eventfd fired</text>
  <text x="710" y="248" text-anchor="middle" class="ta-small">1. drain eventfd</text>
  <text x="710" y="266" text-anchor="middle" class="ta-small">2. nspa_uring_drain() runs inline on dispatcher</text>
  <text x="710" y="284" text-anchor="middle" class="ta-small">3. CQE callback finishes deferred work</text>
  <text x="710" y="302" text-anchor="middle" class="ta-small">4. CHANNEL_REPLY issued from the same RT thread</text>

  <line x1="470" y1="148" x2="230" y2="198" class="ta-line" marker-end="url(#taArrow)"/>
  <line x1="470" y1="148" x2="710" y2="198" class="ta-line" marker-end="url(#taArrow)"/>

  <rect x="230" y="390" width="480" height="74" class="ta-wait"/>
  <text x="470" y="416" text-anchor="middle" class="ta-violet">Loop invariant</text>
  <text x="470" y="438" text-anchor="middle" class="ta-small">the thread that receives the request is also the thread that drains the completion and signals the reply; no main-loop mediation remains in the async completion path</text>

  <line x1="230" y1="330" x2="230" y2="390" class="ta-line"/>
  <line x1="710" y1="330" x2="710" y2="390" class="ta-line"/>
  <line x1="230" y1="390" x2="470" y2="390" class="ta-line"/>
  <line x1="710" y1="390" x2="470" y2="390" class="ta-line"/>
</svg>
</div>

Properties:
- **Same RT thread** submits, drains, and replies.  No cross-thread
  latency, no scheduler boundary crossing within an async op.
- **Per-process io_uring** lifecycle bound to the dispatcher.  When the
  dispatcher exits (process termination), drain in-flight + close ring.
- **Single waiter on the ring** — no SINGLE_ISSUER concerns since
  there's exactly one submitter per ring.
- **CQE drain happens before next RECV is issued** — the dispatcher is
  always responsive, but completions are delivered in the order the
  kernel resolved them.

`main_loop_epoll` retires from the async-completion path entirely.

## 4. Kernel work — `NTSYNC_IOC_AGGREGATE_WAIT` (PI-aware)

### 4.0 Scope decision: one patch, not two

Earlier drafts of this plan split the kernel work into a narrow
gamma-specific wait extension plus a separate general
aggregate-wait patch. After clarifying gamma's role (RT/PI
propagation via the existing channel infrastructure) vs
aggregate-wait's role (general completion-handling primitive),
the gamma-specific extension is unnecessary:

- Gamma channel itself (patches 1004 / 1005 / 1007 / 1008 / 1009 —
  shipped) handles RT/PI for client-to-handler boost.  Not changing.
- `CHANNEL_RECV2` itself stays — dispatcher receives requests with PI
  semantics intact.
- For "wait on (channel, uring CQE) atomically", **aggregate-wait
  serves this case** with two ioctls per iteration (`AGGREGATE_WAIT`
  → `CHANNEL_RECV2` if channel fired) instead of one.  Slightly
  slower in the hot path but architecturally cleaner.
- The channel-extension hot-path optimization can be added LATER if
  measurements ever show the extra ioctl matters.  Probably won't —
  channel ioctls are microsecond-class, doubling them is still well
  below handler latency.

So: **one kernel patch, `NTSYNC_IOC_AGGREGATE_WAIT`, PI-aware**.
Smaller scope, smaller validation surface, fewer ABI shapes.

### 4.1 Existing ntsync patterns this work builds on

The ntsync module already has multiple precedents we should
mirror — none of this is greenfield infrastructure.  Key patterns
already in the kernel module (verify against
`ntsync-patches/ntsync.c.post1008` line numbers):

- **Object-type variants of an ioctl**: `WAIT_ANY` and `WAIT_ALL`
  share the same args struct + helper but differ in semantics.
  Same pattern fits a new aggregate-wait ioctl that shares the
  existing ntsync wait registration and cleanup machinery.

- **`ntsync_schedule()` (line ~2086)**: the existing combined-wait
  helper for WAIT_ANY/WAIT_ALL+uring_fd.  Wraps
  `wait_event_interruptible` with poll-wait registration on the
  uring fd.  This is the **direct template** for
  `ntsync_aggregate_wait()` — same shape, but generalized across
  multiple object and fd sources.

- **`uring_file = fget(args.uring_fd)` + `fput(uring_file)`**
  (lines ~2313, 2465 + similar): canonical resolve/release pattern
  for the optional uring fd parameter.  Copy verbatim.

- **Sentinel return shape for non-object wake reasons**: WAIT_ANY and
  WAIT_ALL already distinguish "an ntsync object fired" from "the
  uring side fired."  Aggregate-wait uses the same design principle,
  but with an explicit `NTSYNC_AGG_TIMEOUT` sentinel for deadline
  expiry while fd readiness still returns the actual source index.

- **Userspace fallback via `#ifndef`**: pattern in
  `server/nspa/shmem_channel.c` (lines ~84-115 post-2026-04-26)
  defines fallback structs and ioctl numbers when the running kernel
  pre-dates a feature.  We use the same pattern for old-kernel
  compatibility.

- **Pool + freelist with `pi_work` allocator pattern**: ntsync's
  PREEMPT_RT-safe alloc-hoist (patch 1006) uses a pre-allocated pool
  with a deferred-kfree helper.  Aggregate-wait's per-source wait
  table can use the same pattern.

- **`obj_lock(ch) ... obj_unlock(dev, obj, all)` discipline**:
  PREEMPT_RT-safe locking pattern — `obj_lock` is a raw spinlock,
  must not call sleeping primitives (kfree, schedule) under it.
  Both new ioctls follow this discipline.  The 1006 patch's
  alloc-hoist lessons (kfree under raw → use pi_work pool +
  deferred kfree) apply directly.

So this is patch 1010 in the existing 1004 / 1005 / 1006 / 1007 /
1008 / 1009 ntsync series.  The kernel module's existing patterns
largely prescribe how the new pieces are written — fewer novel
decisions than would be the case in a greenfield kernel feature.

### 4.2 Why aggregate-wait is the right abstraction

Per `wineserver-decomposition-plan.md` §2.2 spec, aggregate-wait
handles heterogeneous wait sources atomically:

- N ntsync objects (events, mutexes, semaphores, channels)
- M file descriptors (poll-style, with POLLIN/OUT/ERR/HUP semantics)
- Optional absolute deadline (clock_nanosleep ABSTIME semantics)

Wakeup conditions:
- Any source signals → return with `fired_index` indicating which
- Deadline expires → return with timeout indication
- Signal pending → return -ERESTARTSYS

**The full set of consumers** (across §8.6) means this primitive
deserves to be built once, correctly, with PI-awareness baked in
from the start — not bolted on later.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 500" xmlns="http://www.w3.org/2000/svg">
  <style>
    .aw-bg { fill: #1a1b26; }
    .aw-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .aw-fast { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .aw-kernel { fill: #1f2535; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .aw-note { fill: #2a1f14; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .aw-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .aw-small { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .aw-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .aw-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .aw-violet { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .aw-line { stroke: #c0caf5; stroke-width: 1.4; }
  </style>
  <defs>
    <marker id="awArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="940" height="500" class="aw-bg"/>
  <text x="470" y="28" text-anchor="middle" class="aw-title">Aggregate-wait as the common completion primitive</text>

  <rect x="60" y="88" width="230" height="110" class="aw-fast"/>
  <text x="175" y="114" text-anchor="middle" class="aw-green">object sources</text>
  <text x="175" y="140" text-anchor="middle" class="aw-label">events / mutexes / semaphores</text>
  <text x="175" y="158" text-anchor="middle" class="aw-small">channel object for gamma dispatcher</text>
  <text x="175" y="176" text-anchor="middle" class="aw-small">PI-visible wait registration</text>

  <rect x="355" y="88" width="230" height="110" class="aw-kernel"/>
  <text x="470" y="114" text-anchor="middle" class="aw-violet">NTSYNC_IOC_AGGREGATE_WAIT</text>
  <text x="470" y="140" text-anchor="middle" class="aw-label">copy source table, register waits, sleep once</text>
  <text x="470" y="158" text-anchor="middle" class="aw-small">return fired_index + fired_events or timeout sentinel</text>
  <text x="470" y="176" text-anchor="middle" class="aw-small">cleanup unregister path mirrors WAIT_ANY / WAIT_ALL</text>

  <rect x="650" y="88" width="230" height="110" class="aw-box"/>
  <text x="765" y="114" text-anchor="middle" class="aw-label">fd sources</text>
  <text x="765" y="140" text-anchor="middle" class="aw-label">uring eventfd / future polling fds</text>
  <text x="765" y="158" text-anchor="middle" class="aw-small">poll registration, no PI semantics</text>
  <text x="765" y="176" text-anchor="middle" class="aw-small">return actual source index on readiness</text>

  <line x1="290" y1="143" x2="355" y2="143" class="aw-line" marker-end="url(#awArrow)"/>
  <line x1="650" y1="143" x2="585" y2="143" class="aw-line" marker-end="url(#awArrow)"/>

  <rect x="110" y="280" width="720" height="114" class="aw-note"/>
  <text x="470" y="306" text-anchor="middle" class="aw-label">Immediate and deferred consumers</text>
  <text x="470" y="332" text-anchor="middle" class="aw-small">Phase C dispatcher async completion now</text>
  <text x="470" y="350" text-anchor="middle" class="aw-small">timer-thread and fd-poll decomposition work later</text>
  <text x="470" y="368" text-anchor="middle" class="aw-small">IOCP-style completion waits and multi-op handler flows after that</text>
</svg>
</div>

### 4.3 ABI

```c
/* include/uapi/linux/ntsync.h additions */

struct ntsync_aggregate_source {
    __u32 type;              /* NTSYNC_AGG_OBJECT | NTSYNC_AGG_FD */
    __u32 events;            /* if FD: POLLIN/POLLOUT/POLLERR/POLLHUP bits */
    __u64 handle_or_fd;      /* ntsync object handle, or unix fd */
};

struct ntsync_aggregate_wait_args {
    __u32 nb_sources;        /* count of entries in sources[] (max 64) */
    __u32 reserved;
    __u64 sources;           /* user pointer to ntsync_aggregate_source[] */
    struct __kernel_timespec deadline;  /* CLOCK_MONOTONIC ABSTIME, or {0,0} */
    __u32 fired_index;       /* OUT: index of firing source (0..nb-1), or sentinel */
    __u32 fired_events;      /* OUT: for FD type, the POLL* bits that fired */
    __u32 flags;             /* IN: NTSYNC_AGG_FLAG_* (see below) */
    __u32 owner;             /* IN: tid for PI-aware mutex sources, 0 if none */
};

#define NTSYNC_AGG_OBJECT    0x1
#define NTSYNC_AGG_FD        0x2
#define NTSYNC_AGG_MAX       64

/* flags */
#define NTSYNC_AGG_FLAG_REALTIME  0x1   /* match WAIT_ANY's NTSYNC_WAIT_REALTIME */

/* fired_index sentinel for deadline expiry */
#define NTSYNC_AGG_TIMEOUT       0xFFFFFFFFu

#define NTSYNC_IOC_AGGREGATE_WAIT  _IOWR('N', 0x95, struct ntsync_aggregate_wait_args)
```

ABI notes:
- 64 sources max matches existing `NTSYNC_MAX_WAIT_COUNT`
- Sources are passed by user pointer to allow stable per-call array
  (kernel copies in, validates types/handles, registers waits)
- `deadline` mirrors WAIT_ANY's timeout shape — `{0, 0}` means
  no deadline; non-zero is `CLOCK_MONOTONIC` absolute time
- `owner` field carries the calling tid for PI-aware sources
  (mutex/event with PI semantics) — the boost target on the kernel
  side knows whose priority to inherit

### 4.4 PI-awareness — load-bearing requirement

This is the design point that makes aggregate-wait usable for the
gamma dispatcher (the immediate consumer).  Without PI propagation,
gamma's `CHANNEL_SEND_PI` from a high-priority client would not boost
an aggregate-waiter blocked on the channel as one of N sources, and
RT correctness collapses.

The implementation must ensure that for each `NTSYNC_AGG_OBJECT`
source the wait registers the caller in **the same wait queue** the
existing per-object PI-find-target code already walks.  Specifically:

- `WAIT_ANY` extends `ntsync_obj.q.waiters` (or equivalent) with each
  waiter; `ntsync_event_set_pi` walks the same list and boosts.
- Aggregate-wait must register against the same list — not a new
  parallel list — so existing PI logic finds aggregate-waiters
  without modification.

For mutex sources specifically (where PI inheritance is mandatory),
the existing `ntsync_pi_recalc()` (post-1006 alloc-hoist patch) walks
mutex waiters and recomputes the inherited priority.  Aggregate-
waiters must be visible to that walk.

**Validation:** ntsync sub-test that issues a low-priority
aggregate-wait on (channel, fd), then a high-priority
`CHANNEL_SEND_PI` from another thread, then checks via `chrt -p
$tid` (or kernel-side instrumentation) that the aggregate-waiter's
effective priority was boosted to the sender's priority.  Same
check the existing channel patches' PI tests perform — copy that
test pattern.

For `NTSYNC_AGG_FD` sources, no PI propagation — fd readiness is
edge-triggered with no notion of priority owner.  The kernel's poll
machinery wakes whoever's waiting; if a higher-priority task is
also waiting on the fd, scheduler picks it up.  No special handling.

### 4.5 Implementation shape

Builds on the existing WAIT_ANY uring_fd extension's poll-wait
infrastructure (`ntsync_schedule()` in `ntsync.c.post1008` ~line 2086).
For each source in the user-supplied array:

- `NTSYNC_AGG_OBJECT`: same registration as `WAIT_ANY` does for
  individual ntsync objects — `ntsync_lock_obj`,
  `try_wake_any_obj` (peek), add to obj's wait queue
- `NTSYNC_AGG_FD`: register a poll wait on the fd via `vfs_poll`
  with a poll table that wakes the aggregate wait queue when any
  requested events fire

The wait condition (for `WAIT_ANY`-equivalent semantics):

```c
for (;;) {
    set_current_state(TASK_INTERRUPTIBLE);
    /* Check object sources */
    for (i = 0; i < nb_obj_sources; i++)
        if (atomic_read(&obj_qe[i].signaled) != -1) goto fired;
    /* Check fd sources */
    for (i = 0; i < nb_fd_sources; i++)
        if (vfs_poll_peek(fd_files[i], fd_events[i])) goto fired;
    /* Pending signal? */
    if (signal_pending(current)) { ret = -ERESTARTSYS; break; }
    /* Deadline check via hrtimer on schedule */
    schedule();
}
```

Mirrors `ntsync_schedule()`'s structure exactly; the only delta is
multiple sources of each kind instead of one.

Cleanup on unblock: walk both source arrays, deregister each from
its respective wait queue.  Same lock-discipline as WAIT_ANY's
unqueue path (`unqueue:` label in current code).

### 4.6 Files to modify

In `drivers/misc/ntsync.c`:
- New `ntsync_aggregate_wait()` ioctl handler (~150-200 LOC)
- New helpers `ntsync_aggregate_register_obj()` and
  `_register_fd()` (~30 LOC each)
- New `ntsync_aggregate_unregister_all()` cleanup helper (~20 LOC)
- Add ioctl dispatch case for `NTSYNC_IOC_AGGREGATE_WAIT`

In `include/uapi/linux/ntsync.h`:
- Add `struct ntsync_aggregate_source`,
  `struct ntsync_aggregate_wait_args`
- Add `NTSYNC_AGG_*` constants and `NTSYNC_IOC_AGGREGATE_WAIT`
- Add `NTSYNC_AGG_FLAG_REALTIME` and `NTSYNC_AGG_TIMEOUT` sentinel

### 4.7 Testing the primitive

In `programs/nspa_rt_test/main.c`, add `cmd_aggregate_wait`
subcommand with sub-tests:

```
sub-test 1  basic — wait on (event, eventfd), signal each
sub-test 2  timeout — empty sources + deadline, verify AGG_TIMEOUT
sub-test 3  PI propagation — low-prio waiter on (channel, fd),
            high-prio SEND_PI, verify chrt-visible boost
sub-test 4  32-source stress — random signals, fired_index always
            valid signaling source
sub-test 5  mixed obj+fd — alternating signals, both types work,
            fired_events bits correct for fd type
sub-test 6  cancel via signal — caller killed mid-wait, clean
            unregister + no leaked waitqueue entries (KASAN)
```

KASAN debug kernel stress: 1M iterations of sub-tests 1+4+5
alternating; zero splats required.  Same protocol as 2026-04-27
channel session that caught 4 latent bugs.

### 4.8 Estimated scope

- Kernel: ~250-300 LOC in `drivers/misc/ntsync.c`
- Header: ~30 LOC in `include/uapi/linux/ntsync.h`
- Userspace test: ~250 LOC in `nspa_rt_test`
- Patch file: `ntsync-patches/1010-ntsync-aggregate-wait.patch`
- 2-3 sessions for kernel + tests + KASAN validation


## 5. Userspace restructure — per-process ring

### 5.1 Data structures

The new per-channel `struct nspa_uring_instance` holds the ring,
its eventfd, and the pending pool.  Owned by `shmem_channel.c`,
one per gamma channel (effectively one per Wine process).

```c
/* server/nspa/uring.h — new public API */

struct nspa_uring_pending;     /* opaque, defined in uring.c */

typedef void (*nspa_uring_callback_fn)(void *ctx, int result);

struct nspa_uring_instance {
    struct io_uring             ring;
    int                          ring_fd;       /* ring->ring_fd, cached */
    int                          eventfd;       /* registered with ring for ntsync_wait */
    int                          active;
    /* Pending pool */
    struct nspa_uring_pending   *pool;          /* fixed array, size = NSPA_URING_RING_SIZE */
    struct nspa_uring_pending   *free_head;
    unsigned int                 inflight;
};

extern int  nspa_uring_instance_init(struct nspa_uring_instance *u);
extern void nspa_uring_instance_shutdown(struct nspa_uring_instance *u);
extern void nspa_uring_drain(struct nspa_uring_instance *u);
extern struct nspa_uring_pending *nspa_uring_pending_alloc(
    struct nspa_uring_instance *u, nspa_uring_callback_fn cb, void *ctx);
extern void nspa_uring_pending_free(struct nspa_uring_instance *u,
                                     struct nspa_uring_pending *p);
extern struct io_uring_sqe *nspa_uring_get_sqe(struct nspa_uring_instance *u);
extern int  nspa_uring_submit(struct nspa_uring_instance *u);
extern int  nspa_uring_get_eventfd(struct nspa_uring_instance *u);

/* Deferred reply (unchanged signature, but now invoked from dispatcher
 * pthread context with the dispatcher's process context) */
extern void nspa_uring_defer_reply(struct thread *thread);
extern void nspa_uring_signal_reply(struct thread *thread,
                                     struct request_shm *request_shm,
                                     unsigned int data_size,
                                     int channel_fd,
                                     unsigned long long entry_id);
```

The old global-state-based API (`nspa_uring_init()`,
`nspa_uring_get_fd()`, etc.) goes away.

`server/nspa/shmem_channel.c` holds one `nspa_uring_instance` per
process, alongside `process->request_channel_fd`:

```c
/* In server/nspa/shmem_channel.h or process.h — depending on where
 * struct process is defined. */
struct process {
    /* ... existing fields ... */
    int                          request_channel_fd;
    struct nspa_uring_instance   nspa_uring;       /* zero-initialised; init lazily */
};
```

### 5.2 Ring init / shutdown

Init runs from `nspa_shmem_channel_init` (after the channel is created
but before the dispatcher pthread starts):

```c
void nspa_shmem_channel_init(struct process *process)
{
    /* ... existing channel setup ... */

    /* Initialise the per-process io_uring.  Failure is non-fatal —
     * dispatcher falls back to no-uring (legacy CHANNEL_RECV2). */
    if (nspa_uring_instance_init(&process->nspa_uring) < 0)
    {
        if (debug_level)
            fprintf(stderr, "nspa: process pid=%d uring init failed, "
                    "async-completing handlers will fall back to sync\n",
                    process->id);
    }

    /* Spawn dispatcher pthread (existing code). */
    /* ... */
}
```

`nspa_uring_instance_init`:
1. Calls `io_uring_queue_init_params(64, &u->ring, &params)` with
   `params.flags = 0` (multi-issuer-safe; the ring has only one
   submitter — the dispatcher pthread — but no SINGLE_ISSUER means we
   don't pin TID).
2. Probes `IORING_OP_OPENAT` support (existing code).
3. Creates an eventfd via `eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC)`,
   stores in `u->eventfd`.
4. Calls `io_uring_register_eventfd(&u->ring, u->eventfd)` so CQE
   arrivals signal the eventfd. The aggregate-wait fd source then
   polls this eventfd.
5. Initialises the pending pool (linked freelist).

Shutdown runs from `nspa_shmem_channel_destroy`:
1. Drain all in-flight CQEs (call `nspa_uring_drain` until inflight==0
   or timeout).
2. Close eventfd.
3. `io_uring_queue_exit(&u->ring)`.

### 5.3 Dispatcher loop — full rewrite

Current `nspa_shmem_channel_pthread` (verbatim from
`server/nspa/shmem_channel.c` post-2026-04-26, lines ~120-235):

```c
static void *nspa_shmem_channel_pthread(void *arg)
{
    struct process *process = arg;
    int channel_fd = process->request_channel_fd;
    /* ... cached_use_token, recv2_state setup ... */

    for (;;) {
        struct ntsync_channel_recv2_args recv;
        int ret;

        if (recv2_state == 1) {
            ret = ioctl(channel_fd, NTSYNC_IOC_CHANNEL_RECV2, &recv);
            /* ... fallback handling ... */
        } else {
            /* ... legacy RECV ... */
        }
        if (ret < 0) {
            if (errno == EBADF) break;  /* channel closed */
            continue;
        }

        pi_mutex_lock(&global_lock);

        /* resolve thread, run handler, write reply */
        /* ... */

        pi_mutex_unlock(&global_lock);

        /* unconditional CHANNEL_REPLY (today; gated on deferred flag
         * post-Phase-C) */
        ioctl(channel_fd, NTSYNC_IOC_CHANNEL_REPLY, &entry_id);
    }
    return NULL;
}
```

Restructured to use aggregate-wait + separate CHANNEL_RECV2 (verbose
to be implementable from this doc alone):

```c
static void *nspa_shmem_channel_pthread(void *arg)
{
    struct process *process = arg;
    int dev_fd = get_inproc_device_fd();
    int channel_fd = process->request_channel_fd;
    obj_handle_t channel_handle = process->request_channel_obj_handle; /* see note */
    int uring_eventfd = nspa_uring_get_eventfd(&process->nspa_uring);
    int agg_supported = -1;  /* lazy-detect: 1=use aggregate-wait, 0=legacy fallback */
    /* ... cached_use_token, recv2_state setup unchanged ... */

    for (;;) {
        struct ntsync_aggregate_wait_args agg;
        struct ntsync_aggregate_source srcs[2];
        struct ntsync_channel_recv2_args recv;
        struct thread *thread = NULL;
        int ret;
        int channel_fired;

        if (agg_supported != 0 && uring_eventfd >= 0) {
            /* Aggregate-wait path: wait atomically on (channel, uring) */
            srcs[0].type         = NTSYNC_AGG_OBJECT;
            srcs[0].events       = 0;
            srcs[0].handle_or_fd = channel_handle;
            srcs[1].type         = NTSYNC_AGG_FD;
            srcs[1].events       = POLLIN;
            srcs[1].handle_or_fd = uring_eventfd;

            memset(&agg, 0, sizeof(agg));
            agg.nb_sources = 2;
            agg.sources    = (uintptr_t)srcs;
            agg.flags      = NTSYNC_AGG_FLAG_REALTIME;
            agg.owner      = gettid();   /* for PI propagation target */

            ret = ioctl(dev_fd, NTSYNC_IOC_AGGREGATE_WAIT, &agg);
            if (ret < 0 && errno == ENOTTY) {
                /* Pre-1010 kernel — fall back to legacy CHANNEL_RECV2
                 * (no uring integration; Phase C handlers won't work). */
                agg_supported = 0;
                continue;
            }
            if (ret < 0) {
                if (errno == EBADF || errno == EINTR) break;
                continue;
            }

            channel_fired = (agg.fired_index == 0);

            /* ====== Uring CQE source fired — drain inline ====== */
            if (!channel_fired) {
                /* Drain the eventfd to disarm POLLIN, then drain CQEs */
                uint64_t evfd_val;
                read(uring_eventfd, &evfd_val, sizeof(evfd_val));
                pi_mutex_lock(&global_lock);
                nspa_uring_drain(&process->nspa_uring);
                pi_mutex_unlock(&global_lock);
                continue;
            }

            /* Channel source fired — fall through to RECV2 below */
        }

        /* RECV the actual channel entry.  Same code as today; the
         * preceding aggregate-wait just told us the channel is non-empty. */
        if (recv2_state == 1) {
            ret = ioctl(channel_fd, NTSYNC_IOC_CHANNEL_RECV2, &recv);
            /* ... existing fallback to legacy RECV ... */
        } else {
            /* legacy RECV path — unchanged */
            ret = ioctl(channel_fd, NTSYNC_IOC_CHANNEL_RECV, &recv1);
            /* ... copy recv1 → recv (existing fallback shape) ... */
        }

        if (ret < 0) {
            /* Race: aggregate-wait said channel-fired but RECV2 is
             * empty (another consumer raced — shouldn't happen with
             * one dispatcher pthread, but defensive). */
            if (errno == EAGAIN) continue;
            if (errno == EBADF) break;
            continue;
        }

        /* ====== Normal channel entry ====== */
        pi_mutex_lock(&global_lock);

        /* Resolve thread (existing thread_token / get_thread_from_id
         * dance — unchanged) */
        /* ... */

        if (thread && thread->process->request_channel_fd == channel_fd
            && thread->request_shm) {
            /* Stash entry_id for async handler use (existing pattern) */
            thread->nspa_channel_entry_id = recv.entry_id;
            __atomic_thread_fence(__ATOMIC_SEQ_CST);
            read_request_shm(thread, (struct request_shm *)thread->request_shm);
            __atomic_thread_fence(__ATOMIC_SEQ_CST);
        }

        /* Defer-reply check (existing pattern from c7edac9c3d7) */
        {
            int deferred = (thread && thread->nspa_async_reply_deferred);
            pi_mutex_unlock(&global_lock);

            if (!deferred) {
                __u64 entry_id = recv.entry_id;
                ioctl(channel_fd, NTSYNC_IOC_CHANNEL_REPLY, &entry_id);
            }
            /* If deferred, the CQE callback will signal CHANNEL_REPLY
             * when the async op completes — during a later
             * aggregate-wait wake on this same dispatcher thread. */
        }

        if (poll_generation != generation) force_exit_poll();
    }
    return NULL;
}
```

Note about `channel_handle`: the gamma channel is created via
`NTSYNC_IOC_CREATE_CHANNEL` (returns a fd, currently
`process->request_channel_fd`).  For aggregate-wait, we need an
ntsync object handle that refers to the channel.  Either:
- Add an ioctl to fetch a channel-object handle from the channel fd
- OR pass the channel fd as the source handle and have aggregate-wait's
  kernel side accept either fd-style or handle-style references for
  ntsync sources

The latter is simpler — we already pass an fd for `NTSYNC_AGG_FD`
sources, and channel registration via fd is consistent with
gamma's `request_channel_fd` storage shape.  Recommend: aggregate-wait
accepts an ntsync-object-fd in `handle_or_fd` for `NTSYNC_AGG_OBJECT`
sources, looks up the underlying object, registers wait against it.

Two ioctls per dispatch instead of one:
1. `NTSYNC_IOC_AGGREGATE_WAIT` — atomic wait on (channel, uring)
2. `NTSYNC_IOC_CHANNEL_RECV2` — actually consume the entry

Microsecond-class overhead each.  Not the hot-path concern people
might think — channel ioctls themselves are microsecond-class, total
RECV cycle stays in the microsecond range either way.

Key invariants preserved:
- `pi_mutex_lock(&global_lock)` discipline unchanged
- Thread-token plumbing unchanged (still via CHANNEL_RECV2)
- `nspa_async_reply_deferred` flag unchanged
- Force-exit-poll wakeup unchanged
- PI propagation: SEND_PI from a high-priority client boosts the
  aggregate-waiter via the channel object's wait queue (per §4.4
  PI-awareness requirement)

What's new:
- Aggregate-wait sees both channel and uring as sources atomically
- Uring-fired branch drains CQEs inline on the same RT thread
- Channel-fired branch follows up with RECV2 to consume the entry
- Pre-1010 kernel fallback: skip aggregate-wait, go straight to
  RECV2 — Phase C async won't work but sync handlers do

### 5.4 CQE callback context — what changed

CQE callback is called from `nspa_uring_drain()`, which now runs in
the dispatcher pthread (not main loop).  Implications:

- `current` is whatever the previous handler set it to (probably
  cleared to NULL by `call_req_handler_shm` already).  Callback
  saves/restores as before.
- `global_lock` is held by the dispatcher when drain runs.  Existing
  `nspa_uring_signal_reply` discipline holds.
- The callback runs at SCHED_FIFO @ nspa_srv_rt_prio (dispatcher's
  priority) — *better* than today's main-loop drain.
- CHANNEL_REPLY ioctl is issued from the dispatcher pthread (was
  main loop previously).  Same ioctl, different thread context.

The `uring_create_file.c` CQE callback signature and body are
unchanged — `current` save/restore, error-mapping, post-openat
work via `create_inode_fd_from_unix_fd`, then `signal_reply`.  It
just runs on a different thread now.

### 5.5 Removed / simplified components

After this restructure:
- `server/nspa/uring.c::nspa_uring_init()` — gone (was global state)
- `server/nspa/uring.c::nspa_uring_get_fd()` — gone (no longer needed)
- `server/main.c` `nspa_uring_init()` call — gone
- `server/fd.c::init_epoll()` uring fd registration — gone (~15 LOC)
- `server/fd.c::main_loop_epoll()` URING_USER sentinel branch — gone
  (~10 LOC)

Net LOC delta: probably -30 / +200 (removed sketchy bridge, replaced
with cleaner per-instance state).

### 5.6 Compatibility

If running against a pre-1010 kernel (no
`NTSYNC_IOC_AGGREGATE_WAIT`), the dispatcher detects `-ENOTTY`,
marks aggregate-wait unsupported for that process, and falls back to
the synchronous channel-only path. Phase C handlers then stay sync.
No regression.

### 5.7 Estimated scope

- Refactor `server/nspa/uring.{c,h}`: ~200 LOC (mostly mechanical
  s/g_ring/u->ring/ s/g_pool/u->pool/)
- Refactor `server/nspa/shmem_channel.c`: ~80 LOC (uring init +
  dispatcher loop URING_READY branch)
- Modify `struct process`: +1 field (`struct nspa_uring_instance`)
- Strip `main_loop_epoll` integration: -25 LOC across `fd.c`, `main.c`
- `uring_create_file.c`: unchanged (CQE callback body), ~5 LOC for
  context shift (different thread)
- Total: ~250 LOC delta, 1-2 sessions of focused work after the
  kernel patch lands

## 6. Migration phasing

Suggested implementation ladder. Each phase is independently testable
and revertable.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 620" xmlns="http://www.w3.org/2000/svg">
  <style>
    .mp-bg { fill: #1a1b26; }
    .mp-phase { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .mp-kernel { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .mp-risk { fill: #2a1f14; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .mp-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .mp-small { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .mp-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .mp-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .mp-yellow { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .mp-line { stroke: #c0caf5; stroke-width: 1.4; }
  </style>
  <defs>
    <marker id="mpArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="940" height="620" class="mp-bg"/>
  <text x="470" y="28" text-anchor="middle" class="mp-title">Implementation ladder</text>

  <rect x="110" y="70" width="720" height="62" class="mp-risk"/>
  <text x="470" y="96" text-anchor="middle" class="mp-yellow">Phase 0</text>
  <text x="470" y="116" text-anchor="middle" class="mp-label">remove the cross-thread bridge, keep only independent correctness fixes</text>

  <rect x="110" y="168" width="720" height="72" class="mp-kernel"/>
  <text x="470" y="194" text-anchor="middle" class="mp-green">Phase 1</text>
  <text x="470" y="214" text-anchor="middle" class="mp-label">land `NTSYNC_IOC_AGGREGATE_WAIT` + tests + KASAN validation</text>
  <text x="470" y="232" text-anchor="middle" class="mp-small">standalone kernel primitive, no wineserver consumer yet</text>

  <rect x="110" y="276" width="720" height="72" class="mp-phase"/>
  <text x="470" y="302" text-anchor="middle" class="mp-label">Phase 2</text>
  <text x="470" y="322" text-anchor="middle" class="mp-label">per-process `nspa_uring_instance` infrastructure</text>
  <text x="470" y="340" text-anchor="middle" class="mp-small">dispatcher-owned ring exists, but nothing submits to it yet</text>

  <rect x="110" y="384" width="720" height="72" class="mp-phase"/>
  <text x="470" y="410" text-anchor="middle" class="mp-label">Phase 3</text>
  <text x="470" y="430" text-anchor="middle" class="mp-label">dispatcher loop switches to aggregate-wait + inline CQE drain</text>
  <text x="470" y="448" text-anchor="middle" class="mp-small">channel branch and uring branch now live on the same RT thread</text>

  <rect x="110" y="492" width="720" height="72" class="mp-phase"/>
  <text x="470" y="518" text-anchor="middle" class="mp-label">Phases 4-6</text>
  <text x="470" y="538" text-anchor="middle" class="mp-label">re-port async `create_file`, then run Ableton and long-soak validation</text>
  <text x="470" y="556" text-anchor="middle" class="mp-small">first real consumer proves the primitive under workload</text>

  <line x1="470" y1="132" x2="470" y2="168" class="mp-line" marker-end="url(#mpArrow)"/>
  <line x1="470" y1="240" x2="470" y2="276" class="mp-line" marker-end="url(#mpArrow)"/>
  <line x1="470" y1="348" x2="470" y2="384" class="mp-line" marker-end="url(#mpArrow)"/>
  <line x1="470" y1="456" x2="470" y2="492" class="mp-line" marker-end="url(#mpArrow)"/>
</svg>
</div>

### Phase 0: remove the current cross-thread Phase C bridge

Before landing the new structure, remove the main-loop-owned server
io_uring bridge that drains CQEs on a different thread from the one
that received the request. The important boundary here is architectural,
not historical:

- Remove the global server-side io_uring ownership model tied to
  `main_loop_epoll`.
- Remove the cross-thread deferred-reply path that turns CQE wakeup
  into main-thread-owned `CHANNEL_REPLY`.
- Retain independent fixes that are still valid outside that bridge,
  such as the `/proc/self/fd`-based `unix_name` resolution and the
  local-file directory helper cleanups.

After this phase, the tree is back to synchronous handler completion
plus the unrelated file-path fixes that remain correct on their own.

### Phase 1: kernel patch 1010 — `NTSYNC_IOC_AGGREGATE_WAIT`

Files:
- `drivers/misc/ntsync.c` — new `ntsync_aggregate_wait()` ioctl
  handler + register/unregister helpers (per §4.5/4.6)
- `include/uapi/linux/ntsync.h` — new ABI structs + ioctl number
  (per §4.3)
- `ntsync-patches/1010-ntsync-aggregate-wait.patch` — patch file
  in tree

Build: per `reference_ableton_rt_test_recipe.md`:
```bash
cd /home/ninez/pkgbuilds/Linux-NSPA-pkgbuild/linux-nspa-debug
makepkg -s   # or module-only build per existing recipe
```

Validate (KASAN debug kernel — see §7.1):
- `nspa_rt_test ntsync` existing tests PASS (no regression)
- New `nspa_rt_test aggregate-wait` 6/6 PASS (per §4.7)
- PI-propagation sub-test critical — verifies the design
  requirement in §4.4 holds end-to-end
- `run-rt-suite native` 1M-iter stress with aggregate-wait
  patterns, 0 KASAN splats
- Production-kernel rerun after KASAN passes — confirms no
  RT/timing regression

Standalone primitive — no userspace consumers yet in this phase.
Validates the ABI + PI semantics + KASAN-clean implementation
before any wineserver code starts using it.

### Phase 2: per-process uring infrastructure (userspace, no callers)

Files modified:
- `server/nspa/uring.{c,h}` — refactor global state to per-instance
  `struct nspa_uring_instance` (per §5.1)
- `server/process.h` (or wherever struct process is defined) — add
  `struct nspa_uring_instance nspa_uring` field
- `server/nspa/shmem_channel.c` — call
  `nspa_uring_instance_init(&process->nspa_uring)` from
  `nspa_shmem_channel_init`; teardown from `..._destroy`

Behaviour: each gamma-channel-having process now owns its own ring,
but no one submits to it yet.  Server boots, dispatcher loop is
unchanged from pre-Phase-C, no regression.

Validation: smoke (`wineserver -d3 ableton`), check
`nspa_uring instance initialised` log lines per-process at debug
level.

### Phase 3: dispatcher loop refactor

File modified: `server/nspa/shmem_channel.c::nspa_shmem_channel_pthread`.

Behaviour: dispatcher calls `NTSYNC_IOC_AGGREGATE_WAIT` on
`(channel object, uring eventfd)` and follows a channel-fired wake
with `CHANNEL_RECV2`. The uring-fired branch drains CQEs inline.
No submitters exist yet, so only the channel branch should fire in
normal smoke, but both wake paths can be exercised synthetically.

Validation:
- Smoke: server boots, sync handlers still work, Ableton runs OFF
  (no Phase C handler) clean
- Synthetic stress: `nspa_rt_test channel-stress-with-uring` (new
  sub-test that submits NOP via the process's ring + pumps channel
  traffic, verifies both wake paths work)

### Phase 4: re-port `create_file` handler

Files restored:
- `server/nspa/uring_create_file.{c,h}` — restored from prior commit,
  but ctx now references `process->nspa_uring` instead of global
- `server/file.c::DECL_HANDLER(create_file)` — try_async dispatch
  pre-sync (existing pattern)
- `server/Makefile.in` — re-add source

CQE callback body unchanged (the 5 validation fixes — entry_id,
map_access, st_mode, /proc/self/fd, etc. — all stay).  Only the
ring/pool reference changes from global to per-process.

Re-introduce `nspa_rt_test create-file` (5 sub-tests as before).

Validation:
- 5/5 PASS in all gate states (gate-OFF, gate-ON, NSPA_DISABLE_SERVER_URING)
- Smoke under KASAN debug kernel
- Smoke under production kernel

### Phase 5: Ableton validation — the regression target

Same protocol as before but now under correct architecture:

```bash
sudo make install
/tmp/start-wineserver.sh on   # gate ON
sudo /tmp/midi-trace.sh        # capture
# Launch Ableton, full workload (boot → demo → drum-track-load-while-
# playing for ≥10 minutes)
```

Pass criterion (the bug-class we couldn't crack with cross-thread):
- No "Failed to access Undo history file" dialog
- No "There was an error when closing the file ... Undo\0.band"
- Audio / drums / playback functional
- Clean exit

If pass: flip `NSPA_ENABLE_ASYNC_CREATE_FILE` default to ON in a
follow-up commit.

### Phase 6: long-soak + memory update

- ≥1 hour Ableton playback under gate-ON, watching for accumulated
  wake noise, fd leaks, RT slip
- Multi-process stress: 2 Wine apps concurrently, each with their own
  per-process ring
- Update `MEMORY.md` index with the new architecture state
- Update `wineserver-decomposition-plan.md` §5 phasing to reflect
  what's now landed (§3.2 router/handler effectively done as part of
  this; §3.3 FD polling split becomes much smaller)

### Aggregate-wait deferred consumers (NOT in this scope)

Phase 1 lands the primitive; concrete consumers (decomp §3.1 timer
thread, §3.3 FD polling thread) are separate sessions.  They will
land on top of this work.

## 7. Validation strategy

### 7.1 KASAN debug kernel — non-negotiable for the kernel patches

ALL kernel-side validation of patch 1010 MUST run under
the KASAN debug kernel build.  This is the same discipline that
caught 4 latent bugs in the channel extension during the
2026-04-27 ntsync session (memory:
`project_ntsync_session_20260427_results.md`):

1. Test cleanup asymmetry stranding waiters
2. Channel exclusive RECV bug (1007 fix)
3. EVENT_SET_PI deferred boost UAF (1008 fix)
4. Channel entry refcount UAF (1009 fix)

None of these would have surfaced without KASAN — they're
slab-corruption / use-after-free patterns that only manifest under
the instrumentation.

**Setup:**

```bash
# Reference path: linux-nspa-debug build (per project_linux_nspa_debug_handoff.md)
cd /home/ninez/pkgbuilds/Linux-NSPA-pkgbuild/linux-nspa-debug
# Build kernel (or pull existing build if still on disk)
makepkg -s
sudo pacman -U linux-nspa-debug-*.pkg.tar.zst
# Reboot into debug kernel
```

**Verify KASAN active before testing:**
```bash
zgrep CONFIG_KASAN /proc/config.gz   # CONFIG_KASAN=y
dmesg | grep -i kasan | head         # KASAN initialization line
```

**Validation runs under KASAN:**
- All native ntsync sub-tests (existing 4-test suite + new
  aggregate-wait sub-tests)
- 22/22 PE matrix from `nspa_rt_test ntsync`
- 5-minute mixed-load stress (events + mutex + sem + chan + wait_all)
- Aggregate-wait specific: random-source signaling with 32 sources,
  1M iterations
- Deliberate negative tests: bad fd source (-EBADF), unsupported
  source shape, multiple
  threads racing the same channel (already covered by 1007 but
  re-validate)
- Watch for: KASAN "use-after-free", "out-of-bounds", "double-free"
  splats; lockdep "circular dependency"; refcount warnings

**Pass criterion:** zero KASAN/lockdep splats across all runs.  Per
the prior ntsync session, multiple distinct bugs fired under KASAN
that didn't fire on the production kernel — we expect the same here
for any subtle issue in the new wait paths.

If a KASAN splat fires:
- Capture the full splat (`dmesg | grep -A50 'KASAN'`)
- Identify the freed allocation site and the use-after-free site
- Pattern: most ntsync bugs trace to slab UAF in a wait/wake race
  — fix via refcount on the affected struct, not by trying to
  serialise the race differently (1009 lesson)

### 7.2 Per-phase smoke

Each phase's commit has its own validation:
- Phase 1 (kernel patch aggregate-wait): standalone aggregate-wait
  unit + KASAN stress (per §7.1)
- Phase 2 (per-process ring infra): wineserver boots, no handler
  regression (no submitters)
- Phase 3 (dispatcher loop refactor): wineserver boots, gamma RECV
  still works for sync handlers, sync-only Ableton run clean
- Phase 4 (re-port create_file handler): PE test passes, Ableton
  boots gate-ON

### 7.3 The big test

Ableton gate-ON full soak that the cross-thread bridge couldn't pass.
Specifically: the Undo subsystem behaviour (Undo.lock, Undo\0.band
write+rename pattern) must NOT trigger the "Failed to access Undo
history file" dialog.  This is the regression target that defines
"Phase C is shippable."

### 7.4 Long-horizon stress

- Plugin scan storm (open hundreds of DLLs/assets in seconds)
- Drum-track-load-while-playing (the historical xrun stress)
- Long uptime (≥1 hour playback) to surface accumulated state drift
- Multiple processes (run two Wine apps concurrently — exercises
  per-process ring isolation)
- Run on production kernel AFTER KASAN validation passes — KASAN
  itself adds latency that hides timing-class bugs.  Production-
  kernel run validates RT/timing properties; KASAN run validates
  memory-safety.  Both are needed.

### 7.5 Validation cadence (mirrors the 2026-04-27 session)

Per `project_ntsync_session_20260427_results.md`:
1. Native test under KASAN debug kernel: `run-rt-suite native`
   loop until clean (target: 1M ops zero splats)
2. PE test under KASAN: 22/22 matrix
3. 5-minute mixed-load soak
4. Switch to production kernel, re-validate non-debug
5. Ableton soak under production kernel
6. Long-soak (≥1 hour)
7. Only flip default-on after all 6 stages pass

This ladder is the same discipline that gave us the
A250A77651C8D5DAB719FE2 module srcversion from the 2026-04-27 work,
which is the current installed module.  We're adding to that
established work, not starting over.

## 8. Wider architectural implications

### 8.1 Validates the aggregate-wait pattern

`wineserver-decomposition-plan.md` §2.2 specifies an
`NTSYNC_IOC_AGGREGATE_WAIT` ioctl that waits on heterogeneous sources
(ntsync objects + fds + timer). This work is that primitive made
concrete: the Phase C dispatcher becomes the first real consumer,
and later decomposition steps reuse the same shape instead of growing
their own bespoke wait glue.

### 8.2 Foundation for multiple async-completing handlers

Once the per-dispatcher ring exists, ANY handler in `server/nspa/` can
async-complete via the same machinery.  Candidates from earlier perf
data:
- `realpath` (1.42% of wineserver CPU on Ableton)
- `readlink` (1.66%)
- `dir_add_to_existing_notify` (1.72%)
- `fstat` post-openat (currently inline in CQE callback for create_file)

Each new handler is a small additive change; no per-handler
infrastructure needed.

### 8.3 Decomp §3.2 (router/handler split) becomes a no-op

The §3.2 router/handler split was anticipated as separating the
"is this fast-path eligible?" classification from the actual handler
work.  The post-restructure dispatcher is exactly that — its loop body
is router + (sync handler OR async submit + future drain).  No
separate split commit needed.

### 8.4 Decomp §3.3 (FD polling thread split) becomes incremental

If most async work moves to per-dispatcher rings, `main_loop_epoll`'s
role shrinks to legacy fd polling (control-plane fds, fd-passing,
overflow paths).  The FD polling thread split becomes "split the
remaining tiny epoll path off main loop into a low-priority thread,"
which is much smaller than today's "split everything off."

### 8.5 Per-process ring isolation

A single Wine process's pathological I/O burst can't exhaust the ring
for unrelated processes — each has its own pool.  Currently the global
ring is shared; this matters at scale.

### 8.6 Unified completion-handling primitive

**The bigger architectural payoff: this work delivers a unified
completion-handling primitive that Wine has fundamentally lacked.**
Today Wine has fragmented mechanisms for "wait until something
finishes":

- IO completion ports (IOCP) — server-mediated, slow
- Async I/O via NtRead/NtWriteFile — server-routed via async lifecycle
- Client-side io_uring (Phase 1+2+3) — per-thread, sockets + file I/O
- Server-side io_uring (Phase C cross-thread, being replaced) — broken
- ntsync waits — events / mutexes / semaphores only, no fd or
  CQE composition

These don't compose cleanly.  Common patterns like *"wait on this
event OR this fd OR this timer atomically"* are awkward today —
fragile multi-thread coordination, polling loops, or per-pattern
custom infrastructure.

After this work, the same primitive (aggregate-wait) handles:

1. **`NtWaitForMultipleObjects` with heterogeneous sources.**  Win32's
   bread-and-butter wait that mixes events + fds + timers is one
   ioctl, atomic.

2. **IOCP completion delivery without server round-trip.**  A thread
   in `NtRemoveIoCompletion` can wait on the IOCP source AND the
   io_uring CQE source via aggregate-wait, getting completions
   directly from the kernel rather than via wineserver routing.

3. **Server handlers waiting inline for multiple async ops.**  A
   handler that needs "submit A, wait for A, submit B, wait for B,
   complete request" runs in dispatcher context with per-dispatcher
   ring + aggregate-wait.  Multiple ops in flight, properly
   sequenced.

4. **Decomp §3.1 (server timer thread).**  Timer thread waits on
   `(next-NT-timer-ABSTIME, signal-from-main-thread)` via aggregate-
   wait.  Trivial implementation; previously needed bespoke thread
   plumbing.

5. **Decomp §3.3 (FD polling thread split).**  Polling thread waits
   on `(all-server-fds POLLIN, exit-signal-event)` via aggregate-
   wait.  Hands work off via channel to RT handler thread.  RT
   handler waits on `(channel, work-queue completion source)` via
   the same aggregate-wait pattern.

6. **Future async-completing handlers across the board.**  Any
   server-side handler that wants async completion uses the same
   pattern.  `realpath`, `readlink`, `dir_change_notify`, future I/O
   handlers, NT timer expiry processing, etc.

The work is bigger than "fix Phase C's residual" — it lands the
**completion-handling primitive Wine has been missing**, with
immediate consumers (Phase C re-port) and many deferred consumers
that become incremental small commits afterward.

This is also why landing aggregate-wait before any narrower special
case is the right call: every deferred consumer in §8.6.4-§8.6.6
needs the general primitive, not a one-off gamma-specific wait path.
Building the general primitive now amortises kernel-work session
overhead.

## 9. Open questions and recommendations

These are the decisions where the doc takes a position; flag any
that need to be revisited at implementation time.

1. **Patch series numbering.**  The kernel-side heterogeneous wait
   primitive is patch 1010 in the existing ntsync stack; the userspace
   dispatcher restructure remains a separate Wine-side commit ladder.
   **Recommendation: keep that split.** The kernel ABI and the
   userspace consumer should be independently testable and revertable.

2. **Source identification shape.**  Aggregate-wait returns
   `fired_index` plus `fired_events`, and uses `NTSYNC_AGG_TIMEOUT`
   only for deadline expiry.  **Recommendation: keep real source
   indexes for channel and fd wakes.** That keeps the user/kernel
   contract simple and lets the dispatcher map `source[0]` and
   `source[1]` directly to its loop branches.

3. **Eventfd vs ring fd directly.**  The io_uring ring fd is itself
   pollable.  But CQE notification semantics differ — eventfd has a
   stable signal-on-arrival pattern, ring-fd polls require careful
   ordering.  **Recommendation: use eventfd intermediary, matching
   the WAIT_ANY uring extension's existing pattern.**  Plus eventfd
   gives us an explicit fd we can reset in the rare cleanup path.

4. **Per-process ring overhead.**  Each ring is mmap'd ~16-32KB
   (SQ + CQ rings).  At 50 Wine processes (heavy stress), that's
   ~1MB total — negligible.  64-entry ring is shallow; could grow
   per-process if needed later.  **Recommendation: 64 entries to
   match Phase C's existing pool, validate sizing under multi-process
   stress in Phase 6.**

5. **Eligibility for Phase C handler post-restructure.**  The
   read-only-only narrowing (`ffb15c8cf6d`) was a band-aid for the
   cross-thread timing issue.  Once architecture is correct, write
   opens should work (reply ordering is in dispatcher control,
   matches sync semantics).  **Recommendation: re-port handler with
   read-only eligibility first, validate Ableton clean, THEN expand
   to write opens in a follow-up commit.**

6. **Pre-1010 kernel fallback path.**  Userspace must keep working
   on a kernel that doesn't have `NTSYNC_IOC_AGGREGATE_WAIT`.
   **Recommendation: detect `-ENOTTY` on the aggregate-wait ioctl,
   mark the feature unsupported for that process, and stay on the
   synchronous handler path.**

7. **Aggregate-wait — kernel-level OR userspace ABI?**  Decomp §2.2's
   spec is for a kernel ioctl `NTSYNC_IOC_AGGREGATE_WAIT`.  An
   alternative would be a userspace helper that combines existing
   ntsync waits + poll/select.  **Recommendation: kernel ioctl per
   §2.2's original spec.  Userspace combination of multiple wait
   primitives has correctness pitfalls (race between two
   independent kernel waits), and the kernel is the natural place
   for atomic multi-source wait.**

8. **How much of the earlier Phase C attempt to preserve.**
   **Recommendation: preserve only the parts whose correctness is
   independent of the cross-thread bridge.** Architectural cleanup is
   simpler if the final implementation is a clean re-port onto the
   aggregate-wait shape.

9. **Eventfd register lifecycle.**  When does the eventfd get
   registered/deregistered?  Once at ring init, never deregistered
   until ring teardown.  **Recommendation: tie eventfd lifecycle to
   `nspa_uring_instance` lifecycle.  Init ring → create eventfd →
   register with ring → init done.  Teardown reverses.**

10. **Submit-and-wait fast path.**  io_uring has
    `io_uring_submit_and_wait_timeout` — could we use that instead
    of submit + return + RECV2-on-eventfd, for the case where the
    handler needs the CQE soon?  **Recommendation: NO for Phase C.
    The whole point is the dispatcher returns to RECV.  But for
    future patterns (e.g., a handler that legitimately wants to wait
    inline for a fast async op), submit_and_wait_timeout is
    available.  Document but don't use in this scope.**

## 10. Implementer's quick-reference

When picking this up to implement:

### Files to know

- `wine/server/nspa/shmem_channel.c` — gamma dispatcher pthread
  (the core that gets refactored in §5.3)
- `wine/server/nspa/uring.{c,h}` — global → per-instance refactor
- `wine/server/nspa/uring_create_file.{c,h}` — Phase C handler split
  (re-introduced after Phase 0 revert)
- `wine/server/process.h` — add `struct nspa_uring_instance` field
- `linux-nspa-6.19.11-1.src/.../drivers/misc/ntsync.c` — kernel module
- `linux-nspa-6.19.11-1.src/.../include/uapi/linux/ntsync.h` — UAPI

### Reference patches (templates to copy from)

- `ntsync-patches/1004-ntsync-channel.patch` — gamma channel original
- `ntsync-patches/1005-ntsync-channel-thread-token.patch` — adding a
  field to channel args + new ioctl variant + userspace fallback
  pattern
- `ntsync-patches/ntsync-uring-fd.patch` — the WAIT_ANY uring_fd
  extension; direct template for aggregate-wait poll registration
- `ntsync-patches/1006-ntsync-rt-alloc-hoist.patch` — pi_work pool
  pattern for PREEMPT_RT-safe deferred kfree

### Reference docs (read first)

- This doc (`aggregate-wait-and-async-completion.md`)
- `wine/nspa/docs/wineserver-decomposition-plan.md` — §2.2
  aggregate-wait spec, §3.2 / §3.3 future consumers
- `wine/nspa/docs/io_uring-architecture.md` — § "ntsync uring_fd
  Extension" (existing implementation)
- `MEMORY.md` index → `project_phase_c_iouring_in_flight.md`
  (what we learned)

### Build + test recipe

`reference_ableton_rt_test_recipe.md` (memory) — kernel build, install,
ntsync rebuild, Ableton soak protocol.  Used as-is.

### Known pitfalls

- KASAN required for kernel patch validation (§7.1).  Skipping
  this lost us 4 latent bugs in the previous channel work.
- Don't use `make_makefiles` to discover new server files — they
  must be `git add`'d FIRST or make_makefiles drops them
  (memory: `feedback_make_targets_partial_rebuild.md`)
- Wineserver runs as a daemon by default — `wine` launches it
  detached.  For -d3 stderr capture, use `/tmp/start-wineserver.sh`
  to run wineserver in foreground first, then connect via `/usr/bin/wine`

## 11. References

### In-tree

- `wine/nspa/docs/wineserver-decomposition-plan.md` — §2.2
  aggregate-wait, §3.2 router/handler, §3.3 FD polling split
- `wine/nspa/docs/io_uring-architecture.md` — client-side io_uring +
  ntsync uring extension (§ "ntsync uring_fd Extension")
- `wine/nspa/docs/io_uring-integration-plan.md` — Phase 1+2+3 client
  io_uring history
- `ntsync-patches/1004-ntsync-channel.patch` — original gamma channel
- `ntsync-patches/1005-ntsync-channel-thread-token.patch` — pattern
  for adding fields to channel args + new ioctl variant
- `ntsync-patches/ntsync-uring-fd.patch` — the WAIT_ANY uring_fd
  extension (model for aggregate-wait's fd-side registration)
- `ntsync-patches/ntsync.h.post1006` — current header layout

### Memory entries

- `project_phase_c_iouring_in_flight.md` — the cross-thread Phase C
  attempt and what it taught us
- `project_dispatcher_audit_and_split_plan.md` — gamma dispatcher
  history
- `plan_msg_ring_v2_receive_side_handoff.md` — related but different
  plan (msg-ring v2)

### External

- io_uring man pages (`io_uring_setup(2)`, `io_uring_enter(2)`)
- Linux kernel `wait_event_interruptible` / poll wakeup patterns
- ntsync kernel module — `drivers/misc/ntsync.c` in
  `linux-nspa-6.19.11-rt1-1-nspa`
