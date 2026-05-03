# Wine-NSPA -- Wineserver Decomposition: The Long-Horizon Plan

Wine 11.6 + NSPA RT patchset | Kernel 6.19.x-rt with NTSync PI | 2026-05-02
Author: Jordan Johnston
Status: long-horizon architecture plan; aggregate-wait is already a shipped slice, and the 2026-05-02 client-scheduler, local-event, timer, and socket follow-ons further narrowed the residual wineserver surface. The broader timer/fd-poll splits remain roadmap work.

This page explains the residual wineserver architecture problem after the existing bypasses, which decomposition slices have already landed, and which ones are still roadmap material.

## Table of Contents

1. [What this doc is](#1-what-this-doc-is)
2. [Where wineserver is today](#2-where-wineserver-is-today)
3. [Two complementary directions](#3-two-complementary-directions)
    - 3.1 [Priority inheritance across the splits](#31-priority-inheritance-across-the-splits)
4. [NTSync extension proposals](#4-ntsync-extension-proposals)
    - 4.1 [Thread-token pass-through (shipped)](#41-thread-token-pass-through-shipped)
    - 4.2 [Aggregate-wait primitive (shipped slice)](#42-aggregate-wait-primitive-shipped-slice)
5. [Decomposition path proposals](#5-decomposition-path-proposals)
    - 5.1 [Timer thread split](#51-timer-thread-split)
    - 5.2 [Router / handler split](#52-router--handler-split)
    - 5.3 [FD polling thread split](#53-fd-polling-thread-split)
    - 5.4 [Lock partitioning](#54-lock-partitioning)
6. [What MUST stay in wineserver](#6-what-must-stay-in-wineserver)
7. [Phasing](#7-phasing)
8. [Why this isn't a full rewrite](#8-why-this-isnt-a-full-rewrite)
    - 8.1 [The validation discipline](#81-the-validation-discipline)
9. [Open questions](#9-open-questions)
10. [Phase ladder diagram](#10-phase-ladder-diagram)
11. [Cross-references](#11-cross-references)

---

## 1. What this doc is

The NSPA bypass catalog describes the trajectories along which NT-API state moves *out* of wineserver. This doc is the other half: what eventually happens to wineserver itself, after enough state has migrated.

The high-level NSPA strategy has two coordinated parts. First, bypasses move specific classes of state client-side while retaining wineserver as fallback for cases the bypass cannot model. Second, decomposition reduces the residual wineserver to a smaller set of cooperating threads with subsystem-scoped locks instead of a single `global_lock`.

This document describes the decomposition side of that plan: the target wineserver shape and the dependency relationship between bypass work and server-internal restructuring.

A few framing notes before getting into the details:

- This is not a rewrite plan. The premise is that wineserver as a process continues to exist and continues to be the source of truth for a small set of irreducibly-cross-process semantics (process and thread lifecycle, named-object directories, handle inheritance). What changes is what's *inside* it.
- This is not a "kill the global_lock" plan in isolation. Lock partitioning is a late-stage step, not the opening move. Each earlier step is independently valuable and reduces the audit surface for later lock work.
- This is not chronological reading. Phase 1 and Phase 2 are already shipped (`open_fd` lock-drop default-on, NTSync §2.1 thread-token pass-through default-on), and one kernel/userspace slice that used to live under Phase 3 is now also shipped: NTSync aggregate-wait plus the gamma dispatcher consumer. Since the first public draft, more client-side work also shipped around the plan rather than inside wineserver itself: spawn-main + `ntdll_sched`, anonymous local events default-on, sched-hosted `local_timer` / `local_wm_timer`, and socket `RECVMSG` / `SENDMSG`. The phase table in section 7 is the canonical status; the body sections describe each component split in isolation.
- This is not a one-author plan. Several pieces (the gamma dispatcher itself, NTSync's PI machinery, the open_fd lock-drop framing) emerged from the kernel + wineserver co-design sessions and have been shaped over many iterations under real-workload validation. The road map here reflects what those iterations have converged on, not a top-down architectural mandate.

The audience this doc is written for: a developer who has read the bypass overview, has skimmed the gamma-channel-dispatcher and ntsync-driver docs, and wants to understand the architectural arc that the bypass work *enables*. If you're implementing a single bypass and want a checklist, read the bypass detail doc for that bypass; if you're implementing a single phase from this road map, read the in-tree handoff doc (`wine/nspa/docs/wineserver-decomposition-plan.md`) which has line-level kernel landmarks. This doc is the why, not the how.

The main 2026-05-02 correction is scope: some of the work this page once
treated as "future wineserver-internal decomposition pressure" is now
already shipping client-side. Timer dispatch for eligible local timers and
`WM_TIMER`s lives on the per-process scheduler host, anonymous events no
longer require a server-created helper object by default, and PE-side socket
deferred I/O is already on client `io_uring` rings. That does **not** make
the decomposition plan obsolete. It means the residual wineserver problem is
smaller and more concentrated than it was when this page was first drafted.

---

## 2. Where wineserver is today

Wineserver runs two RT threads in current NSPA configurations. Both serialize on a single `pi_mutex_t global_lock`, and that's the dominant bottleneck.

| Thread | Scheduler | Priority | Holds `global_lock` | Wakes on |
|---|---|---|---|---|
| Main loop | SCHED_FIFO | `nspa_srv_rt_prio` (default 64) | yes, around handler dispatch | `poll()` / `epoll_wait()` over wineserver fds |
| Gamma channel dispatcher (1 per client process) | SCHED_FIFO | `nspa_srv_rt_prio` (64) | yes, around handler dispatch | `NTSYNC_IOC_CHANNEL_RECV` (futex-backed) |
| (no separate timer thread today) | -- | -- | -- | timers handled inside main loop's `get_next_timeout` |

The shape worth noting: the main loop's wait primitive is `poll()` / `epoll_wait()` bounded by `get_next_timeout()`. The same syscall returns either when an fd is ready *or* when the next NT timer is due. Time-driven and event-driven processing are conflated into one wait primitive. That conflation is the seam Phase 3 is going to split along.

What changed since the first draft is where the pressure comes from. A chunk
of timer and event traffic no longer reaches wineserver at all:
`nspa_local_timer` and `nspa_local_wm_timer` now dispatch on the client
`wine-sched-rt` host when eligible, and anonymous local events default to a
client-range fast path. So the remaining Phase 3 timer split is about the
residual server-owned timer queue, not the whole timer surface.

The dispatcher pthread runs one per *client process*: the kernel-mediated request channel (the "gamma channel" -- see `gamma-channel-dispatcher.md`) replaces the older per-thread request dispatcher fan-out. So if a Wine application has 50 threads, there is still exactly one dispatcher pthread in wineserver handling all of them, and that dispatcher takes `global_lock` once per request.

Both RT threads serialize on the same lock. Adding more RT threads under the same lock doesn't help, because the lock holds serialise them anyway. Adding RT threads with finer-grained locks helps, but only after we know which subsets of state are independent enough to lock separately.

A perf capture from 2026-04-26 (PREEMPT_RT, Ableton steady-state playback workload) shows the wineserver-resident hot symbols:

- `channel_dispatcher` -- 6-11%
- `get_ptid_entry` -- 1-10% (called from `get_thread_from_id` from dispatcher)
- `main_loop_epoll` -- 2-7%
- `ioctl` -- 5-7%
- `read_request_shm` -- 2-3%
- `nspa_redraw_ring_drain` -- 1-4%
- `get_next_timeout` -- 2-3%

All of those run under `global_lock`. The wineserver process itself sits around 1% CPU at steady state -- it's a very lightly loaded process by throughput. But the question for an RT workload isn't "how busy is the server" -- it's *latency under contention*, which is exactly what a single global lock tilts against. Every handler runs to completion under the lock; the variance of "how long is the lock held" propagates into every other request.

The `open_fd` lock-drop work shipped in Phase 1 attacked one specific instance of this -- the long lock-holder during `openat` -- and it measurably improved drum-track-load-while-playing because it carved out a window where the lock could be released around the slow syscall. Similar surgical fixes exist elsewhere, but the lock-drop pattern is fundamentally a workaround for the wrong-grain-of-locking problem. The real fix is to either move the work out (bypasses) or split the lock (Phase 4).

---

## 3. Two complementary directions

NSPA addresses the wineserver bottleneck along two complementary directions, and this doc is about the second one. They are not alternatives -- they compose.

**Direction A: move state out.** Each NSPA bypass picks a class of NT-API state, hosts it in the client process via a local stub or kernel-mediated primitive, and falls back to the server only when the bypass envelope is exceeded. Sync primitives go to NTSync. File and socket I/O go to `io_uring`. Hooks get a Tier 1+2 cache. Read-only file opens go to local_file. Anonymous events and eligible timers now live on client-local stubs and scheduler hosts. Cross-thread same-process messages go through msg-ring. Each bypass shrinks the residual surface that wineserver still has to authoritatively serve.

**Direction B: restructure what remains.** Once the residual surface is small enough, wineserver can be split into multiple cooperating threads with finer-grained locks. The split has three components:

1. *Kernel-side primitives.* Extend NTSync with the wait/dispatch primitives wineserver needs to do its work without the main-loop conflation (aggregate-wait, thread-token pass-through). These are kernel patches in `ntsync-patches/`.
2. *Userspace dispatcher decomposition.* Split the gamma dispatcher's RECV → handler → REPLY into router (fast-path classifier) + handler (slow-path), and split the main loop's poll into a non-RT FD polling thread that hands off to RT handlers.
3. *Lock partitioning.* Target state: per-subsystem locks (windows, hooks, files, sync, processes) instead of one `global_lock`.

This is the doc for direction B. The two directions interact in a specific way: Direction A reduces the *amount* of state still under the lock; Direction B reduces the *overhead per access* to what's left. Direction A is incremental, parallelizable across many bypasses, and starts paying immediately. Direction B has higher per-step risk and more design surface, and it pays its big dividends only after the surface has already been pruned. That ordering is the central design choice of the whole roadmap.

Direction A reduces the amount of state still owned by wineserver. Direction B reduces the dispatch and locking cost of the state that remains. The ordering matters: reducing the residual surface first lowers the risk and audit cost of later server-internal restructuring.

There is a third direction worth naming explicitly even though it's not a separate workstream: **lock discipline inside existing handlers.** The Phase B `open_fd` lock-drop is the canonical example -- a single handler that holds `global_lock` across a slow blocking syscall, fixed by carefully releasing the lock around the syscall and reacquiring with a generation check. That kind of work doesn't move state out (Direction A) and doesn't restructure the threading (Direction B); it just reduces the lock-hold duration of one specific handler. It's surgical and labour-intensive, but several handlers benefit from it and the wins are immediate. It compounds with both other directions: a handler whose lock-hold has been minimized is a smaller obstacle once aggregate-wait or lock partitioning lands.

The decomposition arc treats lock-discipline patches as Phase 1 -- "individually surgical fixes to the worst lock-holders" -- and otherwise leaves them as ongoing work that ships independently. The Phase 1 row in the phase table represents the entire family, not just `open_fd`.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 540" xmlns="http://www.w3.org/2000/svg">
  <style>
    .wd-bg { fill: #1a1b26; }
    .wd-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .wd-server { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.8; rx: 8; }
    .wd-fast { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .wd-future { fill: #1f2535; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .wd-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .wd-small { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .wd-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .wd-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .wd-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .wd-violet { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .wd-axis { stroke: #3b4261; stroke-width: 1.2; stroke-dasharray: 6,4; }
    .wd-line { stroke: #c0caf5; stroke-width: 1.4; }
  </style>
  <defs>
    <marker id="wdArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="940" height="540" class="wd-bg"/>
  <text x="470" y="28" text-anchor="middle" class="wd-title">Wineserver decomposition arc: from one lock domain to a narrowed metadata core</text>

  <text x="175" y="64" text-anchor="middle" class="wd-red">Today</text>
  <text x="470" y="64" text-anchor="middle" class="wd-green">Bypass-led transition</text>
  <text x="765" y="64" text-anchor="middle" class="wd-violet">Target shape</text>

  <rect x="40" y="86" width="270" height="382" class="wd-server"/>
  <text x="175" y="112" text-anchor="middle" class="wd-label">Current wineserver process</text>
  <rect x="70" y="134" width="210" height="62" class="wd-box"/>
  <text x="175" y="158" text-anchor="middle" class="wd-label">main loop</text>
  <text x="175" y="176" text-anchor="middle" class="wd-small">poll/epoll + get_next_timeout + handlers</text>
  <rect x="70" y="220" width="210" height="62" class="wd-box"/>
  <text x="175" y="244" text-anchor="middle" class="wd-label">gamma dispatcher</text>
  <text x="175" y="262" text-anchor="middle" class="wd-small">CHANNEL_RECV -> handler -> REPLY</text>
  <rect x="70" y="308" width="210" height="110" class="wd-server"/>
  <text x="175" y="332" text-anchor="middle" class="wd-red">single global_lock domain</text>
  <text x="175" y="352" text-anchor="middle" class="wd-small">windows</text>
  <text x="175" y="370" text-anchor="middle" class="wd-small">hooks</text>
  <text x="175" y="388" text-anchor="middle" class="wd-small">files / timers / queues / sync registration</text>
  <text x="175" y="406" text-anchor="middle" class="wd-small">every request serializes here</text>

  <rect x="335" y="86" width="270" height="382" class="wd-fast"/>
  <text x="470" y="112" text-anchor="middle" class="wd-label">Transition state</text>
  <rect x="365" y="134" width="210" height="54" class="wd-fast"/>
  <text x="470" y="156" text-anchor="middle" class="wd-green">state moves out first</text>
  <text x="470" y="174" text-anchor="middle" class="wd-small">msg-ring, local-file, io_uring, hooks, timers</text>
  <rect x="365" y="212" width="210" height="54" class="wd-box"/>
  <text x="470" y="234" text-anchor="middle" class="wd-label">kernel primitives grow</text>
  <text x="470" y="252" text-anchor="middle" class="wd-small">channel RECV2, aggregate-wait, PI handoff</text>
  <rect x="365" y="290" width="210" height="128" class="wd-box"/>
  <text x="470" y="314" text-anchor="middle" class="wd-label">dispatch becomes separable</text>
  <text x="470" y="334" text-anchor="middle" class="wd-small">timer split</text>
  <text x="470" y="352" text-anchor="middle" class="wd-small">FD poll split</text>
  <text x="470" y="370" text-anchor="middle" class="wd-small">router / handler split begins to pay</text>
  <text x="470" y="388" text-anchor="middle" class="wd-small">lock-hold patches continue shipping</text>

  <rect x="630" y="86" width="270" height="382" class="wd-future"/>
  <text x="765" y="112" text-anchor="middle" class="wd-label">Long-horizon wineserver</text>
  <rect x="660" y="134" width="210" height="54" class="wd-box"/>
  <text x="765" y="156" text-anchor="middle" class="wd-label">RT handler tier</text>
  <text x="765" y="174" text-anchor="middle" class="wd-small">aggregate-wait over channel + fd queue + timer queue</text>
  <rect x="660" y="212" width="210" height="54" class="wd-box"/>
  <text x="765" y="234" text-anchor="middle" class="wd-label">non-RT helpers</text>
  <text x="765" y="252" text-anchor="middle" class="wd-small">fd polling, timer wake sources, router staging</text>
  <rect x="660" y="290" width="210" height="128" class="wd-server"/>
  <text x="765" y="314" text-anchor="middle" class="wd-violet">metadata core only</text>
  <text x="765" y="334" text-anchor="middle" class="wd-small">naming</text>
  <text x="765" y="352" text-anchor="middle" class="wd-small">lifecycle</text>
  <text x="765" y="370" text-anchor="middle" class="wd-small">inheritance / handle coordination</text>
  <text x="765" y="388" text-anchor="middle" class="wd-small">named sync registration / NT path rules</text>
  <text x="765" y="406" text-anchor="middle" class="wd-small">lock partitioning only after surface shrinks</text>

  <line x1="310" y1="278" x2="335" y2="278" class="wd-line" marker-end="url(#wdArrow)"/>
  <line x1="605" y1="278" x2="630" y2="278" class="wd-line" marker-end="url(#wdArrow)"/>
  <line x1="320" y1="486" x2="620" y2="486" class="wd-axis"/>
  <text x="470" y="510" text-anchor="middle" class="wd-small">ordering: move state out first, then split waits/threads, then partition residual locks</text>
</svg>
</div>

### 3.1 Priority inheritance across the splits

A reasonable concern when introducing more threads into wineserver is: does priority inheritance still propagate correctly? The answer depends on what's holding what.

In current NSPA wineserver, PI propagates through two paths. First, the gamma channel: a client SEND_PI boosts the dispatcher pthread to the sender's priority (kernel-mediated), and the kernel re-boosts on each RECV pop to the popped entry's priority for the duration of the handler -- so PI tracks the highest-priority pending request automatically. Second, `global_lock` itself is a `pi_mutex_t`; any thread blocked on it boosts the holder.

Phase 3 introduces three new threads. PI behaviour for each:

- *Timer thread* runs at the same priority as the main loop, doesn't have a sender (it's time-driven), and takes `global_lock` like everyone else. PI on its `global_lock` blocking is normal `pi_mutex_t` behaviour. No new propagation is needed.
- *FD polling thread* is non-RT (or low-RT). It enqueues to the handler thread; the handler thread's RT priority is what matters. The polling thread never holds `global_lock`, so it never inverts anything. The handoff queue itself is short-lived; the queue-drain wakeup signals an event that the handler thread waits on, and PI on that event needs to come from somewhere -- probably from the FD readiness itself (which has no inherent priority) plus the highest-priority pending FD-driven request (which we'd have to compute). This is a design detail still open.
- *Router thread* (Phase 4) sits ahead of the handler thread. Senders boost the router via SEND_PI as they do today. Router → handler handoff inside wineserver needs to preserve the boost; an NTSync event signalled with the request's priority does this naturally if both router and handler use NTSync primitives for the handoff. Userspace queues without an NTSync hop don't propagate PI, so the handoff queue probably wants to be NTSync-mediated.

The pattern that emerges: as long as every thread-to-thread handoff inside wineserver goes through an NTSync primitive that carries priority (channel, event with SET_PI), PI propagates end-to-end. As soon as a handoff goes through a bare userspace queue (a `pi_mutex_t`-protected list with no PI signal), priority propagation breaks and the highest-priority pending request can be starved by lower-priority work. That observation alone is a design constraint on Phase 3 / Phase 4: every handoff queue needs an NTSync event as its waiter primitive, not just a bare condition variable.

This is also why the aggregate-wait extension matters strategically. With aggregate-wait, a handler thread can wait on (incoming channel events, FD-event queue NTSync event, timer-deadline NTSync event) and the kernel keeps PI consistent across all of them. Without aggregate-wait, we either fragment the wait primitives (one thread per wait shape, more handoff queues, more places to drop PI) or lose the cleanliness of the boost propagation.

---

## 4. NTSync extension proposals

NTSync is the kernel module NSPA owns and extends (`ntsync-patches/`, `ntsync-driver.gen.html`). Two extensions are relevant to wineserver decomposition. The first is shipped; the second now exists as a shipped kernel/userspace slice with broader decomposition consumers still ahead.

### 4.1 Thread-token pass-through (shipped)

Status: **shipped 2026-04-26** (T1/T2/T3, default-on as of post-1006 unblocking). Listed here for completeness; the implementation is described in `gamma-channel-dispatcher.md`.

The problem this solved: every channel request, the dispatcher called `get_thread_from_id((thread_id_t)recv.payload_off)` which called `get_ptid_entry(id)`, an indexed array lookup with a possible cache miss in `process.c:547`. At 10% of dispatcher CPU in steady-state playback, this was meaningful overhead and -- more importantly -- a cache-miss-prone source of latency variance on every channel request.

The fix: extend `NTSYNC_IOC_CHANNEL_RECV` to return a `thread_token` that wineserver populated at thread create time. Wineserver registers `(tid, struct thread *)` via the new `NTSYNC_IOC_CHANNEL_REGISTER_THREAD` ioctl on thread create, deregisters on thread die, and on the receiving side reads the kernel-stamped token directly with no userspace lookup. Lifetime safety is preserved by the register-before-first-send / deregister-after-last-reply invariants.

Why it lives in this doc: it's the first NTSync extension specifically targeted at making wineserver do less per-request, and it's the prototype for the `4.2` aggregate-wait extension that would follow. The pattern (register a userspace pointer with the kernel; have the kernel hand it back at the dispatch event) is the same pattern aggregate-wait would extend to wider state.

The trust model -- which generalizes to 4.2 -- is "wineserver is trusted by the kernel because wineserver provided the registration; the client cannot influence what's stored." That's the right design for kernel objects whose userspace owner is privileged in the relevant sense (the wineserver process, which runs as the same UID as its clients but is the source of truth for the cross-process semantics layered on top of NTSync).

### 4.2 Aggregate-wait primitive (shipped slice)

Status: **kernel primitive + first userspace consumer shipped 2026-04-29**. The broader decomposition consumers (timer-thread split + FD poll thread split) remain queued, but `NTSYNC_IOC_AGGREGATE_WAIT` itself is no longer hypothetical and is already default-on in the gamma dispatcher via `NSPA_AGG_WAIT`.

The problem: wineserver's main loop today waits via `poll()` / `epoll_wait()` over wineserver fds. It does *not* compose with NTSync object waits. The dispatcher pthread waits via `NTSYNC_IOC_CHANNEL_RECV` (futex-backed); it does *not* compose with fd readiness or NT timer deadlines. Each thread has exactly one wait primitive and one shape of wakeup, and the two shapes can't merge into a single waiter.

That fragmentation is workable today because wineserver is not yet thread-decomposed. The main loop doesn't *need* to wait on NTSync objects; the dispatcher doesn't *need* to wait on fds. Once we move toward "single RT thread does everything except FD polling" (Phase 3) the unification matters: the RT thread needs to wait on the gamma channel, on a poll-set of wineserver fds, and on the next NT timer deadline, all in one syscall, with PI propagation from the channel sender.

The landed ioctl is `NTSYNC_IOC_AGGREGATE_WAIT`, which takes a heterogeneous source set:

- N NTSync objects (events, mutexes, channels)
- M file descriptors (with poll-style readiness flags)
- Optional absolute deadline (clock_nanosleep ABSTIME semantics)

Wakes on whichever source fires first. Reports back which source fired and (for FDs) what events. PI propagates from NTSync sources where the source carries a sender priority (channel SEND_PI, event SET_PI, etc.); FD readiness has no inherent priority.

The cost is moderate:

- Kernel: integrate `poll_wait` machinery for the FD half with the existing NTSync wait machinery for the object half. Existing kernel infrastructure handles both, but the unification work is its own design.
- UAPI: new ioctl + struct definitions. Standard NTSync UAPI patterns apply.
- Userspace: replace `main_loop_epoll` body and dispatcher RECV loop. Mechanical once the kernel side is in.

The win is moderate-large but bounded by the lock. Even with one unified waiter, every handler still serialises on `global_lock`. That honest accounting did not change when the primitive shipped: aggregate-wait is useful today because it fixes the gamma async-completion ownership problem, but it becomes strategically larger once the timer and fd-poll splits also compose with it.

A separate consideration is the PREEMPT_RT epoll question. The runtime gate `NSPA_DISABLE_EPOLL` lets us A/B plain `poll()` against `epoll_wait()` on PREEMPT_RT. If epoll behaves cleanly under the workload (no priority inversions on its internal RT-mutex-converted locks), the urgency on the FD polling thread split (5.3) drops, and aggregate-wait may be the right unification anyway -- but for the right reasons (composition with NTSync, not avoiding epoll). The decision belongs in the same session that designs the aggregate-wait API.

---

## 5. Decomposition path proposals

These four splits describe the userspace side of the road map. They are independent in implementation but ordered in the phasing because the risk profile varies and because some splits depend on prior infrastructure being in place.

### 5.1 Timer thread split

Status: **queued for Phase 3, but narrower than before**. Behaviour-preserving structural change; still the first safe server-internal split.

Today, wineserver's main loop computes `get_next_timeout()` from the head of the residual NT timer queue, passes that timeout to `poll()`, and processes timer expirations when poll returns due to timeout (rather than fd readiness). That couples timer-driven wakeups to fd-driven wakeups in the same syscall.

The scope correction after 2026-05-02 is important: this is no longer the
plan for **all** timer work. Eligible anonymous NT timers and eligible
`WM_TIMER` dispatch already moved onto the client `wine-sched-rt` host. The
remaining server-side split is about the timers that still genuinely belong
to wineserver's authoritative domain.

The proposal: a dedicated timer thread that owns the NT timer queue.

- New SCHED_FIFO thread at the same priority as the main loop.
- Sleeps via `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, deadline)` where deadline is the next NT timer expiration.
- On wake: takes `global_lock`, processes timer expirations, releases, recomputes deadline, sleeps again.
- On timer add/cancel from a handler running on another thread: atomic update + a wakeup signal (likely `pthread_kill(timer_thread, SIGRTMIN)` to interrupt the sleep, or a dedicated futex).

This is the *first safe split* for several reasons:

- Timers are time-driven, not event-driven. The sleep primitive is `clock_nanosleep ABSTIME`, which is exactly the right primitive for "wake at deadline X" -- no math, no conflation.
- The split removes the conflation of timer-driven and fd-driven wakeups in the main loop. After the split, the main loop's `poll()` wakes only on fd readiness, and `get_next_timeout` (currently 2-3% of wineserver CPU) moves to the timer thread.
- It doesn't change handler semantics. Timer expirations still run under `global_lock`; the only thing that moves is *when* they're processed.
- It's easy to back out: revert and timer processing returns to the main loop.

The risk is medium. Timer expiration must happen under `global_lock` to avoid races with handlers that read or write the same NT timer state, so the new thread is another lock contender. Today there are two RT lock-takers on the lock (main loop, dispatcher); after the split there are three. That doesn't directly hurt -- the lock is held briefly during timer processing -- but it is one more thread whose latency is sensitive to lock contention. Pairing this with the aggregate-wait extension (4.2) lets us evaluate whether the timer thread can use aggregate-wait to also watch for timer-add notifications, simplifying the wakeup signaling.

A subtlety worth flagging: NT timer semantics are mutable. NT code can create, modify, or cancel a timer at any moment. The timer thread needs to react to deadline changes between iterations. The cleanest signal is the one in the proposal (`pthread_kill` to interrupt the sleep, recompute, sleep again). An alternative is for the timer thread to also wait on a futex that fires on add/cancel; either works, and the choice is a design detail rather than a fundamental question.

### 5.2 Router / handler split

Status: **queued for Phase 4** (long horizon). Pays its design cost as state migrates out.

Today, the gamma dispatcher pthread does `CHANNEL_RECV → grab global_lock → read_request_shm → run handler → release lock → CHANNEL_REPLY` in a tight loop. Every request takes the lock. Most requests touch only a small subset of wineserver state.

The proposal is to split the dispatcher into two tiers:

- *Router*: a small RT thread (possibly at slightly higher priority than the handler tier). Owns `CHANNEL_RECV`. For each request, classifies it. If the request is **fast-path eligible** -- synthesizable locally without wineserver state, or answerable directly from client-side shm -- it replies immediately via `CHANNEL_REPLY` without taking `global_lock`. Otherwise it queues the request to the handler tier.
- *Handler*: an RT thread at slightly lower priority. Drains the queue, takes `global_lock`, runs the existing handler logic, replies.

Today, the fast-path classifier would return "slow path" for every request type. There is no request that doesn't go through the existing handler. So the split is initially behaviour-neutral: every request still ends up running under `global_lock`, just with one more queue hop.

The split *pays* over time, as state migrates out. Once enough state lives client-side (NT-local stubs, redirect tables in shared memory, hook caches), more request types qualify for the fast path. Trivial queries -- "is this handle valid?" "what's the size of this object?" "is this thread alive?" -- become candidates. Cross-process queries that can be answered from shared metadata become candidates. Each migration is a small change to the classifier: add a request type to the fast-path set, validate, ship.

The reason this is a Phase 4 item rather than a Phase 3 item: it has zero immediate impact. The fast-path set is empty today. Designing the classifier framework before there are clients for it risks over-engineering. Better to wait until a few obvious fast-path candidates exist (the bypasses ahead make this likely -- e.g. the GetMessage bypass turns a class of message-pump traffic into a candidate; the redraw push ring already shifts state shapes that could be queried fast-path).

The risk of the split itself is low (it's mechanical). The actual hard work is the per-request-type fast-path classification: deciding whether request type X is eligible, validating that the eligibility logic is correct under all envelope conditions, A/B'ing.

### 5.3 FD polling thread split

Status: **queued for Phase 3**. Decision contingent on PREEMPT_RT epoll experiment outcome, but the remaining scope is smaller now that PE-side sockets already bypass through client `io_uring` SQEs.

Today, the main loop is RT and spends most of its time blocked in `poll()` or `epoll_wait()`. The wait itself doesn't actually need RT priority -- only the *response* to the wait does. RT priority matters for the work that happens after the wait returns, not for the act of sleeping in the kernel.

The 2026-05-02 shipped socket follow-ons narrow this split's motivation.
Deferred socket recv/send no longer depend on wineserver fd wakeups in the
common PE path because they already submit `IORING_OP_RECVMSG` /
`IORING_OP_SENDMSG` from the client side. So the residual fd-poll split is
about the server-owned descriptor set that remains after those client-side
surfaces have peeled away.

The proposal: separate the FD polling from the FD-event handling.

- *FD polling thread*: a non-RT thread (SCHED_OTHER, or low SCHED_FIFO if measurement shows it helps). Owns `poll()` / `epoll_wait()` / `io_uring_enter()` over wineserver fds. Spends ~all its time sleeping in the kernel. On wake-up, doesn't run the handler -- it queues the fd-event to a handler thread.
- *Handler thread*: RT (the existing main loop, after this split, is essentially this). Drains the handoff queue, takes `global_lock`, runs the per-fd handler, releases.

The reason for non-RT polling: RT priority on a thread that's sleeping in the kernel doesn't change wakeup latency. The kernel wakes the thread when an fd is ready, regardless of scheduler class. RT priority helps once the thread is awake and competing for CPU -- but at that point we've already done a context switch into the polling thread; the cost is paid. Having the polling thread immediately hand off to a separate RT thread keeps the RT scheduler attention focused on the work that benefits from it.

The win compounds with the timer split (5.1) and aggregate-wait (4.2): after both, the wineserver main loop becomes a pure handler loop with no `poll()` calls of its own. The handler loop is the natural home for an aggregate-wait that watches the gamma channel, the FD-event queue, and the timer queue at once.

The risk is moderate. The handoff queue adds an extra context switch per fd-driven request: "fd ready" → polling thread wakes → enqueues → handler thread wakes → runs. Today that's "fd ready → main loop wakes → runs" -- one fewer context switch. Whether that latency increase matters depends on which fds carry latency-critical traffic. Most wineserver fds are control plane (request channels, sockets to clients), not data plane; the latency of "client request enqueued" to "server starts processing" is dominated by the existing channel + lock costs, not by an extra wakeup hop.

The other risk is the PREEMPT_RT epoll behavior. If epoll on PREEMPT_RT is adequate for the workload (the runtime A/B via `NSPA_DISABLE_EPOLL` will determine this), the urgency on this split drops. If epoll shows real priority inversions on its internal locks, the split becomes both an architectural and correctness requirement.

### 5.4 Lock partitioning

Status: **long horizon, Phase 4**. Don't start until 2-3 subsystems have already been pruned.

Current lock state: one `global_lock` (a `pi_mutex_t`) covers all wineserver state. Every handler takes it. The lock is a serialization point for every Win32 process running on the system.

The proposal: per-subsystem locks. Windows, hooks, files, sync objects, processes, message queues -- each with its own lock. Handlers grab only the lock(s) for the subsystem they touch. Cross-subsystem operations (rare) take multiple locks in a canonical order to avoid deadlock.

This is the only thing that lets multiple handlers run concurrently on the same wineserver process. Until it lands, every other split is ultimately bottlenecked at the lock; multi-threaded wineserver under one global lock is no better at throughput than single-threaded wineserver under one global lock, and is *worse* at latency variance because more threads contend for the same lock.

It's also, by a wide margin, the hardest split. The reasons it is the *last* thing to do:

- Massive audit surface. Every handler touches some subset of state. Every subset needs to be characterized for which lock(s) it requires. Existing handlers were written assuming "I hold the lock; nothing else changes during my critical section." That assumption is pervasive and finding all the places it's relied on is hard.
- Reasonable lock-ordering discipline takes work. Cross-subsystem operations need a canonical order; cycles in the lock-acquisition graph cause deadlocks. Linux kernel-style lockdep-equivalent tooling helps, but Wine doesn't have one yet for this surface.
- Most practical wins happen *before* this is needed. State that moves out of wineserver entirely (bypasses) doesn't need a lock at all -- it's gone. State whose access pattern is fast-path-classified (5.2) doesn't take the lock for the fast path. State whose handler runs under aggregate-wait (4.2) and a thread-split (5.1, 5.3) is already being processed under reduced contention. By the time we get to lock partitioning, the residual is small enough that the audit is tractable.
- The motion to dissolve the lock is much more sensible after each subsystem has been pruned to its minimum viable footprint. Partitioning a 100-handler subsystem is a much bigger job than partitioning a 30-handler subsystem; the bypasses do the pruning before partitioning starts.

The recommendation: do not start this work until at least 2-3 subsystems (probably files, sync, hooks) have been moved fully out of wineserver and the remaining lock-holders are identifiable as a small, audit-able set. Until then, ship bypasses, ship the other splits, and let the surface shrink. When the time comes, lock partitioning is the surgical conclusion of the whole strangler arc -- not its centerpiece.

---

## 6. What MUST stay in wineserver

These are the surfaces for which wineserver remains the source of truth and which no bypass or kernel primitive eliminates. The residual wineserver remains a metadata service for these:

- **Cross-process object naming.** Win32's `\BaseNamedObjects\Foo` and the NT object directory tree are shared across processes. Someone has to be the source of truth for "what's the object that handle H in process P refers to?" when H or its name is shared with another process.
- **Process and thread lifecycle.** Process start/exit, thread create/exit, parent-child relationships, exit codes propagation, `WaitForSingleObject` on a process or thread handle. NT semantics are server-mediated and the cross-process visibility requires a centralized authority.
- **Handle table coordination across handle inheritance.** `DuplicateHandle` between processes, inherited handles at process create, and the bookkeeping that ensures handles in the parent's table appear correctly in the child's table at the right moment. The handle table itself can be partitioned per-process; the *coordination* is cross-process.
- **Cross-process synchronization primitive registration.** The kernel side of sync moved to NTSync, but the wineserver-side registration table remains. It's the source of truth for "what handle in what process maps to what NTSync object." Anonymous local events now bypass the old helper-object path by default, but named or shared sync objects still need wineserver's cross-process view.
- **NT path resolution.** `\??\` paths, NT object directory hierarchy, some reparse-point handling, cross-process name redirection. These are NT-specific path rules without a Linux equivalent; they have to live somewhere and the only honest home is the source of truth for the NT name space.
- **Filesystem-as-kernel-object semantics that don't map to Linux primitives.** Some object types (mailslots, sections, specific reparse-point flavors) have semantics that NT exposes through the same mechanism as files and which Linux exposes through entirely different mechanisms. The translation layer lives server-side.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ms-bg { fill: #1a1b26; }
    .ms-core { fill: #2a1a1a; stroke: #f7768e; stroke-width: 2; rx: 10; }
    .ms-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.8; rx: 7; }
    .ms-out { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.6; rx: 7; }
    .ms-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .ms-small { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .ms-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ms-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ms-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ms-line { stroke: #c0caf5; stroke-width: 1.4; }
  </style>
  <defs>
    <marker id="msArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="940" height="420" class="ms-bg"/>
  <text x="470" y="28" text-anchor="middle" class="ms-title">What remains in wineserver after the bypass arc</text>

  <rect x="330" y="96" width="280" height="190" class="ms-core"/>
  <text x="470" y="124" text-anchor="middle" class="ms-red">Residual wineserver metadata core</text>
  <text x="470" y="150" text-anchor="middle" class="ms-label">cross-process object naming</text>
  <text x="470" y="170" text-anchor="middle" class="ms-label">process / thread lifecycle</text>
  <text x="470" y="190" text-anchor="middle" class="ms-label">handle inheritance / duplication coordination</text>
  <text x="470" y="210" text-anchor="middle" class="ms-label">named sync registration</text>
  <text x="470" y="230" text-anchor="middle" class="ms-label">NT path and object-directory rules</text>
  <text x="470" y="250" text-anchor="middle" class="ms-label">object types with no clean Linux analogue</text>

  <rect x="60" y="90" width="200" height="64" class="ms-out"/>
  <text x="160" y="116" text-anchor="middle" class="ms-green">already moving out</text>
  <text x="160" y="136" text-anchor="middle" class="ms-small">sync waits, file I/O, hooks</text>

  <rect x="60" y="186" width="200" height="64" class="ms-out"/>
  <text x="160" y="212" text-anchor="middle" class="ms-green">client-local transports</text>
  <text x="160" y="232" text-anchor="middle" class="ms-small">msg-ring, local-file, local timers</text>

  <rect x="680" y="90" width="200" height="64" class="ms-box"/>
  <text x="780" y="116" text-anchor="middle" class="ms-label">kernel assist</text>
  <text x="780" y="136" text-anchor="middle" class="ms-small">NTSync, futex PI, io_uring</text>

  <rect x="680" y="186" width="200" height="64" class="ms-box"/>
  <text x="780" y="212" text-anchor="middle" class="ms-label">future split points</text>
  <text x="780" y="232" text-anchor="middle" class="ms-small">aggregate-wait, handler tiers, lock partitions</text>

  <line x1="260" y1="122" x2="330" y2="150" class="ms-line" marker-end="url(#msArrow)"/>
  <line x1="260" y1="218" x2="330" y2="222" class="ms-line" marker-end="url(#msArrow)"/>
  <line x1="680" y1="122" x2="610" y2="150" class="ms-line" marker-end="url(#msArrow)"/>
  <line x1="680" y1="218" x2="610" y2="222" class="ms-line" marker-end="url(#msArrow)"/>

  <text x="470" y="332" text-anchor="middle" class="ms-small">design goal: the server stops being the default execution path and becomes</text>
  <text x="470" y="348" text-anchor="middle" class="ms-small">the authoritative broker for the small set of semantics that must stay centralized</text>
</svg>
</div>

These are *small* relative to what can move out. Windows, hooks, file inodes, message queues, timers, sync primitives, and file I/O are already in flight or shipped client-side. The residual wineserver becomes a thin metadata service that answers cross-process naming questions and brokers lifecycle events, not an application server that runs handlers for every NT call.

This list is also why the strategy is "decompose, not delete." A from-scratch replacement would have to re-implement all of the above plus everything that hasn't been moved yet. Decomposition keeps the existing implementations of the must-stay items and just rearranges how they're locked and dispatched.

---

## 7. Phasing

The single canonical phase table for the decomposition arc. This table covers the four phases of decomposition itself; bypass trajectories are tracked separately in their own subsystem docs.

| Phase | Items | Status |
|---|---|---|
| 1 | Phase B `open_fd` lock-drop | shipped default-on |
| 2 | NTSync §2.1 thread-token pass-through (T1/T2/T3) | shipped default-on |
| 3 | Residual timer thread split (5.1) + residual FD poll thread split (5.3), composed around shipped aggregate-wait (4.2) | queued |
| 4 | Router/handler split (5.2) + lock partitioning (5.4) | long horizon |

Each phase ships discrete, testable, revertible wins. The architecture direction stays clear (less wineserver, less `global_lock`, more event-driven RT primitives) but every phase is independently valuable.

A few notes about the ordering:

- Phase 1 (open_fd lock-drop) was a surgical fix targeted at one specific lock-holder pattern (long syscalls under `global_lock`). It's not a "decomposition" in the architectural sense; it's a targeted release of the lock around a known-slow critical section. Listed as Phase 1 because it was the first piece of decomposition-direction work to ship, and because the pattern it establishes (NSPA-side lock-discipline patches inside server handlers) generalizes to other long lock-holders we may identify later.
- Phase 2 is the thread-token pass-through, shipped 2026-04-26 as T1+T2+T3 and flipped default-on after the post-1006 ntsync stabilization. It's a kernel + userspace co-design and the prototype for the kernel-side primitives that Phase 3 will need.
- Phase 3 is still co-designed even though aggregate-wait itself already shipped. The remaining shape is one RT handler thread (running aggregate-wait over the gamma channel + the FD-event queue + the timer queue), one non-RT FD polling thread, and one timer thread. The syscall and the gamma consumer are now proven; the unresolved work is how the rest of wineserver composes around them. Since 2026-05-02, read this as the **residual** server-owned timer/fd set, not the whole timer/socket universe.
- Phase 4 is the long horizon. Router/handler split pays as more bypasses ship; lock partitioning pays at the end. Don't start either until the bypass arc has materially shrunk the surface area.

Most importantly: each phase ships independently. There is no big-bang. If Phase 3 stalls, Phase 4 doesn't unblock anything that Phase 1+2 didn't already unblock; the bypasses keep shipping in parallel. The decomposition-arc and the bypass-arc are independently progressing, with each sometimes accelerating the other but neither blocking it.

---

## 8. Why this isn't a full rewrite

The natural alternative to this plan is: rewrite wineserver from scratch with the architecture you wish it had. Multi-threaded by design, fine-grained locks, modern wait primitives, no `global_lock`. Wine's existing wineserver has a lot of accumulated assumptions ("nothing else changes during my handler") that a clean-slate rewrite could just not have.

There are real reasons NSPA chose decomposition over rewrite:

- **Incremental migration ships value continuously.** Each phase ships a discrete, testable, revertible win. Phase 1 alone (open_fd lock-drop) measurably improved drum-track-load-while-playing. Phase 2 alone reclaims ~10% of dispatcher CPU. A rewrite has no intermediate value; it ships when it ships, and the integration risk is concentrated at the moment of swap-over.
- **The existing handler bodies are correct.** Wine has decades of bugfixing inside the handler implementations -- corner cases, app compatibility, NT-quirk-of-the-month fixes. A rewrite has to re-port all of that, and "we missed a quirk" is a regression that's expensive to find. Decomposition reuses the handler bodies; only the dispatch and locking discipline around them changes.
- **Each step is independently revertible.** If Phase 3 turns out to introduce a regression, the env-var gates flip off and Phase 2 + Phase 1 + the bypasses all keep working. Compare the cost of reverting one phase to the cost of rolling back from a unified rewrite that's already replaced the old wineserver.
- **The bypass arc shrinks the rewrite target.** By the time decomposition gets to lock partitioning, the surface that needs partitioning is much smaller than today's wineserver. A rewrite's target is fixed at the time the rewrite starts; a decomposition's target shrinks while the work is in progress.
- **The direction is consistent at every step.** "Less wineserver, less global_lock, more event-driven RT primitives" is the same direction at every phase. The target architecture is refined incrementally instead of requiring a single up-front replacement design.

The cost of decomposition is a slight cost in design uniformity. Each phase has its own approach, its own gating env var, its own validation discipline. There's no single "wineserver 2.0" that you can point at; instead there's a wineserver that's been progressively reshaped. That is, on net, the right trade for a project that has to ship usable improvements continuously rather than commit to a multi-quarter rewrite.

A useful framing: bypasses and decomposition use the same incremental-migration discipline on different surfaces. Bypasses move NT-API state; decomposition restructures the remaining wineserver internals.

### 8.1 The validation discipline

A constraint that runs through the whole arc: each phase has to pass real-workload validation before it can flip default-on. The default workload is Ableton-on-PREEMPT_RT under realistic plugin load -- it exercises the message pump, the file I/O paths, the sync primitives, the timer paths, and the audio RT thread all simultaneously. If a change breaks Ableton or introduces measurable xrun regressions, it stays default-off until the cause is found and fixed.

This discipline has caught real bugs. The post-1006 ntsync work re-validated several "shipped" bypasses against a kernel module that finally didn't lock the host; the validation found that some of the lockup attribution had been wrong (Phase B `open_fd` was blamed for a lockup that turned out to be an unrelated NTSync slab corruption). Without re-validation under stable conditions, the wrong bypass would have stayed gated.

The implication for Phase 3: every component split needs its own gate (`NSPA_TIMER_THREAD_SPLIT=1`, `NSPA_FD_POLL_THREAD=1`, and so on), its own validation plan, and independent combination testing. `NSPA_AGG_WAIT` already followed that path and flipped default-on after validation; the remaining pieces should be held to the same discipline.

---

## 9. Open questions

These are the unresolved design questions ahead of Phase 3. None block Phase 1 or Phase 2 (already shipped) but each one wants an answer before the corresponding piece of Phase 3 ships.

1. **NTSync trust model for thread-token registration.** Does the kernel hold a strong ref on the thread struct so the token is always valid when returned, or does wineserver clear the token atomically with thread destroy? The former is simpler; the latter has lower kernel memory footprint. Phase 2 chose "wineserver-side clear-on-destroy" on the strength of the register-before-first-send / deregister-after-last-reply invariant. The same question recurs for any future NTSync-side token registry (sections, timers, IOCP completions).
2. **Aggregate-wait fairness.** If multiple sources are ready simultaneously, how are they ordered? For NTSync-object sources, "priority of the waker" is the obvious answer (it's how SEND_PI / SET_PI already work). For FD readiness, there is no waker priority. The aggregate-wait API needs a tie-break rule -- probably "object sources first, ordered by waker priority; FD sources second, ordered by registration order" -- but the call has not been made.
3. **Timer thread vs NT timer mutability.** NT timers can be created, modified, or destroyed at any time. The timer thread needs to react to deadline changes between iterations. Two clean signals: `pthread_kill(timer_thread, SIGRTMIN)` to interrupt `clock_nanosleep` and force recompute, or have the timer thread also wait on a futex that fires on add/cancel. Aggregate-wait (4.2) makes this trivial: the timer thread waits on `(NT timer queue head deadline, futex on add/cancel)` and reacts to whichever fires. So this is partially a question of "does timer-split land before aggregate-wait or after?"
4. **Strangler vs growth.** As the wineserver-decomposition direction continues, do we keep wineserver largely stable while pruning, or actively rewrite the parts that remain? The default recommendation is strangler -- keep the existing handler bodies, change only the dispatch and locking. But there are individual subsystems where a partial rewrite of the *handler* (not the architecture) might be cleaner once it's been pruned to a small surface. That call is per-subsystem and shouldn't be made up front.
5. **PREEMPT_RT epoll experiment outcome.** `NSPA_DISABLE_EPOLL` (`90231fc8d21`) lets us A/B plain `poll()` vs `epoll_wait()` on PREEMPT_RT without rebuilding. If epoll behaves cleanly under the workload, the urgency on the FD poll thread split (5.3) drops; if it shows priority inversions on its internal RT-mutex-converted locks, the split moves up the priority list. The experiment should land before Phase 3 design is finalized.
6. **Where does `inproc_sync` fit?** The in-tree `server/inproc_sync.c` already handles a class of intra-process sync operations without round-tripping through the dispatcher. Some of its design lessons -- per-process state, ioctl-direct dispatch -- generalize to other request types, and the question is whether `inproc_sync` becomes a model for further router/handler-split fast paths or stays a one-off.
7. **Handler queue priority discipline.** If the gamma dispatcher splits into router + handler tiers (5.2), the handoff queue between them needs a priority-respecting drain order. NTSync gives us PI on the channel; once a request is on a userspace queue inside wineserver, PI doesn't automatically follow. The queue drain probably needs to use NTSync as its waiter primitive (an event per handler, signalled from the router) so PI re-applies on the handoff. Not a blocker; a design detail.

---

## 10. Phase ladder diagram

A vertical phase ladder. Phases 1 and 2 are below the line ("done"); Phases 3 and 4 are above the line ("ahead"). The components of each phase are listed inside the phase block.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 720" xmlns="http://www.w3.org/2000/svg">
  <style>
    .bg          { fill: #1a1b26; }
    .axis        { stroke: #3b4261; stroke-width: 1; stroke-dasharray: 4,3; }
    .phase-done  { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.5; }
    .phase-curr  { fill: #2a2438; stroke: #e0af68; stroke-width: 2; }
    .phase-far   { fill: #1f2535; stroke: #565f89; stroke-width: 1; stroke-dasharray: 4,3; }
    .label       { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .label-sm    { fill: #c0caf5; font-size: 9px;  font-family: 'JetBrains Mono', monospace; }
    .label-grn   { fill: #9ece6a; font-size: 12px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-yel   { fill: #e0af68; font-size: 12px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-pur   { fill: #bb9af7; font-size: 12px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-blue  { fill: #7aa2f7; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .label-cyan  { fill: #7dcfff; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .label-mut   { fill: #8c92b3; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .title       { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .header      { fill: #c0caf5; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .rail        { stroke: #3b4261; stroke-width: 1.5; }
  </style>

  <rect x="0" y="0" width="940" height="720" class="bg"/>
  <text x="470" y="28" text-anchor="middle" class="title">Wineserver decomposition phase ladder</text>
  <text x="470" y="48" text-anchor="middle" class="label-mut">bottom = shipped, top = horizon</text>

  <line x1="470" y1="80" x2="470" y2="660" class="rail"/>

  <text x="220" y="78" text-anchor="middle" class="header">PHASE</text>
  <text x="720" y="78" text-anchor="middle" class="header">COMPONENTS</text>

  <line x1="60" y1="86" x2="880" y2="86" class="axis"/>

  <rect x="100" y="540" width="240" height="100" rx="6" class="phase-done"/>
  <text x="220" y="568" text-anchor="middle" class="label-grn">Phase 1</text>
  <text x="220" y="588" text-anchor="middle" class="label-cyan">SHIPPED</text>
  <text x="220" y="610" text-anchor="middle" class="label-mut">default-on 2026-04-26</text>
  <text x="220" y="628" text-anchor="middle" class="label-mut">surgical lock release</text>

  <rect x="500" y="540" width="380" height="100" rx="6" class="phase-done"/>
  <text x="690" y="568" text-anchor="middle" class="label">Phase B open_fd lock-drop</text>
  <text x="690" y="590" text-anchor="middle" class="label-sm">release global_lock around openat (long syscall)</text>
  <text x="690" y="610" text-anchor="middle" class="label-sm">drum-track-load-while-playing xrun fix</text>
  <text x="690" y="628" text-anchor="middle" class="label-sm">pattern: NSPA-side lock-discipline patches in handlers</text>

  <line x1="340" y1="590" x2="500" y2="590" class="axis"/>

  <rect x="100" y="400" width="240" height="100" rx="6" class="phase-done"/>
  <text x="220" y="428" text-anchor="middle" class="label-grn">Phase 2</text>
  <text x="220" y="448" text-anchor="middle" class="label-cyan">SHIPPED</text>
  <text x="220" y="470" text-anchor="middle" class="label-mut">default-on 2026-04-26</text>
  <text x="220" y="488" text-anchor="middle" class="label-mut">first NTSync extension</text>

  <rect x="500" y="400" width="380" height="100" rx="6" class="phase-done"/>
  <text x="690" y="428" text-anchor="middle" class="label">NTSync sec 2.1 thread-token pass-through</text>
  <text x="690" y="450" text-anchor="middle" class="label-sm">T1: ioctls; T2: register/deregister; T3: dispatcher consumes</text>
  <text x="690" y="470" text-anchor="middle" class="label-sm">drops get_ptid_entry from ~10% of dispatcher CPU</text>
  <text x="690" y="488" text-anchor="middle" class="label-sm">prototype for further kernel-side primitives</text>

  <line x1="340" y1="450" x2="500" y2="450" class="axis"/>

  <rect x="100" y="240" width="240" height="120" rx="6" class="phase-curr"/>
  <text x="220" y="270" text-anchor="middle" class="label-yel">Phase 3</text>
  <text x="220" y="290" text-anchor="middle" class="label-cyan">QUEUED</text>
  <text x="220" y="312" text-anchor="middle" class="label-mut">co-designed thread split</text>
  <text x="220" y="330" text-anchor="middle" class="label-mut">+ kernel primitive</text>
  <text x="220" y="348" text-anchor="middle" class="label-mut">aggregate-wait + decomp</text>

  <rect x="500" y="240" width="380" height="120" rx="6" class="phase-curr"/>
  <text x="690" y="266" text-anchor="middle" class="label">5.1 residual timer thread split</text>
  <text x="690" y="284" text-anchor="middle" class="label-sm">separate time-driven from event-driven wakeup</text>
  <text x="690" y="304" text-anchor="middle" class="label">4.2 NTSync sec 2.2 aggregate-wait</text>
  <text x="690" y="322" text-anchor="middle" class="label-sm">unified waiter: NTSync objects + FDs + deadline</text>
  <text x="690" y="340" text-anchor="middle" class="label">5.3 residual FD poll thread split</text>
  <text x="690" y="356" text-anchor="middle" class="label-sm">non-RT polling, RT handler handoff</text>

  <line x1="340" y1="300" x2="500" y2="300" class="axis"/>

  <rect x="100" y="100" width="240" height="120" rx="6" class="phase-far"/>
  <text x="220" y="130" text-anchor="middle" class="label-pur">Phase 4</text>
  <text x="220" y="150" text-anchor="middle" class="label-cyan">LONG HORIZON</text>
  <text x="220" y="172" text-anchor="middle" class="label-mut">begins after 2-3 subsystems</text>
  <text x="220" y="190" text-anchor="middle" class="label-mut">have moved out via bypasses</text>
  <text x="220" y="208" text-anchor="middle" class="label-mut">surgical conclusion</text>

  <rect x="500" y="100" width="380" height="120" rx="6" class="phase-far"/>
  <text x="690" y="126" text-anchor="middle" class="label">5.2 Router / handler split</text>
  <text x="690" y="144" text-anchor="middle" class="label-sm">fast-path classifier; pays as state migrates out</text>
  <text x="690" y="164" text-anchor="middle" class="label-sm">handler queue, NTSync-mediated handoff</text>
  <text x="690" y="184" text-anchor="middle" class="label">5.4 Lock partitioning</text>
  <text x="690" y="202" text-anchor="middle" class="label-sm">per-subsystem locks: windows / hooks / files / sync</text>
  <text x="690" y="218" text-anchor="middle" class="label-sm">late-stage split; massive audit surface</text>

  <text x="470" y="690" text-anchor="middle" class="label-mut">each phase ships independently; bypasses progress in parallel</text>
</svg>
</div>

The visual point of the ladder: the bottom two phases are done, the middle phase is the next major piece of architectural work, and the top phase only starts once the bypass arc has shrunk the surface enough to make it tractable. Each rung is independently valuable; nothing requires the rung above it before it can ship.

---

## 11. Cross-references

- `client-scheduler-architecture.md` -- the shipped per-process scheduler host that already absorbed eligible local timer work and narrowed the remaining wineserver timer problem.
- `gamma-channel-dispatcher.md` -- the existing gamma dispatcher, which 5.2's router/handler split decomposes. Also the home of the Phase 2 thread-token pass-through implementation.
- `nt-local-stubs.md` -- the architectural pattern for client-resident handlers. Section 6's "what stays in wineserver" defines the floor that nt-local stubs and bypasses converge toward.
- `ntsync-driver.gen.html` -- the kernel module that hosts the NTSync primitives. Section 4's extensions live in this module's patch series.
- `nspa-local-file-architecture.gen.html`, `msg-ring-architecture.gen.html`, `io_uring-architecture.gen.html`, `cs-pi.gen.html`, `condvar-pi-requeue.gen.html` -- the per-subsystem detail docs whose work composes with the decomposition arc.
- `architecture.gen.html` -- the integrated NSPA architecture overview; this doc is the wineserver-internals lens of that architecture.
- In-tree handoff: `wine/nspa/docs/wineserver-decomposition-plan.md` -- the session-handoff version of this plan, with line-level kernel landmarks and active-session details. Use that doc when implementing Phase 3 / Phase 4; use this doc when reasoning about the trajectory.
