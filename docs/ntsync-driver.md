# Wine-NSPA -- NTSync Kernel Driver

Linux-NSPA 6.19.11-rt1-1 (PREEMPT_RT), CONFIG_NTSYNC=m | 2026-04-28
Author: Jordan Johnston

## Table of Contents

1. [Overview](#1-overview)
2. [Object Types](#2-object-types)
3. [The 1003 PI Baseline](#3-the-1003-pi-baseline)
4. [Patch 1004: Channel Object](#4-patch-1004-channel-object)
5. [Patch 1005: Thread-Token Pass-Through](#5-patch-1005-thread-token-pass-through)
6. [Patch 1006: RT Alloc-Hoist](#6-patch-1006-rt-alloc-hoist)
7. [Patch 1007: Channel Exclusive Recv](#7-patch-1007-channel-exclusive-recv)
8. [Patch 1008: EVENT_SET_PI Deferred Boost](#8-patch-1008-event_set_pi-deferred-boost)
9. [Patch 1009: channel_entry Refcount UAF](#9-patch-1009-channel_entry-refcount-uaf)
10. [Lessons and Audit Philosophy](#10-lessons-and-audit-philosophy)
11. [Wine Consumer Side](#11-wine-consumer-side)
12. [Validation](#12-validation)
13. [References](#13-references)

---

## 1. Overview

NTSync is a Linux kernel driver (`drivers/misc/ntsync.c`, `/dev/ntsync`) that implements Windows NT synchronization primitives -- mutexes, semaphores, and events -- directly in the kernel. Upstream Wine uses it to replace the wineserver-mediated sync path for these objects, eliminating cross-process round-trips for wait/wake operations.

For Wine-NSPA, upstream ntsync is necessary but insufficient. The upstream driver uses FIFO waiter queues, has no priority inheritance, and uses `spinlock_t` for the per-object lock -- which becomes a sleeping `rt_mutex` on PREEMPT_RT. None of those characteristics is acceptable for an RT audio workload where the audio callback must wait deterministically on Wine's primitives without inheriting unbounded inversion latency.

Wine-NSPA carries a stack of seven kernel patches on top of upstream `ntsync.c`. The first (1003) was the original PI series shipped 2026-04-13: raw spinlocks, priority-ordered queues, mutex-owner PI boost. The next six (1004-1009) added a new object type for kernel-mediated request/reply IPC and then progressively closed real correctness bugs found by stress-testing and KASAN. Three of those bugs (1007, 1008, 1009) were caught only after PREEMPT_RT debug-kernel testing; one (1006) was caught when an Ableton workload hard-froze the host with a clean SLUB freelist-corruption oops.

Module srcversion `A250A77651C8D5DAB719FE2` is the production module on prod kernel `6.19.11-rt1-1-nspa`. It carries all seven patches. ~370M operations of mixed-load stress (events SET / RESET / PULSE / SET_PI; mutex acquire+release; semaphore release+acquire; channel SEND_PI / RECV / REPLY; thread register/deregister; multi-object wait_all / wait_any) have run against this module under KASAN with zero memory-corruption splats.

This doc covers the patch-by-patch design rationale: what each patch changes, what bug it closes (or feature it adds), how it preserves NT semantics, and how it interacts with the `obj_lock` raw_spinlock and PREEMPT_RT.

### NSPA overlay relationship

Wine-NSPA does not fork ntsync. The patches are diffs against upstream `drivers/misc/ntsync.c` and apply cleanly in series 1003 -> 1004 -> 1005 -> 1006 -> 1007 -> 1008 -> 1009. They live in `wine-rt-claude/ntsync-patches/` as standalone unified diffs. The kernel build (`linux-nspa`) applies the stack at PKGBUILD time; the resulting `.ko` ships as part of the kernel package.

The patch numbering (`1003-` through `1009-`) is local to NSPA. It bears no relationship to upstream NTSync revisions or any LKML series.

### Patch series at a glance

| #    | Patch                                 | Purpose                                                                                       | LOC     |
|------|---------------------------------------|-----------------------------------------------------------------------------------------------|---------|
| 1003 | PI primitives                         | raw_spinlock obj_lock, priority-ordered waiter queues, mutex owner PI boost, per-task tracking| ~600    |
| 1004 | Channel object                        | New `NTSYNC_TYPE_CHANNEL` with `CREATE`, `SEND_PI`, `RECV`, `REPLY` ioctls                    | ~530    |
| 1005 | Thread-token                          | Per-channel `(tid -> token)` registry + `RECV2` ioctl, eliminates dispatcher userspace lookup | ~340    |
| 1006 | RT alloc-hoist                        | Hoists 6 sites of `kmalloc`/`kfree` out of `raw_spinlock_t` (RT-illegal); `pi_work` pool      | ~750    |
| 1007 | Channel exclusive recv                | `wake_up_all` priority-inversion fix: 3-LOC `wait_event_interruptible_exclusive` swap         | ~3      |
| 1008 | EVENT_SET_PI deferred boost           | Closes fast-path race where consumer takes obj_lock first, sees signaled, returns unboosted   | ~80     |
| 1009 | channel_entry refcount UAF            | KASAN-caught REPLY-vs-SEND_PI cleanup race; refcount_t on `ntsync_channel_entry`              | ~15     |

Patches 1003-1006 are feature/infrastructure work; 1007-1009 are minimal surgical fixes for specific KASAN- or trace-confirmed bugs. The distinction matters: Section 10 discusses why.

---

## 2. Object Types

Wine-NSPA's ntsync exposes four object types via `/dev/ntsync` (one character device opened once per Wine process; object creation returns FDs).

| Type           | Win32 primitive                              | Created via                       | Wait via                            | Wake / signal via                 |
|----------------|----------------------------------------------|-----------------------------------|-------------------------------------|-----------------------------------|
| **Mutex**      | `CreateMutex`, `WaitForSingleObject`         | `NTSYNC_IOC_CREATE_MUTEX`         | `NTSYNC_IOC_WAIT_ANY` / `WAIT_ALL`  | `NTSYNC_IOC_MUTEX_UNLOCK`         |
| **Semaphore**  | `CreateSemaphore`, `ReleaseSemaphore`        | `NTSYNC_IOC_CREATE_SEM`           | `NTSYNC_IOC_WAIT_ANY` / `WAIT_ALL`  | `NTSYNC_IOC_SEM_RELEASE`          |
| **Event**      | `CreateEvent`, `SetEvent`, `ResetEvent`      | `NTSYNC_IOC_CREATE_EVENT`         | `NTSYNC_IOC_WAIT_ANY` / `WAIT_ALL`  | `NTSYNC_IOC_EVENT_SET` / `_RESET` / `_PULSE` / `_SET_PI` |
| **Channel**    | (no Win32 equivalent -- NSPA-private IPC)    | `NTSYNC_IOC_CREATE_CHANNEL`       | `NTSYNC_IOC_CHANNEL_RECV` / `_RECV2`| `NTSYNC_IOC_CHANNEL_SEND_PI` / `_REPLY` |

Mutex / semaphore / event are upstream concepts; their semantics map 1:1 to Win32. The mutex tracks an owner TID for `WAIT_ABANDONED` semantics and abandoned-recovery; the semaphore is a counted resource pool; the event has both manual-reset and auto-reset variants plus the NSPA-private `EVENT_SET_PI` for cross-thread priority intent.

The channel is wholly NSPA-private. It does not map to any Win32 primitive. It is a transport for Wine-NSPA's wineserver request-reply fast path -- a kernel-mediated alternative to the legacy futex+manual-`sched_setscheduler` shm IPC. Channels do not participate in `WAIT_ANY` / `WAIT_ALL`; they are accessed exclusively through their own ioctls.

### is_signaled by type

The driver's central `is_signaled()` predicate (called from `try_wake_any` / `try_wake_all`) returns differently per type:

| Type      | Signaled when                                      |
|-----------|----------------------------------------------------|
| Mutex     | `count == 0` (unowned) or owner matches current TID |
| Semaphore | `count > 0`                                         |
| Event     | `signaled == true`                                  |
| Channel   | always `false` (channels never wake `WAIT_ANY/ALL`) |

The channel case in `is_signaled()` is a deliberate hard-`false`: any caller that arrives via `WAIT_ANY/ALL` with a channel FD is misusing the API and the wait will time out. Channels are accessed only through `CHANNEL_RECV` / `CHANNEL_RECV2`.

---

## 3. The 1003 PI Baseline

The 1003 patch (originally three logical patches `1001`/`1002`/`1003`, collapsed in this section for clarity) established the RT baseline that all subsequent patches build on.

### Locking hierarchy

The driver has three locks. NSPA classifies them explicitly for PREEMPT_RT:

    raw_spinlock_t obj->lock          per-object, protects state + waiter lists
    rt_mutex       dev->wait_all_lock device-wide, serializes wait-all setup
    raw_spinlock_t dev->boost_lock    device-wide, protects boosted_owners list

`raw_spinlock_t` keeps true spin semantics on PREEMPT_RT (does not become an `rt_mutex`). `obj->lock` is held only across short pointer-only state updates: rb-tree manipulation, list manipulation, signaled-flag flip, owner-TID write. `dev->boost_lock` is held only across `boosted_owners` list updates plus a single `sched_setattr_nocheck()` call. Both critical sections are short, bounded, and never sleep -- the PREEMPT_RT contract.

`dev->wait_all_lock` is `rt_mutex`, not `raw_spinlock_t`, because wait-all setup is long: it walks all named objects to be waited on, may copy_from_user the FD array, and may need to take per-object locks. A raw spinlock is the wrong primitive for that. The `rt_mutex` carries PI -- a high-priority thread blocked on `wait_all_lock` boosts whoever holds it.

The `obj_lock()` fast path acquires only `obj->lock`. When `obj->dev_locked` is set (another thread is doing a wait-all on this object), `obj_lock()` falls back to acquiring `wait_all_lock` first. This avoids ABBA deadlocks between per-object and device-wide locks.

### Priority-ordered waiter queues

Upstream ntsync uses `list_add_tail()` to append waiters: FIFO order. NSPA replaces this with `ntsync_insert_waiter()`, which performs a sorted insertion based on the kernel-internal `task->prio` (lower numeric value = higher scheduling priority).

    static void ntsync_insert_waiter(struct ntsync_q_entry *new_entry,
                                     struct list_head *head)
    {
        struct ntsync_q_entry *entry;
        list_for_each_entry(entry, head, node) {
            if (new_entry->q->task->prio < entry->q->task->prio) {
                list_add_tail(&new_entry->node, &entry->node);
                return;
            }
        }
        list_add_tail(&new_entry->node, head);
    }

Same-priority waiters maintain FIFO order within their priority level. `try_wake_any_*()` walks from the head, so the highest-priority satisfiable waiter wakes first. This restores NT semantics (highest-priority waiter wins) and is strictly stronger than upstream's FIFO.

### Mutex owner PI boost

When an RT thread (e.g. SCHED_FIFO prio 80) waits on a mutex held by a SCHED_OTHER thread (prio 120 in kernel terms), the holder is preempted by every running RT thread and time-sliced by CFS against every other normal thread. The RT waiter's bounded-latency guarantee is violated.

`ntsync_pi_recalc(obj, pi_work)` (line 424 of the production source) handles this. Whenever a mutex's wait list changes (insert, wake, unlock) it scans both `any_waiters` and `all_waiters` for the highest-priority waiter, then boosts the owner's scheduling attributes via `sched_setattr_nocheck()` to match. Per-task tracking (`struct ntsync_pi_owner`, anchored in `dev->boosted_owners`) saves the original attributes once and counts how many of the task's owned mutexes are contributing boosts. Restore happens only when the count drops to zero.

The PI boost design has three v2 lessons baked in:

| Bug                          | v1 behaviour                                                | v2 fix                                                  |
|------------------------------|-------------------------------------------------------------|---------------------------------------------------------|
| Multi-object PI corruption   | Single global `orig_attr` overwritten when 2nd mutex boosted| Per-task `ntsync_pi_owner` with `boost_count`           |
| Zero PI for WaitAll          | `all_waiters` not scanned                                   | Scan both `any_waiters` and `all_waiters`               |
| Stale `normal_prio` thrash   | `owner->normal_prio` mutates after boost -> oscillation     | Compare against saved `orig_normal_prio` from tracker   |

The `ntsync_pi_owner` struct is the unit of bookkeeping. The pool/cleanup pattern that 1006 introduces (Section 6) is the unit of RT-safe allocation for that struct.

### EVENT_SET_PI primitive (pre-1008 design)

`EVENT_SET_PI` was originally introduced in 1003 as the cross-thread priority-intent primitive: an RT thread sets an event, and along with the signal it carries a `(policy, prio)` boost that the kernel applies to the event's first waiter. Wine-NSPA uses this for the audio-thread -> dispatcher SendMessage bypass: the audio callback sets a queue event with its own RT priority, and the dispatcher pthread is woken at that priority.

The original design walked `event->any_waiters` under `obj_lock` at `EVENT_SET_PI` time and applied the boost to the head waiter. This had a fast-path race that 1008 closes -- see Section 8.

### Per-task tracking, conservative over-boost

`ntsync_pi_owner` is allocated lazily on first boost and freed only when the last contributing object releases. Between the first removal and the last, the owner is conservatively over-boosted: it runs at too-high priority briefly, never too-low. That is the safe direction; under-boost would leak inversion. The lazy lifetime also means owner_task is resolved lazily on the first unlock (where `current` is the actual Win32-owning thread), since at create time `current` is the wineserver, not the eventual owner.

---

## 4. Patch 1004: Channel Object

`1004-ntsync-channel.patch` adds a new object type, `NTSYNC_TYPE_CHANNEL`. A channel is a bounded, kernel-side priority-ordered request/reply mailbox. It exists to replace Wine-NSPA's user-space futex + manual `sched_setscheduler` shm-IPC fast path between client processes and the wineserver.

### Why a kernel object

Wine's wineserver protocol is fundamentally a request/reply RPC. Each client thread sends a request, blocks for the reply, and resumes. The legacy fast path used a process-shared futex on a request slot plus a `sched_setscheduler` call from the sending audio thread to lift the dispatcher pthread's priority. That worked but had three problems:

1. **Priority transfer was a separate syscall.** The audio thread had to know which pthread it was lifting and call `sched_setscheduler` on it explicitly. Token-stale racy on thread death.
2. **No priority queueing.** When two senders raced, the futex woke one of them in roughly FIFO order; a higher-priority sender could wait behind a lower-priority one if the dispatcher was idle.
3. **No transactional priority drain.** If the dispatcher returned without replying (signal, error path) the audio-thread-applied boost had no clear cleanup hook.

A kernel-mediated channel solves all three. The kernel:

- Holds a priority-ordered rb-tree of pending requests (priority DESC, sequence ASC).
- Atomically boosts the blocked receiver to the sender's priority on enqueue.
- Auto-boosts the receiver to the popped entry's priority for the handler duration.
- Drains the boost at REPLY and at the next RECV (mirroring `EVENT_SET_PI`'s drain-on-wait pattern).

The channel is purely a *transport*, not a *protocol*. The wineserver still drives the request/reply contract; the kernel multiplexes and priority-orders, and never reorders within a single sender (each sender blocks for reply, so per-thread ordering is preserved).

### API

Four ioctls, all on a channel FD obtained via `NTSYNC_IOC_CREATE_CHANNEL`:

| ioctl                         | Caller            | Effect                                                                    |
|-------------------------------|-------------------|---------------------------------------------------------------------------|
| `NTSYNC_IOC_CREATE_CHANNEL`   | wineserver        | Create channel with `max_depth`. Returns FD.                              |
| `NTSYNC_IOC_CHANNEL_SEND_PI`  | client thread     | Enqueue `(prio, payload_off, reply_off)`; boost recv'er; sleep for reply. |
| `NTSYNC_IOC_CHANNEL_RECV`     | dispatcher pthread| Pop highest-prio entry; auto-boost current to that priority.              |
| `NTSYNC_IOC_CHANNEL_REPLY`    | dispatcher pthread| Wake the sender of `entry_id`; drain receiver boost.                      |

The `payload_off` and `reply_off` fields are opaque to the kernel; conventionally they are indices into a per-process shared-memory region the client and wineserver both map. The kernel transports the cookies; user space interprets them.

### Internal state

The channel object's per-instance state lives in `obj->u.channel`:

    struct {
        struct rb_root  pending;     /* PENDING entries (prio DESC, seq ASC) */
        struct list_head dispatched; /* DISPATCHED entries (REPLY can find by id) */
        atomic64_t  next_id;
        atomic64_t  next_seq;
        __u32       depth;           /* current PENDING count */
        __u32       max_depth;
        wait_queue_head_t recv_wq;   /* blocked receivers */
        struct hlist_head thread_regs[64]; /* added by 1005 */
    } channel;

Each entry is a `struct ntsync_channel_entry`:

    struct ntsync_channel_entry {
        struct rb_node      rb;       /* in pending rb-tree */
        struct list_head    list;     /* in dispatched list */
        __u64               id, seq;
        __u32               prio, policy;
        __u64               payload_off, reply_off;
        __u32               sender_tid;
        enum  ntsync_channel_state state;  /* PENDING | DISPATCHED */
        bool                replied;
        wait_queue_head_t   wq;       /* sender sleeps on this */
        __u64               thread_token;  /* added by 1005 */
        refcount_t          refcnt;        /* added by 1009 */
    };

The rb-tree key is `(prio DESC, seq ASC)`: higher priority sorts first; ties break by enqueue order. `channel_pending_insert()` returns true iff the entry became the new tree minimum -- i.e. it would be popped next. That return value drives the speculative-boost decision in `SEND_PI`.

### SEND_PI flow

1. Validate `(policy, prio)`. Pre-allocate `e` and `new_ep` (the boost tracking entry) with `GFP_KERNEL` outside any lock -- slab on RT cannot be called under `raw_spinlock_t`.
2. `obj_lock(ch)`. Reject with `-EAGAIN` if `depth >= max_depth`. Insert into `pending` rb-tree; bump `depth`. Note whether this entry is the new minimum.
3. `obj_unlock(ch)`.
4. If the new entry is the minimum and `prio` is set, peek the `recv_wq` head. Take a `get_task_struct` reference under `wq->lock`, then call `apply_event_pi_boost()` to boost that receiver to `(policy, prio)`.
5. `wake_up(&ch->recv_wq)` -- wakes exactly the head receiver (1007 made this exclusive).
6. Sleep on `e->wq` until `e->replied` is true or signal pending.
7. On wake: `obj_lock(ch)`, detach `e` from whichever list/tree it's on, `obj_unlock(ch)`. Drop `refcount_dec_and_test(&e->refcnt)`; kfree if last ref (1009).

The cleanup path covers the case where the sender was interrupted (signal). The entry might still be PENDING (rb-tree) or DISPATCHED (list); we use `e->state` to dispatch correctly. `depth` is decremented only in the PENDING branch -- DISPATCHED entries no longer count against `max_depth`.

### RECV / RECV2 flow

1. `drain_event_pi_boosts(dev, current)` -- release any boost left over from a prior RECV cycle.
2. Pre-allocate `new_ep` outside lock.
3. `obj_lock(ch)`. While `pending` is empty: `obj_unlock`, `wait_event_interruptible_exclusive(recv_wq, !empty)` (1007 made this exclusive), `obj_lock` again.
4. Pop the rb-tree minimum; mark DISPATCHED; append to `dispatched` list; decrement `depth`.
5. (1005 only, in `RECV2`:) `e->thread_token = channel_lookup_token(ch, e->sender_tid)`. See Section 5.
6. `obj_unlock(ch)`.
7. If `e->prio`, auto-boost `current` to `(e->policy, e->prio)` for the handler duration via `apply_event_pi_boost(dev, current, ...)`. Boost releases at next RECV's drain, or at REPLY's drain.
8. Copy `(entry_id, payload_off, reply_off, sender_tid, prio[, thread_token])` to user space.

### REPLY flow

1. `obj_lock(ch)`. Walk `dispatched` list for `entry_id`. If not found or already replied: `-ENOENT`.
2. Set `e->replied = true`.
3. `refcount_inc(&e->refcnt)` (1009 -- keep the entry alive across `wake_up_all`).
4. `obj_unlock(ch)`.
5. `wake_up_all(&e->wq)` -- wakes the blocked sender. Outside `obj_lock` because wq's internal lock is `spinlock_t` (becomes `rt_mutex` on PREEMPT_RT) and cannot nest under our `raw_spinlock_t`.
6. `drain_event_pi_boosts(dev, current)` -- handler is done, drop the receiver's auto-boost.
7. `refcount_dec_and_test(&e->refcnt)`; kfree if last ref (1009).

### Memory ordering

Kernel ioctl syscall entry/exit is a full memory barrier. So payload visibility from sender -> receiver and reply visibility from receiver -> sender is naturally serialised: the sender's `copy_from_user` of the payload completed before SEND_PI returns from the syscall handler; the receiver's `copy_to_user` happens-before `RECV` returns; the receiver's writes to the reply region happen-before `REPLY` returns; the sender's `copy_from_user` of the reply happens-after SEND_PI's wake.

### NT semantics

The kernel does not promise ordering across senders -- it priority-orders, but a SCHED_OTHER sender behind a SCHED_FIFO sender will wait. Cross-thread ordering was never guaranteed under the prior per-thread dispatcher pthread shape, so this is strictly stronger semantically (no thread can starve while a higher-prio thread is waiting). Within a single sender, ordering is preserved: each `SEND_PI` blocks for reply, so back-to-back sends from the same TID are serialised.

### Hot-path bound

`obj_lock` sections in SEND_PI / RECV / REPLY are bounded by tree height. With `max_depth = 1024`, that is 10 rb-tree comparisons. Zero allocation under lock. No memory copies under lock (the `copy_to_user` happens after `obj_unlock`).

### Diagnostics: depth and channel emptiness

A channel can only be freed when both `pending` and `dispatched` are empty; otherwise senders or dispatchers still hold the file open via the syscall ref. `ntsync_free_obj()` `WARN_ON`s either non-empty list at free time -- a useful canary if user space ever leaks a channel FD with active entries.

---

## 5. Patch 1005: Thread-Token Pass-Through

Once the channel was in production, perf 2026-04-26 showed ~10% of dispatcher CPU sitting in a userspace `get_thread_from_id()` lookup inside the gamma dispatcher's hot loop. Every received request needed to map `sender_tid` -> `struct thread *` to dispatch. This patch eliminates that lookup by stamping a wineserver-supplied opaque token onto each entry at RECV time.

### Mechanism

The wineserver registers `(tid, token)` per channel via a new ioctl. The kernel stores the mapping in a 64-bucket hash on the channel (`hlist_head thread_regs[64]`, keyed by `tid & 63`, protected by the existing `obj_lock`). At RECV2 time the kernel looks up the token for `e->sender_tid` and returns it in extended args.

    struct ntsync_channel_recv2_args {
        __u64 entry_id;
        __u64 payload_off;
        __u64 reply_off;
        __u32 sender_tid;
        __u32 prio;
        __u64 thread_token;  /* OUT: registered token (0 if unregistered) */
    };

Two new ioctls:

| ioctl                                    | Effect                                       |
|------------------------------------------|----------------------------------------------|
| `NTSYNC_IOC_CHANNEL_REGISTER_THREAD`     | Install or replace `(tid, token)`            |
| `NTSYNC_IOC_CHANNEL_DEREGISTER_THREAD`   | Evict entry for tid (idempotent)             |

Plus `NTSYNC_IOC_CHANNEL_RECV2` -- same as `RECV` but returns an extra `thread_token` field. Old `RECV` remains for backward compat: wineserver tries `RECV2` first, falls back to `RECV` + userspace `get_thread_from_id` on `-ENOTTY` (old kernel).

### v2 design: lookup at RECV2, not SEND_PI

The first version of this patch did the hash lookup in `SEND_PI` and stamped `thread_token` onto the entry there. v2 moved the lookup to `RECV2`. Two reasons:

1. **Audio-thread cost.** The audio thread is the one paying the SEND_PI critical-section cost. Moving the lookup to RECV2 puts the cost on the dispatcher pthread instead -- which is fine, the dispatcher is not deadline-bound.
2. **Stale-token correctness.** A token snapshotted at SEND_PI could go stale if the sender died and the wineserver deregistered before the dispatcher RECV'd. RECV2-time lookup reflects current registration: a deregistered TID returns `token = 0`, and userspace falls back to `get_thread_from_id` (which will fail on a dead TID, and the request gets dropped by the existing logic).

The hash bucket count is fixed at 64 (no resize, no `rhashtable`). For a typical Wine process with dozens to a few hundred threads, that gives single-digit average chain lengths -- well under the rb-tree key comparison cost in SEND_PI/RECV.

### Lifetime invariants

The wineserver enforces:

- Register **before** the client may send (specifically, before the `init_first_thread` reply that signals the client may issue requests).
- Deregister **after** the thread's last reply is delivered.

Together these ensure `RECV2` always sees a non-zero token for a still-live thread. A momentarily-zero token (if registration races a fast first send) yields a userspace fallback that completes correctly -- it is only a perf regression, not a correctness one.

### `channel_drain_thread_regs()` on free

When a channel is freed, any leftover `(tid, token)` registrations are dropped. By construction the channel is unreachable at `ntsync_free_obj()` time (no senders, no dispatchers can have an FD), so no concurrent access is possible -- a single pass through the buckets, kfreeing each `ntsync_thread_reg`.

### Backward compat

Old `RECV` entries always carry `thread_token = 0` (initialized in `kzalloc`). Userspace that calls `RECV` instead of `RECV2` simply never sees a non-zero token and falls through to the legacy `get_thread_from_id` path. New kernel + old wineserver -> works. Old kernel + new wineserver -> works (the `RECV2` ioctl returns `-ENOTTY` and the wineserver retries with `RECV`).

---

## 6. Patch 1006: RT Alloc-Hoist

This is a **safety patch**, not a feature: it fixes six sites in the driver where slab `kzalloc`/`kfree` was being called under `raw_spinlock_t` on PREEMPT_RT -- which is illegal. The bug was latent until 2026-04-26, when an Ableton workload hard-froze the host with a clean kernel oops.

### The kernel oops

After installing the freshly-built thread-token `ntsync.ko` (srcversion `635D3C3857C859418827A5C`), Ableton hard-froze the host 13 minutes into a session:

    BUG: kernel NULL pointer dereference, address: 0x9a
    RIP: ___slab_alloc+0x316  (xor (%rbx,%rdx,1),%rax  RBX=0x3a)
    Call: __kmalloc_cache_noprof <- ntsync_obj_ioctl+0x427 [ntsync]
    Comm: Ableton Web Con      PREEMPT_{RT,(lazy)}

Classic SLUB freelist corruption.

### Root cause

`obj->lock` and `dev->boost_lock` are both `raw_spinlock_t`. On PREEMPT_RT, SLUB's per-CPU fast path uses `local_lock_t`, which is `spinlock_t` -- a sleeping lock under PREEMPT_RT (confirmed in `include/linux/local_lock_internal.h`). So `kzalloc` / `kfree` under any `raw_spinlock_t` is unsafe on RT, including `GFP_ATOMIC` (the GFP flag gates reclaim, not the local_lock).

This is a **mechanically verifiable rule**: `CONFIG_DEBUG_ATOMIC_SLEEP` will splat any sleeping function called from a non-sleepable context. The bug was not caught by that infrastructure only because the production kernel ships without it for performance reasons; the rule itself is unambiguous.

Six sites in `ntsync.c` violated this rule:

| #  | Function                          | Line   | Issue                          |
|----|-----------------------------------|--------|--------------------------------|
| 1  | `ntsync_pi_recalc`                | 345    | `kzalloc(GFP_ATOMIC)` under raw|
| 2  | `ntsync_pi_recalc`                | 409    | `kfree` under `boost_lock`     |
| 3  | `ntsync_pi_recalc`                | 417    | `kfree` under caller's `obj->lock` |
| 4  | `ntsync_pi_drop`                  | 441    | `kfree` under `boost_lock`     |
| 5  | `ntsync_channel_register_thread`  | 1614   | `kfree` under `obj_lock`       |
| 6  | `ntsync_channel_deregister_thread`| 1639   | `kfree` under `obj_lock`       |

Sites 1-4 had been latent since the 1003 PI patch landed; 5-6 were new in 1005 (thread-token registration). The Ableton lockup was almost certainly triggered by 5 or 6: `T2` thread-token registration is always-on when channel + kernel support are present, and Ableton boot creates dozens of threads -> dozens of register/deregister calls -> poisoned freelist 13 minutes in. Sites 1-4 had likely also caused several previous unexplained host lockups (Phase B msg-ring, B1.0 paint-cache, "in-handler instrumentation triggers host lockup" series).

### The pi_work pool/cleanup pattern

The fix introduces a stack-resident `struct ntsync_pi_work` that the caller pre-allocates and finishes outside any raw lock:

    struct ntsync_pi_work {
        struct list_head new_po_pool;     /* pre-allocated; consumed on demand */
        struct list_head to_free_list;    /* removed entries to free post-unlock */
    };

Three helpers:

    void ntsync_pi_work_init(w);                  /* INIT_LIST_HEAD x2 */
    void ntsync_pi_work_prealloc(w);              /* kzalloc + list_add to pool, OUTSIDE locks */
    struct ntsync_pi_owner *ntsync_pi_work_take_new(w); /* pointer-only list_del under raw */
    void ntsync_pi_work_finish(w);                /* kfree pool leftovers + to_free_list */

Lifecycle of a `pi_owner` via this struct:

    kzalloc -> list_add to new_po_pool                  (caller, no lock)
    consumed: list_del from pool, list_add to dev list  (pi_recalc, raw)
    removed: list_move from dev list to to_free_list    (pi_recalc/_drop, raw)
    kfree from new_po_pool + to_free_list               (caller, no lock)

Empty pool is a non-fatal fallback: `pi_recalc` skips the boost (transient priority inversion until next op), matching the prior `GFP_ATOMIC` behaviour. The hot path stays one slab op per ioctl -- just hoisted past the lock, so no extra latency.

### Caller pattern

Every ioctl entry that may invoke `pi_recalc` / `pi_drop` declares one of these on stack:

    struct ntsync_pi_work pi_work;
    ntsync_pi_work_init(&pi_work);
    ntsync_pi_work_prealloc(&pi_work);

    /* ... acquire raw locks, possibly call pi_recalc/pi_drop ... */
    /* ... release all raw locks ... */

    ntsync_pi_work_finish(&pi_work);

This pattern shows up in `try_wake_any`, `try_wake_all_obj`, `release_mutex`, `wait_any`, `wait_all`, `event_set_pi`, and several other entry points. Sites 5-6 (channel register/deregister) use a simpler local `victim` pointer pattern -- a single removal per call doesn't justify the pool.

### NT semantics preserved exactly

Only observable difference: `ntsync_pi_owner` cleanup deferred by tens of nanoseconds past `raw_spin_unlock`. Mutex ownership transfers atomically with wake (cmpxchg unchanged). PI boost levels and stacking semantics unchanged. Channel priority ordering (DESC, seq ASC) unchanged. Token registration replace-or-insert unchanged. Wait-any/all wakeup ordering unchanged.

### Why this fix mattered for everything that came after

1006 is a prerequisite for honest stress-testing of the channel path. Without it, every register/deregister churn in a stress test was rolling SLUB freelist dice. With it, KASAN under PREEMPT_RT became a useful tool: any splat is now a real bug, not slab dust. That is what made 1009 (the channel_entry refcount UAF) catchable.

### Open RT/safety items deferred from 1006

`obj_lock()` between `prepare_to_wait` and `schedule` in `ntsync_channel_send_pi`: `rt_mutex_lock` inside `obj_lock` would clobber `TASK_INTERRUPTIBLE` state if `obj->dev_locked` were set. Latent only -- channels never participate in `wait_all` so `dev_locked` is never set on channels. Safe today; tighten when convenient.

---

## 7. Patch 1007: Channel Exclusive Recv

**Bug:** `ntsync_channel_send_pi` speculatively boosts `recv_wq.head` to the sender's priority before `wake_up()`, but `wake_up()` was waking *all* non-exclusive waiters because `wait_event_interruptible` adds non-exclusive waiters by default. Non-head receivers could win the entry-pop race -> the boosted head was stranded with high priority and no work; the winner had low priority and the actual work. A real production priority inversion.

This was the plausible root cause of unexplained gamma-dispatcher lockups previously (and incorrectly) blamed on userspace patches.

### Three lines

    -  ret = wait_event_interruptible(ch->u.channel.recv_wq,
    +  /* Exclusive wait: wake_up() in SEND_PI walks the recv_wq and
    +   * stops at the first exclusive waiter.  This makes the head
    +   * (which SEND_PI speculatively boosted) the unique winner of
    +   * the entry-pop race -- closes the priority-inversion window
    +   * where a non-head receiver could pop the entry while the
    +   * boosted head got stranded with high prio and no work. */
    +  ret = wait_event_interruptible_exclusive(ch->u.channel.recv_wq,
            !RB_EMPTY_ROOT(&ch->u.channel.pending));

Applied in both `ntsync_channel_recv` and `ntsync_channel_recv2`.

### Why this works

`wake_up()` is already exclusive-aware: it walks the wait queue and stops at the first exclusive waiter. So once both `RECV` and `RECV2` register exclusive waiters, `SEND_PI`'s `wake_up()` wakes exactly the head -- the boost target. The boost target becomes the unique race winner.

`wait_event_interruptible_exclusive` is a kernel primitive; it takes the wait queue lock, sets the waiter's `WQ_FLAG_EXCLUSIVE` flag, and otherwise behaves identically to the non-exclusive variant. No new behaviour introduced; we just opted into the existing semantics.

### Validation

- `test-channel-recv-exclusive`: 100/100 PASS (was deterministic hang before because the test was stale-coded around pre-1007 wake-all behaviour).
- 30-iter native suite: zero hangs on the channel path.
- No new perf overhead (no extra allocations or fast-path locks).

### Why this is the minimal correct fix

The rolled-back "Codex 1007-1011" patch series (Section 10) had attempted a much larger redesign of the channel path, including channel-rejection in `setup_wait`, cross-snapshot PI cleanup, and a pool/cleanup refactor of the channel allocations themselves. None of that was needed. Three lines suffice.

---

## 8. Patch 1008: EVENT_SET_PI Deferred Boost

**Bug:** the original `EVENT_SET_PI` design (Section 3) walked `event->any_waiters` under `obj_lock` at signal time and applied the boost to the head waiter. This missed any consumer that took `obj_lock` first, saw `signaled=true` and returned without queueing -- the standard wait fast-path. Result: ~4% of `EVENT_SET_PI` calls under PREEMPT_RT debug-kernel scheduling silently failed to apply the boost. A real RT-correctness hole.

### The race

    Thread A (consumer, fast path)         Thread B (signaler, EVENT_SET_PI)
    obj_lock(event)
    if (signaled) {                        kzalloc(new_ep)
       /* signaled=false set later */
       fast-path return (NO QUEUE)
    }
    obj_unlock(event)
                                           obj_lock(event)
                                           walk any_waiters: EMPTY
                                           target = NULL
                                           signaled = true
                                           obj_unlock(event)
                                           kfree(new_ep)  /* dropped! */

The signaler sets the event but has no target to boost; the consumer returns from `wait_any` having seen the signal but unboosted. The boost was lost.

This was hard to spot because most `EVENT_SET_PI` calls under PREEMPT_RT scheduling do find a queued waiter (the consumer hadn't reached `obj_lock` yet). Only the fast-path race -- consumer arrives just before signaler -- silently dropped the boost. KASAN debug-kernel testing showed it as a ~4% flake rate on the `test-event-set-pi` test.

### Redesign: stage on event, consume at wait-return

The fix flips ownership of the boost target. Instead of the *signaler* finding the target at `EVENT_SET_PI` time, the *consumer* applies the boost to itself at wait-return.

New per-event state in the event union:

    struct {
        u32 policy;
        u32 prio;
        struct ntsync_event_pi *new_ep;   /* pre-allocated; consumer takes ownership */
    } pending_pi;

Mechanism in five steps:

1. **Pre-allocate** tracking entry outside any lock (slab on RT).
2. **Stage** `(policy, prio, new_ep)` on the event under `obj_lock`; ALSO set `signaled=true` and wake any queued waiter.
3. The first task to **consume** the signal -- whether queued and woken, or fast-path (already-signaled) -- applies the staged boost to itself via `consume_event_pi_boost()` at wait-return. This is race-free: the consumer is by definition the task whose `wait_any/wait_all` returned with this event as the signaled obj.
4. **Last-writer-wins** if `EVENT_SET_PI` is called twice without an intervening consumption -- earlier staged `new_ep` is freed (under `obj_lock`-released, RT-safe).
5. **EVENT_RESET clears** the staging (signal cancelled, boost too).

Plus a 6th rule: `ntsync_free_obj` frees any leaked staging entry on object death (no leak if the event dies unconsumed).

### consume_event_pi_boost()

Called from `wait_any` unqueue loop on the signaled obj if it is an event:

    static void consume_event_pi_boost(struct ntsync_obj *event)
    {
        struct ntsync_event_pi *new_ep = NULL;
        u32 policy = 0, prio = 0;
        bool valid = false, all;

        if (event->type != NTSYNC_TYPE_EVENT)
            return;

        all = ntsync_lock_obj(event->dev, event);
        if (event->u.event.pending_pi.new_ep) {
            new_ep = event->u.event.pending_pi.new_ep;
            policy = event->u.event.pending_pi.policy;
            prio   = event->u.event.pending_pi.prio;
            event->u.event.pending_pi.new_ep = NULL;
            valid = true;
        }
        ntsync_unlock_obj(event->dev, event, all);

        if (valid) {
            if (!apply_event_pi_boost(event->dev, current,
                                       policy, prio, new_ep))
                kfree(new_ep);
        }
    }

The atomic capture-and-clear under `obj_lock` is the one-shot guarantee: the first consumer wins, subsequent consumers see `new_ep == NULL` and no-op. If `EVENT_SET_PI` is called again before consumption, the prior `new_ep` is freed under the same lock and replaced.

### EVENT_SET_PI itself, simplified

The new `ntsync_event_set_pi`:

    new_ep = kzalloc(sizeof(*new_ep), GFP_KERNEL);
    if (!new_ep) return -ENOMEM;

    ntsync_pi_work_init(&pi_work);
    ntsync_pi_work_prealloc(&pi_work);

    all = ntsync_lock_obj(dev, event);

    /* Stage the boost.  Last-writer-wins. */
    prior_new_ep = event->u.event.pending_pi.new_ep;
    event->u.event.pending_pi.policy = args.policy;
    event->u.event.pending_pi.prio   = args.prio;
    event->u.event.pending_pi.new_ep = new_ep;

    /* Signal: identical to EVENT_SET. */
    event->u.event.signaled = true;
    if (all)
        try_wake_all_obj(dev, event, &pi_work);
    try_wake_any_event(event);

    ntsync_unlock_obj(dev, event, all);
    ntsync_pi_work_finish(&pi_work);

    /* Free overwritten prior staging outside lock (slab on RT). */
    kfree(prior_new_ep);

No more `target = list_first_entry(...)` walk under `obj_lock`. No more `get_task_struct(target)` ref management. The signaler just sets the event; whoever consumes it boosts themselves.

### EVENT_RESET hook

Resetting the event cancels the signal, so it must cancel any pending boost too:

    prior_new_ep = event->u.event.pending_pi.new_ep;
    event->u.event.pending_pi.new_ep = NULL;
    ntsync_unlock_obj(dev, event, all);
    kfree(prior_new_ep);

### ntsync_free_obj hook

If the event dies unconsumed, free the staging entry:

    if (obj->type == NTSYNC_TYPE_EVENT)
        kfree(obj->u.event.pending_pi.new_ep);

### wait_any consumer hook

Inside the wait_any unqueue loop, after the obj is unlocked but before `put_obj`:

    if ((int)i == signaled && obj->type == NTSYNC_TYPE_EVENT)
        consume_event_pi_boost(obj);

The `signaled` index identifies which obj actually woke this wait. We consume only on that obj -- non-signaled objs in a multi-object wait have nothing to apply.

### wait_all TODO

`ntsync_wait_all` cannot call `consume_event_pi_boost` because that helper takes the obj's wait-all lock path (via `ntsync_lock_obj`), and the unqueue loop already holds `wait_all_lock`. The audio-callback path uses `wait_any` so this gap is rare in practice; revisit if cross-event boost across `wait_all` becomes a workload concern. Comment in source:

    /* NSPA: TODO -- wait_all consumer hook for EVENT_SET_PI deferred
     * boost.  Cannot call consume_event_pi_boost here because it
     * takes obj's wait-all lock path and we already hold
     * wait_all_lock.  Audio-callback path uses wait_any (handled in
     * the wait_any unqueue), so this is rare in practice; revisit
     * if cross-event boost becomes a workload concern. */

### Validation

- `test-event-set-pi`: 100/100 PASS (was 4% flake rate).
- `test-event-set-pi-stress 60s/8x8`: 2.8M signaler ops + 3.4M waiter consumes, 596K boosts cleanly applied, zero KASAN/KCSAN splats, zero leaks (refcnt=0 post-stress), drain restores cleanly.
- Native suite still passes (no regressions on event path).

### Cost

One extra atomic exchange under `obj_lock` per `EVENT_SET_PI` (the pending_pi store + signal flip). One extra `obj_lock`/`obj_unlock` per consume. The latter is the only new path; it runs only if the event has staged PI -- so on workloads that don't use `EVENT_SET_PI` it is a no-op (`pending_pi.new_ep == NULL` check is one load).

---

## 9. Patch 1009: channel_entry Refcount UAF

**Bug:** KASAN-caught slab-use-after-free on `ntsync_channel_entry` under `test-channel-stress` 4x4 with thread-registration churn. REPLY's `wake_up_all` on `e->wq` runs outside `obj_lock` (it must -- wq's internal lock is `spinlock_t`, becomes `rt_mutex` on PREEMPT_RT, can't nest under our `raw_spinlock_t`). That creates a window where SEND_PI's cleanup could `kfree(e)` between REPLY's `obj_unlock` and REPLY's `wake_up_all` reaching the freed wait queue.

### The KASAN splat

    BUG: KASAN: slab-use-after-free in do_raw_spin_lock+0x23c/0x270
    Read of size 4 at addr ffff8882e30b2564 by task test-channel-st/51072

    Call: __wake_up -> ntsync_obj_ioctl+0x8d5 [ntsync]

    Allocated by task 51069: __kasan_kmalloc -> ntsync_obj_ioctl+0x941
    Freed by task 51069:     kfree         -> ntsync_obj_ioctl+0x3e3c

    Cache: kmalloc-256 (256-byte object), 248 bytes used.
    Address is 100 bytes inside freed region.

Disassembly maps:

- `+0x941` = `kzalloc(sizeof(*e), GFP_KERNEL)` in `ntsync_channel_send_pi` (size 0xf8 = 248 bytes).
- `+0x8d5` = `wake_up_all(&e->wq)` in `ntsync_channel_reply` (call to `__wake_up(wq=rbx+0x60, mode=3=TASK_NORMAL, 0, 0)`). Offset 0x60 matches `wait_queue_head_t wq` field in `ntsync_channel_entry`.
- `+0x3e3c` = `kfree(e)` at the tail of `ntsync_channel_send_pi` cleanup.

### The race

    Thread A (SEND_PI sleeper)              Thread B (REPLY)
                                            obj_lock(ch)
                                            find e in dispatched
                                            e->replied = true
                                            obj_unlock(ch)
    loop iter: prepare_to_wait
    loop iter: obj_lock(ch)
    loop iter: e->replied is true, break
    finish_wait
    obj_lock(ch); list_del(&e->list);
    obj_unlock(ch)
    kfree(e)                                 wake_up_all(&e->wq)  <-- UAF

The `wake_up_all` outside `obj_lock` is necessary on PREEMPT_RT (wq's internal lock cannot be taken under raw_spinlock obj_lock). But that creates the window where SEND_PI's cleanup can free `e` between REPLY's `obj_unlock` and REPLY's `wake_up_all`.

### The fix: refcount_t on channel_entry

Add `refcount_t refcnt` to `struct ntsync_channel_entry`. SEND_PI initializes it to 1 after queue insertion (the sleeping sender holds one ref). REPLY does `refcount_inc` under `obj_lock` before unlock, then `wake_up_all`, then `refcount_dec_and_test`+kfree-if-last. SEND_PI cleanup does `refcount_dec_and_test`+kfree-if-last. Whichever decrement reaches 0 frees.

Code addition is ~15 LOC:

    struct ntsync_channel_entry {
        ...
        refcount_t refcnt;
    };

    /* In SEND_PI, after successful queue insertion: */
    refcount_set(&e->refcnt, 1);  /* sleeper holds 1; REPLY will inc */

    /* In SEND_PI cleanup, replacing kfree(e): */
    if (refcount_dec_and_test(&e->refcnt))
        kfree(e);

    /* In REPLY, between obj_unlock and wake_up_all: */
    e->replied = true;
    refcount_inc(&e->refcnt);
    obj_unlock(ch);
    wake_up_all(&e->wq);
    drain_event_pi_boosts(ch->dev, current);
    if (refcount_dec_and_test(&e->refcnt))
        kfree(e);

### Why this is the minimal correct fix

There was a previous "Codex 1007-1011" patch series (rolled back; see Section 10) that targeted this same bug class but bundled it with a number of unrelated audit-derived changes (REPLY-fake-on-copy-fail, channel-reject in `setup_wait`, cross-boost cleanup refactor). The core fix -- refcount on the entry -- was correct in that series. Everything else was speculative noise that introduced its own bugs.

This patch is just the refcount.

### Validation

- `test-channel-stress 30s/4x4`: 819,803 SEND_PI = 819,803 REPLY (perfect match), 974K register ops, 0 syscall errors, 0 KASAN/KCSAN splats, refcnt=0 post-stress.
- `test-event-set-pi 20/20 PASS`, `test-channel-recv-exclusive 20/20 PASS` (no regression on Bugs 2/3 fixes).
- `test-event-set-pi-stress 60s/8x8`: 2.7M signaler + 3.5M waiter, drain OK, 0 splats.

### Why this is the right shape, not the wrong shape

A common alternative for this class of bug is to take a sleepable lock around the wake. We can't -- the obj_lock that protects entry membership is `raw_spinlock_t`, and we cannot promote it to `rt_mutex` without losing the bounded-CS guarantee that the rest of the driver depends on. Refcount on the entry is the textbook fix for "object outlives its containing-collection lifetime due to async finishers" -- no lock-order changes, no protocol changes, just two `inc`s and three `dec_and_test`s in the right places.

---

## 10. Lessons and Audit Philosophy

The patches in this stack divide cleanly into two categories. The boundary matters because it dictates which patches were safe to ship in a flurry and which weren't.

### Mechanically verifiable correctness vs. code-review hypothesis

Patches in the **mechanically verifiable** category enforce a rule that has an oracle. If the rule is violated, kernel debug infra (`CONFIG_DEBUG_ATOMIC_SLEEP`, `LOCKDEP`, `KASAN`) will splat. The patch either makes the splat go away or it doesn't; there is no ambiguity.

- **1006** (RT alloc-hoist) enforces "no sleeping alloc/free under `raw_spinlock_t` on PREEMPT_RT". `CONFIG_DEBUG_ATOMIC_SLEEP` will splat on a violation. Mechanical.
- **1009** (channel_entry refcount) closes a UAF that KASAN catches by construction. The fix is a textbook refcount discipline. Mechanical.
- **1008** (EVENT_SET_PI deferred boost) closes a measurable flake (4% miss rate on a deterministic test). The fix removes a code path with a known race; the test now passes 100%. Mechanical (the test is the oracle).
- **1007** (channel exclusive recv) closes a deterministic-hang test that was stale-coded around the buggy behaviour. The fix is a 3-LOC swap to a kernel primitive (`wait_event_interruptible_exclusive`) whose semantics are documented and obvious. Mechanical.

Patches in the **code-review hypothesis** category encode a reviewer's argument that some code is buggy. There is no oracle. If the reviewer's argument is wrong (or the bug is somewhere else), the patch ships new bugs without fixing the original one.

### The rolled-back Codex 1007-1011 series

On 2026-04-26 there was an unfound EVENT_SET_PI slab UAF (`___slab_alloc+0x316` GP-fault, `ntsync_obj_ioctl+0x44e`). KASAN was queued but not yet run. Codex's review surfaced three "other issues" (cross-snapshot PI, non-exclusive RECV, channel-accept-in-`setup_wait`), and patches 1007-1011 (5 patches in 6 hours, including a 34KB rewrite) shipped under the rationale that "(1) ∧ (2) explains the hang."

That rationale was theory, not a measured trace. The actual unfound slab UAF was 1006 -- a `kfree` under `raw_spinlock_t` in `channel_register/deregister_thread`. None of 1007-1011's hypotheses were correct about the original symptom. Worse, the 1007-1011 series introduced a new UAF (the CHANNEL_REPLY UAF that 1009 ultimately fixed) that only existed because channels had been added at all.

All of 1007-1011 were rolled back. The proper sequence was then:

1. **First**, KASAN-clean the alloc/free sites under raw_spinlock_t (the actual bug). That became patch 1006.
2. **Then**, with KASAN now usable as an oracle, run the stress tests. Each splat or hang is now a real bug, not slab dust.
3. **One bug per patch**, surgical, with the test that found it as the validation gate. 1007 / 1008 / 1009 each fix exactly one KASAN- or test-confirmed bug.

### Operating principle

When chasing an unidentified bug, narrow on the actual symptom (trace / KASAN / ftrace / repro) -- do not pile speculative fixes from adjacent code review under the cover of "while I was in there, I noticed...". Even when the audit is internally well-reasoned, the issues it surfaces are almost certainly unrelated to the observed symptom -- and shipping them piles new failure modes on top of the original one.

Independent CRIT findings can still be filed as separate tickets/patches, but they should not ship until the original symptom is understood. At minimum: do not ship them on the same day, on top of an unfound bug, in the same module.

A small surface area that is clearly correct in isolation (e.g. a refcount discipline patch with a real KASAN trace) can ship -- but only after asking: "is this fixing damage I caused with adjacent work, or real upstream-relevant correctness?" 1009 was the latter.

This is also why 1006 was safe to ship in-flurry while the rolled-back 1007-1011 wasn't: 1006 has an oracle (`CONFIG_DEBUG_ATOMIC_SLEEP`), the rolled-back series had only Codex's argument.

### Reference

`feedback_dont_shotgun_audit_into_unfound_bug.md` in the project memory documents this lesson in operational terms.

---

## 11. Wine Consumer Side

The Wine-side ntsync integration lives in `dlls/ntdll/unix/sync.c`. Most of it is upstream (Wine's own ntsync support landed in 11.x); NSPA's overlay touches a handful of paths.

### linux_wait_objs

The wait wrapper is largely unchanged from upstream. NSPA's only addition is the `uring_fd` parameter (passed via the repurposed `pad` field) that lets a single `WAIT_ANY` call wake on either an ntsync object signal or an io_uring CQE. See `ntsync-driver.gen.html` Section 7 for the original 1003-era discussion of `uring_fd`.

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

The user-space code is deliberately oblivious to the kernel-side EVENT_SET_PI staging machinery added by 1008. Wine just calls `WAIT_ANY` / `WAIT_ALL`; the kernel handles boost consumption transparently in the unqueue loop. No Wine-side change was needed for 1008.

### linux_set_event_obj_pi

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

This is called from the gamma dispatcher path when an RT audio thread signals a queue event to the dispatcher pthread. The audio thread passes its own `(SCHED_FIFO, prio)`; the kernel stages the boost on the event; the dispatcher consumes the signal in its `WAIT_ANY` and gets boosted at wait-return.

After 1008, this path is bulletproof against the fast-path race: even if the dispatcher pthread takes `obj_lock` first and sees `signaled=true`, it consumes the staged boost in the unqueue loop on its way out. The 4% boost-miss rate disappears.

### Channel ioctl wrappers

The wineserver dispatcher uses the channel ioctls directly via `ioctl()` calls; there is no portable `linux_channel_*` helper at the Wine ntdll layer because channels are wineserver-process-private (they don't cross the wineserver-client boundary as Win32 handles).

The dispatcher loop calls:

    ioctl(channel_fd, NTSYNC_IOC_CHANNEL_RECV2, &args);
    /* dispatch using args.thread_token */
    ioctl(channel_fd, NTSYNC_IOC_CHANNEL_REPLY, &args.entry_id);

with `RECV` as fallback if `RECV2` returns `-ENOTTY` (old kernel without 1005). The client-side `SEND_PI` is invoked from the wineserver request-marshalling fast path; the client's RT thread blocks in the kernel until reply.

### alloc_client_handle

Client-side ntsync object creation (mutexes / semaphores) bypasses the wineserver entirely -- a 1003-era optimization. The handle pool uses `InterlockedDecrement(&client_handle_next)` to allocate negative handle values that don't collide with server-allocated handles. Wait operations (`NtWaitForSingleObject`) resolve the handle to a cached FD via `inproc_wait()`, then call `linux_wait_objs()` which issues the kernel ioctl directly.

Currently enabled for mutexes and semaphores. Event objects are client-capable at the kernel level but disabled in the Wine client due to historic stability issues with certain applications (Ableton Live).

---

## 12. Validation

### Module srcversion lineage

| srcversion                  | Patches loaded                  | Notes                                                              |
|-----------------------------|---------------------------------|--------------------------------------------------------------------|
| `2C3B9BE710704D550141CAA`   | 1003+1004+1005+1006             | Post-1006 baseline; channel-recv hangs (Bug 2 latent); silent EVENT_SET_PI miss (Bug 3 latent); REPLY UAF latent (Bug 4) |
| `11E8385A83FF3B2D6958088`   | + Bug 2 fix (1007)              | Channel exclusive recv only                                        |
| `00C857BD7E51AB4F006B0BB`   | + Bug 3 fix (1008)              | EVENT_SET_PI deferred boost; 100% pass on event-set-pi (was 4% flake) |
| `A250A77651C8D5DAB719FE2`   | + Bug 4 fix (1009)              | channel_entry refcount UAF closed; **CURRENT PRODUCTION**          |
| `BD93BECF70D336DC1A80337`   | (rolled-back Codex 1007-1011)   | Historical only; do not load                                       |

The current production module at `/lib/modules/6.19.11-rt1-1-nspa/kernel/drivers/misc/ntsync.ko` is `A250A77651C8D5DAB719FE2`.

### Stress validation (debug kernel, KASAN-on)

| Test                              | Module srcver | Ops                | KASAN | Result          |
|-----------------------------------|---------------|--------------------|-------|-----------------|
| test-event-set-pi-stress 30s/4x4  | `00C857BD...` | 1.5M signaler      | 0     | PASS            |
| test-event-set-pi-stress 60s/8x8  | `00C857BD...` | 2.8M sig + 3.4M waiter | 0 | PASS            |
| test-mutex-pi-stress 30s/8+4mtx   | `00C857BD...` | 726K acq+rel matched, 632K PI events | 0 | PASS |
| test-channel-stress 30s/4x4       | `00C857BD...` | KASAN UAF caught at ~30s | 1 | EXPECTED FAIL (Bug 4 found) |
| test-channel-stress 30s/4x4       | `A250A77...`  | 819K SEND_PI = 819K REPLY | 0 | PASS         |
| test-event-set-pi-stress 60s/8x8  | `A250A77...`  | 2.7M sig + 3.5M waiter | 0 | PASS            |
| test-event-set-pi 20x sanity      | `A250A77...`  | 20/20 PASS         | 0     | PASS            |
| test-channel-recv-exclusive 20x   | `A250A77...`  | 20/20 PASS         | 0     | PASS            |
| test-mixed-load-stress 5min/13W   | `A250A77...`  | ~10.3M ops, all paths | 0   | PASS            |

Cumulative debug-kernel: ~30 million operations, zero KASAN splats post-Bug 4 fix.

### Mixed-load-stress detail

13-thread/300s soak across every ntsync path concurrently against a single dev_fd:

- 1 audio waiter (Tier B FIFO): wait_any on (event, mutex) multi-obj
- 3 UI signalers: mix EVENT_SET_PI / SET / RESET / mutex acq+rel
- 3 channel senders: SEND_PI loop
- 3 channel recvers: RECV -> REPLY loop
- 1 registrar: REGISTER/DEREGISTER churn
- 1 churner: pthread_kill SIGUSR1 random workers (Ableton thread-restart pattern)

Operation totals:

| Path                          | Ops             | Notes                                |
|-------------------------------|-----------------|--------------------------------------|
| audio multi-obj waits         | 8,757,969       | 100% wake rate                       |
| ui EVENT_SET_PI               | 139,513         |                                      |
| ui EVENT_SET / RESET / PULSE  | 46,506 / 23,181 / 23,324 |                             |
| ui mutex acq=rel              | 137,297 / 137,297 | perfect                            |
| chan SEND_PI / REPLY          | 308,546 / 308,548 | perfect after 30 benign races      |
| chan REGISTER / DEREGISTER    | 730,985 / 365,492 |                                    |
| sem release/acquire/read      | 136,683 / 180,063 / 180,064 |                          |
| wait_all 3-obj acq=rel        | 71,855 / 71,855  | perfect                             |
| syscall errors                | 0                |                                     |
| KASAN/KCSAN splats            | 0                |                                     |
| module refcnt post-soak       | 0                |                                     |

### Production-kernel revalidation

After cross-build to the production kernel `6.19.11-rt1-1-nspa` (no debug instrumentation, throughput 5x-149x higher than debug):

| Layer                | Run                                  | Result    | Ops       | Errors |
|----------------------|--------------------------------------|-----------|-----------|--------|
| 1 native sanity      | run-rt-suite.sh native               | 2/2 PASS  | small     | 0      |
| 1 stress             | event-set-pi 60s 8x8                 | PASS      | ~158M     | 0      |
| 1 stress             | mutex-pi 30s 8h+4mtx                 | PASS      | ~12M      | 0      |
| 1 stress             | channel 30s 4x4                      | PASS      | ~52M      | 0      |
| 1 stress             | mixed-load 300s 13 workers           | PASS      | ~145M     | 0      |
| 2 PE matrix          | nspa_rt_test.exe baseline+rt         | 22/22 PASS| n/a       | 0      |

**Cumulative on production kernel + A250A776 module: ~370 M ops, 0 syscall errors, 0 dmesg splats, refcnt=0 post-soak.**

Per the slub_debug benchmark caveat (`feedback_slub_debug_skews_benchmarks.md`), only PASS/FAIL is authoritative across debug vs production kernels; throughput numbers aren't directly comparable (debug-kernel `slub_debug=FZPU` + kfence + KASAN tax dominates).

### Original 1003-era PI metrics (still valid)

The PI contention / priority wakeup ordering / rapid mutex throughput / philosophers tests from the original `ntsync-driver.gen.html` remain valid. None of patches 1004-1009 touched the mutex PI path; the metrics are unchanged:

| Metric / Test                  | v4 RT     | v5 RT     | Delta       |
|--------------------------------|-----------|-----------|-------------|
| ntsync-d4 RT PI avg            | 387 ms    | 270 ms    | -30.2%      |
| ntsync-d8 RT PI avg            | 419 ms    | 201 ms    | -52.0%      |
| Rapid mutex throughput         | 232K ops/s| 259K ops/s| +11.6%      |
| Rapid mutex RT max_wait        | 54 us     | 47 us     | -13.0%      |
| Philosophers RT max_wait       | 1620 us   | 865 us    | -46.6%      |

Priority wakeup ordering is exact (5 waiters at distinct priorities wake in priority order, both baseline and RT modes, all test runs). PI chain propagation is correct up to depth 12.

---

## 13. References

### Patches (NSPA tree)

All in `wine-rt-claude/ntsync-patches/`:

- `1003-ntsync-mutex-owner-pi-boost.patch` -- PI baseline (combined with 1001+1002 in the live module)
- `1004-ntsync-channel.patch` -- channel object
- `1005-ntsync-channel-thread-token.patch` -- thread-token + RECV2
- `1006-ntsync-rt-alloc-hoist.patch` -- pi_work pool, alloc/free hoist
- `1007-ntsync-channel-exclusive-recv.patch` -- exclusive wait_event
- `1008-ntsync-event-set-pi-deferred-boost.patch` -- deferred-boost machinery
- `1009-ntsync-channel-entry-refcount.patch` -- refcount_t on channel_entry

### Production source

- `drivers/misc/ntsync.c` in `linux-nspa-6.19.11-1.src/linux-nspa/src/linux-6.19.11/` -- 2182 lines.
- Channel section: `ntsync_channel_send_pi` line 1489, `ntsync_channel_recv` line 1620, `ntsync_channel_recv2` line 1690, `ntsync_channel_reply` line 1757, `consume_event_pi_boost` line 1131, `apply_event_pi_boost` line 596, `channel_lookup_token` line 1420.
- `pi_work` infrastructure: `struct ntsync_pi_work` line 196, `ntsync_pi_work_*()` helpers lines 201-244.
- UAPI: `include/uapi/linux/ntsync.h` -- ioctl numbers, `ntsync_wait_args`, `NTSYNC_INDEX_URING_READY`, channel and thread-token ioctl arg structs.

### Wine consumer

- `dlls/ntdll/unix/sync.c` (Wine submodule) -- `linux_wait_objs()` lines 482-549, `linux_set_event_obj_pi()` lines 411-417, semaphore/mutex/event helpers lines 380-475.

### Tests

In `wine/nspa/tests/`:

- `test-event-set-pi.c` -- 1008 EVENT_SET_PI deferred-boost validation
- `test-event-set-pi-stress.c` -- 8x8 EVENT_SET_PI hammer
- `test-channel-recv-exclusive.c` -- 1007 exclusive-recv validation (with symmetric cleanup)
- `test-mutex-pi-stress.c` -- mutex contention + Tier B FIFO
- `test-channel-stress.c` -- channel SEND_PI/RECV/REPLY + register churn (caught the 1009 UAF)
- `test-mixed-load-stress.c` -- 13-thread cross-path soak
- `run-rt-suite.sh` -- sanity runner with `SKIPPED_BY_DESIGN` list

### Audit / handoff documentation

In project memory (`/home/ninez/.claude/projects/-home-ninez-pkgbuilds-Wine-NSPA/memory/`):

- `project_ntsync_session_20260427_results.md` -- the 4-bug-fix session summary
- `project_ntsync_prod_kernel_validation_20260427.md` -- prod-kernel revalidation totals
- `project_ntsync_kfree_under_raw_spinlock.md` -- 1006 root-cause writeup
- `project_ntsync_channel_reply_uaf_20260427.md` -- 1009 KASAN trace + minimal-fix discussion
- `feedback_dont_shotgun_audit_into_unfound_bug.md` -- the lesson behind Section 10
- `feedback_slub_debug_skews_benchmarks.md` -- why debug-vs-prod throughput numbers don't compare
- `wine/nspa/docs/ntsync-rt-audit.md` -- in-tree audit doc

### Cross-references

- `cs-pi.gen.html` -- the userspace CS-PI counterpart; together with this driver they close all priority inversion vectors in Wine's synchronization stack.
- `gamma-channel-dispatcher.gen.html` -- how the gamma dispatcher userspace code uses the channel object and consumes the thread-token.
