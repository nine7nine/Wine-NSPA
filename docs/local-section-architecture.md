# Wine-NSPA -- Local Section Bypass

This page covers the shipped client-side section path built on top of the
local-file bypass: eligible file-backed sections are created, mapped, queried,
unmapped, and closed inside the client process, with honest fallback when the
call crosses into server-owned or cross-process semantics.

## Table of Contents

1. [Overview](#1-overview)
2. [What is shipped](#2-what-is-shipped)
3. [Eligibility and fallback](#3-eligibility-and-fallback)
4. [Handle range and section table](#4-handle-range-and-section-table)
5. [Section lifecycle](#5-section-lifecycle)
6. [DuplicateHandle and ownership boundaries](#6-duplicatehandle-and-ownership-boundaries)
7. [Sharing arbitration and mapping bits](#7-sharing-arbitration-and-mapping-bits)
8. [Validation and observed effect](#8-validation-and-observed-effect)
9. [Implementation map](#9-implementation-map)
10. [Related docs](#10-related-docs)

---

## 1. Overview

Wine-NSPA no longer has to mint a wineserver section object for every eligible
`CreateFileMapping` on a local-file handle. The client process can now keep a
bounded section table of its own, duplicate the unix fd at section-creation
time, and service the common same-process view lifecycle without a server
round-trip.

The feature sits on top of the local-file bypass rather than replacing it. A
local file handle still owns pathname resolution, open semantics, and the
cross-process sharing aggregate. The local section path reuses that file handle
state to build an unnamed file-backed section, then publishes mapping bits back
into the same aggregate so later file operations still see correct
`STATUS_USER_MAPPED_FILE` and sharing behavior.

The current boundary is intentionally narrow:

- file-backed sections only
- unnamed sections only
- same-process mapping / query / close lifecycle only
- same-process `DuplicateHandle` is supported by promoting to a server section
- cross-process duplication still falls back cleanly instead of guessing

That is enough to retire a large volume of mapping RPC traffic from the common
case while leaving the hard cross-process edge cases on the authoritative
server path.

---

## 2. What is shipped

| Surface | Shipped behavior |
|---|---|
| `NtCreateSection` | Eligible file-backed mappings on local-file handles can mint a client-side section handle instead of calling wineserver. |
| `NtMapViewOfSection` / `NtMapViewOfSectionEx` | Same-process maps on local section handles install the view directly in the client process. |
| `NtUnmapViewOfSectionEx` | Local section views unmap without a server hop. |
| `NtQuerySection` | `SectionBasicInformation` is answered locally; image-only queries still fall back or return the honest non-image status where appropriate. |
| `NtClose` | Local section close tears down local views and releases the duplicated unix fd; if a same-process duplicate already promoted the section, the cached server handle is also released. |
| `NtDuplicateObject` | Same-process duplicate of a local section promotes once to a server section, caches that server handle, and then lets the duplicate proceed. |
| File/section coherence | Mapping bits are published into the local-file aggregate so later share checks and `FileEndOfFileInformation` handling still see active mappings. |

This path is now the shipped default for eligible unnamed file-backed sections.

---

## 3. Eligibility and fallback

The local section path is deliberately smaller than the full NT section
surface. A section stays local only when all of the following are true:

- the backing handle is a local-file handle
- the section is file-backed
- the section is unnamed
- the section is not `SEC_IMAGE`
- the section is not `SEC_LARGE_PAGES`
- the later map/query/close operations stay in the same process

Anything outside that envelope falls back to the normal server path. That keeps
the feature easy to reason about and avoids pretending that cross-process
namespace or image-loader semantics can be reconstructed client-side.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 360" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ls-bg { fill: #1a1b26; }
    .ls-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.6; rx: 8; }
    .ls-good { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .ls-warn { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .ls-stop { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.8; rx: 8; }
    .ls-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
    .ls-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .ls-line-y { stroke: #e0af68; stroke-width: 1.3; fill: none; }
    .ls-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ls-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .ls-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .ls-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ls-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ls-yellow { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
  </style>

  <rect x="0" y="0" width="960" height="360" class="ls-bg"/>
  <text x="480" y="28" text-anchor="middle" class="ls-title">Local section eligibility and fallback</text>

  <rect x="360" y="56" width="240" height="48" class="ls-box"/>
  <text x="480" y="76" text-anchor="middle" class="ls-label">`NtCreateSection(file_handle, ...)`</text>
  <text x="480" y="92" text-anchor="middle" class="ls-small">section request reaches ntdll unix layer</text>

  <line x1="480" y1="104" x2="480" y2="128" class="ls-line-b"/>

  <rect x="290" y="130" width="380" height="86" class="ls-good"/>
  <text x="480" y="152" text-anchor="middle" class="ls-green">local-section gate</text>
  <text x="480" y="172" text-anchor="middle" class="ls-label">local-file handle + file-backed + unnamed</text>
  <text x="480" y="190" text-anchor="middle" class="ls-label">not `SEC_IMAGE`, not `SEC_LARGE_PAGES`</text>
  <text x="480" y="206" text-anchor="middle" class="ls-small">otherwise fall through to the normal server section path</text>

  <line x1="290" y1="176" x2="118" y2="176" class="ls-line-y"/>
  <text x="128" y="166" class="ls-yellow">ineligible</text>
  <rect x="40" y="150" width="220" height="54" class="ls-stop"/>
  <text x="150" y="172" text-anchor="middle" class="ls-red">wineserver section path</text>
  <text x="150" y="188" text-anchor="middle" class="ls-small">keeps image, named, and large-page cases honest</text>

  <line x1="480" y1="216" x2="480" y2="238" class="ls-line-g"/>

  <rect x="315" y="240" width="330" height="56" class="ls-good"/>
  <text x="480" y="262" text-anchor="middle" class="ls-green">mint local section handle</text>
  <text x="480" y="278" text-anchor="middle" class="ls-label">duplicate unix fd, publish mapping bits, return client-range handle</text>

  <line x1="480" y1="296" x2="480" y2="320" class="ls-line-g"/>

  <rect x="280" y="322" width="400" height="28" class="ls-box"/>
  <text x="480" y="341" text-anchor="middle" class="ls-label">same-process map / query / unmap / close stay local until a server boundary is crossed</text>
</svg>
</div>

---

## 4. Handle range and section table

Local section handles live in their own client-private range:

- local sections: `[0x7FFF8000, 0x7FFFC000)`
- local files: `[0x7FFFC000, 0x80000000)`

That split matters because later APIs can distinguish a local section from a
local file with a cheap range check before they decide which local table to
consult.

Each local section entry keeps:

- the local section handle returned to the app
- the duplicated unix fd that outlives the original file handle
- the original local-file handle and backing `(dev, inode)` identity
- current mapping bits published into the local-file aggregate
- the cached promoted server handle, if same-process duplication already
  crossed the server boundary
- the list of active local views so `NtUnmapViewOfSectionEx` and `NtClose` can
  tear them down coherently

The table is process-local and protected by its own PI mutex. Cross-process
coordination is not done through the section table itself; only the mapping
effects are published into the shared local-file aggregate.

---

## 5. Section lifecycle

The local section lifecycle is a same-process fast path from creation to final
close. The main change versus the older path is that the unix fd is duplicated
at section creation time, so the mapping can survive a later `CloseHandle()` on
the original file handle.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .life-bg { fill: #1a1b26; }
    .life-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.6; rx: 8; }
    .life-good { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .life-warn { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .life-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .life-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
    .life-line-y { stroke: #e0af68; stroke-width: 1.3; fill: none; }
    .life-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .life-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .life-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .life-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .life-yellow { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
  </style>

  <rect x="0" y="0" width="960" height="430" class="life-bg"/>
  <text x="480" y="26" text-anchor="middle" class="life-title">Local section lifecycle</text>

  <rect x="50" y="90" width="180" height="70" class="life-box"/>
  <text x="140" y="116" text-anchor="middle" class="life-label">local-file handle</text>
  <text x="140" y="134" text-anchor="middle" class="life-small">pathname + sharing state already owned locally</text>

  <rect x="280" y="90" width="190" height="92" class="life-good"/>
  <text x="375" y="114" text-anchor="middle" class="life-green">create local section</text>
  <text x="375" y="134" text-anchor="middle" class="life-label">duplicate unix fd</text>
  <text x="375" y="152" text-anchor="middle" class="life-label">allocate section handle</text>
  <text x="375" y="168" text-anchor="middle" class="life-small">publish `FILE_MAPPING_*` bits</text>

  <rect x="520" y="90" width="190" height="92" class="life-good"/>
  <text x="615" y="114" text-anchor="middle" class="life-green">map and use view</text>
  <text x="615" y="134" text-anchor="middle" class="life-label">`NtMapViewOfSection`</text>
  <text x="615" y="152" text-anchor="middle" class="life-label">tracks local view metadata</text>
  <text x="615" y="168" text-anchor="middle" class="life-small">no server section object involved</text>

  <rect x="760" y="90" width="150" height="92" class="life-box"/>
  <text x="835" y="118" text-anchor="middle" class="life-label">local queries</text>
  <text x="835" y="136" text-anchor="middle" class="life-small">`NtQuerySection` basic info</text>
  <text x="835" y="152" text-anchor="middle" class="life-small">`NtUnmapViewOfSectionEx`</text>
  <text x="835" y="168" text-anchor="middle" class="life-small">local close bookkeeping</text>

  <line x1="230" y1="125" x2="280" y2="125" class="life-line-b"/>
  <line x1="470" y1="136" x2="520" y2="136" class="life-line-g"/>
  <line x1="710" y1="136" x2="760" y2="136" class="life-line-b"/>

  <rect x="160" y="260" width="300" height="96" class="life-warn"/>
  <text x="310" y="286" text-anchor="middle" class="life-yellow">file handle can close earlier</text>
  <text x="310" y="308" text-anchor="middle" class="life-label">`CreateFile -> CreateFileMapping -> CloseHandle(file)`</text>
  <text x="310" y="326" text-anchor="middle" class="life-small">section keeps its own duplicated unix fd</text>
  <text x="310" y="342" text-anchor="middle" class="life-small">later map still succeeds</text>

  <rect x="500" y="260" width="300" height="96" class="life-good"/>
  <text x="650" y="286" text-anchor="middle" class="life-green">final section close</text>
  <text x="650" y="308" text-anchor="middle" class="life-label">unmap remaining local views</text>
  <text x="650" y="326" text-anchor="middle" class="life-label">clear mapping bits and release fd</text>
  <text x="650" y="342" text-anchor="middle" class="life-small">also closes cached server handle if same-process DUP promoted earlier</text>

  <line x1="375" y1="182" x2="375" y2="232" class="life-line-y"/>
  <line x1="615" y1="182" x2="615" y2="232" class="life-line-g"/>
  <line x1="375" y1="232" x2="310" y2="260" class="life-line-y"/>
  <line x1="615" y1="232" x2="650" y2="260" class="life-line-g"/>
</svg>
</div>

Two points are worth calling out:

- `CloseHandle(file)` no longer invalidates the later map path for an eligible
  local section, because the section owns its own duplicated unix fd.
- mapping and unmapping stay client-side, but they still update shared mapping
  state so later file operations do not silently violate Windows semantics.

---

## 6. DuplicateHandle and ownership boundaries

The local section path is same-process first. That is deliberate.

When `NtDuplicateObject()` sees a local section handle and both the source and
destination process are the current process, it promotes the section once to a
server section, caches that promoted handle on the local entry, and then lets
the duplicate proceed through the normal server machinery.

When the duplicate crosses a process boundary, the client-side section handle
stops being a valid abstraction. The server does not have access to the remote
process's private section table, so the current shipped behavior is to fall
through cleanly rather than invent cross-process state. That produces the right
failure instead of a confusing partially-working handle.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 350" xmlns="http://www.w3.org/2000/svg">
  <style>
    .dup-bg { fill: #1a1b26; }
    .dup-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.6; rx: 8; }
    .dup-good { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .dup-warn { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .dup-stop { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.8; rx: 8; }
    .dup-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .dup-line-y { stroke: #e0af68; stroke-width: 1.3; fill: none; }
    .dup-line-r { stroke: #f7768e; stroke-width: 1.3; fill: none; }
    .dup-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .dup-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .dup-small { fill: #a9b1d6; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .dup-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .dup-yellow { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .dup-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
  </style>

  <rect x="0" y="0" width="960" height="350" class="dup-bg"/>
  <text x="480" y="26" text-anchor="middle" class="dup-title">DuplicateHandle boundary</text>

  <rect x="375" y="56" width="210" height="48" class="dup-box"/>
  <text x="480" y="76" text-anchor="middle" class="dup-label">local section handle</text>
  <text x="480" y="92" text-anchor="middle" class="dup-small">client-private source handle</text>

  <line x1="480" y1="104" x2="480" y2="132" class="dup-line-y"/>

  <rect x="310" y="134" width="340" height="60" class="dup-warn"/>
  <text x="480" y="156" text-anchor="middle" class="dup-yellow">`NtDuplicateObject(source, dest, ...)`</text>
  <text x="480" y="174" text-anchor="middle" class="dup-small">decision point depends on whether the destination is the current process</text>

  <line x1="310" y1="164" x2="150" y2="164" class="dup-line-g"/>
  <text x="160" y="154" class="dup-green">same process</text>
  <rect x="40" y="136" width="220" height="86" class="dup-good"/>
  <text x="150" y="160" text-anchor="middle" class="dup-green">promote once, then duplicate</text>
  <text x="150" y="178" text-anchor="middle" class="dup-label">server section handle cached locally</text>
  <text x="150" y="194" text-anchor="middle" class="dup-small">later local close releases both local and promoted state</text>

  <line x1="650" y1="164" x2="810" y2="164" class="dup-line-r"/>
  <text x="820" y="154" class="dup-red">other process</text>
  <rect x="700" y="136" width="220" height="86" class="dup-stop"/>
  <text x="810" y="160" text-anchor="middle" class="dup-red">fall back cleanly</text>
  <text x="810" y="178" text-anchor="middle" class="dup-label">remote process cannot see the private section table</text>
  <text x="810" y="194" text-anchor="middle" class="dup-small">current shipped boundary is honest failure, not partial emulation</text>
</svg>
</div>

This is one of the key differences between a local optimization and a fake
object namespace. The local section handle is a process-local implementation
detail until the call explicitly crosses into server-owned handle semantics.

---

## 7. Sharing arbitration and mapping bits

The local section path stays correct by feeding its mapping state back into the
same shared aggregate that local-file already uses for open and sharing
arbitration.

When a local section is created:

- the client identifies the backing `(dev, inode)` from the local-file entry
- the section publishes `FILE_MAPPING_WRITE`, `FILE_MAPPING_IMAGE`, or
  `FILE_MAPPING_ACCESS` bits into the shared aggregate, matching the mapping
  shape
- the section keeps those bits live until the last local view and the section
  itself are gone

That shared publication matters for two reasons:

- later opens and share checks still see mapping state even though the section
  never became a wineserver object in the common case
- `FileEndOfFileInformation` can still reject a shrink with
  `STATUS_USER_MAPPED_FILE` when a mapped section is active

This is the architectural seam between the file path and the section path: the
file table owns the cross-process aggregate, and the section table reuses it
instead of inventing a second source of truth.

---

## 8. Validation and observed effect

The shipped local section path was validated on the real workload that exposed
the old cost: repeated file mapping and view traffic during app startup and UI
initialization.

Key observed results from the landed implementation:

- DirectWrite-style shape is clean:
  `CreateFile -> CreateFileMapping -> CloseHandle(file) -> MapViewOfFile`
- `nspa_create_mapping_from_unix_fd` count dropped from `2,664` to `~800`
  (`-70%`)
- `get_mapping_info` and `unmap_view` dropped out of the top sampled symbols
- total wineserver handler time moved from `1,991 ms` to `1,077 ms` on the
  cleanest run of that comparison
- same-process duplicate is handled correctly
- cross-process duplicate returns a clean `STATUS_INVALID_HANDLE` instead of an
  inconsistent handle state

The companion local-file follow-ons matter here too. Because mapping bits are
published into the shared aggregate, later file-side changes like local
`FileEndOfFileInformation` handling can preserve the same mapped-file boundary
without reintroducing a mandatory section RPC.

---

## 9. Implementation map

| Path | Role |
|---|---|
| `dlls/ntdll/unix/nspa/local_file.c` | local section table, handle range, create path, mapping-bit publication, same-process duplicate support |
| `dlls/ntdll/unix/sync.c` | `NtCreateSection` / `NtCreateSectionEx` entrypoint hooks |
| `dlls/ntdll/unix/virtual.c` | `NtMapViewOfSection`, `NtMapViewOfSectionEx`, local unmap, view tagging, and `NtQuerySection` support |
| `dlls/ntdll/unix/server.c` | `NtDuplicateObject` promotion boundary and `NtClose` teardown |
| `dlls/ntdll/unix/unix_private.h` | shared declarations for local-file and local-section helpers |

The design intentionally stays inside existing Wine layers:

- `sync.c` decides whether section creation can stay local
- `virtual.c` owns view installation and teardown
- `server.c` remains the place where an explicit server-handle boundary is
  crossed

That keeps the patch understandable and reduces the number of call sites that
need to know about the feature.

---

## 10. Related docs

- [Local-File Bypass Architecture](nspa-local-file-architecture.gen.html)
- [Memory, Sections, Large Pages, and Working-Set Support](memory-and-large-pages.gen.html)
- [NT Local Stubs](nt-local-stubs.gen.html)
- [Architecture Overview](architecture.gen.html)
- [State of The Art](current-state.gen.html)
