# Wine-NSPA -- Hot-Path Optimizations

This page documents implementation-level optimizations that reduce Wine-side
overhead without changing feature boundaries or public API shape, and the
design choices behind them.

## Table of Contents

1. [Overview](#1-overview)
2. [Optimization classes](#2-optimization-classes)
3. [Locality and published-state caching](#3-locality-and-published-state-caching)
4. [TEB-relative hot state](#4-teb-relative-hot-state)
5. [Cache and slab layout](#5-cache-and-slab-layout)
6. [Small-call removal on the wait path](#6-small-call-removal-on-the-wait-path)
7. [String and Unicode vectorization](#7-string-and-unicode-vectorization)
8. [GUI and flush-path trims](#8-gui-and-flush-path-trims)
9. [Current measured effect](#9-current-measured-effect)
10. [Related docs](#10-related-docs)

---

## 1. Overview

Wine-NSPA carries several classes of optimizations that are not new bypass
surfaces by themselves. They make existing fast paths cheaper: more
local answers from already-published state, fewer libc TLS lookups, fewer
cross-DSO helper calls, better cacheline and slab layout, and less pointless
work on already-empty or already-local paths.

These optimizations matter because the remaining hot code paths are already
short. Once a request or wait is mostly local, wrapper overhead becomes visible.
That makes the “why this implementation choice?” question worth documenting,
not just the “what got faster?” result.

Wine-NSPA also makes some deliberately narrower platform choices than upstream
Wine. The project is Linux-only, and a subset of the newest hot-path carries is
Linux-x86_64-specific. That is visible here: some optimizations exploit Linux
futex, `io_uring`, and ntsync behavior generally, while others rely on the
x86_64 TEB / GS-base setup specifically.

---

## 2. Optimization classes

| Class | Current use | Why this choice fits |
|---|---|---|
| Locality and published-state caching | hook Tier 1+2, paint cache, `get_message` empty-poll cache, thread/process shared-state readers, and zero-time wait polls answer locally once state is already published | these paths already had an authoritative shared state block, so the win is to reuse it instead of inventing another transport |
| TEB-relative state access | unix-side `NtCurrentTeb` is inline on Linux x86_64, `get_thread_data()` reads through a TEB backpointer, common thread/process/PEB helpers read from the TEB, and win32u msg-ring per-thread caches read through `TEB->Win32ClientInfo` | repeated thread-local helper calls were pure wrapper cost, so direct TEB reads preserve ownership while removing libc / PLT overhead |
| Cacheline and slab layout | `struct inproc_sync` entries are padded to one cacheline each, ntsync hot structs use dedicated caches, and the production kernel keeps those caches isolated with `SLAB_NO_MERGE` | the work was already concurrent and hot, so layout and allocator shaping reduce coherence and slab noise without changing behavior |
| Batching and burst drain | gamma `TRY_RECV2` drains bursts after one aggregate-wait wake instead of paying one kernel round-trip per entry | request bursts are real, so the right optimization is to amortize wake cost rather than only shave single-request overhead |
| Small helper removal | `ntdll_io_uring_flush_deferred()` folds to an inline empty check when no deferred completions exist, the ring eventfd getter is inline, and `NtGetTickCount()` folds to one KUSER_SHARED_DATA load | once a helper becomes “usually empty” or “just return one TLS value,” the abstraction cost outweighs the abstraction value on the hot path |
| SIMD ASCII-burst loops | `memicmp_strW`, `hash_strW`, `utf8_wcstombs`, and `utf8_mbstowcs` use x86_64 AVX2 fast paths for all-ASCII windows while keeping scalar fallback for mixed or non-ASCII windows | filenames, registry names, and object names are often ASCII-dominant, so vectorizing the common window harvests real cost without changing the Unicode contract |
| GUI / memory-copy tightening | flush throttling and the AVX2 X11 alpha-bit flush loop cut repeated GUI flush overhead without changing surface semantics | these are stable high-frequency loops, so throttling and vectorization fit better than architectural rewrites |

These are intentionally distinct from larger architectural features such as
gamma, local-file, or shared-state readers. The feature pages explain the
surfaces. This page explains the recurring optimization patterns that make
those surfaces cheaper once they are already in place.

---

## 3. Locality and published-state caching

One optimization class shows up throughout Wine-NSPA: publish a small,
authoritative, read-mostly state block once, then answer the common case
locally until that state changes.

| Surface | Published state | Local win |
|---|---|---|
| Hook cache | queue-shared hook metadata | no per-dispatch hook lookup RPC on the common path |
| Paint cache | queue-shared redraw state | repeated paint probes avoid needless server work |
| `get_message` empty-poll cache | filter tuple + `queue_shm->nspa_change_seq` | same empty poll does not pay the same RPC twice |
| Thread / process shared-state | shared object snapshots with seqlock discipline | 7 thread query classes, 6 process query classes, and zero-time waits answer locally |
| Gamma thread-token return | kernel returns the registered sender token | dispatcher avoids a second userspace thread lookup on each request |

The shapes differ, but the pattern is the same:

- publish authoritative state once
- cache a small local handle or filter mapping
- answer the cheap repeat case locally
- fall back immediately when the local predicate is not trustworthy

This is why so many of the project’s measurable wins come from “small” caches.
The point is not speculative behavior. It is to stop paying for the same answer
over and over when the state already exists locally.

---

## 4. TEB-relative hot state

The current x86_64 Unix-side hot path avoids repeated libc TLS lookups by
reading thread-local Wine state from the TEB and adjacent per-thread structs.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 360" xmlns="http://www.w3.org/2000/svg">
  <style>
    .tp-bg { fill: #1a1b26; }
    .tp-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .tp-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .tp-purple { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.7; rx: 8; }
    .tp-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.7; rx: 8; }
    .tp-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .tp-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .tp-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .tp-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .tp-tag-p { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .tp-tag-y { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .tp-line-b { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .tp-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
    .tp-line-p { stroke: #bb9af7; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="360" class="tp-bg"/>
  <text x="480" y="26" text-anchor="middle" class="tp-title">TEB-relative hot state replaces repeated TLS helper calls</text>

  <rect x="50" y="76" width="230" height="102" class="tp-box"/>
  <text x="165" y="102" text-anchor="middle" class="tp-label">hot Wine-side caller</text>
  <text x="165" y="124" text-anchor="middle" class="tp-small">msg-ring, wait path, queue access, signal helpers</text>
  <text x="165" y="146" text-anchor="middle" class="tp-small">used to bounce through `NtCurrentTeb()` / `pthread_getspecific()`</text>

  <rect x="350" y="56" width="260" height="142" class="tp-green"/>
  <text x="480" y="82" text-anchor="middle" class="tp-tag-g">current x86_64 path</text>
  <text x="480" y="108" text-anchor="middle" class="tp-label">inline `NtCurrentTeb()`</text>
  <text x="480" y="128" text-anchor="middle" class="tp-small">single `mov %gs:0x30, %reg` on Linux x86_64</text>
  <text x="480" y="154" text-anchor="middle" class="tp-label">unix-side thread data backpointer</text>
  <text x="480" y="174" text-anchor="middle" class="tp-small">`get_thread_data()` reads via `TEB->GdiTebBatch` extension</text>

  <rect x="680" y="56" width="230" height="142" class="tp-purple"/>
  <text x="795" y="82" text-anchor="middle" class="tp-tag-p">win32u follow-on</text>
  <text x="795" y="108" text-anchor="middle" class="tp-label">msg-ring per-thread caches</text>
  <text x="795" y="128" text-anchor="middle" class="tp-small">`nspa_msg_cache` and `nspa_own_bypass` live in `Win32ClientInfo`</text>
  <text x="795" y="154" text-anchor="middle" class="tp-label">hot reads stay inside the TEB</text>
  <text x="795" y="174" text-anchor="middle" class="tp-small">slow path still registers destructor state when needed</text>

  <line x1="280" y1="128" x2="350" y2="128" class="tp-line-b"/>
  <line x1="610" y1="128" x2="680" y2="128" class="tp-line-p"/>

  <rect x="150" y="238" width="660" height="86" class="tp-yellow"/>
  <text x="480" y="264" text-anchor="middle" class="tp-tag-y">measured effect on the playback path</text>
  <text x="480" y="286" text-anchor="middle" class="tp-small">`NtCurrentTeb` function calls: `9,961,441 -> 566` per 30 s</text>
  <text x="480" y="302" text-anchor="middle" class="tp-small">cumulative cycles after both carries: `257.8B -> 212.4B` (`-17.6%`)</text>
 </svg>
</div>

### 4.1 Inline `NtCurrentTeb()` on x86_64

On Linux x86_64, Wine-NSPA keeps `GS_BASE = teb` from thread startup, so
most Unix-side callers can inline `NtCurrentTeb()` instead of paying a
cross-DSO `pthread_getspecific()` call chain. This is intentionally narrower
than upstream Wine's portability envelope: it trades portability for a cheaper
thread anchor on the platform Wine-NSPA actually targets.

Measured on a 30-second Ableton playback capture:

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| CPU cycles | `257.8B` | `220.9B` | `-14.3%` |
| Instructions | `309.1B` | `269.7B` | `-12.7%` |
| IPC | `1.20` | `1.221` | `+1.7%` |
| iTLB-load-misses | `242M` | `185M` | `-23.4%` |
| LLC-load-misses | `537M` | `482M` | `-10.2%` |
| `NtCurrentTeb` function calls / 30 s | `9,961,441` | `566` | `-99.994%` |

This is Linux-x86_64-specific by design. The public point is not the assembly
detail. It is that a foundational thread-state accessor is no longer hot, and
that Wine-NSPA is willing to use a Linux-x86_64-specific setup when the win is
load-bearing on its target platform.

### 4.2 Msg-ring per-thread caches via the TEB

The msg-ring hot path reads both of its per-thread caches from
`struct user_thread_info` inside `TEB->Win32ClientInfo`:

- peer cache: `nspa_msg_cache`
- own queue-bypass mapping cache: `nspa_own_bypass`

That removes repeated `pthread_getspecific()` reads from the message path while
keeping the destructor-bearing slow path intact for the peer cache. The choice
here was not “invent a new cache.” It was “keep the current cache model, but
move the hot lookup into the TEB.”

Measured on the same workload, on top of the inline `NtCurrentTeb()` carry:

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| CPU cycles | `220.9B` | `212.4B` | `-3.84%` |
| Instructions | `269.7B` | `262.8B` | `-2.55%` |
| iTLB-load-misses | `185M` | `181M` | `-2.21%` |
| `pthread_getspecific` self time | `0.46%` | `0.09%` | `-80%` |
| `nspa_get_own_bypass_shm` | `0.26%` | `0.20%` | `-23%` |
| `get_shared_queue` | `1.70%` | `1.61%` | `-5%` |

### 4.3 Inline process/thread/PEB/tick helpers on x86_64

The same x86_64 TEB foundation also shrinks a second layer of helper cost on
the Unix side.

| Helper family | Current path | Source |
|---|---|---|
| `PsGetCurrentProcessId()` / `PsGetCurrentThreadId()` | inline TEB-relative read via `unix_private.h` | `ClientId` and thread-local unix state are already published in the TEB path |
| `RtlGetCurrentPeb()` | inline TEB-relative read on the Unix side | avoids a separate out-of-line helper for a fixed per-thread pointer |
| `GetCurrentProcessId()` / `GetCurrentThreadId()` in `WINE_UNIX_LIB` | macro parity with the PE-side `ClientId` read | removes an extra unix-thread-data load from hot ntsync and server-call sites |
| `NtGetTickCount()` | one `KUSER_SHARED_DATA::TickCount.LowPart` load | avoids a PLT thunk and function frame on a call site measured at `~3.08M` calls / 30 s |

These carries are small individually, but they all fit the same rule: once the
TEB and `KUSER_SHARED_DATA` are already the authoritative source, the hot Unix
path should read them directly instead of wrapping the same answer in another
function call.

---

## 5. Cache and slab layout

The current `inproc_sync` cache is optimized for concurrent hot waits and
signals, not just for compact storage. The same optimization class also shows
up in the kernel overlay: the hot ntsync allocation classes live in
dedicated caches, and the production kernel keeps those caches isolated.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 360" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ic-bg { fill: #1a1b26; }
    .ic-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .ic-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .ic-red { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.7; rx: 8; }
    .ic-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.7; rx: 8; }
    .ic-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ic-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .ic-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .ic-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ic-tag-r { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ic-tag-y { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ic-line-r { stroke: #f7768e; stroke-width: 1.2; fill: none; }
    .ic-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="360" class="ic-bg"/>
  <text x="480" y="26" text-anchor="middle" class="ic-title">`inproc_sync` cache: one entry per cacheline, original handle capacity restored</text>

  <rect x="60" y="74" width="340" height="124" class="ic-red"/>
  <text x="230" y="100" text-anchor="middle" class="ic-tag-r">old layout</text>
  <text x="230" y="126" text-anchor="middle" class="ic-label">16-byte entries packed 4 per 64-byte cacheline</text>
  <text x="230" y="146" text-anchor="middle" class="ic-small">unrelated waits/signals still shared one line</text>
  <text x="230" y="162" text-anchor="middle" class="ic-small">every refcount `LOCK` op invalidated peers on other CPUs</text>
  <text x="230" y="182" text-anchor="middle" class="ic-small">hot cost showed up as distributed coherence pressure</text>

  <rect x="560" y="74" width="340" height="124" class="ic-green"/>
  <text x="730" y="100" text-anchor="middle" class="ic-tag-g">current layout</text>
  <text x="730" y="126" text-anchor="middle" class="ic-label">64-byte aligned entries, one cacheline each</text>
  <text x="730" y="146" text-anchor="middle" class="ic-small">different handles no longer false-share refcount traffic</text>
  <text x="730" y="162" text-anchor="middle" class="ic-small">same layout retained after capacity restore</text>
  <text x="730" y="182" text-anchor="middle" class="ic-small">block size widened to keep `524288` cacheable handles</text>

  <line x1="400" y1="136" x2="560" y2="136" class="ic-line-r"/>

  <rect x="210" y="238" width="540" height="76" class="ic-yellow"/>
  <text x="480" y="264" text-anchor="middle" class="ic-tag-y">current public contract</text>
  <text x="480" y="286" text-anchor="middle" class="ic-small">faster concurrent wait/signal traffic with the same behavior</text>
  <text x="480" y="302" text-anchor="middle" class="ic-small">capacity still stays at `524288` handles after the block-size increase</text>
</svg>
</div>

### 5.1 Userspace `inproc_sync` layout

The first layout carry padded `struct inproc_sync` to one cacheline so refcount
`LOCK` traffic no longer ping-ponged unrelated handles on the same line. The
follow-on widened each cache block from 64 KiB to 256 KiB so the total cached
handle capacity stayed at `524288` after the padding change.

This is a pure internal layout change. It does not alter the handle protocol or
the wait/signal API surface.

---

### 5.2 Kernel-side ntsync cache shaping

The same “shape the allocator around the hot object” pattern also exists in the
kernel overlay:

| Kernel-side optimization | Effect |
|---|---|
| dedicated `kmem_cache`s for hot ntsync objects | hot small allocations stop competing with unrelated slab users |
| `SLAB_HWCACHE_ALIGN` | hot fields land on cacheline-friendly boundaries |
| dedicated `ntsync_wait_q` cache | common wait objects stop using the generic path |
| `SLAB_NO_MERGE` on all four ntsync caches | cache isolation remains true on the production kernel, not just in theory |

These are not user-visible features, but they matter to the same workloads the
userspace cacheline work targets: lots of short waits, signals, and channel
operations on PREEMPT_RT under real contention.

---

## 6. Small-call removal on the wait path

Some of the remaining hot-path cost was not algorithmic at all. It was helper
overhead on paths that were already almost always empty or already local.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 320" xmlns="http://www.w3.org/2000/svg">
  <style>
    .sw-bg { fill: #1a1b26; }
    .sw-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .sw-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .sw-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.7; rx: 8; }
    .sw-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .sw-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .sw-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .sw-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .sw-tag-y { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .sw-line-b { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .sw-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="320" class="sw-bg"/>
  <text x="480" y="26" text-anchor="middle" class="sw-title">Small helper overhead removed from the steady-state wait path</text>

  <rect x="60" y="82" width="250" height="86" class="sw-box"/>
  <text x="185" y="108" text-anchor="middle" class="sw-label">`ntdll_io_uring_flush_deferred()`</text>
  <text x="185" y="130" text-anchor="middle" class="sw-small">current steady state has no deferred queue users</text>
  <text x="185" y="146" text-anchor="middle" class="sw-small">inline check folds away the empty fast path</text>

  <rect x="355" y="82" width="250" height="86" class="sw-green"/>
  <text x="480" y="108" text-anchor="middle" class="sw-tag-g">wait-path result</text>
  <text x="480" y="130" text-anchor="middle" class="sw-small">audio-path no-op helper cost removed</text>
  <text x="480" y="146" text-anchor="middle" class="sw-small">measured at `0.82%` of audio-thread time before the carry</text>

  <rect x="650" y="82" width="250" height="86" class="sw-box"/>
  <text x="775" y="108" text-anchor="middle" class="sw-label">`ntdll_io_uring_get_eventfd()`</text>
  <text x="775" y="130" text-anchor="middle" class="sw-small">getter reads the TLS ring eventfd inline</text>
  <text x="775" y="146" text-anchor="middle" class="sw-small">measured helper self-time `0.15%` before the carry</text>

  <line x1="310" y1="126" x2="355" y2="126" class="sw-line-b"/>
  <line x1="605" y1="126" x2="650" y2="126" class="sw-line-g"/>

  <rect x="180" y="220" width="600" height="58" class="sw-yellow"/>
  <text x="480" y="244" text-anchor="middle" class="sw-tag-y">common theme</text>
  <text x="480" y="262" text-anchor="middle" class="sw-small">once the real work is already local, tiny empty or one-value helpers</text>
  <text x="480" y="278" text-anchor="middle" class="sw-small">become visible enough to inline away</text>
</svg>
</div>

These are small on their own. Together they keep the wait path from carrying
old scaffold cost after the architectural reason for that scaffold has gone.

---

## 7. String and Unicode vectorization

The current x86_64 AVX2 carries also trim a different class of hot loop:
short, repeated string and Unicode helpers that sit on the path-resolution,
registry, object-name, and locale-conversion surfaces. These are not new
features. They are implementation-level reductions in per-call cost on paths
that are already semantically local.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .sv-bg { fill: #1a1b26; }
    .sv-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .sv-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .sv-purple { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.7; rx: 8; }
    .sv-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.7; rx: 8; }
    .sv-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .sv-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .sv-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .sv-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .sv-tag-p { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .sv-tag-y { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .sv-line-b { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .sv-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
    .sv-line-p { stroke: #bb9af7; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="420" class="sv-bg"/>
  <text x="480" y="26" text-anchor="middle" class="sv-title">x86_64 AVX2 fast paths keep ASCII bursts vectorized and edge cases scalar</text>

  <rect x="70" y="74" width="360" height="128" class="sv-box"/>
  <text x="250" y="98" text-anchor="middle" class="sv-label">server/unicode hot loops</text>
  <text x="250" y="122" text-anchor="middle" class="sv-small">`memicmp_strW`: 16-WCHAR ASCII compare + fold window</text>
  <text x="250" y="142" text-anchor="middle" class="sv-small">`hash_strW`: 8-WCHAR weighted Horner window</text>
  <text x="250" y="166" text-anchor="middle" class="sv-small">common call sites: object names, registry traversal, handle lookup</text>
  <text x="250" y="186" text-anchor="middle" class="sv-small">non-ASCII windows fall back to scalar `to_lower()` logic</text>

  <rect x="530" y="74" width="360" height="128" class="sv-purple"/>
  <text x="710" y="98" text-anchor="middle" class="sv-tag-p">ntdll locale helpers</text>
  <text x="710" y="122" text-anchor="middle" class="sv-label">`utf8_wcstombs`: 16 WCHAR -> 16 byte ASCII burst</text>
  <text x="710" y="142" text-anchor="middle" class="sv-label">`utf8_mbstowcs`: 16 byte -> 16 WCHAR ASCII burst</text>
  <text x="710" y="166" text-anchor="middle" class="sv-small">common call sites: NT path conversion, registry names, section names</text>
  <text x="710" y="186" text-anchor="middle" class="sv-small">multi-byte UTF-8 and surrogate cases stay on the scalar path</text>

  <rect x="130" y="254" width="260" height="84" class="sv-green"/>
  <text x="260" y="278" text-anchor="middle" class="sv-tag-g">common fast-path rule</text>
  <text x="260" y="300" text-anchor="middle" class="sv-small">if the window is all ASCII and large enough,</text>
  <text x="260" y="318" text-anchor="middle" class="sv-small">vectorize the whole block and advance</text>

  <rect x="570" y="254" width="260" height="84" class="sv-yellow"/>
  <text x="700" y="278" text-anchor="middle" class="sv-tag-y">contract rule</text>
  <text x="700" y="300" text-anchor="middle" class="sv-small">mixed/non-ASCII windows do not reinterpret semantics</text>
  <text x="700" y="318" text-anchor="middle" class="sv-small">they reuse the existing scalar path unchanged</text>

  <line x1="250" y1="202" x2="260" y2="254" class="sv-line-b"/>
  <line x1="710" y1="202" x2="700" y2="254" class="sv-line-p"/>
  <line x1="390" y1="296" x2="570" y2="296" class="sv-line-g"/>
</svg>
</div>

### 7.1 Server Unicode compare and hash

The wineserver name path now has two x86_64 AVX2 ASCII-window carries in
`server/unicode.c`:

| Helper | AVX2 fast window | Scalar reuse |
|---|---|---|
| `memicmp_strW` | 16 `WCHAR`s at a time, ASCII-only window, SIMD case-fold and compare | short strings and any non-ASCII window reuse the scalar `to_lower()` compare |
| `hash_strW` | 8 `WCHAR`s at a time, ASCII-only window, weighted Horner unroll with vector multiply | short strings and any non-ASCII window reuse the scalar Horner loop |

These helpers are hot because object-name and registry paths repeatedly compare
and hash short Unicode names. The vectorization is deliberately narrower than
"SIMD all Unicode": it only harvests the ASCII-dominant windows and preserves
the older scalar path for the rest.

Synthetic ASCII-path measurements recorded with the carry:

| Helper | Before | After | Delta |
|---|---:|---:|---:|
| `memicmp_strW` (50 `WCHAR` ASCII) | `~250 cycles` | `~12 cycles` | `~20x` |
| `hash_strW` (50 `WCHAR` ASCII) | `~150 cycles` | `~38 cycles` | `~4x` |

### 7.2 Locale conversion helpers

The Unix-side locale helpers in `dlls/ntdll/locale_private.h` now have matching
x86_64 AVX2 ASCII-burst paths:

| Helper | AVX2 fast window | Scalar reuse |
|---|---|---|
| `utf8_wcstombs` | 16 `WCHAR`s detected as ASCII, packed to 16 bytes and stored in one burst | short buffers, non-ASCII `WCHAR`s, and surrogate pairs remain scalar |
| `utf8_mbstowcs` | 16 source bytes detected as ASCII, zero-extended to 16 `WCHAR`s and stored in one burst | short buffers, multi-byte UTF-8, and invalid UTF-8 remain scalar |

These conversions sit on every PE-to-Unix and Unix-to-PE path/name boundary.
That makes them worth optimizing even though they are small helpers in
isolation: the same directory, registry, and section-name traffic that hits the
shared-state and local-file work also keeps crossing these conversion helpers.

Synthetic ASCII-path measurements recorded with the carries:

| Helper | Before | After | Delta |
|---|---:|---:|---:|
| `utf8_wcstombs` (200-byte ASCII path) | `~500 cycles` | `~25 cycles` | `~20x` |
| `utf8_mbstowcs` (200-byte ASCII path) | `~1000 cycles` | `~40 cycles` | `~25x` |

The architectural point is the same as the TEB carries: once the remaining hot
path is dominated by wrapper work on an already-local operation, a narrow
platform-specific implementation can be the right trade.

---

## 8. GUI and flush-path trims

Two GUI-side optimizations remain part of the current baseline:

| Optimization | Before | After | Delta |
|---|---:|---:|---:|
| `x11drv_surface_flush` throttle | `8.23%` | `4.74%` | `-43%` |
| `copy_rect_32` memmove | `4.38%` | `2.49%` | `-43%` |
| `x11drv_surface_flush` AVX2 | `6.72%` | `2.39%` | `-4.33pp / -64%` |
| total `winex11.so` after AVX2 | `6.76%` | `2.43%` | `-4.33pp` |

These are feature-adjacent because they live on the GUI path, but they are
still optimizations rather than new surfaces. The relevant architecture is
unchanged; the hot implementation is just cheaper.

---

## 9. Current measured effect

The current optimization stack is measured with a three-part profiling pass on
the same workload window:

- system-wide `perf stat` hardware counters over 30 seconds
- system-wide `perf record` DWARF callgraph over 30 seconds
- `bpftrace` Nt* entry distribution over 30 seconds

For the most recent x86_64 inline + AVX2 bundle, the comparison window is:

| Capture | Baseline | After |
|---|---|---|
| workload | Ableton project + browse + plugin + steady playback | same workload shape |
| baseline window | `2026-05-09 12:06` |  |
| post-bundle window |  | `2026-05-10 18:00` |
| bundle scope |  | inline current-thread/current-process/PEB/tick helpers plus AVX2 `memicmp_strW`, `hash_strW`, `utf8_wcstombs`, and `utf8_mbstowcs` |

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 410" xmlns="http://www.w3.org/2000/svg">
  <style>
    .me-bg { fill: #1a1b26; }
    .me-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .me-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .me-purple { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.7; rx: 8; }
    .me-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.7; rx: 8; }
    .me-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .me-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .me-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .me-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .me-tag-p { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .me-tag-y { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .me-line-b { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .me-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
    .me-line-p { stroke: #bb9af7; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="410" class="me-bg"/>
  <text x="480" y="26" text-anchor="middle" class="me-title">2026-05-10 inline + AVX2 bundle: why the carries matter together</text>

  <rect x="40" y="70" width="255" height="116" class="me-box"/>
  <text x="168" y="94" text-anchor="middle" class="me-label">bundle inputs</text>
  <text x="168" y="118" text-anchor="middle" class="me-small">inline current-thread/current-process/PEB/tick helpers</text>
  <text x="168" y="136" text-anchor="middle" class="me-small">inline `NtGetTickCount()` and TEB-relative helper collapse</text>
  <text x="168" y="154" text-anchor="middle" class="me-small">AVX2 ASCII-window compare, hash, and UTF conversion loops</text>
  <text x="168" y="172" text-anchor="middle" class="me-small">all on the already-local hot paths</text>

  <rect x="352" y="70" width="255" height="116" class="me-purple"/>
  <text x="480" y="94" text-anchor="middle" class="me-tag-p">locality effect</text>
  <text x="480" y="118" text-anchor="middle" class="me-small">fewer helper frames and indirect branches</text>
  <text x="480" y="136" text-anchor="middle" class="me-small">hot code and hot state stay in tighter cache windows</text>
  <text x="480" y="154" text-anchor="middle" class="me-small">same contracts, less wrapper work around them</text>

  <rect x="664" y="70" width="255" height="116" class="me-green"/>
  <text x="792" y="94" text-anchor="middle" class="me-tag-g">measured result</text>
  <text x="792" y="118" text-anchor="middle" class="me-small">user samples `97K -> 86K` (`-11.3%`)</text>
  <text x="792" y="136" text-anchor="middle" class="me-small">iTLB `229.7M -> 180.8M` (`-21.3%`)</text>
  <text x="792" y="154" text-anchor="middle" class="me-small">dTLB `51.5M -> 42.4M` (`-17.7%`)</text>
  <text x="792" y="172" text-anchor="middle" class="me-small">branch-miss `348.3M -> 308.4M` (`-11.45%`)</text>

  <line x1="295" y1="128" x2="352" y2="128" class="me-line-b"/>
  <line x1="607" y1="128" x2="664" y2="128" class="me-line-g"/>

  <rect x="110" y="246" width="740" height="104" class="me-yellow"/>
  <text x="480" y="272" text-anchor="middle" class="me-tag-y">load-bearing read</text>
  <text x="480" y="292" text-anchor="middle" class="me-small">this bundle is not "one fast function"</text>
  <text x="480" y="306" text-anchor="middle" class="me-small">it is a compound locality win across the same call graph</text>
  <text x="480" y="320" text-anchor="middle" class="me-small">the counter signature is tighter instruction-TLB use, tighter data-TLB use,</text>
  <text x="480" y="334" text-anchor="middle" class="me-small">fewer branches, and lower user CPU</text>
</svg>
</div>

### 9.1 Current triplet-diff result

The newest bundle confirms the main point of this page: once the dominant work
is already local, shaving helper layers and tightening hot loops compounds.

| Counter | Baseline | Post-bundle | Delta |
|---|---:|---:|---:|
| cpu-cycles | `227.0B` | `223.1B` | `-1.73%` |
| instructions | `273.3B` | `269.1B` | `-1.55%` |
| iTLB-load-misses | `229.7M` | `180.8M` | `-21.30%` |
| dTLB-load-misses | `51.5M` | `42.4M` | `-17.69%` |
| dTLB-store-misses | `16.9M` | `14.8M` | `-12.49%` |
| branch-misses | `348.3M` | `308.4M` | `-11.45%` |
| cache-references | `3.87B` | `3.49B` | `-9.73%` |
| cache-misses | `2.11B` | `1.99B` | `-5.80%` |
| LLC-load-misses | `499.3M` | `491.7M` | `-1.52%` |
| LLC-store-misses | `519.1M` | `550.0M` | `+5.97%` |
| context-switches | `1,463K` | `1,417K` | `-3.19%` |
| cpu-migrations | `144,103` | `133,448` | `-7.39%` |
| page-faults | `130,349` | `71,754` | `-44.95%` |
| IPC | `1.204` | `1.206` | `flat` |

The key read is not any single micro-benchmark number. It is the compound
signature:

- iTLB `-21.30%`
- dTLB `-17.69%`
- branch-misses `-11.45%`
- user-mode samples `-11.3%`

That is what "same work in less of everything" looks like for this kind of
bundle.

### 9.2 Dispatcher-entry confirmation

The Nt* distribution capture confirms that the helper inlining is visible at
the entrypoint level, not only in synthetic loops.

| Nt entry | Baseline | Post-bundle | Delta |
|---|---:|---:|---:|
| `NtGetTickCount` | `3,081,551` | `0 (absent)` | `-100%` |
| `NtSetEvent` | `3,269,629` | `5,586,449` | `+70.9%` |
| `NtQueryPerformanceCounter` | `3,075,360` | `5,392,023` | `+75.3%` |
| `NtWaitForMultipleObjects` | `3,071,442` | `5,387,977` | `+75.4%` |
| `NtResetEvent` | `175,029` | `174,835` | `flat` |
| `NtWaitForSingleObject` | `170,050` | `170,172` | `flat` |
| `NtQuerySystemTime` | `58,676` | `58,997` | `flat` |
| `NtFlushInstructionCache` | `13,764` | `16,380` | `+19.0%` |
| `NtCurrentTeb` fallback | `448` | `548` | `both ~negligible` |

`NtGetTickCount` dropping from `3,081,551` to `0` is the clearest
end-to-end confirmation in the set: the inline path is not theoretical, it has
removed the dispatcher-visible entry entirely on this workload.

The large rises on `NtSetEvent`, `NtQueryPerformanceCounter`, and
`NtWaitForMultipleObjects` are most likely workload-phase differences between
the two captures. If they do reflect real extra traffic, the fact that cycles
and user-mode samples still fall means the per-entry cost is lower, not higher.

### 9.3 Callgraph read

The callgraph view turns the same result into a user-CPU number:

- total user-mode samples: `97K -> 86K` (`-11.3%`)

Post-bundle, the NSPA-local fast-path surface is easier to see directly in the
resolved top symbols:

- `inproc_wait`
- `get_cached_inproc_sync`
- `nspa_try_pop_own_ring_post`
- `nspa_try_pop_own_timer_ring`
- `nspa_try_pop_own_ring_send`
- `nspa_get_own_bypass_shm`
- `nspa_getmsg_cache_record_empty`
- `nspa_getmsg_cache_lookup`

That matters because the relative percentages on untouched shared symbols can
be misleading once the denominator falls. Symbols such as libc bulk-copy
helpers, `apply_alpha_bits_avx2`, or `entry_SYSCALL_64` may rise in share even
when their absolute weight is flat, simply because the total user sample pool
got smaller.

### 9.4 Bundle interpretation

Taken together, the newest hot-path carries changed three important things:

- repeat answers stay local more often because the relevant state is
  already published or cached
- thread-local Wine state is mostly read directly from the TEB instead of
  repeatedly crossing through libc TLS helpers
- high-frequency in-process sync entries no longer false-share refcount traffic
  across unrelated handles
- ntsync hot allocation classes and waits have cache-aware storage on both the
  userspace and kernel sides
- older dormant helper calls are gone from the steady-state wait path
- common current-thread, current-process, PEB, and tick-count helpers collapse
  to direct TEB or `KUSER_SHARED_DATA` reads on Linux x86_64
- ASCII-dominant name and locale loops vectorize whole windows on x86_64 AVX2
  while keeping the scalar Unicode edge handling intact

That is why these changes belong together even though they touch different
files. The common result is lower wrapper cost around work that was already
largely local.

---

## 10. Related docs

- [Architecture Overview](architecture.gen.html)
- [Message Ring Architecture](msg-ring-architecture.gen.html)
- [NTSync Userspace Sync](ntsync-userspace.gen.html)
- [Thread and Process Shared-State Bypass](thread-and-process-shared-state.gen.html)
- [io_uring I/O Architecture](io_uring-architecture.gen.html)
- [Memory, Sections, Large Pages, and Working-Set Support](memory-and-large-pages.gen.html)
- [State of The Art](current-state.gen.html)
