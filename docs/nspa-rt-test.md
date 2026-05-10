# Wine-NSPA RT Test Harness

This page documents the current Wine-NSPA validation harness: the two-layer
full-suite boundary, the default PE validation matrix, the native ntsync suite,
and the targeted validators that sit outside the archived matrix.

## Table of Contents

1. [Validation model](#1-validation-model)
2. [Current archived boundary](#2-current-archived-boundary)
3. [Layer 2 default PE matrix](#3-layer-2-default-pe-matrix)
4. [Layer 1 native ntsync suite](#4-layer-1-native-ntsync-suite)
5. [Targeted validators outside the full-suite archive](#5-targeted-validators-outside-the-full-suite-archive)
6. [Runners and output](#6-runners-and-output)
7. [Safety](#7-safety)
8. [Extending the harness](#8-extending-the-harness)
9. [Environment and prerequisites](#9-environment-and-prerequisites)

---

## 1. Validation model

The current test surface is split into four categories:

- **Layer 1 native suite.** Small plain-C programs under
  `wine/nspa/tests/test-*.c` that talk directly to `/dev/ntsync` ioctls.
  These cover kernel invariants the Win32 layer cannot reach directly.
- **Layer 2 default PE matrix.** `nspa_rt_test.exe` in baseline and RT modes.
  This is the archived user-visible full-suite matrix.
- **Targeted validators.** Focused scripts or workload checks that validate a
  newer subsystem without redefining the full-suite boundary.
- **Opt-in perf tests.** Benchmarks such as `srw-bench` and
  `seqlock-bound`. These are useful for measurement, but they are not part of
  the default validation matrix.

The important maintenance rule is that these categories are not interchangeable.
If a carry is validated only by a targeted harness, the public docs should say
that explicitly instead of silently folding it into the matrix totals.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .vm-bg { fill: #1a1b26; }
    .vm-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .vm-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .vm-purple { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.7; rx: 8; }
    .vm-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.7; rx: 8; }
    .vm-red { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.7; rx: 8; }
    .vm-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .vm-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .vm-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .vm-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .vm-tag-p { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .vm-tag-y { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .vm-tag-r { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .vm-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
    .vm-line-p { stroke: #bb9af7; stroke-width: 1.2; fill: none; }
    .vm-line-y { stroke: #e0af68; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="420" class="vm-bg"/>
  <text x="480" y="26" text-anchor="middle" class="vm-title">Wine-NSPA validation model</text>

  <rect x="90" y="70" width="320" height="110" class="vm-green"/>
  <text x="250" y="94" text-anchor="middle" class="vm-tag-g">archived full-suite boundary</text>
  <text x="250" y="118" text-anchor="middle" class="vm-label">Layer 1 native suite + Layer 2 default PE matrix</text>
  <text x="250" y="142" text-anchor="middle" class="vm-small">current archived snapshot: `v9-validation-default`</text>
  <text x="250" y="160" text-anchor="middle" class="vm-small">native: kernel invariants</text>
  <text x="250" y="176" text-anchor="middle" class="vm-small">PE matrix: Win32 / ntdll / wineserver / kernel path</text>

  <rect x="550" y="70" width="320" height="110" class="vm-purple"/>
  <text x="710" y="94" text-anchor="middle" class="vm-tag-p">targeted validators</text>
  <text x="710" y="118" text-anchor="middle" class="vm-label">focused checks for newer carries</text>
  <text x="710" y="142" text-anchor="middle" class="vm-small">scheduler probes, memory shell harnesses, workload A/Bs</text>
  <text x="710" y="160" text-anchor="middle" class="vm-small">documented as targeted validation, not matrix totals</text>

  <rect x="90" y="250" width="320" height="90" class="vm-yellow"/>
  <text x="250" y="274" text-anchor="middle" class="vm-tag-y">opt-in perf tests</text>
  <text x="250" y="298" text-anchor="middle" class="vm-small">`srw-bench`, `seqlock-bound`, and similar CPU-heavy probes</text>
  <text x="250" y="316" text-anchor="middle" class="vm-small">useful for perf snapshots, excluded from the default matrix</text>

  <rect x="550" y="250" width="320" height="90" class="vm-red"/>
  <text x="710" y="274" text-anchor="middle" class="vm-tag-r">historical comparison</text>
  <text x="710" y="298" text-anchor="middle" class="vm-small">old totals only compare cleanly within the same methodology family</text>
  <text x="710" y="316" text-anchor="middle" class="vm-small">see the comparison page for the v3-v9 boundaries</text>

  <line x1="410" y1="125" x2="550" y2="125" class="vm-line-g"/>
  <line x1="250" y1="180" x2="250" y2="250" class="vm-line-y"/>
  <line x1="710" y1="180" x2="710" y2="250" class="vm-line-p"/>
</svg>
</div>

---

## 2. Current archived boundary

The current archived full-suite snapshot is:

| Item | Value |
|---|---|
| Archive | `v9-validation-default` |
| Archive timestamp | `2026-05-03 12:54:16 -0500` |
| Layer 1 native suite | `3 PASS / 0 FAIL / 0 SKIP` |
| Layer 2 PE matrix | `32 PASS / 0 FAIL / 0 TIMEOUT` |
| Layer 2 test count | `16` default tests x `2` modes |
| Modes | `baseline` and `rt` |

Layer 2 in this archived snapshot covers:

- `rapidmutex`
- `philosophers`
- `fork-mutex`
- `cs-contention`
- `signal-recursion`
- `large-pages`
- `ntsync-d4`
- `ntsync-d8`
- `ntsync-d12`
- `socket-io`
- `condvar-pi`
- `nt-timer`
- `wm-timer`
- `rpc-bypass`
- `irot-bypass`
- `dispatcher-burst`

Mode definitions:

- **baseline** = `WINEDEBUG=-all` with the normal default-on Wine-NSPA stack,
  but without RT promotion
- **rt** = `WINEDEBUG=-all NSPA_RT_PRIO=80 NSPA_RT_POLICY=FF WINEPRELOADREMAPVDSO=force`

One detail worth preserving in the docs: `socket-io` currently reports an
implicit verdict in the suite archive (`PASS*`) because the test exits `0`
without printing an explicit `PASS` line. The suite still counts it as a pass,
but the output format difference is intentional and should stay documented.

The newer subsystem carries that were validated after this archive should be
described as targeted validators unless and until another full archived matrix
is cut.

---

## 3. Layer 2 default PE matrix

The current default PE matrix is driven by `nspa/run_rt_tests.sh`. It is a
validation set, not a "run every possible subcommand" set.

### 3.1 Default validation tests

| Test | Surface | Primary contract |
|---|---|---|
| `rapidmutex` | `CRITICAL_SECTION` fast path | integrity and wait-bound behavior under hot contention |
| `philosophers` | transitive PI chain | no starvation or deadlock through the chain |
| `fork-mutex` | process spawn path | repeated `CreateProcess` + child exit stays clean |
| `cs-contention` | CS-PI slow path | RT waiter is bounded behind a normal-priority holder |
| `signal-recursion` | `virtual_mutex` + fault path | recursive PAGE_GUARD fault path stays deadlock-free |
| `large-pages` | large-page alloc + mapping + reporting | allocation, `SEC_LARGE_PAGES`, and `QueryWorkingSetEx` semantics |
| `ntsync-d4` / `d8` / `d12` | userspace sync -> `/dev/ntsync` | PI, priority wakeup, chain semantics, WFMO |
| `socket-io` | deferred socket path | latency / completion correctness on `RECVMSG` + `SENDMSG` |
| `condvar-pi` | Win32 condvar PI bridge | waiter wake / mutex reacquire path stays PI-clean |
| `nt-timer` | local NT timer path | timer create/set/cancel/query/wait semantics |
| `wm-timer` | local `WM_TIMER` path | message delivery, coalescing, kill semantics |
| `rpc-bypass` | `irpcss` bypass path | functional parity across the RPC bypass surface |
| `irot-bypass` | Running Object Table bypass path | functional parity across the ROT bypass surface |
| `dispatcher-burst` | gamma dispatcher hot path | same-path request/reply correctness and burst-drain behavior |

### 3.2 Optional tests outside the default matrix

| Test | Gate | Why it is excluded by default |
|---|---|---|
| `priority` | `INCLUDE_PRIORITY=1` | it sleeps for manual `ps` / `chrt` inspection and is not a routine matrix test |
| `srw-bench` | `WITH_BENCH=1` | CPU-heavy perf benchmark rather than contract validation |
| `seqlock-bound` | `WITH_BENCH=1` | workload-bound perf / retry probe, not default validation |

### 3.3 Dispatcher-specific PE coverage

`dispatcher-burst` remains important because most other PE tests do not stress
the gamma dispatcher path directly. It is the PE-side oracle for:

- `channel_dispatcher`
- `dispatch_channel_entry`
- aggregate-wait receive / reply ownership
- post-dispatch `TRY_RECV2` burst drain

Archived `v9-validation-default` result:

| Metric | Result |
|---|---|
| baseline verdict | PASS |
| rt verdict | PASS |
| archive position | part of the 16-test default matrix |

The earlier 2026-04-30 A/B numbers remain useful historically, but the current
public fact is that dispatcher coverage is part of the default full-suite
boundary rather than a side harness.

---

## 4. Layer 1 native ntsync suite

Layer 1 is driven by `wine/nspa/tests/run-rt-suite.sh native`. These tests
exercise kernel-only invariants that the PE layer cannot reach directly.

### 4.1 Default native tests

| Test | Coverage |
|---|---|
| `test-event-set-pi` | EVENT_SET_PI smoke and boost shape |
| `test-channel-recv-exclusive` | channel receive wake behavior |
| `test-aggregate-wait` | aggregate-wait coverage including mixed object/fd and kitchen-sink cases |

Archived `v9-validation-default` result:

- `3 PASS / 0 FAIL / 0 SKIP`
- `test-aggregate-wait`: `9/9 PASS`

### 4.2 Opt-in native stress tests

These are not part of the default validation boundary:

| Test | Gate | Purpose |
|---|---|---|
| `test-channel-stress` | `WITH_NATIVE_STRESS=1` | channel churn / cleanup hammer |
| `test-event-set-pi-stress` | `WITH_NATIVE_STRESS=1` | EVENT_SET_PI stress |
| `test-mixed-load-stress` | `WITH_NATIVE_STRESS=1` | mixed-driver soak |
| `test-mutex-pi-stress` | `WITH_NATIVE_STRESS=1` | mutex PI contention hammer |

### 4.3 `SKIPPED_BY_DESIGN`

Two tests remain excluded because they assert behavior that is no longer part
of the active kernel/userspace contract:

- `test-cross-boost`
- `test-wait-rejects-channel`

They are kept as source history and canaries, not as active validation.

---

## 5. Targeted validators outside the full-suite archive

These checks matter, but they are not the same thing as the archived matrix.

| Surface | Validator | Public use |
|---|---|---|
| sched-hosted `local_timer` / `local_wm_timer` | `run-rt-probe-validation.sh` | targeted scheduler-host validation |
| socket `RECVMSG` / `SENDMSG` tuning | `socket-io` plus workload captures | latency / throughput follow-on measurement |
| thread/process shared-state readers | dedicated A/B harnesses | query-class and zero-time-wait correctness |
| msg-ring empty-poll and TEB carries | workload counters | hot-path cost measurement |
| RT-keyed memory follow-ons | shell harnesses such as `test-mlock-ws.sh`, `test-huge-auto.sh`, `test-heap-hugepage.sh` | memory-specific correctness and behavior |

This separation is what keeps the public numbers honest: the archived full-suite
totals stay stable, while newer subsystem carries can still be documented with
their own validators.

---

## 6. Runners and output

### 6.1 Two-layer runner

`wine/nspa/tests/run-rt-suite.sh` drives the public two-layer suite:

```bash
wine/nspa/tests/run-rt-suite.sh
wine/nspa/tests/run-rt-suite.sh native
wine/nspa/tests/run-rt-suite.sh wine
```

It:

- runs Layer 1 native tests
- delegates Layer 2 to `nspa/run_rt_tests.sh`
- cleans up stale Wine processes
- archives logs
- can auto-compare against a prior archive

### 6.2 PE runner

`nspa/run_rt_tests.sh` is the Layer 2 orchestrator. It:

- runs each default test in `baseline` and `rt`
- writes one log per run
- resolves verdicts from explicit `PASS` / `FAIL` lines or exit code
- prints a summary matrix and totals

Verdict resolution order:

1. timeout -> `TIMEOUT`
2. explicit `PASS` line -> `PASS`
3. explicit `FAIL` line -> `FAIL`
4. fallback to exit code -> `PASS*` / `FAIL*`

### 6.3 Build

```bash
i686-w64-mingw32-gcc -O2 -static programs/nspa_rt_test/main.c -o nspa_rt_test.exe -lws2_32
```

Native ntsync tests are built on demand by `run-rt-suite.sh`.

---

## 7. Safety

The harness has two layers of timeout protection:

- **inner watchdog** inside `nspa_rt_test.exe`
- **outer shell timeout** in `run_rt_tests.sh`

Other safety rules:

- stale `nspa_rt_test.exe` processes are reaped between runs
- load-thread counts are capped for system survivability
- Ctrl+C sets the global stop flags and exits cleanly
- native stress tests are opt-in, not part of routine validation

These are part of the methodology, not just implementation detail: they keep
the validation suite usable on a real development machine.

---

## 8. Extending the harness

### 8.1 Adding a PE validation test

1. Add a new `cmd_foo()` handler to `programs/nspa_rt_test/main.c`.
2. Register it in the `commands[]` table.
3. Decide whether it belongs in:
   - the default validation matrix
   - targeted validation only
   - opt-in perf tests
4. If it belongs in the default matrix, add it to the `tests=()` array in
   `nspa/run_rt_tests.sh`.

### 8.2 Adding a native test

1. Add `test-foo.c` under `wine/nspa/tests/`.
2. Add `test-foo` to `NATIVE_TESTS=()` or `NATIVE_STRESS_TESTS=()`.
3. Use exit code `77` for skip.

The important maintenance rule is classification: do not put a perf probe into
the default validation matrix unless it is actually validating a contract.

---

## 9. Environment and prerequisites

### 9.1 Common runner variables

| Variable | Purpose |
|---|---|
| `WINE` | Wine binary path |
| `WINEPREFIX` | prefix used for Layer 2 |
| `TEST_EXE` | `nspa_rt_test.exe` path |
| `LOG_DIR` | per-run Layer 2 logs |
| `TIMEOUT_SECS` | shell-level timeout |
| `RT_PRIO` / `RT_POLICY` | RT-mode settings |

### 9.2 Optional gates

| Variable | Effect |
|---|---|
| `INCLUDE_PRIORITY=1` | include `priority` in Layer 2 |
| `WITH_BENCH=1` | include `srw-bench` and `seqlock-bound` |
| `WITH_NATIVE_STRESS=1` | enable native stress tests |
| `NATIVE_STRESS_DURATION=N` | per-stress-test duration |

### 9.3 Prerequisites

| Requirement | Why it matters |
|---|---|
| `/dev/ntsync` present | Layer 1 and ntsync Layer 2 tests |
| RT-capable kernel | RT-mode scheduling behavior |
| hugepages configured | `large-pages` path |
| RT privilege / `CAP_SYS_NICE` | FIFO promotion in RT mode |

For matrix lineage and comparability rules, see
[nspa-test-comparison](nspa-test-comparison.gen.html).
