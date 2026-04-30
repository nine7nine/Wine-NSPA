# Wine-NSPA -- Aggregate-Wait and Async Completion

Wine 11.6 + NSPA RT patchset | Kernel patch 1010 + Gamma dispatcher Phase 2/3 | 2026-04-29
Author: Jordan Johnston

This page documents the **landed** aggregate-wait work in Wine-NSPA:

- kernel patch **1010**: `NTSYNC_IOC_AGGREGATE_WAIT`
- userspace **Phase 2**: per-process dispatcher-owned `io_uring`
- userspace **Phase 3**: gamma dispatcher waits on channel + uring eventfd + shutdown eventfd and drains CQEs inline on the same RT thread

**Status:** shipped and validated. `NSPA_AGG_WAIT` is **default-on** as of 2026-04-29. The still-WIP async `create_file` port is intentionally excluded here.

---

## Table of contents

1. [Overview](#1-overview)
2. [Why the old bridge was wrong](#2-why-the-old-bridge-was-wrong)
3. [Kernel patch 1010](#3-kernel-patch-1010)
4. [Wine-NSPA Phase 2 and Phase 3](#4-wine-nspa-phase-2-and-phase-3)
5. [Validation and deployment](#5-validation-and-deployment)
6. [Relationship to the broader decomposition plan](#6-relationship-to-the-broader-decomposition-plan)
7. [References](#7-references)

---

## 1. Overview

The aggregate-wait slice closes a specific architectural gap in the gamma dispatcher.

Gamma already gave Wine-NSPA the correct **request-side** priority inheritance story:
client threads do `CHANNEL_SEND_PI`, the kernel enqueues by priority, and the wineserver
dispatcher runs the handler at the right effective priority. What gamma lacked was a
correct **async completion-side** wait primitive.

The first async-completion prototype used the wineserver main thread as the CQE drain
site. That proved the basic mechanism but broke the more important invariant: the thread
that received the request was no longer the thread that completed and replied to it.

Patch 1010 and the accompanying dispatcher restructure fix that. The dispatcher now owns
all three parts of the async path:

1. receive request from the channel
2. submit deferred work to its per-process `io_uring`
3. drain completion and issue `CHANNEL_REPLY`

The same RT thread handles the full lifecycle.

### What shipped

| Layer | Landed change | Why it matters |
|---|---|---|
| Kernel | `NTSYNC_IOC_AGGREGATE_WAIT` | One wait covers NTSync objects plus pollable fds |
| Kernel | Channel notify-only support inside aggregate-wait | lets the dispatcher block on the channel without consuming the entry in the aggregate ioctl itself |
| Kernel | follow-up PI fixes (`072bfee`) | stable boost propagation for aggregate-waiting dispatchers |
| Userspace | `struct nspa_uring_instance` per process | dispatcher-local ring + eventfd + fixed pending pool |
| Userspace | `struct nspa_dispatcher_ctx` | single owner for channel fd, shutdown eventfd, and ring lifetime |
| Userspace | aggregate-wait dispatcher loop | same-thread request receive, CQE drain, and reply |

### What did not ship here

The first async `create_file` handler port is still WIP and currently default-off. That
work uses the same infrastructure, but it is not part of the stable public story yet.

---

## 2. Why the old bridge was wrong

The rejected shape was:

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 470" xmlns="http://www.w3.org/2000/svg">
  <style>
    .bg { fill: #1a1b26; }
    .lane { stroke: #3b4261; stroke-width: 1.2; stroke-dasharray: 6,4; }
    .box { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .bad { fill: #2a1a1a; stroke: #f7768e; stroke-width: 2; rx: 8; }
    .note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .r { fill: #f7768e; font: bold 10px 'JetBrains Mono', monospace; }
    .y { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .line { stroke: #c0caf5; stroke-width: 1.4; fill: none; }
  </style>
  <defs>
    <marker id="badArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="980" height="470" class="bg"/>
  <text x="490" y="26" text-anchor="middle" class="h">Rejected cross-thread bridge</text>

  <text x="250" y="62" text-anchor="middle" class="t">Dispatcher pthread</text>
  <text x="730" y="62" text-anchor="middle" class="r">Wineserver main thread</text>
  <line x1="250" y1="76" x2="250" y2="360" class="lane"/>
  <line x1="730" y1="76" x2="730" y2="360" class="lane"/>

  <rect x="120" y="96" width="260" height="58" class="box"/>
  <text x="250" y="120" text-anchor="middle" class="t">`CHANNEL_RECV2`</text>
  <text x="250" y="140" text-anchor="middle" class="s">dispatcher owns request entry</text>

  <rect x="120" y="188" width="260" height="78" class="box"/>
  <text x="250" y="212" text-anchor="middle" class="t">handler submits SQE</text>
  <text x="250" y="232" text-anchor="middle" class="s">deferred path returns to channel receive loop</text>
  <text x="250" y="250" text-anchor="middle" class="s">completion is now somebody else’s problem</text>

  <rect x="600" y="96" width="260" height="58" class="bad"/>
  <text x="730" y="120" text-anchor="middle" class="t">`main_loop_epoll`</text>
  <text x="730" y="140" text-anchor="middle" class="s">main thread owns uring wake</text>

  <rect x="600" y="188" width="260" height="92" class="bad"/>
  <text x="730" y="212" text-anchor="middle" class="t">CQE arrives later</text>
  <text x="730" y="232" text-anchor="middle" class="s">main thread drains CQE</text>
  <text x="730" y="250" text-anchor="middle" class="s">callback restores state and writes reply</text>
  <text x="730" y="268" text-anchor="middle" class="s">`CHANNEL_REPLY` issued cross-thread</text>

  <path d="M380 227 C480 227, 520 227, 600 227" class="line" marker-end="url(#badArrow)"/>
  <path d="M600 305 C520 320, 460 328, 380 338" class="line" marker-end="url(#badArrow)"/>

  <rect x="150" y="386" width="680" height="56" class="note"/>
  <text x="490" y="410" text-anchor="middle" class="y">Why it was rejected</text>
  <text x="490" y="426" text-anchor="middle" class="s">completion timing and reply ordering now depend on main-thread wake timing</text>
  <text x="490" y="440" text-anchor="middle" class="s">and contention, not on dispatcher availability</text>
</svg>
</div>

The problem was not that the code path was impossible. The problem was that it was the
wrong ownership model for an RT request path:

- submission happened on the dispatcher thread
- completion wake happened on the main thread
- reply signaling happened on the main thread
- the gamma request path lost its single-thread execution invariant

That shape showed up exactly where expected: real workloads tolerated it structurally,
but timing-sensitive application behavior did not.

---

## 3. Kernel patch 1010

Patch 1010 adds `NTSYNC_IOC_AGGREGATE_WAIT`: a heterogeneous wait that combines
NTSync object sources, pollable fd sources, and an optional absolute deadline.

The dispatcher is the first consumer, but the primitive is intentionally general.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .bg { fill: #1a1b26; }
    .obj { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .fd  { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .mid { fill: #1f2535; stroke: #bb9af7; stroke-width: 2; rx: 8; }
    .note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .v { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
    .line { stroke: #c0caf5; stroke-width: 1.4; fill: none; }
  </style>
  <defs>
    <marker id="aggArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="980" height="420" class="bg"/>
  <text x="490" y="28" text-anchor="middle" class="h">Patch 1010: heterogeneous wait surface</text>

  <rect x="50" y="92" width="240" height="110" class="obj"/>
  <text x="170" y="118" text-anchor="middle" class="g">Object sources</text>
  <text x="170" y="142" text-anchor="middle" class="t">event / mutex / semaphore</text>
  <text x="170" y="160" text-anchor="middle" class="t">channel notify-only source</text>
  <text x="170" y="178" text-anchor="middle" class="s">PI-visible registration for NTSync-backed sources</text>

  <rect x="370" y="74" width="240" height="146" class="mid"/>
  <text x="490" y="102" text-anchor="middle" class="v">`NTSYNC_IOC_AGGREGATE_WAIT`</text>
  <text x="490" y="128" text-anchor="middle" class="t">copy source array</text>
  <text x="490" y="146" text-anchor="middle" class="t">register object waits and poll waits</text>
  <text x="490" y="164" text-anchor="middle" class="t">sleep once</text>
  <text x="490" y="182" text-anchor="middle" class="t">return `fired_index` + `fired_events`</text>
  <text x="490" y="200" text-anchor="middle" class="s">deadline expiry returns `NTSYNC_AGG_TIMEOUT`</text>

  <rect x="690" y="92" width="240" height="110" class="fd"/>
  <text x="810" y="118" text-anchor="middle" class="t">FD sources</text>
  <text x="810" y="142" text-anchor="middle" class="t">uring eventfd</text>
  <text x="810" y="160" text-anchor="middle" class="t">future fd-poll / timer wake sources</text>
  <text x="810" y="178" text-anchor="middle" class="s">poll semantics, no intrinsic PI owner</text>

  <path d="M290 147 C320 147, 340 147, 370 147" class="line" marker-end="url(#aggArrow)"/>
  <path d="M690 147 C660 147, 640 147, 610 147" class="line" marker-end="url(#aggArrow)"/>

  <rect x="160" y="286" width="660" height="74" class="note"/>
  <text x="490" y="312" text-anchor="middle" class="t">Kernel follow-ups required for production stability</text>
  <text x="490" y="330" text-anchor="middle" class="s">`072bfee` added SEND_PI any-waiters fallback and wake-after-boost ordering</text>
  <text x="490" y="344" text-anchor="middle" class="s">so aggregate-waiting dispatchers inherit priority correctly</text>
</svg>
</div>

### UAPI shape

```c
struct ntsync_aggregate_source {
    __u32 type;          /* NTSYNC_AGG_OBJECT | NTSYNC_AGG_FD */
    __u32 events;        /* FD source: POLLIN / POLLOUT / POLLERR / POLLHUP */
    __u64 handle_or_fd;  /* ntsync object handle, or unix fd */
};

struct ntsync_aggregate_wait_args {
    __u32 nb_sources;
    __u32 reserved;
    __u64 sources;       /* user pointer to struct ntsync_aggregate_source[] */
    struct __kernel_timespec deadline; /* CLOCK_MONOTONIC ABSTIME or {0,0} */
    __u32 fired_index;
    __u32 fired_events;
    __u32 flags;
    __u32 owner;
};

#define NTSYNC_AGG_OBJECT        0x1
#define NTSYNC_AGG_FD            0x2
#define NTSYNC_AGG_MAX           64
#define NTSYNC_AGG_FLAG_REALTIME 0x1
#define NTSYNC_AGG_TIMEOUT       0xFFFFFFFFu
#define NTSYNC_IOC_AGGREGATE_WAIT _IOWR('N', 0x95, struct ntsync_aggregate_wait_args)
```

### Semantics that matter for gamma

- **Channel participation is notify-only.** Aggregate-wait tells userspace that the
  channel source fired; userspace still follows up with `CHANNEL_RECV2` to consume
  the actual entry.
- **Object-source PI remains visible.** The dispatcher blocked inside aggregate-wait
  must still be discoverable by the existing channel and event PI paths.
- **Pre-1010 kernels are supported.** Userspace detects `-ENOTTY` on the first
  aggregate-wait attempt and permanently falls back to the legacy direct
  `CHANNEL_RECV2` loop for that dispatcher.

That last point is operationally important: public docs can describe the new default
without pretending the code lost its rollback path.

---

## 4. Wine-NSPA Phase 2 and Phase 3

### 4.1 Phase 2: dispatcher-owned `io_uring`

Phase 2 did not make handlers async by itself. It put the ring and its state in the
correct ownership domain first.

The old global-ring direction was abandoned. The landed design keeps one
`nspa_uring_instance` **per gamma channel / per Wine process**, stored alongside the
dispatcher context.

```c
struct nspa_dispatcher_ctx {
    int channel_fd;
    int shutdown_efd;
    struct nspa_uring_instance uring;
};
```

Key properties:

- one submitter per ring
- one CQE drainer per ring
- ring lifecycle ends with the dispatcher that owns it
- `shutdown_efd` gives the aggregate-wait path an explicit teardown wakeup

### 4.2 Phase 3: aggregate-wait dispatcher loop

The dispatcher now waits on three sources:

1. **channel object**: request available
2. **uring eventfd**: completion available
3. **shutdown eventfd**: process teardown requested

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 560" xmlns="http://www.w3.org/2000/svg">
  <style>
    .bg { fill: #1a1b26; }
    .ctx { fill: #1f2535; stroke: #bb9af7; stroke-width: 2; rx: 8; }
    .chan { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .fast { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 8; }
    .note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .v { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
    .y { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .line { stroke: #c0caf5; stroke-width: 1.4; fill: none; }
  </style>
  <defs>
    <marker id="dispArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="980" height="560" class="bg"/>
  <text x="490" y="28" text-anchor="middle" class="h">Phase 3 dispatcher topology</text>

  <rect x="290" y="70" width="400" height="84" class="ctx"/>
  <text x="490" y="98" text-anchor="middle" class="v">Dispatcher context</text>
  <text x="490" y="122" text-anchor="middle" class="t">channel fd + shutdown eventfd + `nspa_uring_instance`</text>
  <text x="490" y="140" text-anchor="middle" class="s">one context per Wine process, freed by the dispatcher on exit</text>

  <rect x="80" y="212" width="250" height="118" class="chan"/>
  <text x="205" y="238" text-anchor="middle" class="t">source 0: channel object</text>
  <text x="205" y="262" text-anchor="middle" class="s">aggregate-wait fires</text>
  <text x="205" y="280" text-anchor="middle" class="s">dispatcher follows with `CHANNEL_RECV2`</text>
  <text x="205" y="298" text-anchor="middle" class="s">handler runs under existing `global_lock` discipline</text>

  <rect x="365" y="212" width="250" height="118" class="fast"/>
  <text x="490" y="238" text-anchor="middle" class="g">source 1: uring eventfd</text>
  <text x="490" y="262" text-anchor="middle" class="s">drain eventfd</text>
  <text x="490" y="280" text-anchor="middle" class="s">`nspa_uring_drain()` runs inline on the dispatcher</text>
  <text x="490" y="298" text-anchor="middle" class="s">CQE callback issues `CHANNEL_REPLY` on that same thread</text>

  <rect x="650" y="212" width="250" height="118" class="chan"/>
  <text x="775" y="238" text-anchor="middle" class="t">source 2: shutdown eventfd</text>
  <text x="775" y="262" text-anchor="middle" class="s">destroy path writes `1`</text>
  <text x="775" y="280" text-anchor="middle" class="s">aggregate-wait returns</text>
  <text x="775" y="298" text-anchor="middle" class="s">dispatcher drains and frees its own context</text>

  <path d="M490 154 L205 212" class="line" marker-end="url(#dispArrow)"/>
  <path d="M490 154 L490 212" class="line" marker-end="url(#dispArrow)"/>
  <path d="M490 154 L775 212" class="line" marker-end="url(#dispArrow)"/>

  <rect x="160" y="392" width="660" height="94" class="note"/>
  <text x="490" y="418" text-anchor="middle" class="y">Operational invariants</text>
  <text x="490" y="440" text-anchor="middle" class="s">same RT thread receives the request, drains the completion, and signals the reply</text>
  <text x="490" y="458" text-anchor="middle" class="s">`-ENOTTY` at first aggregate-wait call permanently selects the old `CHANNEL_RECV2` loop for that dispatcher</text>
</svg>
</div>

### 4.3 Dispatcher behavior

The loop is now:

1. build the aggregate source table from `{channel, uring eventfd if active, shutdown eventfd}`
2. call `NTSYNC_IOC_AGGREGATE_WAIT`
3. if the fired source is the channel:
   - call `CHANNEL_RECV2`
   - dispatch the request
   - sync handlers reply immediately
   - async-capable handlers may submit work and return to the wait loop
4. if the fired source is the uring eventfd:
   - drain the eventfd counter
   - call `nspa_uring_drain()`
   - completion callbacks finish deferred work and issue `CHANNEL_REPLY`
5. if the fired source is `shutdown_efd`:
   - exit cleanly and free the dispatcher-owned context

### 4.4 Fallback behavior

Userspace still handles two older-kernel shapes:

- **no patch 1010**: aggregate-wait returns `-ENOTTY`, dispatcher permanently falls back to direct `CHANNEL_RECV2`
- **no patch 1005**: `CHANNEL_RECV2` returns `-ENOTTY`, dispatcher falls back to legacy `CHANNEL_RECV`

That gives a clean compatibility ladder:

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 330" xmlns="http://www.w3.org/2000/svg">
  <style>
    .bg { fill: #1a1b26; }
    .done { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .curr { fill: #1f2535; stroke: #bb9af7; stroke-width: 2; rx: 8; }
    .note { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .v { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
    .line { stroke: #c0caf5; stroke-width: 1.4; fill: none; }
  </style>
  <defs>
    <marker id="rollArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="980" height="330" class="bg"/>
  <text x="490" y="26" text-anchor="middle" class="h">Landing sequence</text>

  <rect x="40" y="104" width="180" height="86" class="done"/>
  <text x="130" y="130" text-anchor="middle" class="g">1004-1009 base</text>
  <text x="130" y="152" text-anchor="middle" class="s">channel + thread-token + hardening</text>
  <text x="130" y="170" text-anchor="middle" class="s">legacy direct `CHANNEL_RECV2` loop</text>

  <rect x="280" y="104" width="180" height="86" class="done"/>
  <text x="370" y="130" text-anchor="middle" class="g">1010 kernel</text>
  <text x="370" y="152" text-anchor="middle" class="s">aggregate-wait + channel notify-only</text>
  <text x="370" y="170" text-anchor="middle" class="s">plus 072bfee PI follow-ups</text>

  <rect x="520" y="104" width="180" height="86" class="done"/>
  <text x="610" y="130" text-anchor="middle" class="g">Phase 2</text>
  <text x="610" y="152" text-anchor="middle" class="s">per-process ring + eventfd</text>
  <text x="610" y="170" text-anchor="middle" class="s">dispatcher-owned uring lifetime</text>

  <rect x="760" y="92" width="180" height="110" class="curr"/>
  <text x="850" y="120" text-anchor="middle" class="v">Phase 3</text>
  <text x="850" y="144" text-anchor="middle" class="t">aggregate-wait dispatcher</text>
  <text x="850" y="162" text-anchor="middle" class="s">same-thread CQE drain</text>
  <text x="850" y="180" text-anchor="middle" class="s">default-on: `NSPA_AGG_WAIT`</text>

  <path d="M220 147 L280 147" class="line" marker-end="url(#rollArrow)"/>
  <path d="M460 147 L520 147" class="line" marker-end="url(#rollArrow)"/>
  <path d="M700 147 L760 147" class="line" marker-end="url(#rollArrow)"/>
</svg>
</div>

---

## 5. Validation and deployment

### Production state

| Item | Value |
|---|---|
| Kernel module srcversion | `CFF56DE1EF28D693BB597CD` |
| Wine userspace state | Phase 2 + Phase 3 landed |
| Default gate | `NSPA_AGG_WAIT=1` |
| Opt-out | `NSPA_AGG_WAIT=0` |
| WIP exclusion | `NSPA_ENABLE_ASYNC_CREATE_FILE` remains default-off and is not covered here |

### Validation results

| Test | Result |
|---|---|
| `test-aggregate-wait` | 9/9 PASS |
| channel-PI propagation sub-test | PASS |
| 1k mixed-concurrency stress | PASS |
| 30k stress + full native ntsync suite | PASS, dmesg clean |
| Ableton level 2/3 with `NSPA_AGG_WAIT=1` | PASS |
| Phase 3 default-on under Ableton | PASS |

The follow-up kernel fixes in `072bfee` matter here. The first 1010 cut exposed exactly
the kind of PI edge that the dispatcher cannot tolerate: an aggregate-waiting dispatcher
must still be visible to SEND_PI wake/boost logic and must not be woken before the new
boost state is established. The production module includes those corrections.

---

## 6. Relationship to the broader decomposition plan

The public decomposition plan still has queued work in front of it, but the aggregate-wait
story is no longer purely hypothetical.

**Already shipped:**

- kernel aggregate-wait primitive
- gamma dispatcher consumer
- per-process dispatcher-owned ring infrastructure

**Still queued:**

- timer-thread split
- fd-poll thread split
- wider handler-tier decomposition
- lock partitioning

So the right interpretation is:

- the **primitive and first consumer** are landed
- the **broader multi-thread decomposition** that also wants this primitive is still ahead

That is a better architectural state than the earlier plan assumed. Future work no longer
needs to prove the syscall shape from scratch; it can build on a production consumer.

---

## 7. References

- `wine/server/nspa/shmem_channel.c` — dispatcher context, aggregate-wait loop, shutdown path
- `wine/server/nspa/uring.h` — per-process `nspa_uring_instance` public surface
- `ntsync-patches/1010-ntsync-aggregate-wait.patch` — aggregate-wait kernel patch
- Superproject commits:
  - `1879e2c` — ntsync 1010 first cut
  - `072bfee` — SEND_PI any_waiters fallback + wake-after-boost reorder
  - `8cc157c` — userspace Phase 2 per-process uring infrastructure
  - `f21c6e1` — userspace Phase 3 aggregate-wait dispatcher
  - `b36e36d` — Phase 3 default-on
- In-tree handoff:
  - `wine/nspa/docs/session-handoff-20260429-phase-4.md`
