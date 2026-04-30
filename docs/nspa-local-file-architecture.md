# Wine-NSPA -- Local-File Bypass Architecture

Wine 11.6 + NSPA RT patchset | Kernel 6.19.x-rt with NTSync PI | 2026-04-23
Author: Jordan Johnston
Status: design and implementation reference for the shipped read-only regular-file local-open bypass.

This page covers the `NtCreateFile` local-fast-path itself, the local handle table and inode-sharing rules behind it, and the lazy-promotion path back into wineserver when server-owned state becomes necessary.

## Table of Contents

1. [Overview](#1-overview)
2. [Motivation](#2-motivation)
3. [Design Principles](#3-design-principles)
4. [Vanilla Wine vs Wine-NSPA File Open](#4-vanilla-wine-vs-wine-nspa-file-open)
5. [Handle Range & Per-Process Table](#5-handle-range--per-process-table)
6. [Shared Inode Table & Sharing Arbitration](#6-shared-inode-table--sharing-arbitration)
7. [Lazy Server-Handle Promotion](#7-lazy-server-handle-promotion)
8. [Dispatch Flow](#8-dispatch-flow)
9. [Eligibility Criteria](#9-eligibility-criteria)
10. [NT API Coverage Matrix](#10-nt-api-coverage-matrix)
11. [File Manifest (post-reorg)](#11-file-manifest-post-reorg)
12. [Debug Gating](#12-debug-gating)
13. [Results & Profiler Numbers](#13-results--profiler-numbers)
14. [Known Gaps & Roadmap](#14-known-gaps--roadmap)
15. [Phase History](#15-phase-history)

---

## 1. Overview

Wine-NSPA's **local-file bypass** (`NSPA_LOCAL_FILES=1`) services read-only regular-file `NtCreateFile` calls entirely within the client process. Every eligible open would otherwise cost a full wineserver round-trip: the client builds a `create_file` request, the server allocates a `struct file` + inode tracking + handle entry, returns a server-visible handle, then every subsequent `NtReadFile` / `NtQueryInformationFile` / etc fires another round-trip. For an app like Ableton Live 12 Lite that does roughly **28,500 file opens in a single startup session** -- DLL manifests, `.pyc` files, theme resources, Live Library indexes -- those round-trips dominate startup profile and show up as real latency on the main thread.

The bypass routes eligible opens to a client-private handle range, maintains a per-process table that owns the unix fd, and exposes the unix fd to every Wine I/O path via a thin fast-path check inside `server_get_unix_fd`. When an API needs server-side state (section mapping, query-by-handle, inheritance), the bypass *lazily promotes* the local handle to a server-recognised handle on demand.

The feature is invisible to Win32 applications: same `CreateFile` semantics, same sharing arbitration, same `io->Information = FILE_OPENED` return value, same behaviour on every downstream API. Apps see identical functional behaviour whether the bypass is enabled or not -- the difference is measurable only in profiler output and perceived startup latency.

---

## 2. Motivation

Ableton's startup profile exposed a large population of short-lived file opens:

| Pattern | Example |
|---|---|
| DLL manifest lookups | `C:\windows\winsxs\manifests\amd64_microsoft.windows.common-controls_*.manifest` |
| Python bytecode loads | `.../Resources/Python/abl.live/**/*.pyc` |
| Theme resources | `C:\windows\resources\themes\aero\aero.msstyles` |
| Clock source probes | `/sys/bus/clocksource/devices/clocksource0/current_clocksource` |
| Ableton library indexes | `C:\users\ninez\AppData\Local\Ableton\Live Database\Live-files-*.db` |
| Live Packs | `C:\ProgramData\Ableton\Live 12 Lite\Resources\Graphics.alp` |

Each open is cheap on its own (a few µs) but the aggregate is hundreds of millisecond-scale server traffic during startup -- and the startup is happening on the main thread, which is where paint and UI dispatch live. Eliminating the server round-trip on these opens directly reduces time-to-first-paint and reduces steady-state priority-inversion risk on the RT audio path (server's single-threaded main loop services all requests).

Other candidate workloads with similar profiles: plugin scanners (hundreds of VST probe opens), .NET apps (thousands of assembly-manifest reads at JIT time), installers (cache-file probes), and any Windows application using Python or Lua as an embedded runtime.

---

## 3. Design Principles

- **Client-private handle range.** The bypass issues handles from a fixed high range `[0x7FFFC000, 0x80000000)` that is disjoint from the server's normal handle allocation (low-to-mid) and from the NTSync client-handle range. Any caller that does `nspa_local_file_is_local_handle(h)` can cheaply tell whether a handle is ours.
- **Per-process table, not process-shared.** Local handles are invalid in any other process. The table is a plain linked list under a PI mutex -- no shared memory, no cross-process lookups. Cross-process handle duplication falls back to promotion through the server.
- **Shared inode table for sharing arbitration.** The only thing multiple processes need to agree on is *sharing*: if another process opens a file with `FILE_SHARE_NONE` we must honour that. A server-published shmem region carries `(dev, inode) -> (aggregate-access, aggregate-sharing, refcount)` so client-side arbitration matches what server-side `check_sharing` would enforce.
- **Lazy promotion.** On first API that genuinely needs a server-visible handle (`NtQueryInformationFile`, `NtDuplicateObject`, `NtCreateSection`, ...), the bypass does a single `nspa_create_file_from_unix_fd` RPC that hands the unix fd to the server and gets back a real server handle. Subsequent calls on the same local handle reuse the cached promoted handle.
- **RT-safe fast path.** Once the table + inode shmem are warm, the bypass open path is `stat()` + linked-list-walk-under-lock + `open()` + list insert -- no syscall other than the two that are inherent to the work. No lazy-init on the hot path (see Phase 1A.9 init-fix).
- **Transparent fallback.** Every disqualifier returns `STATUS_NOT_SUPPORTED` and the caller falls through to the normal `server_create_file` path. Anything the bypass doesn't handle is handled by vanilla Wine unchanged.
- **Tight correctness envelope.** Only `FILE_OPEN` / `FILE_OPEN_IF`-on-existing-file dispositions, only read-only access masks, only regular files, only synchronous (`FILE_SYNCHRONOUS_IO_*`) opens. Anything outside the envelope goes to the server.

---

## 4. Vanilla Wine vs Wine-NSPA File Open

<div class="diagram-container">
<svg width="920" height="580" viewBox="0 0 920 580" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box-vanilla { fill: #24283b; stroke: #9aa5ce; stroke-width: 1.5; rx: 6; }
    .box-nspa { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 6; }
    .box-new { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 6; }
    .box-server { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.5; rx: 6; }
    .box-kernel { fill: #1a1a2a; stroke: #bb9af7; stroke-width: 1.5; rx: 6; }
    .label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .label-sm { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .label-accent { fill: #7aa2f7; font-size: 13px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-yellow { fill: #e0af68; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .label-muted { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .divider { stroke: #3b4261; stroke-width: 1; stroke-dasharray: 8,4; }
  </style>
  <defs>
    <marker id="lfA" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><path d="M0,0 L8,3 L0,6" fill="#c8d0e8"/></marker>
    <marker id="lfG" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><path d="M0,0 L8,3 L0,6" fill="#9ece6a"/></marker>
    <marker id="lfR" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><path d="M0,0 L8,3 L0,6" fill="#f7768e"/></marker>
  </defs>

  <text x="220" y="24" class="label-accent" text-anchor="middle">Vanilla Wine: every open = server RTT</text>
  <text x="700" y="24" class="label-accent" text-anchor="middle">Wine-NSPA: local bypass for eligible opens</text>
  <line x1="460" y1="8" x2="460" y2="570" class="divider"/>

  <!-- LEFT -->
  <rect x="40" y="45" width="340" height="28" class="box-vanilla"/>
  <text x="210" y="64" text-anchor="middle" class="label">NtCreateFile (ntdll unix)</text>
  <line x1="210" y1="73" x2="210" y2="93" stroke="#f7768e" stroke-width="1.5" marker-end="url(#lfR)"/>

  <rect x="60" y="95" width="300" height="28" class="box-server"/>
  <text x="210" y="114" text-anchor="middle" class="label-red">SERVER: create_file request</text>
  <line x1="210" y1="123" x2="210" y2="143" stroke="#f7768e" stroke-width="1.5" marker-end="url(#lfR)"/>

  <rect x="60" y="145" width="300" height="60" class="box-server"/>
  <text x="210" y="163" text-anchor="middle" class="label-red">open(), stat(), check_sharing</text>
  <text x="210" y="180" text-anchor="middle" class="label-red">alloc struct fd + struct file</text>
  <text x="210" y="197" text-anchor="middle" class="label-muted">global_lock held during sharing arbitration</text>
  <line x1="210" y1="205" x2="210" y2="225" stroke="#f7768e" stroke-width="1.5" marker-end="url(#lfR)"/>

  <rect x="60" y="227" width="300" height="28" class="box-server"/>
  <text x="210" y="246" text-anchor="middle" class="label-red">alloc_handle (server range)</text>
  <line x1="210" y1="255" x2="210" y2="275" stroke="#9aa5ce" stroke-width="1" marker-end="url(#lfA)"/>

  <rect x="40" y="277" width="340" height="28" class="box-vanilla"/>
  <text x="210" y="296" text-anchor="middle" class="label">reply: server handle 0x14</text>
  <line x1="210" y1="305" x2="210" y2="325" stroke="#9aa5ce" stroke-width="1" marker-end="url(#lfA)"/>

  <rect x="40" y="327" width="340" height="28" class="box-vanilla"/>
  <text x="210" y="346" text-anchor="middle" class="label">NtReadFile: another server RTT</text>
  <line x1="210" y1="355" x2="210" y2="375" stroke="#f7768e" stroke-width="1.5" marker-end="url(#lfR)"/>

  <rect x="60" y="377" width="300" height="42" class="box-server"/>
  <text x="210" y="395" text-anchor="middle" class="label-red">get_handle_fd -> SCM_RIGHTS</text>
  <text x="210" y="412" text-anchor="middle" class="label-muted">client mmaps + pread; close on needs_close</text>

  <text x="210" y="465" text-anchor="middle" class="label-yellow">Cost per open-read-close: 3+ server RTTs</text>
  <text x="210" y="483" text-anchor="middle" class="label-muted">~5-10µs each, ~15-30µs wall on an otherwise idle server</text>
  <text x="210" y="501" text-anchor="middle" class="label-muted">under RT contention: unbounded</text>

  <!-- RIGHT -->
  <rect x="520" y="45" width="340" height="28" class="box-nspa"/>
  <text x="690" y="64" text-anchor="middle" class="label">NtCreateFile (ntdll unix)</text>
  <line x1="690" y1="73" x2="690" y2="93" stroke="#9ece6a" stroke-width="1.5" marker-end="url(#lfG)"/>

  <rect x="540" y="95" width="300" height="28" class="box-new"/>
  <text x="690" y="114" text-anchor="middle" class="label-green">nspa_local_file_try_bypass</text>
  <line x1="690" y1="123" x2="690" y2="143" stroke="#9ece6a" stroke-width="1.5" marker-end="url(#lfG)"/>

  <rect x="540" y="145" width="300" height="75" class="box-new"/>
  <text x="690" y="163" text-anchor="middle" class="label-green">stat() -&gt; (dev, inode)</text>
  <text x="690" y="180" text-anchor="middle" class="label-green">check_and_publish via shmem table</text>
  <text x="690" y="197" text-anchor="middle" class="label-green">open() O_RDONLY</text>
  <text x="690" y="214" text-anchor="middle" class="label-muted">per-bucket PI mutex, no server call</text>
  <line x1="690" y1="220" x2="690" y2="240" stroke="#9ece6a" stroke-width="1.5" marker-end="url(#lfG)"/>

  <rect x="540" y="242" width="300" height="28" class="box-new"/>
  <text x="690" y="261" text-anchor="middle" class="label-green">alloc local handle (0x7FFF xxxx)</text>
  <line x1="690" y1="270" x2="690" y2="290" stroke="#9ece6a" stroke-width="1.5" marker-end="url(#lfG)"/>

  <rect x="540" y="292" width="300" height="28" class="box-nspa"/>
  <text x="690" y="311" text-anchor="middle" class="label">return local handle</text>
  <line x1="690" y1="320" x2="690" y2="340" stroke="#9aa5ce" stroke-width="1" marker-end="url(#lfA)"/>

  <rect x="520" y="342" width="340" height="28" class="box-nspa"/>
  <text x="690" y="361" text-anchor="middle" class="label">NtReadFile(local_handle)</text>
  <line x1="690" y1="370" x2="690" y2="390" stroke="#9ece6a" stroke-width="1.5" marker-end="url(#lfG)"/>

  <rect x="540" y="392" width="300" height="42" class="box-new"/>
  <text x="690" y="410" text-anchor="middle" class="label-green">server_get_unix_fd fast path</text>
  <text x="690" y="427" text-anchor="middle" class="label-green">table lookup -&gt; pread(fd)</text>

  <text x="690" y="465" text-anchor="middle" class="label-green">Cost per open-read-close: 0 server RTTs</text>
  <text x="690" y="483" text-anchor="middle" class="label-muted">stat + open + pread; everything local</text>
  <text x="690" y="501" text-anchor="middle" class="label-muted">promotion happens only on API that needs server state</text>
</svg>
</div>

---

## 5. Handle Range & Per-Process Table

### 5.1 Handle range

Local handles are allocated from the fixed range `[NSPA_LF_HANDLE_BASE, 0x80000000)` where `NSPA_LF_HANDLE_BASE = 0x80000000 - NSPA_LF_HANDLE_CAP*4` with `NSPA_LF_HANDLE_CAP = 4096`. That gives an exact 16 KiB handle window disjoint from:

- Server's normal handle allocation (starts at `0x4`, grows up)
- Wine's pseudo-handles (`~0..~5`)
- The NTSync client-handle range (near `INPROC_SYNC_CACHE_TOTAL`)

`nspa_local_file_is_local_handle(h)` is a constant-time range check: `base <= h < 0x80000000 && h != 0x7FFFFFFF` (the last exclusion is for the `CURRENT_PROCESS` pseudo-handle which would otherwise land inside the range). The check is called from every NT-API intercept site to decide whether to take the bypass path or fall through.

### 5.2 Per-process table

```c
struct nspa_local_open {
    struct list       entry;
    HANDLE            handle;         /* local-range handle returned to app */
    HANDLE            server_handle;  /* lazy-promoted; 0 until first promote */
    int               unix_fd;
    unsigned long long device;
    unsigned long long inode;
    unsigned int      access;
    unsigned int      sharing;
    unsigned int      options;        /* FILE_OPEN options: SYNC_IO_NONALERT, etc */
    unsigned int      attributes;     /* OBJ_INHERIT forwarded on promote */
    WCHAR            *nt_name;        /* original NT path for GetFinalPathNameByHandle */
    USHORT            nt_name_len;
};
```

Protected by a single process-wide PI mutex (`nspa_lf_opens_mutex`). Linear list -- walk is O(N) per lookup. For Ableton's typical workload the list reaches a few hundred entries at peak; the walk is in the noise next to a server RTT it avoids.

Table add (on mint) and remove (on close) are the only writers. Every other operation (lookup, promote lookup) is a read under the same lock. The lock is a PI mutex because RT-priority threads occasionally open files at init and we cannot have a low-priority thread holding the lock against the audio callback.

---

## 6. Shared Inode Table & Sharing Arbitration

Windows file sharing (`FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE`) has cross-process semantics: if Process A opens `foo` with `sharing=0`, Process B's open of `foo` must fail with `STATUS_SHARING_VIOLATION`. Any pure-local bypass has to see what other processes have done on the same `(device, inode)`.

### 6.1 Shmem layout

The wineserver publishes a `NSPA_INODE_BUCKETS` = 1024 bucket hash table as a memfd-backed shmem region. Each bucket has 4 slots of `(dev, inode, agg_access, agg_sharing, refcount)` + a per-bucket PI mutex. Clients map the region read-only for arbitration lookups, read-write on the mutex word for publishing their own opens.

```
┌───────────────────────────────────────────────┐
│ nspa_inode_table_shm_t (~160 KB)              │
├───────────────────────────────────────────────┤
│  buckets[0..1023]                             │
│   ├─ lock_storage (pi_mutex_t, 64 B)          │
│   ├─ slot[0] (dev, ino, access, share, ref)   │
│   ├─ slot[1]                                  │
│   ├─ slot[2]                                  │
│   └─ slot[3]                                  │
└───────────────────────────────────────────────┘
```

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .lf-bg { fill: #1a1b26; }
    .lf-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .lf-fast { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .lf-server { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.8; rx: 8; }
    .lf-bucket { fill: #1f2535; stroke: #bb9af7; stroke-width: 1.6; rx: 8; }
    .lf-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .lf-small { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .lf-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .lf-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .lf-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .lf-violet { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .lf-line { stroke: #c0caf5; stroke-width: 1.4; }
  </style>
  <defs>
    <marker id="lfShareArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="940" height="420" class="lf-bg"/>
  <text x="470" y="28" text-anchor="middle" class="lf-title">Shared inode arbitration: bypass clients and wineserver publish into one compatibility table</text>

  <rect x="50" y="88" width="220" height="88" class="lf-fast"/>
  <text x="160" y="114" text-anchor="middle" class="lf-green">Client process A</text>
  <text x="160" y="140" text-anchor="middle" class="lf-label">stat() -> (dev, inode)</text>
  <text x="160" y="158" text-anchor="middle" class="lf-small">check_and_publish_open</text>

  <rect x="50" y="242" width="220" height="88" class="lf-fast"/>
  <text x="160" y="268" text-anchor="middle" class="lf-green">Client process B</text>
  <text x="160" y="294" text-anchor="middle" class="lf-label">same file, different access/share mask</text>
  <text x="160" y="312" text-anchor="middle" class="lf-small">must see A before minting local handle</text>

  <rect x="335" y="66" width="270" height="286" class="lf-bucket"/>
  <text x="470" y="92" text-anchor="middle" class="lf-violet">memfd-backed inode table</text>
  <rect x="365" y="120" width="210" height="62" class="lf-box"/>
  <text x="470" y="144" text-anchor="middle" class="lf-label">bucket = hash(dev, inode) % 1024</text>
  <text x="470" y="162" text-anchor="middle" class="lf-small">per-bucket PI mutex</text>
  <rect x="365" y="206" width="210" height="104" class="lf-box"/>
  <text x="470" y="230" text-anchor="middle" class="lf-label">slot[0..3]</text>
  <text x="470" y="248" text-anchor="middle" class="lf-small">dev, inode</text>
  <text x="470" y="266" text-anchor="middle" class="lf-small">agg_access, agg_sharing</text>
  <text x="470" y="284" text-anchor="middle" class="lf-small">refcount</text>
  <text x="470" y="302" text-anchor="middle" class="lf-small">overflow -> STATUS_NOT_SUPPORTED fallback</text>

  <rect x="670" y="88" width="220" height="88" class="lf-server"/>
  <text x="780" y="114" text-anchor="middle" class="lf-red">wineserver non-bypass open</text>
  <text x="780" y="140" text-anchor="middle" class="lf-label">server-side publish hook</text>
  <text x="780" y="158" text-anchor="middle" class="lf-small">same compatibility rule, same bucket</text>

  <rect x="670" y="242" width="220" height="88" class="lf-server"/>
  <text x="780" y="268" text-anchor="middle" class="lf-red">authoritative fallback</text>
  <text x="780" y="294" text-anchor="middle" class="lf-label">overflow or unsupported case</text>
  <text x="780" y="312" text-anchor="middle" class="lf-small">server create_file path remains exact</text>

  <line x1="270" y1="132" x2="335" y2="132" class="lf-line" marker-end="url(#lfShareArrow)"/>
  <line x1="270" y1="286" x2="335" y2="286" class="lf-line" marker-end="url(#lfShareArrow)"/>
  <line x1="670" y1="132" x2="605" y2="132" class="lf-line" marker-end="url(#lfShareArrow)"/>
  <line x1="605" y1="286" x2="670" y2="286" class="lf-line" marker-end="url(#lfShareArrow)"/>
  <text x="470" y="380" text-anchor="middle" class="lf-small">the table is not a data path cache; it is a compatibility contract</text>
  <text x="470" y="396" text-anchor="middle" class="lf-small">so local opens and server opens enforce one sharing model</text>
</svg>
</div>

Bucket index = hash(dev, inode) mod 1024. Slot selection is linear within the bucket (first free or matching). If all 4 slots are full and none match, the bypass returns `STATUS_NOT_SUPPORTED` and the open falls back to the server -- this is an overflow-safety valve, not a correctness path.

### 6.2 Arbitration logic

`nspa_local_file_check_and_publish_open` atomically checks the existing aggregate against the new open's access/sharing mask, returning `STATUS_SHARING_VIOLATION` if they conflict. Matching the server's algorithm exactly:

- Pending opens add `access` to `agg_access` and intersect `sharing` with `agg_sharing`.
- A new open must satisfy: `(agg_access & ~my_sharing) == 0` AND `(my_access & ~agg_sharing) == 0`.

This lives in `nspa_local_file_check_sharing_algorithm()`. The server-side publish hooks (`nspa_inode_publish_slot`) mirror the same rule from the server side whenever a non-bypass open creates or clears an inode entry. Arbitration therefore sees the *union* of bypass and non-bypass opens.

---

## 7. Lazy Server-Handle Promotion

The LF table returns a local-range handle to the application. Most Nt-API intercepts can service the call from the local unix fd directly (`NtReadFile`, `NtWriteFile`, `NtQueryInformationFile` for `FileBasicInformation` / `FilePositionInformation` / etc). But some APIs *require* a server-visible handle:

- `NtCreateSection` -- section object lives on the server
- `NtDuplicateObject` -- dup goes through `SERVER_START_REQ(dup_handle)`
- `NtQueryInformationFile` for classes the server handles (e.g. `FileNameInformation`)
- `NtQueryObject` -- `ObjectName` / `ObjectBasic` / `ObjectType` all server-side
- `NtQuerySecurityObject`, `NtSetSecurityObject`
- `NtMakePermanentObject`, `NtMakeTemporaryObject`
- `NtCompareObjects`

For these, the bypass lazily promotes the local handle: on first call needing server state, it issues a single `nspa_create_file_from_unix_fd` RPC:

1. `wine_server_send_fd(unix_fd)` -- SCM_RIGHTS transfers a dup of the fd to the server
2. Server's handler wraps the fd in a `struct fd` + `struct file_obj` + stores the NT path
3. Server calls `alloc_handle` and returns a normal server-range handle
4. Client stores the server handle in the LF entry's `server_handle` field

Subsequent calls on the same local handle reuse the cached server handle -- no second RPC. `nspa_promote_if_local(h)` is the one-line helper that every intercept site calls:

```c
HANDLE nspa_promote_if_local( HANDLE h );

// Returns `h` unchanged if not local-range.
// Returns the promoted server handle (cached if already promoted) if local-range.
// Returns `h` unchanged if promotion failed (caller falls back to server path).
```

This is Phase 1A.4.a lazy-promotion. The alternative -- eagerly promoting at mint time -- was rejected because most file opens in Ableton's workload never touch a server-requiring API; they read, maybe query a position, and close. Eager promotion would cost an RPC per open; lazy promotion costs an RPC per *distinct file that escapes the read-only happy path*.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .lp-bg { fill: #1a1b26; }
    .lp-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .lp-fast { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .lp-slow { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.8; rx: 8; }
    .lp-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .lp-small { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .lp-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .lp-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .lp-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .lp-line { stroke: #c0caf5; stroke-width: 1.4; }
  </style>
  <defs>
    <marker id="lpArrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="#c0caf5"/>
    </marker>
  </defs>

  <rect x="0" y="0" width="940" height="430" class="lp-bg"/>
  <text x="470" y="28" text-anchor="middle" class="lp-title">Lazy promotion: keep the read-only happy path local until an API actually needs server state</text>

  <rect x="80" y="78" width="220" height="64" class="lp-fast"/>
  <text x="190" y="104" text-anchor="middle" class="lp-green">local handle minted</text>
  <text x="190" y="124" text-anchor="middle" class="lp-small">`server_handle = 0`, unix fd already valid</text>

  <rect x="360" y="78" width="220" height="64" class="lp-box"/>
  <text x="470" y="104" text-anchor="middle" class="lp-label">intercept site checks handle range</text>
  <text x="470" y="124" text-anchor="middle" class="lp-small">`nspa_local_file_is_local_handle()`</text>

  <rect x="640" y="78" width="220" height="64" class="lp-fast"/>
  <text x="750" y="104" text-anchor="middle" class="lp-green">already promoted?</text>
  <text x="750" y="124" text-anchor="middle" class="lp-small">reuse cached server handle if yes</text>

  <line x1="300" y1="110" x2="360" y2="110" class="lp-line" marker-end="url(#lpArrow)"/>
  <line x1="580" y1="110" x2="640" y2="110" class="lp-line" marker-end="url(#lpArrow)"/>

  <rect x="70" y="208" width="250" height="140" class="lp-fast"/>
  <text x="195" y="234" text-anchor="middle" class="lp-green">stays local</text>
  <text x="195" y="260" text-anchor="middle" class="lp-label">NtReadFile / NtWriteFile</text>
  <text x="195" y="278" text-anchor="middle" class="lp-small">server_get_unix_fd fast path</text>
  <text x="195" y="302" text-anchor="middle" class="lp-label">basic query classes</text>
  <text x="195" y="320" text-anchor="middle" class="lp-small">no server-visible object required</text>

  <rect x="345" y="208" width="250" height="140" class="lp-slow"/>
  <text x="470" y="234" text-anchor="middle" class="lp-red">promote now</text>
  <text x="470" y="260" text-anchor="middle" class="lp-label">NtCreateSection / NtDuplicateObject</text>
  <text x="470" y="278" text-anchor="middle" class="lp-small">NtQueryObject / server-side info classes</text>
  <text x="470" y="302" text-anchor="middle" class="lp-label">CreateProcess inheritance</text>
  <text x="470" y="320" text-anchor="middle" class="lp-small">crosses into server object model</text>

  <rect x="620" y="208" width="250" height="140" class="lp-box"/>
  <text x="745" y="234" text-anchor="middle" class="lp-label">one RPC only</text>
  <text x="745" y="260" text-anchor="middle" class="lp-small">send fd via SCM_RIGHTS</text>
  <text x="745" y="278" text-anchor="middle" class="lp-small">server allocates real handle</text>
  <text x="745" y="296" text-anchor="middle" class="lp-small">cache `server_handle` in LF entry</text>
  <text x="745" y="320" text-anchor="middle" class="lp-small">all later calls reuse it</text>

  <line x1="470" y1="142" x2="195" y2="208" class="lp-line" marker-end="url(#lpArrow)"/>
  <line x1="470" y1="142" x2="470" y2="208" class="lp-line" marker-end="url(#lpArrow)"/>
  <line x1="750" y1="142" x2="745" y2="208" class="lp-line" marker-end="url(#lpArrow)"/>
  <line x1="595" y1="278" x2="620" y2="278" class="lp-line" marker-end="url(#lpArrow)"/>

  <text x="470" y="384" text-anchor="middle" class="lp-small">this is why lazy promotion wins on workloads like Ableton:</text>
  <text x="470" y="400" text-anchor="middle" class="lp-small">most opens die on the left-hand path and never pay the server transition</text>
</svg>
</div>

### 7.1 `attributes` plumbing

The promote RPC forwards `ObjectAttributes->Attributes` (typically `OBJ_CASE_INSENSITIVE`, plus `OBJ_INHERIT` when `bInheritHandles=TRUE` is set on `CreateProcess`). The server's `alloc_handle_entry` translates `OBJ_INHERIT` to `RESERVED_INHERIT` on the handle's access mask, which is how Wine tracks inheritable handles for `copy_handle_table` during `CreateProcess`. Without the forwarding, inheritable local-range handles would be silently dropped by the inheritance walk.

---

## 8. Dispatch Flow

<div class="diagram-container">
<svg width="920" height="640" viewBox="0 0 920 640" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box-gate { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 6; }
    .box-fast { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 6; }
    .box-slow { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.5; rx: 6; }
    .box-api { fill: #24283b; stroke: #e0af68; stroke-width: 1.5; rx: 6; }
    .label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .label-sm { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .label-accent { fill: #7aa2f7; font-size: 13px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-yellow { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .label-muted { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
  </style>
  <defs>
    <marker id="df1" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><path d="M0,0 L8,3 L0,6" fill="#c8d0e8"/></marker>
    <marker id="df2" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><path d="M0,0 L8,3 L0,6" fill="#9ece6a"/></marker>
    <marker id="df3" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><path d="M0,0 L8,3 L0,6" fill="#f7768e"/></marker>
  </defs>

  <text x="460" y="24" class="label-accent" text-anchor="middle">NtCreateFile bypass dispatch + downstream intercepts</text>

  <rect x="340" y="50" width="240" height="32" class="box-api"/>
  <text x="460" y="70" text-anchor="middle" class="label">app: CreateFileA(...)</text>

  <line x1="460" y1="82" x2="460" y2="102" stroke="#c8d0e8" stroke-width="1.5" marker-end="url(#df1)"/>

  <rect x="320" y="104" width="280" height="52" class="box-gate"/>
  <text x="460" y="124" text-anchor="middle" class="label-yellow">eligibility gate (file.c:4706)</text>
  <text x="460" y="142" text-anchor="middle" class="label-muted">disposition FILE_OPEN|FILE_OPEN_IF, sync, read-only</text>

  <line x1="320" y1="130" x2="140" y2="200" stroke="#f7768e" stroke-width="1.5" marker-end="url(#df3)"/>
  <text x="180" y="170" class="label-red" text-anchor="start">fail gate</text>
  <rect x="40" y="200" width="200" height="32" class="box-slow"/>
  <text x="140" y="220" text-anchor="middle" class="label-red">server create_file RTT</text>

  <line x1="460" y1="156" x2="460" y2="180" stroke="#9ece6a" stroke-width="1.5" marker-end="url(#df2)"/>

  <rect x="320" y="182" width="280" height="76" class="box-fast"/>
  <text x="460" y="202" text-anchor="middle" class="label-green">nspa_local_file_try_bypass</text>
  <text x="460" y="220" text-anchor="middle" class="label-sm">stat() + S_ISREG check</text>
  <text x="460" y="236" text-anchor="middle" class="label-sm">check_and_publish via inode shmem</text>
  <text x="460" y="252" text-anchor="middle" class="label-sm">open() + table_add</text>

  <line x1="320" y1="240" x2="160" y2="290" stroke="#f7768e" stroke-width="1.5" marker-end="url(#df3)"/>
  <text x="200" y="270" class="label-red" text-anchor="start">SHARING_VIOLATION or NOT_SUPPORTED</text>

  <line x1="460" y1="258" x2="460" y2="282" stroke="#9ece6a" stroke-width="1.5" marker-end="url(#df2)"/>

  <rect x="340" y="284" width="240" height="32" class="box-api"/>
  <text x="460" y="304" text-anchor="middle" class="label">local handle 0x7FFFC4xx</text>

  <line x1="460" y1="316" x2="460" y2="340" stroke="#c8d0e8" stroke-width="1.5" marker-end="url(#df1)"/>

  <rect x="100" y="342" width="720" height="42" class="box-api"/>
  <text x="460" y="360" text-anchor="middle" class="label">app uses the handle: NtReadFile / NtQuery* / NtSet* / NtFsCtl / NtDeviceIoCtl / ...</text>
  <text x="460" y="376" text-anchor="middle" class="label-muted">every NT-API entry point checks nspa_local_file_is_local_handle</text>

  <line x1="300" y1="384" x2="200" y2="410" stroke="#9ece6a" stroke-width="1.5" marker-end="url(#df2)"/>
  <line x1="620" y1="384" x2="720" y2="410" stroke="#9ece6a" stroke-width="1.5" marker-end="url(#df2)"/>

  <rect x="60" y="412" width="280" height="52" class="box-fast"/>
  <text x="200" y="432" text-anchor="middle" class="label-green">NtReadFile / NtWriteFile</text>
  <text x="200" y="450" text-anchor="middle" class="label-sm">server_get_unix_fd fast path -&gt; pread(fd)</text>

  <rect x="580" y="412" width="280" height="52" class="box-fast"/>
  <text x="720" y="432" text-anchor="middle" class="label-green">NtQuery*InformationFile etc</text>
  <text x="720" y="450" text-anchor="middle" class="label-sm">nspa_promote_if_local -&gt; server RPC</text>

  <line x1="720" y1="464" x2="720" y2="486" stroke="#f7768e" stroke-width="1" marker-end="url(#df3)"/>
  <rect x="580" y="488" width="280" height="42" class="box-slow"/>
  <text x="720" y="506" text-anchor="middle" class="label-red">nspa_create_file_from_unix_fd</text>
  <text x="720" y="520" text-anchor="middle" class="label-muted">one-time per local handle; cached</text>

  <line x1="460" y1="556" x2="460" y2="580" stroke="#c8d0e8" stroke-width="1" marker-end="url(#df1)"/>
  <rect x="340" y="582" width="240" height="42" class="box-fast"/>
  <text x="460" y="600" text-anchor="middle" class="label-green">NtClose (local path)</text>
  <text x="460" y="616" text-anchor="middle" class="label-muted">close(fd) + remove entry + server close if promoted</text>
</svg>
</div>

---

## 9. Eligibility Criteria

The bypass accepts only a tightly-scoped subset. The eligibility gate in `file.c`'s `NtCreateFile`:

```c
if (!loader_open &&
    !attr->RootDirectory && !attr->SecurityDescriptor &&
    (disposition == FILE_OPEN || disposition == FILE_OPEN_IF) &&
    !(options & (FILE_OPEN_BY_FILE_ID | FILE_DIRECTORY_FILE | FILE_DELETE_ON_CLOSE)) &&
    (options & (FILE_SYNCHRONOUS_IO_ALERT | FILE_SYNCHRONOUS_IO_NONALERT)) &&
    !(access & ~(FILE_READ_DATA | FILE_READ_ATTRIBUTES | FILE_READ_EA |
                 READ_CONTROL | SYNCHRONIZE | GENERIC_READ)))
{
    NTSTATUS bypass = nspa_local_file_try_bypass( ... );
    if (bypass == STATUS_SUCCESS) return STATUS_SUCCESS;
    if (bypass == STATUS_SHARING_VIOLATION) { status = bypass; goto done; }
    /* STATUS_NOT_SUPPORTED -> fall through */
}
```

Disqualifiers and their reasons:

| Condition | Why rejected |
|---|---|
| `loader_open` (`.dll` / `.drv` / `.sys` / `.exe`) | Wine's loader owns its own open path for these; we don't want to race with it. |
| `attr->RootDirectory != 0` | Relative opens would need `openat()` against a server-handle root -- not worth the complexity. |
| `attr->SecurityDescriptor != 0` | Custom SD means the caller wants server-enforced access control. |
| `disposition != FILE_OPEN` && `!= FILE_OPEN_IF` | Create / overwrite / supersede need server-side atomicity on existence checks. |
| `options & FILE_OPEN_BY_FILE_ID` | Open-by-ID walks the server's inode -> name mapping. |
| `options & FILE_DIRECTORY_FILE` | Directories use `NtQueryDirectoryFile` streaming -- different bypass target, not in scope. |
| `options & FILE_DELETE_ON_CLOSE` | Atomic-delete semantics need server ordering. |
| `options` lacks any `FILE_SYNCHRONOUS_IO_*` flag | OVERLAPPED opens route through `register_async_file_read` which takes the handle to the server -- local handle would fail STATUS_INVALID_HANDLE. |
| Any access bit outside the read-only mask | Write access has sharing-arbitration corners we don't cover in MVP. |

`FILE_OPEN_FOR_BACKUP_INTENT`, `FILE_NO_INTERMEDIATE_BUFFERING`, `FILE_WRITE_THROUGH`, `FILE_OPEN_REPARSE_POINT`, `FILE_RANDOM_ACCESS`, `FILE_SEQUENTIAL_ONLY` are all *accepted* -- they either have no semantic we need to enforce client-side or map cleanly to `open()` flags.

---

## 10. NT API Coverage Matrix

Every handle-consuming NT API in ntdll/unix and server/ either:

- **(intercept)** has a local-handle intercept at its top that promotes on demand
- **(fast path)** services the call from the local unix fd without server contact
- **(pass-through)** doesn't care about local handles (e.g. works on SID not handle)

| NT API | Strategy | File / Line |
|---|---|---|
| `NtCreateFile` | bypass dispatch | `dlls/ntdll/unix/file.c` |
| `NtReadFile`, `NtWriteFile` | fast path via `server_get_unix_fd` | `dlls/ntdll/unix/file.c` |
| `NtQueryInformationFile` | intercept + promote | `dlls/ntdll/unix/file.c` |
| `NtSetInformationFile` | intercept + promote | `dlls/ntdll/unix/file.c` |
| `NtFsControlFile` | intercept + promote | `dlls/ntdll/unix/file.c` |
| `NtDeviceIoControlFile` | intercept + promote | `dlls/ntdll/unix/file.c` |
| `NtFlushBuffersFileEx` | intercept + promote | `dlls/ntdll/unix/file.c` |
| `NtCancelIoFile`, `NtCancelSynchronousIoFile` | intercept + promote | `dlls/ntdll/unix/file.c` |
| `NtLockFile` | intercept + promote | `dlls/ntdll/unix/file.c` |
| `NtQueryVolumeInformationFile` | intercept + promote | `dlls/ntdll/unix/file.c` |
| `NtQueryObject` | intercept + traced promote | `dlls/ntdll/unix/file.c` |
| `NtSetInformationObject` | intercept + promote | `dlls/ntdll/unix/file.c` |
| `NtCreateSection` | dedicated `nspa_create_mapping_from_unix_fd` RPC | `dlls/ntdll/unix/sync.c` |
| `NtDuplicateObject` (same-process) | intercept + promote + DUPLICATE_CLOSE_SOURCE LF cleanup | `dlls/ntdll/unix/server.c` |
| `NtCompareObjects` | intercept + promote (both args) | `dlls/ntdll/unix/server.c` |
| `NtQuerySecurityObject` | intercept + promote | `dlls/ntdll/unix/security.c` |
| `NtSetSecurityObject` | intercept + promote | `dlls/ntdll/unix/security.c` |
| `NtMakePermanentObject` | intercept + promote | `dlls/ntdll/unix/sync.c` |
| `NtMakeTemporaryObject` | intercept + promote | `dlls/ntdll/unix/sync.c` |
| `NtClose` | LF close path (close fd + remove entry + server-close promoted) | `dlls/ntdll/unix/server.c` |
| `CreateProcess` inheritance (legacy `bInheritHandles=TRUE`) | `nspa_local_file_promote_inheritable` before `new_process` RPC | `dlls/ntdll/unix/process.c` |
| `CreateProcess` inheritance (STARTUPINFOEX `PS_ATTRIBUTE_HANDLE_LIST`) | **deferred** -- synchronous promote-per-handle introduced a one-frame menu-paint delay; proper fix is batched promote RPC | `dlls/ntdll/unix/process.c` |

---

## 11. File Manifest (post-reorg)

All NSPA-specific source lives under a `nspa/` subdirectory in each module. Upstream Wine files carry only single-line intercept hook calls, keeping rebase-against-upstream conflicts minimal.

```
dlls/ntdll/unix/nspa/
├── local_file.c         -- LF table, bypass dispatch, promote helpers
├── local_timer.c        -- NT timer local dispatcher
└── debug.h              -- NSPA_TRACE macro, compile + runtime gated

dlls/win32u/nspa/
├── msg_ring.c           -- Message bypass (POST/SEND rings)
└── local_wm_timer.c     -- WM_TIMER local dispatcher

server/nspa/
├── local_file.c         -- inode-aggregation shmem + promote handler
├── local_file.h         -- server-side declarations
├── profile.c            -- wineserver per-request-type profiler
└── debug.h              -- server-side NSPA_TRACE macro
```

Upstream diffs against vanilla Wine are narrow:

- `dlls/ntdll/unix/file.c`: eligibility gate (8 lines) + 10 one-line intercept calls
- `dlls/ntdll/unix/server.c`: one call to `nspa_local_file_try_get_unix_fd()`, one promote in `NtDuplicateObject`, one LF-close entry in `NtClose`
- `dlls/ntdll/unix/sync.c`: LF-handle branch in `NtCreateSection`, two promote lines in `NtMake{Permanent,Temporary}Object`
- `dlls/ntdll/unix/security.c`: two promote lines
- `dlls/ntdll/unix/process.c`: `alloc_handle_list` was extended (prong A, currently deferred -- see §14) + `nspa_local_file_promote_inheritable()` call before `new_process` RPC
- `server/file.c`: one call to `nspa_lf_trace_promote()` inside the existing `nspa_create_file_from_unix_fd` handler

---

## 12. Debug Gating

Trace emission is both compile-time gated (`NSPA_DEBUG`, default on; pass `-DNSPA_DEBUG=0` for a release build) and runtime gated via cached env checks.

```c
#if NSPA_DEBUG

#define NSPA_TRACE_ENABLED_FN(name) \
    static inline int nspa_trace_##name##_enabled(void) { \
        static int cache = -1; \
        int v = __atomic_load_n( &cache, __ATOMIC_RELAXED ); \
        if (v < 0) { \
            v = getenv( "NSPA_" #name ) ? 1 : 0; \
            __atomic_store_n( &cache, v, __ATOMIC_RELAXED ); \
        } \
        return v; \
    }

NSPA_TRACE_ENABLED_FN(LF_TRACE)
NSPA_TRACE_ENABLED_FN(LF_TRACE_SRV)
/* ... */

#define NSPA_TRACE(name, ...) \
    do { if (nspa_trace_##name##_enabled()) fprintf( stderr, __VA_ARGS__ ); } while (0)

#else
#define NSPA_TRACE(name, ...) ((void)0)
#endif
```

- First call per TU does a single `getenv()`; subsequent calls are a relaxed atomic load + not-taken branch when the env is unset (production default).
- Trace *emission* lives inside `nspa/*.c` -- upstream Wine files have zero `NSPA_TRACE` calls. Trace-worthy hooks in upstream code (e.g. the LF fast path in `server_get_unix_fd`) have been extracted into helpers (`nspa_local_file_try_get_unix_fd`, `nspa_promote_if_local_traced`) that the upstream file calls, and all trace logic lives inside those helpers.

---

## 13. Results & Profiler Numbers

Ableton Live 12 Lite, 95-second playback window, `NSPA_PROFILE=1` with all prod gates. Baseline is the pre-LF fullprod run (2026-04-21); "post-LF" is the 2026-04-23 run after the complete stack landed.

| Request | Pre-LF (baseline) | Post-LF | Delta |
|---|---:|---:|---:|
| `send_message` | 32,342 | 325 | **-99%** |
| `get_message_reply` | 7,557 | 0 | -100% |
| `send_hardware_message` | 1,249 | 0 | -100% |
| `accept_hardware_message` | 1,205 | 0 | -100% |
| `set_cursor` | 1,766 | 0 | -100% |
| `get_key_state` | 1,166 | 0 | -100% |
| `get_window_children_from_point` | 1,705 | 0 | -100% |
| `create_file` | 60 | 0 | -100% |
| `close_handle` | 62 | 0 | -100% |
| AudioCalc thread server requests | 27 mentions | **0** | complete audio-path offload |
| Server handler total CPU | 686.8 ms | 571.6 ms | **-16.8%** |

The 99% drop on `send_message` is msg-ring (documented separately) rather than LF -- they compose, and the full NSPA bypass stack is what produces the aggregate numbers. LF's direct contribution shows as the zero rows on `create_file` / `close_handle` / `get_handle_fd`: those are steady-state during playback, but during startup the LF bypass eats roughly **28,500 file opens** that would otherwise each cost a server RTT plus a `get_handle_fd` return-trip.

The bottom-line metric is server handler CPU: 16.8% less server work across the board despite a 10x higher raw request count. The replacement traffic (ring wakeups, hook chain) is ~0.05 µs per request where the replaced traffic was 8+ µs per request.

---

## 14. Known Gaps & Roadmap

### 14.1 Cross-process `DuplicateHandle` of a local-range source

The same-process path is covered. Cross-process dup where the source lives in *another* Wine-NSPA process's local-range is not -- the server has no access to the remote's LF table. Fix would require a cross-process LF promotion RPC. Rare in DAW workloads; parked.

### 14.2 `STARTUPINFOEX PROC_THREAD_ATTRIBUTE_HANDLE_LIST` local-range inheritance

Phase 1A.9 prong A (synchronous `get_or_promote` per handle in the explicit inheritance list) was deferred because the per-handle promote RPC on the CreateProcess-calling thread surfaced as a visible menu-content-paint delay ("black menu flash"). Legacy `bInheritHandles=TRUE` via prong B (`nspa_local_file_promote_inheritable`) is unaffected and covers the common case.

Proper fix options (ranked):

1. **Batched promote RPC** -- single server round-trip that promotes an array of local handles. Caps the CreateProcess cost at one RTT regardless of list length.
2. **Async pre-promotion at mint time** -- if the open carried `OBJ_INHERIT`, fire the promote RPC off the critical path so the server handle is already cached when `alloc_handle_list` runs. Lower CreateProcess latency but higher complexity.

#### Relationship to 14.1

14.1 and 14.2 share the same underlying shape -- "an LF handle must become a real server handle before it crosses a process boundary" -- but the fix surfaces differ:

- **14.2 is in-process.** The CreateProcess caller owns both the LF table and the calling thread, so the unix fds are locally accessible. Option 1 is a pure "batch the existing promote RPC" change.
- **14.1 is cross-process.** Process B holds a handle that refers to process A's LF table. Neither B nor the server has the unix fd. Servicing it requires the server to wake **process A** and have A run the promote on its own entry before the dup can proceed. That needs new server-to-peer-client signaling, which is not LF infrastructure -- it is closer to how the msg-ring wakes peer threads.

The two fixes compose: **14.2's batched RPC is a prerequisite of 14.1.** Once `nspa_promote_local_handles` exists as a handler, 14.1 can reuse it on process A, driven by a new "remote promote" request where process B asks the server to wake A and invoke it. 14.1's complexity is then the wake mechanism, not the promote itself. Ship 14.2 first; 14.1 composes on top.

### 14.3 Eligibility widening

The current envelope captures the hot path. Anything outside it falls back cleanly. Worth widening only when a real workload demands:

- `FILE_OVERWRITE_IF` / `FILE_SUPERSEDE` (cache writes, plugin DB updates)
- Any write access (file saves, recorded audio, log append)
- `FILE_DIRECTORY_FILE` (directory handles -- different primitive, `NtQueryDirectoryFile` streaming)
- `FILE_DELETE_ON_CLOSE` (temp-file semantics)

None of these has a profile-visible cost today; keep them on the server path.

---

## 15. Phase History

| Phase | Commit | Scope |
|---|---|---|
| 1A.0 | `bbea50591a4` | Diagnostic scaffolding |
| 1A.1.a-c | `5fe0bff087c` .. `fc79ed3` | Shared inode-table shmem + publish hooks + client reader |
| 1A.2.a-e | `8c43fcbfb1f` .. `99254f1` | Per-bucket PI lock + slot subentries + client publish API + `NtCreateFile` bypass dispatch + read/write routing |
| 1A.3 | `836cfa2` .. `c71e8fc` | Section-handle promotion infrastructure + audit conclusions |
| 1A.4.a | `35f8897` | Lazy server-handle promotion + PI mutex on table |
| 1A.4 partial | `eb9c6d8454d` | `Nt*File` hooks (b-e) |
| 1A.5 | `43f68f1` | Final ship-stable + audit findings |
| 1A.5+ | `7a03f51` | Wider `Nt*File` coverage (audit-driven) |
| 1A.6 | `73426aa72c4` | Promoted-fd correctness (`nt_name` plumb, `GENERIC_*` access map) |
| 1A.6 follow-up | `69bde5a825e` | `NtQueryObject` + `NtSetInformationObject` promote |
| 1A.7 | `2b193aa0590` | `NtDuplicateObject` same-process promote (fixes Ableton .als load) |
| 1A.8 | `86e17b75986` | Object-generic API audit sweep (`NtCompareObjects`, security, permanence) |
| 1A.9 | `18c209da804` | `OVERLAPPED` reject + `FILE_OPEN_IF` widen + CreateProcess inheritance (prong B) + `attributes` plumbing |
| Menu-flash fix | `641dd63a313` + `72c59b04337` + `6edea95126f` | Init `nspa_lf_handle_base` at declaration + defer prong A + gate QS_TIMER synth on caller's filter |
| Reorg A-D | `e81f4a3817f` .. `cc491efe052` | File moves into `nspa/` subdirs + intercept-site collapse + debug gating |

---
