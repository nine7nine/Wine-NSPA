# Wine-NSPA RT Test Harness

**Date:** 2026-04-30
**Author:** Jordan Johnston
**Kernel:** `6.19.11-rt1-1-nspa` (PREEMPT_RT_FULL)
**ntsync module:** `srcversion 10124FB81FDC76797EF1F91`
**Wine:** 11.6 + NSPA RT patchset
**Status:** public test-harness reference; Layer 1 native suite is 3 PASS / 0 FAIL and Layer 2 PE matrix is 24 PASS / 0 FAIL / 0 TIMEOUT as of 2026-04-30.

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [PE Subcommands (Layer 2)](#3-pe-subcommands-layer-2)
4. [Layer 1: native ntsync stress suite](#4-layer-1-native-ntsync-stress-suite)
5. [Test Runner](#5-test-runner)
6. [Watchdog and Safety](#6-watchdog-and-safety)
7. [Native Benchmarks](#7-native-benchmarks)
8. [Adding New Tests](#8-adding-new-tests)
9. [Environment Variables](#9-environment-variables)

---

## 1. Overview

The Wine-NSPA test surface is split into two layers:

- **Layer 1 -- native ntsync stress suite.** A small set of plain C
  programs at `wine/nspa/tests/test-*.c` that talk directly to
  `/dev/ntsync` ioctls. These exercise kernel-level invariants the
  Win32 surface can't reach (channels, EVENT_SET_PI, raw sched attrs,
  channel REPLY/cleanup races). Added during the 2026-04-26 -> 2026-04-28
  audit cycle.
- **Layer 2 -- `nspa_rt_test.exe`.** A multi-subcommand PE binary that
  validates the full Wine -> ntsync stack via Win32 APIs (RT scheduling,
  PI, sync primitives, io_uring, memory, process creation).

The combined runner `wine/nspa/tests/run-rt-suite.sh` drives both layers
and reports per-layer pass/fail. The Layer 2 PE matrix continues to be
driven by the existing `nspa/run_rt_tests.sh` runner.

As of 2026-04-30 the PE side has one new critical harness:
`dispatcher-burst`. It exists because the rest of the PE matrix mostly
exercises `inproc_wait` -> ntsync ioctls directly and does **not** hit
`channel_dispatcher` / `dispatch_channel_entry` / the TRY_RECV2 drain
loop. `dispatcher-burst` is the first PE-side workload in the published
matrix that covers that path.

The PE binary runs in two modes:

- **Baseline mode** (`WINEDEBUG=-all` only) -- no RT promotion, all
  threads SCHED_OTHER. Establishes reference behavior.
- **RT mode** (`NSPA_RT_PRIO=80 NSPA_RT_POLICY=FF
  WINEPRELOADREMAPVDSO=force`) -- full NSPA RT promotion active.
  TIME_CRITICAL threads become SCHED_FIFO, PI boost is active, the
  vDSO is remapped for RT-safe clock access.

### Validation Totals (2026-04-30)

- **Layer 1 native suite:** 3 PASS / 0 FAIL against module
  `10124FB81FDC76797EF1F91` (`test-event-set-pi`,
  `test-channel-recv-exclusive`, `test-aggregate-wait` 9/9 including
  kitchen-sink 86,528 wakes / 0 timeouts / 0 errors).
- **Layer 2 PE matrix:** 24 PASS / 0 FAIL / 0 TIMEOUT (12 tests x
  baseline + RT), including `dispatcher-burst`.

### Build

    i686-w64-mingw32-gcc -O2 -static programs/nspa_rt_test/main.c -o nspa_rt_test.exe -lws2_32

Native ntsync tests are built by `run-rt-suite.sh` on first invocation:

    cc -O2 -Wall -Wextra -o test-foo wine/nspa/tests/test-foo.c -lpthread

### Quick Run

    # Full two-layer suite (native + PE matrix):
    wine/nspa/tests/run-rt-suite.sh

    # Layer 1 only:
    wine/nspa/tests/run-rt-suite.sh native

    # Layer 2 only:
    wine/nspa/tests/run-rt-suite.sh wine

    # Single PE subcommand, RT mode:
    NSPA_RT_PRIO=80 NSPA_RT_POLICY=FF /usr/bin/wine nspa_rt_test.exe cs-contention

---

## 2. Architecture

The following diagram shows how `nspa_rt_test.exe` exercises each layer
of the Wine-NSPA stack. Each PE subcommand targets specific components.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 880 620" xmlns="http://www.w3.org/2000/svg">
  <style>
    .rt-box      { fill: #24283b; stroke: #3b4261; stroke-width: 1.5; rx: 6; }
    .rt-box-pe   { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 6; }
    .rt-box-ntdll{ fill: #1a1a2a; stroke: #7aa2f7; stroke-width: 2; rx: 6; }
    .rt-box-kern { fill: #2a1a1a; stroke: #f7768e; stroke-width: 2; rx: 6; }
    .rt-box-wine { fill: #24283b; stroke: #bb9af7; stroke-width: 1.5; rx: 6; }
    .rt-box-srv  { fill: #24283b; stroke: #e0af68; stroke-width: 1.5; rx: 6; }
    .rt-label    { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .rt-label-sm { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .rt-label-grn{ fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .rt-label-blu{ fill: #7aa2f7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .rt-label-red{ fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .rt-label-ylw{ fill: #e0af68; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .rt-label-pur{ fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .rt-label-cyn{ fill: #7dcfff; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .rt-arrow    { stroke: #9aa5ce; stroke-width: 1.5; fill: none; }
    .rt-arrow-grn{ stroke: #9ece6a; stroke-width: 1.5; fill: none; }
    .rt-arrow-blu{ stroke: #7aa2f7; stroke-width: 1.5; fill: none; }
    .rt-region   { fill: none; stroke: #3b4261; stroke-width: 1; stroke-dasharray: 5,3; rx: 8; }
  </style>

  <text x="440" y="22" class="rt-label-ylw" text-anchor="middle">nspa_rt_test.exe -- Test Architecture (PE binary to kernel)</text>

  <rect x="30" y="38" width="820" height="100" class="rt-region"/>
  <text x="50" y="56" class="rt-label-grn">PE Binary (Win32 user-space)</text>

  <rect x="50" y="62" width="150" height="62" rx="6" class="rt-box-pe"/>
  <text x="125" y="80" class="rt-label-grn" text-anchor="middle">nspa_rt_test.exe</text>
  <text x="125" y="94" class="rt-label-sm" text-anchor="middle">13 subcommands</text>
  <text x="125" y="107" class="rt-label-sm" text-anchor="middle">mingw PE static</text>

  <rect x="230" y="62" width="120" height="62" rx="6" class="rt-box"/>
  <text x="290" y="78" class="rt-label-cyn" text-anchor="middle">RT scheduling</text>
  <text x="290" y="92" class="rt-label-sm" text-anchor="middle">priority</text>
  <text x="290" y="104" class="rt-label-sm" text-anchor="middle">cs-contention</text>
  <text x="290" y="116" class="rt-label-sm" text-anchor="middle">rapidmutex</text>

  <rect x="370" y="62" width="120" height="62" rx="6" class="rt-box"/>
  <text x="430" y="78" class="rt-label-cyn" text-anchor="middle">PI chains</text>
  <text x="430" y="92" class="rt-label-sm" text-anchor="middle">philosophers</text>
  <text x="430" y="104" class="rt-label-sm" text-anchor="middle">ntsync (5 sub)</text>
  <text x="430" y="116" class="rt-label-sm" text-anchor="middle">srw-bench</text>

  <rect x="510" y="62" width="120" height="62" rx="6" class="rt-box"/>
  <text x="570" y="78" class="rt-label-cyn" text-anchor="middle">memory + proc</text>
  <text x="570" y="92" class="rt-label-sm" text-anchor="middle">large-pages</text>
  <text x="570" y="104" class="rt-label-sm" text-anchor="middle">signal-recursion</text>
  <text x="570" y="116" class="rt-label-sm" text-anchor="middle">fork-mutex</text>

  <rect x="650" y="62" width="120" height="62" rx="6" class="rt-box"/>
  <text x="710" y="78" class="rt-label-cyn" text-anchor="middle">io_uring + gamma</text>
  <text x="710" y="92" class="rt-label-sm" text-anchor="middle">socket-io</text>
  <text x="710" y="104" class="rt-label-sm" text-anchor="middle">dispatcher-burst</text>
  <text x="710" y="116" class="rt-label-sm" text-anchor="middle">Phase 4 create_file</text>

  <rect x="30" y="160" width="820" height="130" class="rt-region"/>
  <text x="50" y="178" class="rt-label-blu">Wine ntdll Unix layer</text>

  <rect x="50" y="185" width="145" height="90" rx="6" class="rt-box-ntdll"/>
  <text x="122" y="200" class="rt-label-blu" text-anchor="middle">sync.c</text>
  <text x="122" y="214" class="rt-label-sm" text-anchor="middle">CriticalSection</text>
  <text x="122" y="226" class="rt-label-sm" text-anchor="middle">CS-PI (FUTEX_LOCK_PI)</text>
  <text x="122" y="238" class="rt-label-sm" text-anchor="middle">manual PI boost v2.5</text>
  <text x="122" y="250" class="rt-label-sm" text-anchor="middle">SRW lock</text>

  <rect x="215" y="185" width="145" height="90" rx="6" class="rt-box-ntdll"/>
  <text x="287" y="200" class="rt-label-blu" text-anchor="middle">thread.c</text>
  <text x="287" y="214" class="rt-label-sm" text-anchor="middle">RT priority mapping</text>
  <text x="287" y="226" class="rt-label-sm" text-anchor="middle">SCHED_FIFO/RR/OTHER</text>
  <text x="287" y="238" class="rt-label-sm" text-anchor="middle">sched_setattr_nocheck</text>
  <text x="287" y="250" class="rt-label-sm" text-anchor="middle">Tier 1 / REALTIME class</text>

  <rect x="380" y="185" width="145" height="90" rx="6" class="rt-box-ntdll"/>
  <text x="452" y="200" class="rt-label-blu" text-anchor="middle">virtual.c</text>
  <text x="452" y="214" class="rt-label-sm" text-anchor="middle">virtual_mutex (recursive)</text>
  <text x="452" y="226" class="rt-label-sm" text-anchor="middle">VirtualAlloc large pages</text>
  <text x="452" y="238" class="rt-label-sm" text-anchor="middle">MAP_HUGETLB + MAP_LOCKED</text>
  <text x="452" y="250" class="rt-label-sm" text-anchor="middle">PAGE_GUARD fault handler</text>

  <rect x="545" y="185" width="145" height="90" rx="6" class="rt-box-ntdll"/>
  <text x="617" y="200" class="rt-label-blu" text-anchor="middle">io_uring.c</text>
  <text x="617" y="214" class="rt-label-sm" text-anchor="middle">per-thread rings</text>
  <text x="617" y="226" class="rt-label-sm" text-anchor="middle">TLS pool allocator</text>
  <text x="617" y="238" class="rt-label-sm" text-anchor="middle">COOP_TASKRUN</text>
  <text x="617" y="250" class="rt-label-sm" text-anchor="middle">Phase 1 file I/O bypass</text>

  <rect x="710" y="185" width="120" height="90" rx="6" class="rt-box-ntdll"/>
  <text x="770" y="200" class="rt-label-blu" text-anchor="middle">process.c</text>
  <text x="770" y="214" class="rt-label-sm" text-anchor="middle">CreateProcess</text>
  <text x="770" y="226" class="rt-label-sm" text-anchor="middle">posix_spawn</text>
  <text x="770" y="238" class="rt-label-sm" text-anchor="middle">librtpi sweep</text>
  <text x="770" y="250" class="rt-label-sm" text-anchor="middle">opt-out (EXCLUDE)</text>

  <rect x="30" y="310" width="280" height="80" class="rt-region"/>
  <text x="50" y="328" class="rt-label-pur">wineserver</text>

  <rect x="50" y="335" width="240" height="45" rx="6" class="rt-box-wine"/>
  <text x="170" y="352" class="rt-label-pur" text-anchor="middle">wineserver + gamma dispatcher</text>
  <text x="170" y="366" class="rt-label-sm" text-anchor="middle">AGG_WAIT | TRY_RECV2 | process registration | mapping</text>

  <rect x="330" y="310" width="520" height="80" class="rt-region"/>
  <text x="350" y="328" class="rt-label-red">Linux kernel (6.19.x-rt)</text>

  <rect x="350" y="335" width="120" height="45" rx="6" class="rt-box-kern"/>
  <text x="410" y="352" class="rt-label-red" text-anchor="middle">/dev/ntsync</text>
  <text x="410" y="366" class="rt-label-sm" text-anchor="middle">PI + prio wakeup</text>

  <rect x="490" y="335" width="120" height="45" rx="6" class="rt-box-kern"/>
  <text x="550" y="352" class="rt-label-red" text-anchor="middle">futex_lock_pi</text>
  <text x="550" y="366" class="rt-label-sm" text-anchor="middle">CS-PI path</text>

  <rect x="630" y="335" width="100" height="45" rx="6" class="rt-box-kern"/>
  <text x="680" y="352" class="rt-label-red" text-anchor="middle">io_uring</text>
  <text x="680" y="366" class="rt-label-sm" text-anchor="middle">SQ/CQ rings</text>

  <rect x="750" y="335" width="80" height="45" rx="6" class="rt-box-kern"/>
  <text x="790" y="352" class="rt-label-red" text-anchor="middle">hugetlbfs</text>
  <text x="790" y="366" class="rt-label-sm" text-anchor="middle">2MB/1GB</text>

  <line x1="290" y1="124" x2="122" y2="185" class="rt-arrow-grn"/>
  <line x1="290" y1="124" x2="287" y2="185" class="rt-arrow-grn"/>
  <line x1="430" y1="124" x2="122" y2="185" class="rt-arrow-grn"/>
  <line x1="430" y1="124" x2="287" y2="185" class="rt-arrow-grn"/>
  <line x1="570" y1="124" x2="452" y2="185" class="rt-arrow-grn"/>
  <line x1="570" y1="124" x2="770" y2="185" class="rt-arrow-grn"/>
  <line x1="710" y1="124" x2="617" y2="185" class="rt-arrow-grn"/>

  <line x1="122" y1="275" x2="550" y2="335" class="rt-arrow-blu"/>
  <line x1="122" y1="275" x2="410" y2="335" class="rt-arrow-blu"/>
  <line x1="617" y1="275" x2="680" y2="335" class="rt-arrow-blu"/>
  <line x1="452" y1="275" x2="790" y2="335" class="rt-arrow-blu"/>
  <line x1="770" y1="275" x2="170" y2="335" class="rt-arrow-blu"/>

  <rect x="30" y="420" width="820" height="80" class="rt-region"/>
  <text x="50" y="438" class="rt-label-ylw">run-rt-suite.sh + run_rt_tests.sh -- two-layer orchestration</text>

  <rect x="50" y="445" width="180" height="45" rx="6" class="rt-box-srv"/>
  <text x="140" y="462" class="rt-label-ylw" text-anchor="middle">Layer 1 native</text>
  <text x="140" y="476" class="rt-label-sm" text-anchor="middle">/dev/ntsync ioctl tests</text>

  <line x1="230" y1="467" x2="280" y2="467" class="rt-arrow"/>

  <rect x="280" y="445" width="180" height="45" rx="6" class="rt-box-srv"/>
  <text x="370" y="462" class="rt-label-ylw" text-anchor="middle">Layer 2 PE matrix</text>
  <text x="370" y="476" class="rt-label-sm" text-anchor="middle">baseline + RT modes</text>

  <line x1="460" y1="467" x2="510" y2="467" class="rt-arrow"/>

  <rect x="510" y="445" width="180" height="45" rx="6" class="rt-box-srv"/>
  <text x="600" y="462" class="rt-label-ylw" text-anchor="middle">summary matrix</text>
  <text x="600" y="476" class="rt-label-sm" text-anchor="middle">per-test PASS/FAIL/TIMEOUT</text>

  <rect x="30" y="520" width="820" height="90" class="rt-region"/>
  <text x="50" y="540" class="rt-label" font-weight="bold">Legend</text>
  <rect x="50" y="550" width="14" height="14" fill="#1a2a1a" stroke="#9ece6a" stroke-width="2" rx="3"/>
  <text x="72" y="562" class="rt-label-sm">PE test binary</text>
  <rect x="180" y="550" width="14" height="14" fill="#1a1a2a" stroke="#7aa2f7" stroke-width="2" rx="3"/>
  <text x="202" y="562" class="rt-label-sm">ntdll Unix layer</text>
  <rect x="320" y="550" width="14" height="14" fill="#2a1a1a" stroke="#f7768e" stroke-width="2" rx="3"/>
  <text x="342" y="562" class="rt-label-sm">Linux kernel</text>
  <rect x="450" y="550" width="14" height="14" fill="#24283b" stroke="#bb9af7" stroke-width="1.5" rx="3"/>
  <text x="472" y="562" class="rt-label-sm">wineserver</text>
  <rect x="570" y="550" width="14" height="14" fill="#24283b" stroke="#e0af68" stroke-width="1.5" rx="3"/>
  <text x="592" y="562" class="rt-label-sm">runner / orchestration</text>
  <line x1="50" y1="582" x2="80" y2="582" class="rt-arrow-grn"/>
  <text x="88" y="586" class="rt-label-sm">test -> ntdll</text>
  <line x1="180" y1="582" x2="210" y2="582" class="rt-arrow-blu"/>
  <text x="218" y="586" class="rt-label-sm">ntdll -> kernel</text>
</svg>
</div>

### Layered Validation

Each PE subcommand targets a specific cross-section of the stack:

| Test | ntdll component | Kernel mechanism | What breaks if the component regresses |
|------|----------------|-----------------|----------------------------------------|
| priority | thread.c | sched_setattr | Wrong FIFO priorities, threads stay TS |
| cs-contention | sync.c (CS-PI) | futex_lock_pi | RT thread starved behind SCHED_OTHER holder |
| rapidmutex | sync.c (CS fast path) | futex_lock_pi | Throughput collapse, RT max_wait unbounded |
| philosophers | sync.c (transitive PI) | futex_lock_pi | Deadlock or starvation in PI chain |
| ntsync | ntsync client | /dev/ntsync | PI not firing, wrong wakeup order |
| dispatcher-burst | gamma dispatcher + server-side io_uring | `/dev/ntsync` channel + aggregate-wait + TRY_RECV2 | dispatcher hot path regresses with no PE-side coverage |
| socket-io | io_uring.c | io_uring | Async recv latency regression |
| signal-recursion | virtual.c | segv_handler | Deadlock in recursive mutex path |
| large-pages | virtual.c | hugetlbfs | Silent fallback to 4KB pages |
| fork-mutex | process.c | posix_spawn | Child hangs from corrupted mutex |
| srw-bench | sync.c (SRW) | futex | Acquire latency regression |

---

## 3. PE Subcommands (Layer 2)

### Summary Table

| # | Subcommand | Tests | Key Metrics | NSPA Component |
|---|-----------|-------|-------------|----------------|
| 1 | `priority` | RT priority mapping (11 threads, 2 phases) | Thread scheduling class + FIFO priority | thread.c RT mapping |
| 2 | `cs-contention` | CS-PI under SCHED_FIFO vs SCHED_OTHER | wait time (ms), samples captured | sync.c CS-PI |
| 3 | `rapidmutex` | CS throughput stress (1 RT + N-1 load) | ops/sec, max_wait (us), counter integrity | sync.c CS fast path |
| 4 | `philosophers` | Dining philosophers with transitive PI | meals/phil, RT max_wait (us), spread | sync.c transitive PI |
| 5 | `fork-mutex` | Rapid CreateProcess stress (N spawns) | spawn time, exit code, success rate | process.c opt-out |
| 6 | `signal-recursion` | PAGE_GUARD fault stress (N threads) | iters completed, fault count, elapsed | virtual.c recursive mutex |
| 7 | `large-pages` | VirtualAlloc(MEM_LARGE_PAGES) 2MB + PAGEMAP | HugePages_Free delta, LargePage flag | virtual.c large pages |
| 8 | `ntsync` | 5 sub-tests: rapid mutex, PI, prio, chain, WFMO | per-sub PASS/FAIL, wait times | /dev/ntsync driver |
| 9 | `socket-io` | TCP loopback: immediate + deferred recv | latency (us) p50/p95/p99/max, msgs/sec | io_uring (Phase 2 surface) |
| 10 | `srw-bench` | SRW lock contention benchmark | acquire latency (ns) p50/p99/max, ops/sec | sync.c SRW |
| 11 | `dispatcher-burst` | Gamma dispatcher A/B harness (`CreateFile` / `CloseHandle` on `NUL`) | burst ops/sec, worst max ns, steady avg ns | gamma dispatcher + Phase 4 `create_file` |
| 12 | `child-quickexit` | Internal helper for fork-mutex | exit code 42 | (internal) |
| 13 | `help` | Usage display | -- | -- |

### 3.1 `priority` -- RT Priority Mapping

Spawns 11 worker threads across two phases, each sleeping long enough
for external inspection via `ps` and `chrt`.

- Phase 1 (3 threads, default process class): `P1-TC` TIME_CRITICAL
  expected FF 80, `P1-MCSS` via avrt expected FF 80, `P1-NORM` NORMAL
  expected TS or FF 73 under RT class.
- Phase 2 (8 threads, after `SetPriorityClass(REALTIME_PRIORITY_CLASS)`):
  IDLE FF 65, LOWEST FF 71, BELOW_NORMAL FF 72, NORMAL FF 73,
  ABOVE_NORMAL FF 74, HIGHEST FF 75, TIME_CRITICAL FF 80.

PASS criteria: all threads spawned and `SetPriorityClass(REALTIME)`
succeeded. Skipped by the runner by default (sleeps 10s for
observation).

### 3.2 `cs-contention` -- CS-PI Validation

RT thread (TIME_CRITICAL) blocks on a CS held by a SCHED_OTHER thread
while background SCHED_OTHER load threads compete. With PI, the holder
is boosted for the duration of the hold, so the RT thread's wait time
approximates the holder's uncontended work time. Without PI, the
holder is preempted by load and the RT thread waits much longer.

Key metrics: min/max/avg wait time. PASS criteria: all CS_ITERATIONS
samples captured (no deadlock, no lost wakeup).

### 3.3 `rapidmutex` -- CS Throughput Stress

N threads (default 4) hammer a shared CS in a tight EnterCS/LeaveCS
loop. Thread 0 is TIME_CRITICAL; others are NORMAL. PASS criteria:
`shared_counter == N * iters` and no errors.

### 3.4 `philosophers` -- Dining Philosophers / Transitive PI

5 philosophers share 5 chopsticks. Phil 0 is TIME_CRITICAL; phils 1-4
are load. Background SCHED_OTHER busyloops starve the OTHER phils.
Transitive PI must propagate from RT through phils 1..N to the tail
holder. PASS criteria: all philosophers complete the target meal
count within timeout (60s).

### 3.5 `fork-mutex` -- CreateProcess Stress

Spawns N copies of itself (default 100) via `CreateProcess` running
the internal `child-quickexit` subcommand, waits, and verifies exit
code 42.

Catches: librtpi-sweep regression on `process.c`,
`pthread_atfork` regression, CreateProcess race / handle leak,
wineserver process-table overflow, posix_spawn regression under RT.

### 3.6 `signal-recursion` -- Guard-Page Fault Stress

N threads (default 4) repeatedly: alloc 2-page region, set PAGE_GUARD
on first page, touch (triggers STATUS_GUARD_PAGE_VIOLATION ->
SIGSEGV -> segv_handler -> virtual_handle_fault), catch via VEH,
verify accessible, free.

Catches: `virtual_mutex` self-re-entry deadlock, broken PAGE_GUARD
clear-on-first-access, alloc/free race with fault handler, wrong-thread
signal delivery.

### 3.7 `large-pages` -- VirtualAlloc(MEM_LARGE_PAGES)

`RtlAdjustPrivilege(SE_LOCK_MEMORY_PRIVILEGE)` ->
`VirtualAlloc(MEM_LARGE_PAGES)` -> `/proc/meminfo` cross-check ->
page touch round-trip -> `K32QueryWorkingSetEx` PAGEMAP_SCAN
LargePage-flag check -> `VirtualFree` -> verify `HugePages_Free`
restored.

Skip conditions (PASS): meminfo not readable, `HugePages_Total == 0`,
`GetLargePageMinimum == 0`, RtlAdjustPrivilege fails.

### 3.8 `ntsync` -- NTSync Kernel Driver Validation

5 sub-tests: mutex PI contention, rapid kernel mutex throughput,
priority-ordered wakeup, transitive PI chain, mixed WFMO (WAIT_ANY +
WAIT_ALL with heterogeneous object types). Probes CreateMutex handle
range to confirm ntsync client path is active (handles >= 2,080,000).

Runner configurations:

- `ntsync-d4`: depth 4, 4 rapid threads, 100K iters, 8 PI iters, 5 prio waiters
- `ntsync-d8`: depth 8, 4 rapid threads, 100K iters, 3 PI iters, 10 prio waiters
- `ntsync-d12`: depth 12, 8 rapid threads, 50K iters, 3 PI iters, 16 prio waiters

PASS criteria: all 5 sub-tests plus 5a-5d PASS.

### 3.9 `socket-io` -- Async TCP Loopback Latency

TCP loopback pair, per-message recv latency via overlapped WSARecv.

- **Phase A immediate:** sender sends *before* receiver calls WSARecv.
  Exercises `try_recv` fast path.
- **Phase B deferred:** receiver calls WSARecv *before* sender sends.
  Forces the async wait path: WSARecv returns `WSA_IO_PENDING`. With
  io_uring Phase 2 (sockets) enabled, this exercises the
  POLL_ADD/CQE/try_recv interception path.

PASS criteria: both phases complete without recv errors.

The current public matrix is functionally green on this path in both
baseline and RT modes. Dispatcher-specific tuning is validated by
`dispatcher-burst`; `socket-io` remains its own correctness surface
rather than the main gamma performance harness.

### 3.10 `srw-bench` -- SRW Lock Contention Benchmark

N threads acquire/release a shared SRWLOCK in exclusive mode in a
tight loop. Per-thread metrics: avg, p50, p99, max acquire latency
(ns), ops/sec.

### 3.11 `dispatcher-burst` -- Gamma Dispatcher A/B Harness

Two sub-tests hammer `CreateFile` / `CloseHandle` on `NUL` specifically
to cover the gamma dispatcher hot path:

- **steady-state:** 1 thread, 100k iters, single open+close
- **burst:** 8 threads × 1000 outer × 64-handle fanout = 512k ops

The verdict is failure-count only; latency is observational. That
keeps the test deterministic enough to live in the default matrix while
still giving a reproducible A/B for `NSPA_TRY_RECV2`. The subcommand
landed in [`f087a265`](https://github.com/nine7nine/Wine-NSPA/commit/f087a265)
and was wired into the default PE matrix by
[`343d7ac2`](https://github.com/nine7nine/Wine-NSPA/commit/343d7ac2).
The later dispatcher hot-path tuning commits continue to use this same
subcommand as their PE-side oracle.

Published 2026-04-30 observations:

- burst ops/sec (wall): `841,765` with TRY_RECV2 on vs `555,567` with
  TRY_RECV2 off (`+34% / 1.5x`)
- burst worst max ns: `23,014,325` with TRY_RECV2 on vs `31,843,082`
  with TRY_RECV2 off (`-28%`)
- steady avg ns: `35,202` with TRY_RECV2 on vs `33,405` with TRY_RECV2
  off (flat in the no-burst case)
- default matrix runtime contribution: `~7s wall`

### 3.12 / 3.13 -- internal `child-quickexit` and `help`

---

## 4. Layer 1: native ntsync stress suite

Added during the 2026-04-26 -> 2026-04-28 audit cycle. These are plain
C programs that talk directly to `/dev/ntsync` ioctls, exercising
kernel-level invariants the Win32 surface can't reach. Located at
`wine/nspa/tests/test-*.c`. Built on first invocation of
`run-rt-suite.sh`.

### Test Inventory

| Test | What it stresses | Why it exists |
|------|-----------------|---------------|
| `test-event-set-pi.c` | EVENT_SET_PI sanity (modified for ready-flag handshake) | Baseline event-PI signal/wake pair, asserts the deferred-boost path lands |
| `test-event-set-pi-stress.c` | 8x8 EVENT_SET_PI hammer | Stresses the EVENT_SET_PI path for the slab UAF that 1008 closed |
| `test-channel-recv-exclusive.c` | Symmetric cleanup on channel RECV | Reproduces the channel RECV hang root-caused on 2026-04-27 (Bug 2: pre-1007 wake-all in SEND_PI) |
| `test-mutex-pi-stress.c` | Mutex contention + Tier B FIFO | Stresses ntsync mutex PI under high contention with FIFO competition |
| `test-channel-stress.c` | Channel SEND_PI + RECV + REPLY + register churn | Catches channel REPLY/cleanup UAFs (Bug 4 from 2026-04-27, fixed by patch 1009 channel_entry refcount) |
| `test-mixed-load-stress.c` | Full driver coverage (events SET/RESET/PI/PULSE + mutex + sem + chan + wait_all) | 5-min mixed-load soak across all driver paths; the integration test |
| `run-rt-suite.sh` | Layer 1 native + Layer 2 PE matrix runner | Integrates both layers; prints SKIPPED_BY_DESIGN list |

### SKIPPED_BY_DESIGN list

`run-rt-suite.sh` excludes two tests from the active run because they
assert behaviour that was rolled back (the 1007-1011 patch series shipped
as "audit findings" without a confirmed bug -- see memory entry
`feedback_dont_shotgun_audit_into_unfound_bug`):

- `test-cross-boost` -- asserts 1007 cross-boost cleanup
- `test-wait-rejects-channel` -- asserts 1007 channel-reject in
  `setup_wait`

These are kept on disk and excluded from the suite list. Re-enable
only if a future ntsync change makes their invariants real. Keeping
the source around documents what we tried and why it was reverted.

### Run

    cd wine/nspa/tests
    ./run-rt-suite.sh native     # Layer 1 only
    ./run-rt-suite.sh wine       # Layer 2 only
    ./run-rt-suite.sh all        # both (default)

### Validation Totals (2026-04-30)

The current ntsync module (`srcversion 10124FB81FDC76797EF1F91`) keeps
all four post-debug-kernel bugs fixed and adds the 1011
`CHANNEL_TRY_RECV2` follow-on:

- Bug 1: test cleanup asymmetry stranding R1 in
  `test-channel-recv-exclusive` (test-side, fixed)
- Bug 2: pre-1007 wake-all in SEND_PI (real production priority
  inversion, fixed by 1007-style narrow patch: `wait_event_interruptible_exclusive`
  + `wake_up_interruptible` in CHANNEL_RECV)
- Bug 3: EVENT_SET_PI deferred-boost (1008 patch)
- Bug 4: channel_entry refcount UAF caught by KASAN in
  `test-channel-stress` (1009 patch)

Cumulative public result for 2026-04-30:

- Layer 1 native suite: 3 PASS / 0 FAIL
- Layer 2 PE matrix: 24 PASS / 0 FAIL / 0 TIMEOUT
- `test-aggregate-wait`: 9/9 PASS with kitchen-sink 86,528 wakes / 0
  timeouts / 0 errors
- zero syscall errors, zero KASAN/dmesg splats

### Layer 2 PE Matrix

The PE matrix (`nspa_rt_test.exe` baseline + RT) now passes
24 PASS / 0 FAIL / 0 TIMEOUT (12 tests x 2 modes) on the current
build. The new row is `dispatcher-burst`, which is the first PE-side
matrix test that actually covers the dispatcher hot path.

---

## 5. Test Runner

### Two-Layer Runner: `wine/nspa/tests/run-rt-suite.sh`

Drives Layer 1 (native ntsync ioctl tests) and Layer 2 (PE matrix via
delegation to `wine/nspa/run_rt_tests.sh`):

    Usage: ./run-rt-suite.sh [native|wine|all]   (default: all)

Layer 1 builds each test if its source is newer than the binary,
checks `/dev/ntsync` accessibility, prints the SKIPPED_BY_DESIGN list,
and runs each `NATIVE_TESTS[]` entry. Aggregates pass/fail/skip and
returns the fail count.

Layer 2 invokes `nspa/run_rt_tests.sh` with the existing baseline + RT
matrix.

### Layer 2 Runner: `nspa/run_rt_tests.sh`

Orchestrates the PE matrix. Runs every configured subcommand twice --
once in baseline mode and once in RT mode -- captures per-run logs,
parses the binary's PASS/FAIL verdict line, and prints a summary.

### Test List Configuration

The runner script defines the test list as an array. Each entry is:
`"display_name subcmd [args...]"`.

    tests=(
        "rapidmutex rapidmutex 4 500000"
        "philosophers philosophers 50 4"
        "fork-mutex fork-mutex 100"
        "cs-contention cs-contention"
        "signal-recursion signal-recursion 4 500"
        "large-pages large-pages"
        "ntsync-d4 ntsync 4 4 100000 8 5"
        "ntsync-d8 ntsync 8 4 100000 3 10"
        "ntsync-d12 ntsync 12 8 50000 3 16"
        "socket-io socket-io"
        "srw-bench srw-bench 4 500000"
        "dispatcher-burst dispatcher-burst"
    )

The `priority` subcommand is included only when `INCLUDE_PRIORITY=1`.

### Verdict Resolution

The runner determines each test's verdict in this priority order:

1. **Timeout** (`rc=124` or `rc=137`) -> `TIMEOUT`
2. **Explicit PASS** (line matching `^  PASS\s*$` in stdout) -> `PASS`
3. **Explicit FAIL** (line matching `^  FAIL` in stdout) -> `FAIL`
4. **Implicit** (no verdict line): `rc=0` -> `PASS*`, else
   `FAIL* (rc=N)`

The `*` marker distinguishes tests that emitted an explicit verdict
from those relying on exit code.

### Log File Structure

All logs are written to `$LOG_DIR` (default `/tmp/nspa_rt_test_logs/`):

    /tmp/nspa_rt_test_logs/
      baseline_rapidmutex.log
      baseline_philosophers.log
      ...
      rt_rapidmutex.log
      rt_philosophers.log
      ...

### Environment Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `WINE` | `/usr/bin/wine` | Wine binary path |
| `WINEPREFIX` | `/home/ninez/Winebox/winebox-master` | Wine prefix |
| `TEST_EXE` | `nspa_rt_test.exe` | PE binary path (searched in Wine lib dirs) |
| `LOG_DIR` | `/tmp/nspa_rt_test_logs` | Per-run log output directory |
| `TIMEOUT_SECS` | `120` | Per-test timeout (seconds) |
| `RT_PRIO` | `80` | NSPA_RT_PRIO for RT mode |
| `RT_POLICY` | `FF` | NSPA_RT_POLICY for RT mode |
| `INCLUDE_PRIORITY` | `0` | Set to `1` to include the `priority` subcommand |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All runs PASS |
| 1 | At least one FAIL, TIMEOUT, or UNKNOWN |
| 2 | Prerequisites missing (test binary not built, Wine not found) |

---

## 6. Watchdog and Safety

### Watchdog Timer

Every PE subcommand runs with a watchdog timer armed on entry. The
watchdog is a dedicated thread at `THREAD_PRIORITY_TIME_CRITICAL` that
calls `ExitProcess(99)` after a configurable timeout.

- **Default timeout:** 120 seconds
- **Override:** `NSPA_TEST_TIMEOUT=N` environment variable (seconds)
- **Thread priority:** TIME_CRITICAL -- ensures the watchdog can
  preempt stuck SCHED_FIFO threads

The watchdog is the *inner* safety net. The runner script's
`timeout --kill-after=5` is the *outer* safety net at the shell level.
Together they guarantee that no test can hang indefinitely, even if
SCHED_FIFO busyloop threads have saturated all cores.

### Ctrl+C Handler

A `SetConsoleCtrlHandler` callback is registered before any
subcommand runs. On Ctrl+C: sets all known stop flags
(`g_global_abort`, `g_stop_load`, `phil_load_stop`,
`nts_pi_stop_load`, `nts_chain_stop_load`), sleeps 500 ms to let
threads notice, then calls `ExitProcess(1)`.

### Stop Flag Architecture

Each subcommand uses its own volatile `LONG` stop flag, checked by
busyloop threads via `InterlockedCompareExchange`. All flags are set
atomically by both the Ctrl+C handler and the watchdog's
`ExitProcess` path.

### Runner-Level Safety

- **Per-test cleanup:** `cleanup_stale` runs between every test, using
  `pgrep -f '[n]spa_rt_test\.exe$'` with the bracket trick to avoid
  self-matching. First pass SIGTERM, second pass SIGKILL.
- **Timeout wrapper:** `timeout --kill-after=5 $TIMEOUT_SECS` wraps
  each Wine invocation. If the test ignores SIGTERM, SIGKILL arrives
  5 seconds later.

---

## 7. Native Benchmarks

### `pi_cond_bench.c` -- Requeue-PI Condvar Benchmark

A native Linux benchmark (not a Wine program) that measures condvar
signal-to-wake latency under RT priority contention. Located at
`wine/nspa/tests/pi_cond_bench.c`.

An RT waiter (SCHED_FIFO) sleeps on a pi_cond. A normal-priority
signaler signals it after a delay. Background load threads compete
for CPU. With requeue-PI, the wake-to-mutex-reacquire is atomic
(kernel-side). Without it, there is a gap where no PI boost is in
effect.

Build:

    gcc -O2 -o pi_cond_bench wine/nspa/tests/pi_cond_bench.c -lpthread -I../../libs/librtpi

Run:

    sudo chrt -f 80 ./pi_cond_bench [iterations] [load_threads]
    # Default: 10000 iterations, 4 load threads

Output: wake latency histogram (avg, p50, p99, max in nanoseconds).
Validates the underlying kernel requeue-PI mechanism Wine-NSPA's
condvar path depends on. Running outside Wine isolates kernel
behaviour from Wine's ntdll layer.

---

## 8. Adding New Tests

### Step 1: Write the Command Function

In `programs/nspa_rt_test/main.c`:

    static int cmd_foo(int argc, char **argv)
    {
        print_banner("foo", "description of what foo tests");
        print_section("parameters");
        /* ... test logic ... */

        if (success) {
            print_verdict(1, NULL);  /* prints "  PASS" */
            return 0;
        } else {
            print_verdict(0, "reason for failure");  /* "  FAIL: reason" */
            return 1;
        }
    }

### Step 2: Add to the Commands Table

    static struct command commands[] = {
        /* ... existing entries ... */
        { "foo", "short description of foo", cmd_foo },
        { NULL, NULL, NULL }
    };

### Step 3: Add to the Runner Script

In `nspa/run_rt_tests.sh`, add to the `tests` array:

    tests=(
        # ...
        "foo foo [optional args]"
    )

### Guidelines

- Use `print_banner()`, `print_section()`, `print_kv()`,
  `print_verdict()` for consistent output formatting.
- Use `print_worker_start()` when spawning named threads.
- Use `enter_realtime_class()` / `leave_realtime_class()` to switch
  to `REALTIME_PRIORITY_CLASS`.
- Spawn SCHED_OTHER load threads *before* `enter_realtime_class()`
  so they stay OTHER.
- Use `safe_load_count()` to cap load threads at `(n_cpus - 1)` to
  avoid saturating the machine.
- Check `g_global_abort` in long-running loops for Ctrl+C
  responsiveness.
- Use `now_us()` / `now_ms()` for timing measurements (QPC-based).
- Emit explicit PASS/FAIL via `print_verdict()` so the runner can
  parse verdicts without relying on exit codes.

### Adding a Layer 1 native test

Drop a `test-foo.c` in `wine/nspa/tests/` and add `test-foo` to the
`NATIVE_TESTS=( ... )` array in `run-rt-suite.sh`. Use exit code 77
to signal SKIP (e.g. driver feature missing). Runner will autobuild
on next invocation if the source is newer than the binary.

---

## 9. Environment Variables

### Variables Consumed by `nspa_rt_test.exe`

| Variable | Default | Description |
|----------|---------|-------------|
| `NSPA_RT_PRIO` | (unset) | Enables v1 RT promotion. Sets ceiling FIFO priority for TIME_CRITICAL threads. Typical: `80`. |
| `NSPA_RT_POLICY` | (unset) | Scheduler policy for the lower RT band. `FF`/`RR`/`TS`. |
| `NSPA_TEST_TIMEOUT` | `120` | Watchdog timeout in seconds. |

### Variables Consumed by `run_rt_tests.sh`

| Variable | Default | Description |
|----------|---------|-------------|
| `WINE` | `/usr/bin/wine` | Path to Wine binary |
| `WINEPREFIX` | `/home/ninez/Winebox/winebox-master` | Wine prefix directory |
| `TEST_EXE` | `nspa_rt_test.exe` | Path to the PE test binary |
| `LOG_DIR` | `/tmp/nspa_rt_test_logs` | Directory for per-run log files |
| `TIMEOUT_SECS` | `120` | Per-test timeout (shell-level, seconds) |
| `RT_PRIO` | `80` | NSPA_RT_PRIO value for RT mode passes |
| `RT_POLICY` | `FF` | NSPA_RT_POLICY value for RT mode passes |
| `INCLUDE_PRIORITY` | `0` | Set to `1` to include the `priority` subcommand |

### Variables Set by the Runner in RT Mode

| Variable | Value | Purpose |
|----------|-------|---------|
| `WINEDEBUG` | `-all` | Suppress debug output (both modes) |
| `WINEPREFIX` | `$WINEPREFIX` | Wine prefix (both modes) |
| `NSPA_RT_PRIO` | `$RT_PRIO` | RT mode only -- enables FIFO promotion |
| `NSPA_RT_POLICY` | `$RT_POLICY` | RT mode only -- sets scheduler policy |
| `WINEPRELOADREMAPVDSO` | `force` | RT mode only -- remap vDSO for RT-safe clock access |

### Kernel Prerequisites

| Requirement | Check | Purpose |
|-------------|-------|---------|
| `ntsync` module loaded | `sudo modprobe ntsync` | Required for ntsync sub-tests + Layer 1 |
| ntsync 1011 loaded | module srcversion `10124FB81FDC76797EF1F91` | Required for `NSPA_TRY_RECV2=1` to do anything in `dispatcher-burst` |
| Hugepages reserved | `/proc/meminfo` HugePages_Total > 0 | Required for `large-pages` test |
| RT-capable kernel | `uname -r` shows `-rt` | Required for SCHED_FIFO promotion |
| CAP_SYS_NICE or root | `ulimit -r` | Required for RT scheduling |
