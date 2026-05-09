# Wine-NSPA -- Thread and Process Shared-State Bypass

This page documents the shipped shared-state bypass for read-mostly thread and
process queries, plus the zero-time process and thread wait fast paths built on
the same published snapshots.

## Table of Contents

1. [Overview](#1-overview)
2. [What is shipped](#2-what-is-shipped)
3. [Architecture](#3-architecture)
4. [Thread query coverage](#4-thread-query-coverage)
5. [Process query coverage and zero-time waits](#5-process-query-coverage-and-zero-time-waits)
6. [Correctness boundaries](#6-correctness-boundaries)
7. [Related docs](#7-related-docs)

---

## 1. Overview

Wine already had an upstream shared-object publication mechanism for queue,
window, class, input, and desktop state. Wine-NSPA now extends that same
seqlock-published shape to thread and process state, so a set of
`NtQueryInformationThread()` and `NtQueryInformationProcess()` classes can be
answered from shared memory instead of a wineserver RPC.

The same published state now also powers zero-time `WaitForSingleObject()`
polls for process and thread handles. For those single-handle, non-alertable,
timeout-0 waits, ntdll can answer from the shared snapshot instead of paying an
ntsync wait ioctl.

---

## 2. What is shipped

| Surface | Shipped behavior |
|---|---|
| Thread shared-state publication | wineserver publishes a per-thread shared object with seqlock update discipline and a per-handle locator RPC (`get_thread_shm`) for first resolve |
| Process shared-state publication | wineserver publishes a per-process shared object with the same seqlock shape and a matching first-resolve RPC (`get_process_shm`) |
| Thread query bypass | 7 `NtQueryInformationThread()` classes are served shmem-first with RPC fallback |
| Process query bypass | 6 `NtQueryInformationProcess()` classes are served shmem-first with RPC fallback |
| Zero-time thread wait | `WaitForSingleObject(thread, 0)` can answer from `thread_shm` and skip the ntsync ioctl on a hit |
| Zero-time process wait | `WaitForSingleObject(process, 0)` can answer from `process_shm` and skip the ntsync ioctl on a hit |
| Cache discipline | first use resolves the locator once; later reads are local; stale-slot detection and negative-cache entries force safe fallback instead of silent drift |

The shipped query coverage is:

- Thread: `ThreadAffinityMask`, `ThreadQuerySetWin32StartAddress`,
  `ThreadGroupInformation`, `ThreadIsTerminated`, `ThreadSuspendCount`,
  `ThreadHideFromDebugger`, `ThreadPriorityBoost`
- Process: `ProcessBasicInformation`, `ProcessTimes`, `ProcessPriorityBoost`,
  `ProcessAffinityMask`, `ProcessSessionInformation`, `ProcessPriorityClass`

`ThreadBasicInformation` is intentionally left on the server path. The existing
reply applies server-side transforms that are not mirrored in the published
snapshot, so the public design keeps that one class authoritative instead of
adding a special-case partial mirror.

---

## 3. Architecture

The bypass has two layers:

1. wineserver publishes thread and process snapshots inside the existing shared
   object union, using the normal seqlock write protocol
2. ntdll resolves a handle to its published object once, caches the locator,
   then serves later queries from a single seqlock snapshot read

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .sb-bg { fill: #1a1b26; }
    .sb-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .sb-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .sb-purple { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.7; rx: 8; }
    .sb-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.7; rx: 8; }
    .sb-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .sb-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .sb-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .sb-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .sb-tag-p { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .sb-tag-y { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .sb-line-b { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .sb-line-p { stroke: #bb9af7; stroke-width: 1.2; fill: none; }
    .sb-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="420" class="sb-bg"/>
  <text x="480" y="26" text-anchor="middle" class="sb-title">Shared-state query bypass: one resolve RPC, then local seqlock reads</text>

  <rect x="40" y="70" width="210" height="78" class="sb-box"/>
  <text x="145" y="96" text-anchor="middle" class="sb-label">Win32 query call site</text>
  <text x="145" y="118" text-anchor="middle" class="sb-small">NtQueryInformationThread / Process</text>
  <text x="145" y="134" text-anchor="middle" class="sb-small">same handle may be queried repeatedly</text>

  <rect x="300" y="70" width="220" height="96" class="sb-purple"/>
  <text x="410" y="96" text-anchor="middle" class="sb-tag-p">first use only</text>
  <text x="410" y="118" text-anchor="middle" class="sb-label">resolve shared object</text>
  <text x="410" y="138" text-anchor="middle" class="sb-small">`get_thread_shm` / `get_process_shm` returns locator</text>
  <text x="410" y="154" text-anchor="middle" class="sb-small">locator id cached with object pointer</text>

  <rect x="570" y="70" width="220" height="96" class="sb-green"/>
  <text x="680" y="96" text-anchor="middle" class="sb-tag-g">steady state</text>
  <text x="680" y="118" text-anchor="middle" class="sb-label">single seqlock snapshot read</text>
  <text x="680" y="138" text-anchor="middle" class="sb-small">thread/process fields copied locally</text>
  <text x="680" y="154" text-anchor="middle" class="sb-small">class-specific reply built without wineserver</text>

  <rect x="320" y="236" width="320" height="110" class="sb-box"/>
  <text x="480" y="262" text-anchor="middle" class="sb-label">server-published shared object</text>
  <text x="480" y="284" text-anchor="middle" class="sb-small">wineserver updates fields under `SHARED_WRITE_BEGIN` / `END`</text>
  <text x="480" y="300" text-anchor="middle" class="sb-small">client retries until the seqlock cycle is stable</text>
  <text x="480" y="316" text-anchor="middle" class="sb-small">object id is rechecked after read to catch slot recycling</text>

  <rect x="680" y="236" width="220" height="110" class="sb-yellow"/>
  <text x="790" y="262" text-anchor="middle" class="sb-tag-y">safe miss path</text>
  <text x="790" y="284" text-anchor="middle" class="sb-small">no query access, stale slot, or map failure</text>
  <text x="790" y="300" text-anchor="middle" class="sb-small">negative cache or stale-id eviction</text>
  <text x="790" y="316" text-anchor="middle" class="sb-small">caller falls back to the original RPC</text>

  <line x1="250" y1="110" x2="300" y2="110" class="sb-line-b"/>
  <line x1="520" y1="118" x2="570" y2="118" class="sb-line-p"/>
  <line x1="680" y1="166" x2="680" y2="206" class="sb-line-g"/>
  <line x1="680" y1="206" x2="560" y2="206" class="sb-line-g"/>
  <line x1="560" y1="206" x2="560" y2="236" class="sb-line-g"/>
  <line x1="790" y1="166" x2="790" y2="236" class="sb-line-p"/>
</svg>
</div>

The public point of the design is simple:

- first query on a handle may still pay a small resolve RPC
- later queries on that same handle do not
- any ambiguity falls back to the original authoritative path

That is why this feature can land safely without changing Win32-visible
semantics.

---

## 4. Thread query coverage

The thread snapshot carries the fields needed by the shipped read-mostly thread
classes:

- affinity
- entry point
- suspend count
- priority-boost disable bit
- terminated bit
- debugger-hidden bit
- thread and process ids

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 330" xmlns="http://www.w3.org/2000/svg">
  <style>
    .th-bg { fill: #1a1b26; }
    .th-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .th-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .th-red { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.7; rx: 8; }
    .th-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .th-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .th-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .th-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .th-tag-r { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
  </style>

  <rect x="0" y="0" width="960" height="330" class="th-bg"/>
  <text x="480" y="26" text-anchor="middle" class="th-title">Thread query coverage: shipped snapshot classes vs. retained RPC classes</text>

  <rect x="40" y="70" width="420" height="210" class="th-green"/>
  <text x="250" y="96" text-anchor="middle" class="th-tag-g">served from `thread_shm`</text>
  <text x="250" y="126" text-anchor="middle" class="th-label">`ThreadAffinityMask`</text>
  <text x="250" y="146" text-anchor="middle" class="th-label">`ThreadQuerySetWin32StartAddress`</text>
  <text x="250" y="166" text-anchor="middle" class="th-label">`ThreadGroupInformation`</text>
  <text x="250" y="186" text-anchor="middle" class="th-label">`ThreadIsTerminated`</text>
  <text x="250" y="206" text-anchor="middle" class="th-label">`ThreadSuspendCount`</text>
  <text x="250" y="226" text-anchor="middle" class="th-label">`ThreadHideFromDebugger`</text>
  <text x="250" y="246" text-anchor="middle" class="th-label">`ThreadPriorityBoost`</text>

  <rect x="500" y="70" width="420" height="210" class="th-red"/>
  <text x="710" y="96" text-anchor="middle" class="th-tag-r">retained on RPC</text>
  <text x="710" y="126" text-anchor="middle" class="th-label">`ThreadBasicInformation`</text>
  <text x="710" y="146" text-anchor="middle" class="th-small">server reply still applies effective-priority and exit-status transforms</text>
  <text x="710" y="178" text-anchor="middle" class="th-label">`ThreadAmILastThread`</text>
  <text x="710" y="198" text-anchor="middle" class="th-small">depends on process-scoped last-thread computation</text>
  <text x="710" y="230" text-anchor="middle" class="th-label">`ThreadNameInformation`</text>
  <text x="710" y="250" text-anchor="middle" class="th-small">variable-length payload stays on the original reply path</text>
</svg>
</div>

This boundary is deliberate. The point is not to force every thread query onto
shared memory. The point is to retire the cheap, high-frequency, fixed-shape
queries and leave the odd or transformed replies on the authoritative path.

---

## 5. Process query coverage and zero-time waits

The process snapshot carries enough state to answer the six shipped
`NtQueryInformationProcess()` classes and to answer one additional hot liveness
question: "has this process already exited?"

That second use matters because Wine's in-process sync path already resolves a
process handle to an ntsync-backed wait object. For `WaitForSingleObject(proc,
0)`, ntdll can now short-circuit before the wait ioctl:

- if `process_shm.exit_code` still says the process is alive, return
  `STATUS_TIMEOUT`
- if the exit code has already been published, return `STATUS_WAIT_0`

This is both faster and slightly more correct for Wine's own layering, because
it removes the small gap between the already-shipped process info snapshot and
the separate wait path.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 360" xmlns="http://www.w3.org/2000/svg">
  <style>
    .pw-bg { fill: #1a1b26; }
    .pw-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .pw-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .pw-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.7; rx: 8; }
    .pw-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .pw-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .pw-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .pw-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .pw-tag-y { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .pw-line-b { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .pw-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="360" class="pw-bg"/>
  <text x="480" y="26" text-anchor="middle" class="pw-title">Zero-time process wait: shared-state answer before the wait ioctl</text>

  <rect x="50" y="76" width="240" height="86" class="pw-box"/>
  <text x="170" y="102" text-anchor="middle" class="pw-label">`WaitForSingleObject(process, 0)`</text>
  <text x="170" y="124" text-anchor="middle" class="pw-small">single handle, zero timeout, non-alertable only</text>
  <text x="170" y="140" text-anchor="middle" class="pw-small">ordinary waits still use the normal ntsync path</text>

  <rect x="360" y="76" width="240" height="104" class="pw-green"/>
  <text x="480" y="102" text-anchor="middle" class="pw-tag-g">shmem fast path</text>
  <text x="480" y="124" text-anchor="middle" class="pw-label">read `process_shm.exit_code`</text>
  <text x="480" y="144" text-anchor="middle" class="pw-small">alive -> `STATUS_TIMEOUT`</text>
  <text x="480" y="160" text-anchor="middle" class="pw-small">dead  -> `STATUS_WAIT_0`</text>

  <rect x="670" y="76" width="240" height="104" class="pw-yellow"/>
  <text x="790" y="102" text-anchor="middle" class="pw-tag-y">fallback</text>
  <text x="790" y="124" text-anchor="middle" class="pw-label">resolve fd and issue wait ioctl</text>
  <text x="790" y="144" text-anchor="middle" class="pw-small">used on cache miss, access miss, multi-handle,</text>
  <text x="790" y="160" text-anchor="middle" class="pw-small">alertable wait, or non-zero timeout</text>

  <line x1="290" y1="118" x2="360" y2="118" class="pw-line-b"/>
  <line x1="600" y1="128" x2="670" y2="128" class="pw-line-g"/>

  <rect x="170" y="236" width="620" height="74" class="pw-box"/>
  <text x="480" y="262" text-anchor="middle" class="pw-label">measured synthetic poll cost</text>
  <text x="480" y="284" text-anchor="middle" class="pw-small">ntsync ioctl path: ~10000 ns/poll (`9916`, `10030`, `10141`)</text>
  <text x="480" y="300" text-anchor="middle" class="pw-small">shmem fast path: ~144 ns/poll (`130`, `130`, `171`) — about `70x` faster per poll</text>
</svg>
</div>

The public process-query coverage is:

- `ProcessBasicInformation`
- `ProcessTimes`
- `ProcessPriorityBoost`
- `ProcessAffinityMask`
- `ProcessSessionInformation`
- `ProcessPriorityClass`

The fixed-shape, read-mostly part of that surface is now local. Process image
name queries, debug-object queries, variable-length payloads, and other server
authority cases still use the original RPC path.

### 5.1 Zero-time thread wait

Thread handles now get the same zero-time short-circuit shape, but the
predicate is different. A thread exit code starts life at `0`, which is a
valid user exit code, so the thread fast path cannot use `exit_code != 0` as a
liveness test. It instead reads `THREAD_SHM_FLAG_TERMINATED` from the
published thread snapshot:

- terminated flag clear -> `STATUS_TIMEOUT`
- terminated flag set -> `STATUS_WAIT_0`

That keeps the thread wait path honest while still removing the wait ioctl from
the common zero-time poll case.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 340" xmlns="http://www.w3.org/2000/svg">
  <style>
    .tw-bg { fill: #1a1b26; }
    .tw-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .tw-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .tw-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.7; rx: 8; }
    .tw-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .tw-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .tw-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .tw-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .tw-tag-y { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .tw-line-b { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .tw-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="340" class="tw-bg"/>
  <text x="480" y="26" text-anchor="middle" class="tw-title">Zero-time thread wait: use the published termination flag before the wait ioctl</text>

  <rect x="60" y="76" width="250" height="92" class="tw-box"/>
  <text x="185" y="102" text-anchor="middle" class="tw-label">`WaitForSingleObject(thread, 0)`</text>
  <text x="185" y="124" text-anchor="middle" class="tw-small">single handle, timeout 0, non-alertable only</text>
  <text x="185" y="140" text-anchor="middle" class="tw-small">ordinary waits still use the normal ntsync path</text>

  <rect x="355" y="76" width="250" height="110" class="tw-green"/>
  <text x="480" y="102" text-anchor="middle" class="tw-tag-g">shmem fast path</text>
  <text x="480" y="124" text-anchor="middle" class="tw-label">read `THREAD_SHM_FLAG_TERMINATED`</text>
  <text x="480" y="144" text-anchor="middle" class="tw-small">clear -> `STATUS_TIMEOUT`</text>
  <text x="480" y="160" text-anchor="middle" class="tw-small">set   -> `STATUS_WAIT_0`</text>

  <rect x="650" y="76" width="250" height="110" class="tw-yellow"/>
  <text x="775" y="102" text-anchor="middle" class="tw-tag-y">fallback</text>
  <text x="775" y="124" text-anchor="middle" class="tw-label">resolve fd and issue wait ioctl</text>
  <text x="775" y="144" text-anchor="middle" class="tw-small">used on cache miss, access miss, multi-handle,</text>
  <text x="775" y="160" text-anchor="middle" class="tw-small">alertable wait, or non-zero timeout</text>

  <line x1="310" y1="122" x2="355" y2="122" class="tw-line-b"/>
  <line x1="605" y1="132" x2="650" y2="132" class="tw-line-g"/>

  <rect x="170" y="236" width="620" height="74" class="tw-box"/>
  <text x="480" y="262" text-anchor="middle" class="tw-label">measured synthetic poll cost</text>
  <text x="480" y="284" text-anchor="middle" class="tw-small">ntsync ioctl path: ~11940 ns/poll</text>
  <text x="480" y="300" text-anchor="middle" class="tw-small">shmem fast path: ~164 ns/poll — about `73x` faster per poll</text>
</svg>
</div>

---

## 6. Correctness boundaries

Three parts make this safe enough to ship as the default behavior:

- **slot recycling check**: the cached locator id is rechecked against the
  current shared object id after each read; mismatch evicts the cache entry and
  forces fallback
- **negative cache entries**: handles that cannot resolve to a usable snapshot
  cache that miss explicitly, so repeat polls do not burn a fresh resolve RPC
- **class-by-class fallback**: unsupported or transformed reply shapes stay on
  wineserver instead of being half-mirrored

That is the important discipline for this feature family. It is not trying to
be clever about every thread or process query. It is publishing the read-mostly
state that Wine can mirror honestly, reading it with the existing seqlock
pattern, and refusing the rest.

---

## 7. Related docs

- [Architecture Overview](architecture.gen.html)
- [NTSync Userspace Sync](ntsync-userspace.gen.html)
- [Gamma Channel Dispatcher](gamma-channel-dispatcher.gen.html)
- [Message Ring Architecture](msg-ring-architecture.gen.html)
- [Wineserver Decomposition](wineserver-decomposition.gen.html)
- [State of The Art](current-state.gen.html)
