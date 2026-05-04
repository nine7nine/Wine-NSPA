# Wine-NSPA -- Aggregate-Wait and Async Completion

This page documents the **landed** aggregate-wait slice in Wine-NSPA:
the `NTSYNC_IOC_AGGREGATE_WAIT` kernel primitive plus the first
userspace consumer shape that uses it: the gamma dispatcher's
per-process `io_uring` ownership model and its same-thread
aggregate-wait receive / CQE-drain / reply loop.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Why the old bridge was wrong](#2-why-the-old-bridge-was-wrong)
3. [Aggregate-wait kernel primitive](#3-aggregate-wait-kernel-primitive)
4. [Dispatcher-owned `io_uring` and same-thread completion](#4-dispatcher-owned-iouring-and-same-thread-completion)
5. [Validation and deployment](#5-validation-and-deployment)
6. [Relationship to the broader decomposition plan](#6-relationship-to-the-broader-decomposition-plan)
7. [References](#7-references)

---

## 1. Overview

Aggregate-wait is the kernel-side wait primitive that lets the gamma
dispatcher block on request traffic, deferred-completion wakeups, and
teardown wakeups in one place while keeping receive, CQE drain, and
reply signaling on the same RT thread.

That is the architectural role of aggregate-wait plus the dispatcher's
ring-ownership and same-thread completion work. Gamma already gave Wine-NSPA the correct
**request-side** priority inheritance story: client threads do
`CHANNEL_SEND_PI`, the kernel enqueues by priority, and the wineserver
dispatcher runs the handler at the right effective priority. What gamma
lacked was the matching **async completion-side** wait primitive.

The first async-completion prototype used the wineserver main thread as the CQE drain
site. That proved the basic mechanism but broke the more important invariant: the thread
that received the request was no longer the thread that completed and replied to it.

The aggregate-wait kernel extension and the accompanying dispatcher restructure fix that.
The dispatcher now owns all three parts of the async path:

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

---

## 2. Why the old bridge was wrong

The rejected shape was:

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .bg { fill: #1a1b26; }
    .lane { stroke: #6b7398; stroke-width: 1.2; stroke-dasharray: 6,4; }
    .box { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .bad { fill: #2a1a1a; stroke: #f7768e; stroke-width: 2; rx: 8; }
    .note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .r { fill: #f7768e; font: bold 10px 'JetBrains Mono', monospace; }
    .y { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .line-l { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
    .line-r { stroke: #f7768e; stroke-width: 1.4; fill: none; }
    .line-y { stroke: #e0af68; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="980" height="430" class="bg"/>
  <text x="490" y="26" text-anchor="middle" class="h">Rejected cross-thread bridge</text>

  <text x="250" y="62" text-anchor="middle" class="t">Dispatcher pthread</text>
  <text x="730" y="62" text-anchor="middle" class="r">Wineserver main thread</text>
  <line x1="250" y1="76" x2="250" y2="310" class="lane"/>
  <line x1="730" y1="76" x2="730" y2="310" class="lane"/>

  <rect x="120" y="96" width="260" height="58" class="box"/>
  <text x="250" y="120" text-anchor="middle" class="t">`CHANNEL_RECV2`</text>
  <text x="250" y="140" text-anchor="middle" class="s">dispatcher owns request entry</text>

  <line x1="250" y1="154" x2="250" y2="182" class="line-l"/>

  <rect x="120" y="182" width="260" height="78" class="box"/>
  <text x="250" y="206" text-anchor="middle" class="t">handler submits SQE</text>
  <text x="250" y="226" text-anchor="middle" class="s">deferred path returns to channel receive loop</text>
  <text x="250" y="244" text-anchor="middle" class="s">request is no longer owned by the dispatcher</text>

  <rect x="600" y="96" width="260" height="58" class="bad"/>
  <text x="730" y="120" text-anchor="middle" class="t">`main_loop_epoll`</text>
  <text x="730" y="140" text-anchor="middle" class="s">main thread owns uring wake</text>

  <line x1="730" y1="154" x2="730" y2="182" class="line-r"/>

  <rect x="600" y="182" width="260" height="92" class="bad"/>
  <text x="730" y="206" text-anchor="middle" class="t">CQE arrives later</text>
  <text x="730" y="226" text-anchor="middle" class="s">main thread drains CQE</text>
  <text x="730" y="244" text-anchor="middle" class="s">callback restores state and writes reply</text>
  <text x="730" y="262" text-anchor="middle" class="s">`CHANNEL_REPLY` issued cross-thread</text>

  <text x="490" y="172" text-anchor="middle" class="y">ownership jump after SQE submit</text>
  <line x1="380" y1="221" x2="600" y2="221" class="line-y"/>
  <text x="490" y="238" text-anchor="middle" class="s">completion timing now depends on the main-thread wake path</text>

  <line x1="730" y1="274" x2="730" y2="322" class="line-r"/>
  <rect x="170" y="322" width="640" height="72" class="note"/>
  <text x="490" y="346" text-anchor="middle" class="y">Why it was rejected</text>
  <text x="490" y="364" text-anchor="middle" class="s">request receive, CQE drain, and reply signaling no longer live on one RT thread</text>
  <text x="490" y="382" text-anchor="middle" class="s">reply timing depends on main-thread wake timing and main-thread contention</text>
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

## 3. Aggregate-wait kernel primitive

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
    .line-o { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .line-f { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
  </style>

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

  <line x1="290" y1="147" x2="370" y2="147" class="line-o"/>
  <line x1="610" y1="147" x2="690" y2="147" class="line-f"/>

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

## 4. Dispatcher-owned `io_uring` and same-thread completion

### 4.1 Dispatcher-owned `io_uring`

This step did not make handlers async by itself. It put the ring and its state in the
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

### 4.2 Aggregate-wait dispatcher loop

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
    .line-b { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
    .line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="980" height="560" class="bg"/>
  <text x="490" y="28" text-anchor="middle" class="h">Dispatcher aggregate-wait topology</text>

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

  <path d="M490 154 L490 180 L205 180 L205 212" class="line-b"/>
  <line x1="490" y1="154" x2="490" y2="212" class="line-g"/>
  <path d="M490 154 L490 180 L775 180 L775 212" class="line-b"/>

  <rect x="160" y="392" width="660" height="94" class="note"/>
  <text x="490" y="418" text-anchor="middle" class="y">Operational invariants</text>
  <text x="490" y="440" text-anchor="middle" class="s">same RT thread receives the request, drains completion, and signals the reply</text>
  <text x="490" y="458" text-anchor="middle" class="s">aggregate-wait `-ENOTTY` selects the legacy direct `CHANNEL_RECV2` loop</text>
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

- **no aggregate-wait support**: aggregate-wait returns `-ENOTTY`, dispatcher permanently falls back to direct `CHANNEL_RECV2`
- **no thread-token receive support**: `CHANNEL_RECV2` returns `-ENOTTY`, dispatcher falls back to legacy `CHANNEL_RECV`

That logic is runtime feature detection, not a release ladder:

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .bg { fill: #1a1b26; }
    .done { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .curr { fill: #1f2535; stroke: #bb9af7; stroke-width: 2; rx: 8; }
    .note { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .warn { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .v { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
    .y { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .line-v { stroke: #bb9af7; stroke-width: 1.4; fill: none; }
    .line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .line-y { stroke: #e0af68; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="980" height="430" class="bg"/>
  <text x="490" y="26" text-anchor="middle" class="h">Dispatcher compatibility decisions</text>

  <rect x="330" y="62" width="320" height="70" class="curr"/>
  <text x="490" y="88" text-anchor="middle" class="v">dispatcher startup / first wait</text>
  <text x="490" y="108" text-anchor="middle" class="s">probe once, then cache the supported receive shape in the dispatcher context</text>

  <rect x="70" y="178" width="260" height="92" class="done"/>
  <text x="200" y="204" text-anchor="middle" class="g">1. try `NTSYNC_IOC_AGGREGATE_WAIT`</text>
  <text x="200" y="224" text-anchor="middle" class="s">channel object + uring eventfd + shutdown eventfd</text>
  <text x="200" y="242" text-anchor="middle" class="s">production path on post-1010 kernels</text>

  <rect x="390" y="178" width="200" height="92" class="note"/>
  <text x="490" y="204" text-anchor="middle" class="t">if `-ENOTTY`</text>
  <text x="490" y="224" text-anchor="middle" class="s">kernel lacks aggregate-wait support</text>
  <text x="490" y="242" text-anchor="middle" class="s">disable aggregate-wait for this dispatcher</text>

  <rect x="650" y="178" width="260" height="92" class="done"/>
  <text x="780" y="204" text-anchor="middle" class="g">2. use direct `CHANNEL_RECV2` loop</text>
  <text x="780" y="224" text-anchor="middle" class="s">channel transport still intact</text>
  <text x="780" y="242" text-anchor="middle" class="s">older dispatcher wait shape</text>

  <rect x="390" y="300" width="200" height="92" class="note"/>
  <text x="490" y="326" text-anchor="middle" class="t">if `CHANNEL_RECV2` returns `-ENOTTY`</text>
  <text x="490" y="346" text-anchor="middle" class="s">kernel lacks thread-token receive support</text>
  <text x="490" y="364" text-anchor="middle" class="s">disable `RECV2` for this dispatcher</text>

  <rect x="650" y="300" width="260" height="92" class="warn"/>
  <text x="780" y="326" text-anchor="middle" class="y">3. fall back to `CHANNEL_RECV`</text>
  <text x="780" y="346" text-anchor="middle" class="s">oldest supported channel shape</text>
  <text x="780" y="364" text-anchor="middle" class="s">no thread-token carried in the receive result</text>

  <path d="M490 132 L490 156 L200 156 L200 178" class="line-v"/>
  <path d="M490 132 L490 156 L780 156 L780 178" class="line-v"/>
  <line x1="330" y1="224" x2="390" y2="224" class="line-y"/>
  <line x1="590" y1="224" x2="650" y2="224" class="line-g"/>
  <line x1="780" y1="270" x2="780" y2="300" class="line-g"/>
  <line x1="590" y1="346" x2="650" y2="346" class="line-y"/>

  <rect x="70" y="300" width="260" height="92" class="curr"/>
  <text x="200" y="326" text-anchor="middle" class="v">steady-state production loop</text>
  <text x="200" y="346" text-anchor="middle" class="s">aggregate-wait blocks once on channel, uring, and shutdown</text>
  <text x="200" y="364" text-anchor="middle" class="s">same thread receives, drains CQEs, and replies</text>
</svg>
</div>

---

## 5. Validation and deployment

### Production state

| Item | Value |
|---|---|
| Kernel module srcversion | `10124FB81FDC76797EF1F91` |
| Wine userspace state | Dispatcher-owned ring and aggregate-wait loop are landed; async `CreateFile` now uses the same ring |
| Default gate | `NSPA_AGG_WAIT=1` |
| Opt-out | `NSPA_AGG_WAIT=0` |
| Follow-on gates on top of this base | `NSPA_ENABLE_ASYNC_CREATE_FILE=1`; `NSPA_TRY_RECV2=1` on 1011 kernels |

### Validation results

| Test | Result |
|---|---|
| `test-aggregate-wait` | 9/9 PASS |
| channel-PI propagation sub-test | PASS |
| 1k mixed-concurrency stress | PASS |
| 30k stress + full native ntsync suite | PASS, dmesg clean |
| PE matrix | 24 PASS / 0 FAIL / 0 TIMEOUT, including `dispatcher-burst` |
| Ableton level 2/3 with `NSPA_AGG_WAIT=1` | PASS |
| Aggregate-wait default-on under Ableton | PASS |

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
  - `8cc157c` — userspace per-process uring infrastructure
  - `f21c6e1` — userspace aggregate-wait dispatcher
  - `b36e36d` — aggregate-wait default-on
- In-tree handoff:
  - `wine/nspa/docs/session-handoff-20260429-phase-4.md`
