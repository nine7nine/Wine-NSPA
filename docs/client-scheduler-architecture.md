# Wine-NSPA -- Client Scheduler Architecture

This page documents the client-side scheduler hosts and the current consumers
routed through them.

## Table of Contents

1. [Overview](#1-overview)
2. [Thread model](#2-thread-model)
3. [API surface](#3-api-surface)
4. [Current consumers](#4-current-consumers)
5. [Validation and current controls](#5-validation-and-current-controls)
6. [Relationship to the rest of Wine-NSPA](#6-relationship-to-the-rest-of-wine-nspa)
7. [References](#7-references)

---

## 1. Overview

The architectural prerequisite was upstream spawn-main: the Unix bootstrap
thread no longer becomes the application's Win32 main thread. Instead, the
bootstrap thread parks in `sched_run()` and becomes a per-process scheduler
host, while the app main thread is created separately and continues through
normal Win32 startup.

On top of that split, Wine-NSPA uses a client-side scheduler substrate:

- one always-present default-class sched thread, named `wine-sched`
- one lazy RT-class sched thread, named `wine-sched-rt`, created only when an
  RT consumer actually registers work and `NSPA_RT_PRIO` is configured
- `ntdll_sched_*` entry points for poll, timer, async, synchronous call, and
  cancel

The purpose is not to replace wineserver dispatch. Gamma remains
wineserver-side. This scheduler is the client-process sidecar used to host
small helper loops and timer dispatchers without adding more dedicated helper
threads per subsystem.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .sc-bg { fill: #1a1b26; }
    .sc-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.5; rx: 8; }
    .sc-main { fill: #1a2235; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .sc-sched { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 8; }
    .sc-rt { fill: #2a1f35; stroke: #bb9af7; stroke-width: 2; rx: 8; }
    .sc-note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .sc-t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .sc-s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .sc-h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .sc-g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .sc-v { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
    .sc-y { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .sc-line-g { stroke: #9ece6a; stroke-width: 1.5; fill: none; }
    .sc-line-v { stroke: #bb9af7; stroke-width: 1.5; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="420" class="sc-bg"/>
  <text x="480" y="28" text-anchor="middle" class="sc-h">Per-process thread model after spawn-main</text>

  <rect x="50" y="70" width="860" height="290" class="sc-box"/>
  <text x="78" y="96" class="sc-t">Wine process</text>
  <text x="78" y="112" class="sc-s">spawn-main separates the bootstrap scheduler host from the Win32 app main thread</text>

  <rect x="90" y="150" width="220" height="100" class="sc-main"/>
  <text x="200" y="178" text-anchor="middle" class="sc-t">application main thread</text>
  <text x="200" y="200" text-anchor="middle" class="sc-s">runs Win32 startup and normal user code</text>
  <text x="200" y="218" text-anchor="middle" class="sc-s">no longer doubles as the Unix bootstrap loop</text>

  <rect x="370" y="138" width="220" height="124" class="sc-sched"/>
  <text x="480" y="166" text-anchor="middle" class="sc-g">`wine-sched`</text>
  <text x="480" y="188" text-anchor="middle" class="sc-s">default-class scheduler thread</text>
  <text x="480" y="206" text-anchor="middle" class="sc-s">SCHED_OTHER by design</text>
  <text x="480" y="224" text-anchor="middle" class="sc-s">hosts poll / timer / async / call work</text>
  <text x="480" y="242" text-anchor="middle" class="sc-s">always present after process bootstrap</text>

  <rect x="650" y="150" width="220" height="100" class="sc-rt"/>
  <text x="760" y="178" text-anchor="middle" class="sc-v">`wine-sched-rt`</text>
  <text x="760" y="200" text-anchor="middle" class="sc-s">lazy RT-class scheduler thread</text>
  <text x="760" y="218" text-anchor="middle" class="sc-s">spawned on first RT-class registration</text>
  <text x="760" y="236" text-anchor="middle" class="sc-s">SCHED_FIFO at `NSPA_RT_PRIO - 1`</text>

  <line x1="310" y1="200" x2="370" y2="200" class="sc-line-g"/>
  <text x="340" y="188" text-anchor="middle" class="sc-g">spawn-main split</text>

  <line x1="590" y1="200" x2="650" y2="200" class="sc-line-v"/>
  <text x="620" y="188" text-anchor="middle" class="sc-v">RT-class only</text>

  <rect x="150" y="286" width="660" height="58" class="sc-note"/>
  <text x="480" y="314" text-anchor="middle" class="sc-y">Load-bearing invariant</text>
  <text x="480" y="330" text-anchor="middle" class="sc-s">the sched host stays separate from the app main thread</text>
  <text x="480" y="344" text-anchor="middle" class="sc-s">gamma and wineserver remain separate server-side machinery</text>
</svg>
</div>

---

## 2. Thread model

The thread model has two classes.

| Class | Thread name | Spawn policy | Scheduler policy | Purpose |
|---|---|---|---|---|
| Default | `wine-sched` | always present after spawn-main | `SCHED_OTHER` | general poll/timer/async/call hosting |
| RT | `wine-sched-rt` | lazy, first RT-class registration only | `SCHED_FIFO` at `NSPA_RT_PRIO - 1` | precision timer consumers that used to own dedicated RT helper threads |

Two details matter:

- The default sched thread is intentionally pinned to `SCHED_OTHER`. It is a
  general callback host and must not become an RT thread accidentally.
- The RT sched thread is optional. If RT promotion is unavailable, RT-class
  registrations return `STATUS_NOT_SUPPORTED` and the caller falls back to its
  legacy dedicated-thread path.

The scheduler implementation itself uses:

- PI mutexes around each sched-instance user list
- a non-blocking wake pipe so producers never deadlock on a full signal fd
- generation-stamped handles for ABA-safe cancel
- self-call detection in `ntdll_sched_call()` so the sched thread does not
  deadlock by waiting for work it must dispatch itself

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .sm-bg { fill: #1a1b26; }
    .sm-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.5; rx: 8; }
    .sm-api { fill: #1a2235; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .sm-inst { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 8; }
    .sm-rt { fill: #2a1f35; stroke: #bb9af7; stroke-width: 2; rx: 8; }
    .sm-note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .sm-t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .sm-s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .sm-h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .sm-g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .sm-v { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
    .sm-y { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .sm-line-g { stroke: #9ece6a; stroke-width: 1.5; fill: none; }
    .sm-line-v { stroke: #bb9af7; stroke-width: 1.5; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="420" class="sm-bg"/>
  <text x="480" y="28" text-anchor="middle" class="sm-h">`ntdll_sched` routing model</text>

  <rect x="60" y="80" width="220" height="236" class="sm-api"/>
  <text x="170" y="108" text-anchor="middle" class="sm-t">public entry points</text>
  <text x="170" y="136" text-anchor="middle" class="sm-s">`ntdll_sched_register_poll`</text>
  <text x="170" y="154" text-anchor="middle" class="sm-s">`ntdll_sched_register_timer`</text>
  <text x="170" y="172" text-anchor="middle" class="sm-s">`ntdll_sched_async`</text>
  <text x="170" y="190" text-anchor="middle" class="sm-s">`ntdll_sched_call`</text>
  <text x="170" y="208" text-anchor="middle" class="sm-s">`ntdll_sched_cancel`</text>
  <text x="170" y="236" text-anchor="middle" class="sm-s">generation-tagged handles</text>
  <text x="170" y="254" text-anchor="middle" class="sm-s">ABA-safe cancel across instances</text>
  <text x="170" y="272" text-anchor="middle" class="sm-s">self-call runs inline on sched thread</text>

  <rect x="370" y="92" width="220" height="92" class="sm-inst"/>
  <text x="480" y="120" text-anchor="middle" class="sm-g">default instance</text>
  <text x="480" y="142" text-anchor="middle" class="sm-s">poll users + timer users</text>
  <text x="480" y="160" text-anchor="middle" class="sm-s">PI mutex + non-blocking wake pipe</text>

  <rect x="370" y="212" width="220" height="92" class="sm-rt"/>
  <text x="480" y="240" text-anchor="middle" class="sm-v">RT instance</text>
  <text x="480" y="262" text-anchor="middle" class="sm-s">same API, separate sched instance</text>
  <text x="480" y="280" text-anchor="middle" class="sm-s">lazy-spawned only when needed</text>

  <rect x="680" y="92" width="220" height="92" class="sm-inst"/>
  <text x="790" y="120" text-anchor="middle" class="sm-g">`wine-sched` loop</text>
  <text x="790" y="142" text-anchor="middle" class="sm-s">poll()</text>
  <text x="790" y="160" text-anchor="middle" class="sm-s">dispatch callbacks outside producer locks</text>

  <rect x="680" y="212" width="220" height="92" class="sm-rt"/>
  <text x="790" y="240" text-anchor="middle" class="sm-v">`wine-sched-rt` loop</text>
  <text x="790" y="262" text-anchor="middle" class="sm-s">same dispatch core</text>
  <text x="790" y="280" text-anchor="middle" class="sm-s">RT-only consumers</text>

  <line x1="280" y1="140" x2="370" y2="140" class="sm-line-g"/>
  <line x1="280" y1="258" x2="370" y2="258" class="sm-line-v"/>
  <line x1="590" y1="140" x2="680" y2="140" class="sm-line-g"/>
  <line x1="590" y1="258" x2="680" y2="258" class="sm-line-v"/>

  <rect x="180" y="334" width="600" height="54" class="sm-note"/>
  <text x="480" y="362" text-anchor="middle" class="sm-y">Cancel and wake discipline</text>
  <text x="480" y="378" text-anchor="middle" class="sm-s">generation-checked cancel avoids stale-handle ABA</text>
  <text x="480" y="392" text-anchor="middle" class="sm-s">non-blocking wake writes avoid producer-side deadlock</text>
</svg>
</div>

---

## 3. API surface

The API surface is:

```c
NTSTATUS ntdll_sched_register_poll( int fd, int events,
                                    poll_callback callback,
                                    void *private,
                                    sched_handle_t *handle );

NTSTATUS ntdll_sched_register_timer( const LARGE_INTEGER *timeout,
                                     async_callback callback,
                                     void *private,
                                     sched_handle_t *handle );

NTSTATUS ntdll_sched_async( async_callback callback, void *private );
NTSTATUS ntdll_sched_call( call_callback callback, void *private );
NTSTATUS ntdll_sched_cancel( sched_handle_t handle );
```

NSPA adds class routing through `NTDLL_SCHED_CLASS_DEFAULT` and
`NTDLL_SCHED_CLASS_RT`. Consumers that need RT dispatch call the class-aware
registration helpers; consumers that only need a general callback host stay on
the default instance.

The important semantics:

- `register_*` returns a generation-stamped handle that can be canceled later
- `cancel` is best-effort and returns `STATUS_NOT_FOUND` on a stale or already
  consumed handle
- `async` is fire-and-forget
- `call` is synchronous to the caller, but self-calls from the sched thread
  run inline to avoid deadlock

---

## 4. Current consumers

### 4.1 Async close queue on `wine-sched`

The first real consumer is the local-file async close queue. For eligible
fully-shareable local-file handles, `NtClose` no longer pays unix `close()` and
server `close_handle` latency inline on the caller thread. Instead it pushes a
bounded queue entry to the default sched thread.

The rules are conservative:

- queue capacity: 64
- eligibility: `FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE` only
- pre-flush on same-path reopen to close the local race window
- fallback inline on queue-full, disabled sched routing, or restrictive sharing

This is a latency and consolidation feature, not a semantic change. Restrictive
sharing closes still go inline immediately so any blocked opener sees the close
at the same point as before.

### 4.2 `local_timer` and `local_wm_timer` on `wine-sched-rt`

The next consumers are the timer dispatchers that used to own separate
RT helper threads:

- `nspa_local_timer`
- `nspa_local_wm_timer`

When RT is available, both route onto the shared RT sched instance instead
of running dedicated `pthread` loops. The priority class is unchanged from the
legacy design: `SCHED_FIFO` at `NSPA_RT_PRIO - 1`. The win is consolidation and
shared infrastructure, not a different scheduling policy.

When both migrations are active together, the process loses one helper thread
relative to the pre-migration layout because two legacy loops collapse onto one
shared `wine-sched-rt` host.

### 4.3 Observability sampler on the default class

`NSPA_SCHED_OBS_INTERVAL_MS` enables a periodic sampler hosted on the default
class. It is not a production fast path, but it is active and useful because
it exercises the timer and cancel paths continuously with a real in-tree
consumer.

Current built-in output is written to `/dev/shm/nspa-obs.<pid>` and includes
stats such as:

- close-queue depth
- RT-probe liveness and firing counters when the RT probe is enabled

This sampler remains default OFF.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .cc-bg { fill: #1a1b26; }
    .cc-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.5; rx: 8; }
    .cc-def { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 8; }
    .cc-rt { fill: #2a1f35; stroke: #bb9af7; stroke-width: 2; rx: 8; }
    .cc-src { fill: #1a2235; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .cc-note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .cc-t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .cc-s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .cc-h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .cc-g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .cc-v { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
    .cc-y { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .cc-line-g { stroke: #9ece6a; stroke-width: 1.5; fill: none; }
    .cc-line-v { stroke: #bb9af7; stroke-width: 1.5; fill: none; }
    .cc-line-y { stroke: #e0af68; stroke-width: 1.5; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="430" class="cc-bg"/>
  <text x="480" y="28" text-anchor="middle" class="cc-h">Current consumer map</text>

  <rect x="70" y="90" width="230" height="72" class="cc-src"/>
  <text x="185" y="118" text-anchor="middle" class="cc-t">local-file close path</text>
  <text x="185" y="140" text-anchor="middle" class="cc-s">eligible full-share closes enqueue work</text>

  <rect x="70" y="200" width="230" height="72" class="cc-src"/>
  <text x="185" y="228" text-anchor="middle" class="cc-t">`NtSetTimer` / `WM_TIMER`</text>
  <text x="185" y="250" text-anchor="middle" class="cc-s">precision timer expiries and reposts</text>

  <rect x="70" y="310" width="230" height="72" class="cc-src"/>
  <text x="185" y="338" text-anchor="middle" class="cc-t">observability sampler</text>
  <text x="185" y="360" text-anchor="middle" class="cc-s">periodic stats snapshot when env-enabled</text>

  <rect x="410" y="118" width="220" height="96" class="cc-def"/>
  <text x="520" y="146" text-anchor="middle" class="cc-g">`wine-sched`</text>
  <text x="520" y="168" text-anchor="middle" class="cc-s">async close queue drain</text>
  <text x="520" y="186" text-anchor="middle" class="cc-s">observability timer</text>

  <rect x="410" y="246" width="220" height="96" class="cc-rt"/>
  <text x="520" y="274" text-anchor="middle" class="cc-v">`wine-sched-rt`</text>
  <text x="520" y="296" text-anchor="middle" class="cc-s">`local_timer` dispatch</text>
  <text x="520" y="314" text-anchor="middle" class="cc-s">`local_wm_timer` dispatch</text>

  <rect x="730" y="170" width="170" height="82" class="cc-note"/>
  <text x="815" y="198" text-anchor="middle" class="cc-y">Fallback path</text>
  <text x="815" y="220" text-anchor="middle" class="cc-s">legacy dedicated thread</text>
  <text x="815" y="236" text-anchor="middle" class="cc-s">or inline close if routing is unavailable</text>

  <path d="M300 126 L410 150" class="cc-line-g"/>
  <path d="M300 236 L410 294" class="cc-line-v"/>
  <path d="M300 346 L410 182" class="cc-line-g"/>
  <path d="M630 294 L730 220" class="cc-line-y"/>
</svg>
</div>

---

## 5. Validation and current controls

The public status here is based on targeted validation of the current
consumers, not on a new full-suite publish.

The scheduler consumers no longer expose per-feature opt-out gates in
the public surface. Async close routing, `local_timer`, and `local_wm_timer`
all run on the normal path when their own eligibility checks pass and RT is
available. The one remaining public control here is the optional sampler:

| Item | Default | Purpose |
|---|---|---|
| `NSPA_SCHED_OBS_INTERVAL_MS` | OFF | opt-in scheduler-host sampler for observability only |

Targeted 2026-05-02 results:

- spawn-main carry: Smoke 0 / 1 / 2 / 3 PASS
- Ableton playback after spawn-main: wineserver observed at `0.0%` CPU during
  playback
- combined sched-RT migrations: `10/10` RT-probe regression check PASS
- combined sched-RT migrations: Ableton boot, library scan, project load, and
  playback PASS
- combined sched-RT migrations: net `-1` thread per process relative to the
  pre-migration layout

---

## 6. Relationship to the rest of Wine-NSPA

This page is client-side infrastructure. It composes with, but does not replace:

- **Gamma channel dispatcher:** still wineserver-side and still the server RPC
  path for requests that need wineserver authority
- **NT-local stubs:** the sched threads host some of those client-local
  dispatchers, especially timers
- **io_uring:** separate client-side async I/O substrate; not routed through
  `ntdll_sched`

The main decomposition consequence is that the client side has a cleaner
place to host helper loops. That shrinks the number of ad-hoc per-subsystem
threads and moves more timing-sensitive work out of the wineserver process
without changing wineserver ownership of cross-process semantics.

---

## 7. References

- [architecture](architecture.gen.html)
- [nt-local-stubs](nt-local-stubs.gen.html)
- [io_uring-architecture](io_uring-architecture.gen.html)
- [wineserver-decomposition](wineserver-decomposition.gen.html)
