# Wine-NSPA -- Shmem IPC Architecture (LEGACY -- superseded by gamma channel dispatcher)

> **Status: SUPERSEDED 2026-04-26.**
>
> This document describes the v1.5 / v2.4 per-thread shmem-pthread dispatcher
> with userspace `sched_setscheduler` PI boost. That architecture has been
> replaced by the **gamma channel dispatcher**: a single per-process kernel-
> mediated channel using NTSync `NTSYNC_IOC_CHANNEL_*` ioctls, with kernel-
> atomic priority inheritance.
>
> See: [Gamma Channel Dispatcher](gamma-channel-dispatcher.gen.html)
>
> This page is retained for historical context.

---

Wine-NSPA 11.6 | Kernel 6.19.11-rt1-1-nspa (PREEMPT_RT) | 2026-04-15
Author: Jordan Johnston

## Table of Contents

1. [Overview](#1-overview)
2. [Upstream vs NSPA Comparison](#2-upstream-vs-nspa-comparison)
3. [Dispatcher Architecture](#3-dispatcher-architecture)
4. [PI Boost Protocol (v2.5)](#4-pi-boost-protocol-v25)
5. [Global Lock PI](#5-global-lock-pi)
6. [Appendix: Rejected FUTEX_LOCK_PI Redesign](#6-appendix-rejected-futex_lock_pi-redesign)

---

## 1. Overview

Upstream Wine uses a single-threaded wineserver that communicates with client processes over Unix domain sockets. Every `SERVER_START_REQ` / `SERVER_END_REQ` pair requires a full round-trip: client writes request to socket, wineserver's epoll loop wakes, dispatches, writes reply, client reads reply.

Wine-NSPA v1.5 (Torge Matthies forward-port) adds **per-thread shared memory** between each client thread and the wineserver. Instead of socket I/O, requests and replies are written to a shared page, and futexes signal readiness. The wineserver spawns a **per-client dispatcher pthread** that watches each thread's futex and dispatches requests under `global_lock`.

This eliminates the socket round-trip but introduces two new challenges:
- The wineserver is now multi-threaded (dispatchers + main epoll loop), requiring `global_lock` serialization
- RT client threads can be blocked waiting for a reply from a normal-priority dispatcher, creating priority inversion

---

## 2. Upstream vs NSPA Comparison

<div class="diagram-container">
<svg width="100%" viewBox="0 0 900 500" xmlns="http://www.w3.org/2000/svg">
  <style>
    .shm-box { fill: #24283b; stroke: #9aa5ce; stroke-width: 1.5; rx: 6; }
    .shm-new { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 6; }
    .shm-bad { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.5; rx: 6; }
    .shm-pi { fill: #1a1a2a; stroke: #7aa2f7; stroke-width: 1.5; rx: 6; }
    .shm-lbl { fill: #c0caf5; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .shm-lbl-a { fill: #7aa2f7; font-size: 12px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .shm-lbl-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .shm-lbl-r { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .shm-lbl-y { fill: #e0af68; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .shm-lbl-m { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .shm-lbl-c { fill: #7dcfff; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .shm-div { stroke: #3b4261; stroke-width: 1; stroke-dasharray: 8,4; }
  </style>

  <!-- Headers -->
  <text x="210" y="24" class="shm-lbl-a" text-anchor="middle">Upstream Wine (socket IPC)</text>
  <text x="680" y="24" class="shm-lbl-a" text-anchor="middle">Wine-NSPA (shmem IPC + PI)</text>
  <line x1="440" y1="8" x2="440" y2="490" class="shm-div"/>

  <!-- LEFT: Upstream -->
  <rect x="30" y="45" width="180" height="30" rx="6" class="shm-box"/>
  <text x="120" y="65" text-anchor="middle" class="shm-lbl">Client: SERVER_START_REQ</text>

  <line x1="120" y1="75" x2="120" y2="95" stroke="#9aa5ce" stroke-width="1"/>

  <rect x="30" y="97" width="180" height="30" rx="6" class="shm-bad"/>
  <text x="120" y="117" text-anchor="middle" class="shm-lbl-r">write() to Unix socket</text>

  <line x1="120" y1="127" x2="310" y2="155" stroke="#f7768e" stroke-width="1.5"/>

  <rect x="230" y="150" width="190" height="55" rx="6" class="shm-bad"/>
  <text x="325" y="168" text-anchor="middle" class="shm-lbl-r">Wineserver (single-threaded)</text>
  <text x="325" y="183" text-anchor="middle" class="shm-lbl-m">epoll_wait() -> fd ready</text>
  <text x="325" y="198" text-anchor="middle" class="shm-lbl-m">dispatch request (no lock needed)</text>

  <line x1="310" y1="205" x2="120" y2="235" stroke="#f7768e" stroke-width="1.5"/>

  <rect x="30" y="230" width="180" height="30" rx="6" class="shm-bad"/>
  <text x="120" y="250" text-anchor="middle" class="shm-lbl-r">read() reply from socket</text>

  <line x1="120" y1="260" x2="120" y2="280" stroke="#9aa5ce" stroke-width="1"/>

  <rect x="30" y="282" width="180" height="30" rx="6" class="shm-box"/>
  <text x="120" y="302" text-anchor="middle" class="shm-lbl">Client: SERVER_END_REQ</text>

  <!-- Cost box -->
  <rect x="30" y="340" width="390" height="70" rx="6" fill="#24283b" stroke="#3b4261" stroke-width="1"/>
  <text x="225" y="360" text-anchor="middle" class="shm-lbl-r">Cost per server request:</text>
  <text x="50" y="378" class="shm-lbl-m">2 socket I/O syscalls (write + read)</text>
  <text x="50" y="393" class="shm-lbl-m">1 epoll wakeup + context switch to wineserver</text>

  <rect x="30" y="430" width="390" height="50" rx="6" fill="#2a1a1a" stroke="#f7768e" stroke-width="1"/>
  <text x="225" y="450" text-anchor="middle" class="shm-lbl-r">No multi-threading, no PI needed</text>
  <text x="225" y="468" text-anchor="middle" class="shm-lbl-m">But: every request pays full socket round-trip</text>

  <!-- RIGHT: NSPA -->
  <rect x="490" y="45" width="180" height="30" rx="6" class="shm-new"/>
  <text x="580" y="65" text-anchor="middle" class="shm-lbl-g">Client: write to shmem page</text>

  <line x1="580" y1="75" x2="580" y2="95" stroke="#9ece6a" stroke-width="1.5"/>

  <rect x="490" y="97" width="180" height="30" rx="6" class="shm-new"/>
  <text x="580" y="117" text-anchor="middle" class="shm-lbl-g">CAS futex 0->1, wake</text>

  <line x1="580" y1="127" x2="580" y2="147" stroke="#9ece6a" stroke-width="1.5"/>

  <rect x="480" y="149" width="200" height="30" rx="6" class="shm-pi"/>
  <text x="580" y="169" text-anchor="middle" class="shm-lbl-c">PI boost dispatcher (v2.5)</text>

  <line x1="580" y1="179" x2="770" y2="205" stroke="#9ece6a" stroke-width="1.5"/>

  <!-- Dispatcher -->
  <rect x="700" y="200" width="180" height="75" rx="6" class="shm-new"/>
  <text x="790" y="218" text-anchor="middle" class="shm-lbl-g">Dispatcher pthread</text>
  <text x="790" y="233" text-anchor="middle" class="shm-lbl-m">(boosted to client's prio)</text>
  <text x="790" y="248" text-anchor="middle" class="shm-lbl-m">global_lock.lock() (PI)</text>
  <text x="790" y="263" text-anchor="middle" class="shm-lbl-m">dispatch + write reply</text>

  <line x1="770" y1="275" x2="580" y2="300" stroke="#9ece6a" stroke-width="1.5"/>

  <rect x="490" y="295" width="180" height="30" rx="6" class="shm-new"/>
  <text x="580" y="315" text-anchor="middle" class="shm-lbl-g">Client: read from shmem</text>

  <line x1="580" y1="325" x2="580" y2="345" stroke="#9ece6a" stroke-width="1.5"/>

  <rect x="480" y="347" width="200" height="30" rx="6" class="shm-pi"/>
  <text x="580" y="367" text-anchor="middle" class="shm-lbl-c">PI unboost dispatcher</text>

  <!-- Cost box -->
  <rect x="470" y="400" width="410" height="70" rx="6" fill="#1a2a1a" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="675" y="420" text-anchor="middle" class="shm-lbl-g">Cost per server request:</text>
  <text x="490" y="438" class="shm-lbl-m">0 socket syscalls (shmem is mapped, no I/O)</text>
  <text x="490" y="453" class="shm-lbl-m">1 futex wake + 2 sched_setscheduler (PI boost/unboost)</text>
</svg>
</div>

| Aspect | Upstream Wine | Wine-NSPA Shmem |
| --- | --- | --- |
| IPC mechanism | Unix socket write/read | Shared memory page + futex |
| Server threading | Single-threaded epoll loop | Multi-threaded: epoll + per-client dispatchers |
| Serialization | None (single thread) | `global_lock` (PI-aware `pi_mutex_t`) |
| Syscalls per request | 2 socket I/O + epoll wake | 1 futex wake + 2 sched_setscheduler |
| Priority inversion | Not applicable | Mitigated by PI boost (v2.5) |
| Context switches | Client -> wineserver -> client | Client -> dispatcher (same process) |

---

## 3. Dispatcher Architecture

Each client thread that connects to the wineserver gets a dedicated **dispatcher pthread** on the server side. The dispatcher watches the thread's shmem futex and processes requests under `global_lock`.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 860 380" xmlns="http://www.w3.org/2000/svg">
  <style>
    .d-box { fill: #24283b; stroke: #9aa5ce; stroke-width: 1.5; rx: 6; }
    .d-new { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 6; }
    .d-pi { fill: #1a1a2a; stroke: #7aa2f7; stroke-width: 1.5; rx: 6; }
    .d-lbl { fill: #c0caf5; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .d-lbl-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .d-lbl-y { fill: #e0af68; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .d-lbl-m { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .d-lbl-c { fill: #7dcfff; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
  </style>

  <text x="430" y="22" class="d-lbl-y" text-anchor="middle">Wineserver Process -- Per-Client Dispatcher Model</text>

  <!-- Main epoll loop -->
  <rect x="20" y="45" width="200" height="120" rx="6" class="d-box"/>
  <text x="120" y="65" text-anchor="middle" class="d-lbl-y">Main Epoll Loop</text>
  <text x="120" y="82" text-anchor="middle" class="d-lbl-m">epoll_pwait2()</text>
  <text x="120" y="97" text-anchor="middle" class="d-lbl-m">fd events (file, socket)</text>
  <text x="120" y="112" text-anchor="middle" class="d-lbl-m">async lifecycle mgmt</text>
  <text x="120" y="127" text-anchor="middle" class="d-lbl-c">global_lock.lock()</text>
  <text x="120" y="142" text-anchor="middle" class="d-lbl-m">for each event</text>

  <!-- Dispatcher 1 -->
  <rect x="280" y="45" width="250" height="90" rx="6" class="d-new"/>
  <text x="405" y="65" text-anchor="middle" class="d-lbl-g">Dispatcher pthread (thread 1)</text>
  <text x="405" y="82" text-anchor="middle" class="d-lbl-m">futex_wait(shmem-&gt;futex, 0)</text>
  <text x="405" y="97" text-anchor="middle" class="d-lbl-c">wakes -&gt; global_lock.lock()</text>
  <text x="405" y="112" text-anchor="middle" class="d-lbl-m">dispatch(req) -&gt; write reply</text>
  <text x="405" y="127" text-anchor="middle" class="d-lbl-m">CAS futex 1-&gt;0, wake client</text>

  <!-- Dispatcher 2 -->
  <rect x="280" y="155" width="250" height="40" rx="6" class="d-new"/>
  <text x="405" y="175" text-anchor="middle" class="d-lbl-g">Dispatcher pthread (thread 2)</text>
  <text x="405" y="188" text-anchor="middle" class="d-lbl-m">same pattern, different shmem page</text>

  <!-- Dispatcher N -->
  <rect x="280" y="215" width="250" height="40" rx="6" class="d-new"/>
  <text x="405" y="235" text-anchor="middle" class="d-lbl-g">Dispatcher pthread (thread N)</text>
  <text x="405" y="248" text-anchor="middle" class="d-lbl-m">1 dispatcher per client thread</text>

  <!-- global_lock -->
  <rect x="590" y="45" width="250" height="100" rx="6" class="d-pi"/>
  <text x="715" y="65" text-anchor="middle" class="d-lbl-c">global_lock (pi_mutex_t)</text>
  <text x="715" y="85" text-anchor="middle" class="d-lbl-m">Serializes all server state access</text>
  <text x="715" y="100" text-anchor="middle" class="d-lbl-m">FUTEX_LOCK_PI -&gt; kernel rt_mutex</text>
  <text x="715" y="115" text-anchor="middle" class="d-lbl-g">PI: highest-prio dispatcher wins</text>
  <text x="715" y="130" text-anchor="middle" class="d-lbl-m">Holder boosted if contended</text>

  <!-- Client processes -->
  <rect x="20" y="280" width="820" height="85" rx="6" fill="none" stroke="#3b4261" stroke-width="1" stroke-dasharray="5,3"/>
  <text x="430" y="300" text-anchor="middle" class="d-lbl-y">Client Processes</text>

  <rect x="40" y="310" width="160" height="40" rx="6" class="d-box"/>
  <text x="120" y="327" text-anchor="middle" class="d-lbl">Client thread 1</text>
  <text x="120" y="342" text-anchor="middle" class="d-lbl-m">shmem page + futex</text>

  <rect x="230" y="310" width="160" height="40" rx="6" class="d-box"/>
  <text x="310" y="327" text-anchor="middle" class="d-lbl">Client thread 2</text>
  <text x="310" y="342" text-anchor="middle" class="d-lbl-m">shmem page + futex</text>

  <rect x="420" y="310" width="160" height="40" rx="6" class="d-box"/>
  <text x="500" y="327" text-anchor="middle" class="d-lbl">Client thread N</text>
  <text x="500" y="342" text-anchor="middle" class="d-lbl-m">shmem page + futex</text>

  <rect x="620" y="310" width="200" height="40" rx="6" class="d-pi"/>
  <text x="720" y="327" text-anchor="middle" class="d-lbl-c">RT thread (SCHED_FIFO)</text>
  <text x="720" y="342" text-anchor="middle" class="d-lbl-g">PI boosts its dispatcher</text>

  <!-- Arrows from clients to dispatchers -->
  <path d="M120 310 L120 220 L320 220 L320 135" stroke="#9ece6a" stroke-width="1" fill="none"/>
  <line x1="310" y1="310" x2="380" y2="195" stroke="#9ece6a" stroke-width="1"/>
  <line x1="500" y1="310" x2="430" y2="255" stroke="#9ece6a" stroke-width="1"/>
</svg>
</div>

### Dispatcher Lifecycle

1. Client thread calls `wine_server_call()` with a request
2. Request data written to the thread's shared memory page
3. Client CAS's the shmem futex from 0 -> 1, then `futex_wake()`
4. Client PI-boosts the dispatcher (v2.5 protocol)
5. Client `futex_wait(futex, 1)` -- sleeps until reply
6. Dispatcher wakes, acquires `global_lock`, dispatches the request
7. Dispatcher writes reply to shmem, CAS futex 1 -> 0, `futex_wake()`
8. Client wakes, reads reply, PI-unboosts the dispatcher

---

## 4. PI Boost Protocol (v2.5)

When an RT client thread (SCHED_FIFO) sends a request, it must boost the dispatcher pthread so the dispatcher runs at sufficient priority to process the request promptly. Without boosting, CFS could delay the dispatcher behind dozens of other normal-priority threads.

### Protocol

    Client (SCHED_FIFO:80):
      1. Write request to shmem
      2. CAS futex 0->1, futex_wake (wake dispatcher)
      3. Read dispatcher TID from shmem (atomic load, cached by dispatcher)
      4. sched_getscheduler(TID) + sched_getparam(TID)  -- save original
      5. sched_setscheduler(TID, SCHED_FIFO, client_prio) -- BOOST
      6. futex_wait(futex, 1) -- sleep
    Dispatcher (now boosted):
      7. Wakes at boosted priority
      8. global_lock.lock() (PI mutex -- if contended, holder also boosted)
      9. Dispatch request, write reply
      10. CAS futex 1->0, futex_wake (wake client)
      11. global_lock.unlock()
    Client (wakes):
      12. Read reply
      13. sched_setscheduler(TID, original_policy, original_prio) -- UNBOOST

### Syscall Cost: v2.4 vs v2.5

<div class="diagram-container">
<svg width="100%" viewBox="0 0 780 280" xmlns="http://www.w3.org/2000/svg">
  <!-- v2.4 timeline -->
  <rect x="20" y="10" width="350" height="28" rx="6" fill="#24283b" stroke="#f7768e" stroke-width="1.5"/>
  <text x="195" y="29" text-anchor="middle" fill="#f7768e" font-size="11" font-weight="bold">v2.4: 4 syscalls per RT request</text>

  <rect x="30" y="50" width="150" height="22" rx="6" fill="#24283b" stroke="#8c92b3" stroke-width="1" stroke-dasharray="4,2"/>
  <text x="105" y="65" text-anchor="middle" fill="#c0caf5" font-size="9" text-decoration="line-through">sched_getscheduler()</text>
  <rect x="190" y="50" width="150" height="22" rx="6" fill="#24283b" stroke="#8c92b3" stroke-width="1" stroke-dasharray="4,2"/>
  <text x="265" y="65" text-anchor="middle" fill="#c0caf5" font-size="9" text-decoration="line-through">sched_getparam()</text>
  <text x="345" y="65" fill="#f7768e" font-size="8">&lt;-- eliminated by v2.5</text>
  <rect x="30" y="80" width="150" height="22" rx="6" fill="#24283b" stroke="#e0af68" stroke-width="1"/>
  <text x="105" y="95" text-anchor="middle" fill="#e0af68" font-size="9">sched_setscheduler(BOOST)</text>
  <text x="195" y="95" text-anchor="middle" fill="#c0caf5" font-size="8">&lt;-- dispatch --&gt;</text>
  <rect x="220" y="80" width="150" height="22" rx="6" fill="#24283b" stroke="#e0af68" stroke-width="1"/>
  <text x="295" y="95" text-anchor="middle" fill="#e0af68" font-size="9">sched_setscheduler(UNBOOST)</text>
  <text x="195" y="120" text-anchor="middle" fill="#f7768e" font-size="9">~2-4us overhead (4 sched syscalls)</text>

  <!-- v2.5 timeline -->
  <rect x="410" y="10" width="350" height="28" rx="6" fill="#24283b" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="585" y="29" text-anchor="middle" fill="#9ece6a" font-size="11" font-weight="bold">v2.5: 2 syscalls per RT request</text>

  <rect x="420" y="50" width="150" height="22" rx="6" fill="#1a3a1a" stroke="#9ece6a" stroke-width="1"/>
  <text x="495" y="65" text-anchor="middle" fill="#9ece6a" font-size="9">sched_setscheduler(BOOST)</text>
  <text x="585" y="65" text-anchor="middle" fill="#c0caf5" font-size="8">&lt;-- dispatch --&gt;</text>
  <rect x="610" y="50" width="150" height="22" rx="6" fill="#1a3a1a" stroke="#9ece6a" stroke-width="1"/>
  <text x="685" y="65" text-anchor="middle" fill="#9ece6a" font-size="9">sched_setscheduler(UNBOOST)</text>

  <rect x="420" y="82" width="340" height="30" rx="6" fill="#24283b" stroke="#3b4261" stroke-width="1"/>
  <text x="590" y="96" text-anchor="middle" fill="#c0caf5" font-size="9">TLS cache: nspa_rt_cached_policy + nspa_rt_cached_prio</text>
  <text x="590" y="108" text-anchor="middle" fill="#c0caf5" font-size="8">Set once at thread RT init, read on every boost -- eliminates get* calls</text>
  <text x="585" y="130" text-anchor="middle" fill="#9ece6a" font-size="9">~1-2us overhead (2 sched syscalls)</text>

  <!-- Why not FUTEX_LOCK_PI -->
  <rect x="20" y="150" width="740" height="65" rx="6" fill="#24283b" stroke="#3b4261" stroke-width="1"/>
  <text x="390" y="172" text-anchor="middle" fill="#e0af68" font-size="10" font-weight="bold">Why not FUTEX_LOCK_PI? (attempted and REJECTED)</text>
  <text x="390" y="192" text-anchor="middle" fill="#c0caf5" font-size="9">Dispatcher sleeps on a notify futex, not the PI futex itself. A separate PI word requires</text>
  <text x="390" y="206" text-anchor="middle" fill="#c0caf5" font-size="9">unlock + re-acquire between dispatches. Under SMP contention, this causes deadlocks</text>

  <!-- FUTEX_LOCK_PI deadlock scenario -->
  <rect x="20" y="225" width="740" height="45" rx="6" fill="#24283b" stroke="#f7768e" stroke-width="1.5"/>
  <text x="390" y="244" text-anchor="middle" fill="#c0caf5" font-size="9">Deadlock: client A holds PI lock, client B boosts dispatcher, dispatcher blocks on A's PI lock</text>
  <text x="390" y="260" text-anchor="middle" fill="#c0caf5" font-size="8">Manual boost avoids client↔dispatcher lock dependencies entirely</text>
</svg>
</div>

2 syscalls per RT request: `sched_setscheduler` (boost) + `sched_setscheduler` (unboost). Down from 4 in v2.4 (v2.5 caches the scheduler state, eliminating `sched_getscheduler` + `sched_getparam`).

### Race Window

Between steps 3 and 5, another client's unboost could lower the dispatcher's priority. The window is small (~100ns on modern hardware) and the consequence is a one-request delay (the next request re-boosts). Accepted as a practical trade-off vs kernel-managed PI (see appendix).

---

## 5. Global Lock PI

`server/fd.c:global_lock` serializes all wineserver state access between the main epoll loop and the per-client dispatcher pthreads. Converted from `pthread_mutex_t` to `pi_mutex_t` (FUTEX_LOCK_PI), providing kernel-managed priority inheritance.

When a boosted dispatcher (SCHED_FIFO:80) contends with a normal-priority thread holding `global_lock`, the kernel's rt_mutex PI chain automatically boosts the holder. This is transitive: if the holder is itself blocked on another PI mutex, the boost propagates through the chain.

| Files Changed | What |
| --- | --- |
| `server/fd.c` | `pthread_mutex_t global_lock` -> `pi_mutex_t global_lock` |
| `server/file.h` | Declaration + `#include <rtpi.h>` |
| `server/thread.c` | All lock/unlock calls updated |

---

## 6. Appendix: Rejected FUTEX_LOCK_PI Redesign

**Status: Implemented and tested 2026-04-15. REJECTED -- deadlocks on SMP.**

### Concept

Replace the manual `sched_setscheduler` PI boost with `FUTEX_LOCK_PI` on a shared pi_lock. The dispatcher would hold pi_lock while idle; the client's `futex_lock_pi` would atomically boost the dispatcher through the kernel's rt_mutex. Zero race window, zero `sched_*` syscalls.

### Why It Failed

The dispatcher must unlock pi_lock (to wake the client) then re-acquire it (for the next request). On SMP, if the dispatcher is faster than the client:

1. Dispatcher `UNLOCK_PI` -- no waiters (client hasn't blocked yet), futex cleared to 0
2. Dispatcher `LOCK_PI` -- re-acquires immediately (futex was 0)
3. Dispatcher `WAIT(notify)` -- sleeps, holding pi_lock
4. Client `LOCK_PI` -- blocks (dispatcher holds it)
5. **Deadlock:** client waits for pi_lock, dispatcher waits for notify

Root cause: `FUTEX_LOCK_PI` can't serve as both reply notification and PI mechanism. The unlock/re-acquire has a window where ownership transfer to the client isn't guaranteed.

### Conclusion

The v2.5 manual boost (2 syscalls per RT request) remains correct. A kernel-managed solution would require a combined notify+PI atomic operation that doesn't exist in the Linux futex API.
