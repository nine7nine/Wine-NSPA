# Wine-NSPA -- Full Suite Comparison Report

**Date:** 2026-05-01
**Author:** Jordan Johnston
**Kernel:** `6.19.11-rt1-1-nspa` (PREEMPT_RT_FULL, production)
**ntsync module:** `srcversion 10124FB81FDC76797EF1F91`
**Wine:** 11.6 + NSPA RT patchset
Baseline = `WINEDEBUG=-all` only |
RT = `NSPA_RT_PRIO=80 NSPA_RT_POLICY=FF WINEPRELOADREMAPVDSO=force`

This doc tracks Wine-NSPA test-suite evolution from v3 through v8. The
current published snapshot is v8 / 2026-04-30 (1003-1011 kernel stack,
24 PASS / 0 FAIL / 0 TIMEOUT PE matrix, `dispatcher-burst` added).
Earlier version sections are retained below as historical snapshots.

| Version | Date | Highlight |
|---------|------|-----------|
| v3 -> v4 | 2026-04-15 | NTSync PI v2 kernel fixes; io_uring socket bypass landed (later renumbered to Phase 2) |
| v4 -> v5 | 2026-04-15 | msvcrt SIMD + SRW spin + pi_cond requeue-PI |
| v5 -> v6 | 2026-04-16/17 | (incremental tuning, stable matrix) |
| **v6 -> v7** | **2026-04-28** | **Native ntsync stress suite added; ~370M ops zero KASAN; PE matrix 22/22 stable** |
| **v7 -> v8** | **2026-04-30** | **1011 / TRY_RECV2 shipped, `dispatcher-burst` added, Layer 1 native suite 3 PASS / 0 FAIL, Layer 2 PE matrix 24 PASS / 0 FAIL / 0 TIMEOUT** |

---

## v8 / 2026-04-30 -- 1011 shipped, dispatcher coverage added, 24/24 PE matrix

### Headline

A cleaner current two-layer surface:

- **Layer 1 (native ntsync suite):** `3 PASS / 0 FAIL` against
  production module `10124FB81FDC76797EF1F91`
  (`test-event-set-pi`, `test-channel-recv-exclusive`,
  `test-aggregate-wait` 9/9 including kitchen-sink 86,528 wakes /
  0 timeouts / 0 errors).
- **Layer 2 (PE matrix):** `24 PASS / 0 FAIL / 0 TIMEOUT` after adding
  `dispatcher-burst`.
- **Dispatcher-specific gap closed:** `dispatcher-burst` finally covers
  `channel_dispatcher` / `dispatch_channel_entry` / the `TRY_RECV2`
  drain loop, which the rest of the PE matrix mostly does not touch.

### Layer 1 results -- current production module

Module under test: `srcversion 10124FB81FDC76797EF1F91`
(1003-1011, post-1010 PI follow-ups, `NTSYNC_IOC_CHANNEL_TRY_RECV2`
present).

| Test | Result |
|------|--------|
| `test-event-set-pi` | PASS |
| `test-channel-recv-exclusive` | PASS |
| `test-aggregate-wait` | **9/9 PASS**: basic, timeout, PI propagation, 32-source stress, mixed obj+fd, cancel-via-signal, channel-notify, channel-PI propagation, kitchen-sink |

**Layer 1 totals: 3 PASS / 0 FAIL.**

### Layer 2 PE matrix -- 24 PASS / 0 FAIL / 0 TIMEOUT

| Test | Baseline | RT | Notes |
|------|----------|----|------|
| rapidmutex | PASS | PASS | CS-PI fast path stable |
| philosophers | PASS | PASS | transitive PI chain validated |
| fork-mutex | PASS | PASS | 100/100 children spawned + reaped |
| cs-contention | PASS | PASS | CS-PI fires correctly |
| signal-recursion | PASS | PASS | recursive `virtual_mutex` path clean |
| large-pages | PASS | PASS | 2MB + 1GB pages, LargePage flag set |
| ntsync-d4 | PASS | PASS | mutex PI + chain + prio + WFMO |
| ntsync-d8 | PASS | PASS | same, depth 8 |
| ntsync-d12 | PASS | PASS | same, depth 12, 8 rapid threads |
| socket-io | PASS* | PASS* | current build functionally green on the socket path |
| condvar-pi | PASS | PASS | Win32 condvar PI bridge stable |
| dispatcher-burst | PASS | PASS | gamma dispatcher A/B harness for `TRY_RECV2` + Phase 4 `CreateFile` |

**24 PASS / 0 FAIL / 0 TIMEOUT** (12 tests x 2 modes).

`*` = implicit verdict from exit code `0`; the test binary does not
emit a PASS/FAIL line for `socket-io`.

### Dispatcher-specific validation

`dispatcher-burst` is the reason v8 matters. All other PE tests mostly
route through `inproc_wait` -> ntsync ioctls directly and never load
the gamma hot path hard enough to be a useful oracle for
`channel_dispatcher` tuning.

| Metric | TRY_RECV2 on | TRY_RECV2 off | Delta |
|---|---:|---:|---:|
| burst ops/sec (wall) | 841,765 | 555,567 | +34% / 1.5x |
| burst worst max ns | 23,014,325 | 31,843,082 | −28% |
| steady avg ns | 35,202 | 33,405 | flat (no burst) |

Steady-state stays flat because a one-RPC pump has nothing to drain.
The win is concentrated in burst load, exactly where `TRY_RECV2`
removes repeated `AGG_WAIT` round-trips.

### Comparison to 2026-04-26 (single-sample, noisy)

| Metric | 2026-04-26 | 2026-04-30 (now) | Δ |
|---|---|---|---|
| rapidmutex RT max_wait | 44us | 38us | −14% |
| rapidmutex RT elapsed | 1950ms | 1924ms | −1.3% |
| ntsync-d12 PI chain depth-12 | 236ms | 237ms | ≈0 |

Caveat: the PE matrix does **not** show the dispatcher win directly
except through `dispatcher-burst`. That is why the dedicated gamma A/B
harness was added in v8.

### v7 -> v8 changes

| Area | Change | Impact |
|------|--------|--------|
| Kernel | 1011 `NTSYNC_IOC_CHANNEL_TRY_RECV2` shipped | non-blocking channel dequeue for post-dispatch burst drain |
| Userspace | `NSPA_TRY_RECV2=1` default-on | drains multiple entries per `AGG_WAIT` under burst load |
| Userspace | `NSPA_ENABLE_ASYNC_CREATE_FILE=1` default-on | Phase 4 removes the `open()` lock-drop CS from the audio xrun path |
| Userspace | `NSPA_FLUSH_THROTTLE_MS=8` default-on | recovers ~5.4 percentage points of MainThread CPU under busy Ableton |
| Test surface | `dispatcher-burst` added to Layer 2 | first PE-side gamma / dispatcher coverage |

---

## v7 / 2026-04-28 -- Native ntsync stress suite added (historical snapshot)

### Headline

A two-layer test surface:

- **Layer 1 (new):** native `/dev/ntsync` ioctl stress tests at
  `wine/nspa/tests/test-*.c`. Catches kernel bugs the Win32 surface
  can't reach (channels, EVENT_SET_PI, raw sched, channel REPLY/cleanup
  refcount).
- **Layer 2 (unchanged scope):** `nspa_rt_test.exe` PE matrix --
  baseline + RT pass for all 11 tests. Continues to pass 22/22 in that
  historical snapshot.

### Layer 1 results -- ~370M ops, zero KASAN, zero dmesg splats

Module under test: `srcversion A250A77651C8D5DAB719FE2`. All four bugs
caught during the 2026-04-26 -> 2026-04-28 KASAN-armed debug-kernel
session are fixed. Cumulative ops since the audit session opened.

| Test | Ops / config | Result |
|------|--------------|--------|
| `test-event-set-pi` | sanity (modified for ready-flag handshake) | PASS |
| `test-event-set-pi-stress` | 8x8 EVENT_SET_PI hammer | PASS |
| `test-channel-recv-exclusive` | symmetric cleanup; was the channel-recv hang repro | PASS |
| `test-channel-stress` | SEND_PI + RECV + REPLY + register churn | PASS |
| `test-mutex-pi-stress` | mutex contention + Tier B FIFO | PASS |
| `test-mixed-load-stress` | 5-min mixed-load soak (events SET/RESET/PI/PULSE + mutex + sem + chan + wait_all + pulse), ~10M ops | PASS |
| Cumulative session total | ~370M ops across all paths (debug kernel + prod kernel) | 0 KASAN, 0 dmesg, 0 syscall errors |

Tests deliberately excluded from the active run via
`SKIPPED_BY_DESIGN`:

- `test-cross-boost` -- asserts 1007 cross-boost cleanup (rolled back)
- `test-wait-rejects-channel` -- asserts 1007 channel-reject in
  setup_wait (rolled back)

These remain in-tree as documentation of what was tried and why it was
reverted (memory: `feedback_dont_shotgun_audit_into_unfound_bug`).

### Layer 2 PE matrix -- 22/22 PASS

| Test | Baseline | RT | Notes |
|------|----------|----|------|
| rapidmutex | PASS | PASS | CS-PI fast path + SIMD memcpy stable |
| philosophers | PASS | PASS | Transitive PI chain validated |
| fork-mutex | PASS | PASS | 100/100 children spawned + reaped |
| cs-contention | PASS | PASS | CS-PI fires correctly |
| signal-recursion | PASS | PASS | Recursive virtual_mutex path clean |
| large-pages | PASS | PASS | 2MB + 1GB pages, LargePage flag set |
| ntsync-d4 | 8/8 | 8/8 | Mutex PI + chain + prio + WFMO |
| ntsync-d8 | 8/8 | 8/8 | Same, depth 8 |
| ntsync-d12 | 8/8 | 8/8 | Same, depth 12, 8 rapid threads |
| socket-io | PASS | PASS | io_uring Phase 2 bypass code path |
| srw-bench | PASS | PASS | SRW spin phase + RT skip |

**22/22 PASS** (11 tests x 2 modes). All PI, sync, ntsync, and
io_uring subsystems healthy.

### v6 -> v7 changes

| Area | Change | Impact |
|------|--------|--------|
| Test surface | Layer 1 native ntsync stress suite added (6 tests + runner) | Catches kernel bugs Win32 layer can't reach |
| ntsync module | Bug 1 (test cleanup), Bug 2 (channel exclusive recv: 1007-style narrow patch), Bug 3 (EVENT_SET_PI deferred boost: 1008), Bug 4 (channel_entry refcount UAF: 1009) all fixed | Production kernel solid: ~370M ops zero KASAN |
| Wine ring code | Audit §4.1 retry-loop hardening shipped (superproject `a7e34c7`) | 7 sites + `NSPA_SHM_RETRY_GUARD`; subtests A+B PASS |
| Runner | `wine/nspa/tests/run-rt-suite.sh` orchestrates Layer 1 + Layer 2 | Single command for full surface |
| io_uring socket bypass | Renumbered to Phase 2 | PE socket-io test still PASSed against that build |

### Numbers (PE matrix, 2026-04-28)

PE matrix throughput / latency numbers are within run-to-run variance
of v5/v6. The stable result is the 22/22 PASS itself plus the absence
of regressions across the audit cycle. Verbose per-test deltas were
useful in v3 -> v4 -> v5 when we were chasing PI v2 fixes; they're
noise now that the PI surface is stable.

---

## v3 -> v4 (2026-04-15) -- NTSync PI v2 + io_uring socket bypass

Original report. Kernel: 6.19.11-rt1-1-nspa, CONFIG_NTSYNC=m (PI v2
patches, module loaded). Wine-NSPA 11.6, `nspa_rt_test.exe` v4 via
`run_rt_tests.sh` (10 tests, baseline + RT).

### NTSync PI v2 Kernel Fixes [3 BUGS FIXED]

| # | Bug | Impact |
|---|-----|--------|
| 1 | Multi-object PI corruption: per-object orig_attr save/restore broke when a task held multiple boosted mutexes | Owner dropped to SCHED_OTHER while second mutex still had RT waiters |
| 2 | wait_all had zero PI: `ntsync_wait_all` never called `ntsync_pi_recalc`, and recalc only scanned `any_waiters` | WaitForMultipleObjects(bWaitAll=TRUE) with mutexes got no PI boost |
| 3 | Stale `normal_prio` comparison: after boost, `sched_setattr_nocheck` changed `normal_prio`; downward recalc failed | Boost dropped entirely when highest-prio waiter left but lower-prio waiters remained |

### io_uring Socket I/O Bypass [NEW in v4]

(Numbered "Phase 3" in the v4 report; renumbered to Phase 2 in 2026-04-28.)

| # | What | Impact |
|---|------|--------|
| 1 | ALERTED-state interception: intercept before `set_async_direct_result` | Async stays frozen on server (no epoll monitoring), CQE handler completes once |
| 2 | E2 bitmap in `sock_get_poll_events` | Server skips epoll for client-monitored fds -- no protocol change |
| 3 | ntsync `uring_fd` kernel extension | Threads blocked in ntsync waits wake on io_uring CQE arrival |

### v4 Overall Verdict

| Test | Baseline | RT | v3->v4 | Notes |
|------|----------|-----|-------|-------|
| rapidmutex | PASS | PASS | RT max wait 29->46us (noise) | 312K ops/s RT |
| philosophers | PASS | PASS | **RT max wait 1620->601us (-63%)** | PI v2 fix validated |
| fork-mutex | PASS | PASS | flat | 100/100 both modes |
| cs-contention | PASS | PASS | flat | CS-PI fires correctly |
| signal-recursion | PASS | PASS | flat | No sync primitives |
| large-pages | PASS | PASS | identical | Deterministic |
| ntsync-d4 | 8/8 | 8/8 | PI avg 238->388ms (CFS variance) | chain + prio correct |
| ntsync-d8 | 8/8 | 8/8 | **PI avg 479->419ms (fixed)** | Was reversed in v3, now correct direction |
| ntsync-d12 | 8/8 | 8/8 | chain scales to 12 | prio wakeup correct |
| socket-io A | PASS | PASS | **new: avg 95us** | immediate recv |
| socket-io B | PASS | PASS | **new: avg 113us, 2000 async** | overlapped recv via io_uring |

**20/20 PASS** (10 tests x 2 modes).

### v3 -> v4 Key Improvements

| Metric | v3 | v4 | Cause |
|--------|----|----|-------|
| Philosophers RT max wait | 1620 us | **601 us (-63%)** | PI v2: stale normal_prio fix eliminated thrashing |
| ntsync d8 PI RT avg | 479 ms | **419 ms** | PI v2 fix (was reversed in v3) |
| Philosophers elapsed (RT) | 265 ms | **189 ms (-29%)** | Less PI overhead |
| socket-io Phase B avg | -- | **113 us** | NEW: io_uring overlapped socket bypass |
| socket-io Phase B throughput | -- | **8837 msg/s** | NEW: +18% vs baseline |

### Resolved in v4

- Philosophers RT max wait 1620us -- root cause was buggy PI code
  (stale `normal_prio`), not `sched_setattr_nocheck`. PI v2 fix:
  1620 -> 601us.
- ntsync module autoload -- promoted from "convenience" to CRITICAL.
  Now autoloaded via `/etc/modules-load.d/ntsync.conf`.
- Overlapped socket bypass -- 4 failed approaches (signal reentrancy,
  deadlock, double completion, ALERTED/PENDING race). 5th approach
  (ALERTED-state interception) works.

---

## v4 -> v5 (2026-04-15) -- msvcrt SIMD + SRW spin + pi_cond requeue-PI

### msvcrt SIMD Optimizations [NEW]

| # | Change | Impact |
|---|--------|--------|
| 1 | AVX/SSE2 memcpy/memmove | Wider stores, lower overhead for buffer copies |
| 2 | SSE2 memchr, strlen, memcmp | Faster string operations across all Wine code paths |
| 3 | Runtime CPU dispatch | AVX path selected at init when CPUID confirms support |

### Synchronization Improvements [3 CHANGES]

| # | Change | Impact |
|---|--------|--------|
| 4 | `CoWaitForMultipleHandles` correctness rewrite | Removes 100-msg hack, correct COM message pumping |
| 5 | SRW lock spin phase (256 iterations, skip for RT threads) | Reduces kernel transitions for short holds, RT threads skip spin to avoid priority inversion |
| 6 | pi_cond requeue-PI upgrade (FUTEX_WAIT_REQUEUE_PI / FUTEX_CMP_REQUEUE_PI) | Closes PI gap in condition variable wakeup |

### New Test Subcommands [2 NEW]

| # | Change | Impact |
|---|--------|--------|
| 7a | SRW contention benchmark | Measures SRW lock throughput under load |
| 7b | pi_cond requeue-PI benchmark (native Linux) | Validates requeue-PI kernel path |

### v5 Overall Verdict

| Test | Baseline | RT | v4->v5 Delta | Notes |
|------|----------|-----|-------------|-------|
| rapidmutex | PASS | PASS | **RT throughput 312K->327K (+4.7%)** | SIMD + SRW spin benefit |
| philosophers | PASS | PASS | RT max wait 601->1301us (CFS variance) | PI still correct, run-to-run noise |
| fork-mutex | PASS | PASS | **RT elapsed 1021->948ms (-7.1%)** | Faster process startup |
| cs-contention | PASS | PASS | flat | CS-PI fires correctly |
| signal-recursion | PASS | PASS | flat | No sync primitives |
| large-pages | PASS | PASS | identical | Deterministic |
| ntsync-d4 | 8/8 | 8/8 | **baseline PI avg 415->209ms (-50%)** | Dramatic improvement |
| ntsync-d8 | 8/8 | 8/8 | **RT PI avg 419->201ms (-52%)** | CFS variance resolved |
| ntsync-d12 | 8/8 | 8/8 | flat (CFS variance) | chain + prio correct |
| socket-io A | PASS | PASS | flat | immediate recv stable |
| socket-io B | PASS | PASS | flat | overlapped recv stable |

**20/20 PASS**.

### v4 -> v5 Key Improvements

| Metric | v4 | v5 | Cause |
|--------|----|----|-------|
| rapidmutex RT throughput | 312K ops/s | **327K ops/s (+4.7%)** | SIMD memcpy/memmove in CS overhead |
| ntsync d4 baseline PI avg | 415 ms | **209 ms (-50%)** | SRW spin phase + SIMD reduces CFS contention |
| ntsync d8 RT PI avg | 419 ms (reversed) | **201 ms (-52%)** | CFS reversal resolved |
| ntsync d4 rapid throughput | 232K ops/s | **259K ops/s (+11.6%)** | Lower lock transition overhead |
| baseline socket-io B avg | 133.2 us | **104.5 us (-21%)** | SIMD memcpy in io_uring buffer path |
| baseline socket-io B throughput | 7506 msg/s | **9568 msg/s (+27%)** | Same |
| fork-mutex RT elapsed | 1021 ms | **948 ms (-7.1%)** | SIMD string ops in process startup |

---

## v5 -> v6 (2026-04-16/17) -- incremental tuning

Stable matrix; no new test subcommands. Tuning passes on the gamma
channel scaffolding and msg-ring v2 Phase A (redraw_window push ring)
landed in this window. PE matrix continued to pass 20/20 throughout.

---

## Chain Depth Scaling Summary (PE matrix)

PI contention avg wait (informational only -- highly sensitive to CFS
load placement; PASS criteria stay on chain + prio + WFMO correctness,
which are stable):

| Depth | v4 RT avg | v5 RT avg | v7 status |
|-------|-----------|-----------|-----------|
| d4 (8 iters) | 387 ms | 270 ms | stable, within run-to-run |
| d8 (3 iters) | 419 ms | 201 ms | stable, within run-to-run |
| d12 (3 iters) | 282 ms | 418 ms | high variance with 3 samples |

Rapid throughput (kernel mutex):

| Depth | Threads | v4 RT | v5 RT | v7 status |
|-------|---------|-------|-------|-----------|
| d4 | 4 | 232K | 259K | stable |
| d8 | 4 | 238K | 253K | stable |
| d12 | 8 | 237K | 231K | stable |

Priority wakeup order: correct in all configs across all versions.

---

## Notes on Cross-Version Comparison

- Benchmark numbers (latency, throughput) are run-to-run noisy and
  also skew when slub_debug / KFENCE are on. The authoritative signal
  across versions is **PASS/FAIL plus presence of KASAN splats** --
  not specific microsecond or ops/sec deltas. (Memory:
  `feedback_slub_debug_skews_benchmarks`.)
- The 2026-04-26 -> 2026-04-28 audit cycle paid bills against the
  ntsync surface and the wine ring-retry loop. Both surfaces are
  stable as of v7. Velocity is now back on the bypass roadmap (msg-ring
  v2 Phase C get_message bypass paused mid-development is the next
  resume target).

---

Generated: 2026-05-01 | Wine-NSPA RT test harness v8 current snapshot
(Layer 1 + Layer 2) -- `10124FB81FDC76797EF1F91`, 3 PASS / 0 FAIL
native, 24 PASS / 0 FAIL / 0 TIMEOUT PE matrix.
