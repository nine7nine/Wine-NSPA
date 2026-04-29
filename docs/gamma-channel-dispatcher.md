# Wine-NSPA -- Gamma Channel-Based Wineserver Dispatcher

Wine 11.6 + NSPA RT patchset | Kernel 6.19.x-rt with NTSync channels (1004+1005) | 2026-04-27
Author: jordan Johnston

## Table of Contents

1. [Overview](#1-overview)
2. [Predecessors and Their Failure Modes](#2-predecessors-and-their-failure-modes)
3. [Design Goals](#3-design-goals)
4. [Architecture](#4-architecture)
5. [Kernel Channel Object and ioctls](#5-kernel-channel-object-and-ioctls)
6. [Sender State Machine](#6-sender-state-machine)
7. [Dispatcher State Machine](#7-dispatcher-state-machine)
8. [Priority-Inheritance Semantics](#8-priority-inheritance-semantics)
9. [Phase B Lock-Drop Integration](#9-phase-b-lock-drop-integration)
10. [Thread-Token Pass-Through (T1/T2/T3)](#10-thread-token-pass-through-t1t2t3)
11. [NT Semantics Preservation](#11-nt-semantics-preservation)
12. [Bug History and Audits](#12-bug-history-and-audits)
13. [Validation and Performance](#13-validation-and-performance)
14. [References](#14-references)

---

## 1. Overview

Gamma is the third generation of Wine-NSPA's client-to-wineserver IPC fast
path. It replaces the v1.5 per-thread pthread dispatcher (and the v2.4
cached-CAS / futex-wake hybrid that briefly extended it) with a single
**per-process kernel-mediated request channel** built on top of the
NTSync `NTSYNC_TYPE_CHANNEL` object.

Every Wine client process has exactly one channel fd, opened by the
wineserver during process attach and shipped to the client via
`SCM_RIGHTS` in the `init_first_thread` reply. Client threads issue
`NTSYNC_IOC_CHANNEL_SEND_PI` to atomically enqueue a request, boost the
dispatcher pthread to the sender's priority, and block for reply, all
in one syscall. The wineserver runs one dispatcher pthread per client
process which loops on `NTSYNC_IOC_CHANNEL_RECV2` (or `RECV` if the
kernel predates patch 1005), runs the existing `read_request_shm`
handler under `global_lock`, and finally calls
`NTSYNC_IOC_CHANNEL_REPLY` to wake the originator and drain its PI
boost.

The key win over the legacy designs: priority inheritance is now
**kernel-atomic**. There is no userspace TID-read-vs-`sched_setscheduler`
race window, no `pthread_setschedparam` call against a thread that may
have already exited, and no userspace bookkeeping of "who is currently
boosted to what". The kernel's `apply_event_pi_boost` /
`consume_event_pi_boost` machinery (introduced in ntsync patch 1008
deferred-boost) handles all of it inside the same lock that orders the
queue.

The published `shmem-ipc.gen.html` describes v1.5 and v2.4. That
document is **superseded** by this one. Gamma is the architecture in
production today.

---

## 2. Predecessors and Their Failure Modes

### 2.1 Alpha (v1.5) -- per-thread pthread + userspace `sched_setscheduler`

The original Torge Matthies forward-port spawned **one dispatcher
pthread per client thread**. Each pthread owned a thread-private
`request_shm` page and watched a futex word inside it. When the client
wrote a request, it raised the word and `FUTEX_WAKE`-ed the dispatcher;
the dispatcher locked `global_lock`, ran the handler, wrote the reply,
and lowered the word so the client's `FUTEX_WAIT` returned.

Priority inheritance was bolted on in userspace. Before sending, the
client did `sched_setscheduler(dispatcher_tid, RT_POLICY, our_prio)`
to boost the dispatcher to the caller's level. After reply, the
dispatcher reset its own scheduler attrs.

The pain points:

- **N dispatchers per process** all waking on the same `global_lock`.
  A 60-thread DAW had 60 dispatcher pthreads contending for one mutex.
- **TID race window.** The client read `dispatcher_tid` from a shared
  field, then called `sched_setscheduler`. Between the read and the
  syscall the dispatcher could exit and another thread could be
  assigned the same tid by the kernel; the boost would land on a
  random thread. We never observed this in production but it was a
  real correctness hole.
- **Capability churn.** Boost / unboost cycles forced
  `cap_sys_nice`-bearing syscalls on every request.
- **Userspace PI accounting.** The wineserver maintained its own
  "current boost level" cache so that overlapping senders did not
  trample each other's boost. Hand-rolled PI is brittle; under stress
  we hit unboost-too-early bugs.

### 2.2 Beta (v2.4) -- cached-CAS + manual prio cache

v2.4 narrowed the steady-state cost: senders cached their RT prio in
`ntdll_thread_data`, did a CAS on a request-state word, did a single
`FUTEX_WAKE`, and only fell back to `sched_setscheduler` when the
cached dispatcher prio was below ours. This eliminated four syscalls
per request on the steady-state hot path but left every architectural
problem of v1.5 in place: still one dispatcher per thread, still
userspace TID-read-vs-setscheduler racing, still hand-rolled PI
arithmetic. The "cache" added a third place where boost state could
desync.

### 2.3 The case for moving boost into the kernel

Once NTSync gained an event PI primitive (patch 1006, eventually
deferred-boost in 1008), it was clear that PI for IPC could ride the
same machinery. The legacy machinery had three structural problems no
amount of userspace engineering could fix:

| Structural problem | Gamma resolution |
|---|---|
| N pthreads per process contending on `global_lock` | One dispatcher per process; contention is O(1) per process |
| TID-read vs `sched_setscheduler` race window | Kernel boosts dispatcher inside the same syscall that enqueues |
| Userspace PI accounting drift | Kernel owns the boost state; userspace never reads or writes it |

Gamma is the smallest design that closes all three.

---

## 3. Design Goals

The gamma redesign was scoped tightly:

- **One dispatcher pthread per client process.** Not per thread; not
  router/handler split (deferred to a later phase, see
  `project_gamma_dispatcher_audit_and_split_plan.md`). Just one
  pthread that drains the channel sequentially.
- **Single ioctl per request on the sender side.** Enqueue + boost +
  block-for-reply must be one syscall, not three. Anything less leaks
  PI gaps.
- **Single ioctl per reply on the dispatcher side.** Wake-sender +
  drain-our-boost must be atomic. Otherwise a higher-prio sender that
  arrived during our handler would be unboosted before the dispatcher
  picks them up.
- **Zero-copy payloads.** Reuse the v1.5 per-thread `request_shm` page
  exactly as-is. The channel only carries metadata (TID + priority),
  never request data.
- **Behavioural neutrality vs upstream.** Per-thread request ordering
  must be preserved; cross-thread ordering can become priority-ordered
  (strictly stronger, never weaker, than the legacy "first-to-wake"
  shape).
- **Graceful fallback.** If the kernel lacks the channel ioctls, the
  client must transparently fall back to the upstream socket path.
  Same for senders that arrive before their dispatcher pthread has
  managed to spawn.

The gating env var `NSPA_DISPATCHER_USE_TOKEN=0` gives an A/B handle
for the T3 thread-token optimisation but does not gate gamma itself --
gamma is unconditional when the kernel ioctls are present.

---

## 4. Architecture

### 4.1 Component diagram

The gamma path involves four cooperating components:

| Component | Location | Role |
|---|---|---|
| Kernel channel object | `drivers/misc/ntsync.c` lines 1190-1494 | Priority rbtree of pending entries; PI boost machinery |
| Sender shim | `dlls/ntdll/unix/server.c` lines 311-436 | `nspa_send_request_channel`: copy header, ioctl, copy reply |
| Dispatcher pthread | `server/nspa/shmem_channel.c` lines 134-242 | `channel_dispatcher`: RECV2 loop, handler under `global_lock`, REPLY |
| Per-thread shmem | unchanged from v1.5 | Holds request payload and reply payload (zero-copy) |

The channel fd is created in process attach
(`nspa_shmem_channel_init`, `server/nspa/shmem_channel.c:244`), spawned
detached as a pthread with explicit RT scheduler attrs when
`NSPA_SRV_RT_PRIO > 0`, and shipped to the client over `SCM_RIGHTS`
alongside the existing per-thread `request_shm` fds in the
`init_first_thread` reply. The client stashes it in
`nspa_request_channel_fd` and from then on uses it for every
`server_call_unlocked` whose request fits in the per-thread shmem
window.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 340" xmlns="http://www.w3.org/2000/svg">
  <style>
    .gc-bg { fill: #1a1b26; }
    .gc-process { fill: #24283b; stroke: #3b4261; stroke-width: 1.5; rx: 10; }
    .gc-client { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .gc-kernel { fill: #2a1f35; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .gc-server { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .gc-shmem  { fill: #2a2418; stroke: #e0af68; stroke-width: 1.5; rx: 8; }
    .gc-label  { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .gc-sm     { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .gc-head   { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .gc-blue   { fill: #7aa2f7; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .gc-pur    { fill: #bb9af7; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .gc-grn    { fill: #9ece6a; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .gc-yel    { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .gc-arrow-b { stroke: #7aa2f7; stroke-width: 1.8; fill: none; }
    .gc-arrow-p { stroke: #bb9af7; stroke-width: 1.8; fill: none; }
    .gc-arrow-g { stroke: #9ece6a; stroke-width: 1.8; fill: none; }
    .gc-arrow-y { stroke: #e0af68; stroke-width: 1.6; fill: none; stroke-dasharray: 5,4; }
  </style>

  <rect x="0" y="0" width="960" height="340" class="gc-bg"/>
  <text x="480" y="24" text-anchor="middle" class="gc-head">Gamma channel topology</text>

  <rect x="24" y="48" width="276" height="248" class="gc-process"/>
  <text x="42" y="70" class="gc-blue">Client process</text>
  <text x="42" y="84" class="gc-sm">many sender threads, one shared channel fd</text>

  <rect x="44" y="104" width="108" height="54" class="gc-client"/>
  <text x="98" y="126" text-anchor="middle" class="gc-label">sender thread A</text>
  <text x="98" y="143" text-anchor="middle" class="gc-sm">memcpy req</text>

  <rect x="168" y="104" width="108" height="54" class="gc-client"/>
  <text x="222" y="126" text-anchor="middle" class="gc-label">sender thread B</text>
  <text x="222" y="143" text-anchor="middle" class="gc-sm">memcpy req</text>

  <rect x="44" y="186" width="232" height="62" class="gc-shmem"/>
  <text x="160" y="208" text-anchor="middle" class="gc-yel">per-thread request_shm pages</text>
  <text x="160" y="225" text-anchor="middle" class="gc-sm">payload and reply remain zero-copy</text>
  <text x="160" y="239" text-anchor="middle" class="gc-sm">channel carries metadata only</text>

  <rect x="74" y="264" width="172" height="22" class="gc-client"/>
  <text x="160" y="279" text-anchor="middle" class="gc-sm">nspa_request_channel_fd</text>

  <rect x="342" y="72" width="276" height="200" class="gc-process"/>
  <text x="360" y="94" class="gc-pur">Kernel</text>
  <text x="360" y="108" class="gc-sm">ntsync channel object</text>

  <rect x="370" y="128" width="220" height="94" class="gc-kernel"/>
  <text x="480" y="151" text-anchor="middle" class="gc-label">priority rbtree of entries</text>
  <text x="480" y="168" text-anchor="middle" class="gc-sm">sender_tid, prio, payload_off, thread_token</text>
  <text x="480" y="185" text-anchor="middle" class="gc-sm">SEND_PI enqueue + boost + block</text>
  <text x="480" y="202" text-anchor="middle" class="gc-sm">RECV2 dequeue + boost dispatcher</text>
  <text x="480" y="216" text-anchor="middle" class="gc-sm">REPLY wake sender + drain / re-boost</text>

  <rect x="660" y="48" width="276" height="248" class="gc-process"/>
  <text x="678" y="70" class="gc-grn">Wineserver process</text>
  <text x="678" y="84" class="gc-sm">one dispatcher pthread per client process</text>

  <rect x="684" y="104" width="228" height="62" class="gc-server"/>
  <text x="798" y="126" text-anchor="middle" class="gc-label">channel_dispatcher pthread</text>
  <text x="798" y="143" text-anchor="middle" class="gc-sm">RECV2 loop at NSPA_SRV_RT_PRIO</text>
  <text x="798" y="157" text-anchor="middle" class="gc-sm">thread-token-aware on T1/T2/T3 kernels</text>

  <rect x="684" y="194" width="228" height="70" class="gc-server"/>
  <text x="798" y="216" text-anchor="middle" class="gc-label">existing request handlers</text>
  <text x="798" y="233" text-anchor="middle" class="gc-sm">read_request_shm under global_lock</text>
  <text x="798" y="247" text-anchor="middle" class="gc-sm">writes reply back into request_shm</text>

  <line x1="246" y1="275" x2="370" y2="175" class="gc-arrow-p"/>
  <text x="305" y="208" text-anchor="middle" class="gc-pur">SEND_PI / block for reply</text>

  <line x1="590" y1="175" x2="684" y2="135" class="gc-arrow-g"/>
  <text x="638" y="146" text-anchor="middle" class="gc-grn">RECV2</text>

  <line x1="684" y1="228" x2="590" y2="228" class="gc-arrow-g"/>
  <text x="638" y="220" text-anchor="middle" class="gc-grn">REPLY</text>

  <line x1="160" y1="186" x2="160" y2="158" class="gc-arrow-y"/>
  <line x1="798" y1="194" x2="798" y2="166" class="gc-arrow-y"/>
  <text x="480" y="320" text-anchor="middle" class="gc-sm">Attach-time path: wineserver creates the channel fd and transfers it to the client with SCM_RIGHTS in init_first_thread.</text>
</svg>
</div>

### 4.2 Per-request data flow

For a single request the data movement is:

    Client                          Kernel channel             Dispatcher
    ------                          --------------             ----------
    1. memcpy req hdr+data ->
       request_shm[caller_tid]
    2. ioctl SEND_PI ---------->    enqueue (prio,
                                    payload_off=tid,
                                    thread_token)
                                    apply PI boost to
                                    dispatcher
                                    block sender
                                                          <--- ioctl RECV2
                                    dequeue highest-prio
                                    boost dispatcher to
                                    entry's prio
                                    return entry, token
                                                               3. global_lock
                                                                  read_request_shm
                                                                  (writes reply
                                                                   into shmem)
                                                                  global_unlock
                                                          <--- ioctl REPLY(entry_id)
                                    wake sender
                                    drain dispatcher's
                                    boost from this entry
                                    re-boost to next
                                    entry's prio if any
    4. SEND_PI returns
    5. memcpy reply hdr+data <-
       request_shm[caller_tid]

Steps 2 and the unboost-and-reboost inside the kernel REPLY handler
are atomic with respect to each other under the channel's internal
spinlock. There is no observable interval where the dispatcher is
running unboosted while another high-prio entry sits ready in the
queue.

### 4.3 End-to-end flow diagram

The following inline SVG shows a single request's lifecycle through
gamma. Two senders are shown at differing priorities to illustrate
the rbtree's strict-priority ordering and REPLY's automatic
re-boost.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 640" xmlns="http://www.w3.org/2000/svg">
  <style>
    .gd-bg     { fill: #1a1b26; }
    .gd-client { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.5; rx: 6; }
    .gd-kernel { fill: #1a1a2a; stroke: #bb9af7; stroke-width: 2;   rx: 6; }
    .gd-server { fill: #24283b; stroke: #9ece6a; stroke-width: 2;   rx: 6; }
    .gd-shmem  { fill: #2a2418; stroke: #e0af68; stroke-width: 1.5; rx: 6; }
    .gd-lane   { fill: none;    stroke: #3b4261; stroke-width: 1; stroke-dasharray: 6,4; }
    .gd-title  { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .gd-h      { fill: #c0caf5; font: bold 11px 'JetBrains Mono', monospace; }
    .gd-l      { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .gd-m      { fill: #8c92b3; font: 9px 'JetBrains Mono', monospace; }
    .gd-acc    { fill: #7aa2f7; font: bold 10px 'JetBrains Mono', monospace; }
    .gd-grn    { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .gd-red    { fill: #f7768e; font: bold 10px 'JetBrains Mono', monospace; }
    .gd-yel    { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .gd-pur    { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
  </style>

  <rect x="0" y="0" width="980" height="640" class="gd-bg"/>

  <text x="490" y="22" text-anchor="middle" class="gd-title">Gamma channel: two senders, one dispatcher, kernel-mediated PI</text>

  <!-- swim-lanes -->
  <line x1="170" y1="40"  x2="170" y2="620" class="gd-lane"/>
  <line x1="430" y1="40"  x2="430" y2="620" class="gd-lane"/>
  <line x1="690" y1="40"  x2="690" y2="620" class="gd-lane"/>

  <text x="85"  y="56" text-anchor="middle" class="gd-h">CLIENT THREAD A</text>
  <text x="85"  y="70" text-anchor="middle" class="gd-m">FIFO 80 (audio)</text>

  <text x="300" y="56" text-anchor="middle" class="gd-h">CLIENT THREAD B</text>
  <text x="300" y="70" text-anchor="middle" class="gd-m">FIFO 50 (gui)</text>

  <text x="560" y="56" text-anchor="middle" class="gd-h">KERNEL CHANNEL</text>
  <text x="560" y="70" text-anchor="middle" class="gd-m">priority rbtree + PI boost</text>

  <text x="830" y="56" text-anchor="middle" class="gd-h">DISPATCHER PTHREAD</text>
  <text x="830" y="70" text-anchor="middle" class="gd-m">SCHED_FIFO base 64</text>

  <!-- t0: B sends first -->
  <rect x="220" y="92" width="160" height="32" class="gd-client"/>
  <text x="300" y="105" text-anchor="middle" class="gd-l">memcpy req -> shmem[B]</text>
  <text x="300" y="118" text-anchor="middle" class="gd-m">request_shm[B_tid]</text>

  <line x1="380" y1="108" x2="480" y2="148" stroke="#bb9af7" stroke-width="1.5"/>
  <text x="430" y="125" class="gd-pur" text-anchor="middle">SEND_PI(prio=50)</text>

  <rect x="480" y="135" width="160" height="44" class="gd-kernel"/>
  <text x="560" y="150" text-anchor="middle" class="gd-l">enqueue B @prio 50</text>
  <text x="560" y="164" text-anchor="middle" class="gd-l">apply_event_pi_boost</text>
  <text x="560" y="176" text-anchor="middle" class="gd-pur">dispatcher: 64 -> 50? NO (50&lt;64)</text>

  <line x1="640" y1="156" x2="740" y2="180" stroke="#bb9af7" stroke-width="1.5"/>
  <text x="710" y="170" class="gd-pur">wake</text>

  <rect x="740" y="170" width="200" height="32" class="gd-server"/>
  <text x="840" y="183" text-anchor="middle" class="gd-l">RECV2 -> entry B</text>
  <text x="840" y="196" text-anchor="middle" class="gd-grn">re-boost dispatcher to 64</text>

  <!-- t1: A arrives mid-handler -->
  <rect x="20" y="228" width="160" height="32" class="gd-client"/>
  <text x="100" y="241" text-anchor="middle" class="gd-l">memcpy req -> shmem[A]</text>
  <text x="100" y="254" text-anchor="middle" class="gd-m">request_shm[A_tid]</text>

  <line x1="180" y1="244" x2="480" y2="268" stroke="#7aa2f7" stroke-width="1.5"/>
  <text x="330" y="258" class="gd-acc" text-anchor="middle">SEND_PI(prio=80)</text>

  <rect x="480" y="258" width="160" height="60" class="gd-kernel"/>
  <text x="560" y="273" text-anchor="middle" class="gd-l">enqueue A @prio 80</text>
  <text x="560" y="287" text-anchor="middle" class="gd-l">apply_event_pi_boost</text>
  <text x="560" y="300" text-anchor="middle" class="gd-acc">dispatcher: 64 -> 80 IMMEDIATE</text>
  <text x="560" y="314" text-anchor="middle" class="gd-m">A blocks waiting for REPLY</text>

  <!-- handler runs at 80 (preempted up) -->
  <rect x="740" y="232" width="200" height="68" class="gd-server"/>
  <text x="840" y="248" text-anchor="middle" class="gd-l">global_lock</text>
  <text x="840" y="262" text-anchor="middle" class="gd-l">read_request_shm(B)</text>
  <text x="840" y="276" text-anchor="middle" class="gd-acc">running @80 due to A's boost</text>
  <text x="840" y="290" text-anchor="middle" class="gd-l">global_unlock</text>

  <!-- t2: REPLY for B -->
  <line x1="740" y1="316" x2="640" y2="350" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="690" y="332" class="gd-grn" text-anchor="middle">REPLY(B)</text>

  <rect x="480" y="334" width="160" height="62" class="gd-kernel"/>
  <text x="560" y="350" text-anchor="middle" class="gd-l">complete B.reply_done</text>
  <text x="560" y="364" text-anchor="middle" class="gd-l">drain B's PI contribution</text>
  <text x="560" y="378" text-anchor="middle" class="gd-acc">re-boost from queue head: 80</text>
  <text x="560" y="392" text-anchor="middle" class="gd-m">(A is now head)</text>

  <line x1="480" y1="358" x2="380" y2="402" stroke="#bb9af7" stroke-width="1.5"/>
  <text x="430" y="382" class="gd-pur" text-anchor="middle">B wakes</text>

  <rect x="220" y="394" width="160" height="32" class="gd-client"/>
  <text x="300" y="407" text-anchor="middle" class="gd-l">memcpy reply <- shmem[B]</text>
  <text x="300" y="420" text-anchor="middle" class="gd-m">SEND_PI returns</text>

  <!-- t3: dispatcher RECV2 again -->
  <line x1="640" y1="382" x2="740" y2="426" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="710" y="404" class="gd-grn">RECV2</text>

  <rect x="740" y="418" width="200" height="32" class="gd-server"/>
  <text x="840" y="431" text-anchor="middle" class="gd-l">RECV2 -> entry A</text>
  <text x="840" y="444" text-anchor="middle" class="gd-acc">no re-boost: same prio 80</text>

  <rect x="740" y="458" width="200" height="46" class="gd-server"/>
  <text x="840" y="474" text-anchor="middle" class="gd-l">global_lock</text>
  <text x="840" y="488" text-anchor="middle" class="gd-l">read_request_shm(A)</text>
  <text x="840" y="500" text-anchor="middle" class="gd-l">global_unlock</text>

  <line x1="740" y1="500" x2="640" y2="528" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="690" y="516" class="gd-grn" text-anchor="middle">REPLY(A)</text>

  <rect x="480" y="510" width="160" height="44" class="gd-kernel"/>
  <text x="560" y="524" text-anchor="middle" class="gd-l">complete A.reply_done</text>
  <text x="560" y="538" text-anchor="middle" class="gd-l">drain A's PI</text>
  <text x="560" y="551" text-anchor="middle" class="gd-yel">queue empty -> back to base 64</text>

  <line x1="480" y1="534" x2="180" y2="572" stroke="#7aa2f7" stroke-width="1.5"/>
  <text x="330" y="558" class="gd-acc" text-anchor="middle">A wakes</text>

  <rect x="20" y="568" width="160" height="32" class="gd-client"/>
  <text x="100" y="581" text-anchor="middle" class="gd-l">memcpy reply <- shmem[A]</text>
  <text x="100" y="594" text-anchor="middle" class="gd-m">SEND_PI returns</text>

  <!-- legend -->
  <rect x="20" y="610" width="940" height="22" fill="#24283b" stroke="#3b4261" stroke-width="1" rx="4"/>
  <text x="32"  y="625" class="gd-acc">A: prio 80</text>
  <text x="120" y="625" class="gd-pur">B: prio 50</text>
  <text x="210" y="625" class="gd-grn">REPLY = wake + drain + auto-reboost</text>
  <text x="500" y="625" class="gd-yel">empty queue -> base prio</text>
  <text x="700" y="625" class="gd-m">all kernel ops under channel->lock spinlock</text>
</svg>
</div>

The two-sender scenario shows the property that motivated gamma:
between B's REPLY and the dispatcher's next RECV2, the dispatcher
**stays at FIFO 80** because the kernel re-boosted from the new
queue head atomically inside REPLY. The legacy v1.5 design would
have unboosted the dispatcher to 64 at unboost-time and then
re-boosted to 80 only when A's `sched_setscheduler` landed --
which would have raced with the dispatcher's own RECV-side
runqueue insertion. Gamma closes that gap by construction.

---

## 5. Kernel Channel Object and ioctls

The kernel side lives in `drivers/misc/ntsync.c` (Linux-NSPA tree at
`/home/ninez/pkgbuilds/Linux-NSPA-pkgbuild/linux-nspa-6.19.11-1.src/linux-nspa/src/linux-6.19.11/drivers/misc/ntsync.c`,
lines 1190-1494 for the channel object). Each NTSync channel is:

    struct ntsync_channel {
        struct ntsync_obj   obj;          /* base */
        spinlock_t          lock;         /* serialises queue + boost state */
        struct rb_root      entries;      /* priority-ordered by entry->prio */
        u32                 max_depth;
        struct hlist_head   thread_tokens;/* (tid -> struct thread *) registry */
        ...
    };

    struct ntsync_channel_entry {
        struct rb_node      node;
        u32                 prio;
        u32                 sender_tid;
        u64                 payload_off;
        u64                 reply_off;
        u64                 thread_token;
        struct task_struct *sender;
        struct completion   reply_done;
        refcount_t          refs;          /* added by patch 1009 (see audit) */
    };

The channel exposes six ioctls. Five are core to gamma's hot path; one
is for opening a channel during process attach.

| ioctl | Direction | Patch | Purpose |
|---|---|---|---|
| `NTSYNC_IOC_CREATE_CHANNEL` | wineserver | 1004 | Open a new channel, return fd. `max_depth` caps queued entries. |
| `NTSYNC_IOC_CHANNEL_SEND_PI` | client | 1004 | Enqueue + boost dispatcher + block for reply, atomically. |
| `NTSYNC_IOC_CHANNEL_RECV` | dispatcher | 1004 | Dequeue highest-prio entry; boost dispatcher to that prio; return metadata. |
| `NTSYNC_IOC_CHANNEL_RECV2` | dispatcher | 1005 | Same as RECV but additionally returns `thread_token`. |
| `NTSYNC_IOC_CHANNEL_REPLY` | dispatcher | 1004 | Wake the matching entry's sender; drain our PI boost from that entry; auto-re-boost to the next pending entry's prio if any. |
| `NTSYNC_IOC_CHANNEL_REGISTER_THREAD` / `DEREGISTER_THREAD` | wineserver | 1005 | Register `(tid -> struct thread *)` for token pass-through. |

The userspace UAPI structs are defined in `linux/ntsync.h` and
fall-back-defined in both `dlls/ntdll/unix/server.c:339-347` and
`server/nspa/shmem_channel.c:60-107` for clients running against a
kernel header that predates the patches. The fall-back blocks
`#ifndef NTSYNC_IOC_CREATE_CHANNEL` so they activate exactly when the
build host's headers are stale; once the kernel headers carry the
definitions the fall-back is silently ignored.

Operationally the channel's policy is **strict-priority + FIFO inside
each priority class**. The rbtree key is `(prio_desc, enqueue_seq_asc)`.
A SCHED_FIFO sender at prio 70 always drains before any sender at
prio 65; among prio-70 senders they drain in arrival order.
SCHED_OTHER senders pass `prio = 0` and the kernel routes them at
the bottom of the tree.

---

## 6. Sender State Machine

The client-side entry point is `nspa_send_request_channel` in
`dlls/ntdll/unix/server.c:349`. The function is invoked from
`server_call_unlocked` (line 442) when **all three** preconditions hold:

- `nspa_request_channel_fd >= 0` -- channel was successfully opened by
  the wineserver and the fd survived the SCM_RIGHTS exchange;
- `ntdll_get_thread_data()->request_shm` is non-NULL -- per-thread
  shmem is mapped (set up during `init_thread`);
- `sizeof(req->u.req) + req->u.req.request_header.request_size <
  NSPA_REQUEST_SHM_SIZE` -- request fits in the zero-copy window.

If any precondition fails, `server_call_unlocked` falls through to the
upstream socket path (`send_request` + `wait_reply`). This is the
ungated, transparent fallback.

The state machine for the gamma path is:

    1. memcpy req->u.req into request_shm->u.req
    2. for each req->data[i]:
           memcpy into request_shm[after-header]
    3. read data->nspa_rt_cached_prio (set by nspa_rt_apply_tid)
       if > 0:
           args.policy = data->nspa_rt_cached_policy
           args.prio   = data->nspa_rt_cached_prio
       else:
           args.policy = 0; args.prio = 0    /* SCHED_OTHER, no boost */
    4. args.payload_off = GetCurrentThreadId()
       args.reply_off   = same  (channel is metadata-only)
    5. data_ptr  = request_shm + sizeof(req) + request_size
       copy_limit = end-of-shmem - data_ptr
       /* Computed BEFORE the SEND_PI: req->u.req and req->u.reply
          share union storage, so post-reply reads of request_size
          would actually return reply_size. */
    6. ioctl SEND_PI            <-- blocks until REPLY
       on EINTR: fall through to read reply (server already wrote it)
       on any other error: return STATUS_INTERNAL_ERROR
    7. memcpy request_shm->u.reply -> req->u.reply
    8. if reply_size > copy_limit:
           split: copy first copy_limit bytes from shmem
                  read remainder via socket fallback (read_reply_data)
       else:
           memcpy reply_size bytes from shmem
    9. return req->u.reply.reply_header.error

Two subtleties worth highlighting:

- **The data_ptr / copy_limit computation must happen before the
  SEND_PI**, not after. This was a v2.4 invariant carried forward
  unchanged. After SEND_PI returns, `request_shm->u.req` and
  `request_shm->u.reply` share union storage; reading
  `request_header.request_size` post-reply actually reads
  `reply_header.reply_size` (same byte offset in the C union) and
  drives `data_ptr` to the wrong place.
- **EINTR is recoverable.** A signal interruption during the wait
  does not abort the request -- the wineserver still ran the handler
  and the reply is already in `request_shm`. We fall through to
  copy it out as if SEND_PI had returned 0.

The non-RT case (`prio = 0`) is interesting: the kernel still enqueues
the entry at the bottom of the rbtree and wakes the dispatcher, but it
skips the boost machinery entirely. SCHED_OTHER clients pay a single
ioctl and a single memcpy round-trip -- no `sched_setscheduler`
syscalls, no userspace PI bookkeeping. Even on the cold (non-RT) path
gamma is cheaper than v1.5.

---

## 7. Dispatcher State Machine

The dispatcher pthread is `channel_dispatcher` in
`server/nspa/shmem_channel.c:134`. It is spawned detached with
explicit `SCHED_FIFO` attrs when `NSPA_SRV_RT_PRIO > 0` (lines
261-270) so it is born RT and bypasses any inherited capability
reset-on-fork.

Its loop is:

    for (;;) {
        if (recv2_state == 1) {
            ret = ioctl CHANNEL_RECV2 -> recv;
            if (ret < 0 && errno == ENOTTY) {
                /* Old kernel without 1005 -- fall back permanently. */
                recv2_state = 0;
                continue;
            }
        } else {
            ret = ioctl CHANNEL_RECV  -> recv1;
            recv = lift(recv1, thread_token = 0);
        }
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;                      /* EBADF on close = exit */
        }

        pi_mutex_lock(&global_lock);
        generation = poll_generation;

        if (recv.thread_token)
            thread = (struct thread *)(uintptr_t)recv.thread_token;
        else
            thread = get_thread_from_id((thread_id_t)recv.payload_off);

        if (thread &&
            thread->process->request_channel_fd == channel_fd &&
            thread->request_shm)
        {
            __atomic_thread_fence(__ATOMIC_SEQ_CST);
            read_request_shm(thread, thread->request_shm);
            __atomic_thread_fence(__ATOMIC_SEQ_CST);
        }
        if (thread && !recv.thread_token)
            release_object(thread);

        pi_mutex_unlock(&global_lock);

        ioctl CHANNEL_REPLY(recv.entry_id);    /* atomic wake + boost-drain */

        if (poll_generation != generation)
            force_exit_poll();
    }

Key invariants:

- **`global_lock` is the only lock the dispatcher takes.** No
  per-thread futex, no per-thread state. `read_request_shm` reuses
  the v1.5 handler exactly as-is and is unaware that it is being
  invoked from a channel rather than a per-thread pthread.
- **Sequential consistency fences around `read_request_shm`.** The
  client's ioctl boundary and the kernel-mediated wake are full
  barriers in principle, but the explicit fences make the ordering
  unambiguous when read by a human auditor and cost essentially
  nothing on x86-64.
- **Process-membership check before dispatching.** Line 210 verifies
  `thread->process->request_channel_fd == channel_fd` and
  `thread->request_shm` is set. The channel is per-process so a
  payload that resolves to a thread elsewhere is either client
  tampering or a logic bug; running the handler against the wrong
  process would corrupt unrelated state. This check was added in
  Wine commit `baf088c290f` (gamma audit fix) along with a refcount
  leak fix.
- **`poll_generation` re-arming.** Many request handlers can change
  the wait conditions of other threads (signaling events, releasing
  mutexes). The dispatcher snapshots `poll_generation` before the
  handler and calls `force_exit_poll` after if the handler bumped
  it. The relaxed read outside the lock is intentional -- worst case
  is one missed or one spurious nudge, both benign.

The dispatcher exits on `EBADF` from RECV/RECV2, which fires when
`nspa_shmem_channel_destroy` (`server/nspa/shmem_channel.c:291`)
closes the channel fd during process teardown. Because the pthread
is detached at spawn time, no join is needed.

---

## 8. Priority-Inheritance Semantics

Gamma's PI guarantee is the most important property of the design.
The promise is:

> While a request from sender S (priority P_S) is pending or in flight,
> the dispatcher pthread runs at priority `max(P_dispatcher_base, max
> {P_S' : S' enqueued or being handled})`. There is no observable
> interval where the dispatcher runs at a lower priority while a
> higher-priority sender's entry is queued.

This holds because of three kernel-side properties of
`NTSYNC_TYPE_CHANNEL`:

### 8.1 SEND_PI atomically boosts the dispatcher

When SEND_PI fires, the kernel acquires `channel->lock`, inserts the
entry into the rbtree, and -- under the same spinlock -- compares the
entry's `prio` against the current dispatcher boost level. If the new
entry is higher prio, it calls `apply_event_pi_boost(channel,
entry->prio)` which raises the dispatcher's effective prio via the
underlying `task_struct`. The boost happens before SEND_PI sleeps the
sender, so by the time the sender is blocked the dispatcher is
already running at (at least) the sender's prio.

### 8.2 RECV2 re-boosts to the popped entry's prio

When the dispatcher pops the highest-prio entry, the kernel
recalculates the boost cap from the new queue head and the popped
entry's prio. The dispatcher's boost is "rooted" in the popped entry
for the duration of the handler -- if a lower-prio sender arrives
while the handler runs, it does not raise the dispatcher's prio; if
a higher-prio sender arrives, it does (`apply_event_pi_boost` is
re-entrant in the safe direction).

### 8.3 REPLY drains the popped entry's contribution and re-boosts

`NTSYNC_IOC_CHANNEL_REPLY` is the most subtle ioctl. In one critical
section under `channel->lock` it:

1. removes the entry from the per-channel "in-flight" list and frees
   its slot;
2. completes the entry's `reply_done` (waking the sender);
3. drops the entry's contribution to the dispatcher's PI boost;
4. **re-applies a boost from the new queue head if one exists**.

Step 4 is what closes the gap. Without it, REPLY would return the
dispatcher to base priority for the duration of the next RECV
syscall, during which a high-prio sender that arrived during the
just-completed handler would be stranded behind the dispatcher's
self-rescheduling. Step 4 stitches the boost forward from one entry
to the next inside the same ioctl that wakes the previous sender.
This is the **deferred-boost** mechanism introduced in ntsync patch
1008; gamma was redesigned mid-2026-04 to require it.

### 8.4 Why kernel-atomic PI is strictly better than userspace PI

The legacy v1.5/v2.4 design had three orthogonal hand-rolled pieces:
the boost call itself (`sched_setscheduler`), the bookkeeping cache
(`nspa_dispatcher_current_prio`), and the unboost call. Any of the
three could desync from the others under churn:

| Userspace PI failure mode | Kernel-atomic equivalent |
|---|---|
| Boost lands on wrong tid (TID race) | Impossible: boost is keyed off the channel's `task_struct` pointer, set at dispatcher pthread spawn time |
| Cache says "boosted to 80" but actual policy is RR/40 | Impossible: kernel owns the boost |
| Two senders racing the cache leave dispatcher unboosted | Impossible: `apply_event_pi_boost` is serialised by `channel->lock` |
| Dispatcher exits between cache read and unboost call | N/A: dispatcher exit closes the channel; pending sends fail with EBADF |

The only remaining consideration is interaction with NTSync's other
PI machinery (events, mutexes). Channels share the same `apply_*` /
`drain_*` primitives so a dispatcher that holds an event boost from
one source and a channel boost from another sees correctly summed
priority. We have observed no PI-summing bugs in production since
the channel landed.

---

## 9. Phase B Lock-Drop Integration

Phase B is the second-most important integration consumer of gamma.
It lives in `server/nspa/fd_lockdrop.c` and reshapes how the
dispatcher cooperates with slow filesystem syscalls.

### 9.1 The problem

The wineserver's `create_file` handler ultimately does an
`openat()` syscall against the host filesystem. On a cold-cache
disk read this can take tens of milliseconds. With the v1.5 design
each dispatcher held only one thread's `global_lock` so a slow
`openat` only blocked one client's queue. With gamma there is one
dispatcher per process: a slow `openat` blocks **the entire
process's request queue**.

In a DAW, the audio thread issuing a `NtQueryPerformanceCounter` or
a futex syscall lookup is now stuck behind the GUI thread's
multi-millisecond `LoadLibrary` chain. That is a reliable xrun on
drum-track-load-while-playing.

### 9.2 The Phase B fix

`nspa_openat_lockdrop` (line 47) reorganises the openat critical
section into a "drop, syscall, re-acquire" pattern:

    /* Inside server/fd.c create_file_obj path */
    ...
    {
        struct thread *saved_current = current;
        unsigned int saved_error = saved_current->error;
        struct object *fd_ref = grab_object(fd_object);
        struct object *root_ref = root_object ? grab_object(root_object) : NULL;

        pi_mutex_unlock(&global_lock);

        unix_fd = do_openat(...);

        pi_mutex_lock(&global_lock);

        current = saved_current;
        if (saved_current) saved_current->error = saved_error;
        if (root_ref) release_object(root_ref);
        if (fd_ref)   release_object(fd_ref);
    }

While the lock is dropped the dispatcher's priority is whatever the
kernel last boosted it to (the pending sender's prio). Any other
sender -- including the audio thread -- can have its request popped
by a different mechanism... except there isn't one: the dispatcher
is in the middle of *this* handler. Phase B is therefore narrower
than its name suggests: it lets the **kernel** schedule other
processes' threads (and the host's RT audio path) while we are
blocked in `openat()`, but it does not let other entries in this
process's queue jump ahead.

That sounds like it does nothing useful, but the Linux scheduler's
PI propagation is what makes it work: while we hold `global_lock`
under FIFO 80 (boosted), other RT threads in this process are at
their own FIFO prio (typically 80 for the audio thread), and they
are CPU-blocked behind us only insofar as we hold the CPU. Dropping
the lock lets us *also* be IO-blocked, at which point the audio
thread can preempt us via the kernel scheduler. The dispatcher is
still single-threaded with respect to gamma's own queue.

### 9.3 Save/restore discipline

Several pieces of per-request state are global-ish and must be
preserved across the lock-drop window:

| State | Why it must be saved |
|---|---|
| `current` (per-request thread pointer; `server/request.c:121`) | Another handler running in our unlocked window will overwrite it |
| `current->error` | Belongs to our request; read by the reply path. Must not pick up a stranger's error |
| `fd_object` refcount | Just-allocated by `alloc_fd_object`, only the caller knows it; `grab_object` makes the unlocked window bullet-proof |
| `root_object` refcount | Held by caller's handler; pinning means a concurrent close-handle of root cannot free it during our syscall |
| `errno` | Per-thread, so naturally preserved; we still snapshot to `local_errno` to insulate from libc calls in `pi_mutex_lock` etc. |

The restore order is the inverse: re-lock, restore `current`,
restore `current->error`, drop refs.

### 9.4 Gating

Phase B is **default-on as of 2026-04-26**, gated by
`NSPA_OPENFD_LOCKDROP=0` for A/B testing or as a panic switch.
Originally shipped default-off after a host lockup on the first
validation run; the lockup was eventually traced to the ntsync
driver's `kfree`-under-`raw_spinlock_t` bug (fixed in
`ntsync-patches/1006-ntsync-rt-alloc-hoist.patch`), not Phase B
itself. Re-validated post-1006 with Ableton drum-track-load-while-
playing -- the file-open-burst workload Phase B targets -- with
clean results.

The cached env-var read at lines 67-79 follows the same one-shot
`getenv` pattern as the other gamma gates (`NSPA_DISPATCHER_USE_TOKEN`,
`NSPA_DISABLE_EPOLL`).

---

## 10. Thread-Token Pass-Through (T1/T2/T3)

The thread-token mechanism is a steady-state CPU optimisation
introduced by ntsync patch 1005 and consumed by the dispatcher. It
removes a hash-table lookup on the dispatcher's hot path.

### 10.1 The bottleneck

Pre-token, the dispatcher mapped `payload_off` (which is the
sender's Wine `thread_id_t`) to a `struct thread *` via
`get_thread_from_id`, which walks a hash table under
`thread_id_lock`. Per the perf trace from 2026-04-26 this call was
**~10% of dispatcher CPU** in mixed-load steady state. Eliminating
it is worth the kernel-side complexity.

### 10.2 The protocol

The optimisation is split across three deployment phases:

| Phase | Patch | What changes |
|---|---|---|
| T1 | 1005 kernel patch | Channel object grows a `(tid -> token)` hash; new ioctls `REGISTER_THREAD` / `DEREGISTER_THREAD` / `RECV2` |
| T2 | wineserver plumbing | Wineserver registers `(unix_tid -> (struct thread *))` from `req_init_first_thread` and `req_init_thread`; deregisters from `destroy_thread` |
| T3 | dispatcher consumes token | `channel_dispatcher` calls `RECV2` and uses the token directly, skipping `get_thread_from_id` when it is non-zero |

T1 and T2 ship behaviour-neutral (the kernel stamps tokens and the
wineserver registers them, but nobody reads the token). T3 flips
the dispatcher to consume them and is gated `NSPA_DISPATCHER_USE_TOKEN`
(default on, set to `0` to fall back to the legacy
`get_thread_from_id` lookup for A/B testing).

### 10.3 Lifetime safety

The token is `(struct thread *)` cast to `__u64`. Dereferencing it
in the dispatcher requires the registration to happen **before** any
client send that would resolve to that thread, and the deregistration
to happen **after** the last reply. Both invariants are satisfied
naturally:

- Registration runs inside `req_init_first_thread` /
  `req_init_thread`, both of which are server handlers that complete
  before the client sees the reply that lets it issue further requests.
- Deregistration runs inside `destroy_thread`, which is called after
  the thread's last reference drops. By that point no further sends
  are possible (the thread is gone).

The dispatcher does *not* take a ref on the token-resolved thread
(line 222 in `shmem_channel.c`: `if (!recv.thread_token)
release_object(thread)`). It "borrows" the registration's ref. That
is sound because the registration's ref is held until deregister-
after-last-reply, and the dispatcher is the entity that processes
those replies -- the deregister cannot race with the dispatcher
doing the work.

If a sender's thread happens to be unregistered (very early
pre-init traffic, or a build against an old kernel without 1005),
`recv.thread_token` is zero and the dispatcher falls back to
`get_thread_from_id` + `release_object`. The fallback path is
identical to the pre-token behaviour and is exercised every time
RECV2 returns ENOTTY (line 161-166).

### 10.4 Performance

Per the 2026-04-26 perf run, with T3 enabled:

- `get_ptid_entry` drops from **~10% of dispatcher CPU** to **~0%**.
- No measurable change in per-request latency (the lookup was
  always within a microsecond), but the freed CPU translates
  directly into headroom under load.

---

## 11. NT Semantics Preservation

A redesign of the IPC fast path must not change observable Win32
semantics. Two ordering guarantees must be preserved:

### 11.1 Per-thread request ordering

Win32 guarantees that within a single thread, request `k` is
serialised before request `k+1`. Gamma preserves this trivially
because every request blocks the issuing thread until its reply is
delivered (`SEND_PI` returns only after `REPLY`). Thread T cannot
have request `k+1` outstanding while `k` is still in flight; the
kernel-side rbtree never holds two entries from the same thread
simultaneously.

### 11.2 Cross-thread ordering

Win32 is silent on cross-thread request ordering -- threads race the
wineserver, and whichever request reaches the server first wins. The
upstream socket dispatcher serialises by epoll-readiness order
(roughly arrival order plus kernel scheduling latency). The v1.5
per-thread-pthread design serialised by "first dispatcher pthread to
acquire `global_lock`" (essentially random under contention). Gamma
serialises by **strict sender priority, FIFO inside priority**.

This is strictly stronger than either legacy design. An app that
relied on a specific cross-thread ordering would already be racy on
upstream Wine; gamma's priority-ordered shape is observationally
indistinguishable from a faster machine reaching the upstream
ordering. Notably, gamma never violates a happens-before relationship
the app could observe through synchronisation primitives, because
those primitives also flow through the wineserver and are subject to
the same ordering -- a high-prio thread's signal arrives at the
wineserver in priority order along with everyone else's traffic.

### 11.3 Reply data shape

The reply is byte-identical to the upstream socket reply. Same
`reply_header.error` codes, same payload layout, same handle
allocations. Apps that probe wineserver-internal state (none should,
but Wine's own conformance tests do) see the same values.

---

## 12. Bug History and Audits

Gamma has been validated under sustained stress and through several
KASAN-caught bugs. Tracking them here for completeness.

### 12.1 The 2026-04-26 read-only audit (Wine commit 75a3c534d5f)

A static audit of `server/nspa/shmem_channel.c` found **no latent
correctness bugs** after the `baf088c290f` refcount + process-
membership patch. The handler runs under `global_lock` exactly as
v1.5 did, so handler-internal correctness is inherited from upstream
Wine. The dispatcher loop has no spin-loops, no missing locks, and
no lifetime races. The full audit lives at
`wine/nspa/docs/gamma-dispatcher-audit-and-split-plan.md`.

### 12.2 ntsync patch 1007 -- channel exclusive recv (priority inversion)

Pre-1007, the channel's RECV path used a non-exclusive
`wake_up_interruptible_all` on enqueue, which woke every waiter and
let the kernel pick one. Under multiple-dispatcher scenarios (which
gamma does not actually use, but the test-channel-stress harness does)
the wake-all caused a real priority inversion: a low-prio waiter
could win the race and delay the high-prio waiter behind a sleep.
Patch 1007 narrowed RECV to `wait_event_interruptible_exclusive` +
`wake_up_interruptible`. Audit doc at `wine/nspa/docs/ntsync-rt-audit.md`.

### 12.3 ntsync patch 1008 -- EVENT_SET_PI deferred boost

The pre-1008 `EVENT_SET_PI` boost was applied immediately under
`raw_spinlock_t`, which blocked other RT operations. 1008 deferred
the boost to a per-CPU `pi_work` pool drained outside the spinlock.
Gamma channel REPLY uses the same machinery via
`consume_event_pi_boost` / `apply_event_pi_boost` -- the deferred-
boost queue is what makes "drain previous, re-boost from new head"
atomic-feeling without holding the raw spinlock through the actual
`task_struct` boost call.

### 12.4 ntsync patch 1009 -- channel_entry refcount UAF

KASAN caught a use-after-free on `struct ntsync_channel_entry` in
`test-channel-stress`: a REPLY's `wake_up_all` raced with SEND_PI's
`kfree(entry)`. Same bug class as the rolled-back 1008/1009 wave.
The clean fix was a `refcount_t refs` on `ntsync_channel_entry`,
incremented on enqueue and decremented at REPLY completion and at
sender wakeup; ~15 LOC. Patch 1009 in tree. No production user has
ever observed this bug (gamma has only one dispatcher per channel,
which keeps the path single-consumer); but the channel UAPI is
shared with other potential consumers and the fix is unconditional.

### 12.5 The lockup audit (2026-04-27)

After the ~370M-ops ntsync validation proved the kernel sound, the
lockup investigation moved to wine-NSPA userspace. The audit doc at
`wine/nspa/docs/wine-nspa-lockup-audit-20260427.md` covers F1-F9
wineserver-side findings and MR1-MR8 msg_ring findings; gamma
itself was scored clean. The shipped fixes (MR1 reply-slot ABA, MR2
FUTEX_PRIVATE on shared memfd, MR4 POST wake-loss) are all in
`dlls/win32u/nspa/msg_ring.c` and orthogonal to gamma.

### 12.6 Don't-shotgun-the-audit feedback

A separate behavioural-feedback note
(`feedback_dont_shotgun_audit_into_unfound_bug`) documents that
ntsync patches 1007-1011 originally shipped five patches as "audit
findings" without ever tracing the original `EVENT_SET_PI` slab
UAF; they were rolled back, reduced to the four genuinely-needed
fixes (1006/1007/1008/1009), and re-shipped. The lesson: KASAN /
trace first, audit second. Gamma's design is small enough that
this discipline applies to its own future evolution as well.

---

## 13. Validation and Performance

### 13.1 Functional

- `run-rt-suite native` (4 native tests + 22 PE matrix entries):
  10/10 iterations pass against the canonical post-1006 module
  `srcversion 2C3B9BE710704D550141CAA`.
- 5-minute mixed-load soak across all paths (events
  SET/RESET/PI/PULSE + mutex + sem + chan + wait_all): ~10M ops, 0
  KASAN, 0 leaks; cumulative ~30M ops since the 2026-04-27 session
  start.
- Ableton Live 12 Lite: clean cold-start through plugin scan,
  drum-track-load-while-playing, and 5-min sustained playback.

### 13.2 Performance

| Metric | v1.5/v2.4 | Gamma | Source |
|---|---|---|---|
| Dispatcher pthreads per process | N (~60 for a busy DAW) | 1 | Architectural |
| Sender syscalls per request (RT) | 4-5 (CAS + futex_wake + futex_wait + setscheduler*2) | 1 (SEND_PI) | `dlls/ntdll/unix/server.c:403` |
| Dispatcher syscalls per request | 1-2 (futex_wait + sometimes setscheduler) | 2 (RECV2 + REPLY) | `server/nspa/shmem_channel.c:160,231` |
| `get_ptid_entry` dispatcher CPU | ~10% | ~0% (T3 enabled) | perf 2026-04-26 |
| TID-race PI window | Real (TID-read vs setscheduler) | Closed (kernel-atomic) | Architectural |
| Priority gaps between adjacent requests | Possible (between unboost and next boost) | Closed (REPLY re-boosts atomically) | ntsync 1008 |

The dispatcher syscall count went **up** (from ~1 futex to 2
ioctls) but each ioctl does substantially more work atomically and
the userspace path has no userspace PI bookkeeping at all. End-to-
end latency for a typical small request (`get_thread_info`,
`get_handle_info`) is comparable.

The deeper win is **tail latency under mixed load**. With v1.5, a
high-prio audio-thread request could be queued behind a GUI-thread
request whose dispatcher pthread had not yet been scheduled. With
gamma, the kernel rbtree guarantees the audio thread's entry is
popped first, regardless of arrival order. Empirically this shows
up as fewer xruns under burst workloads (Ableton drum-track-load-
while-playing), which is exactly the workload Phase B targets.

### 13.3 Configuration validated for production

For Ableton run-3 (2026-04-27):

- Module: `A250A77651C8D5DAB719FE2` (loaded on prod kernel
  6.19.11-rt1-1-nspa)
- `NSPA_RT_POLICY=FF` (in `/etc/environment`)
- `NSPA_ENABLE_PAINT_CACHE` unset -> default OFF (B1.0 reverted)
- `NSPA_OPENFD_LOCKDROP` unset -> default ON (Phase B post-1006)
- `NSPA_DISPATCHER_USE_TOKEN` unset -> default ON (gamma T3)

---

## 14. References

### 14.1 Wine-NSPA source

| File | Lines | Role |
|---|---|---|
| `wine/dlls/ntdll/unix/server.c` | 311-436 | Sender shim `nspa_send_request_channel` + UAPI fallback |
| `wine/dlls/ntdll/unix/server.c` | 442-461 | `server_call_unlocked` gating logic |
| `wine/server/nspa/shmem_channel.c` | 60-107 | UAPI fallback for pre-1004 / pre-1005 kernel headers |
| `wine/server/nspa/shmem_channel.c` | 134-242 | `channel_dispatcher` pthread loop |
| `wine/server/nspa/shmem_channel.c` | 244-289 | `nspa_shmem_channel_init` -- create + spawn dispatcher |
| `wine/server/nspa/shmem_channel.c` | 291-299 | `nspa_shmem_channel_destroy` -- close fd, dispatcher exits via EBADF |
| `wine/server/nspa/shmem_channel.c` | 310-340 | T2 thread-token register/deregister |
| `wine/server/nspa/shmem_channel.h` | 1-48 | Public header |
| `wine/server/nspa/fd_lockdrop.c` | 47-125 | Phase B `nspa_openat_lockdrop` -- lock-drop integration |
| `wine/nspa/docs/gamma-dispatcher-audit-and-split-plan.md` | -- | Audit + future router/handler split plan |
| `wine/nspa/docs/wine-nspa-lockup-audit-20260427.md` | -- | F1-F9 + MR1-MR8 lockup-investigation findings |
| `wine/nspa/docs/ntsync-rt-audit.md` | -- | ntsync 1007/1008/1009 audit |

### 14.2 Kernel source

| File | Lines | Role |
|---|---|---|
| `drivers/misc/ntsync.c` | 1190-1494 | Channel object: rbtree, send/recv/reply, registration |
| `ntsync-patches/1004-ntsync-channel.patch` | -- | Channel object + core ioctls |
| `ntsync-patches/1005-ntsync-channel-thread-token.patch` | -- | RECV2 + REGISTER_THREAD + DEREGISTER_THREAD |
| `ntsync-patches/1006-ntsync-rt-alloc-hoist.patch` | -- | kfree-under-raw_spinlock fix; unblocked Phase B default-on |
| `ntsync-patches/1007-ntsync-channel-exclusive-recv.patch` | -- | Channel exclusive recv -- priority inversion fix |
| `ntsync-patches/1008-ntsync-event-set-pi-deferred-boost.patch` | -- | Deferred boost machinery (consumed by REPLY) |
| `ntsync-patches/1009-ntsync-channel-entry-refcount.patch` | -- | refcount_t on `ntsync_channel_entry` (KASAN UAF fix) |

### 14.3 Memory / handoff documents

| Doc | Topic |
|---|---|
| `project_gamma_dispatcher_audit_and_split_plan.md` | 2026-04-26 audit + T1/T2/T3 + router/handler split plan |
| `project_msg_ring_v2_mr1_mr2_mr4_shipped_20260427.md` | MR1/MR2/MR4 + Ableton run-3 config |
| `project_ntsync_session_20260427_results.md` | 30M-ops cumulative validation, 4 bugs fixed |
| `project_ntsync_kfree_under_raw_spinlock.md` | 1006 alloc-hoist (unblocked Phase B default-on) |
| `feedback_dont_shotgun_audit_into_unfound_bug.md` | KASAN-first / audit-second discipline |

### 14.4 Predecessor docs

The published `shmem-ipc.gen.html` describes v1.5 (per-thread
dispatcher) and v2.4 (cached-CAS + manual prio cache) and is
superseded by this document. It is retained for historical
reference and for the comparison diagrams. The CS-PI design
(`cs-pi.gen.html`) is orthogonal to gamma and continues to apply
unchanged: gamma improves the IPC path; CS-PI improves the in-
process critical-section path; they coexist without interaction.

---
