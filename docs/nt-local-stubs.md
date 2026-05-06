# Wine-NSPA -- NT-local stubs

This page documents the NT-local stub pattern and the shipped stub
surfaces built on it.

## Table of Contents

1. [Overview](#1-overview)
2. [The shape of an NT-local stub](#2-the-shape-of-an-nt-local-stub)
3. [Why progressive stubs beat monolithic decomposition](#3-why-progressive-stubs-beat-monolithic-decomposition)
4. [Cross-process state arbitration](#4-cross-process-state-arbitration)
5. [Lazy server-handle promotion](#5-lazy-server-handle-promotion)
6. [Lock discipline shared by every stub](#6-lock-discipline-shared-by-every-stub)
7. [Currently shipped stubs](#7-currently-shipped-stubs)
    1. [`nspa_local_file` + local sections](#71-nspa_local_file--local-file-handles-and-local-sections)
    2. [anonymous local events -- `NtCreateEvent` fast path](#72-anonymous-local-events--ntcreateevent-fast-path)
    3. [`nspa_local_timer` -- `NtSetTimer` fast path](#73-nspa_local_timer--ntsettimer-fast-path)
    4. [`nspa_local_wm_timer` -- `WM_TIMER` dispatcher](#74-nspa_local_wm_timer--wm_timer-dispatcher)
8. [Future stubs (roadmap)](#8-future-stubs-roadmap)
9. [Connection to wineserver decomposition](#9-connection-to-wineserver-decomposition)
10. [References](#10-references)

---

## 1. Overview

Wineserver is the historical bottleneck of Wine on PREEMPT_RT. Every NT-API
call that touches kernel-mediated state -- a file handle, a synchronization
object, a timer, a message queue, a window -- traditionally crosses a
request-shmem RPC into wineserver, where one global `pi_mutex_t global_lock`
is held while a handler runs the request. Throughput is fine on idle systems;
*latency* is not. Under contention the global lock serialises every handler,
priority-inverts low-priority handlers against the RT audio thread, and
turns every NT-API call into a queue-depth-bounded wait. This is the lock
that perf 2026-04-26 keeps showing in every wineserver capture: `channel_dispatcher`
6-11%, `get_ptid_entry` 1-10%, `main_loop_epoll` 2-7%, all under one lock.

NSPA's response is not "rewrite wineserver from scratch". It is an
architectural pattern we call **NT-local stubs**: client-process-resident
handlers that satisfy a class of NT-API calls *without* crossing into
wineserver, and fall back to the server only when an honest cross-process
arbitration is required. Each stub picks an NT surface, owns its own
data structures (a private handle range, a per-process table, a shmem
region, a dispatcher thread), and short-circuits the server when it can.

The pattern is already shipping. As of 2026-05-05 there are four live
NT-local stub surfaces in tree:

| Stub | NT surface | Lives in |
|---|---|---|
| `nspa_local_file` | bounded `NtCreateFile` for regular files and explicit directories, plus downstream file ops and local file-backed sections | `dlls/ntdll/unix/nspa/local_file.c` |
| local event fast path | anonymous `NtCreateEvent` with server-aware async-completion signaling | `dlls/ntdll/unix/sync.c` + `server/nspa/inproc_event_table.c` |
| `nspa_local_timer` | `NtCreateTimer` / `NtSetTimer` / `NtCancelTimer` / `NtQueryTimer` (anonymous) | `dlls/ntdll/unix/nspa/local_timer.c` |
| `nspa_local_wm_timer` | `NtUserSetTimer` / `NtUserSetSystemTimer` / `NtUserKillTimer` / `WM_TIMER` posting | `dlls/win32u/nspa/local_wm_timer.c` |

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 380" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ns-bg { fill: #1a1b26; }
    .ns-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.4; rx: 8; }
    .ns-fast { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .ns-shared { fill: #2a1f35; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .ns-server { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .ns-promo { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .ns-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .ns-sm { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .ns-head { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ns-blue { fill: #7aa2f7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ns-pur { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ns-grn { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ns-yel { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .ns-arrow { stroke: #7aa2f7; stroke-width: 1.7; fill: none; }
    .ns-arrow-b { stroke: #7aa2f7; stroke-width: 1.8; fill: none; }
    .ns-arrow-p { stroke: #bb9af7; stroke-width: 1.8; fill: none; }
    .ns-arrow-g { stroke: #9ece6a; stroke-width: 1.8; fill: none; }
    .ns-arrow-y { stroke: #e0af68; stroke-width: 1.8; fill: none; stroke-dasharray: 5,4; }
  </style>

  <rect x="0" y="0" width="940" height="380" class="ns-bg"/>
  <text x="470" y="26" text-anchor="middle" class="ns-head">NT-local stub pattern</text>

  <rect x="40" y="66" width="180" height="66" class="ns-box"/>
  <text x="130" y="92" text-anchor="middle" class="ns-label">NT API entry point</text>
  <text x="130" y="109" text-anchor="middle" class="ns-sm">NtCreateFile / NtCreateEvent / NtSetTimer / NtUserSetTimer</text>

  <rect x="280" y="66" width="170" height="66" class="ns-fast"/>
  <text x="365" y="92" text-anchor="middle" class="ns-blue">eligibility predicate</text>
  <text x="365" y="109" text-anchor="middle" class="ns-sm">take fast path or return STATUS_NOT_SUPPORTED</text>

  <rect x="510" y="48" width="190" height="84" class="ns-fast"/>
  <text x="605" y="74" text-anchor="middle" class="ns-label">client-local state</text>
  <text x="605" y="91" text-anchor="middle" class="ns-sm">private handle range</text>
  <text x="605" y="105" text-anchor="middle" class="ns-sm">per-process tables, pi_mutex locks</text>
  <text x="605" y="119" text-anchor="middle" class="ns-sm">fast-path success returns directly</text>

  <rect x="510" y="168" width="190" height="84" class="ns-shared"/>
  <text x="605" y="194" text-anchor="middle" class="ns-label">shared arbitration state</text>
  <text x="605" y="211" text-anchor="middle" class="ns-sm">optional memfd / shmem publication</text>
  <text x="605" y="225" text-anchor="middle" class="ns-sm">PSHARED PI mutex writers + seqlock readers</text>
  <text x="605" y="239" text-anchor="middle" class="ns-sm">used only when cross-process state is bounded</text>

  <rect x="510" y="288" width="190" height="54" class="ns-promo"/>
  <text x="605" y="310" text-anchor="middle" class="ns-yel">lazy server-handle promotion</text>
  <text x="605" y="327" text-anchor="middle" class="ns-sm">mint server-visible handle only on rare downstream APIs</text>

  <rect x="760" y="120" width="140" height="106" class="ns-server"/>
  <text x="830" y="146" text-anchor="middle" class="ns-grn">wineserver fallback</text>
  <text x="830" y="163" text-anchor="middle" class="ns-sm">named objects</text>
  <text x="830" y="177" text-anchor="middle" class="ns-sm">cross-process visibility</text>
  <text x="830" y="191" text-anchor="middle" class="ns-sm">unsupported info classes</text>
  <text x="830" y="205" text-anchor="middle" class="ns-sm">promotion targets</text>

  <line x1="220" y1="99" x2="280" y2="99" class="ns-arrow"/>
  <line x1="450" y1="99" x2="510" y2="90" class="ns-arrow-b"/>
  <path d="M450 99 L690 99 L690 173 L760 173" class="ns-arrow-g"/>
  <line x1="605" y1="132" x2="605" y2="168" class="ns-arrow-p"/>
  <line x1="605" y1="252" x2="605" y2="288" class="ns-arrow-y"/>
  <line x1="700" y1="315" x2="760" y2="200" class="ns-arrow-y"/>

  <text x="474" y="82" text-anchor="middle" class="ns-blue">eligible</text>
  <text x="615" y="154" text-anchor="middle" class="ns-pur">bounded shared state</text>
  <text x="610" y="274" text-anchor="middle" class="ns-yel">rare server-required API</text>
  <text x="626" y="122" text-anchor="middle" class="ns-grn">ineligible or unsupported</text>

  <rect x="40" y="286" width="410" height="78" class="ns-box"/>
  <text x="245" y="309" text-anchor="middle" class="ns-label">Shipped surfaces</text>
  <text x="245" y="324" text-anchor="middle" class="ns-sm">nspa_local_file + local sections: client-private file and section handles</text>
  <text x="245" y="338" text-anchor="middle" class="ns-sm">local event: anonymous NtCreateEvent client-range handles</text>
  <text x="245" y="352" text-anchor="middle" class="ns-sm">local timers + local WM_TIMER: sched-hosted dispatch inside the process</text>
</svg>
</div>

Each stub is independent -- they do not share state and do not coordinate.
Together they
form a *strategy*: shrink wineserver request-by-request, until the
handlers that remain are honest and small. The end state -- which is
the long arc of `wine/nspa/docs/wineserver-decomposition-plan.md` -- is
a metadata service for cross-process arbitration only, not an application
server.

---

## 2. The shape of an NT-local stub

Every stub follows the same skeleton. Strip away the API-specific details
and the structure is:

    NTSTATUS NtSomething( ..., IO_STATUS_BLOCK *io )
    {
        NTSTATUS bypass = nspa_local_X_try_bypass( ... );
        if (bypass == STATUS_SUCCESS)        return STATUS_SUCCESS;
        if (bypass == STATUS_<real_error>)   return bypass;
        /* otherwise STATUS_NOT_SUPPORTED -- fall through */
        /* original server path -- unmodified */
        ...
    }

The five invariants every stub honours:

1. **Eligibility predicate.** The stub inspects the call arguments and
   either takes the fast path or returns `STATUS_NOT_SUPPORTED` /
   `STATUS_NOT_IMPLEMENTED`. Anything outside the stub's correctness
   envelope falls back to the unmodified server path. No silent
   correctness drift -- the stub either handles the call exactly as
   the server would, or refuses it.
2. **Private data structures.** A handle range disjoint from the
   server's, a per-process hash table, a per-bucket lock, optionally
   a shmem region, optionally a dispatcher pthread. The stub owns
   these completely; nothing in the server's request handlers
   touches them.
3. **Hot-path locks held briefly.** Every stub takes a `pi_mutex_t`
   (PI-priority-boosting under PREEMPT_RT), mutates its in-memory
   tables, and releases. No blocking syscall, no RPC, no inter-stub
   call is made under the stub's lock. (See §6.)
4. **Honest boundary.** Every stub has a clearly bounded correctness
   envelope. When a call crosses that envelope the stub returns
   `STATUS_NOT_SUPPORTED` / `STATUS_NOT_IMPLEMENTED` and the original
   server path is used unchanged. That is the safety valve when a case
   still needs server authority.
5. **Never observable to the app.** A correctness regression in a stub
   would be caught by Win32 semantics tests, not app-visible behaviour
   shifts. The bypass is an optimisation; it does not relax NT
   semantics, sharing arbitration, error codes, `STATUS_*` returns,
   or `IO_STATUS_BLOCK` content.

The shape is mechanical enough that a new stub for a new NT surface --
say `NtQueryDirectoryFile` -- would be drop-in: define a private handle
range or reuse one, build a per-process table, decide an eligibility
predicate, and write the bypass entry point. The pattern itself is the
reusable element; the per-stub specifics are surface-dependent.

---

## 3. Why progressive stubs beat monolithic decomposition

A reasonable counter-proposal to "ship many NT-local stubs" is "rewrite
wineserver as a multi-threaded handler with per-subsystem locks". This
is the §3.4 of `wineserver-decomposition-plan.md`. It is a valid
long-horizon target but the wrong starting move, for three reasons:

**Audit surface.** Wineserver assumes "nothing else changes during my
handler" pervasively. Every handler reads + writes shared state, often
mutually entangled (a file open might create a kernel object that is
named in the object directory that is held in the handle table that is
referenced from the parent process's handle table). Partitioning the
lock means proving every cross-subsystem invariant explicitly. That's
months of audit work for one architectural change, and the change does
not deliver any user-visible improvement until the whole partitioning
is done.

**Incremental migration vs full rewrite.** Each NT-local stub
intercepts one specific NT surface, services it from outside the
server, and routes anything it cannot model back to the server. The
interception point is the stub's eligibility check; the routing path is
the `STATUS_NOT_SUPPORTED` fallback. Each stub independently delivers a
measurable win on its NT surface and is independently revertible. After
enough surfaces move out, what remains in wineserver is the small set
of handlers that genuinely need cross-process arbitration -- the list
in §4 of the decomposition plan: cross-process object naming, process /
thread lifecycle, handle inheritance, and NT-specific path resolution.

**Practical wins happen before the lock dissolves.** Consider Ableton's
startup profile: ~28,500 file opens in the first session boot, dominated by
regular-file and directory traffic for DLL manifests, `.pyc` files, theme
resources, and library indexes. Every one of those round-trips into
the server today, holds the global lock during sharing arbitration, and
returns. The local-file bypass eliminates the round-trip for the
eligible subset; lock contention drops because the server is not
running the handler at all. Lock partitioning would help the *handlers
that are still running*. Eliminating the handler entirely is a
strictly bigger win.

The progressive-stubs strategy lets us sequence the work:

1. Build stubs that absorb the highest-volume NT surfaces (file opens,
   timers, message-queue carve-outs).
2. Watch the wineserver footprint shrink in `perf` captures.
3. Once a subsystem's wineserver footprint is small, the partitioning
   audit for *that subsystem* is small too -- because there isn't much
   left in the server to audit.
4. Eventually only the §4 honest handlers remain, and at that point
   the lock-partitioning question becomes "is it worth bothering" --
   if wineserver is doing < 1% CPU end-to-end the answer may be "no".

This is the inverted ordering relative to "monolithic rewrite" and it
matches the de-risking discipline the rest of the project uses
(`feedback_validate_before_default_on.md`, `feedback_ship_default_off.md`).

---

## 4. Cross-process state arbitration

Some NT semantics genuinely cross processes. A `FILE_SHARE_NONE` open
in process A must reject a subsequent open in process B. A named
synchronization object created in A must be openable by name from B.
A handle inherited from a parent at process create must be reachable
from the child. These cannot be serviced from within one client's
address space alone -- somebody has to arbitrate.

Stubs handle cross-process state in one of two ways:

**(a) Process-shared shmem with a PSHARED PI mutex.** When the
arbitration data is small, well-bounded, and update-rate-limited, the
stub publishes it into a shared memory region. Wineserver creates the
region (memfd-backed) at first request from a client, and clients
mmap it into their own address space. A `pi_mutex_t` in the shmem,
initialised with `RTPI_MUTEX_PSHARED`, serialises writers across
processes; readers use a seqlock and never block. The local-file
bypass uses this exclusively for its inode-aggregation table:

    /* server/nspa/local_file.c:113 */
    for (b = 0; b < NSPA_INODE_BUCKETS; b++)
        pi_mutex_init( nspa_lock_of( (nspa_inode_bucket_t *)&t->buckets[b] ),
                       RTPI_MUTEX_PSHARED );

Writers (server + clients) take the per-bucket PSHARED PI mutex,
bump the bucket's seq odd, mutate the slot, bump the seq even. Readers
take no lock -- they ACQUIRE-load the seq, copy the slot, ACQUIRE-load
the seq again, and retry on mismatch. Bounded retry (8 attempts in
the local-file table) followed by silent fall-back to "treat as not
found, ask the server" keeps reads RT-safe. The lock holders are the
processes that *own* opens; they boost each other under PI when the
server thread holding the same bucket is at low priority.

**(b) Bypass disabled for the cross-process case.** When the
arbitration is too entangled to map onto shmem-with-seqlock, the stub
simply refuses the cross-process path. Anonymous timers are eligible
for the local-timer bypass; named timers (`OBJECT_ATTRIBUTES->ObjectName`
non-empty) fall through to the server, because their cross-process
visibility lives in the NT object directory which is only accessible
from the server. The local-WM_TIMER stub is even stricter: hwnds owned
by other processes are server-only:

    /* dlls/win32u/nspa/local_wm_timer.c:474 */
    if (owner_pid != GetCurrentProcessId()) return STATUS_NOT_IMPLEMENTED;

The cost of refusal is the lost optimisation on that one call. The
benefit is that the stub never has to model cross-process semantics
that are honestly server-side. Cross-process correctness stays where
it belongs.

**Rule of thumb:** if the arbitration data is `<= 256 KB`, idempotent
under retry, and read-mostly, push it through shmem (option a). If
it's bigger, mutable, or tied to NT object naming, refuse the bypass
(option b). The local-file and local-section path is the main shipped
example of option (a); the timer stubs both use (b). Future stubs such
as named pipes or richer directory/query surfaces will likely require
option (a) for their refcount tables.

---

## 5. Lazy server-handle promotion

Stubs intercept the *creation* call. They do not (necessarily) intercept
every downstream API on the resulting handle. NT has dozens of
`NtSomethingFile` syscalls; instead of stubbing all of them, NSPA's
stubs cover the high-volume hot path (open + read + close) and *lazily
mint a server-recognised handle on demand* for the rare downstream
APIs that need it.

Mechanism, using the local-file bypass as the canonical example:

1. `NtCreateFile` returns a local-range handle (`0x7FFFCxxx` --
   `0x7FFFFFFE`). The handle is recognised as local by a constant-time
   range check `nspa_local_file_is_local_handle(h)`.
2. `NtReadFile`, `NtClose`, and `server_get_unix_fd` all check the
   range and route to the local table -- zero RPC.
3. Some less-common API (`NtCreateSection`, `NtDuplicateObject`,
   `NtQueryInformationFile` for an unsupported info class) genuinely
   needs a server-side handle. Those entry points call:

       /* dlls/ntdll/unix/nspa/local_file.c:1414 */
       HANDLE nspa_local_file_get_or_promote_server_handle( HANDLE local_handle );

   On first call, it issues `nspa_create_file_from_unix_fd` -- an
   NSPA-specific RPC that hands the server the unix fd, a path string,
   and access bits, and gets back a fresh server handle. The server
   handle is cached in the per-process opens table; subsequent calls
   on the same local handle return the cached promoted handle without
   another RPC.
4. The original API can then operate on the promoted handle exactly
   as it would have if the bypass had never been taken. The app sees
   nothing different.

The principle: **stubs accelerate the dominant API set; promotion
preserves correctness for the long tail.** The long-tail APIs cost
exactly one extra RPC (the promotion), once per lifetime of the
handle. Compare to the no-bypass case where the *entire* lifetime is
RPCs.

The same lazy-mint pattern shows up elsewhere. NTSync direct-sync
(client-side sync object creation, `feedback_test_with_pe_binaries.md`)
mints client-range NTSync handles that bypass wineserver, then
promotes to a server handle on first cross-process duplication.
Section objects that back local-file handles get promoted via
`nspa_create_mapping_from_unix_fd` (the same shape as the file
promotion). Each promotion path is a small RPC that wineserver still
serves -- but only at the moment of promotion, not on every API
afterwards.

References:

| Stub | Promotion entry point | RPC |
|---|---|---|
| `nspa_local_file` | `nspa_local_file_get_or_promote_server_handle` (`dlls/ntdll/unix/nspa/local_file.c:1414`) | `nspa_create_file_from_unix_fd` |
| `nspa_local_file` (sections) | `NtCreateSection` intercept | `nspa_create_mapping_from_unix_fd` |
| NTSync direct-sync | client-range handle promote on dup | existing wineserver `dup_handle` |
| `nspa_local_timer` | (none -- backing event is server-allocated up front) | `NtCreateEvent` |
| `nspa_local_wm_timer` | (none -- pure shmem dispatch) | n/a |

Notice that the `nspa_local_timer` stub takes a different design:
rather than returning a private handle and lazily promoting, it
returns a server-allocated `NtCreateEvent` handle from the start.
The bypass is in the *expiry path* (zero-RTT `NtSetEvent` instead of
a server timer-fire), not in the *creation path*. Same goal -- avoid
RPCs on the hot path -- different mechanics. Per-stub design choice.

---

## 6. Lock discipline shared by every stub

Every NT-local stub takes a lock during table mutation. None of them
hold that lock across an RPC, a blocking syscall, or a callback into
unrelated code. This is not optional -- it is the property that lets
the stubs be safe to call from RT-priority client threads and from
audio-callback contexts.

The discipline, as written in `feedback_never_fifo_busyloops.md` and
the `wine-nspa-lockup-audit-20260427.md` audit:

1. **Lock taken briefly.** Acquire `pi_mutex_t`, mutate in-memory
   tables, release. Worst-case hold time is dozens of nanoseconds.
2. **No blocking syscall under lock.** `open()`, `stat()`, `read()`,
   `mmap()` all happen *outside* the per-stub lock. The stub
   sequences them: stat first (no lock), check + publish under
   lock, open second (no lock), insert under lock.
3. **No RPC under lock.** A `wine_server_call` would defeat the
   entire point of the stub -- it's the call we're trying to
   eliminate. RPCs happen before the lock is taken (e.g. table
   mmap-fetch via `nspa_get_inode_table` at first-use) or after
   it's released (e.g. lazy server-handle promotion).
4. **No callback into app code under lock.** Timer fires invoke
   `NtSetEvent` and `NtQueueApcThread` -- both of which can wake
   threads that try to re-enter the stub. The fire path drops the
   lock first, fires, re-acquires.

The local-timer dispatcher's fire loop is a clean illustration:

    /* dlls/ntdll/unix/nspa/local_timer.c:381-432 */
    if (!list_empty( &fire_batch ))
    {
        pi_mutex_unlock( &timer_lock );

        LIST_FOR_EACH_ENTRY_SAFE( t, next, &fire_batch, ... )
        {
            list_remove( &t->queue_entry );
            if (!t->cancelled) fire_timer( t );          /* NtSetEvent + APC */
            pi_mutex_lock( &timer_lock );
            /* re-arm under lock, then drop */
            ...
            pi_mutex_unlock( &timer_lock );
        }

        pi_mutex_lock( &timer_lock );
        continue;
    }

The lock is dropped before any `NtSetEvent` -- which can wake a higher-
priority thread that immediately calls `NtSetTimer` or `NtCancelTimer`,
both of which take `timer_lock`. If the dispatcher held `timer_lock`
through the fire, the woken thread would block on the dispatcher's
release -- a textbook unbounded priority inversion mediated by PI on
the lock, which is *survivable* but expensive. Dropping the lock
makes the inversion impossible at the cost of a refcount on the
in-flight entry (`t->refcount++` before drop, `--t->refcount` after
re-acquire) so a concurrent close can't free the entry mid-fire.

This pattern -- "drop lock, do the dangerous thing, re-acquire" --
shows up in every stub. It is the same discipline `feedback_no_blocking_under_lock.md`
calls out for the wineserver itself; the stubs apply it locally.

The 2026-04-27 audit (see `wine-nspa-lockup-audit-20260427.md`)
explicitly verified this property for every NT-local stub:

> Out of scope: ntsync.c (validated), client-side bucket_lock discipline
> (other-process behaviour), Ableton-internal bugs, performance.
> [...]
> F1-F12: every NT-local stub holds its lock for in-memory mutation only.
> No syscalls, no RPCs, no callbacks under any stub's lock. Refcount
> patterns ensure entries survive lock drops in fire / promote paths.

The audit was a precondition for re-arming the lockup repro. With the
discipline confirmed, the path forward is more stubs -- not different
locking.

---

## 7. Currently shipped stubs

### 7.1 `nspa_local_file` -- local file handles and local sections

**Surface:** bounded `NtCreateFile` for regular files and explicit directory
opens, plus downstream `NtReadFile` / `NtWriteFile` / selected
`NtQueryInformationFile` / `NtSetInformationFile` / `NtFlushBuffersFileEx`
paths, and client-side file-backed sections for the same-process common case.

**Files:**

| Path | Role |
|---|---|
| `dlls/ntdll/unix/nspa/local_file.c` (1630 lines) | client-side stub: handle range, table, lookup, bypass entry, promotion |
| `server/nspa/local_file.c` (300 lines) | server-side cross-process inode-aggregation shmem |
| `include/wine/server_protocol.h` | `nspa_get_inode_table`, `nspa_create_file_from_unix_fd` requests |

**Entry point:** `nspa_local_file_try_bypass` at `local_file.c:1238`.
Called from `dlls/ntdll/unix/file.c:4717` inside `NtCreateFile`,
right after path resolution.

**Eligibility predicate:** bounded regular-file and explicit-directory opens:
no loader-owned image path, no root-directory or custom security-descriptor
shape, no open-by-id, no delete-on-close, and only the dispositions and access
masks the local table knows how to preserve correctly. The shipped envelope is
materially broader than the first public draft: it includes common write-class
opens, explicit `FILE_DIRECTORY_FILE` cases, selected metadata updates, common
flush paths, and local `FileEndOfFileInformation`.

**Private handle range:** `[0x7FFFC000, 0x80000000)` (16 KiB window,
4096 handles), excluding `0x7FFFFFFF` for `CURRENT_PROCESS`. Range
check via `nspa_local_file_is_local_handle(h)` is constant-time.

**Per-process table:** linked list of `struct nspa_local_open` under
a single `pi_mutex_t nspa_lf_opens_mutex`. Each entry caches:
- the local handle returned to the app
- the unix fd
- (device, inode) for shmem cross-process arbitration
- access / sharing bits
- the original NT path string for `GetFinalPathNameByHandle`
- the lazy-promoted server handle (0 until first promote)

**Local sections on top:** eligible unnamed file-backed sections now get a
second client-private handle range of their own. The section duplicates the
backing unix fd at creation time, publishes `FILE_MAPPING_*` bits back into the
same local-file sharing aggregate, and can then map, query, unmap, and close
inside the client process. Same-process `DuplicateHandle` promotes once to a
server section; cross-process duplication remains an honest server boundary.

**Cross-process arbitration:** server-allocated memfd-backed shmem
region of `nspa_inode_bucket_t` buckets. Each bucket has a PSHARED
PI mutex, a seqlock, and N subentries (one per process holding an
open of any inode that hashes to this bucket). Server publishes its
own subentry under index 0; clients publish into 1..N-1. Hash:
`device * 0x9E3779B97F4A7C15 + inode`, mixed twice -- byte-identical
between client and server (`local_file.c:180` mirrors
`server/nspa/local_file.c:135`).

**Lock discipline:** `nspa_lf_opens_mutex` covers in-memory list
operations only; `stat`, `open`, `mmap` happen outside. The PSHARED
bucket mutex is taken cross-process for the seqlock-write, dropped
before any further work. Reads are seqlock-bounded with 8-retry cap.

**Lazy promotion:** `nspa_local_file_get_or_promote_server_handle`
mints a server handle via `nspa_create_file_from_unix_fd` RPC and
caches it. Long-tail NT surfaces still route through that promoted
handle, but eligible file-backed sections no longer force an immediate
promote just to exist.

**Dedicated references:** [Local-File Bypass Architecture](nspa-local-file-architecture.gen.html)
for the file-handle path and [Local Section Bypass](local-section-architecture.gen.html)
for the section lifecycle and duplicate boundary.

### 7.2 anonymous local events -- `NtCreateEvent` fast path

**Surface:** anonymous `NtCreateEvent` on the client-range fast path,
with the server still able to signal those events correctly when they
are passed into server-managed async-I/O paths.

**Files:**

| Path | Role |
|---|---|
| `dlls/ntdll/unix/sync.c` | anonymous event create, client-handle allocation, inproc-sync cache population, register / unregister with wineserver |
| `server/nspa/inproc_event_table.c` | per-process `(client handle -> ntsync fd)` registration table |
| `server/async.c` | fallback lookup and direct `NTSYNC_IOC_EVENT_SET` signaling on completion |

**Design shape:** the event object itself is client-local, but the server is
made aware of it at creation time. That is the important distinction from the
older anonymous-event fast path: when a client-range event handle later crosses
into a wineserver-managed async path, the server does not reject it as an
unknown handle. Instead it looks up the registered ntsync fd and signals that
fd directly on completion.

That completion path is broader than the raw `NtCreateEvent` call itself. It is
the thing that keeps named-pipe / RPC listener waits, SCM-via-pipe startup, and
wined3d-style present-completion events working once anonymous events flip to
client-range by default.

**Async parity detail:** the shipped implementation also mirrors the server's
normal queue-time `reset_event` discipline before async operations are armed.
That fix landed during the same session after validation exposed stale
`io_status` behaviour on the client-range path.

**Eligibility:** anonymous only. Named, inherited, or directory-relative
events still fall through to the server because their semantics live in the NT
object namespace.

**Architectural consequence:** this is now the base that anonymous local timers
build on. The timer stub no longer needs a temporary helper to create a
server-visible backing event up front; it can call `NtCreateEvent` directly and
inherit the same client-range fast path.

**Validation note:** smoke 0/1 were clean after
the reset fix, with zero `err:service`, `err:rpc`, or `err:ole` errors.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 350" xmlns="http://www.w3.org/2000/svg">
  <style>
    .le-bg { fill: #1a1b26; }
    .le-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.5; rx: 8; }
    .le-fast { fill: #1a2235; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .le-srv { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 8; }
    .le-note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .le-t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .le-s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .le-h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .le-g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .le-y { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .le-line-b { stroke: #7aa2f7; stroke-width: 1.5; fill: none; }
    .le-line-g { stroke: #9ece6a; stroke-width: 1.5; fill: none; }
  </style>

  <rect x="0" y="0" width="940" height="350" class="le-bg"/>
  <text x="470" y="26" text-anchor="middle" class="le-h">Anonymous local event with server-aware completion</text>

  <rect x="50" y="82" width="230" height="84" class="le-fast"/>
  <text x="165" y="110" text-anchor="middle" class="le-t">PE-side `NtCreateEvent`</text>
  <text x="165" y="132" text-anchor="middle" class="le-s">client-range handle + ntsync fd</text>
  <text x="165" y="150" text-anchor="middle" class="le-s">cached in inproc-sync table</text>

  <rect x="355" y="82" width="230" height="84" class="le-srv"/>
  <text x="470" y="110" text-anchor="middle" class="le-g">server registration table</text>
  <text x="470" y="132" text-anchor="middle" class="le-s">(client handle -> ntsync fd)</text>
  <text x="470" y="150" text-anchor="middle" class="le-s">per-process, lazy lifetime</text>

  <rect x="660" y="82" width="230" height="84" class="le-srv"/>
  <text x="775" y="110" text-anchor="middle" class="le-t">server async completion</text>
  <text x="775" y="132" text-anchor="middle" class="le-s">direct `NTSYNC_IOC_EVENT_SET` on registered fd</text>
  <text x="775" y="150" text-anchor="middle" class="le-s">no `STATUS_INVALID_HANDLE` fallback failure</text>

  <path d="M280 124 L355 124" class="le-line-b"/>
  <path d="M585 124 L660 124" class="le-line-g"/>

  <rect x="150" y="214" width="640" height="76" class="le-note"/>
  <text x="470" y="246" text-anchor="middle" class="le-y">Why this matters</text>
  <text x="470" y="264" text-anchor="middle" class="le-s">client-range events now compose with server-managed async paths</text>
  <text x="470" y="278" text-anchor="middle" class="le-s">instead of being limited to purely local waits</text>
</svg>
</div>

### 7.3 `nspa_local_timer` -- `NtSetTimer` fast path

**Surface:** `NtCreateTimer` (anonymous only), `NtSetTimer`,
`NtCancelTimer`, `NtQueryTimer`.

**Files:**

| Path | Role |
|---|---|
| `dlls/ntdll/unix/nspa/local_timer.c` (713 lines) | the entire stub: dispatcher, table, fire path |

**Entry points** (all in `dlls/ntdll/unix/sync.c`, all check
`nspa_local_timer_*` first and fall through on `STATUS_NOT_IMPLEMENTED`):

| Sync.c line | Function | Stub call |
|---|---|---|
| 2655 | `NtCreateTimer` | `nspa_promote_if_local` (no-op for timers) |
| 2709 | `NtCreateTimer` | `nspa_local_timer_create` |
| 2768 | `NtSetTimer` | `nspa_local_timer_set` |
| 2803 | `NtCancelTimer` | `nspa_local_timer_cancel` |
| 2837 | `NtQueryTimer` | `nspa_local_timer_query` |

**Design twist:** unlike the local-file bypass, the timer stub does
*not* return a private timer handle. The object still presents itself as
an event-backed timer handle to the rest of Wine. What changed on
2026-05-02 is that the anonymous backing event now comes from the same
client-range `NtCreateEvent` fast path described in §7.2, rather than
from a dedicated temporary helper.

The bypass is still in the *firing* path. On expiry the timer code issues
`NtSetEvent` against the backing event handle. Because that handle is now
client-range by default, expiry stays entirely on the local fast path unless
the event later crosses into a server-managed async surface.

**Dispatch host:** when RT is available and
`NSPA_SCHED_USE_FOR_LOCAL_TIMER` is left at its default setting, timer expiry
is hosted on the shared `wine-sched-rt` thread instead of a dedicated helper
pthread. The priority class stays the same (`SCHED_FIFO` at
`NSPA_RT_PRIO - 1`); the win is consolidation and shared infrastructure, not a
different scheduler policy.

**Eligibility:** anonymous only (`!attr->ObjectName`). Named timers
fall through to the server because their cross-process visibility
lives in the NT object directory.

**Clock semantics:** internal deadlines are `CLOCK_MONOTONIC`
absolute nanoseconds. NT relative `when` (negative LARGE_INTEGER)
maps cleanly -- elapsed time is what monotonic measures. NT absolute
`when` (positive FILETIME) is converted at insert time via the
current `CLOCK_REALTIME / CLOCK_MONOTONIC` offset; an NTP step
between insert and fire is absorbed at the cost of the step size.
For audio/RT workloads using only relative timers, this is the
correct trade. (See `local_timer.c:34-48` for the design comment.)

**Lock discipline:** `pi_mutex_t timer_lock` covers the table and
the deadline queue. `fire_timer` (which calls `NtSetEvent` and
`NtQueueApcThread`) runs *outside* the lock with a refcount on the
entry. The dispatcher loop at `local_timer.c:346-437` is the
canonical drop-fire-reacquire pattern.

**Scheduler boundary:** `NSPA_SCHED_USE_FOR_LOCAL_TIMER=0` keeps the
older dedicated RT helper thread instead of the shared sched host.

### 7.4 `nspa_local_wm_timer` -- `WM_TIMER` dispatcher

**Surface:** `NtUserSetTimer`, `NtUserSetSystemTimer`, `NtUserKillTimer`,
`NtUserKillSystemTimer`, plus `WM_TIMER` / `WM_SYSTIMER` posting into
the message queue.

**Files:**

| Path | Role |
|---|---|
| `dlls/win32u/nspa/local_wm_timer.c` (638 lines) | the entire stub: dispatcher, table, ring publish |
| `dlls/win32u/message.c:4694, 4736, 4770, 4791` | call-sites in `NtUserSetTimer` etc. |

**Entry points** (all check `nspa_local_wm_timer_*` first and fall
through on `STATUS_NOT_IMPLEMENTED`):

| message.c line | Function | Stub call |
|---|---|---|
| 4694 | `NtUserSetTimer` | `nspa_local_wm_timer_set(WM_TIMER)` |
| 4736 | `NtUserSetSystemTimer` | `nspa_local_wm_timer_set(WM_SYSTIMER)` |
| 4770 | `NtUserKillTimer` | `nspa_local_wm_timer_kill(WM_TIMER)` |
| 4791 | `NtUserKillSystemTimer` | `nspa_local_wm_timer_kill(WM_SYSTIMER)` |

**Design twist:** WM_TIMERs are posted into the *owner thread's*
message queue, not the calling thread's. The stub resolves
`hwnd -> owner_tid` at SetTimer time (which is when the caller has
a wineserver session and can do the resolution), caches a pointer
into the *peer's* `nspa_queue_bypass_shm_t`, and the dispatcher
thread later writes WM_TIMER ring slots into that peer shmem
directly:

    /* dlls/win32u/nspa/local_wm_timer.c:478-484 */
    if (owner_tid == GetCurrentThreadId())
        peer_shm = nspa_get_own_bypass_shm_public();
    else
        peer_shm = nspa_get_peer_bypass_shm_public( owner_tid );
    if (!peer_shm) return STATUS_NOT_IMPLEMENTED;

The dispatcher is a pure shmem-writer -- it never enters wineserver.
`peek_message` on the consumer side drains the ring client-side via
`nspa_try_pop_own_timer_ring`. End-to-end, a WM_TIMER expiry is a timer
wake plus a ring-slot store plus a consumer ring-pop. Server's old
`pending_timers` / `expired_timers` dispatch is bypassed entirely.

As of 2026-05-02, eligible WM_TIMER dispatch also shares the RT sched
host instead of owning a dedicated helper pthread. That keeps the same
effective priority while removing another per-process helper thread.

**Cross-process refusal:** hwnds owned by other processes are
explicitly rejected (`local_wm_timer.c:474`). Cross-process WM_TIMERs
go through the server, where the server can do the cross-process
post correctly. The bypass declines cases it can't handle as
correctly as the server -- option (b) of §4.

**Coalescing semantics:** NT's `WM_TIMER` has implicit coalescing --
if the message pump stalls across N periods, the app sees one
`WM_TIMER`. The stub replicates this by tagging entries with `in_ring`
on publish; the dispatcher only re-arms once the consumer drains
the slot (`local_wm_timer.c:281-309`). Server's `restart_timer`
discipline mapped to a slot-state check.

**Lock discipline:** `pi_mutex_t wm_timer_lock` covers the table
and wheel. Ring publishes use atomic state machine on the slot
without taking the lock -- the slot's state byte is the
synchronisation point with the consumer. The dispatcher does not
issue any wineserver RPC.

**Scheduler boundary:** `NSPA_SCHED_USE_FOR_WM_TIMER=0` keeps the
older dedicated RT helper thread instead of the shared sched host.

**2026-04-30 follow-up:** [`78947c1`](https://github.com/nine7nine/Wine-NSPA/commit/78947c1)
tightened the eligibility predicate so `TIMERPROC` and cross-thread
`SetTimer` cases now refuse the stub and defer to the server. That is
the correct NT-local-stub shape: keep the cheap owner-thread path local,
and route anything with ambiguous ownership or callback semantics back
to the authoritative server path.

---

## 8. Future stubs (roadmap)

The pattern is generalisable. A handful of high-volume NT surfaces
remain in the server today; each is a candidate for a future stub.

**`NtQueryDirectoryFile`.** Directory enumerations dominate certain
workloads (file dialogs, plugin scanners, installers). A stub backed
by a per-process directory-handle table and `getdents64` syscalls,
returning a private handle range, is a natural extension of the
local-file bypass. Eligibility predicate: read-only directory open,
no notify, single-process consumer. Cross-process visibility is not
a concern -- directory contents are filesystem state, the kernel is
the source of truth, no wineserver mediation is needed once the
handle is in our table.

**`NtFsControlFile` for named-pipe and registry ops.** Many FSCTLs
(query mountpoint, query partition, registry queries) are read-only
and don't need server arbitration. Per-FSCTL stubbing is feasible.

**Richer section and mapping cases.** The shipped local-section path
already absorbs eligible unnamed file-backed sections in the same
process. What still remains server-owned is the harder edge of the
surface: named sections, cross-process duplication, and image-mapping
semantics.

**More message-queue carve-outs.** The `nspa_msg_ring` v2 work
(see `MEMORY.md` indices) is a stub-shaped bypass for message
posting and peeking. The direct `get_message` bypass continues this
direction: the shipped bucketing diagnostic
(`project_msg_ring_v2_phase_c_stage1_validated`) identified that
server-generated `WM_PAINT` / hardware / winevent messages dominate
the Ableton workload's get_message traffic. A stub for those classes
would push the consumer side fully off the server's `find_msg_to_get`
path.

**Timer further work.** The `NtSetTimerEx` variant with completion
ports is currently always server-routed. A completion-port-aware
local-timer stub would extend `nspa_local_timer` to handle that
case, at the cost of building a per-process completion-port-mux.

The roadmap section of `wineserver-decomposition-plan.md` has the
broader timeline; this list is the NT-local-stub-shaped subset.

---

## 9. Connection to wineserver decomposition

Each NT-local stub shrinks the wineserver footprint along one NT
surface. As the surfaces add up, the decomposition plan changes:

**Today:** wineserver runs `channel_dispatcher` 6-11%
of CPU under load, `get_ptid_entry` 1-10%, `main_loop_epoll` 2-7%.
The hot path is the channel-RECV / handler / channel-REPLY loop
running under `global_lock`. Stubs are absorbing the
highest-frequency NT calls (file opens, anonymous timers, owner-
process WM_TIMERs); the channel traffic is shrinking in those
classes.

**Mid-term:** as more stubs ship -- directory enumeration,
named-pipe FSCTLs, named or cross-process section cases -- the channel traffic that
remains in the server is exactly the cross-process arbitration set
of §4 of the decomposition plan. At that point the §3.2
"router/handler split" of the decomposition plan becomes natural:
the router's "fast-path" is just "pass to a stub if a stub claims
the call". Most of the codebase is already structured this way --
the stub call is the first thing the NT entry point does, so the
"router" is the current control flow. Decomposition becomes folding
existing handlers into nt-local stubs, not rewriting wineserver.

**End-state:** wineserver is a metadata service. Cross-process
object naming, process / thread lifecycle, handle inheritance,
NT-specific path resolution -- the §4 list. At that point the §3.4
"lock partitioning" question is not "should we" but "is it worth
the audit". If the metadata service is doing < 0.5% CPU end-to-end
under audio + UI load, the answer is probably no -- and the lock
stays a single global pi_mutex_t because there's nothing left to
contend on.

**The migration is complete when wineserver is small enough that it is
no longer a meaningful hot-path component.**

---

## 10. References

| Reference | Purpose |
|---|---|
| `nspa-local-file-architecture.gen.html` | Per-stub deep dive on the local-file bypass |
| `dlls/ntdll/unix/nspa/local_file.c:1238` | `nspa_local_file_try_bypass` entry |
| `dlls/ntdll/unix/nspa/local_file.c:1414` | `nspa_local_file_get_or_promote_server_handle` (lazy promotion) |
| `dlls/ntdll/unix/nspa/local_file.c:1207` | `nspa_local_file_is_local_handle` (range check) |
| `server/nspa/local_file.c:113` | PSHARED PI mutex init for inode-table buckets |
| `server/nspa/local_file.c:181` | `nspa_inode_publish_slot` seqlock-write protocol |
| `dlls/ntdll/unix/nspa/local_timer.c:346` | `dispatcher_main` (drop-fire-reacquire) |
| `dlls/ntdll/unix/nspa/local_timer.c:465` | `nspa_local_timer_create` (anonymous-only check) |
| `dlls/ntdll/unix/sync.c:2709` | `NtCreateTimer` call-site for local-timer stub |
| `dlls/win32u/nspa/local_wm_timer.c:227` | `publish_timer_slot` (peer-shmem ring write) |
| `dlls/win32u/nspa/local_wm_timer.c:457` | `nspa_local_wm_timer_set` (cross-process refusal) |
| `dlls/win32u/message.c:4694` | `NtUserSetTimer` call-site for WM_TIMER stub |
| `wine/nspa/docs/wineserver-decomposition-plan.md` | Long-arc decomposition plan (NT-local stubs are §3.x) |
| `wine/nspa/docs/wine-nspa-lockup-audit-20260427.md` | Lock-discipline audit confirming every stub holds locks briefly |
| `wine/nspa/docs/local-file-bypass-design.md` | Original design doc for the local-file bypass |
| `MEMORY.md: project_msg_ring_v2_phase_c_stage1_validated` | msg-ring bucketing diag (basis for future message-queue stubs) |
