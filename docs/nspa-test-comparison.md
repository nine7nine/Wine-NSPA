# Wine-NSPA -- Validation Baselines and Comparison

This page preserves the archived RT-suite snapshots and the subsystem deltas
that are still useful when reading older Wine-NSPA results.

## Table of Contents

1. [Overview](#1-overview)
2. [Archived suite snapshots](#2-archived-suite-snapshots)
3. [Current archived boundary](#3-current-archived-boundary)
4. [Historical suite deltas worth keeping](#4-historical-suite-deltas-worth-keeping)
5. [Targeted subsystem A/Bs after the archive boundary](#5-targeted-subsystem-abs-after-the-archive-boundary)
6. [Methodology boundaries](#6-methodology-boundaries)
7. [References](#7-references)

---

## 1. Overview

The public test story has two layers:

- archived full-suite snapshots, where the whole default matrix was rerun and
  versioned
- targeted validators and workload A/Bs, which carry later subsystem work that
  did not get a new archived suite snapshot

This page keeps both. It does not try to turn every later A/B into a fake
matrix version, but it also does not throw away the concrete per-test and
before/after data that explains why individual carries mattered.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 360" xmlns="http://www.w3.org/2000/svg">
  <style>
    .tv-bg { fill: #1a1b26; }
    .tv-arch { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .tv-data { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .tv-ab { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .tv-note { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.6; rx: 8; }
    .tv-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .tv-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .tv-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .tv-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .tv-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .tv-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .tv-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
    .tv-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="360" class="tv-bg"/>
  <text x="480" y="28" text-anchor="middle" class="tv-title">Public validation data has three useful shapes</text>

  <rect x="54" y="94" width="230" height="112" class="tv-arch"/>
  <text x="169" y="120" text-anchor="middle" class="tv-head-b">archived full suite</text>
  <text x="169" y="142" text-anchor="middle" class="tv-small">versioned snapshot</text>
  <text x="169" y="158" text-anchor="middle" class="tv-small">same runner for every default test</text>
  <text x="169" y="174" text-anchor="middle" class="tv-small">headline totals stay meaningful</text>

  <rect x="365" y="94" width="230" height="112" class="tv-data"/>
  <text x="480" y="120" text-anchor="middle" class="tv-head-g">per-test detail</text>
  <text x="480" y="142" text-anchor="middle" class="tv-small">rapidmutex, philosophers, socket-io,</text>
  <text x="480" y="158" text-anchor="middle" class="tv-small">dispatcher-burst, condvar-pi, etc.</text>
  <text x="480" y="174" text-anchor="middle" class="tv-small">explains what changed inside the total</text>

  <rect x="676" y="94" width="230" height="112" class="tv-ab"/>
  <text x="791" y="120" text-anchor="middle" class="tv-head-y">targeted A/B</text>
  <text x="791" y="142" text-anchor="middle" class="tv-small">used after the archive boundary</text>
  <text x="791" y="158" text-anchor="middle" class="tv-small">preserves feature-specific evidence</text>
  <text x="791" y="174" text-anchor="middle" class="tv-small">without minting fake suite versions</text>

  <line x1="284" y1="150" x2="365" y2="150" class="tv-line-b"/>
  <line x1="595" y1="150" x2="676" y2="150" class="tv-line-g"/>

  <rect x="172" y="254" width="616" height="56" class="tv-note"/>
  <text x="480" y="280" text-anchor="middle" class="tv-head-p">Rule</text>
  <text x="480" y="298" text-anchor="middle" class="tv-small">keep archived suite totals for boundary-to-boundary comparison,</text>
  <text x="480" y="314" text-anchor="middle" class="tv-small">and keep the concrete per-test / per-feature numbers that explain architectural change</text>
</svg>
</div>

---

## 2. Archived suite snapshots

These are the public snapshots worth keeping as suite-level boundaries.

| Snapshot | Date | Suite shape | Result | Why it matters |
|---|---|---|---|---|
| `v4` | `2026-04-15` | PE-only matrix, 10 tests x baseline + RT | `20/20 PASS` | first public socket `io_uring` numbers and post-PI-v2 kernel fixes |
| `v5` | `2026-04-15/16` | PE-only matrix, 10 tests x baseline + RT | `20/20 PASS` | SIMD / SRW-spin era with detailed per-test deltas |
| `v7` | `2026-04-28` | early two-layer | Layer 1 native suite added; Layer 2 `22/22 PASS` | native ntsync Layer 1 becomes part of the public suite |
| `v8` | `2026-04-30` | early two-layer | Layer 1 `3 PASS / 0 FAIL`; Layer 2 `24 PASS / 0 FAIL / 0 TIMEOUT` | `dispatcher-burst` enters the default PE matrix |
| `v9-validation-default` | `2026-05-03` | current archived two-layer default | Layer 1 `3 PASS / 0 FAIL / 0 SKIP`; Layer 2 `32 PASS / 0 FAIL / 0 TIMEOUT` | current archived baseline used by the public docs |

Later carries are documented through targeted validators and workload A/Bs
unless another full-suite archive supersedes `v9-validation-default`.

The last older-method whole-suite reference run before the methodology shift
was `v18`. Its useful late-suite numbers are carried in
[5.4 ntsync allocator and wait-queue follow-ons](#54-ntsync-allocator-and-wait-queue-follow-ons)
rather than being presented as a fake new archived boundary.

---

## 3. Current archived boundary

The current archived full-suite boundary is `v9-validation-default`
(`2026-05-03`).

| Layer | Result | Notes |
|---|---|---|
| Layer 1 native suite | `3 PASS / 0 FAIL / 0 SKIP` | `test-event-set-pi`, `test-channel-recv-exclusive`, `test-aggregate-wait` |
| Layer 2 PE matrix | `32 PASS / 0 FAIL / 0 TIMEOUT` | `16` default tests x `baseline` + `rt` |

The archived default PE test set is:

| Sync and contention | I/O and bypass | Timers and UI |
|---|---|---|
| `rapidmutex` | `socket-io` | `nt-timer` |
| `philosophers` | `rpc-bypass` | `wm-timer` |
| `fork-mutex` | `irot-bypass` | `dispatcher-burst` |
| `cs-contention` | `large-pages` | `signal-recursion` |
| `ntsync-d4` |  |  |
| `ntsync-d8` |  |  |
| `ntsync-d12` |  |  |
| `condvar-pi` |  |  |

This is the baseline to use when a public page says "archived matrix" or
"current archived validation boundary."

---

## 4. Historical suite deltas worth keeping

### 4.1 `v3` -> `v4`

The `v4` archive is still useful because it was the first full public matrix
after the PI-v2 ntsync fixes and the socket `io_uring` overlapped path landed.

| Metric | Earlier run | `v4` | Read |
|---|---:|---:|---|
| philosophers RT max wait | `1620 us` | `601 us` | `-63%`; PI-v2 bugfix removes boost/unboost thrash |
| socket-io B avg latency | — | `113.2 us` | first public overlapped `io_uring` result |
| socket-io B throughput | — | `8837 msg/s` | first public overlapped `io_uring` result |
| rapidmutex RT throughput | `~262K-301K ops/s` | `312K ops/s` | stable CS-PI hot path after PI-v2 cleanup |

### 4.2 `v4` -> `v5`

`v5` is still the densest archived example of how a micro-optimization bundle
shows up in RT tests.

| Metric | `v4` | `v5` | Read |
|---|---:|---:|---|
| rapidmutex RT throughput | `312K ops/s` | `327K ops/s` | `+4.7%`; lower CS-path copy overhead |
| rapidmutex RT max wait | `46 us` | `36 us` | lower transition overhead |
| fork-mutex RT elapsed | `1021 ms` | `948 ms` | `-7.1%`; process-start path trimmed |
| ntsync d4 rapid throughput | `232K ops/s` | `259K ops/s` | `+11.6%`; lower lock transition cost |
| ntsync d8 RT PI avg | `419 ms` | `201 ms` | `-52%`; the earlier reversal disappears |
| baseline socket-io B avg | `133.2 us` | `104.5 us` | `-21%`; overlapped path copy cost drops |
| baseline socket-io B throughput | `7506 msg/s` | `9568 msg/s` | `+27%`; same socket path improvement |

### 4.3 Representative per-test numbers

Some individual test numbers are still worth keeping because later pages cite
them directly.

| Test | Metric | Value |
|---|---|---|
| `condvar-pi` | with PI max wait | `152 us` |
| `condvar-pi` | without PI max wait | `263 us` |
| `rapidmutex` | RT throughput (`v5`) | `327K ops/s` |
| `rapidmutex` | RT max wait (`v5`) | `36 us` |
| `philosophers` | meals served | `250/250` |
| `socket-io` B | overlapped avg (`v5` baseline) | `104.5 us` |
| `socket-io` B | overlapped throughput (`v5` baseline) | `9568 msg/s` |

---

## 5. Targeted subsystem A/Bs after the archive boundary

The public docs kept moving after `v9-validation-default`, but not every carry
was followed by a new archived suite snapshot. These are the concrete deltas
worth keeping.

### 5.1 Dispatcher and message-path work

| Feature | Before | After | Read |
|---|---:|---:|---|
| `dispatcher-burst` burst ops/sec | `555,567` | `841,765` | `+34% / 1.5x` with `TRY_RECV2` burst drain |
| `dispatcher-burst` burst worst max ns | `31,843,082` | `23,014,325` | `-28%` |
| `channel_dispatcher` samples | `14.51%` | `0.70%` | `-13.81pp / -95%` |
| `main_loop_epoll` samples | `7.24%` | `2.68%` | `-4.56pp` |
| `get_message` calls / 60 s | `3,880` | `866` | `-78%` with empty-poll cache |
| `get_message` direct handler time | `16.5 ms` | `2.2 ms` | `-87%` |
| `get_message` total handler time | `46.8 ms` | `36.9 ms` | `-21%` |

### 5.2 Shared-state and zero-time waits

| Feature | Before | After | Read |
|---|---:|---:|---|
| zero-time process wait | `~10000 ns/poll` | `~144 ns/poll` | `process_shm` short-circuit |
| zero-time thread wait | `~11940 ns/poll` | `~164 ns/poll` | `thread_shm` short-circuit |
| local sections `nspa_create_mapping_from_unix_fd` count | `2,664` | `~800` | `-70%`; mapping work stays local |
| local sections total handler time | `1,991 ms` | `1,077 ms` | lighter mapping path |

### 5.3 x86_64 hot-path bundle

| Metric | Before | After | Read |
|---|---:|---:|---|
| user-mode samples | `97K` | `86K` | `-11.3%` |
| iTLB misses | `229.7M` | `180.8M` | `-21.30%` |
| dTLB misses | `51.5M` | `42.4M` | `-17.69%` |
| branch misses | `348.3M` | `308.4M` | `-11.45%` |
| page faults | `130,349` | `71,754` | `-44.95%` |
| `NtGetTickCount` dispatcher entries | `3,081,551` | `0` | inline path confirmed end-to-end |

### 5.4 ntsync allocator and wait-queue follow-ons

The later ntsync cache-isolation and wait-queue work was validated more through
targeted stress and tail numbers than through a new public full-suite archive.
The best late post-1011 whole-suite reference in that family was `v18`, so it
is worth keeping its numbers explicit instead of collapsing them into prose.

| Metric | post-1011 `v17` | post-1011 `v18` | later cache-isolated sample | Read |
|---|---:|---:|---:|---|
| philosophers RT max wait | `4154 us` | `3039 us` | `857 us` | `v18` was the tighter post-1011 run; later cache isolation tightens the tail again |
| philosophers worst max wait | `13097 us` | `9963 us` | `1424 us` | same tail-tightening story |
| rapidmutex ops/sec | `862K` | `254K` | `270K` | no collapse after the later allocator/cache changes |
| dispatcher p99 | `22.8M ns` | `17.0M ns` | `16.9M ns` | no regression on the dispatcher hot path |
| socket-io p99 | `238 us` | `161 us` | `234 us` | later sample remains inside the earlier variance band |

These numbers are useful as a no-regression and tail-tightening read, not as a
replacement for a new archived suite boundary.

---

## 6. Methodology boundaries

The methodology note should be short but explicit.

| Family | Snapshots | What changed | Comparison rule |
|---|---|---|---|
| PE-only matrix | `v3` through `v6` | one PE layer, smaller default set | compare within the family |
| Early two-layer | `v7`, `v8` | native Layer 1 added; `dispatcher-burst` joins the PE set | compare within the family |
| Current archived default | `v9-validation-default` | 16-test default PE matrix with Layer 1 intact | current public baseline |

So:

- use archived totals inside the same family
- keep later targeted A/Bs as feature evidence
- do not pretend a targeted A/B is a new suite snapshot

For the current runner shape and default test list, see
[RT Test Harness](nspa-rt-test.gen.html).

---

## 7. References

- [RT Test Harness](nspa-rt-test.gen.html)
- [State of The Art](current-state.gen.html)
- [Critical Section PI](cs-pi.gen.html)
- [Win32 Condvar PI](condvar-pi-requeue.gen.html)
- [Gamma Channel Dispatcher](gamma-channel-dispatcher.gen.html)
- [io_uring I/O Architecture](io_uring-architecture.gen.html)
