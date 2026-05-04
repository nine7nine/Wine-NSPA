# Wine-NSPA -- Memory, Large Pages, and Working-Set Support

This page covers the shipped Wine-NSPA memory surface: large-page allocation,
large-page file mappings, current-process working-set reporting, working-set
quota bookkeeping, and the shared-memory backing choices used by the major
bypass subsystems.

## Table of Contents

1. [Overview](#1-overview)
2. [What is shipped](#2-what-is-shipped)
3. [Large-page allocation and mapping](#3-large-page-allocation-and-mapping)
4. [Working-set reporting and quota semantics](#4-working-set-reporting-and-quota-semantics)
5. [Shared-memory backing choices](#5-shared-memory-backing-choices)
6. [Validation surface](#6-validation-surface)
7. [Implementation map](#7-implementation-map)
8. [Related docs](#8-related-docs)

---

## 1. Overview

Wine-NSPA has a real memory subsystem story now. It is not just "some
hugepage patches" and it is not just "memfd everywhere."

Three distinct pieces are shipped:

- large-page support for anonymous and section-backed mappings
- working-set reporting plus working-set quota bookkeeping
- selective shared-memory backing choices for bypass state

The important design point is that these pieces solve different problems.
Large pages reduce TLB pressure on hot mappings. Working-set reporting makes
the Windows-visible memory surface honest enough for tools and tests.
Dedicated shared-memory backends keep bypass subsystems off the wineserver hot
path without forcing every shared region through one mechanism.

---

## 2. What is shipped

| Surface | Shipped behavior |
|---|---|
| `GetLargePageMinimum()` | Returns the real smallest huge-page size published into `KUSER_SHARED_DATA`, or `0` when the host has no usable hugepage pool. |
| `VirtualAlloc(MEM_LARGE_PAGES)` | Accepted and mapped through the unix VM path, with large-page alignment and large-page view tagging preserved for reporting. |
| `NtAllocateVirtualMemoryEx(... MEM_LARGE_PAGES ...)` | Accepted on the same large-page path, including the 1 GiB huge-page request shape when the host supports it. |
| `CreateFileMapping(SEC_LARGE_PAGES)` | Privilege-gated, backed through large-page-capable `memfd_create()` on the wineserver side, and mapped with large-page alignment rules. |
| `QueryWorkingSetEx()` | Current-process reporting is live, including `LargePage` flag reporting. Preferred path is `PAGEMAP_SCAN`; fallback is `/proc/self/pagemap`. |
| `Get/SetProcessWorkingSetSize(Ex)` | Working-set quota values are accepted, stored, and returned through `ProcessQuotaLimits`. This is bookkeeping, not a working-set trimmer. |
| msg-ring shared state | Per-queue message / redraw / paint-cache regions live in dedicated `memfd` mappings. |
| local-file shared state | Cross-process inode sharing arbitration lives in a dedicated shared `memfd` table, separate from message rings and separate from large-page mappings. |

---

## 3. Large-page allocation and mapping

Large-page support has two entry paths: anonymous allocation and section-backed
mapping. Both start from Windows-visible APIs, but the backing shape differs.

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

---

## 4. Working-set reporting and quota semantics

Working-set support is deliberately split into two levels:

- **reporting**: current-process `QueryWorkingSetEx()` tells tools and tests
  what is resident and whether a page is large-page-backed
- **quota bookkeeping**: `GetProcessWorkingSetSize(Ex)` and
  `SetProcessWorkingSetSize(Ex)` store and return Windows-visible quota values

What is **not** shipped is a Linux-side working-set trimmer that enforces those
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
  <text x="555" y="202" class="ws-label">no `mlockall`, no kernel-side trimmer, no forced sweep</text>
  <text x="555" y="222" class="ws-label">Windows-visible quota surface is present without fake enforcement</text>
  <text x="555" y="244" class="ws-small">keeps compatibility and diagnostics honest</text>
  <text x="555" y="258" class="ws-small">without claiming a memory manager Wine does not have</text>

  <line x1="430" y1="178" x2="530" y2="178" class="ws-dash"/>
  <text x="480" y="170" text-anchor="middle" class="ws-small">same overall memory surface, different semantics</text>
</svg>
</div>

That division is intentional. Reporting should be correct. Quota APIs should
behave coherently. But the docs should not imply that Wine-NSPA has grown a
full Windows-style working-set manager. It has not.

---

## 5. Shared-memory backing choices

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

## 6. Validation surface

The public `large-pages` PE harness now covers more than one call shape:

- `VirtualAlloc(MEM_LARGE_PAGES)`
- `QueryWorkingSetEx()` `LargePage` reporting on the resulting view
- `CreateFileMapping(SEC_LARGE_PAGES)`
- privilege-negative `SEC_LARGE_PAGES` behavior
- 1 GiB huge-page request shape when the host is configured for it

That means the public test surface now validates both the allocation path and
the Windows-visible reporting path. The relevant public harness documentation
lives on `nspa-rt-test.gen.html`.

---

## 7. Implementation map

| File | Responsibility |
|---|---|
| `server/mapping.c` | hugepage inventory scan, `LargePageMinimum` publication, `SEC_LARGE_PAGES` privilege gate, large-page section backing |
| `dlls/kernelbase/memory.c` | `GetLargePageMinimum()` |
| `dlls/ntdll/unix/virtual.c` | anonymous large-page allocation, large-page view tracking, `QueryWorkingSetEx()` reporting |
| `dlls/ntdll/unix/process.c` | `ProcessQuotaLimits` working-set bookkeeping |
| `dlls/kernelbase/process.c` | `Get/SetProcessWorkingSetSize(Ex)` user-facing entrypoints |
| `dlls/kernelbase/debug.c` | `QueryWorkingSetEx()` / `K32QueryWorkingSetEx()` front-end |
| `server/queue.c` | per-queue `memfd` regions for msg-ring / redraw / paint-cache |
| `server/nspa/local_file.c` | shared inode arbitration `memfd` table for the local-file path |

---

## 8. Related docs

- [Architecture Overview](architecture.gen.html)
- [RT Test Harness](nspa-rt-test.gen.html)
- [Message Ring Architecture](msg-ring-architecture.gen.html)
- [NT Local Stubs](nt-local-stubs.gen.html)
- [Local-File Bypass Architecture](nspa-local-file-architecture.gen.html)
