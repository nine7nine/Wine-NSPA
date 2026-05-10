# Wine-NSPA -- Validation Baselines and Comparison

This page tracks the archived full-suite lineage and the methodology
boundaries that determine which totals are actually comparable.

## Table of Contents

1. [Comparison rules](#1-comparison-rules)
2. [Current archived boundary](#2-current-archived-boundary)
3. [Methodology eras](#3-methodology-eras)
4. [Version summary](#4-version-summary)
5. [Reading historical numbers](#5-reading-historical-numbers)

---

## 1. Comparison rules

The practical comparison rule is simple: compare like with like.

There are three distinct public methodology families in the Wine-NSPA test
history:

1. **PE-only matrix era (`v3` through `v6`).**
   One PE runner, no native Layer 1, and a smaller default subcommand set.
2. **Early two-layer era (`v7` and `v8`).**
   Native ntsync tests are added, but the PE default matrix is still smaller
   than the current one.
3. **Current default validation era (`v9`).**
   Two-layer suite remains, but the default PE matrix expands to 16 validation
   tests and moves perf-only probes out of the default set.

That means:

- `v4`, `v5`, and `v6` compare cleanly with each other.
- `v7` and `v8` compare cleanly with each other.
- `v9` is the current archived boundary and should be compared to later runs
  only if those runs keep the same default matrix shape.
- Totals across these families are not directly comparable because the number
  of layers and the number of default tests changed.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 350" xmlns="http://www.w3.org/2000/svg">
  <style>
    .cm-bg { fill: #1a1b26; }
    .cm-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .cm-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .cm-purple { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.7; rx: 8; }
    .cm-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.7; rx: 8; }
    .cm-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cm-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .cm-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .cm-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cm-tag-p { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cm-tag-y { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cm-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
    .cm-line-p { stroke: #bb9af7; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="350" class="cm-bg"/>
  <text x="480" y="26" text-anchor="middle" class="cm-title">Suite totals only compare within the same methodology family</text>

  <rect x="70" y="96" width="250" height="108" class="cm-box"/>
  <text x="195" y="120" text-anchor="middle" class="cm-label">PE-only matrix</text>
  <text x="195" y="144" text-anchor="middle" class="cm-small">`v3` -> `v6`</text>
  <text x="195" y="162" text-anchor="middle" class="cm-small">single-layer suite</text>
  <text x="195" y="180" text-anchor="middle" class="cm-small">small default PE set</text>

  <rect x="355" y="96" width="250" height="108" class="cm-purple"/>
  <text x="480" y="120" text-anchor="middle" class="cm-tag-p">two-layer, early shape</text>
  <text x="480" y="144" text-anchor="middle" class="cm-label">`v7` -> `v8`</text>
  <text x="480" y="162" text-anchor="middle" class="cm-small">native Layer 1 added</text>
  <text x="480" y="180" text-anchor="middle" class="cm-small">PE matrix still smaller than current</text>

  <rect x="640" y="96" width="250" height="108" class="cm-green"/>
  <text x="765" y="120" text-anchor="middle" class="cm-tag-g">current archived boundary</text>
  <text x="765" y="144" text-anchor="middle" class="cm-label">`v9-validation-default`</text>
  <text x="765" y="162" text-anchor="middle" class="cm-small">Layer 1 + 16-test default PE matrix</text>
  <text x="765" y="180" text-anchor="middle" class="cm-small">perf-only probes moved out of default suite</text>

  <line x1="320" y1="150" x2="355" y2="150" class="cm-line-p"/>
  <line x1="605" y1="150" x2="640" y2="150" class="cm-line-g"/>

  <rect x="250" y="250" width="460" height="56" class="cm-yellow"/>
  <text x="480" y="274" text-anchor="middle" class="cm-tag-y">practical rule</text>
  <text x="480" y="288" text-anchor="middle" class="cm-small">do not compare raw PASS totals across family boundaries</text>
  <text x="480" y="302" text-anchor="middle" class="cm-small">without normalizing the suite shape first</text>
</svg>
</div>

---

## 2. Current archived boundary

The current archived full-suite boundary is `v9-validation-default`
(`2026-05-03`).

| Layer | Result | Notes |
|---|---|---|
| Layer 1 native suite | `3 PASS / 0 FAIL / 0 SKIP` | `test-event-set-pi`, `test-channel-recv-exclusive`, `test-aggregate-wait` |
| Layer 2 PE matrix | `32 PASS / 0 FAIL / 0 TIMEOUT` | `16` default tests x `baseline` + `rt` |

Default PE test set in `v9-validation-default`:

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

This is the current archived comparison baseline. Later subsystem carries that
were validated only by targeted harnesses or workload A/Bs should not be
described as new matrix versions.

---

## 3. Methodology eras

### 3.1 `v3` through `v6`: PE-only matrix

This family uses a single PE runner and no native Layer 1. Its totals can be
compared internally, but not directly against later two-layer totals.

Typical characteristics:

- one layer only
- smaller PE test list
- perf and validation probes were less cleanly separated

### 3.2 `v7` and `v8`: two-layer suite introduced

`v7` adds the native ntsync suite and therefore changes the meaning of the
headline totals. `v8` keeps that same two-layer shape while adding
`dispatcher-burst` to the PE matrix.

Typical characteristics:

- Layer 1 native suite exists
- Layer 2 PE matrix is still smaller than the current default set
- dispatcher-specific PE coverage starts at `v8`

### 3.3 `v9`: current default validation shape

`v9-validation-default` keeps the two-layer structure but changes the PE matrix
shape again:

- default PE matrix expands to 16 tests
- `nt-timer`, `wm-timer`, `rpc-bypass`, and `irot-bypass` are part of the
  default validation set
- perf-only probes stay opt-in rather than inflating the default matrix

This is the current methodology family the public docs should treat as the live
comparison baseline.

---

## 4. Version summary

| Version | Date | Methodology family | Headline boundary |
|---|---|---|---|
| `v3` -> `v4` | `2026-04-15` | PE-only matrix | `20/20 PASS` PE matrix |
| `v4` -> `v5` | `2026-04-15` | PE-only matrix | `20/20 PASS` PE matrix |
| `v5` -> `v6` | `2026-04-16/17` | PE-only matrix | stable PE-only matrix; no suite-family change |
| `v7` | `2026-04-28` | early two-layer | Layer 1 native suite added; Layer 2 `22/22 PASS` |
| `v8` | `2026-04-30` | early two-layer | Layer 1 `3 PASS / 0 FAIL`; Layer 2 `24 PASS / 0 FAIL / 0 TIMEOUT` |
| `v9-validation-default` | `2026-05-03` | current default validation shape | Layer 1 `3 PASS / 0 FAIL / 0 SKIP`; Layer 2 `32 PASS / 0 FAIL / 0 TIMEOUT` |

### What changed at each boundary

| Boundary | Practical change |
|---|---|
| `v6` -> `v7` | native ntsync Layer 1 enters the public suite |
| `v7` -> `v8` | `dispatcher-burst` enters the default PE matrix |
| `v8` -> `v9` | default PE matrix expands to 16 tests and the current validation shape stabilizes |

---

## 5. Reading historical numbers

- Use raw PASS totals only within the same methodology family.
- Use micro-bench or latency deltas only when the harness shape is unchanged.
- Treat targeted validators as subsystem evidence, not as replacement matrix totals.
- If a newer run changes the default test set again, mint a new methodology
  boundary rather than pretending the old totals still compare directly.

For the current harness structure, default test list, and runner behavior, see
[nspa-rt-test](nspa-rt-test.gen.html).
