# Wine-NSPA -- Memory, Sections, Large Pages, and Working-Set Support

This page documents Wine-NSPA's memory surface: local sections, large-page
mappings, RT-keyed page locking and hugetlb, working-set support, and
shared-memory backing choices.

## Table of Contents

1. [Overview](#1-overview)
2. [Coverage](#2-coverage)
3. [Client-side sections](#3-client-side-sections)
4. [Large-page allocation and mapping](#4-large-page-allocation-and-mapping)
5. [Working-set reporting and quota semantics](#5-working-set-reporting-and-quota-semantics)
6. [Shared-memory backing choices](#6-shared-memory-backing-choices)
7. [Validation and observed effect](#7-validation-and-observed-effect)
8. [Implementation map](#8-implementation-map)
9. [Related docs](#9-related-docs)

---

## 1. Overview

Wine-NSPA's memory work is not just large-page syscall support and it is not
just `memfd` everywhere.

Five distinct pieces are active:

- client-side file-backed sections built on top of local-file handles
- large-page support for anonymous and section-backed mappings
- RT-keyed page locking and automatic hugetlb promotion for the hot anonymous-memory path
- hugetlb safety and fallback rules so transparent promotion stays honest under
  pool pressure, partial operations, and JIT RWX allocation
- working-set reporting plus working-set quota bookkeeping
- selective shared-memory backing choices for bypass state

The important design point is that these pieces solve different problems.
Client-side sections reduce mapping RPC traffic on same-process file-backed
mapping workloads. Large pages reduce TLB pressure on hot mappings.
Working-set reporting makes the Windows-visible memory surface honest enough
for tools and tests. Dedicated shared-memory backends keep bypass subsystems
off the wineserver hot path without forcing every shared region through one
mechanism.

---

## 2. Coverage

| Surface | Current behavior |
|---|---|
| `GetLargePageMinimum()` | Returns the real smallest huge-page size published into `KUSER_SHARED_DATA`, or `0` when the host has no usable hugepage pool. |
| `VirtualAlloc(MEM_LARGE_PAGES)` | Accepted and mapped through the unix VM path, with large-page alignment and large-page view tagging preserved for reporting. |
| `NtAllocateVirtualMemoryEx(... MEM_LARGE_PAGES ...)` | Accepted on the same large-page path, including the 1 GiB huge-page request shape when the host supports it. |
| `CreateFileMapping(SEC_LARGE_PAGES)` | Privilege-gated, backed through large-page-capable `memfd_create()` on the wineserver side, and mapped with large-page alignment rules. |
| RT-keyed `mlockall()` | When `NSPA_RT_PRIO` is set, process startup issues `mlockall(MCL_CURRENT | MCL_FUTURE | MCL_ONFAULT)` so touched pages stay locked without pretending Wine has a full working-set manager. |
| RT-keyed automatic hugetlb promotion | When `NSPA_RT_PRIO` is set, eligible anonymous `RESERVE|COMMIT` allocations auto-promote onto the existing large-page mapping path, including `PAGE_EXECUTE_READWRITE` JIT-style arenas. |
| RT-keyed heap arena hugetlb backing | When `NSPA_RT_PRIO` is set, eligible growable heap arenas round up and full-commit onto huge pages, eliminating most heap-driven `mmap` / `mprotect` / page-fault traffic from the hot path. |
| hugetlb pool pressure handling | auto-promotion stops when free hugepages drop below a 10% watermark, and auto-promoted allocations fall back to regular pages instead of failing when the pool is exhausted |
| partial-op demote | sub-hugepage `MEM_DECOMMIT`, partial `MEM_RELEASE`, or partial `VirtualProtect` on an auto-promoted view first demote the view back to regular pages so NT semantics stay correct |
| `MEM_RESET` under `mlockall()` | `MEM_RESET` uses `munlock + MADV_DONTNEED`, so pages can really leave RAM before their next touch |
| local file-backed sections | Eligible unnamed file-backed sections on local-file handles can stay client-side for create / map / unmap / query / close, with same-process duplicate promoted only when the call crosses a real server-handle boundary. |
| `QueryWorkingSetEx()` | Current-process reporting is live, including `LargePage` flag reporting. Preferred path is `PAGEMAP_SCAN`; fallback is `/proc/self/pagemap`. |
| `Get/SetProcessWorkingSetSize(Ex)` | Working-set quota values are accepted, stored, and returned through `ProcessQuotaLimits`. This is bookkeeping, not a working-set trimmer. |
| msg-ring shared state | Per-queue message / redraw / paint-cache regions live in dedicated `memfd` mappings. |
| local-file shared state | Cross-process inode sharing arbitration lives in a dedicated shared `memfd` table, separate from message rings and separate from large-page mappings. |

---

## 3. Client-side sections

The new client-side section path sits between local-file handles and the
traditional wineserver mapping-object path.

Eligible unnamed file-backed sections on local-file handles can:

- allocate a client-private section handle
- duplicate the backing unix fd at section creation time
- map, unmap, query, and close the section locally in the same process
- publish `FILE_MAPPING_*` bits back into the local-file aggregate so later
  share checks and end-of-file changes still see active mappings

This is a memory feature as much as a file feature. It changes how Windows
section objects are represented, how views are installed, and how file-mapping
state is reflected back into the rest of the process.

The main boundary is still the same one the local-file path already uses:
cross-process or namespace-visible semantics remain on the server side.
Same-process mapping is the fast path. Cross-process duplication is not
guessed at.

For the full lifecycle and ownership rules, see
[Local Section Bypass](local-section-architecture.gen.html).

---

## 4. Large-page allocation and mapping

Large-page support has three allocation shapes: explicit Windows
large-page APIs, RT-keyed anonymous-memory promotion, and heap-arena backing
that rides on that same anonymous path. Section-backed mappings remain the one
large-page shape that still crosses wineserver once for backing creation.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ml-bg { fill: #1a1b26; }
    .ml-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.6; rx: 8; }
    .ml-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.6; rx: 8; }
    .ml-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .ml-purple { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.6; rx: 8; }
    .ml-line-blue { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .ml-line-green { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
    .ml-line-yellow { stroke: #e0af68; stroke-width: 1.2; fill: none; }
    .ml-dash { stroke: #6b7398; stroke-width: 0.9; stroke-dasharray: 5,3; fill: none; }
    .ml-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ml-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .ml-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .ml-tag-green { fill: #9ece6a; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ml-tag-yellow { fill: #e0af68; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ml-tag-purple { fill: #bb9af7; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
  </style>

  <rect x="0" y="0" width="960" height="430" class="ml-bg"/>
  <text x="480" y="26" text-anchor="middle" class="ml-title">Large-page allocation and mapping paths</text>

  <rect x="35" y="60" width="250" height="120" class="ml-green"/>
  <text x="60" y="84" class="ml-tag-green">Windows-visible entrypoints</text>
  <text x="60" y="112" class="ml-label">`GetLargePageMinimum()`</text>
  <text x="60" y="132" class="ml-label">`VirtualAlloc(MEM_LARGE_PAGES)`</text>
  <text x="60" y="152" class="ml-label">`NtAllocateVirtualMemoryEx(...)`</text>
  <text x="60" y="172" class="ml-label">`CreateFileMapping(SEC_LARGE_PAGES)`</text>

  <rect x="355" y="60" width="250" height="150" class="ml-box"/>
  <text x="380" y="84" class="ml-title" style="font-size:12px;">Wine userspace</text>
  <text x="380" y="112" class="ml-label">kernelbase reads `KUSER_SHARED_DATA`</text>
  <text x="380" y="132" class="ml-label">`virtual.c` validates size + alignment</text>
  <text x="380" y="152" class="ml-label">large-page views keep `SEC_LARGE_PAGES` tag</text>
  <text x="380" y="172" class="ml-label">working-set reporting can later expose `LargePage`</text>
  <text x="380" y="192" class="ml-small">anonymous path stays in-process; section path crosses wineserver once</text>

  <rect x="675" y="60" width="250" height="150" class="ml-yellow"/>
  <text x="700" y="84" class="ml-tag-yellow">Kernel and wineserver backing</text>
  <text x="700" y="112" class="ml-label">hugepage inventory scanned at startup</text>
  <text x="700" y="132" class="ml-label">`LargePageMinimum` published to shared data</text>
  <text x="700" y="152" class="ml-label">anonymous large pages use hugepage-aware `mmap`</text>
  <text x="700" y="172" class="ml-label">section path uses `memfd_create(... MFD_HUGETLB ...)`</text>
  <text x="700" y="192" class="ml-label">`SEC_LARGE_PAGES` requires `SeLockMemoryPrivilege`</text>

  <line x1="285" y1="120" x2="355" y2="120" class="ml-line-green"/>
  <line x1="605" y1="120" x2="675" y2="120" class="ml-line-blue"/>

  <rect x="70" y="260" width="360" height="110" class="ml-purple"/>
  <text x="95" y="284" class="ml-tag-purple">Anonymous path</text>
  <text x="95" y="312" class="ml-label">`VirtualAlloc(MEM_LARGE_PAGES)`</text>
  <text x="95" y="332" class="ml-label">or `NtAllocateVirtualMemoryEx(... MEM_LARGE_PAGES ...)`</text>
  <text x="95" y="352" class="ml-small">2 MiB large pages today; 1 GiB huge-page request shape also accepted when configured</text>

  <rect x="530" y="260" width="360" height="110" class="ml-yellow"/>
  <text x="555" y="284" class="ml-tag-yellow">Section-backed path</text>
  <text x="555" y="312" class="ml-label">`CreateFileMapping(SEC_LARGE_PAGES)`</text>
  <text x="555" y="332" class="ml-label">wineserver mapping object + hugetlb-capable memfd</text>
  <text x="555" y="352" class="ml-small">map-view path enforces large-page size alignment before the view is installed</text>

  <line x1="480" y1="210" x2="480" y2="235" class="ml-dash"/>
  <line x1="250" y1="235" x2="710" y2="235" class="ml-dash"/>
  <line x1="250" y1="235" x2="250" y2="260" class="ml-line-purple"/>
  <line x1="710" y1="235" x2="710" y2="260" class="ml-line-yellow"/>
</svg>
</div>

The large-page contract is:

- expose the real large-page minimum when the host has one
- reject invalid alignment and privilege shapes instead of silently inventing a fake success path
- preserve enough view metadata that `QueryWorkingSetEx()` can later report `LargePage=1`

That last point matters. The feature is not just about getting `mmap()`
flags accepted. It is about keeping the Windows-visible memory story coherent
from allocation to reporting.

### 4.1 Automatic hugetlb promotion safety rules

Transparent promotion is an optimization, not a new Windows API.
That means the fast path also needs a clear "stay honest" rule set:

- if the free hugetlb pool drops below 10%, stop auto-promoting and leave the
  reserve for explicit large-page callers
- if an auto-promoted allocation hits pool exhaustion anyway, fall back to
  regular pages and succeed instead of failing the ordinary allocation
- if an app later performs a sub-hugepage partial operation on an
  auto-promoted view, demote that view back to regular pages first so
  `MEM_DECOMMIT`, `MEM_RELEASE`, and `VirtualProtect` retain NT semantics
- if `MEM_RESET` runs under `mlockall()`, unlock before `MADV_DONTNEED` so the
  kernel can actually reclaim the pages

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 380" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ha-bg { fill: #1a1b26; }
    .ha-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.7; rx: 8; }
    .ha-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.7; rx: 8; }
    .ha-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.7; rx: 8; }
    .ha-purple { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.7; rx: 8; }
    .ha-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ha-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .ha-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .ha-tag-g { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ha-tag-y { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ha-tag-p { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ha-line-g { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
    .ha-line-b { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .ha-line-y { stroke: #e0af68; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="380" class="ha-bg"/>
  <text x="480" y="26" text-anchor="middle" class="ha-title">Automatic hugetlb promotion: promote when safe, demote or fall back when not</text>

  <rect x="50" y="76" width="220" height="92" class="ha-green"/>
  <text x="160" y="102" text-anchor="middle" class="ha-tag-g">eligible alloc</text>
  <text x="160" y="124" text-anchor="middle" class="ha-label">anonymous `RESERVE|COMMIT`</text>
  <text x="160" y="144" text-anchor="middle" class="ha-small">RW or RWX, RT gate enabled, size and alignment fit</text>

  <rect x="330" y="76" width="280" height="110" class="ha-box"/>
  <text x="470" y="102" text-anchor="middle" class="ha-label">promotion checks</text>
  <text x="470" y="124" text-anchor="middle" class="ha-small">free-pool watermark: refuse below 10%</text>
  <text x="470" y="140" text-anchor="middle" class="ha-small">pool exhaust on auto-promote: retry on regular pages</text>
  <text x="470" y="156" text-anchor="middle" class="ha-small">explicit large-page callers still keep fail-fast semantics</text>

  <rect x="670" y="76" width="240" height="92" class="ha-green"/>
  <text x="790" y="102" text-anchor="middle" class="ha-tag-g">steady state</text>
  <text x="790" y="124" text-anchor="middle" class="ha-label">hugetlb-backed view</text>
  <text x="790" y="144" text-anchor="middle" class="ha-small">or regular-page fallback if transparent promotion was refused</text>

  <line x1="270" y1="122" x2="330" y2="122" class="ha-line-g"/>
  <line x1="610" y1="122" x2="670" y2="122" class="ha-line-b"/>

  <rect x="120" y="236" width="300" height="92" class="ha-purple"/>
  <text x="270" y="262" text-anchor="middle" class="ha-tag-p">partial-op guard</text>
  <text x="270" y="284" text-anchor="middle" class="ha-label">sub-hugepage decommit / release / protect</text>
  <text x="270" y="304" text-anchor="middle" class="ha-small">demote auto-promoted view before the NT operation runs</text>

  <rect x="540" y="236" width="300" height="92" class="ha-yellow"/>
  <text x="690" y="262" text-anchor="middle" class="ha-tag-y">reclaim guard</text>
  <text x="690" y="284" text-anchor="middle" class="ha-label">`MEM_RESET` under `mlockall()`</text>
  <text x="690" y="304" text-anchor="middle" class="ha-small">`munlock + MADV_DONTNEED` so the page can really leave RAM</text>

  <line x1="470" y1="186" x2="270" y2="236" class="ha-line-b"/>
  <line x1="470" y1="186" x2="690" y2="236" class="ha-line-y"/>
</svg>
</div>

---

## 5. Working-set reporting and quota semantics

Working-set support is deliberately split into two levels:

- **reporting**: current-process `QueryWorkingSetEx()` tells tools and tests
  what is resident and whether a page is large-page-backed
- **quota bookkeeping**: `GetProcessWorkingSetSize(Ex)` and
  `SetProcessWorkingSetSize(Ex)` store and return Windows-visible quota values

What is **not** part of this surface is a Linux-side working-set trimmer that enforces those
quota values by reclaiming or emptying the process working set.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 370" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ws-bg { fill: #1a1b26; }
    .ws-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.6; rx: 8; }
    .ws-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.6; rx: 8; }
    .ws-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .ws-line-blue { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .ws-line-green { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
    .ws-line-yellow { stroke: #e0af68; stroke-width: 1.2; fill: none; }
    .ws-dash { stroke: #6b7398; stroke-width: 0.9; stroke-dasharray: 5,3; fill: none; }
    .ws-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ws-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .ws-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .ws-tag-green { fill: #9ece6a; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ws-tag-yellow { fill: #e0af68; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
  </style>

  <rect x="0" y="0" width="960" height="370" class="ws-bg"/>
  <text x="480" y="26" text-anchor="middle" class="ws-title">Working-set reporting vs quota bookkeeping</text>

  <rect x="40" y="70" width="390" height="215" class="ws-green"/>
  <text x="65" y="94" class="ws-tag-green">Reporting path</text>
  <text x="65" y="122" class="ws-label">`QueryWorkingSetEx()`</text>
  <text x="65" y="142" class="ws-label">`NtQueryVirtualMemory(... MemoryWorkingSetExInformation ...)`</text>
  <text x="65" y="162" class="ws-label">current-process pages only</text>
  <text x="65" y="182" class="ws-label">preferred probe: `PAGEMAP_SCAN`</text>
  <text x="65" y="202" class="ws-label">fallback probe: `/proc/self/pagemap`</text>
  <text x="65" y="222" class="ws-label">returns residency bits plus `LargePage`</text>
  <text x="65" y="248" class="ws-small">this is the path the public `large-pages` harness uses to confirm large-page-backed views</text>

  <rect x="530" y="70" width="390" height="215" class="ws-yellow"/>
  <text x="555" y="94" class="ws-tag-yellow">Quota path</text>
  <text x="555" y="122" class="ws-label">`SetProcessWorkingSetSize(Ex)`</text>
  <text x="555" y="142" class="ws-label">`NtSetInformationProcess(ProcessQuotaLimits)`</text>
  <text x="555" y="162" class="ws-label">values stored in process bookkeeping</text>
  <text x="555" y="182" class="ws-label">`GetProcessWorkingSetSize(Ex)` returns the stored values</text>
  <text x="555" y="202" class="ws-label">no kernel-side trimmer, no forced sweep, no fake reclaim story</text>
  <text x="555" y="222" class="ws-label">Windows-visible quota surface is present without fake enforcement</text>
  <text x="555" y="244" class="ws-small">keeps compatibility and diagnostics honest</text>
  <text x="555" y="258" class="ws-small">without claiming a memory manager Wine does not have</text>

  <line x1="430" y1="178" x2="530" y2="178" class="ws-dash"/>
  <text x="480" y="170" text-anchor="middle" class="ws-small">same overall memory surface, different semantics</text>
</svg>
</div>

That division is intentional. Reporting should be correct. Quota APIs should
behave coherently. RT-keyed `mlockall()` improves residency behavior for the
actual process, but the docs should not imply that Wine-NSPA has grown a full
Windows-style working-set manager or a quota-enforcing trimmer. It has not.

---

## 6. Shared-memory backing choices

The tree uses several shared-memory backends, and they are chosen per
subsystem instead of by one global rule.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .bk-bg { fill: #1a1b26; }
    .bk-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.6; rx: 8; }
    .bk-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.6; rx: 8; }
    .bk-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .bk-purple { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.6; rx: 8; }
    .bk-line-blue { stroke: #7aa2f7; stroke-width: 1.2; fill: none; }
    .bk-line-green { stroke: #9ece6a; stroke-width: 1.2; fill: none; }
    .bk-line-yellow { stroke: #e0af68; stroke-width: 1.2; fill: none; }
    .bk-line-purple { stroke: #bb9af7; stroke-width: 1.2; fill: none; }
    .bk-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .bk-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .bk-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .bk-tag-green { fill: #9ece6a; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .bk-tag-yellow { fill: #e0af68; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .bk-tag-purple { fill: #bb9af7; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
  </style>

  <rect x="0" y="0" width="960" height="420" class="bk-bg"/>
  <text x="480" y="26" text-anchor="middle" class="bk-title">Shared-memory backing choices by subsystem</text>

  <rect x="35" y="70" width="205" height="250" class="bk-box"/>
  <text x="60" y="94" class="bk-title" style="font-size:12px;">Request / reply payload</text>
  <text x="60" y="122" class="bk-label">per-thread `request_shm`</text>
  <text x="60" y="142" class="bk-label">server-call payload bytes</text>
  <text x="60" y="162" class="bk-label">reply payload bytes</text>
  <text x="60" y="188" class="bk-small">used by gamma and by the canonical wineserver path</text>

  <rect x="265" y="70" width="205" height="250" class="bk-green"/>
  <text x="290" y="94" class="bk-tag-green">Per-queue `memfd`</text>
  <text x="290" y="122" class="bk-label">msg-ring send / reply slots</text>
  <text x="290" y="142" class="bk-label">redraw push ring</text>
  <text x="290" y="162" class="bk-label">paint-cache metadata</text>
  <text x="290" y="188" class="bk-small">queue-local, fd-passed, mapped by the client peers that need it</text>

  <rect x="495" y="70" width="205" height="250" class="bk-purple"/>
  <text x="520" y="94" class="bk-tag-purple">Shared `memfd` tables</text>
  <text x="520" y="122" class="bk-label">local-file inode arbitration</text>
  <text x="520" y="142" class="bk-label">shared `(dev, inode)` state</text>
  <text x="520" y="162" class="bk-label">bucket PI mutex words</text>
  <text x="520" y="188" class="bk-small">one published region, reused by every process that participates in the local-file path</text>

  <rect x="725" y="70" width="200" height="250" class="bk-yellow"/>
  <text x="750" y="94" class="bk-tag-yellow">Large-page mappings</text>
  <text x="750" y="122" class="bk-label">hugepage-backed anonymous views</text>
  <text x="750" y="142" class="bk-label">or hugetlb-capable section memfd</text>
  <text x="750" y="162" class="bk-label">not part of msg-ring or inode-table plumbing</text>
  <text x="750" y="188" class="bk-small">separate goal: page size and locking semantics, not peer-to-peer bypass state</text>

  <line x1="240" y1="195" x2="265" y2="195" class="bk-line-blue"/>
  <line x1="470" y1="195" x2="495" y2="195" class="bk-line-green"/>
  <line x1="700" y1="195" x2="725" y2="195" class="bk-line-purple"/>
</svg>
</div>

This is why a single "memfd page" would be misleading. `memfd` is important,
but it is not the whole story:

- some NSPA state lives in shared payload windows
- some lives in queue-local `memfd` regions
- some lives in shared `memfd` tables
- large pages are a different memory feature again

The docs should keep those roles separate, because the correctness rules and
performance goals are different.

---

## 7. Validation and observed effect

The public `large-pages` PE harness covers more than one call shape:

- `VirtualAlloc(MEM_LARGE_PAGES)`
- `QueryWorkingSetEx()` `LargePage` reporting on the resulting view
- `CreateFileMapping(SEC_LARGE_PAGES)`
- privilege-negative `SEC_LARGE_PAGES` behavior
- 1 GiB huge-page request shape when the host is configured for it

That means the public test surface validates both the allocation path and
the Windows-visible reporting path. Local sections are currently validated
through the workload path rather than a dedicated PE harness:
`CreateFile -> CreateFileMapping -> CloseHandle(file) -> MapViewOfFile` is
clean on the local path and materially reduces mapping RPC traffic.

The relevant public harness documentation lives on `nspa-rt-test.gen.html`.

The newer RT-keyed memory work was validated separately on real workloads and
targeted shell harnesses:

- `mlockall()` under `NSPA_RT_PRIO` cut perf page faults from `561/s` to
  `451/s`, cut bpf page faults from `869/s` to `629/s`, and tightened max
  futex wait from `94us` to `49us`, with `VmLck` around `300848kB`.
- automatic hugetlb promotion stayed conservative and is keyed only
  off `NSPA_RT_PRIO`; the cleanup pass ended with `test-huge-auto.sh` `3/3 PASS`.
- the demote / fallback / reclaim follow-ons are also on the active path:
  `test-huge-decommit.sh` validates zero-on-recommit after partial decommit,
  `test-huge-rwx.sh` validates RWX JIT-style promotion, and pool-pressure cases
  fall back instead of failing an ordinary allocation
- heap arena hugetlb backing increased hugepage regions from `3` or `6` to
  `104`, reduced dTLB miss / insn to `0.071%`, reduced `mmap` rate from
  `33-61/s` to `0.13/s`, reduced `mprotect` rate from `56-90/s` to `0.03/s`,
  and reduced page-faults from `753-869/s` to `2.8/s`.
- after the gate cleanup, the public shell checks finished at
  `test-mlock-ws.sh 4/4`, `test-huge-auto.sh 3/3`, and
  `test-heap-hugepage.sh 3/3`.

---

## 8. Implementation map

| File | Responsibility |
|---|---|
| `dlls/ntdll/unix/nspa/local_file.c` | local-file table plus local-section table, handle ranges, mapping-bit publication |
| `dlls/ntdll/unix/sync.c` / `dlls/ntdll/unix/virtual.c` | section creation, map / unmap / query hooks, and large-page / view semantics |
| `server/mapping.c` | hugepage inventory scan, `LargePageMinimum` publication, `SEC_LARGE_PAGES` privilege gate, large-page section backing |
| `dlls/kernelbase/memory.c` | `GetLargePageMinimum()` |
| `dlls/ntdll/unix/nspa/huge_auto.c` | automatic hugetlb-promotion eligibility, watermarking, and demote helper for auto-promoted views |
| `dlls/ntdll/unix/virtual.c` | anonymous large-page allocation, automatic hugetlb promotion, fallback and demote call sites, `MEM_RESET`, large-page view tracking, `QueryWorkingSetEx()` reporting |
| `dlls/ntdll/unix/process.c` | `ProcessQuotaLimits` working-set bookkeeping plus RT-keyed `mlockall()` startup |
| `dlls/ntdll/heap.c` | RT-keyed hugepage arena backing for eligible growable heaps |
| `dlls/kernelbase/process.c` | `Get/SetProcessWorkingSetSize(Ex)` user-facing entrypoints |
| `dlls/kernelbase/debug.c` | `QueryWorkingSetEx()` / `K32QueryWorkingSetEx()` front-end |
| `server/queue.c` | per-queue `memfd` regions for msg-ring / redraw / paint-cache |
| `server/nspa/local_file.c` | shared inode arbitration `memfd` table for the local-file path |

---

## 9. Related docs

- [Local Section Bypass](local-section-architecture.gen.html)
- [Architecture Overview](architecture.gen.html)
- [RT Test Harness](nspa-rt-test.gen.html)
- [Message Ring Architecture](msg-ring-architecture.gen.html)
- [NT Local Stubs](nt-local-stubs.gen.html)
- [Local-File Bypass Architecture](nspa-local-file-architecture.gen.html)
