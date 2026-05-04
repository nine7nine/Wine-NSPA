# Wine-NSPA — State of The Art

This page is the shipped-state snapshot: kernel patch state, live userspace
features, exact defaults and gates, targeted validation totals, and the
remaining work that is still ahead.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Current shipped state](#2-current-shipped-state)
3. [Active subsystems](#3-active-subsystems)
4. [Validation and performance](#4-validation-and-performance)
5. [Open work, in priority order](#5-open-work-in-priority-order)
6. [Recent landed arc](#6-recent-landed-arc-2026-04-30-to-2026-05-02)
7. [Configuration reference](#7-configuration-reference)
8. [Doc index](#8-doc-index)

---

## 1. Overview

The public 2026-05-02 state is no longer just "aggregate-wait plus a faster
dispatcher". Three larger client-side follow-ons shipped on top of that base:

- the **spawn-main + `ntdll_sched` substrate**, now default-on as the per-process
  client scheduler host via `NSPA_USE_SCHED_THREAD`
- the **local event / local timer / local WM_TIMER consolidation**, with
  anonymous events now client-range by default and the timer dispatchers moved
  onto the shared RT sched host when RT is available
- the **socket `io_uring` RECVMSG / SENDMSG path**, now default-on through
  `NSPA_URING_RECV=1` and `NSPA_URING_SEND=1`

The important architectural distinction is that these are not isolated feature
flags. They continue the same direction as gamma, local-file, msg-ring, and
the earlier timer work: move latency-sensitive common-case work out of the
single-threaded wineserver path while keeping honest fallback paths for
cross-process or server-authoritative semantics.

What the project looks like today: one small kernel overlay
(1003-1011 on top of upstream `ntsync`) plus a Wine fork that increasingly
routes work through kernel-mediated channels, client-range sync objects,
bounded shared-memory rings, local NT stubs, and per-process scheduler hosts,
all still gated so upstream-Wine behaviour remains available when the NSPA
paths are disabled.

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
| Client scheduler | spawn-main + `ntdll_sched`, default-class and RT-class consumers live |
| Async file path | async `CreateFile`, default ON |
| Async socket path | `io_uring` RECVMSG / SENDMSG, default ON |
| Memory surface | large pages, current-process `QueryWorkingSetEx`, and working-set quota bookkeeping shipped |
| Local sync path | anonymous events client-range by default; timers piggyback on that base |
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

### 2.4 2026-04-30 shipped defaults

| Feature | Default | Override | User-visible result |
|---|---|---|---|
| `NSPA_FLUSH_THROTTLE_MS` | `8` | `NSPA_FLUSH_THROTTLE_MS=N`; `=0` disables | `x11drv_surface_flush`: 8.23% -> 4.74% (−43%); `copy_rect_32` memmove: 4.38% -> 2.49% (−43%); MainThread CPU recovered: ~5.4 percentage points |
| `NSPA_ENABLE_ASYNC_CREATE_FILE` | `1` | `NSPA_ENABLE_ASYNC_CREATE_FILE=0` | routes `CreateFile` through the per-process `io_uring` ring, removing the `open()` lock-drop CS from the audio xrun path |
| `NSPA_TRY_RECV2` | `1` | `NSPA_TRY_RECV2=0` | On ntsync 1011 kernels, drains multiple channel entries per `AGG_WAIT` instead of N round-trips |

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

### 2.7 2026-05-02 shipped client-side follow-ons

| Feature | Default | Override | Shipped effect |
|---|---|---|---|
| `NSPA_USE_SCHED_THREAD` | `1` | `NSPA_USE_SCHED_THREAD=0` | spawn-main + `ntdll_sched` substrate is now engaged by default; first real consumer is the async close queue |
| `NSPA_SCHED_USE_FOR_WM_TIMER` | ON when RT available | `NSPA_SCHED_USE_FOR_WM_TIMER=0` | `local_wm_timer` dispatch moves onto shared `wine-sched-rt` instead of a dedicated RT helper thread |
| `NSPA_SCHED_USE_FOR_LOCAL_TIMER` | ON when RT available | `NSPA_SCHED_USE_FOR_LOCAL_TIMER=0` | `local_timer` dispatch moves onto shared `wine-sched-rt` instead of a dedicated RT helper thread |
| `NSPA_NT_LOCAL_EVENT` | `1` | `NSPA_NT_LOCAL_EVENT=0` | anonymous `NtCreateEvent` now uses the client-range fast path with server-side fd registration for async-completion signaling |
| `NSPA_URING_RECV` | `1` | `NSPA_URING_RECV=0` | `recv_socket` uses `IORING_OP_RECVMSG` on the shipped async socket path |
| `NSPA_URING_SEND` | `1` | `NSPA_URING_SEND=0` | `send_socket` uses `IORING_OP_SENDMSG` on the shipped async socket path |

Supporting shipped changes in the same arc:

| Change | Effect |
|---|---|
| client-range event async parity fix | server-side async queue path mirrors the `reset_event` discipline used for server events; smoke 0/1 with `NSPA_NT_LOCAL_EVENT=1` were clean with zero `err:service`, `err:rpc`, or `err:ole` errors |
| `NtCreateTimer` client-range backing event default ON | local timers stop paying a server-created event helper round-trip for anonymous backing events |
| local-file async close queue | eligible fully-shareable local-file closes leave the caller thread immediately and drain on `wine-sched` |
| sched observability sampler | shipped opt-in periodic sampler behind `NSPA_SCHED_OBS_INTERVAL_MS` |
| heap LFH carries | two LFH heuristic / retained-group carries shipped with smoke level 0 + 1 PASS; broader public validation still ahead |

### 2.8 Validation baseline against `10124FB81FDC76797EF1F91`

| Layer | Run | Result | Ops | Errors |
|---|---|---|---|---|
| Native suite | `run-rt-suite.sh native` | 3 PASS / 0 FAIL | `test-event-set-pi`, `test-channel-recv-exclusive`, `test-aggregate-wait` | 0 |
| Native aggregate | `test-aggregate-wait` | 9/9 PASS | kitchen-sink: 86,528 wakes / 0 timeouts / 0 errors | 0 |
| PE matrix | `nspa_rt_test.exe baseline+rt` | 24 PASS / 0 FAIL / 0 TIMEOUT | baseline + RT | 0 |
| PE dispatcher A/B | `dispatcher-burst` | PASS in matrix | steady-state 100k iters; burst 8 × 1000 × 64 = 512k ops | 0 |
| Busy-workload perf | Ableton 30s busy capture | PASS | `channel_dispatcher` 14.51% -> 0.70%; samples 38,588 -> 19,415 | 0 |

**Layer 1 totals: 3 PASS / 0 FAIL. Layer 2 totals: 24 PASS / 0 FAIL /
0 TIMEOUT. Module `10124FB81FDC76797EF1F91` was loaded live and
verified while these full-suite results were collected.**

NTSync kernel and Wine in-process sync detail lives on
`ntsync-driver.gen.html`; dispatcher and async-completion detail lives on
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
| **Open-path refactor** | Shipped | ON | `fchdir+open` → `openat`; first step toward holding `global_lock` for less of the open path. |
| **Open-path lock-drop** | Shipped | ON | Release `global_lock` around `openat()` so audio thread requests are not blocked by slow file syscalls during drum-load. |
| **Hook tier 1+2 cache** | Shipped | ON | Server-side cache rebuild + client cache reader; 26.7k/26.7k cache hit on Ableton 165s, `server_dispatch=0`. |
| **CS-PI v2.3** | Shipped | ON when `NSPA_RT_PRIO` set | Recursive `pi_mutex` extension on top of vendored librtpi; LockSemaphore field repurposed. |
| **Condvar PI requeue** | Shipped | ON when `NSPA_RT_PRIO` set | `FUTEX_WAIT_REQUEUE_PI`; `RtlSleepConditionVariableCS` slow path. |
| **librtpi vendoring** | Shipped | n/a | Header-only `rtpi.h` forwarder into the vendored library copy. |
| **NT-local file** (`nspa_local_file`) | Shipped | ON | `NtCreateFile` bypass for unix-name-resolvable paths, with 2026-04-30 sync-parity fixes for directory promotion and `FILE_MAPPING_WRITE` sharing. |
| **Client scheduler** (`wine-sched` / `wine-sched-rt`) | Shipped | ON | spawn-main + `ntdll_sched` substrate; default-class host plus lazy RT-class host, with `NSPA_USE_SCHED_THREAD=0` as the diagnostic override. |
| **NT-local event** | Shipped | ON | anonymous `NtCreateEvent` now routes to client-range handles by default, with server-side fd registration so async completion still signals correctly across wineserver-managed paths. |
| **NT-local timer** (`nspa_local_timer`) | Shipped | ON | anonymous NT timers now use client-range backing events by default and, when RT is available, dispatch on the shared `wine-sched-rt` host. |
| **NT-local WM timer** (`nspa_local_wm_timer`) | Shipped | ON | `SetTimer` userspace path; `TIMERPROC` + cross-thread cases defer to the server, while eligible local dispatch now shares the RT sched host instead of owning its own helper thread. |
| **Async local-file close queue** | Shipped | ON with sched enabled | eligible fully-shareable local-file closes defer unix `close()` + server `close_handle` onto `wine-sched`, removing close-path latency from the caller thread. |
| **msg-ring v1 (POST/SEND/REPLY)** | Shipped | ON | Bounded mpmc shmem ring for `PostMessage` / `SendMessage` / reply between Wine threads in the same process. |
| **msg-ring paint cache** | Shipped | ON | Cross-process redraw cache for `WM_PAINT`; `NSPA_ENABLE_PAINT_CACHE=0` is now the diagnostic opt-out, while the default shipped path stays on. |
| **Memory and large pages** | Shipped | ON where supported | `GetLargePageMinimum`, `VirtualAlloc(MEM_LARGE_PAGES)`, `CreateFileMapping(SEC_LARGE_PAGES)`, current-process `QueryWorkingSetEx`, and working-set quota bookkeeping are live with no NSPA gate. |
| **Direct `get_message` bypass** | **WIP, paused** | n/a | Remaining message-pump bypass piece; once it lands, window messages are fully out of wineserver. |
| **`io_uring` file I/O bypass** | Shipped | ON when `NSPA_RT_PRIO` set | sync poll replacement plus async `NtReadFile` / `NtWriteFile` bypass on the PE side. |
| **Aggregate-wait dispatcher** (`NSPA_AGG_WAIT`) | Shipped | ON | Per-process server-side `io_uring` infrastructure plus aggregate-wait dispatcher loop. Same RT thread receives requests, drains CQEs, and signals replies. |
| **Async `CreateFile`** | Shipped | ON | `NSPA_ENABLE_ASYNC_CREATE_FILE=1` routes `CreateFile` through the dispatcher-owned ring and removes the `open()` lock-drop critical section from the audio xrun path. |
| **`io_uring` socket recv/send** | Shipped | ON | `NSPA_URING_RECV=1` and `NSPA_URING_SEND=1`; deferred `socket-io` path now uses true socket SQEs instead of only poll-then-syscall. |
| **Wineserver `global_lock` PI** | Shipped | ON when `NSPA_RT_PRIO` set | `pthread_mutex` → `pi_mutex` on `global_lock`; CFS holders boost via PI chain when the boosted dispatcher contends. |
| **vDSO preloader (Jinoh Kang port)** | Shipped | ON | Full port minus the EHDR-unmap piece intentionally omitted on static-pie x86_64. |
| **NSPA priority mapping** | Shipped | ON when `NSPA_RT_PRIO` set | `fifo_prio = nspa_rt_prio_base - (31 - nt_band)`, clamped `[1..98]`; TIME_CRITICAL pinned to ceiling. |

### 3.3 Audio stack

| Component | Status | Brief |
|---|---|---|
| `winejack.drv` | Shipped | JACK-backed MIDI plus WASAPI audio in one driver |
| `nspaASIO` low-latency path | Shipped | Zero-latency `bufferSwitch` invoked **inside** the JACK RT callback — same-period output, no double-buffering hop |
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
    .cs-line { stroke: #7aa2f7; stroke-width: 1.3; }
  </style>

  <rect x="0" y="0" width="940" height="500" class="cs-bg"/>
  <text x="470" y="28" text-anchor="middle" class="cs-title">2026-05-02 deployment board: shipped state, diagnostics, and remaining work</text>

  <rect x="50" y="70" width="250" height="150" class="cs-green"/>
  <text x="175" y="96" text-anchor="middle" class="cs-tag-green">Kernel / sync substrate</text>
  <text x="175" y="122" text-anchor="middle" class="cs-label">NTSync 1003-1011</text>
  <text x="175" y="140" text-anchor="middle" class="cs-small">PI waits, channel IPC, aggregate-wait, TRY_RECV2</text>
  <text x="175" y="164" text-anchor="middle" class="cs-label">CS-PI + condvar PI</text>
  <text x="175" y="182" text-anchor="middle" class="cs-small">all RT paths gate on NSPA_RT_PRIO</text>

  <rect x="345" y="70" width="250" height="150" class="cs-green"/>
  <text x="470" y="96" text-anchor="middle" class="cs-tag-green">Client-side bypasses</text>
  <text x="470" y="122" text-anchor="middle" class="cs-label">gamma + spawn-main + local events</text>
  <text x="470" y="140" text-anchor="middle" class="cs-small">local-file, sched-hosted timers, hook cache, msg-ring v1</text>
  <text x="470" y="164" text-anchor="middle" class="cs-label">socket uring + async create_file shipped</text>
  <text x="470" y="182" text-anchor="middle" class="cs-small">more client-side work avoids wineserver entirely</text>

  <rect x="640" y="70" width="250" height="150" class="cs-green"/>
  <text x="765" y="96" text-anchor="middle" class="cs-tag-green">Audio stack</text>
  <text x="765" y="122" text-anchor="middle" class="cs-label">winejack.drv</text>
  <text x="765" y="140" text-anchor="middle" class="cs-small">MIDI + WASAPI on JACK</text>
  <text x="765" y="164" text-anchor="middle" class="cs-label">nspaASIO low-latency path</text>
  <text x="765" y="182" text-anchor="middle" class="cs-small">bufferSwitch in JACK RT callback</text>

  <rect x="50" y="270" width="250" height="140" class="cs-gate"/>
  <text x="175" y="296" text-anchor="middle" class="cs-tag-yellow">Diagnostics / A-B</text>
  <text x="175" y="322" text-anchor="middle" class="cs-label">force older paths for comparison</text>
  <text x="175" y="340" text-anchor="middle" class="cs-small">env overrides keep local-file, paint-cache, gamma, and uring A/B-able</text>
  <text x="175" y="364" text-anchor="middle" class="cs-label">runtime measurement toggles</text>
  <text x="175" y="382" text-anchor="middle" class="cs-small">kept for validation and regression isolation, not as the shipped default</text>

  <rect x="345" y="270" width="250" height="140" class="cs-wip"/>
  <text x="470" y="296" text-anchor="middle" class="cs-tag-violet">Paused / queued</text>
  <text x="470" y="322" text-anchor="middle" class="cs-label">direct get_message bypass</text>
  <text x="470" y="340" text-anchor="middle" class="cs-small">remaining message-pump bypass piece</text>
  <text x="470" y="364" text-anchor="middle" class="cs-label">sechost device-IRP poll</text>
  <text x="470" y="382" text-anchor="middle" class="cs-small">next substantial bypass candidate after the shipped 4.8 socket work</text>

  <rect x="640" y="270" width="250" height="140" class="cs-wip"/>
  <text x="765" y="296" text-anchor="middle" class="cs-tag-violet">Longer horizon</text>
  <text x="765" y="322" text-anchor="middle" class="cs-label">wineserver decomposition remainder</text>
  <text x="765" y="340" text-anchor="middle" class="cs-small">timer split + FD polling split around shipped aggregate-wait</text>
  <text x="765" y="364" text-anchor="middle" class="cs-label">residual server split</text>
  <text x="765" y="382" text-anchor="middle" class="cs-small">router / handler split plus lock partitioning</text>

  <line x1="175" y1="220" x2="175" y2="270" class="cs-line"/>
  <line x1="470" y1="220" x2="470" y2="270" class="cs-line"/>
  <line x1="765" y1="220" x2="765" y2="270" class="cs-line"/>
  <text x="470" y="456" text-anchor="middle" class="cs-small">top row = shipped state today; bottom row = diagnostics and remaining architecture work</text>
</svg>
</div>

---

## 4. Validation and performance

### 4.1 Full-suite baseline still in force

- ntsync module `10124FB81FDC76797EF1F91` against prod kernel
  `6.19.11-rt1-1-nspa`: 1003-1011 live, loaded, and verified clean.
- Native suite: **3 PASS / 0 FAIL** (`test-event-set-pi`,
  `test-channel-recv-exclusive`, `test-aggregate-wait`).
- `test-aggregate-wait`: **9/9 PASS**, including kitchen-sink
  `86,528 wakes / 0 timeouts / 0 errors`.
- `nspa_rt_test` PE matrix: **24 PASS / 0 FAIL / 0 TIMEOUT** (baseline + RT).
- `dispatcher-burst` remains the PE-side harness that exercises the gamma hot
  path directly.

The 2026-05-02 work did not publish a new full-suite version. What it added was
targeted validation for the newly-landed scheduler, timer, event, and socket
surfaces.

### 4.2 Targeted 2026-05-02 validation

| Surface | Validation | Result |
|---|---|---|
| spawn-main + sched base | Smoke 0 / 1 / 2 / 3 | PASS |
| spawn-main steady-state | Ableton playback | wineserver observed at `0.0%` CPU during playback |
| sched-RT migrations | `run-rt-probe-validation.sh` | `10/10 PASS` |
| sched-RT migrations | Smoke 0 / 1 | PASS |
| sched-RT migrations | Ableton boot + library + project load + playback | PASS |
| sched-RT migrations | runtime shape | net `-1` thread per process vs pre-migration layout |
| timer backing-event flip | smoke + RT probe + playback | clean; `63` threads stable, no sync / handle / timer errors |
| local events default-ON | Ableton boot + library + project load + `30s+` playback | clean |
| socket RECVMSG / SENDMSG default-ON | `socket-io` deferred path | `+6.5%` throughput, `-6.8%` p99 latency, `0/2000` failures |
| socket RECVMSG / SENDMSG default-ON | Ableton boot + library + playback | clean; `63` threads, zero new errors vs the earlier socket baseline |

### 4.3 Headline performance

#### Dispatcher tuning under Ableton busy workload

| Symbol | Before | After | Delta |
|---|---:|---:|---:|
| `channel_dispatcher` | 14.51% | 0.70% | −13.81pp / −95% |
| `main_loop_epoll` | 7.24% | 2.68% | −4.56pp |
| `nspa_queue_bypass_shm` | 2.77% | absent | inlined into call sites |
| `req_get_update_region` | 4.92% | absent | gone from top symbols |
| `nspa_redraw_ring_drain` | 2.88% | absent | gone from top symbols |

System-wide samples: `38,588 -> 19,415` per 30s.

#### `dispatcher-burst` A/B

| Metric | TRY_RECV2 on | TRY_RECV2 off | Delta |
|---|---:|---:|---:|
| burst ops/sec (wall) | 841,765 | 555,567 | +34% / 1.5x |
| burst worst max ns | 23,014,325 | 31,843,082 | −28% |
| steady avg ns | 35,202 | 33,405 | flat (no burst) |

#### X11 flush follow-ons

| Symbol | Before | After | Delta |
|---|---:|---:|---:|
| `x11drv_surface_flush` throttle | 8.23% | 4.74% | −43% |
| `copy_rect_32` memmove | 4.38% | 2.49% | −43% |
| `x11drv_surface_flush` AVX2 | 6.72% | 2.39% | −4.33pp / −64% |
| total `winex11.so` AVX2 | 6.76% | 2.43% | −4.33pp |
| total kernel after AVX2 | 10.22% | 8.58% | −1.64pp |

#### 2026-05-02 feature-specific wins

| Feature | Result |
|---|---|
| local events default-ON | Ableton system CPU from the earlier event baseline `40-57%` to `~35%` during playback (`~15-20%` reduction) |
| socket RECVMSG / SENDMSG | `socket-io` deferred path `+6.5%` throughput, `-6.8%` p99 latency, `0/2000` failures |

### 4.4 Residual caveats

- The last published full PE matrix is still the 2026-04-30 `24 PASS / 0 FAIL /
  0 TIMEOUT` run. The 2026-05-02 features are covered by targeted validation,
  not a new full-suite publish yet.
- Local events default-ON still exposes a known cosmetic log line in some
  Ableton runs: `wined3d_cs_destroy` "Closing present event failed". It is not
  currently associated with a functional failure or resource leak.
- The LFH carries shipped, but public validation is intentionally light so far:
  smoke level 0 + 1 only.

---

## 5. Open work, in priority order

1. **Longer paint-cache soak** — different day / cold start plus a
   longer runtime window so the default-on path has a cleaner public record.
2. **Full-suite rerun against the 2026-05-02 stack** — the last published
   matrix is still v8 / 2026-04-30; the new scheduler / event / socket surfaces
   deserve a fresh public matrix.
3. **Longer local-event and 4.8 socket soak** — targeted validations are clean;
   hours-scale default-on runtime is still worth publishing.
4. **`wine_sechost_service` device-IRP poll** — still the next obvious
   high-frequency bypass candidate.
5. **Direct `get_message` bypass** — paused mid-development; still
   the remaining message-pump bypass piece.
6. **Wineserver decomposition remainder** — aggregate-wait is already shipped;
   timer/fd-poll/router splits remain longer-horizon work.
7. **Wow64 clean rebuild** — 32-bit (i386) DLLs may be stale. Required for
   32-bit VST plugins and older games.

---

## 6. Recent landed arc (2026-04-30 to 2026-05-02)

| Date | Shipped work | Public result |
|---|---|---|
| 2026-04-30 | flush throttle + async `CreateFile` + `TRY_RECV2` | dispatcher hot path and MainThread flush cost both dropped materially |
| 2026-05-01 | winex11 AVX2 flush follow-on + Tier 1 log hygiene | lower GUI flush cost, cleaner logs, no semantic drift |
| 2026-05-02 | spawn-main + `ntdll_sched` substrate | one default scheduler host per process, plus lazy RT-class host |
| 2026-05-02 | async local-file close queue | caller thread stops paying eligible close latency inline |
| 2026-05-02 | sched-hosted `local_timer` + `local_wm_timer` | RT timer work consolidated onto shared `wine-sched-rt` |
| 2026-05-02 | `NtCreateTimer` client-range backing event default ON | anonymous timer backing events stop using the temporary server helper path |
| 2026-05-02 | local events default ON | anonymous events move client-side while async completion remains server-correct |
| 2026-05-02 | socket RECVMSG / SENDMSG default ON | `socket-io` deferred path gets a real `io_uring` data path, not just poll interception |

---

## 7. Configuration reference

### 7.1 Active env vars

| Var | Effect |
|---|---|
| `NSPA_RT_PRIO=80` | Master gate. Sets RT priority ceiling and activates all four PI paths. When unset, Wine-NSPA is byte-identical to upstream Wine. |
| `NSPA_RT_POLICY=FF` | SCHED_FIFO (vs RR). Same-prio RR quantum-slices the audio thread; FIFO eliminates. |
| `NSPA_OPENFD_LOCKDROP=1` | Open-path `openat()` lock-drop. **Default ON post-1006.** |
| `NSPA_DISPATCHER_USE_TOKEN=1` | Gamma T3 thread-token consumption in dispatcher. **Default ON.** |
| `NSPA_AGG_WAIT=1` | Aggregate-wait dispatcher loop. **Default ON post-1010 validation.** Set `0` to force the legacy direct receive loop. |
| `NSPA_TRY_RECV2=1` | Post-dispatch burst-drain on ntsync 1011 kernels. **Default ON.** Set `0` to force one `AGG_WAIT` round-trip per dequeued entry. |
| `NSPA_ENABLE_ASYNC_CREATE_FILE=1` | Async `CreateFile` through the dispatcher-owned ring. **Default ON.** Set `0` to stay on the older sync handler path. |
| `NSPA_USE_SCHED_THREAD=1` | Client scheduler host. **Default ON.** Set `0` to keep consumers on their older inline / dedicated-thread paths. |
| `NSPA_SCHED_USE_FOR_WM_TIMER=1` | Route `local_wm_timer` onto `wine-sched-rt` when RT is available. Set `0` to keep the legacy dedicated RT helper thread. |
| `NSPA_SCHED_USE_FOR_LOCAL_TIMER=1` | Route `local_timer` onto `wine-sched-rt` when RT is available. Set `0` to keep the legacy dedicated RT helper thread. |
| `NSPA_SCHED_OBS_INTERVAL_MS=N` | Opt-in sched observability sampler. Default OFF. Writes `/dev/shm/nspa-obs.<pid>` periodically. |
| `NSPA_NT_LOCAL_EVENT=1` | Anonymous `NtCreateEvent` client-range fast path. **Default ON.** Set `0` to force anonymous events back through wineserver. |
| `NSPA_FLUSH_THROTTLE_MS=8` | `flush_window_surfaces` throttle on `x11drv` MainThread. **Default ON at 8.** Set `N` to retune; `0` disables. |
| `NSPA_URING_RECV=1` | Socket RECVMSG `io_uring` path. **Default ON.** Set `0` to force the older recv path. |
| `NSPA_URING_SEND=1` | Socket SENDMSG `io_uring` path. **Default ON.** Set `0` to force the older send path. |
| `NSPA_ENABLE_PAINT_CACHE=1` | msg-ring paint cache. **Default ON.** Set `0` to force the older RPC path for A/B testing. |
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
| `current-state.md` | This document — state of the art on 2026-05-02 |
| `client-scheduler-architecture.gen.html` | spawn-main + `ntdll_sched`, default-class and RT-class scheduler hosts, and the shipped consumers routed through them |
| `cs-pi.gen.html` | Critical Section Priority Inheritance (CS-PI v2.3) — twelve-section deep dive |
| `condvar-pi-requeue.gen.html` | `RtlSleepConditionVariableCS` `FUTEX_WAIT_REQUEUE_PI` slow path |
| `aggregate-wait-and-async-completion.gen.html` | Aggregate-wait plus same-thread async completion architecture |
| `gamma-channel-dispatcher.gen.html` | Gamma request/reply transport plus post-1010 aggregate-wait dispatcher loop |
| `ntsync-driver.gen.html` | NTSync kernel overlay plus Wine in-process sync path, including aggregate-wait and `TRY_RECV2` |
| `io_uring-architecture.gen.html` | `io_uring` integration for file I/O, async `CreateFile`, and shipped socket RECVMSG / SENDMSG |
| `msg-ring-architecture.gen.html` | msg-ring v1 + v2 design notes |
| `memory-and-large-pages.gen.html` | large pages, working-set reporting, working-set quota bookkeeping, and shared-memory backing choices |
| `nspa-local-file-architecture.gen.html` | NT-local file bypass (`NtCreateFile` short-circuit) |
| `nt-local-stubs.gen.html` | NT-local stub pattern, now including local events and sched-hosted timer dispatch |
| `shmem-ipc.gen.html` | NSPA shmem IPC primitives (γ + redraw + paint-cache) |
| `nspa-rt-test.gen.html` | nspa_rt_test PE harness reference |
| `architecture.gen.html` | Whole-system architecture overview |
| `decoration-loop-investigation.gen.html` | Wine 11.6 X11 windowing decoration-loop bug 57955 |
| `sync-primitives-research.gen.html` | Background research on sync primitive selection |

The architecture-heavy pieces added through 2026-05-02 are now covered
in the public docs set, including the client scheduler, local events,
socket `io_uring`, gamma, aggregate-wait, hook cache, local-file,
msg-ring, and the decomposition notes.

---

*Generated 2026-05-03. State board reflects the shipped 2026-05-02 set. ntsync `10124FB81FDC76797EF1F91`, kernel
`6.19.11-rt1-1-nspa`.*
