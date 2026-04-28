# Wine-NSPA — Message Ring Architecture

**Date:** 2026-04-28
**Author:** Jordan Johnston
**Wine submodule HEAD:** `ac823311aba` (Wine 11.6 + NSPA fork)
**Kernel:** `6.19.11-rt1-1-nspa` with NTSync PI (`A250A77651C8D5DAB719FE2`)
**Subsystem source:** `wine/dlls/win32u/nspa/msg_ring.c` (1633 LOC),
`wine/server/protocol.def` (slot definitions, lines 1020-1214),
`wine/server/nspa/redraw_ring.c` (87 LOC server drain),
`wine/dlls/win32u/dce.c` (paint cache fastpath).

---

## Table of contents

 1. [Abstract](#1-abstract)
 2. [Architecture overview](#2-architecture-overview)
 3. [Ring layout in shared memory](#3-ring-layout-in-shared-memory)
 4. [Memfd lifecycle](#4-memfd-lifecycle)
 5. [POST class — `nspa_try_post_ring`](#5-post-class)
 6. [SEND class — `nspa_try_send_ring`](#6-send-class)
 7. [REPLY class — `nspa_write_ring_reply`](#7-reply-class)
 8. [Reply-slot generation discriminator (MR1)](#8-reply-slot-generation-discriminator-mr1)
 9. [Cross-process futex (MR2)](#9-cross-process-futex-mr2)
10. [Wake-loss rollback (MR4)](#10-wake-loss-rollback-mr4)
11. [Phase A — `redraw_window` push ring](#11-phase-a-redraw_window-push-ring)
12. [Phase B1.0 — paint cache fastpath](#12-phase-b10-paint-cache-fastpath)
13. [Phase C — `get_message` bypass (paused)](#13-phase-c-get_message-bypass-paused)
14. [`NSPA_SHM_RETRY_GUARD` — bounded retry primitive](#14-nspa_shm_retry_guard)
15. [Footnote — why memfd, not session shmem](#15-footnote-why-memfd)
16. [Phase history](#16-phase-history)
17. [References](#17-references)

---

## 1. Abstract

Wine's windowing model routes every `PostMessage` / `SendMessage` call
through the wineserver: the sender writes a request, the server allocates
a `struct message`, inserts it into the receiver's queue, the receiver
polls via `GetMessage` / `PeekMessage` (another wineserver round-trip),
and for synchronous sends a `reply_message` round-trip closes the loop.
On a typical RT audio workload this costs hundreds to thousands of
wineserver RTTs per second — the NSPA profiler captured **6,239
`send_message` RTTs / 60 s** from Ableton Live's `AudioCalc` thread alone
during a single adversarial recording session.

Wine-NSPA's **message ring** replaces that round-trip chain for
same-process cross-thread window messages with a direct shared-memory
ring:

1. Sender writes the message into the receiver thread's ring and wakes
   the receiver via an NTSync event.
2. Receiver's message pump reads the message out of the ring locally
   (no `get_message` server request).
3. For synchronous SENDs the receiver writes the reply back into the
   sender's reply ring and signals.

The feature is invisible to Win32 applications — the same `PostMessage`
/ `SendMessage` API, the same delivery semantics, the same window
procedure dispatch. It is same-process-only by design (cross-process
messaging continues through the server because ring addresses like
`HWND` / `WPARAM` / `LPARAM` only make sense in the sender's address
space and handle table).

This document is the canonical reference for the entire ring family.
The original POST / SEND / REPLY ring landed first (2026-04, see
[§16 Phase history](#16-phase-history)). Subsequent additions —
Phase A `redraw_window` push, Phase B1.0 paint cache, Phase C
`get_message` bypass, and the MR1 / MR2 / MR4 audit fix-pack from
2026-04-27 — extend or harden the same substrate. They share the
per-queue memfd, the slot state machine, the cache discipline, and the
fast-path atomics. The doc treats them as one evolving design rather
than versioned sub-systems.

### 1.1 Motivating profile

| Source | RTTs / 60 s (bypass off) |
| --- | --- |
| `AudioCalc` threads (`send_message`) | **6,239** |
| `DWM-Sync` (posts + sync sends) | several thousand |
| Total busy Ableton playback traffic | ~500 – 1000 / sec |

The bypass targets the AudioCalc + DWM-Sync → MainThread hot path that
dominates this profile.

### 1.2 Relationship to existing NSPA infrastructure

| Component | Interaction |
| --- | --- |
| Shmem IPC (v1.5) | **Orthogonal.** Shmem IPC handles the request/reply protocol for ntdll ↔ wineserver. The ring is a peer-to-peer window-message path that sidesteps the server entirely. |
| NTSync (`/dev/ntsync`) | **Direct wake.** Sender calls `wine_server_signal_internal_sync()` on the receiver's queue sync event — an `ntsync` ioctl, no wineserver round-trip. Receiver wakes via `ntsync_schedule`. |
| PI `global_lock` | **Load relief.** Every ring message is one fewer `send_message` request the server handles under `global_lock`. Reduces contention for shmem dispatchers. |
| CS-PI (`FUTEX_LOCK_PI`) | **No conflict.** Ring operates in client code only; no server locks are acquired on the fast path. |
| RT scheduling (SCHED_FIFO/RR) | **RT-safe fast path.** After warm-up, a ring POST/SEND is atomic CAS plus memory reads/writes on `mlock()`-pinned memory. No syscalls, no page faults. |
| io_uring I/O bypass | **Compatible, independent.** Different bottleneck, different ring. |
| Phase A redraw push ring | Shares the per-queue memfd. The ring is co-located in `nspa_queue_bypass_shm_t` so the existing fd-passing protocol carries it for free. |
| Phase B1.0 paint cache | Reads `queue_shm`, not the message ring; co-resident in the same fastpath taxonomy. |

---

## 2. Architecture overview

### 2.1 Vanilla Wine vs Wine-NSPA

<div class="diagram-container">
<svg width="100%" viewBox="0 0 920 580" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box-vanilla { fill: #24283b; stroke: #8c92b3; stroke-width: 1.5; rx: 6; }
    .box-nspa { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 6; }
    .box-new { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 6; }
    .box-server { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.5; rx: 6; }
    .label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .label-sm { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .label-accent { fill: #7aa2f7; font-size: 13px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-muted { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .divider { stroke: #3b4261; stroke-width: 1; stroke-dasharray: 8,4; }
  </style>

  <text x="220" y="24" class="label-accent" text-anchor="middle">Vanilla Wine (server-mediated)</text>
  <text x="700" y="24" class="label-accent" text-anchor="middle">Wine-NSPA msg-ring (memfd)</text>
  <line x1="460" y1="8" x2="460" y2="570" class="divider"/>

  <rect x="40" y="45" width="340" height="28" class="box-vanilla"/>
  <text x="210" y="64" text-anchor="middle" class="label">PostMessage / SendMessage (ntuser)</text>
  <line x1="210" y1="73" x2="210" y2="93" stroke="#f7768e" stroke-width="1.5"/>

  <rect x="60" y="95" width="300" height="28" class="box-server"/>
  <text x="210" y="114" text-anchor="middle" class="label-red">SERVER: send_message request</text>
  <line x1="210" y1="123" x2="210" y2="143" stroke="#f7768e" stroke-width="1.5"/>

  <rect x="60" y="145" width="300" height="45" class="box-server"/>
  <text x="210" y="163" text-anchor="middle" class="label-red">alloc struct message + insert queue</text>
  <text x="210" y="180" text-anchor="middle" class="label-muted">global_lock held during insertion</text>
  <line x1="210" y1="190" x2="210" y2="210" stroke="#f7768e" stroke-width="1.5"/>

  <rect x="60" y="212" width="300" height="28" class="box-server"/>
  <text x="210" y="231" text-anchor="middle" class="label-red">set_queue_bits + sync wake</text>
  <line x1="210" y1="240" x2="210" y2="260" stroke="#8c92b3" stroke-width="1"/>

  <rect x="40" y="262" width="340" height="28" class="box-vanilla"/>
  <text x="210" y="281" text-anchor="middle" class="label">receiver wakes (NtWaitForMultipleObjects)</text>
  <line x1="210" y1="290" x2="210" y2="310" stroke="#f7768e" stroke-width="1.5"/>

  <rect x="60" y="312" width="300" height="28" class="box-server"/>
  <text x="210" y="331" text-anchor="middle" class="label-red">SERVER: get_message request</text>
  <line x1="210" y1="340" x2="210" y2="360" stroke="#f7768e" stroke-width="1.5"/>

  <rect x="60" y="362" width="300" height="28" class="box-server"/>
  <text x="210" y="381" text-anchor="middle" class="label-red">remove from queue, copy to reply</text>
  <line x1="210" y1="390" x2="210" y2="410" stroke="#8c92b3" stroke-width="1"/>

  <rect x="40" y="412" width="340" height="28" class="box-vanilla"/>
  <text x="210" y="431" text-anchor="middle" class="label">dispatch window proc</text>
  <line x1="210" y1="440" x2="210" y2="460" stroke="#f7768e" stroke-width="1.5"/>

  <rect x="60" y="462" width="300" height="28" class="box-server"/>
  <text x="210" y="481" text-anchor="middle" class="label-red">(SEND only) reply_message RTT</text>

  <rect x="50" y="500" width="320" height="60" rx="5" fill="#24283b" stroke="#3b4261"/>
  <text x="210" y="518" text-anchor="middle" class="label-red">Cost per send:</text>
  <text x="70" y="534" class="label-sm">2 wineserver RTTs (POST), 3 (SEND)</text>
  <text x="70" y="548" class="label-sm">global_lock held during every insertion</text>

  <rect x="520" y="45" width="360" height="28" class="box-nspa"/>
  <text x="700" y="64" text-anchor="middle" class="label">PostMessage / SendMessage (ntuser)</text>
  <line x1="700" y1="73" x2="700" y2="93" stroke="#9ece6a" stroke-width="1.5"/>

  <rect x="530" y="95" width="340" height="28" class="box-new"/>
  <text x="700" y="114" text-anchor="middle" class="label-green">nspa_try_post_ring() / nspa_try_send_ring()</text>
  <line x1="700" y1="123" x2="700" y2="143" stroke="#9ece6a" stroke-width="1.5"/>

  <rect x="530" y="145" width="340" height="60" class="box-new"/>
  <text x="700" y="163" text-anchor="middle" class="label-green">ring_reserve_slot (CAS head++)</text>
  <text x="700" y="179" text-anchor="middle" class="label-green">write fields to slot, state -&gt; READY</text>
  <text x="700" y="195" text-anchor="middle" class="label-green">(SEND) reserve reply slot in own ring</text>
  <line x1="700" y1="205" x2="700" y2="225" stroke="#9ece6a" stroke-width="1.5"/>

  <rect x="530" y="227" width="340" height="40" class="box-new"/>
  <text x="700" y="244" text-anchor="middle" class="label-green">wine_server_signal_internal_sync()</text>
  <text x="700" y="259" text-anchor="middle" class="label-sm">ntsync ioctl -&gt; rt_mutex wake (no RTT)</text>
  <line x1="700" y1="267" x2="700" y2="287" stroke="#9ece6a" stroke-width="1.5"/>

  <rect x="520" y="289" width="360" height="28" class="box-nspa"/>
  <text x="700" y="308" text-anchor="middle" class="label">receiver wakes (ntsync_schedule)</text>
  <line x1="700" y1="317" x2="700" y2="337" stroke="#9ece6a" stroke-width="1.5"/>

  <rect x="530" y="339" width="340" height="40" class="box-new"/>
  <text x="700" y="356" text-anchor="middle" class="label-green">nspa_try_pop_own_ring_send/post()</text>
  <text x="700" y="370" text-anchor="middle" class="label-sm">CAS READY -&gt; CONSUMED, fill info</text>
  <line x1="700" y1="379" x2="700" y2="399" stroke="#9ece6a" stroke-width="1.5"/>

  <rect x="520" y="401" width="360" height="28" class="box-nspa"/>
  <text x="700" y="420" text-anchor="middle" class="label">dispatch window proc</text>
  <line x1="700" y1="429" x2="700" y2="449" stroke="#9ece6a" stroke-width="1.5"/>

  <rect x="530" y="451" width="340" height="40" class="box-new"/>
  <text x="700" y="468" text-anchor="middle" class="label-green">(SEND) nspa_write_ring_reply()</text>
  <text x="700" y="483" text-anchor="middle" class="label-sm">write to sender's reply slot + futex_wake</text>

  <rect x="530" y="500" width="340" height="60" rx="5" fill="#24283b" stroke="#3b4261"/>
  <text x="700" y="518" text-anchor="middle" class="label-green">Cost per send (warm ring):</text>
  <text x="550" y="534" class="label-sm">0 wineserver RTTs for POST or SEND</text>
  <text x="550" y="548" class="label-sm">1 ntsync wake ioctl + 1 futex wake (kernel fast path)</text>
</svg>
</div>

The reduction is not just in RTT count — vanilla Wine's `send_message`
handler acquires `global_lock` to insert the new message into the
receiver's queue. Under heavy traffic this contended mutex becomes a
serialization point. The memfd ring sidesteps `global_lock` entirely:
slot reservation is a lock-free CAS in shared memory.

### 2.2 Design principles

- **Memfd-backed per-queue rings.** Each thread queue owns a private
  `memfd_create()` region containing its bypass ring. Server allocates
  on demand; client receives via `SCM_RIGHTS` and `mmap`s locally.
  Rings never live in Wine's session shmem (see [§15](#15-footnote-why-memfd)
  for why that matters).
- **Same-process only.** Cross-process messages cannot use ring
  pointers (HWND translation, WPARAM/LPARAM pointer dereferences).
  The server rejects cross-process `nspa_get_thread_queue` requests
  early. (MR2 from the 2026-04-27 audit broadens the underlying
  primitives to be cross-process-correct, but the same-process
  invariant on user-supplied addresses is unchanged.)
- **Transparent fallback.** Every ring operation returns `FALSE` /
  `NULL` on any corner case (ring disabled, no own ring, lookup
  failure, cross-process destination, DDE message, thread-message with
  `hwnd == 0`). Callers fall back to the legacy wineserver path. Wine
  apps see identical behaviour whether the ring is enabled or not.
- **RT-safe fast path.** Ring slots use `__atomic_*` operations only.
  Shared memory is `MAP_POPULATE`-prefaulted and `mlock`-pinned so no
  demand paging happens on hot access. Warm-up cost (memfd create +
  map + lock) is paid once per peer, off the RT-critical path.
- **Bounded retry loops.** Every seqlock-style read in this subsystem
  uses `NSPA_SHM_RETRY_GUARD` (see [§14](#14-nspa_shm_retry_guard))
  to bound spin to 256 PAUSEs and fall back to RPC on exhaustion.
- **Layered opt-in / opt-out gates.** Each capability is an
  independent `NSPA_*` environment variable. Production-default
  posture (default-on or default-off) is fixed per-feature and
  documented inline.
- **Minimal protocol surface.** Two server requests:
  `nspa_get_thread_queue` (peer lookup + memfd send) and
  `nspa_ensure_own_bypass` (own bootstrap). Server handlers reuse a
  single `nspa_alloc_bypass_shm()` helper for both.

---

## 3. Ring layout in shared memory

Each `msg_queue` owns a `nspa_queue_bypass_shm_t` region. The struct
lives in `wine/server/protocol.def` (lines 1205-1214) and aggregates
several class-isolated rings under one memfd:

    typedef volatile struct {
        nspa_msg_ring_t      nspa_msg_ring;     /* incoming msgs (senders -> me) */
        nspa_reply_ring_t    nspa_reply_ring;   /* replies to my SendMessage */
        nspa_timer_ring_t    nspa_timer_ring;   /* WM_TIMER expiries */
        int                  nspa_hook_walk_counts[NB_HOOKS];   /* Tier 1 hook */
        nspa_hook_chain_t    nspa_hook_chains[NB_HOOKS];        /* Tier 2 hook */
        unsigned char        nspa_hook_module_pool[...];        /* Tier 2 strings */
        nspa_redraw_ring_t   nspa_redraw_ring;  /* Phase A: redraw_window push */
    } nspa_queue_bypass_shm_t;

Class isolation: each ring has its own producer / consumer roles
appropriate to the message class it carries. The original message ring
is MPSC (many producers post / send to the queue owner). The redraw
push ring is SPSC (queue owner pushes to itself, server drains). The
timer ring is SPSC (per-process timer dispatcher to queue owner). Each
class avoids contending on another class's head CAS, even though they
co-locate in the same memfd for protocol-passing economy.

### 3.1 `nspa_msg_ring_t` — forward ring

Sized at 64 slots × 128 bytes ≈ 8 KB. Header fields (`protocol.def`
lines 1069-1082):

    typedef volatile struct {
        unsigned int head;              /* MPSC producer index */
        unsigned int tail;              /* SPSC consumer index */
        unsigned int overflow;          /* fall-back-to-server count */
        unsigned int active;            /* 0 = ring disabled */
        unsigned int pending_count;     /* total READY slots */
        unsigned int pending_send_count;/* SEND-class subset */
        unsigned int next_post_seq;     /* canonical post ordering */
        unsigned int change_seq;        /* bumped on each publish */
        unsigned int change_ack_seq;    /* owner-side ack */
        unsigned int __pad;
        nspa_msg_slot_t slots[NSPA_MSG_RING_SLOTS];
    } nspa_msg_ring_t;

Each slot (`nspa_msg_slot_t`, 128 B, lines 1046-1067) carries the
forwarded message plus routing metadata:

    typedef volatile struct {
        unsigned int  state;        /* state enum */
        unsigned int  type;         /* enum message_type */
        user_handle_t win;          /* target hwnd */
        unsigned int  msg;
        unsigned int  post_seq;     /* canonical posted ordering */
        lparam_t      wparam;
        lparam_t      lparam;
        int           x, y;         /* cursor at send time */
        unsigned int  time;
        unsigned int  sender_tid;   /* for reply routing */
        unsigned int  sender_pid;
        unsigned int  reply_slot;   /* index into sender's reply ring, ~0u = no-reply */
        unsigned int  data_size;
        unsigned int  reply_gen;    /* MR1 ABA guard — see §8 */
        unsigned char data[NSPA_MSG_INLINE_MAX];
    } nspa_msg_slot_t;

The `reply_gen` field is the MR1 ABA guard added 2026-04-27. It
repurposes the previously-reserved `__pad` slot. Sender stamps it
post-reserve with the value returned from atomic-fetch-add on the reply
slot's generation; receiver passes it through to
`nspa_write_ring_reply`, which writes only on generation match.
Mechanism detailed in [§8](#8-reply-slot-generation-discriminator-mr1).

### 3.2 Forward slot state machine

| From | To | Actor | Semantic |
| --- | --- | --- | --- |
| `EMPTY` | `WRITING` | sender | `ring_reserve_slot` CAS on `head` allocates; transition before payload fill |
| `WRITING` | `READY` | sender | release store after all slot fields written |
| `READY` | `CONSUMED` | receiver | CAS-claim in client pump or server arbitration — whichever wins |
| `CONSUMED` | `EMPTY` | receiver | batched run at tail advance after consumption |

State values (`protocol.def` lines 1036-1039):

    #define NSPA_MSG_STATE_EMPTY     0
    #define NSPA_MSG_STATE_WRITING   1
    #define NSPA_MSG_STATE_READY     2
    #define NSPA_MSG_STATE_CONSUMED  3

The sender's release store on `state = READY` orders all preceding slot
writes before the receiver's acquire load on `state == READY`. Pure
`__atomic_*` operations; no memory barrier syscalls.

### 3.3 `nspa_reply_ring_t` — reply ring

Sized at 16 slots × 96 bytes ≈ 1.5 KB. The reply ring is per-queue
(every queue's bypass shm owns one), and it is **the sender's own
queue** that holds the reply slot for a SEND — not the receiver's
queue. The flow:

1. Sender reserves a free slot in its OWN reply ring (CAS `FREE` →
   `PENDING`).
2. Sender stamps the slot's `generation` (atomic-fetch-add) and
   captures the post-bump value.
3. Sender publishes the message into the receiver's forward ring with
   `slot.reply_slot = reply_idx` and `slot.reply_gen = generation`.
4. Receiver dispatches the window proc, gets `LRESULT`.
5. Receiver looks up the sender via the peer cache, finds the sender's
   own bypass shm, indexes into the reply ring at `reply_slot`.
6. Receiver checks slot state is `PENDING` AND slot generation matches
   `reply_gen` from the message slot; on mismatch, drops the reply
   silently.
7. On match, receiver writes `result`, `data`, sets `state = READY`,
   `futex_wake` on `&slot->state`.
8. Sender's `futex_wait` returns, reads `result`, sets `state = FREE`.

Slot fields (`protocol.def` lines 1084-1092):

    typedef volatile struct {
        unsigned int state;       /* NSPA_REPLY_STATE_* */
        unsigned int error;
        lparam_t     result;      /* LRESULT */
        unsigned int data_size;
        unsigned int generation;  /* ABA guard — bumped on each reserve */
        unsigned char data[NSPA_REPLY_INLINE_MAX];
    } nspa_reply_slot_t;

States:

    #define NSPA_REPLY_STATE_FREE     0   /* sender may allocate */
    #define NSPA_REPLY_STATE_PENDING  1   /* awaiting receiver */
    #define NSPA_REPLY_STATE_READY    2   /* receiver wrote; sender may read */

The wrapping ring header has a `next_alloc` hint for the next free
slot:

    typedef volatile struct {
        unsigned int next_alloc;
        unsigned int __pad[3];
        nspa_reply_slot_t slots[NSPA_REPLY_RING_SLOTS];
    } nspa_reply_ring_t;

### 3.4 Layout diagram

<div class="diagram-container">
<svg width="100%" viewBox="0 0 920 410" xmlns="http://www.w3.org/2000/svg">
  <style>
    .rl-box { fill: #24283b; stroke: #8c92b3; stroke-width: 1.5; rx: 6; }
    .rl-box-nspa { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 6; }
    .rl-slot { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1; rx: 3; }
    .rl-slot-full { fill: #2a2a1a; stroke: #e0af68; stroke-width: 1; rx: 3; }
    .rl-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .rl-label-sm { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .rl-label-accent { fill: #7aa2f7; font-size: 12px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .rl-label-yellow { fill: #e0af68; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .rl-label-cyan { fill: #7dcfff; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .rl-label-muted { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .rl-label-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
  </style>

  <text x="460" y="24" class="rl-label-accent" text-anchor="middle">nspa_queue_bypass_shm_t (memfd, ~10 KB + class rings, mlock'd)</text>

  <rect x="20" y="35" width="880" height="355" rx="10" fill="none" stroke="#3b4261" stroke-width="1" stroke-dasharray="5,3"/>

  <rect x="40" y="55" width="840" height="160" class="rl-box-nspa"/>
  <text x="460" y="74" class="rl-label-accent" text-anchor="middle">nspa_msg_ring_t (forward MPSC, 64 slots)</text>

  <rect x="60" y="85" width="800" height="38" class="rl-box"/>
  <text x="90" y="102" class="rl-label-cyan">head</text>
  <text x="90" y="115" class="rl-label-sm">producer (CAS)</text>
  <text x="180" y="102" class="rl-label-cyan">tail</text>
  <text x="180" y="115" class="rl-label-sm">consumer cursor</text>
  <text x="280" y="102" class="rl-label-cyan">active</text>
  <text x="280" y="115" class="rl-label-sm">0 = disabled</text>
  <text x="370" y="102" class="rl-label-cyan">pending_count</text>
  <text x="370" y="115" class="rl-label-sm">+ pending_send_count</text>
  <text x="540" y="102" class="rl-label-cyan">next_post_seq</text>
  <text x="540" y="115" class="rl-label-sm">canonical ordering</text>
  <text x="690" y="102" class="rl-label-cyan">change_seq / ack</text>
  <text x="690" y="115" class="rl-label-sm">wake-bit edge detect</text>

  <text x="70" y="143" class="rl-label-yellow">slots[0..63]</text>
  <text x="70" y="155" class="rl-label-muted">nspa_msg_slot_t (128 B)</text>

  <rect x="180" y="140" width="90" height="65" class="rl-slot"/>
  <text x="225" y="157" class="rl-label-sm" text-anchor="middle">state</text>
  <text x="225" y="169" class="rl-label-sm" text-anchor="middle">type, msg</text>
  <text x="225" y="181" class="rl-label-sm" text-anchor="middle">win, wparam</text>
  <text x="225" y="193" class="rl-label-sm" text-anchor="middle">lparam</text>

  <rect x="280" y="140" width="90" height="65" class="rl-slot"/>
  <text x="325" y="157" class="rl-label-sm" text-anchor="middle">sender_tid</text>
  <text x="325" y="169" class="rl-label-sm" text-anchor="middle">sender_pid</text>
  <text x="325" y="181" class="rl-label-sm" text-anchor="middle">reply_slot</text>
  <text x="325" y="193" class="rl-label-sm" text-anchor="middle">reply_gen (MR1)</text>

  <rect x="380" y="140" width="90" height="65" class="rl-slot"/>
  <text x="425" y="157" class="rl-label-sm" text-anchor="middle">time, x, y</text>
  <text x="425" y="169" class="rl-label-sm" text-anchor="middle">post_seq</text>
  <text x="425" y="181" class="rl-label-sm" text-anchor="middle">data_size</text>
  <text x="425" y="193" class="rl-label-sm" text-anchor="middle">data[64]</text>

  <text x="490" y="175" class="rl-label" text-anchor="start">...</text>
  <rect x="525" y="140" width="90" height="65" class="rl-slot"/>
  <text x="570" y="175" class="rl-label-sm" text-anchor="middle">[63]</text>

  <text x="470" y="200" class="rl-label-green" text-anchor="middle">EMPTY -&gt; WRITING -&gt; READY -&gt; CONSUMED -&gt; EMPTY</text>

  <rect x="40" y="235" width="840" height="140" class="rl-box-nspa"/>
  <text x="460" y="254" class="rl-label-accent" text-anchor="middle">nspa_reply_ring_t (16 slots, per-queue, holds replies for sender's own SENDs)</text>

  <rect x="60" y="265" width="800" height="30" class="rl-box"/>
  <text x="90" y="284" class="rl-label-cyan">next_alloc</text>
  <text x="220" y="284" class="rl-label-sm">monotonic reservation hint (CAS FREE -&gt; PENDING)</text>

  <text x="70" y="313" class="rl-label-yellow">slots[0..15]</text>
  <text x="70" y="325" class="rl-label-muted">nspa_reply_slot_t</text>

  <rect x="180" y="305" width="100" height="60" class="rl-slot-full"/>
  <text x="230" y="322" class="rl-label-sm" text-anchor="middle">state</text>
  <text x="230" y="335" class="rl-label-sm" text-anchor="middle">result</text>
  <text x="230" y="348" class="rl-label-sm" text-anchor="middle">generation</text>
  <text x="230" y="361" class="rl-label-sm" text-anchor="middle">data[64]</text>

  <rect x="290" y="305" width="100" height="60" class="rl-slot-full"/>
  <text x="340" y="335" class="rl-label-sm" text-anchor="middle">[1]</text>
  <rect x="400" y="305" width="100" height="60" class="rl-slot-full"/>
  <text x="450" y="335" class="rl-label-sm" text-anchor="middle">[2]</text>
  <text x="520" y="335" class="rl-label" text-anchor="start">...</text>
  <rect x="560" y="305" width="100" height="60" class="rl-slot-full"/>
  <text x="610" y="335" class="rl-label-sm" text-anchor="middle">[15]</text>

  <text x="460" y="384" class="rl-label-yellow" text-anchor="middle">FREE -&gt; PENDING (sender) -&gt; READY (receiver) -&gt; FREE (sender reads)</text>
</svg>
</div>

The forward ring's `state` transitions are CAS-claimed (multi-producer
head, single-consumer tail). The reply ring's `generation` field
discriminates against stale writebacks (MR1, [§8](#8-reply-slot-generation-discriminator-mr1));
the receiver writes only on `state == PENDING && generation == reply_gen`.

---

## 4. Memfd lifecycle

Every queue's bypass region is backed by an anonymous `memfd_create()`
file. The fd's lifetime follows the queue: created on first use,
closed on queue destroy. Clients that need to talk to a peer receive
the fd over the wineserver socket via `SCM_RIGHTS` and `mmap` it
locally.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 920 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .mf-box-nspa { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 6; }
    .mf-box-server { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.5; rx: 6; }
    .mf-box-kernel { fill: #1a1a2a; stroke: #bb9af7; stroke-width: 1.5; rx: 6; }
    .mf-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .mf-label-sm { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .mf-label-accent { fill: #7aa2f7; font-size: 12px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .mf-label-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .mf-label-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .mf-label-violet { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
  </style>

  <text x="460" y="24" class="mf-label-accent" text-anchor="middle">memfd allocation + fd passing + client mmap</text>

  <rect x="30" y="360" width="860" height="50" class="mf-box-kernel"/>
  <text x="460" y="378" class="mf-label-violet" text-anchor="middle">Kernel (anon shmem pages, single physical backing)</text>
  <text x="460" y="395" class="mf-label-sm" text-anchor="middle">fd reference-counted; pages unlink when last mapping released AND fd closed</text>

  <rect x="30" y="50" width="300" height="170" class="mf-box-server"/>
  <text x="180" y="70" class="mf-label-red" text-anchor="middle">wineserver</text>
  <text x="50" y="90" class="mf-label">nspa_alloc_bypass_shm():</text>
  <text x="65" y="106" class="mf-label-sm">1. memfd_create(MFD_CLOEXEC)</text>
  <text x="65" y="120" class="mf-label-sm">2. ftruncate(fd, sizeof(ring))</text>
  <text x="65" y="134" class="mf-label-sm">3. mmap(fd, RW, SHARED)</text>
  <text x="65" y="148" class="mf-label-sm">4. memset(map, 0); active = 1</text>
  <text x="50" y="168" class="mf-label-green">queue-&gt;nspa_bypass_fd = fd</text>
  <text x="50" y="182" class="mf-label-green">queue-&gt;nspa_shared = map</text>
  <text x="50" y="202" class="mf-label">nspa_get_thread_queue handler:</text>
  <text x="65" y="216" class="mf-label-sm">send_client_fd(fd, sync_handle)</text>

  <rect x="590" y="50" width="300" height="200" class="mf-box-nspa"/>
  <text x="740" y="70" class="mf-label-accent" text-anchor="middle">Client thread (ntdll Unix)</text>
  <text x="605" y="92" class="mf-label">SERVER_START_REQ(nspa_get_thread_queue):</text>
  <text x="620" y="106" class="mf-label-sm">wine_server_call(req)</text>
  <text x="620" y="120" class="mf-label-sm">check reply-&gt;fd_sent</text>
  <text x="605" y="140" class="mf-label-green">wine_server_receive_fd(&amp;token):</text>
  <text x="620" y="154" class="mf-label-sm">recvmsg(..., SCM_RIGHTS)</text>
  <text x="620" y="168" class="mf-label-sm">match token == sync_handle</text>
  <text x="605" y="188" class="mf-label-green">mmap(fd, RW, SHARED | MAP_POPULATE):</text>
  <text x="620" y="202" class="mf-label-sm">prefault all pages</text>
  <text x="605" y="222" class="mf-label-green">mlock(map, size):</text>
  <text x="620" y="236" class="mf-label-sm">pin in RAM, no RT page faults</text>

  <line x1="335" y1="215" x2="585" y2="140" stroke="#9ece6a" stroke-width="1.5" fill="none"/>
  <text x="460" y="173" class="mf-label-green" text-anchor="middle">SCM_RIGHTS</text>
  <text x="460" y="186" class="mf-label-sm" text-anchor="middle">fd crosses the wineserver socket</text>

  <line x1="180" y1="225" x2="180" y2="355" stroke="#8c92b3" stroke-width="1.3" fill="none"/>
  <text x="110" y="290" class="mf-label-sm">server-side map</text>

  <line x1="740" y1="255" x2="740" y2="355" stroke="#9ece6a" stroke-width="1.5" fill="none"/>
  <text x="755" y="290" class="mf-label-green">client-side map</text>
  <text x="755" y="304" class="mf-label-sm">(same physical pages)</text>

  <rect x="40" y="260" width="510" height="90" rx="5" fill="#24283b" stroke="#3b4261"/>
  <text x="55" y="280" class="mf-label-accent">Lifetime rules:</text>
  <text x="55" y="298" class="mf-label-sm">1. Server holds fd until msg_queue_destroy -&gt; nspa_free_bypass_shm</text>
  <text x="55" y="312" class="mf-label-sm">2. Each client holds one mmap (+ reference count via page tables)</text>
  <text x="55" y="326" class="mf-label-sm">3. Clients close fd immediately after mmap -- mapping holds the kernel ref</text>
  <text x="55" y="340" class="mf-label-sm">4. On queue destroy: server closes fd + unmaps; client maps drain naturally</text>
</svg>
</div>

The client's mmap lifetime is independent of the server's. If a peer
queue is destroyed while a holder still has it mapped, the holder's
slot reads return whatever was last written to the pages — the page
backing remains as long as any mapping references it. The peer cache's
positive entries become stale and are evicted lazily on next signal
failure (`nspa_clear_cache_entry`); a stale send falls back to server
RPC.

### 4.1 `nspa_cache_entry` per-thread peer cache

The client side caches resolved peers in TLS so subsequent sends to
the same peer skip the `nspa_get_thread_queue` round-trip. From
`msg_ring.c:82-88`:

    struct nspa_cache_entry {
        DWORD                   tid;            /* 0 = empty slot */
        HANDLE                  sync_handle;    /* peer queue->sync */
        nspa_queue_bypass_shm_t *mapped_ptr;    /* peer's bypass mmap (NULL = neg cache) */
        size_t                  mapped_size;
    };

The cache is open-addressed linear probing on `tid` (Wang hash), 128
slots per producer thread (`NSPA_CACHE_SLOTS`, 4 KB lazy-allocated per
producing thread). Sized to comfortably cover a DAW main thread
receiving from 14 AudioCalc workers + ~20 misc UI/timer/library
threads + headroom for VST plugin worker pools. Stored under a
`pthread_key_t` because PE-spawned threads (Ableton's DWM-Sync,
AudioCalc, VST hosts) faulted on `__thread` access in win32u — the
dynamic-TLS block isn't set up on every PE-spawned thread by the time
it enters win32u, but pthread TLS is always live (Wine uses
`pthread_create` to back `CreateThread`).

Each entry caches three values: the wineserver thread id, an event
handle for the peer queue's sync (used by `wine_server_signal_internal_sync`),
and the pointer to the peer's mmap'd ring. A negative-cache sentinel
is `tid` set with `mapped_ptr` NULL, used for cross-process or
otherwise-unreachable peers so the lookup doesn't re-issue an RPC for
each subsequent send.

### 4.2 Own-bypass TLS

Each thread's own bypass shm is also cached in TLS, separately
(`nspa_own_tls_key`). Sentinel values:

    NULL          = never queried
    (void *)-1    = queried, server had no bypass (negative cache)
    valid ptr     = queried, positive (mmap'd ring)

The own bypass is bootstrapped on first call to
`nspa_get_own_bypass_shm()`. It is needed for two purposes: (1) local
wake-bit synthesis in `check_queue_bits()` reads `pending_count` from
this region to surface ring-pending activity in `GetQueueStatus`; (2)
SEND-class messages reserve their reply slot in this region's
`nspa_reply_ring`. Bootstrap is unconditional (skips the
`NSPA_DISABLE_OWN_BOOTSTRAP` gate) because the wake-bit synthesis path
is required for correctness even when the SEND fast-path is disabled.

---

## 5. POST class

`nspa_try_post_ring` (`msg_ring.c:715-887`) handles asynchronous
`PostMessage` deliveries. Returns `TRUE` when the message was delivered
via the ring; the caller skips the server `send_message` request in
that case. `FALSE` means "ineligible / failed" and the caller does the
server path.

### 5.1 Eligibility gates

Returned `FALSE` immediately for any of:

| Gate | Reason |
| --- | --- |
| `NSPA_DISABLE_MSG_BYPASS` env var set | Manual override |
| `type_enum != MSG_POSTED` | POST handles MSG_POSTED only; SEND/notify routed elsewhere |
| `hwnd == 0` | Thread-message; semantics need server's queue rules |
| `dest_tid == own_tid` | Same-thread post; legacy queue semantics |
| `WM_DDE_FIRST <= msg <= WM_DDE_LAST` | DDE has separate registered-message handling |
| Peer cache full | 128-slot table exceeded — rare with stable thread sets |
| Peer in different process | Negative-cache sentinel; falls back to server |
| Ring not active | Receiver not yet bootstrapped |
| Ring full | 64 slots all in flight; bumps `overflow` counter |

### 5.2 Publish sequence

On the accept path:

1. `ring_reserve_slot` performs a CAS-loop on `head`. Bounded to
   `NSPA_RING_RESERVE_RETRY_MAX = 256` iterations to bound a producer's
   stall under SCHED_FIFO same-prio thrash; on exhaustion, returns
   `~0u` and the caller falls through to server post.
2. State transitions to `WRITING` (relaxed store; producer-only
   visibility).
3. All payload fields are written: `type`, `win`, `msg`, `wparam`,
   `lparam`, `time`, `sender_tid`, `sender_pid`, `reply_slot = ~0u`,
   `reply_gen = 0` (POSTs don't take replies, so the ABA guard is
   never engaged), `data_size = 0`.
4. `pending_count` atomically incremented (`ACQ_REL`). Visible to
   server-side wake-bit synthesis from this point.
5. `post_seq` is allocated immediately before `READY` so canonical
   ordering tracks publication time, not reserve time. Server
   arbitration uses this when interleaving ring posts with
   server-routed posts.
6. Release-store on `state = READY`. Pairs with the consumer's
   acquire-load for a happens-before edge over all preceding writes.
7. `change_seq` incremented (release).
8. Wake the receiver:
   `wine_server_signal_internal_sync(entry->sync_handle)` — an
   `NTSYNC_IOC_EVENT_SET_PI` ioctl. On failure, falls through to
   `NtSetEvent`. On dual failure, the MR4 rollback path engages
   ([§10](#10-wake-loss-rollback-mr4)).

Code (`msg_ring.c:819-887`):

    __atomic_store_n( &slot->state, NSPA_MSG_STATE_WRITING, __ATOMIC_RELAXED );
    slot->type        = MSG_POSTED;
    slot->win         = (UINT)(UINT_PTR)hwnd;
    slot->msg         = msg;
    slot->wparam      = (ULONG_PTR)wparam;
    slot->lparam      = (ULONG_PTR)lparam;
    slot->sender_tid  = HandleToULong( NtCurrentTeb()->ClientId.UniqueThread );
    slot->sender_pid  = HandleToULong( NtCurrentTeb()->ClientId.UniqueProcess );
    slot->reply_slot  = ~0u;        /* posted = no reply expected */
    slot->reply_gen   = 0;          /* MR1: no reply, no generation guard */
    slot->data_size   = 0;

    __atomic_fetch_add( &ring->pending_count, 1, __ATOMIC_ACQ_REL );
    slot->post_seq = __atomic_add_fetch( &ring->next_post_seq, 1, __ATOMIC_RELAXED );

    __atomic_store_n( &slot->state, NSPA_MSG_STATE_READY, __ATOMIC_RELEASE );
    __atomic_add_fetch( &ring->change_seq, 1, __ATOMIC_RELEASE );

    status = wine_server_signal_internal_sync( entry->sync_handle );
    if (status) status = NtSetEvent( entry->sync_handle, NULL );
    if (status) {
        /* MR4 rollback path — see §10 */
    }

### 5.3 Consumer-side pop

The receiver's `peek_message` calls `nspa_try_pop_own_ring_post`
(`msg_ring.c:1196-1268`) before the wineserver `get_message` request.
The pop function:

1. Returns FALSE early if `NSPA_DISABLE_CLIENT_RING_DISPATCH` is set
   or if a specific `filter_hwnd` is requested (specific-window filter
   needs the server's window tree to evaluate `is_child_window`).
2. **Arbitration check**: reads `queue_shm->wake_bits` under a
   `NSPA_SHM_RETRY_GUARD`-bounded seqlock retry. If `QS_INPUT |
   QS_HOTKEY | QS_POSTMESSAGE` is set on the server side, the server
   has higher-priority or order-conflicting work pending and the
   client falls back to the server scan. Win32 enforces priority:
   hardware > POST > PAINT, so a blind ring pop when the server has
   older POSTs or any hardware messages would deliver out of order.
3. Walks the ring forward from `tail`, looking for a `READY`
   MSG_POSTED slot with `first <= msg <= last`. CAS-claims via
   `READY → CONSUMED`.
4. Decrements `pending_count`, advances tail over leading runs of
   `CONSUMED`, returns the message fields.

The arbitration window (between the wake-bits read and the CAS) is
microseconds, and the Ableton workload has near-zero server-routed
POSTs once the eager-allocate fix is in place — race is degenerate. If
strict ordering is ever needed, a re-read of wake-bits after CAS with
CONSUMED → READY undo would close it.

### 5.4 Wake-bit synthesis

`NtUserGetQueueStatus`, `check_queue_bits`, and the message pump's
local shmem check all need to report ring-pending activity alongside
legacy `wake_bits`. The wake-bit synthesis path
(`dlls/win32u/input.c`, ~10 LOC) reads the local own-ring's
`pending_count` / `pending_send_count` via `nspa_get_own_bypass_shm_public()`
and ORs synthetic QS bits into the result:

    UINT ring_total = __atomic_load_n( &queue_bypass->nspa_msg_ring.pending_count, ACQUIRE );
    UINT ring_send  = __atomic_load_n( &queue_bypass->nspa_msg_ring.pending_send_count, ACQUIRE );
    if (ring_total > ring_send) ring_bits |= QS_POSTMESSAGE | QS_ALLPOSTMESSAGE;
    if (ring_send)              ring_bits |= QS_SENDMESSAGE;
    wake |= ring_bits;

Without this synthesis, `check_queue_bits` reports "nothing to do"
even after the sender's ntsync wake — the thread sleeps through ring
deliveries until some unrelated event prompts it to call
`get_message`, producing the historical 5 s dispatch-latency timeout.

---

## 6. SEND class

`nspa_try_send_ring` (`msg_ring.c:1371-1633`) handles synchronous
`SendMessage` (MSG_ASCII / MSG_UNICODE) and asynchronous-with-reply-slot
`SendNotifyMessage` (MSG_NOTIFY). Returns `TRUE` with `*result_out`
populated on synchronous success, `TRUE` immediately for MSG_NOTIFY
(no reply expected).

### 6.1 Eligibility gates

Same as POST plus:

| Gate | Reason |
| --- | --- |
| `type_enum` not in (MSG_ASCII, MSG_UNICODE, MSG_NOTIFY) | Other synchronous types (callback, hooked, packed) not supported |
| `NSPA_DISABLE_OWN_BOOTSTRAP` set | Bisection / debug gate |
| Own bypass shm not allocated | Bootstrap failed; falls through to server |
| Reply ring full | 16-slot reply ring exhausted under heavy SEND fan-out |
| Own queue sync handle unavailable | TLS sentinel issue; fall through |

### 6.2 Reply slot reservation

Before publishing the message into the receiver's forward ring, the
sender reserves a slot in its own reply ring:

    own_reply_ring = &((nspa_queue_bypass_shm_t *)own_bypass)->nspa_reply_ring;
    reply_idx = nspa_reply_ring_reserve( own_reply_ring );
    /* ... */
    reply_slot = &own_reply_ring->slots[reply_idx];
    reply_slot->result    = 0;
    reply_slot->error     = 0;
    reply_slot->data_size = 0;
    /* MR1: bump generation under release ordering and capture the
     * post-bump value to stamp into the message slot. */
    reply_gen = __atomic_add_fetch( &reply_slot->generation, 1, __ATOMIC_RELEASE );

`nspa_reply_ring_reserve` (`msg_ring.c:1010-1029`) walks slots from
`next_alloc` looking for `state == FREE`, CAS-claims `FREE → PENDING`,
and returns the index. Returns `~0u` if all 16 slots are PENDING or
READY.

The generation increment is the MR1 ABA guard. Sender captures the
post-increment value into `reply_gen`; this gets stamped into the
message slot's `slot.reply_gen` field. Receiver passes it through to
`nspa_write_ring_reply`, which writes only if the live slot's
`generation` matches. Mechanism in [§8](#8-reply-slot-generation-discriminator-mr1).

### 6.3 Forward ring publish

The forward ring publish (`msg_ring.c:1519-1561`) is the same shape as
POST but populates `reply_slot = reply_idx`, `reply_gen = reply_gen`,
and increments `pending_send_count` in addition to `pending_count`:

    msg_idx = ring_reserve_slot( ring );
    /* ... */
    slot->type       = type_enum;
    /* ... */
    slot->reply_slot = is_notify ? ~0u : reply_idx;
    slot->reply_gen  = is_notify ? 0    : reply_gen;   /* MR1 ABA guard */

    __atomic_fetch_add( &ring->pending_count, 1, __ATOMIC_ACQ_REL );
    __atomic_fetch_add( &ring->pending_send_count, 1, __ATOMIC_ACQ_REL );
    slot->post_seq = __atomic_add_fetch( &ring->next_post_seq, 1, __ATOMIC_RELAXED );

    __atomic_store_n( &slot->state, NSPA_MSG_STATE_READY, __ATOMIC_RELEASE );
    __atomic_add_fetch( &ring->change_seq, 1, __ATOMIC_RELEASE );

    status = wine_server_signal_internal_sync( entry->sync_handle );
    if (status) status = NtSetEvent( entry->sync_handle, NULL );

For `is_notify`, the function returns `TRUE` immediately after the
wake — the caller does not wait for a reply.

### 6.4 Reply wait loop with re-entrant drain

For synchronous SEND (`MSG_ASCII` / `MSG_UNICODE`) the sender enters
the reply wait loop (`msg_ring.c:1587-1623`):

    for (;;) {
        unsigned int state = __atomic_load_n( &reply_slot->state, __ATOMIC_ACQUIRE );
        struct timespec rel;

        if (state == NSPA_REPLY_STATE_READY) break;
        if (waits > 200)  /* 200 * 10 ms = 2 s */ {
            __atomic_store_n( &reply_slot->state, NSPA_REPLY_STATE_FREE, __ATOMIC_RELEASE );
            return FALSE;
        }
        /* Drain inbound SEND messages before waiting so a peer that has
         * called back into us can make forward progress. */
        nspa_process_sent_messages();
        state = __atomic_load_n( &reply_slot->state, __ATOMIC_ACQUIRE );
        if (state == NSPA_REPLY_STATE_READY) break;

        rel.tv_sec  = 0;
        rel.tv_nsec = 10 * 1000 * 1000;  /* 10 ms */
        ret = syscall( SYS_futex, (void *)&reply_slot->state,
                       FUTEX_WAIT, NSPA_REPLY_STATE_PENDING,
                       &rel, NULL, 0 );
        waits++;
    }

Two key shapes worth calling out:

**Re-entrant drain.** Before every futex wait, `nspa_process_sent_messages()`
drains incoming SENDs to the current thread. This is the cross-send
deadlock protection: if the peer's window proc happens to send
synchronously back to us, we must handle that incoming SEND or both
threads block waiting for each other. Each recursion reserves its own
reply slot, so no slot collision; recursion depth is bounded by the
same constraints as ordinary Win32 SendMessage nesting. (MR5 in the
audit; not a bug, called out as a re-entrancy pattern audit tools
miss.)

**Targeted futex on the slot itself.** The wait is on
`&reply_slot->state` rather than on the queue-wide sync handle, so it
only wakes when the receiver writes the reply (which calls
`FUTEX_WAKE` on the same address). No false wakes from unrelated queue
traffic. Earlier designs used `NtWaitForSingleObject` on `queue->sync`,
which woke on every incoming message and caused `waits++` to advance
much faster than the nominal 10 ms tick — the "5 s timeout" fired in
milliseconds under busy-queue conditions. The targeted futex fixed
this.

**FUTEX flag note.** The wait uses plain `FUTEX_WAIT`, not
`FUTEX_WAIT_PRIVATE`. The reason is the MR2 fix — see
[§9](#9-cross-process-futex-mr2). The reply slot lives in a
`MAP_SHARED` memfd, so cross-process wakes must use the global futex
hash, not the per-mm hash that `_PRIVATE` selects.

**2 s timeout.** Lower than the legacy 5 s because the futex actually
waits the full 10 ms when no real signal is pending. Under genuine
receiver outage (peer crashed, window proc deadlocked elsewhere) the
2 s cap is the floor for falling back to server `send_message`.

### 6.5 Consumer-side pop (SEND-class)

Mirrors the POST pop but matches MSG_ASCII / MSG_UNICODE / MSG_NOTIFY.
`nspa_try_pop_own_ring_send` (`msg_ring.c:1093-1165`) is called from
`peek_message` before the `SERVER_START_REQ(get_message)` block:

    if (signal_bits & QS_SENDMESSAGE &&
        nspa_try_pop_own_ring_send( hwnd, first, last,
                                    &pop_type, &pop_msg, &pop_wp, &pop_lp,
                                    &pop_time, &pop_sender, &pop_reply_slot,
                                    &pop_reply_gen, &pop_win )) {
        /* Filled info struct directly; skip server RTT */
    }
    else SERVER_START_REQ(get_message) {
        /* Legacy path */
    }

Critical: the pop function captures `slot->reply_gen` into the output
parameter. This is the value the receiver passes to
`nspa_write_ring_reply` after the window proc returns. Without this
pass-through, MR1's ABA guard cannot operate.

SEND-class pop does NOT do the wake-bits arbitration check that POST
does — SENDs are independent (no FIFO ordering between distinct SENDs
from different threads) so a blind client-side claim cannot misorder.

---

## 7. REPLY class

`nspa_write_ring_reply` (`msg_ring.c:1275-1366`) is the receiver-side
write that closes a SEND. Called from `reply_message()` in
`dlls/win32u/message.c` after the window proc returns:

    if (info->nspa_sender_tid && remove) {
        if (nspa_write_ring_reply( info->nspa_sender_tid,
                                   info->nspa_reply_slot,
                                   info->nspa_reply_gen,    /* MR1 */
                                   result, NULL, 0 ))
            return;   /* direct ring write + signal — no server */
        /* fall through to server reply_message on stale-slot */
    }

Returns `TRUE` if the reply was delivered via the ring; `FALSE` means
the caller falls back to the server `reply_message` path.

### 7.1 Path

1. **Validate inputs.** `sender_tid != 0`, `reply_slot_idx <
   NSPA_REPLY_RING_SLOTS`, `data_size <= NSPA_REPLY_INLINE_MAX`.
2. **Resolve sender** via `nspa_lookup_peer(sender_tid)`. If the
   sender's bypass shm hasn't been mapped by this thread yet, this
   issues an `nspa_get_thread_queue` request and `mmap`s the sender's
   ring. Subsequent replies hit the cache.
3. **Locate reply slot:**
   `bypass->nspa_reply_ring.slots[reply_slot_idx]`.
4. **MR1 ABA guard** — capture the slot's live `generation`, then
   check:
   - `state == NSPA_REPLY_STATE_PENDING` (sender still waiting), AND
   - `generation == expected_gen` (no recycle since sender's stamp).
   On either mismatch, drop the reply silently and return FALSE (the
   caller falls back to server `reply_message`, which is the
   authoritative path for stale-slot recovery).
5. **Write payload:** `result`, `error`, `data_size`, `data[...]`.
6. **Release-store** `state = READY`. This is the ordering edge that
   the sender's acquire-load on `state` pairs with.
7. **Targeted futex_wake** on `&slot->state`. The sender's
   `FUTEX_WAIT(state, PENDING)` returns immediately.
8. **Queue-wide ntsync kick.** Also signal `entry->sync_handle` via
   `wine_server_signal_internal_sync` for any waiter that came in via
   the legacy queue-wide path (e.g., `wait_message_reply` on a
   server-routed send). Cheap; no-op if no waiter.

### 7.2 Code

    slot = &((nspa_queue_bypass_shm_t *)bypass)->nspa_reply_ring.slots[reply_slot_idx];

    {
        unsigned int slot_gen = __atomic_load_n( &slot->generation, __ATOMIC_ACQUIRE );
        unsigned int state    = __atomic_load_n( &slot->state, __ATOMIC_ACQUIRE );
        if (state != NSPA_REPLY_STATE_PENDING) {
            /* Sender already timed out + freed slot, OR slot recycled */
            return FALSE;
        }
        if (expected_gen && slot_gen != expected_gen) {
            /* MR1: ABA — sender timed out, slot recycled to a different sender */
            return FALSE;
        }
    }

    slot->result    = result;
    slot->error     = 0;
    slot->data_size = data_size;
    if (data_size) memcpy( (void *)slot->data, data, data_size );

    __atomic_store_n( &slot->state, NSPA_REPLY_STATE_READY, __ATOMIC_RELEASE );

    syscall( SYS_futex, (void *)&slot->state, FUTEX_WAKE, 1, NULL, NULL, 0 );

    status = wine_server_signal_internal_sync( entry->sync_handle );
    if (status) status = NtSetEvent( entry->sync_handle, NULL );

The `expected_gen == 0` case preserves backwards compatibility for any
caller that didn't track generation (hypothetical pre-MR1 path); falls
back to the state-only check. In current code, every SEND stamps
`reply_gen` so this branch is never taken.

---

## 8. Reply-slot generation discriminator (MR1)

### 8.1 The hazard

The MR1 audit finding (`wine/nspa/docs/wine-nspa-lockup-audit-20260427.md`
§MR1) identified a real correctness bug in the original ring design:
`nspa_reply_slot_t::generation` was bumped on reserve but never compared
by the receiver. Sequence to misdeliver a reply:

1. Sender A reserves slot N, `generation` bumped to G; publishes
   message; waits on `&slot->state`.
2. Receiver R takes >2 s in its window proc.
3. Sender A times out (`waits > 200`), CAS-stores `state = FREE`.
4. Sender B reserves slot N (CAS finds it FREE), `generation` bumped
   to G+1; publishes a different message; waits.
5. Receiver R completes A's window proc, calls
   `nspa_write_ring_reply(A_sender_tid, N, result_for_A)`.
6. Pre-MR1: receiver checks only `state == PENDING` (true — B set it),
   writes `result_for_A` into slot N.
7. Sender B's futex returns, reads `result_for_A`, returns it as if it
   were B's reply.

**Magnitude:** misdelivered `LRESULT`. Could be a value, a pointer, a
status code. Sender B's window proc receives a fabricated reply value.
**Probability:** requires >2 s window proc plus a slot-reuse race
during the gap. Possible under Ableton's heavy UI load, especially
when paint or hook chains stall a window proc.

The MR1 + MR4 reframing in the audit was that this class of silent
contract violation looks like the same family as the upstream Wine
`Disallow Win32 va_list in Unix libraries` fix (`6366775e82a`) — the
symptom is not a deadlock at the bug site but cascading state
corruption that eventually hangs the process via a downstream
state-machine that trusted the corrupted value. Both MR1 and MR4 are
treated as lockup-class for Ableton stability purposes.

### 8.2 The fix

Repurpose the previously-reserved `__pad` field in `nspa_msg_slot_t`
as `reply_gen`. Sender stamps it post-reserve; receiver passes it
through to `nspa_write_ring_reply`; write only on generation match.

#### Wire-level changes

| Layer | Field / argument | Source |
| --- | --- | --- |
| `protocol.def:1062-1065` | `unsigned int reply_gen` (was `__pad`) | Inline comment: `MR1 ABA guard — receiver passes through to nspa_write_ring_reply` |
| `msg_ring.c:1516` | `reply_gen = __atomic_add_fetch(&reply_slot->generation, 1, RELEASE)` | sender captures post-bump value |
| `msg_ring.c:1544` | `slot->reply_gen = is_notify ? 0 : reply_gen` | sender stamps message slot |
| `msg_ring.c:1154` | `*reply_gen_out = slot->reply_gen` | consumer pop function passes through |
| `dlls/win32u/message.c` | `info->nspa_reply_gen` plumbed through `received_message_info` | receiver dispatch path |
| `msg_ring.c:1275-1333` | `expected_gen` parameter, generation compare against `slot->generation` | reply-write check |
| `dlls/win32u/win32u_private.h` | `nspa_write_ring_reply` prototype gains `expected_gen` parameter | (function signature) |

#### Ordering

Sender side:

    /* Step 1: bump generation under RELEASE so the post-bump value is
     * visible to any concurrent receiver that has already started
     * processing a message stamped with the OLD generation. */
    reply_gen = __atomic_add_fetch( &reply_slot->generation, 1, __ATOMIC_RELEASE );

    /* Step 2: stamp the message slot's reply_gen.  Slot is still
     * WRITING, no consumer can see it yet. */
    slot->reply_gen = reply_gen;

    /* Step 3: release-store on slot->state = READY publishes both
     * payload and reply_gen. */
    __atomic_store_n( &slot->state, NSPA_MSG_STATE_READY, __ATOMIC_RELEASE );

Receiver side:

    /* Acquire on slot->state pairs with sender's release-store.
     * After this load, slot->reply_gen is visible. */
    state = __atomic_load_n( &slot->state, __ATOMIC_ACQUIRE );
    if (state != READY) continue;
    expected_gen = slot->reply_gen;
    /* ... CAS-claim slot ... */

In `nspa_write_ring_reply`:

    /* Acquire on slot->generation pairs with the next sender's
     * RELEASE on atomic_add_fetch.  If a recycle has happened
     * since the message we're handling was stamped, this load
     * sees the new generation. */
    slot_gen = __atomic_load_n( &slot->generation, __ATOMIC_ACQUIRE );
    if (expected_gen && slot_gen != expected_gen)
        return FALSE;

The acquire-release pairing is sufficient because the only concurrent
mutation of `generation` is the next sender's atomic-fetch-add at
reserve time. There is no third actor.

### 8.3 What it does NOT defend against

- **Sender process exit** between publish and reply. Receiver's
  `nspa_lookup_peer(sender_tid)` will fail (server returns "thread
  gone") and return FALSE before the slot read; caller falls back to
  server `reply_message`, which handles the stale-sender case via the
  authoritative server-side msg-tracking.
- **Same-sender duplicate reply.** If a window proc somehow gets
  dispatched twice (e.g., a hook chain re-enters), the second
  `write_ring_reply` will find `state != PENDING` (sender already read
  the first reply and set FREE) and drop. Same defense as legacy.
- **Cross-process generation skew.** Generations are monotonic per
  `nspa_reply_slot_t`. Cross-process is irrelevant (slot belongs to
  one process's queue).

### 8.4 P5 sweep — no other latent ABA discriminators

The audit's P5 follow-up swept every `__pad` field in the NSPA shmem
surface (`protocol.def`, 6 instances total) for the same shape. Result:
all clean. Five are pure alignment, one is explicitly reserved for the
documented future Vyukov per-slot-seq redesign on the timer ring. MR1
was uniquely incomplete because the corresponding
`nspa_reply_slot_t::generation` was being bumped on the other side but
never compared by the receiver. No more MR1-shape latent discriminator
bugs lurk in the NSPA shmem surface.

---

## 9. Cross-process futex (MR2)

### 9.1 The hazard

The original SEND code paired:

    /* sender */
    syscall( SYS_futex, &reply_slot->state, FUTEX_WAIT_PRIVATE,
             NSPA_REPLY_STATE_PENDING, &rel, NULL, 0 );

    /* receiver */
    syscall( SYS_futex, &slot->state, FUTEX_WAKE_PRIVATE, 1, NULL, NULL, 0 );

The reply slot lives in a `MAP_SHARED` memfd. `_PRIVATE` tells the
kernel "process-private" and hashes futex keys per-mm. Same-process
this is fine — the hash matches and the wake reaches the waiter. But
**wakes from a different process don't reach the waiter** — different
mm, different hash bucket. The waiter sleeps until its 2 s timeout
expires.

For Ableton today, this was latent: Ableton runs as a single Wine
client process, SEND bypass is intra-process, and `_PRIVATE` matches.
But the bug would surface as soon as we extend SEND bypass to
cross-process scenarios — a daemon-style plugin host, an out-of-process
COM server, or a Wine helper process spawned mid-session. Wakes silently
lost; 2 s timeout becomes the only fallback; throughput collapses to
0.5 SEND/s on the cross-process pair.

### 9.2 The fix

Drop `_PRIVATE`:

    /* sender */
    syscall( SYS_futex, &reply_slot->state, FUTEX_WAIT,
             NSPA_REPLY_STATE_PENDING, &rel, NULL, 0 );

    /* receiver */
    syscall( SYS_futex, &slot->state, FUTEX_WAKE, 1, NULL, NULL, 0 );

`FUTEX_WAIT` / `FUTEX_WAKE` (without `_PRIVATE`) use the global futex
hash, which keys on the underlying physical page rather than the
per-mm virtual address. Cross-process matches correctly because both
processes see the same memfd page.

### 9.3 Performance trade-off

Marginal. The global hash has slightly more contention than the
per-mm hash on hot futexes, but the reply slot is exercised once per
SEND-with-reply-wait, and the futex syscall already dominates that
path. Measured difference: below noise floor on the Ableton workload.

### 9.4 Why this didn't surface earlier

The reply-slot futex was added during the v1 SEND work as a
replacement for `NtWaitForSingleObject` on `queue->sync`. The
`_PRIVATE` flag was carried over reflexively — most futex code uses
`_PRIVATE` because most futexes are process-local mutexes — without
auditing the underlying shared-page lifetime. The MR2 audit caught it
on a focused walk of the futex flag arguments. Lesson logged as part
of the broader `wine-nspa-lockup-audit-20260427.md` follow-up patterns.

---

## 10. Wake-loss rollback (MR4)

### 10.1 The hazard

The POST publish path ends with two-stage signalling:

    status = wine_server_signal_internal_sync( entry->sync_handle );
    if (status) status = NtSetEvent( entry->sync_handle, NULL );
    if (status) {
        /* both failed */
    }

If both signal paths fail (which would mean the sync handle has
died — peer queue destroyed, descriptor closed, ntsync object gone),
the slot is published `READY`, `change_seq` bumped, `pending_count`
incremented — but **no wake reached the receiver**. The receiver will
only find the message if it scans the ring on its own (via a
`change_seq != change_ack_seq` poll in `peek_message`'s hot path). A
receiver blocked in `NtWaitForSingleObject` on its queue sync handle
stays blocked until something else wakes it — which may not happen
until the user moves the mouse or clicks a button.

Pre-MR4: the sender just `WARN`ed and treated the post as accepted
(returned TRUE for POST, fell through to wait-for-reply for SEND). No
retry, no fallback to server `send_message`.

Both-signal-fail is unlikely (would mean the sync handle died) but the
audit treated it as lockup-class because the failure mode is a
permanently-stuck queue with no recovery path. Same shape as MR1 — the
bug isn't the deadlock at the call site; it's the contract violation
that produces a deadlock downstream.

### 10.2 The fix

CAS-rollback the slot from `READY → EMPTY`, decrement `pending_count`,
return FALSE. Caller falls back to authoritative server post.

    if (status) {
        unsigned int expected = NSPA_MSG_STATE_READY;
        BOOL rolled_back = __atomic_compare_exchange_n( &slot->state, &expected,
                                                        NSPA_MSG_STATE_EMPTY, 0,
                                                        __ATOMIC_ACQ_REL,
                                                        __ATOMIC_RELAXED );
        nspa_clear_cache_entry( entry );
        if (rolled_back) {
            __atomic_fetch_sub( &ring->pending_count, 1, __ATOMIC_ACQ_REL );
            return FALSE;   /* caller falls back to server post_message */
        }
        /* rollback failed — consumer beat us — keep return-TRUE */
    }

Two subtlety paths:

**Rollback succeeds.** Consumer hasn't claimed the slot yet (its CAS
on `READY → CONSUMED` would have advanced state past `READY`). We
flip state back to EMPTY, undo the `pending_count` increment, return
FALSE so the caller does the authoritative server post. The slot is
recyclable for the next sender.

**Rollback fails.** Consumer beat us — the CAS found `state != READY`
because the consumer claimed it as `CONSUMED`. The message **will be
delivered** (consumer drives forward progress; it has the slot
contents). Keep the post-acceptance shape (don't roll back
`pending_count`; consumer will decrement on its own consume path).
Return TRUE.

`change_seq` is left advanced in either case. A spurious advance just
causes consumers to scan once and find nothing, which is benign.

### 10.3 Why not also retry signalling

We could retry the signal a couple of times before giving up, but the
audit's reasoning was: if `wine_server_signal_internal_sync` AND
`NtSetEvent` both fail, the sync handle is gone (the peer queue was
destroyed, the ntsync object was freed). Retrying without
re-establishing the handle is futile. The MR4 path correctly clears
the cache entry (`nspa_clear_cache_entry`), so the next send to this
peer will re-resolve via `nspa_get_thread_queue` and either get a new
sync handle or end up in negative-cache.

### 10.4 SEND class — fall through to wait

For SEND (`msg_ring.c:1554-1560`), the dual-signal-fail path is similar
but doesn't rollback because the SEND has already reserved a reply
slot and the wait loop will time out at 2 s. The loop's drain plus
re-check covers the case where the receiver woke for some other
reason and processed the slot. If neither happens, the 2 s timeout
fires, sender CAS-sets `reply_slot->state = FREE`, returns FALSE, and
the caller falls back to server `send_message`. Slightly slower than
the POST rollback (2 s vs immediate), but the SEND wait loop already
handles "no reply arrived" as a first-class failure mode.

---

## 11. Phase A — `redraw_window` push ring

### 11.1 Status

**Shipped, default-on.** Phase A landed in wine commit `72d7a9055a8`
(2026-04-25). Eliminates the synchronous `redraw_window` round-trip on
the hot UI path.

### 11.2 Rationale

`RedrawWindow` is one-way (no `@REPLY`): the client just tells the
server "this window plus this region are dirty; flush invalidation
state appropriately". Pre-Phase-A, every `RedrawWindow` was a full
RTT: client → server → handler runs `redraw_window()` → reply. Ableton
playback hit ~10,930 redraw_window RTTs / 120 s of GUI workload.

Phase A converts this to a one-way push ring. Client appends an entry
to a per-queue ring slot; server drains lazily on its next request
handler dispatch from the same queue.

### 11.3 Layout

`nspa_redraw_ring_t` is co-located in `nspa_queue_bypass_shm_t`
(`protocol.def:1196-1203`):

    typedef volatile struct {
        unsigned int           head;       /* producer (client) advances */
        unsigned int           tail;       /* consumer (server) advances */
        unsigned int           overflow;   /* dropped on ring full */
        unsigned int           active;     /* 0 = consumer not set up */
        nspa_redraw_slot_t     slots[NSPA_REDRAW_RING_SLOTS];
    } nspa_redraw_ring_t;

    typedef volatile struct {
        unsigned int      state;        /* NSPA_REDRAW_STATE_* */
        user_handle_t     window;       /* 0 = desktop window */
        unsigned int      flags;        /* RDW_* */
        unsigned int      rect_count;   /* 0..4; 0 = whole window */
        struct rectangle  rects[NSPA_REDRAW_INLINE_RECTS];
    } nspa_redraw_slot_t;

32 slots × 4 inline rectangles. Rectangles beyond `NSPA_REDRAW_INLINE_RECTS`
fall back to RPC (variable-length payloads need the side-channel
plumbing the message ring carries via `nspa_msg_slot_t::data`, which
the redraw ring intentionally doesn't replicate).

### 11.4 Producer (`dlls/win32u/dce.c:1510-1551`)

`redraw_window_rects` first tries the push ring:

    static BOOL nspa_redraw_ring_try_push( HWND hwnd, UINT flags, const RECT *rects, UINT count )
    {
        nspa_queue_bypass_shm_t *bypass;
        nspa_redraw_ring_t *ring;
        nspa_redraw_slot_t *slot;
        unsigned int head, tail, i;

        if (nspa_redraw_ring_disabled()) return FALSE;
        if (count > NSPA_REDRAW_INLINE_RECTS) return FALSE;

        bypass = (nspa_queue_bypass_shm_t *)nspa_get_own_bypass_shm_public();
        if (!bypass) return FALSE;
        ring = (nspa_redraw_ring_t *)&bypass->nspa_redraw_ring;

        /* SPSC: this thread is sole producer for its own queue's ring. */
        head = ring->head;
        tail = __atomic_load_n( &ring->tail, __ATOMIC_ACQUIRE );
        if (head - tail >= NSPA_REDRAW_RING_SLOTS) {
            __atomic_fetch_add( &ring->overflow, 1, __ATOMIC_RELAXED );
            return FALSE;
        }

        slot = (nspa_redraw_slot_t *)&ring->slots[head % NSPA_REDRAW_RING_SLOTS];
        __atomic_store_n( &slot->state, NSPA_REDRAW_STATE_WRITING, __ATOMIC_RELAXED );
        slot->window     = wine_server_user_handle( hwnd );
        slot->flags      = flags;
        slot->rect_count = count;
        for (i = 0; i < count; i++) slot->rects[i] = ...;
        __atomic_store_n( &slot->state, NSPA_REDRAW_STATE_READY, __ATOMIC_RELEASE );
        __atomic_store_n( &ring->head, head + 1, __ATOMIC_RELEASE );
        return TRUE;
    }

SPSC, so no head-CAS — plain atomic store on `head` after the slot
becomes `READY`. If full, increment `overflow` counter and return
FALSE — caller does the legacy `redraw_window` RPC. No wake signal to
the server: the server drains lazily, on the next request handler
dispatched from this queue's thread.

### 11.5 Consumer (`server/nspa/redraw_ring.c:27-87`)

`nspa_redraw_ring_drain` runs at the top of every request dispatcher
when `current == thread`. Walks the ring forward applying entries via
`nspa_redraw_apply` (`server/window.c`):

    void nspa_redraw_ring_drain( struct thread *thread )
    {
        nspa_queue_bypass_shm_t *shm;
        nspa_redraw_ring_t *ring;
        unsigned int tail, head, saved_error;

        if (!thread || !(shm = nspa_queue_bypass_shm( thread ))) return;
        ring = (nspa_redraw_ring_t *)&shm->nspa_redraw_ring;

        head = __atomic_load_n( &ring->head, __ATOMIC_ACQUIRE );
        tail = ring->tail;
        if (tail == head) return;  /* fast empty path */

        /* Snapshot+restore thread->error: the drain may set_error()
         * on stale handles, and that error must NOT leak into the
         * unrelated request that triggered the drain. */
        saved_error = thread->error;

        while (tail != head) {
            nspa_redraw_slot_t *slot = ...;
            unsigned int state = __atomic_load_n( &slot->state, __ATOMIC_ACQUIRE );
            if (state != NSPA_REDRAW_STATE_READY) break;  /* producer mid-write */

            window     = slot->window;
            flags      = slot->flags;
            rect_count = slot->rect_count;
            for (i = 0; i < rect_count; i++) local_rects[i] = slot->rects[i];

            nspa_redraw_apply( thread, window, flags, ... );

            __atomic_store_n( &slot->state, NSPA_REDRAW_STATE_EMPTY, __ATOMIC_RELEASE );
            tail++;
            __atomic_store_n( &ring->tail, tail, __ATOMIC_RELEASE );
        }

        thread->error = saved_error;
        if (thread == current) global_error = saved_error;
    }

The error snapshot/restore is load-bearing. The drain may hit a stale
handle (window destroyed between client push and drain), a region
validation failure, or a server alloc failure. Any of these calls
`set_error()` on `current`. Pre-snapshot, that error then leaked into
the otherwise-successful reply of the unrelated request that triggered
the drain (e.g., `get_update_region`, `get_visible_region`,
`get_message`). Symptoms: caller saw `STATUS_INVALID_WINDOW_HANDLE` /
`STATUS_INVALID_PARAMETER` on a successful reply, treated the data as
failed, tight-loop repainted, eventually wedged KWin/X11. Same shape
as the gamma offset corruption fix — different mechanism. Fixed by
snapshot/restore.

### 11.6 Empirical results (Phase A ship)

Ableton Live 12 Lite, gamma + Tier 1+2 hook + Phase A, ~120 s with
demo song + menus + window-move:

| RPC | Pre-Phase-A | Post-Phase-A | Delta |
| --- | --- | --- | --- |
| `redraw_window` | 10,930 | **0** | -100% |
| `get_update_region` | 18,185 | 9,633 | -47% (secondary effect) |

The `get_update_region` reduction is partly secondary: fewer redraws
mean fewer paint probe cycles. Plus workload variance.

### 11.7 Cross-thread caveat

Phase A intentionally accepts cross-thread `RedrawWindow` into the
**caller's** queue ring. When server drains,
`nspa_redraw_apply(current_thread, ...)` is called — `current_thread`
is the producer thread, not the window-owner. The server-side
`redraw_window()` static function doesn't differentiate, so this
works. Don't refactor without re-verifying this assumption under
concurrent load.

### 11.8 Opt-out

`NSPA_DISABLE_REDRAW_RING=1` forces all `RedrawWindow` to the legacy
RPC path. Default-on; flag is for bisection only.

---

## 12. Phase B1.0 — paint cache fastpath

### 12.1 Status

**Default-OFF; opt-in via `NSPA_ENABLE_PAINT_CACHE=1`.** The fastpath
is shipped at `dlls/win32u/dce.c:1648-1685`. Validated in two clean
Ableton runs on 2026-04-28 (run-3 default-off, run-4 default-on past
the historical 5-min lockup threshold). One more validation run is
queued before flipping default-on; see [§12.7](#127-current-status-toward-default-on).

### 12.2 Rationale

`get_update_flags` always sends `UPDATE_NOREGION` on the wire and is
the dominant `get_update_region` cost in the post-Phase-A residual:
9.6k RPCs / 120 s of Ableton playback. The dominant call site is the
`erase_now()` `for(;;)` loop in `dce.c:1862`, which polls until the
queue's paint state goes clean.

The server already publishes a queue-level "anything dirty?" answer in
`queue_shm->wake_bits` via `QS_PAINT` — set whenever
`inc_queue_paint_count` flips `paint_count` to >0, cleared when it
returns to 0 (`server/queue.c::inc_queue_paint_count`). When this
thread owns `hwnd` AND `QS_PAINT` is clear, `get_update_region` is
guaranteed to return `flags = 0` (no window in this queue is dirty,
so no paint can be returned for any of its hwnds), so we can skip the
RPC entirely.

### 12.3 The fastpath

`nspa_get_update_flags_try_fastpath` (`dce.c:1648-1685`):

    static BOOL nspa_get_update_flags_try_fastpath( HWND hwnd, HWND *child, UINT *flags )
    {
        struct object_lock lock = OBJECT_LOCK_INIT;
        const queue_shm_t *queue_shm;
        unsigned int wake_bits = 0;
        unsigned int spin = 0;
        UINT status;

        if (nspa_paint_fastpath_disabled()) return FALSE;

        /* No hwnd -> server interprets as "any window owned by current
         * thread"; queue-level QS_PAINT IS the answer.  Otherwise hwnd
         * must be owned by current thread. */
        if (hwnd && !is_current_thread_window( hwnd )) return FALSE;

        /* Bypass shm not mapped yet (early in process startup). */
        if (!nspa_get_own_bypass_shm_public()) return FALSE;

        while ((status = get_shared_queue( &lock, &queue_shm )) == STATUS_PENDING)
        {
            wake_bits = queue_shm->wake_bits;
            NSPA_SHM_RETRY_GUARD( spin, return FALSE );
        }
        if (status) return FALSE;

        /* QS_PAINT set -> at least one window in this queue is dirty.
         * Cannot tell from a single queue bit whether *this* hwnd is
         * the dirty one; fall back to the RPC. */
        if (wake_bits & QS_PAINT) return FALSE;

        /* QS_PAINT clear -> no paint state in this queue ->
         * get_update_region would return flags=0.  Short-circuit. */
        if (child) *child = hwnd;
        *flags = 0;
        return TRUE;
    }

Uses `NSPA_SHM_RETRY_GUARD` ([§14](#14-nspa_shm_retry_guard)) inside
the seqlock retry loop; on retry exhaustion, falls back to RPC.

### 12.4 Caller-side integration

`get_update_flags` (`dce.c:1692-1709`):

    static BOOL get_update_flags( HWND hwnd, HWND *child, UINT *flags )
    {
        BOOL ret;

        if (nspa_get_update_flags_try_fastpath( hwnd, child, flags )) {
            if (nspa_paint_diag_enabled())
                __atomic_fetch_add( &nspa_paint_fastpath_hits, 1, __ATOMIC_RELAXED );
            return TRUE;
        }
        if (nspa_paint_diag_enabled())
            __atomic_fetch_add( &nspa_paint_fastpath_misses, 1, __ATOMIC_RELAXED );

        SERVER_START_REQ( get_update_region ) {
            /* Legacy RPC */
        }
    }

### 12.5 Diagnostic counters

Hit/miss counters are gated behind `NSPA_PAINT_DIAG=1` because they ran
unconditionally on every `get_update_flags` call across every Wine
process — measurable cost on Ableton's polling UI thread (~3,227 calls
per session even with paint-cache disabled, since the miss counter sat
outside the disabled-check). Gated post-`f4a1671973b`.

### 12.6 Default-OFF history

The fastpath was originally shipped default-on (commit `70d55350bef`,
2026-04-26) but reverted same day after Ableton reproducibly locked
up in userspace ~5 min into a session with paint-cache enabled (kernel
never faulted; pure userspace deadlock). The mechanism was unexplained
at the time. Reverted in `4f2c29bb1b2` to gate behind
`NSPA_ENABLE_PAINT_CACHE=1`.

### 12.7 Current status toward default-on

The 2026-04-27 audit failed to identify the F5 paint-cache deadlock
mechanism by code review. Empirical evidence pointed at a slow-build
state-machine corruption rather than an obvious lock cycle. The audit
flagged the most-likely-suspects:
- a class of message types that reach the fastpath but were never
  tested in the validation workload,
- a hook chain that interacts with the cache's notion of "QS_PAINT
  clear",
- a server-side state machine whose seqlock is mutated mid-read.

The MR1 + MR2 + MR4 fix-pack landed 2026-04-27. On 2026-04-28, run-4
was performed with `NSPA_ENABLE_PAINT_CACHE=1` and the historical
5-min lockup was cleared without incident. Multiple drum-track
load-while-playing cycles, audio clean throughout, Ableton exited
cleanly.

**Working hypothesis:** MR1 (reply-slot ABA) was driving F5. Reasoning:
paint-cache amplifies the rate of cross-thread sync sends because it
skips the wineserver round-trip, so any caller that follows up with
a `SendMessage` on a related window sees a higher volume of
fastpath-skipped + sync-send pairings. An ABA-driven misdelivered
LRESULT under that volume would build up state-machine corruption
faster than the off-paint-cache baseline, eventually reaching a
deadlock state where one thread is waiting for a signal that was
misdirected to a different correlation.

MR4 (POST wake-loss) is a secondary candidate: paint-cache enables a
path where queue_shm changes are observed via shmem rather than RPC,
increasing the chance that a wake delivered via
`wine_server_signal_internal_sync` matters for forward progress.

Cannot be definitively confirmed without a from-scratch repro on the
pre-fix wine binary while bpftrace-armed — and that's not worth the
cost given the matching fix set and the clean post-fix validation run.

**DO NOT flip paint-cache default-on yet.** Per
`feedback_validate_before_default_on.md` (NSPA project memory):
"redraw-ring discipline; B1.0 lockup happened because default-on flip
skipped behavioural validation." One clean run is necessary but not
sufficient. Required before flipping default-on:

- One more clean run, ideally on a different day / cold start.
- Long-soak run (>30 min) — the prior 5-min lockup was a "build-up"
  pattern; a longer run gives the system more chances to surface a
  slower variant.
- One additional Ableton workload (record arming, plugin scan, freeze
  track) to vary the load shape from "demo playback + drum-load" alone.

Until those clear, paint-cache stays opt-in via env var.

### 12.8 Opt-in

    NSPA_ENABLE_PAINT_CACHE=1

Default-OFF. Disabled via `NSPA_DISABLE_PAINT_CACHE=1` if a future
B1.x default-on flip is layered.

---

## 13. Phase C — `get_message` bypass (paused)

### 13.1 Status

**Paused mid-development 2026-04-25.** Design notes at
`wine/nspa/docs/msg-ring-v2-phase-bc-handoff.md`. Diagnostic stage 1
(`get_message` residual bucketing) was shipped in `6e83fa72420` and
removed after the Phase C Stage 1 validation cycle (`79bb7c77c40`).
The actual coverage extension is queued.

### 13.2 What remains uncovered

`dlls/win32u/nspa/msg_ring.c` drains *cross-thread* `PostMessage` and
`SendMessage` to the recipient's per-queue ring. Post-Phase-A there is
still residual `get_message` traffic — about 29.7k RPCs / 120 s of
Ableton playback. Inspection candidates (from the handoff doc):

1. **Self-thread messages** — messages this thread posted to itself
   (`PostMessage(hwnd, ..., 0)` where the target's queue == sender's
   queue). v1 may exclude these because the wake-bit synthesis is
   queue-local already.
2. **System messages** — `WM_TIMER`, `WM_PAINT`, `WM_QUIT`, hardware
   messages that the server synthesises into the queue. v1 doesn't
   write these; server does. (`WM_TIMER` already has its own
   class-isolated `nspa_timer_ring`; the local-WM-timer dispatcher
   covers this for in-process timers but server-generated ticks still
   route via RPC.)
3. **Cross-process messages** — if v1's ring is per-process memfd,
   cross-process traffic falls back to RPC. Confirm via peer-cache
   logic.
4. **Late-binding cases** — when the ring's bypass shm isn't
   bootstrapped yet (early in process startup).

The Phase C Stage 1 bucketing diag (now removed) was instrumented to
attribute `get_message` RPCs to one of these categories. Stage 1
results from the validated 2026-04-26 capture: Bucket B (server-
generated `WM_PAINT` / hardware / winevent) dominates 99.9%; A/C/D/E
negligible on the Ableton workload. Stage 2 / 3 would carve a server-
side ring for the dominant category — most likely a hardware-input or
winevent push ring co-located in `nspa_queue_bypass_shm_t`.

### 13.3 Why paused

Phase B1.0 (paint cache) hit the 5-min lockup on its first default-on
validation run, and the audit walked back through the entire
ring-family critical path. MR1 / MR2 / MR4 fix-pack shipped before
Phase C resumes. The next queued message-path work item is Phase C per
`project_msg_ring_v2_phase_c_stage1_validated.md`.

### 13.4 Files queued for Phase C

- `dlls/win32u/message.c`: instrumentation, fast paths.
- `dlls/win32u/nspa/msg_ring.c`: any new ring categories or coverage
  extension.
- `server/queue.c`: server-side ring writers if a new category is
  added.
- `server/protocol.def`: layout extension if a new ring is added.

---

## 14. NSPA_SHM_RETRY_GUARD

### 14.1 Why

Every seqlock-style read in this subsystem (and the broader NSPA
shmem family) needs a bound on the retry loop. SCHED_FIFO callsites
can spin forever if the writer stalls under priority inversion or if
two readers chase a same-prio writer's odd-seq window. The audit
section §4.1 (the original `nspa-bypass-audit.md`) documented this as
"the single rule" for retry loops at SCHED_FIFO callsites.

### 14.2 The macro

`dlls/win32u/win32u_private.h:46-57`:

    /* NSPA — bound for shmem seqlock / CAS retry loops at SCHED_FIFO
     * callsites.  256 PAUSEs ~ tens of microseconds at modern Intel
     * pause latency, comfortably above the writer's odd-seq window
     * for normal traffic.  On exhaustion the caller falls back to
     * the legacy RPC, whose syscall yields the CPU and gives the
     * kernel scheduler a chance to migrate / run any starved writer. */
    #define NSPA_SHM_RETRY_MAX 256

    #define NSPA_SHM_RETRY_GUARD( spin_var, exhaust_action ) do { \
        __builtin_ia32_pause();                                   \
        if (++(spin_var) >= NSPA_SHM_RETRY_MAX) { exhaust_action; }\
    } while (0)

Drop in inside a `while (... == STATUS_PENDING)` loop body. Bounds the
retry count and emits `__builtin_ia32_pause()` to relieve SMT/cache-line
pressure. On exhaustion runs `exhaust_action` (typically
`return FALSE;` or `break;`). Keeps the upstream call sites to a single
line of NSPA-flavored logic per audit §4.1 plus the NSPA reorg style
(concentrate NSPA intent, leave upstream thin).

### 14.3 Call sites

| Site | Hot path | Exhaust action |
| --- | --- | --- |
| `dlls/win32u/dce.c:1670` | paint cache fastpath (default OFF) | `return FALSE;` (force RPC) |
| `dlls/win32u/input.c:863` | `GetQueueStatus` shm read | `return FALSE;` (force RPC) |
| `dlls/win32u/hook.c:77` | `is_hooked` shm read | `return TRUE;` (server is authoritative) |
| `dlls/win32u/nspa/msg_ring.c:1219` | POST arbitration check (`server_pending` query) | `return FALSE;` (server-fallback) |

All four exit the seqlock retry loop deterministically and fall back to
the safe path. Validated by `nspa_rt_test`'s seqlock-bound subtests A
and B (`9b13a757860`, `01efcd076c6`):

- Subtest A: paint fastpath under writer thrash — paint_max 67 µs,
  hard=0.
- Subtest B: queue-bits via `GetQueueStatus` under writer thrash —
  queue-bits max 945 µs, hard=0.

Subtest C (multi-FIFO painter) is queued — needs an external bash
timeout watchdog so the host survives a regression.

### 14.4 Why 256

256 PAUSEs ≈ tens of microseconds at modern Intel PAUSE latency
(~20 ns each on Skylake-era; lower on Haswell, higher on Skylake-X).
The bound is comfortably above any writer's normal odd-seq window
(reservation + payload write + release-store, typically <1 µs).
Anything beyond that strongly suggests a stalled or priority-inverted
writer; the retry doesn't help, and the syscall fallback (which yields
the CPU to the scheduler) is the right answer.

---

## 15. Footnote — why memfd, not session shmem

The memfd design was not the initial plan. The first msg-ring
implementation put the per-queue ring inside Wine's session shmem via
`alloc_shared_object()` — natural given the existing machinery. That
produced a reliable Ableton Live regression: the library panel would
not populate whenever the ring allocation happened for the process's
first thread (MainThread).

A systematic A/B matrix ruled out every runtime code path that reads
or writes the ring. Gates tested (each with bypass on, each in
isolation):

| Gate | Subsystem disabled | Library |
| --- | --- | --- |
| `NSPA_MSG_RING_SERVER_NO_RING_ARB` | ring arbitration in get_posted/get_message | broken |
| `NSPA_MSG_RING_SERVER_NO_WAKE_SYN` | wake-bit synthesis in is_signaled | broken |
| `NSPA_MSG_RING_SERVER_NO_SEQ` | per-message post_seq / change_ack_seq atomics | broken |
| `NSPA_MSG_RING_SERVER_NO_LOCATOR` | zero the wire locator (keep alloc) | broken |
| `NSPA_MSG_RING_SERVER_NO_POISON` | skip mark_block_uninitialized 0x55 fill | broken |
| `NSPA_MSG_RING_SERVER_ID_STRIDE=1` | bump last_object_id by 65536 (ID range) | broken |
| `NSPA_CLIENT_IGNORE_LOCATOR` | client never resolves ring (no reads) | broken |
| `NSPA_MSG_RING_SERVER_NO_ALLOC` | skip alloc_shared_object entirely | **works** |
| `NSPA_MSG_RING_EXCLUDE_MAIN` | block alloc only for first-thread queue | **works** |

Every identifiable runtime side-effect (poison fill, ID bump, locator
publish, seqlock ops) was proven innocent. The bug sat in the mere
presence of a `session_object_t` entry plus its `shared_object_t`
header inside the shared session for the process's first thread. The
specific mechanism was never isolated further — all named side-effects
were ruled out, leaving only a memory-layout / seqlock-interaction
class of cause.

Moving the ring to a per-queue memfd eliminates all of it: no
`session_object_t` entry, no `shared_object_t` header bump, no
`queue_shm_t` locator publish, no interaction with session shmem's
bump allocator. The ring protocol itself (slot layout, state machine,
cache discipline, fast paths) was unchanged — only the allocation +
discovery layer swapped. Library regression resolved end-to-end.

The memfd redesign is the only NSPA bypass that uses memfd rather
than session shmem; it is a documented exception to the
"alloc_shared_object for everything" rule and the rationale lives in
this footnote.

---

## 16. Phase history

### 16.1 Original POST/SEND/REPLY ring

| Phase | Wine commit | Outcome |
| --- | --- | --- |
| `c9daf83afe9` | alloc-side-effect isolation probes | Ruled out poison fill, ID sensitivity |
| `924df6727db` | opt-in `NSPA_MSG_RING_EXCLUDE_MAIN` gate | Workaround for library panel; first-thread specific |
| `54802c6351d` | Memfd redesign implementation plan doc | Plan captured |
| `75de316f9ad` | Phase 1+2 memfd alloc + client mmap | POST capture validated (~95 RTTs/s saved) |
| `4eaf876a118` | Phase 4 `ensure_own_bypass` protocol + client TLS | SEND infrastructure in place |
| `106735ff791` | Phase 4 opt-in gate (default off) | Avoided premature-default stale-slot storm |
| `1d18cb7c4e8` | Phase 4.5 wake-bit synthesis via memfd | Fixed client-side wake-bit blindness |
| `657c16691f5` | Phase 4.6 client-side ring-SEND dispatch | Full SEND bypass validated |
| `70ea71f8c7b` | Design doc update with ballpark reduction | Docs current |

### 16.2 Phase A — `redraw_window` push ring

| Phase | Wine commit | Outcome |
| --- | --- | --- |
| `72d7a9055a8` | Phase A — redraw_window push ring | 10,930 -> 0 RPCs / 120 s; default-on |

### 16.3 Phase B1.0 — paint cache fastpath

| Phase | Wine commit | Outcome |
| --- | --- | --- |
| `c763761b928` | B1.0 paint-cache implementation + diag | Default-OFF; opt-in |
| `70d55350bef` | B1.0 default-on flip post-1006 | Locked Ableton at ~5 min; reverted same day |
| `4f2c29bb1b2` | B1.0 revert paint-cache default to OFF | Stays opt-in via `NSPA_ENABLE_PAINT_CACHE=1` |
| `f4a1671973b` | Gate hit/miss counters behind `NSPA_PAINT_DIAG=1` | Removed always-on counter cost |
| (validation) | run-4 2026-04-28 with paint-cache on | PASS past historical 5-min lockup; F5 likely fixed by MR1/MR4 |

### 16.4 Phase C — `get_message` bypass

| Phase | Wine commit | Outcome |
| --- | --- | --- |
| `6e83fa72420` | Phase C Stage 1 — `get_message` residual bucketing diag | Bucket B dominant 99.9% |
| `79bb7c77c40` | Phase C Stage 1 — remove diag | Diag source removed; coverage extension queued |

### 16.5 MR1/MR2/MR4 audit fix-pack

| Phase | Wine commit | Outcome |
| --- | --- | --- |
| `9b4172e2bbc` | MR1 ABA + MR2 cross-process futex + MR4 POST wake-loss | Three bugs shipped, validated by run-3 + run-4 |
| `ac823311aba` | Audit doc | `wine/nspa/docs/wine-nspa-lockup-audit-20260427.md` |

### 16.6 NSPA_SHM_RETRY_GUARD audit §4.1

| Phase | Wine commit | Outcome |
| --- | --- | --- |
| `9e51ed5f907` | Harden retry loops at SCHED_FIFO callsites (audit §4.1) | 7 sites + the macro |
| `01efcd076c6` | `nspa_rt_test` seqlock-bound subtest A | Paint max 67 µs, hard=0 |
| `9b13a757860` | `nspa_rt_test` seqlock-bound subtest B | Queue-bits max 945 µs, hard=0 |

### 16.7 Bugs left as-is per audit

| ID | Class | Disposition |
| --- | --- | --- |
| MR3 | Peer-cache slot leak for departed peer threads | Perf cliff under thread churn; Ableton's stable thread set unlikely to hit; ~30 LOC GC pass deferred |
| MR5 | Recursive `nspa_process_sent_messages` inside futex wait | By design (cross-send deadlock protection); same re-entrancy contract as ordinary Win32 SendMessage nesting |
| MR6 | `pending_count++` ordered before `state = READY` | Sub-µs benign window; consumer falls through |
| MR7 | `mlock` silent failure | Config-dependent (RLIMIT_MEMLOCK) |
| MR8 | Bucket-lock cross | Not present in this file; client bucket-lock + RPC pattern still queued for `dlls/ntdll/unix/nspa/local_file.c` audit (separate pass) |

### 16.8 Out-of-scope (architectural mismatches)

- **Cross-process messaging** — ring pointers (HWND, WPARAM/LPARAM
  dereferences) are per-address-space. Cross-process messaging must
  stay on the server path unless we add a full translation layer
  (effectively a redesign).
- **DDE** — registered-message handling is separate from the normal
  message dispatch machinery; not a natural fit for the ring.
- **Hardware input queueing** — `thread_input` is a different shared
  structure with server-owned state; out of scope for the per-thread
  bypass ring.

---

## 17. References

### 17.1 Source files (absolute paths)

| Path | Role |
| --- | --- |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/win32u/nspa/msg_ring.c` | Client-side POST/SEND/REPLY ring + caches (1633 LOC) |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/server/protocol.def` | Slot struct definitions, lines 1020-1214 |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/server/queue.c` | Server-side memfd alloc, ring arbitration, signal paths |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/server/nspa/redraw_ring.c` | Phase A server drain (87 LOC) |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/win32u/dce.c` | Phase A producer + Phase B1.0 paint cache fastpath |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/win32u/message.c` | Integration in `send_inter_thread_message`, `peek_message`, `reply_message` |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/win32u/input.c` | Wake-bit synthesis through own ring |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/win32u/win32u_private.h` | `NSPA_SHM_RETRY_GUARD` macro, ring prototypes |

### 17.2 Audit + design docs

| Path | Role |
| --- | --- |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/nspa/docs/wine-nspa-lockup-audit-20260427.md` | MR1-MR8 + F1-F9 + P2/P3/P5 audit findings (612 LOC) |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/nspa/docs/msg-ring-v2-phase-bc-handoff.md` | Phase B + C handoff (paused state, prerequisites for resume) |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/nspa/docs/msg-ring-v2-design-idea.md` | Original v2 thesis (Vyukov MPMC; superseded — see handoff §7) |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/nspa/docs/nspa-bypass-audit.md` | Whole-surface bypass audit (gates Q3+Q4+R6.4 for resuming Phase B/C) |
| `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/nspa/docs/msg-ring-memfd-redesign.md` | Memfd redesign implementation plan (historical) |

### 17.3 Memory entries (`~/.claude/projects/.../memory/`)

- `project_msg_ring_v2_mr1_mr2_mr4_shipped_20260427.md` — Audit fix-pack ship report.
- `project_ableton_run4_paintcache_pass_20260428.md` — Run-4 with paint-cache enabled, F5 likely fixed by MR1/MR4.
- `project_msg_ring_v2_b10_shipped.md` — B1.0 ship + same-day rollback.
- `project_msg_ring_v2_phase_c_stage1_validated.md` — Phase C Stage 1 results (Bucket B 99.9% dominant).
- `project_msg_ring_v2_paused.md` — Pause memo (superseded post-fix-pack).
- `project_audit_4_1_retry_hardening_shipped.md` — `NSPA_SHM_RETRY_GUARD` ship + Subtest A/B results.
- `feedback_validate_before_default_on.md` — Discipline rule: ship default-off, validate, then flip.
- `feedback_dont_shotgun_audit_into_unfound_bug.md` — Discipline rule: KASAN/trace first, audit second.

### 17.4 Related architecture docs in this site

- [current-state.md](current-state.md) — Wine-NSPA state of the art (2026-04-28).
- [gamma-channel-dispatcher.md](gamma-channel-dispatcher.md) — gamma backbone for in-process wineserver dispatch.
- [shmem-ipc.gen.html](shmem-ipc.gen.html) — Shmem v1.5 (orthogonal to the message ring; both share NTSync).
- [io_uring-architecture.gen.html](io_uring-architecture.gen.html) — Orthogonal I/O bypass layer.
- [nspa-local-file-architecture.md](nspa-local-file-architecture.md) — Local-file bypass; bucket-lock context for the F8 / MR8 audit thread.
