# Wine-NSPA — State of The Art

**Date:** 2026-05-01
**Author:** Jordan Johnston
**Kernel:** `6.19.11-rt1-1-nspa` (PREEMPT_RT_FULL, production)
**ntsync module:** `srcversion 10124FB81FDC76797EF1F91`
**Status:** production state board as of 2026-05-01; the 2026-04-30 shipped feature set plus the immediate dispatcher hot-path tuning follow-ons, the winex11 AVX2 flush follow-on, and the Tier 1 compatibility/log-hygiene cleanup are all in the public tree.

This page is the project snapshot for what is actually shipped: kernel patch state, userspace feature state, validation totals, configuration knobs, and the remaining open work.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Current shipped state](#2-current-shipped-state)
3. [Active subsystems](#3-active-subsystems)
4. [Validation and performance](#4-validation-and-performance)
5. [Open work, in priority order](#5-open-work-in-priority-order)
6. [Recent investigation arc](#6-recent-investigation-arc-2026-04-26-to-2026-04-30)
7. [Configuration reference](#7-configuration-reference)
8. [Doc index](#8-doc-index)

---

## 1. Overview

Wine-NSPA moved beyond the post-1010 aggregate-wait baseline on
2026-04-30. The kernel now ships patch 1011
(`NTSYNC_IOC_CHANNEL_TRY_RECV2`) on top of the 1003-1011 stack, and the
wineserver side now ships three default-on follow-ons built on that
base: `NSPA_FLUSH_THROTTLE_MS=8` for `x11drv` MainThread flushes,
`NSPA_ENABLE_ASYNC_CREATE_FILE=1` for Phase 4 `CreateFile` through the
per-process dispatcher-owned `io_uring` ring, and `NSPA_TRY_RECV2=1`
for post-dispatch burst drain on 1011 kernels.

The important distinction for this state board is that the stable
public story now includes the **dispatcher async-completion
architecture**, the **Phase 4 async `create_file` consumer**, and the
**1011 burst-drain follow-on**, not just the prerequisite channel and PI
stack.

Immediately after that feature landing, the dispatcher also got a
second tuning sweep with no new user knob: lighter fences on the hot
path, inlined helper glue, and production-off allocator debug poison /
valgrind stubs so the shipped build stops paying debug-only costs on
every server-bound RPC.

Two smaller 2026-05-01 follow-ons also shipped on top of that base:
the `winex11.drv` alpha-bit flush loop is now AVX2-vectorized, and the
dominant non-actionable Ableton FIXME noise sources were collapsed to
first-print-only while `ShutdownBlockReasonCreate/Destroy` stopped
reporting `ERROR_CALL_NOT_IMPLEMENTED` as a hard failure.

What the project looks like today: one small kernel module
(~3kLOC) plus a Wine fork that increasingly bypasses wineserver
through bounded shmem rings, all gated by a single env var
(`NSPA_RT_PRIO`) so upstream-Wine bytewise behaviour is unchanged
when the gate is off.

---

## 2. Current shipped state

### 2.1 Kernel and module

| Item | Value |
|---|---|
| Kernel | `6.19.11-rt1-1-nspa` |
| Scheduler | `PREEMPT_RT_FULL` |
| ntsync `.ko` | `/lib/modules/6.19.11-rt1-1-nspa/kernel/drivers/misc/ntsync.ko` |
| ntsync srcversion | `10124FB81FDC76797EF1F91` |
| Module ref count | 0 idle |
| Sources | upstream `drivers/misc/ntsync.{c,h}` + NSPA patch stack `1003-1011` |

### 2.2 Userspace baseline

| Item | Value |
|---|---|
| Wine base | Wine 11.6 + NSPA fork |
| Dispatcher shape | gamma + aggregate-wait + post-1011 `TRY_RECV2` burst drain |
| Async file path | Phase 4 async `CreateFile`, default ON |
| X11 flush policy | `NSPA_FLUSH_THROTTLE_MS=8`, default ON |

### 2.3 Patch stack on top of upstream ntsync

| # | Patch | Summary | Status |
|---|---|---|---|
| 1003 | Priority inheritance | Mutex owner PI boost, priority-ordered waiter queues, raw_spinlock + rt_mutex hardening | Shipped |
| 1004 | Channels | Per-process kernel-mediated request/reply channel object (gamma dispatcher backbone) | Shipped |
| 1005 | Thread-token | Per-thread token carried across channel sends; backs gamma T1/T2/T3 | Shipped |
| 1006 | RT alloc-hoist | Hoist `kfree`/`kmalloc` out from under `raw_spinlock` (six sites; pi_work pool/cleanup pattern) | Shipped |
| 1007 | Channel exclusive recv | `wait_event_interruptible_exclusive` + `wake_up_interruptible` — closes thundering-herd on channel waiter wake | Shipped |
| 1008 | EVENT_SET_PI deferred boost | Stage boost decision under `obj_lock`, apply inline at wait-return — no worker thread, no timer | Shipped |
| 1009 | channel_entry refcount | `refcount_t` on `ntsync_channel_entry`; closes REPLY-vs-cleanup UAF caught by KASAN in `test-channel-stress` | Shipped |
| 1010 | Aggregate-wait | Heterogeneous object+fd wait; channel notify-only path used by the gamma dispatcher | Shipped |
| 1011 | Channel TRY_RECV2 | `NTSYNC_IOC_CHANNEL_TRY_RECV2`: non-blocking `RECV2` for post-dispatch burst drain | Shipped |

### 2.4 Default-on session changes -- 2026-04-30

#### Env-controlled features now default-on

| Feature | Default | Override | User-visible result |
|---|---|---|---|
| `NSPA_FLUSH_THROTTLE_MS` | `8` | `NSPA_FLUSH_THROTTLE_MS=N`; `=0` disables | `x11drv_surface_flush`: 8.23% -> 4.74% (−43%); `copy_rect_32` memmove: 4.38% -> 2.49% (−43%); MainThread CPU recovered: ~5.4 percentage points |
| `NSPA_ENABLE_ASYNC_CREATE_FILE` | `1` | `NSPA_ENABLE_ASYNC_CREATE_FILE=0` | Phase 4 routes `CreateFile` through the per-process `io_uring` ring, removing the `open()` lock-drop CS from the audio xrun path |
| `NSPA_TRY_RECV2` | `1` | `NSPA_TRY_RECV2=0` | On ntsync 1011 kernels, drains multiple channel entries per `AGG_WAIT` instead of N round-trips |

#### Correctness fixes shipped in the same session

| Fix | Effect |
|---|---|
| LF dir-bypass `fd->nt_name` populated on promote | fixes `start.exe` NULL-Name crash |
| LF rejects `FILE_NON_DIRECTORY_FILE` on dir bypass | restores sync parity for directory opens |
| LF `check_sharing` arbitrates `FILE_MAPPING_WRITE` | mirrors `server/fd.c::check_sharing` |
| `local_wm_timer` eligibility tightening | `TIMERPROC` + cross-thread `SetTimer` cases defer to the server |

### 2.5 Dispatcher hot-path follow-ons (shipped, no user knob)

| Commit | Landed change | Observed effect |
|---|---|---|
| `1d85c558ceb` | ACQ_REL fences + inline `nspa_queue_bypass_shm` | removes the hot accessor call and the unnecessary `mfence` cost from the dispatcher path |
| `c0f5c515cd7` + `2870c9629ce` | gate `mark_block_*` poison and the paired valgrind annotations behind `NSPA_DEBUG_POISON_ALLOCS` | reclaims the full `1.34pp` allocator-debug tax seen under `dispatcher-burst`; `mark_block_uninitialized` falls out of the top symbols |
| `0802dadc750` | inline `read_request_shm` at the dispatcher call site | `read_request_shm` was sampled at `3.55%` wineserver-relative under `dispatcher-burst`; after inlining it disappears from the symbol table and saves `~1pp` more on the dispatcher path |

These are production-path cleanups, not new feature flags. They keep
the shipped gamma dispatcher from paying avoidable function-call and
debug-aid overhead once the architectural wins from aggregate-wait and
`TRY_RECV2` are already in place.

### 2.6 2026-05-01 shipped follow-ons (no new user knob)

| Commit | Landed change | Observed effect |
|---|---|---|
| `527647bac3e` | AVX2-vectorize the alpha-bit OR loop in `dlls/winex11.drv/bitblt.c::x11drv_surface_flush` | `x11drv_surface_flush`: `6.72%` -> `2.39%` (`-4.33pp`, `-64%`); total `winex11.so`: `6.76%` -> `2.43%` (`-4.33pp`); output bit-identical, no visual regression |
| `97aff17da45` + `206f32b3de9` | once-guard 9 dominant stub FIXMEs and real-impl `ShutdownBlockReasonCreate/Destroy` as silent success | top stub noise drops from `~565` prints per Ableton run to `~5` first-time prints; shutdown-reason calls stop failing with `ERROR_CALL_NOT_IMPLEMENTED` |

These are compatibility and presentation cleanups, not architectural
changes. The AVX2 change reduces PE-side GUI flush cost under the same
busy Ableton workload already used for the 2026-04-30 throttle and
dispatcher measurements. The FIXMEs cleanup does not change RT
behaviour, but it makes real regressions easier to spot because known
stub chatter no longer buries the logs.

### 2.7 Validation totals against `10124FB81FDC76797EF1F91`

| Layer | Run | Result | Ops | Errors |
|---|---|---|---|---|
| Native suite | `run-rt-suite.sh native` | 3 PASS / 0 FAIL | `test-event-set-pi`, `test-channel-recv-exclusive`, `test-aggregate-wait` | 0 |
| Native aggregate | `test-aggregate-wait` | 9/9 PASS | kitchen-sink: 86,528 wakes / 0 timeouts / 0 errors | 0 |
| PE matrix | `nspa_rt_test.exe baseline+rt` | 24 PASS / 0 FAIL / 0 TIMEOUT | baseline + RT | 0 |
| PE dispatcher A/B | `dispatcher-burst` | PASS in matrix | steady-state 100k iters; burst 8 × 1000 × 64 = 512k ops | 0 |
| Busy-workload perf | Ableton 30s busy capture | PASS | `channel_dispatcher` 14.51% -> 0.70%; samples 38,588 -> 19,415 | 0 |

**Layer 1 totals: 3 PASS / 0 FAIL. Layer 2 totals: 24 PASS / 0 FAIL /
0 TIMEOUT. Module `10124FB81FDC76797EF1F91` was loaded live and
verified while these results were collected.**

Patch-level kernel detail lives on `ntsync-driver.gen.html`; dispatcher
and async-completion detail lives on
`gamma-channel-dispatcher.gen.html` and
`aggregate-wait-and-async-completion.gen.html`.

---

## 3. Active subsystems

### 3.1 RT priority inheritance — four paths

The four PI coverage paths are unchanged from the v6 board, all still
active when `NSPA_RT_PRIO` is set:

| Path | Win32 surface | Wine layer | Kernel mechanism |
|---|---|---|---|
| A | `EnterCriticalSection` | `RtlEnterCriticalSection` (TID CAS fast-path → unix slow-path) | `FUTEX_LOCK_PI` rt_mutex |
| B | `WaitForSingleObject` / `Multiple` | `NtWaitForSingleObject` → `inproc_wait` → `ioctl(/dev/ntsync)` | `/dev/ntsync` PI (1003) |
| C | `pi_cond_wait` (vendored librtpi) | librtpi unix-side header-only | `FUTEX_WAIT_REQUEUE_PI` |
| D | `SleepConditionVariableCS` | `NtNspaCondWaitPI` (3 syscalls + condvar→mutex map) | `FUTEX_WAIT_REQUEUE_PI` |

When `NSPA_RT_PRIO` is unset, every code path is byte-identical to
upstream Wine. Zero overhead.

### 3.2 Bypass and infrastructure subsystems

The dominant architectural change over the last six months has been
moving state out of the single-threaded wineserver event loop into
bounded shmem rings or direct kernel-mediated channels, each with its
own correctness proof and gate.

| Subsystem | Status | Default | Brief |
|---|---|---|---|
| **Gamma channel dispatcher** | Shipped | ON | Per-process kernel-mediated channel via ntsync 1004/1005/1011, with post-1010 aggregate-wait over channel + uring eventfd + shutdown eventfd and post-dispatch TRY_RECV2 burst drain on 1011 kernels. |
| **Phase A — `open_fd` refactor** | Shipped | ON | `fchdir+open` → `openat`; first step toward holding `global_lock` for less of the open path. |
| **Phase B — `openat` lock-drop** | Shipped | ON | Release `global_lock` around `openat()` so audio thread requests are not blocked by slow file syscalls during drum-load. |
| **Hook tier 1+2 cache** | Shipped | ON | Server-side cache rebuild + client cache reader; 26.7k/26.7k cache hit on Ableton 165s, `server_dispatch=0`. |
| **CS-PI v2.3** | Shipped | ON when `NSPA_RT_PRIO` set | Recursive `pi_mutex` extension on top of vendored librtpi; LockSemaphore field repurposed. |
| **Condvar PI requeue** | Shipped | ON when `NSPA_RT_PRIO` set | `FUTEX_WAIT_REQUEUE_PI`; `RtlSleepConditionVariableCS` slow path. |
| **librtpi vendoring** | Shipped | n/a | Header-only `rtpi.h` forwarder into the vendored library copy. |
| **NT-local file** (`nspa_local_file`) | Shipped | ON | `NtCreateFile` bypass for unix-name-resolvable paths, with 2026-04-30 sync-parity fixes for directory promotion and `FILE_MAPPING_WRITE` sharing. |
| **NT-local timer** (`nspa_local_timer`) | Shipped | ON | NT timer object client-resolution. |
| **NT-local WM timer** (`nspa_local_wm_timer`) | Shipped | ON | `SetTimer` userspace path; `TIMERPROC` + cross-thread cases now explicitly defer to the server. |
| **msg-ring v1 (POST/SEND/REPLY)** | Shipped | ON | Bounded mpmc shmem ring for `PostMessage` / `SendMessage` / reply between Wine threads in the same process. |
| **msg-ring v2 B1.0 paint-cache** | Shipped | **OFF** (gated) | Cross-process redraw cache for `WM_PAINT` fast-path; one clean confirmation run exists, but the default-on flip still wants more validation. |
| **msg-ring v2 Phase C get_message** | **WIP, paused** | n/a | Remaining message-pump bypass piece; once it lands, window messages are fully out of wineserver. |
| **io_uring Phase 1 (socket I/O)** | Shipped | ON when `NSPA_RT_PRIO` set | ALERTED-state interception; ntsync `uring_fd` extension under the older numbering. |
| **Dispatcher Phase 2/3 (`NSPA_AGG_WAIT`)** | Shipped | ON | Per-process server-side `io_uring` infrastructure plus aggregate-wait dispatcher loop. Same RT thread receives requests, drains CQEs, and signals replies. |
| **Async `CreateFile` (Phase 4)** | Shipped | ON | `NSPA_ENABLE_ASYNC_CREATE_FILE=1` routes `CreateFile` through the dispatcher-owned ring and removes the `open()` lock-drop critical section from the audio xrun path. |
| **io_uring socket/pipe follow-on** | Pending | n/a | Socket and pipe coverage beyond the shipped dispatcher-owned ring consumer; sync socket work remains a separate revalidation thread. |
| **Wineserver `global_lock` PI** | Shipped | ON when `NSPA_RT_PRIO` set | `pthread_mutex` → `pi_mutex` on `global_lock`; CFS holders boost via PI chain when the boosted dispatcher contends. |
| **vDSO preloader (Jinoh Kang port)** | Shipped | ON | Full port minus the EHDR-unmap piece intentionally omitted on static-pie x86_64. |
| **NSPA priority mapping** | Shipped | ON when `NSPA_RT_PRIO` set | `fifo_prio = nspa_rt_prio_base - (31 - nt_band)`, clamped `[1..98]`; TIME_CRITICAL pinned to ceiling. |

### 3.3 Audio stack

| Component | Status | Brief |
|---|---|---|
| `winejack.drv` | Shipped | Phase 1 MIDI + Phase 2 WASAPI audio + future MIDI through unified driver |
| `nspaASIO` Phase F | Shipped | Zero-latency `bufferSwitch` invoked **inside** the JACK RT callback — same-period output, no double-buffering hop |
| Native `winealsa`/`winepulse`/`wineoss` | Drop planned | Once winejack is fully stable; not removed yet |

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 500" xmlns="http://www.w3.org/2000/svg">
  <style>
    .cs-bg { fill: #1a1b26; }
    .cs-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .cs-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .cs-gate { fill: #2a1f14; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .cs-wip { fill: #1f2535; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .cs-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .cs-small { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .cs-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cs-tag-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cs-tag-yellow { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cs-tag-violet { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cs-line { stroke: #c0caf5; stroke-width: 1.3; }
  </style>
  <defs>
    <marker id="csArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="940" height="500" class="cs-bg"/>
  <text x="470" y="28" text-anchor="middle" class="cs-title">2026-04-30 deployment board: what is shipped, what is gated, and what is next</text>

  <rect x="50" y="70" width="250" height="150" class="cs-green"/>
  <text x="175" y="96" text-anchor="middle" class="cs-tag-green">Kernel / sync substrate</text>
  <text x="175" y="122" text-anchor="middle" class="cs-label">NTSync 1003-1011</text>
  <text x="175" y="140" text-anchor="middle" class="cs-small">PI waits, channel IPC, aggregate-wait, TRY_RECV2</text>
  <text x="175" y="164" text-anchor="middle" class="cs-label">CS-PI + condvar PI</text>
  <text x="175" y="182" text-anchor="middle" class="cs-small">all RT paths gate on NSPA_RT_PRIO</text>

  <rect x="345" y="70" width="250" height="150" class="cs-green"/>
  <text x="470" y="96" text-anchor="middle" class="cs-tag-green">Client-side bypasses</text>
  <text x="470" y="122" text-anchor="middle" class="cs-label">gamma + Phase 4 async create_file</text>
  <text x="470" y="140" text-anchor="middle" class="cs-small">local-file, local timers, hook cache, msg-ring v1</text>
  <text x="470" y="164" text-anchor="middle" class="cs-label">TRY_RECV2 + flush throttle shipped</text>
  <text x="470" y="182" text-anchor="middle" class="cs-small">many hot paths no longer need global_lock</text>

  <rect x="640" y="70" width="250" height="150" class="cs-green"/>
  <text x="765" y="96" text-anchor="middle" class="cs-tag-green">Audio stack</text>
  <text x="765" y="122" text-anchor="middle" class="cs-label">winejack.drv</text>
  <text x="765" y="140" text-anchor="middle" class="cs-small">MIDI + WASAPI on JACK</text>
  <text x="765" y="164" text-anchor="middle" class="cs-label">nspaASIO Phase F</text>
  <text x="765" y="182" text-anchor="middle" class="cs-small">bufferSwitch in JACK RT callback</text>

  <rect x="50" y="270" width="250" height="140" class="cs-gate"/>
  <text x="175" y="296" text-anchor="middle" class="cs-tag-yellow">Gated / default-OFF</text>
  <text x="175" y="322" text-anchor="middle" class="cs-label">paint-cache fastpath</text>
  <text x="175" y="340" text-anchor="middle" class="cs-small">one clean run done; more validation required</text>
  <text x="175" y="364" text-anchor="middle" class="cs-label">epoll A/B switch</text>
  <text x="175" y="382" text-anchor="middle" class="cs-small">runtime measurement, not committed direction</text>

  <rect x="345" y="270" width="250" height="140" class="cs-wip"/>
  <text x="470" y="296" text-anchor="middle" class="cs-tag-violet">Paused / queued</text>
  <text x="470" y="322" text-anchor="middle" class="cs-label">msg-ring Phase C get_message</text>
  <text x="470" y="340" text-anchor="middle" class="cs-small">remaining message-pump bypass piece</text>
  <text x="470" y="364" text-anchor="middle" class="cs-label">io_uring sockets + pipes</text>
  <text x="470" y="382" text-anchor="middle" class="cs-small">follow-on surfaces beyond the shipped ring consumer</text>

  <rect x="640" y="270" width="250" height="140" class="cs-wip"/>
  <text x="765" y="296" text-anchor="middle" class="cs-tag-violet">Longer horizon</text>
  <text x="765" y="322" text-anchor="middle" class="cs-label">wineserver decomposition remainder</text>
  <text x="765" y="340" text-anchor="middle" class="cs-small">timer split + FD polling split around shipped aggregate-wait</text>
  <text x="765" y="364" text-anchor="middle" class="cs-label">phase 4</text>
  <text x="765" y="382" text-anchor="middle" class="cs-small">router/handler split + lock partitioning</text>

  <line x1="175" y1="220" x2="175" y2="270" class="cs-line" marker-end="url(#csArrow)"/>
  <line x1="470" y1="220" x2="470" y2="270" class="cs-line" marker-end="url(#csArrow)"/>
  <line x1="765" y1="220" x2="765" y2="270" class="cs-line" marker-end="url(#csArrow)"/>
  <text x="470" y="456" text-anchor="middle" class="cs-small">top row = shipped state today; bottom row = remaining gates and roadmap pressure</text>
</svg>
</div>

---

## 4. Validation and performance

### 4.1 What's clean

- ntsync module `10124FB81FDC76797EF1F91` against prod kernel `6.19.11-rt1-1-nspa`: 1003-1011 live, loaded, and verified clean.
- Native suite: **3 PASS / 0 FAIL** (`test-event-set-pi`, `test-channel-recv-exclusive`, `test-aggregate-wait`).
- `test-aggregate-wait`: **9/9 PASS**, including kitchen-sink `86,528 wakes / 0 timeouts / 0 errors`.
- nspa_rt_test PE matrix: **24 PASS / 0 FAIL / 0 TIMEOUT** (baseline + RT).
- `dispatcher-burst` is now in the PE matrix and is the first PE-side harness that actually covers `channel_dispatcher` / `dispatch_channel_entry` / the TRY_RECV2 drain loop.
- Ableton Live 12 Lite — full smoke level 4 — **two clean runs on 2026-04-28**:
  - **Run-3**: paint-cache OFF (default config). Drum-track-load-while-playing × multiple, audio clean, exit 0.
  - **Run-4**: `NSPA_ENABLE_PAINT_CACHE=1` (the historical 5-min-lockup config). Past 5-min threshold without incident, multiple drum-load cycles, audio clean, exit 0.
- Ableton Live 12 Lite — **Phase 3 dispatcher + TRY_RECV2 + Phase 4 create_file** (2026-04-30): clean under the same workload, with the dispatcher re-profiled under a 30s busy capture.

### 4.2 Headline performance

#### Dispatcher tuning under Ableton busy workload

| Symbol | Before | After | Delta |
|---|---:|---:|---:|
| `channel_dispatcher` | 14.51% | 0.70% | −13.81pp / −95% |
| `main_loop_epoll` | 7.24% | 2.68% | −4.56pp |
| `nspa_queue_bypass_shm` | 2.77% | absent | inlined into call sites |
| `req_get_update_region` | 4.92% | absent | gone from top symbols |
| `nspa_redraw_ring_drain` | 2.88% | absent | gone from top symbols |

System-wide samples: 38,588 -> 19,415 per 30s.

#### Post-ship dispatcher hot-path follow-ons

| Commit | Measured result |
|---|---|
| `c0f5c515cd7` + `2870c9629ce` | `mark_block_uninitialized` was sampled at `1.34%` wineserver-relative under `dispatcher-burst`; after gating the poison + valgrind pair behind `NSPA_DEBUG_POISON_ALLOCS`, the full `1.34pp` cost is reclaimed |
| `0802dadc750` | `read_request_shm` was sampled at `3.55%` wineserver-relative under `dispatcher-burst`; after inlining it disappears from the symbol table and saves `~1pp` more on the dispatcher path |

These commits are layered on top of the bigger 2026-04-30 dispatcher
shape change (`TRY_RECV2`, inline queue accessor, lighter fences). They
do not change the architecture; they remove residual per-RPC overhead
from the already-shipped path.

#### PE-side `dispatcher-burst` A/B

| Metric | TRY_RECV2 on | TRY_RECV2 off | Delta |
|---|---:|---:|---:|
| burst ops/sec (wall) | 841,765 | 555,567 | +34% / 1.5x |
| burst worst max ns | 23,014,325 | 31,843,082 | −28% |
| steady avg ns | 35,202 | 33,405 | flat (no burst) |

#### Flush throttle impact

| Symbol | Before throttle | After throttle=8ms | Delta |
|---|---:|---:|---:|
| `x11drv_surface_flush` | 8.23% | 4.74% | −43% |
| `copy_rect_32` memmove | 4.38% | 2.49% | −43% |
| MainThread CPU recovered | — | — | ~5.4 percentage points |

#### Winex11 AVX2 follow-on after throttle

| Symbol | Before AVX2 | After AVX2 | Delta |
|---|---:|---:|---:|
| `x11drv_surface_flush` | 6.72% | 2.39% | −4.33pp / −64% |
| total `winex11.so` | 6.76% | 2.43% | −4.33pp |
| total kernel | 10.22% | 8.58% | −1.64pp |

This was a pure PE-side follow-on inside `winex11.drv`, after the
8ms flush throttle had already landed. The hot scalar `ptr[x] |=
alpha_bits` loop was replaced with an AVX2 `vpor` path over 8 pixels
per iteration, with a scalar tail. Publicly relevant result: lower
MainThread GUI flush cost with bit-identical output.

#### PE-suite comparison vs 2026-04-26

| Metric | 2026-04-26 | 2026-04-30 | Delta |
|---|---:|---:|---:|
| rapidmutex RT max_wait | 44us | 38us | −14% |
| rapidmutex RT elapsed | 1950ms | 1924ms | −1.3% |
| ntsync-d12 PI chain depth-12 | 236ms | 237ms | ≈0 |

### 4.3 Remaining gates

- **`NSPA_ENABLE_PAINT_CACHE=1`** — one clean confirmation run exists,
  but the default-on flip still wants a second-day cold start, a
  longer soak (>30 min playback + idle), and workload variation
  beyond the existing drum-load case.
- **Phase 4 + TRY_RECV2 long-soak** — current data is clean, but an
  hours-long default-on Ableton session is still worth doing.
- **Throttle=16 A/B** — the current 8ms default is validated; a higher
  throttle setting still needs its own data before any wider change.
- **`NSPA_DISABLE_EPOLL`** — runtime A/B for poll vs epoll on the
  wineserver main loop; epoll remains the default.

### 4.4 Residual caveats

- **F5 paint-cache 5-min lockup** — Run-4 cleared the historical
  workload cleanly, but the exact pre-fix root cause is still a working
  hypothesis rather than a trace-proven fact.
- **Why confidence is higher now** — idle CPU stayed clean and audio
  continued through drum-load GUI pauses, which is consistent with the
  minimal 1007/1008/1009 kernel fixes plus Phase B lock-drop doing the
  work they were meant to do.

---

## 5. Open work, in priority order

1. **Phase 4 + TRY_RECV2 long-soak** — extended Ableton session under
   default-on settings to validate stability over hours.
2. **Throttle=16 A/B** — see whether the throttle curve keeps paying
   past 8ms before changing the default.
3. **WM_TIMER MR2 fix** — cache queue ntsync sync fd at `SetTimer`
   time so dispatcher wake semantics close the remaining idle-wake gap.
4. **Second paint-cache validation run** — different day / cold start
   plus long-soak (>30 min) plus workload variation. Closes the F5
   chapter. After that, flip `NSPA_ENABLE_PAINT_CACHE` default-on.
5. **msg-ring v2 Phase C get_message bypass** — paused mid-development.
   After C lands, window messages are fully out of wineserver.
6. **io_uring socket + pipe follow-on** — sync socket revalidation plus
   pipe/named-event surface work on top of the shipped ring consumer.
7. **`wine_sechost_service` device-IRP poll** — ~530 polls/s, 63k
   `get_next_device_request` per Ableton run; audit Q2
   (payload-distribution) is the gate before any bypass design.
8. **Wineserver decomposition remainder** — timer thread + FD poll
   thread splits still queued. The aggregate-wait kernel/userspace
   slice is already shipped; the remaining design work is how the rest
   of wineserver composes around it.
9. **MR3 GC pass** — peer-cache slot leak under thread churn;
   ~30 LOC; perf cliff, not lockup. Defer until somebody hits it.
10. **CS DYNAMIC_SPIN substitution** — `RTL_CRITICAL_SECTION_FLAG_DYNAMIC_SPIN`
   FIXME stub for CRT heap; plan is ~4000 spincount gated behind
   `!nspa_cs_pi_active()`. Low priority.
11. **Wow64 clean rebuild** — 32-bit (i386) DLLs may be stale. Required
   for 32-bit VST plugins and older games. Medium priority.

---

## 6. Recent investigation arc (2026-04-26 to 2026-04-30)

The three-day arc is worth recording in one place because it
illustrates how Wine-NSPA's failure modes cross the kernel/userspace
boundary and how the discipline of "trace before audit" plays out.

**2026-04-26 morning** — msg-ring v2 B1.0 paint-cache shipped
default-on. Ableton ran fine for 4–5 minutes then locked into pure
userspace deadlock. Mechanism unexplained; paint-cache was reverted to
default-off the same day.

**2026-04-26 afternoon** — assumed kernel-side, given the symptom
shape (silent userspace stall, no kernel splat). Spent the day on a
five-patch ntsync "audit-finding" series (1007–1011) without ever
tracing the original `EVENT_SET_PI` slab UAF. All five were later
rolled back. The cost of skipping the trace step was a full day of
wasted patch-writing.

**2026-04-27 morning** — installed the debug kernel
(`linux-nspa-debug` with `slub_debug=FZPU` + `kfence` + KASAN). Ran
the test suite. KASAN fired in `test-channel-stress`: REPLY's
`wake_up_all` racing `SEND_PI`'s `kfree(e)`. **Root caused.** Same bug
class as the rolled-back 1008/1009 — but now with a backtrace. Clean
fix was `refcount_t` on `ntsync_channel_entry`, ~15 LOC. Three more
bugs surfaced in sequence: channel-RECV thundering-herd (1007 — clean
fix `wait_event_interruptible_exclusive`, 3 LOC), `EVENT_SET_PI`
deferred boost (1008 — staged under `obj_lock`, applied inline), test
cleanup asymmetry (Bug 1 — test-only).

**2026-04-27 afternoon** — debug kernel itself proved unstable under
heavy PREEMPT_RT load (`MAX_LOCKDEP_CHAINS too low`, `__might_sleep`
warnings, `softlockup_panic=1` configured). Module rebuilt for
production kernel `6.19.11-rt1-1-nspa`. Validation ran clean: 370M ops,
zero errors.

**2026-04-27 evening** — pivoted to wine-userspace audit on the
working hypothesis that remaining lockups are now wine-side. 1576-LOC
walk of `dlls/win32u/nspa/msg_ring.c` found three pre-existing bugs:
MR1 (reply-slot ABA), MR2 (`FUTEX_PRIVATE` on shared memfd), MR4
(POST dual-signal-fail wake-loss). All shipped the same evening.
P2/P3/P5 follow-up audits all clean.

**2026-04-28 daytime** — Ableton run-3 PASS (paint-cache OFF).
Closed the lockup investigation. Then run-4 with
`NSPA_ENABLE_PAINT_CACHE=1` PASS, past the historical 5-min threshold,
likely incidentally fixing F5 via MR1.

**2026-04-29** — kernel 1010 + gamma Phase 2/3 shipped as the first
landed aggregate-wait consumer. The dispatcher now waits on `(channel,
uring eventfd, shutdown eventfd)`, drains CQEs inline on the same RT
thread, and signals replies from that same thread.

**2026-04-30** — three compounding default-on follow-ons landed on top
of that base: flush throttle at 8ms, Phase 4 async `create_file`, and
1011 TRY_RECV2 burst drain. `dispatcher-burst` was added to the PE
matrix specifically because the existing PE suite did not exercise the
dispatcher hot path. The Ableton 30s busy capture then confirmed the
full-stack result: `channel_dispatcher` 14.51% -> 0.70%, with
system-wide samples 38,588 -> 19,415 per 30s.

**The takeaway** — the bugs found were all on the critical RT-sync
path that every remaining bypass (Phase C, io_uring 2/3, sechost)
calls into. They would have surfaced regardless, just attributed to
whichever bypass was being shipped at the time. Better paid now on a
contained surface than mid-feature-rollout. The discipline lesson —
trace before audit — remains the operating principle going forward.

---

## 7. Configuration reference

### 7.1 Active env vars

| Var | Effect |
|---|---|
| `NSPA_RT_PRIO=80` | Master gate. Sets RT priority ceiling and activates all four PI paths. When unset, Wine-NSPA is byte-identical to upstream Wine. |
| `NSPA_RT_POLICY=FF` | SCHED_FIFO (vs RR). Same-prio RR quantum-slices the audio thread; FIFO eliminates. |
| `NSPA_OPENFD_LOCKDROP=1` | Phase B `openat` lock-drop. **Default ON post-1006.** |
| `NSPA_DISPATCHER_USE_TOKEN=1` | Gamma T3 thread-token consumption in dispatcher. **Default ON.** |
| `NSPA_AGG_WAIT=1` | Phase 3 aggregate-wait dispatcher loop. **Default ON post-1010 validation.** Set `0` to force the legacy direct receive loop. |
| `NSPA_TRY_RECV2=1` | Post-dispatch burst-drain on ntsync 1011 kernels. **Default ON.** Set `0` to force one `AGG_WAIT` round-trip per dequeued entry. |
| `NSPA_ENABLE_ASYNC_CREATE_FILE=1` | Phase 4 async `CreateFile` through the dispatcher-owned ring. **Default ON.** Set `0` to stay on the older sync handler path. |
| `NSPA_FLUSH_THROTTLE_MS=8` | `flush_window_surfaces` throttle on `x11drv` MainThread. **Default ON at 8.** Set `N` to retune; `0` disables. |
| `NSPA_ENABLE_PAINT_CACHE=1` | msg-ring v2 B1.0 paint-cache. **Default OFF.** Awaiting second validation run. |
| `NSPA_DISABLE_EPOLL=1` | A/B PREEMPT_RT poll vs epoll on wineserver main loop. Default upstream (epoll). |
| `WINEPRELOADREMAPVDSO=force\|skip\|on-conflict` | vDSO preloader behaviour. Default `on-conflict`. |

### 7.2 RT priority mapping (with `NSPA_RT_PRIO=80`)

Formula: `fifo_prio = nspa_rt_prio_base - (31 - nt_band)`, clamped to `[1..98]`.

| Win32 label | Win32 value | NT band | FIFO priority |
|---|---|---|---|
| IDLE (realtime class) | -15 | 16 | 65 |
| LOWEST | -2 | 22 | 71 |
| BELOW_NORMAL | -1 | 23 | 72 |
| NORMAL | 0 | 24 | 73 |
| ABOVE_NORMAL | 1 | 25 | 74 |
| HIGHEST | 2 | 26 | 75 |
| **TIME_CRITICAL** | 15 | 31 | **80** |
| wineserver main | — | — | **64** (auto-derive = `NSPA_RT_PRIO - 16`) |

`NSPA_RT_PRIO` is the *ceiling*, not a midpoint. `TIME_CRITICAL` is
special-cased to NT band 31 and maps exactly to that ceiling. Standard
REALTIME-class priorities scale linearly below it.

---

## 8. Doc index

State boards and architecture deep-dives produced by the project:

| Doc | Subject |
|---|---|
| `current-state.md` | This document — state of the art on 2026-05-01 |
| `cs-pi.gen.html` | Critical Section Priority Inheritance (CS-PI v2.3) — twelve-section deep dive |
| `condvar-pi-requeue.gen.html` | `RtlSleepConditionVariableCS` `FUTEX_WAIT_REQUEUE_PI` slow path |
| `aggregate-wait-and-async-completion.gen.html` | Landed kernel 1010 + dispatcher Phase 2/3 aggregate-wait architecture |
| `gamma-channel-dispatcher.gen.html` | Gamma request/reply transport plus post-1010 aggregate-wait dispatcher loop |
| `ntsync-driver.gen.html` | NTSync kernel driver patch stack through 1011 plus `TRY_RECV2` |
| `io_uring-architecture.gen.html` | io_uring Phase 1-4 integration, including dispatcher-owned async `CreateFile` |
| `msg-ring-architecture.gen.html` | msg-ring v1 + v2 design notes |
| `nspa-local-file-architecture.gen.html` | NT-local file bypass (`NtCreateFile` short-circuit) |
| `shmem-ipc.gen.html` | NSPA shmem IPC primitives (γ + redraw + paint-cache) |
| `nspa-rt-test.gen.html` | nspa_rt_test PE harness reference |
| `architecture.gen.html` | Whole-system architecture overview |
| `decoration-loop-investigation.gen.html` | Wine 11.6 X11 windowing decoration-loop bug 57955 |
| `sync-primitives-research.gen.html` | Background research on sync primitive selection |

The architecture-heavy pieces added through 2026-04-30 are now covered
in the public docs set, including the gamma dispatcher, aggregate-wait,
hook cache, local-file, msg-ring, and the decomposition notes.

---

*Generated 2026-05-01. ntsync `10124FB81FDC76797EF1F91`, kernel
`6.19.11-rt1-1-nspa`.*
