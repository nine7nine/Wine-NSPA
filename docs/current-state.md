# Wine-NSPA — State of The Art

This page is the current state snapshot: kernel patch state, live userspace
features, exact defaults, targeted validation totals, and the current
architecture boundary.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Current state](#2-current-state)
3. [Active subsystems](#3-active-subsystems)
4. [Validation and performance](#4-validation-and-performance)
5. [Open work, in priority order](#5-open-work-in-priority-order)
6. [Recent landed arc](#6-recent-landed-arc-2026-04-30-to-2026-05-10)
7. [Configuration reference](#7-configuration-reference)
8. [Doc index](#8-doc-index)

---

## 1. Overview

The public 2026-05-09 state is no longer just "aggregate-wait plus a faster
dispatcher". The current stack layers several larger client-side and
shared-state follow-ons on top of that base:

- the **spawn-main + `ntdll_sched` substrate**, the per-process client
  scheduler host for close-queue and RT timer consumers
- the **local event / local timer / local WM_TIMER consolidation**, with
  anonymous events using client-range handles by default and the timer
  dispatchers moved
  onto the shared RT sched host when RT is available
- the **socket `io_uring` RECVMSG / SENDMSG path**, enabled through
  `NSPA_URING_RECV=1` and `NSPA_URING_SEND=1`
- the **local section and widened local-file path**, which keeps eligible
  file-backed sections client-side and retires more file metadata, flush, EOF,
  directory, and write-class traffic from wineserver
- the **thread / process shared-state readers**, which serve read-mostly query
  classes from seqlock-published shared objects and also power the
  zero-time process and thread wait fast paths
- the **message-pump empty-poll cache**, which retires a large chunk of
  same-filter `get_message` empty polls without pretending the whole message
  pump is client-complete
- the **RT memory safety follow-ons**, which keep the hugetlb path honest under
  pool pressure, partial view operations, `MEM_RESET`, and RWX JIT allocation
- the **hot-path optimization layer**, which includes x86_64 TEB-relative
  thread state, inline current-thread/current-process/PEB/tick helpers,
  msg-ring per-thread cache lookups inside the TEB, cacheline-isolated
  `inproc_sync` entries, smaller wait-path helper cost, and AVX2
  ASCII-burst string / Unicode loops on x86_64

The important architectural distinction is that these are not isolated feature
flags. They continue the same direction as gamma, local-file, msg-ring, and
the earlier timer work: move latency-sensitive common-case work out of the
single-threaded wineserver path while keeping honest fallback paths for
cross-process or server-authoritative semantics.

Project shape: one small ntsync kernel overlay on top of upstream `ntsync`
plus a Wine fork that increasingly
routes work through kernel-mediated channels, client-range sync objects,
bounded shared-memory rings, server-published shared objects, local NT stubs,
per-process scheduler hosts, and RT-keyed memory tuning. When `NSPA_RT_PRIO`
is unset, the RT-specific paths still stand down and upstream-Wine behaviour
remains available.

---

## 2. Current state

### 2.1 Kernel and ntsync overlay

| Item | Value |
|---|---|
| Kernel | `6.19.11-rt1-1-nspa` |
| Scheduler | `PREEMPT_RT_FULL` |
| ntsync `.ko` | `/lib/modules/6.19.11-rt1-1-nspa/kernel/drivers/misc/ntsync.ko` |
| Module ref count | 0 idle |
| Sources | upstream `drivers/misc/ntsync.{c,h}` plus the Wine-NSPA ntsync overlay |

### 2.2 Userspace baseline

| Item | Value |
|---|---|
| Wine base | Wine 11.8 + NSPA fork |
| Dispatcher shape | gamma + aggregate-wait + post-1011 `TRY_RECV2` burst drain |
| Client scheduler | spawn-main + `ntdll_sched`, default-class and RT-class consumers live |
| Async file path | dispatcher-owned async `CreateFile` on the per-process ring |
| Async socket path | `io_uring` `RECVMSG` / `SENDMSG` on the deferred path |
| Shared-state query path | thread + process shared-object readers; zero-time process wait can short-circuit from `process_shm`, and zero-time thread wait can short-circuit from `thread_shm` |
| Message-pump cache | empty same-filter `get_message` polls can return locally when `queue_shm->nspa_change_seq` has not advanced, and msg-ring per-thread caches read through TEB-backed state |
| Hot-path optimization layer | x86_64 unix-side `NtCurrentTeb()` is inline, `get_thread_data()` reads through a TEB backpointer, `inproc_sync` entries are cacheline-isolated, dormant `io_uring` helper calls are inlined away, and ASCII-dominant string / Unicode loops use AVX2 fast windows on x86_64 |
| Memory surface | local sections, large pages, current-process `QueryWorkingSetEx`, working-set quota bookkeeping, RT-keyed `mlockall()`, automatic hugetlb promotion, and heap arena hugetlb backing |
| Local sync path | anonymous events client-range by default; timers piggyback on that base |
| X11 flush policy | `NSPA_FLUSH_THROTTLE_MS=8`, default ON |

### 2.3 Patch stack on top of upstream ntsync

| # | Patch | Summary | Status |
|---|---|---|---|
| 1003 | Priority inheritance | Mutex owner PI boost, priority-ordered waiter queues, raw_spinlock + rt_mutex hardening | Active |
| 1004 | Channels | Per-process kernel-mediated request/reply channel object (gamma dispatcher backbone) | Active |
| 1005 | Thread-token | Per-thread token carried across channel sends; backs gamma T1/T2/T3 | Active |
| 1006 | RT alloc-hoist | Hoist `kfree`/`kmalloc` out from under `raw_spinlock` (six sites; pi_work pool/cleanup pattern) | Active |
| 1007 | Channel exclusive recv | `wait_event_interruptible_exclusive` + `wake_up_interruptible` — closes thundering-herd on channel waiter wake | Active |
| 1008 | EVENT_SET_PI deferred boost | Stage boost decision under `obj_lock`, apply inline at wait-return — no worker thread, no timer | Active |
| 1009 | channel_entry refcount | `refcount_t` on `ntsync_channel_entry`; closes REPLY-vs-cleanup UAF caught by KASAN in `test-channel-stress` | Active |
| 1010 | Aggregate-wait | Heterogeneous object+fd wait; channel notify-only path used by the gamma dispatcher | Active |
| 1011 | Channel TRY_RECV2 | `NTSYNC_IOC_CHANNEL_TRY_RECV2`: non-blocking `RECV2` for post-dispatch burst drain | Active |
| 1012 | Receive snapshot fix | snapshots popped channel-entry fields under `obj_lock`; closes post-1011 slab UAF on `RECV` / `RECV2` | Active |
| 1013 | Dedicated slab caches | moves the three hot small ntsync allocation classes into dedicated `kmem_cache`s with `SLAB_HWCACHE_ALIGN` | Active |
| 1014 | Lockless SEND_PI target scan | `list_empty_careful` fast-path avoids a wasted `wq->lock` round-trip on the common empty-queue case | Active |
| 1015 | Wait-queue cache and cache isolation | adds a dedicated `ntsync_wait_q` cache for common waits and applies `SLAB_NO_MERGE` across all four ntsync caches so the isolation story holds on the production kernel | Active |

### 2.4 2026-04-30 dispatcher and flush follow-ons

| Change | Effect |
|---|---|
| `NSPA_FLUSH_THROTTLE_MS=8` | `x11drv_surface_flush`: `8.23%` -> `4.74%` (`-43%`); `copy_rect_32` memmove: `4.38%` -> `2.49%` (`-43%`); MainThread CPU recovered: `~5.4` percentage points |
| aggregate-wait + `TRY_RECV2` burst drain | dispatcher drains multiple queued entries per wake instead of paying N aggregate-wait round-trips |
| dispatcher-owned async `CreateFile` | removes the `open()` lock-drop critical section from the audio xrun path |
| dispatcher helper inlining and lighter fences | removes queue-helper call overhead, strips allocator-debug tax from production, and inlines `read_request_shm` on the dispatcher path |

### 2.5 2026-05-01 compatibility and GUI follow-ons

| Change | Landed effect | Observed result |
|---|---|---|
| AVX2 alpha-bit flush | `dlls/winex11.drv/bitblt.c::x11drv_surface_flush` is vectorized | `x11drv_surface_flush`: `6.72%` -> `2.39%` (`-4.33pp`, `-64%`); total `winex11.so`: `6.76%` -> `2.43%` (`-4.33pp`) |
| Tier 1 log-noise cleanup | dominant stub FIXMEs are once-guarded and `ShutdownBlockReasonCreate/Destroy` succeed silently | top stub noise drops from `~565` prints per Ableton run to `~5` first-time prints |

### 2.6 2026-05-02 client-side follow-ons

| Change | Effect |
|---|---|
| spawn-main + `ntdll_sched` | one default scheduler host per process, plus lazy RT-class host |
| sched-hosted `local_timer` + `local_wm_timer` | eligible timer work moves onto shared `wine-sched-rt` instead of dedicated helper threads |
| anonymous local events | `NtCreateEvent` uses the client-range fast path while async completion remains server-correct |
| socket `RECVMSG` / `SENDMSG` | deferred socket I/O uses true socket SQEs on the PE side |
| local-file async close queue | eligible fully-shareable local-file closes leave the caller thread immediately and drain on `wine-sched` |

### 2.7 2026-05-03 local-file and section follow-ons

| Change | Effect |
|---|---|
| widened local-file envelope | more regular-file, directory, metadata, flush, and EOF traffic stays client-side |
| local sections | eligible unnamed file-backed sections stay client-side for create / map / query / unmap / close |
| widened local open dispositions and access masks | `create_file` handler count `7,845` -> `5,658` (`-28%`), handler time `137 ms` -> `50 ms` (`-64%`) on the compared run |
| local-section path | `nspa_create_mapping_from_unix_fd` count `2,664` -> `~800` (`-70%`); total wineserver handler time `1,991 ms` -> `1,077 ms` on the cleanest run |

### 2.8 2026-05-05 memory and kernel follow-ons

| Change | Effect |
|---|---|
| ntsync wait-queue cache and cache isolation | all four ntsync caches stay unmerged on the production kernel, including the dedicated wait-queue cache |
| RT-keyed `mlockall()` | perf page faults `561/s` -> `451/s`; bpf page faults `869/s` -> `629/s`; max futex wait `94us` -> `49us`; `VmLck` around `300848kB` |
| RT-keyed automatic hugetlb promotion | conservative hugepage auto-promotion is keyed only off `NSPA_RT_PRIO` |
| RT-keyed heap arena hugetlb backing | hugepage regions `3/6` -> `104`; dTLB miss / insn -> `0.071%`; `mmap` rate `33-61/s` -> `0.13/s`; `mprotect` rate `56-90/s` -> `0.03/s`; page-faults `753-869/s` -> `2.8/s` |
| memory gate cleanup | per-feature memory env gates removed; `NSPA_RT_PRIO` is the single public RT memory gate |

### 2.9 Shared-state, message, and memory follow-ons

| Change | Effect |
|---|---|
| thread shared-state readers | 7 `NtQueryInformationThread()` classes use seqlock-published thread snapshots with RPC fallback |
| process shared-state readers | 6 `NtQueryInformationProcess()` classes use seqlock-published process snapshots with RPC fallback |
| zero-time process wait fast path | `WaitForSingleObject(process, 0)` can answer from `process_shm.exit_code`, cutting synthetic poll cost from `~10000 ns` to `~144 ns` |
| `get_message` empty-poll cache | empty-poll Ableton run: `get_message` `3,880 -> 866` calls / 60 s, handler time `46.8 ms -> 36.9 ms`, direct `get_message` time `16.5 ms -> 2.2 ms` |
| hugetlb safety + fallback | auto-promoted views demote before sub-huge partial ops, fall back cleanly on pool exhaustion, respect a 10% free-pool watermark, and allow `PAGE_EXECUTE_READWRITE` auto-promotion |
| `MEM_RESET` reclaim under `mlockall()` | `MEM_RESET` uses `munlock + MADV_DONTNEED`, so reclaimed pages can actually leave RAM before their next touch |

### 2.10 Hot-path optimization follow-ons

| Change | Effect |
|---|---|
| zero-time thread wait fast path | `WaitForSingleObject(thread, 0)` can answer from `THREAD_SHM_FLAG_TERMINATED`, cutting synthetic poll cost from `~11940 ns` to `~164 ns` |
| x86_64 inline `NtCurrentTeb()` | 30 s playback counters: CPU cycles `257.8B -> 220.9B`, iTLB-load-misses `242M -> 185M`, `NtCurrentTeb` function calls `9,961,441 -> 566` |
| x86_64 inline current-thread/current-process/PEB/tick helpers | `PsGetCurrent*Id()`, `RtlGetCurrentPeb()`, `WINE_UNIX_LIB` `GetCurrent*Id()`, and `NtGetTickCount()` collapse to direct TEB or `KUSER_SHARED_DATA` reads on the Unix side |
| msg-ring TEB-backed per-thread caches | 30 s playback counters: CPU cycles `220.9B -> 212.4B`, `pthread_getspecific` self time `0.46% -> 0.09%`, `nspa_get_own_bypass_shm` `0.26% -> 0.20%` |
| `inproc_sync` cacheline isolation + capacity restore | each entry occupies one cacheline, removing cross-handle false sharing on hot refcount `LOCK` ops while keeping total cacheable handle capacity at `524288` |
| `io_uring` helper inlining | `ntdll_io_uring_flush_deferred()` empty-path cost (`0.82%` audio-thread time) and `ntdll_io_uring_get_eventfd()` helper cost (`0.15%`) are removed from the steady-state wait path |
| x86_64 AVX2 string / Unicode loops | `server/unicode.c::{memicmp_strW,hash_strW}` and `dlls/ntdll/locale_private.h::{utf8_wcstombs,utf8_mbstowcs}` vectorize ASCII windows while preserving scalar fallback for mixed or non-ASCII windows |

### 2.11 Validation baseline

| Layer | Run | Result | Ops | Errors |
|---|---|---|---|---|
| Native suite | `run-rt-suite.sh native` | 3 PASS / 0 FAIL | `test-event-set-pi`, `test-channel-recv-exclusive`, `test-aggregate-wait` | 0 |
| Native aggregate | `test-aggregate-wait` | 9/9 PASS | kitchen-sink: 86,528 wakes / 0 timeouts / 0 errors | 0 |
| PE matrix | `nspa_rt_test.exe baseline+rt` | 24 PASS / 0 FAIL / 0 TIMEOUT | baseline + RT | 0 |
| PE dispatcher A/B | `dispatcher-burst` | PASS in matrix | steady-state 100k iters; burst 8 × 1000 × 64 = 512k ops | 0 |
| Busy-workload perf | Ableton 30s busy capture | PASS | `channel_dispatcher` 14.51% -> 0.70%; samples 38,588 -> 19,415 | 0 |

**Layer 1 totals: 3 PASS / 0 FAIL. Layer 2 totals: 24 PASS / 0 FAIL /
0 TIMEOUT. The full-suite public boundary is still those totals; the
newer `1012-1015`, memory, and hot-path carries are documented as
targeted follow-on validation on top of that base.**

NTSync detail lives on two public pages:
`ntsync-pi-driver.gen.html` for the kernel overlay and
`ntsync-userspace.gen.html` for Wine's in-process sync path. Dispatcher
and async-completion detail lives on
`gamma-channel-dispatcher.gen.html` and
`aggregate-wait-and-async-completion.gen.html`.

---

## 3. Active subsystems

### 3.1 RT priority inheritance — four paths

The four PI coverage paths are unchanged from the v6 board, all still
active when `NSPA_RT_PRIO` is set:

| Path | Win32 surface | Wine layer | Kernel mechanism |
|---|---|---|---|
| A | `EnterCriticalSection` | `RtlEnterCriticalSection` (TID CAS fast-path → unix slow-path) | `FUTEX_LOCK_PI` rt_mutex |
| B | `WaitForSingleObject` / `Multiple` | `NtWaitForSingleObject` → `inproc_wait` → `ioctl(/dev/ntsync)` | `/dev/ntsync` PI (1003) |
| C | `pi_cond_wait` (vendored librtpi) | librtpi unix-side header-only | `FUTEX_WAIT_REQUEUE_PI` |
| D | `SleepConditionVariableCS` | `NtNspaCondWaitPI` (3 syscalls + condvar→mutex map) | `FUTEX_WAIT_REQUEUE_PI` |

When `NSPA_RT_PRIO` is unset, every code path is byte-identical to
upstream Wine. Zero overhead.

### 3.2 Bypass and infrastructure subsystems

The dominant architectural change over the last six months has been
moving state out of the single-threaded wineserver event loop into
bounded shmem rings or direct kernel-mediated channels, each with its
own correctness proof and gate.

| Subsystem | Status | Default | Brief |
|---|---|---|---|
| **Gamma channel dispatcher** | Active | ON | Per-process kernel-mediated channel via ntsync 1004/1005/1011, with post-1010 aggregate-wait over channel + uring eventfd + shutdown eventfd and post-dispatch TRY_RECV2 burst drain on 1011 kernels. |
| **Open-path refactor** | Active | ON | `fchdir+open` → `openat`; first step toward holding `global_lock` for less of the open path. |
| **Open-path lock-drop** | Active | ON | Release `global_lock` around `openat()` so audio thread requests are not blocked by slow file syscalls during drum-load. |
| **Hook tier 1+2 cache** | Active | ON | Server-side cache rebuild + client cache reader; 26.7k/26.7k cache hit on Ableton 165s, `server_dispatch=0`. |
| **CS-PI v2.3** | Active | ON when `NSPA_RT_PRIO` set | Recursive `pi_mutex` extension on top of vendored librtpi; LockSemaphore field repurposed. |
| **Condvar PI requeue** | Active | ON when `NSPA_RT_PRIO` set | `FUTEX_WAIT_REQUEUE_PI`; `RtlSleepConditionVariableCS` slow path. |
| **librtpi vendoring** | Active | n/a | Header-only `rtpi.h` forwarder into the vendored library copy. |
| **NT-local file and sections** (`nspa_local_file` + local sections) | Active | ON | `NtCreateFile` bypass for bounded regular-file and explicit-directory opens, selected downstream metadata / flush / EOF paths, and client-side unnamed file-backed sections on top of local-file handles. |
| **Client scheduler** (`wine-sched` / `wine-sched-rt`) | Active | ON | spawn-main + `ntdll_sched` substrate; default-class host plus lazy RT-class host, used by the close queue and eligible timer consumers without a separate public A/B gate. |
| **NT-local event** | Active | ON | anonymous `NtCreateEvent` routes to client-range handles by default, with server-side fd registration so async completion still signals correctly across wineserver-managed paths. |
| **NT-local timer** (`nspa_local_timer`) | Active | ON | anonymous NT timers use client-range backing events by default and, when RT is available, dispatch on the shared `wine-sched-rt` host. |
| **NT-local WM timer** (`nspa_local_wm_timer`) | Active | ON | `SetTimer` userspace path; `TIMERPROC` + cross-thread cases defer to the server, while eligible local dispatch shares the RT sched host instead of owning its own helper thread. |
| **Async local-file close queue** | Active | ON with sched enabled | eligible fully-shareable local-file closes defer unix `close()` + server `close_handle` onto `wine-sched`, removing close-path latency from the caller thread. |
| **msg-ring v1 (POST/SEND/REPLY)** | Active | ON | Bounded mpmc shmem ring for `PostMessage` / `SendMessage` / reply between Wine threads in the same process. |
| **msg-ring paint cache** | Active | ON | Cross-process redraw cache for `WM_PAINT` on top of the msg-ring publication path. |
| **`get_message` empty-poll cache** | Active | ON | per-thread 8-entry TLS cache keyed by full filter + `queue_shm->nspa_change_seq`; repeats a known empty poll locally instead of issuing the same `get_message` RPC again. |
| **Thread / process shared-state bypass** | Active | ON | server-published shared-object snapshots answer 7 thread query classes, 6 process query classes, and the zero-time process and thread wait polls without a wineserver RTT on a hit. |
| **Memory and large pages** | Active | ON where supported | local sections, `GetLargePageMinimum`, `VirtualAlloc(MEM_LARGE_PAGES)`, `CreateFileMapping(SEC_LARGE_PAGES)`, current-process `QueryWorkingSetEx`, working-set quota bookkeeping, and RT-keyed `mlockall()` / hugetlb follow-ons are live. |
| **`io_uring` file I/O bypass** | Active | ON when `NSPA_RT_PRIO` set | sync poll replacement plus async `NtReadFile` / `NtWriteFile` bypass on the PE side. |
| **Aggregate-wait dispatcher** | Active | ON | Per-process server-side `io_uring` infrastructure plus aggregate-wait dispatcher loop. Same RT thread receives requests, drains CQEs, and signals replies. |
| **Async `CreateFile`** | Active | ON | `CreateFile` routes through the dispatcher-owned ring and removes the `open()` lock-drop critical section from the audio xrun path. |
| **`io_uring` socket recv/send** | Active | ON | `NSPA_URING_RECV=1` and `NSPA_URING_SEND=1`; deferred `socket-io` path uses true socket SQEs instead of only poll-then-syscall. |
| **Wineserver `global_lock` PI** | Active | ON when `NSPA_RT_PRIO` set | `pthread_mutex` → `pi_mutex` on `global_lock`; CFS holders boost via PI chain when the boosted dispatcher contends. |
| **vDSO preloader (Jinoh Kang port)** | Active | ON | Full port minus the EHDR-unmap piece intentionally omitted on static-pie x86_64. |
| **NSPA priority mapping** | Active | ON when `NSPA_RT_PRIO` set | `fifo_prio = nspa_rt_prio_base - (31 - nt_band)`, clamped `[1..98]`; TIME_CRITICAL pinned to ceiling. |

### 3.3 Audio stack

| Component | Status | Brief |
|---|---|---|
| `winejack.drv` | Shipped | JACK-backed MIDI plus WASAPI audio in one driver |
| `nspaASIO` low-latency path | Shipped | Zero-latency `bufferSwitch` invoked **inside** the JACK RT callback — same-period output, no double-buffering hop |
| Native `winealsa`/`winepulse`/`wineoss` | Drop planned | Once winejack is fully stable; not removed yet |

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 500" xmlns="http://www.w3.org/2000/svg">
  <style>
    .cs-bg { fill: #1a1b26; }
    .cs-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 8; }
    .cs-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .cs-gate { fill: #2a1f14; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .cs-wip { fill: #1f2535; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .cs-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .cs-small { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .cs-title { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cs-tag-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cs-tag-yellow { fill: #e0af68; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cs-tag-violet { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cs-line { stroke: #9ece6a; stroke-width: 1.3; }
  </style>

  <rect x="0" y="0" width="940" height="500" class="cs-bg"/>
  <text x="470" y="28" text-anchor="middle" class="cs-title">2026-05-09 deployment board: active state, diagnostics, and remaining work</text>

  <rect x="50" y="70" width="250" height="150" class="cs-green"/>
  <text x="175" y="96" text-anchor="middle" class="cs-tag-green">Kernel / sync substrate</text>
  <text x="175" y="122" text-anchor="middle" class="cs-label">NTSync PI + dispatcher kernel surfaces</text>
  <text x="175" y="140" text-anchor="middle" class="cs-small">PI waits, channel transport, aggregate-wait, cache-isolated waits</text>
  <text x="175" y="164" text-anchor="middle" class="cs-label">CS-PI + condvar PI</text>
  <text x="175" y="182" text-anchor="middle" class="cs-small">all RT paths gate on NSPA_RT_PRIO</text>

  <rect x="345" y="70" width="250" height="150" class="cs-green"/>
  <text x="470" y="96" text-anchor="middle" class="cs-tag-green">Client-side bypasses</text>
  <text x="470" y="122" text-anchor="middle" class="cs-label">gamma + spawn-main + local events</text>
  <text x="470" y="140" text-anchor="middle" class="cs-small">local-file, local sections, sched-hosted timers, hook cache, msg-ring v1</text>
  <text x="470" y="164" text-anchor="middle" class="cs-label">shared-state readers + socket uring + RT memory</text>
  <text x="470" y="182" text-anchor="middle" class="cs-small">message empty polls, shared-state queries, and hot VM paths stay local more often</text>

  <rect x="640" y="70" width="250" height="150" class="cs-green"/>
  <text x="765" y="96" text-anchor="middle" class="cs-tag-green">Audio stack</text>
  <text x="765" y="122" text-anchor="middle" class="cs-label">winejack.drv</text>
  <text x="765" y="140" text-anchor="middle" class="cs-small">MIDI + WASAPI on JACK</text>
  <text x="765" y="164" text-anchor="middle" class="cs-label">nspaASIO low-latency path</text>
  <text x="765" y="182" text-anchor="middle" class="cs-small">bufferSwitch in JACK RT callback</text>

  <rect x="50" y="270" width="250" height="140" class="cs-gate"/>
  <text x="175" y="296" text-anchor="middle" class="cs-tag-yellow">Diagnostics / A-B</text>
  <text x="175" y="322" text-anchor="middle" class="cs-label">force older paths for comparison</text>
  <text x="175" y="338" text-anchor="middle" class="cs-small">remaining A/B toggles cover sched routing, socket uring,</text>
  <text x="175" y="352" text-anchor="middle" class="cs-small">flush throttle, and poll vs epoll</text>
  <text x="175" y="364" text-anchor="middle" class="cs-label">runtime measurement toggles</text>
  <text x="175" y="382" text-anchor="middle" class="cs-small">kept for validation and regression isolation, not as the default path</text>

  <rect x="345" y="270" width="250" height="140" class="cs-green"/>
  <text x="470" y="296" text-anchor="middle" class="cs-tag-green">2026-05-06 to 2026-05-09 follow-ons</text>
  <text x="470" y="322" text-anchor="middle" class="cs-label">thread/process shared-state bypass</text>
  <text x="470" y="340" text-anchor="middle" class="cs-small">query RTTs and zero-time process/thread waits hit shared snapshots first</text>
  <text x="470" y="364" text-anchor="middle" class="cs-label">message-pump + hot-path + hugetlb safety</text>
  <text x="470" y="382" text-anchor="middle" class="cs-small">empty get_message polls, TEB hot state, and hugetlb edge cases</text>
  <text x="470" y="396" text-anchor="middle" class="cs-small">stay local more often</text>

  <rect x="640" y="270" width="250" height="140" class="cs-wip"/>
  <text x="765" y="296" text-anchor="middle" class="cs-tag-violet">Longer horizon</text>
  <text x="765" y="322" text-anchor="middle" class="cs-label">wineserver decomposition remainder</text>
  <text x="765" y="340" text-anchor="middle" class="cs-small">timer split + FD polling split around aggregate-wait</text>
  <text x="765" y="364" text-anchor="middle" class="cs-label">residual server split</text>
  <text x="765" y="382" text-anchor="middle" class="cs-small">router / handler split plus lock partitioning</text>

  <line x1="175" y1="220" x2="175" y2="270" class="cs-line"/>
  <line x1="470" y1="220" x2="470" y2="270" class="cs-line"/>
  <line x1="765" y1="220" x2="765" y2="270" class="cs-line"/>
  <text x="470" y="456" text-anchor="middle" class="cs-small">top row = active state; bottom row = diagnostics and remaining architecture work</text>
</svg>
</div>

---

## 4. Validation and performance

### 4.1 Full-suite baseline still in force

- current ntsync overlay against kernel `6.19.11-rt1-1-nspa`,
  with the public full-suite boundary still anchored to the earlier
  `3 PASS / 0 FAIL` native + `24 PASS / 0 FAIL / 0 TIMEOUT`
  PE matrix totals.
- Native suite: **3 PASS / 0 FAIL** (`test-event-set-pi`,
  `test-channel-recv-exclusive`, `test-aggregate-wait`).
- `test-aggregate-wait`: **9/9 PASS**, including kitchen-sink
  `86,528 wakes / 0 timeouts / 0 errors`.
- `nspa_rt_test` PE matrix: **24 PASS / 0 FAIL / 0 TIMEOUT** (baseline + RT).
- `dispatcher-burst` remains the PE-side harness that exercises the gamma hot
  path directly.

The 2026-05-02 through 2026-05-09 work did not publish a new full-suite
version. What it added was targeted validation for the newly-landed scheduler,
timer, event, socket, local-file, local-section, shared-state, msg-ring,
ntsync-hardening, RT memory, and hot-path optimization surfaces.

### 4.2 Targeted 2026-05-02 through 2026-05-09 validation

| Surface | Validation | Result |
|---|---|---|
| spawn-main + sched base | Smoke 0 / 1 / 2 / 3 | PASS |
| spawn-main steady-state | Ableton playback | wineserver observed at `0.0%` CPU during playback |
| sched-RT migrations | `run-rt-probe-validation.sh` | `10/10 PASS` |
| sched-RT migrations | Smoke 0 / 1 | PASS |
| sched-RT migrations | Ableton boot + library + project load + playback | PASS |
| sched-RT migrations | runtime shape | net `-1` thread per process vs pre-migration layout |
| timer backing-event flip | smoke + RT probe + playback | clean; `63` threads stable, no sync / handle / timer errors |
| local events default-ON | Ableton boot + library + project load + `30s+` playback | clean |
| socket RECVMSG / SENDMSG default-ON | `socket-io` deferred path | `+6.5%` throughput, `-6.8%` p99 latency, `0/2000` failures |
| socket RECVMSG / SENDMSG default-ON | Ableton boot + library + playback | clean; `63` threads, zero new errors vs the earlier socket baseline |
| local sections default-ON | DirectWrite-style `CreateFile -> CreateFileMapping -> CloseHandle(file) -> MapViewOfFile` | clean; no EBADF / mapping failures |
| widened local-file path | workload comparison | `create_file` count `7,845` -> `5,658`, handler time `137 ms` -> `50 ms` |
| thread / process shared-state readers | A/B harness + smoke validation | clean; 7 thread classes and 6 process classes are active, with `ThreadBasicInformation` intentionally retained on RPC |
| zero-time process wait fast path | synthetic poll harness | ioctl path `~10000 ns/poll`; shared-state path `~144 ns/poll` |
| zero-time thread wait fast path | synthetic poll harness | ioctl path `~11940 ns/poll`; shared-state path `~164 ns/poll` |
| `get_message` empty-poll cache | Ableton 60 s playback | `get_message` `3,880 -> 866`; `get_message` time `16.5 ms -> 2.2 ms`; total handler time `46.8 ms -> 36.9 ms` |
| x86_64 TEB-relative hot state | 30 s Ableton playback counters | `NtCurrentTeb` calls `9,961,441 -> 566`; cumulative CPU cycles after the two TEB carries `257.8B -> 212.4B` |
| `inproc_sync` cacheline isolation | 30 s Ableton playback counters | distributed hot-symbol drops after eliminating false sharing on refcount `LOCK` ops; cache capacity restored to `524288` handles |
| RT-keyed `mlockall()` | targeted shell harness | `test-mlock-ws.sh 4/4 PASS`; `VmLck` `301,884 kB` on-gate vs `28 kB` off-gate |
| RT-keyed automatic hugetlb promotion | targeted shell harness | `test-huge-auto.sh 3/3 PASS` |
| RT-keyed heap arena hugetlb backing | targeted shell harness | `test-heap-hugepage.sh 3/3 PASS`; hugepage regions `1` on-gate vs `0` off-gate |
| hugetlb demote / RWX regressions | targeted shell harness | `test-huge-decommit.sh` and `test-huge-rwx.sh` clean on the active path |

### 4.3 Headline performance

#### Dispatcher tuning under Ableton busy workload

| Symbol | Before | After | Delta |
|---|---:|---:|---:|
| `channel_dispatcher` | 14.51% | 0.70% | −13.81pp / −95% |
| `main_loop_epoll` | 7.24% | 2.68% | −4.56pp |
| `nspa_queue_bypass_shm` | 2.77% | absent | inlined into call sites |
| `req_get_update_region` | 4.92% | absent | gone from top symbols |
| `nspa_redraw_ring_drain` | 2.88% | absent | gone from top symbols |

System-wide samples: `38,588 -> 19,415` per 30s.

#### `dispatcher-burst` A/B

| Metric | TRY_RECV2 on | TRY_RECV2 off | Delta |
|---|---:|---:|---:|
| burst ops/sec (wall) | 841,765 | 555,567 | +34% / 1.5x |
| burst worst max ns | 23,014,325 | 31,843,082 | −28% |
| steady avg ns | 35,202 | 33,405 | flat (no burst) |

#### X11 flush follow-ons

| Symbol | Before | After | Delta |
|---|---:|---:|---:|
| `x11drv_surface_flush` throttle | 8.23% | 4.74% | −43% |
| `copy_rect_32` memmove | 4.38% | 2.49% | −43% |
| `x11drv_surface_flush` AVX2 | 6.72% | 2.39% | −4.33pp / −64% |
| total `winex11.so` AVX2 | 6.76% | 2.43% | −4.33pp |
| total kernel after AVX2 | 10.22% | 8.58% | −1.64pp |

#### 2026-05-02 through 2026-05-10 feature-specific wins

| Feature | Result |
|---|---|
| local events default-ON | Ableton system CPU from the earlier event baseline `40-57%` to `~35%` during playback (`~15-20%` reduction) |
| socket RECVMSG / SENDMSG | `socket-io` deferred path `+6.5%` throughput, `-6.8%` p99 latency, `0/2000` failures |
| local sections | `nspa_create_mapping_from_unix_fd` count `2,664` -> `~800` (`-70%`); total wineserver handler time `1,991 ms` -> `1,077 ms` on the cleanest run |
| `get_message` empty-poll cache | `get_message` `3,880 -> 866` calls / 60 s (`-78%`); direct `get_message` handler time `16.5 ms -> 2.2 ms` (`-87%`); total handler time `46.8 ms -> 36.9 ms` (`-21%`) |
| zero-time process wait | process-handle poll loop `~10000 ns/poll` -> `~144 ns/poll` |
| zero-time thread wait | thread-handle poll loop `~11940 ns/poll` -> `~164 ns/poll` |
| x86_64 TEB hot state | cumulative playback CPU cycles `257.8B -> 212.4B` across inline `NtCurrentTeb()` plus msg-ring TEB-cache carries |
| x86_64 AVX2 string / Unicode loops | synthetic ASCII-path cuts range from `~4x` (`hash_strW`) to `~25x` (`utf8_mbstowcs`), while preserving scalar fallback for non-ASCII windows |
| local-file EOF path | direct handler-time saving `~8 ms / snapshot`, plus eligible `ftruncate()` no longer blocks the wineserver loop inline |
| RT-keyed heap arena hugetlb backing | hugepage regions `3/6` -> `104`; `mmap` rate `33-61/s` -> `0.13/s`; `mprotect` rate `56-90/s` -> `0.03/s`; page-faults `753-869/s` -> `2.8/s` |
| x86_64 AVX2 string / Unicode loops | ASCII-burst fast windows land in server name compare/hash and Unix-side UTF conversion helpers; non-ASCII and edge cases continue through the scalar path |

### 4.4 Residual caveats

- The last published full PE matrix is still the 2026-04-30 `24 PASS / 0 FAIL /
  0 TIMEOUT` run. The 2026-05-02 through 2026-05-09 features are covered by
  targeted validation, not a new full-suite publish yet.
- Local events default-ON still exposes a known cosmetic log line in some
  Ableton runs: `wined3d_cs_destroy` "Closing present event failed". It is not
  currently associated with a functional failure or resource leak.
- The LFH carries landed, but public validation is intentionally light so far:
  smoke level 0 + 1 only.

---

## 5. Open work, in priority order

1. **Longer paint-cache soak** — different day / cold start plus a
   longer runtime window so the default-on path has a cleaner public record.
2. **Full-suite rerun against the 2026-05-09 stack** — the last published
   matrix is still v8 / 2026-04-30; the new scheduler / event / socket surfaces
   deserve a fresh public matrix.
3. **Longer local-event, local-section, shared-state, and socket soak** — targeted validations are clean;
   hours-scale default-on runtime is still worth publishing.
4. **`wine_sechost_service` device-IRP poll** — still the next obvious
   high-frequency bypass candidate.
5. **Wineserver decomposition remainder** — aggregate-wait is already active;
   timer/fd-poll/router splits remain longer-horizon work.
6. **Wow64 clean rebuild** — 32-bit (i386) DLLs may be stale. Required for
   32-bit VST plugins and older games.

---

## 6. Recent landed arc (2026-04-30 to 2026-05-10)

| Date | Work | Public result |
|---|---|---|
| 2026-04-30 | flush throttle + async `CreateFile` + `TRY_RECV2` | dispatcher hot path and MainThread flush cost both dropped materially |
| 2026-05-01 | winex11 AVX2 flush follow-on + Tier 1 log hygiene | lower GUI flush cost, cleaner logs, no semantic drift |
| 2026-05-02 | spawn-main + `ntdll_sched` substrate | one default scheduler host per process, plus lazy RT-class host |
| 2026-05-02 | async local-file close queue | caller thread stops paying eligible close latency inline |
| 2026-05-02 | sched-hosted `local_timer` + `local_wm_timer` | RT timer work consolidated onto shared `wine-sched-rt` |
| 2026-05-02 | `NtCreateTimer` client-range backing event default ON | anonymous timer backing events stop using the temporary server helper path |
| 2026-05-02 | local events default ON | anonymous events move client-side while async completion remains server-correct |
| 2026-05-02 | socket RECVMSG / SENDMSG default ON | `socket-io` deferred path gets a real `io_uring` data path, not just poll interception |
| 2026-05-03 | widened local-file envelope | more regular-file, directory, metadata, flush, and EOF traffic stays client-side |
| 2026-05-03 | local sections default ON | eligible unnamed file-backed sections stay client-side for create / map / query / unmap / close |
| 2026-05-04 | ntsync hardening follow-ons | receive snapshot fix, dedicated slab caches, and lockless `SEND_PI` target scan land in the production kernel module |
| 2026-05-05 | ntsync wait-queue cache follow-on | dedicated `ntsync_wait_q` cache ships, and `SLAB_NO_MERGE` is applied across all four ntsync caches so cache isolation is real on the production kernel |
| 2026-05-05 | RT memory follow-ons | `mlockall()`, automatic hugetlb promotion, and heap-arena hugetlb backing ship under `NSPA_RT_PRIO` |
| 2026-05-06 | thread + process shared-state readers | 7 thread classes and 6 process classes serve from seqlock-published shared objects with RPC fallback |
| 2026-05-06 | zero-time process wait fast path | `WaitForSingleObject(process, 0)` can answer from `process_shm` instead of paying the wait ioctl on a hit |
| 2026-05-06 | `get_message` empty-poll cache | same-filter empty polls can return locally when `queue_shm->nspa_change_seq` has not advanced |
| 2026-05-06 | hugetlb safety follow-ons | auto-promoted views demote safely on partial ops, fall back cleanly under pool pressure, reclaim correctly on `MEM_RESET`, and include RWX JIT allocations when eligible |
| 2026-05-08 | zero-time thread wait fast path | `WaitForSingleObject(thread, 0)` can answer from `thread_shm` via the published termination flag |
| 2026-05-09 | x86_64 TEB hot-state carries | inline `NtCurrentTeb()` and msg-ring TEB-backed per-thread caches remove repeated thread-local helper overhead |
| 2026-05-09 | `inproc_sync` cache layout follow-ons | cacheline isolation lands on the userspace sync cache and the original `524288`-handle capacity is restored |
| 2026-05-10 | x86_64 AVX2 string / Unicode carries | server name compare/hash and Unix-side UTF conversion helpers vectorize ASCII windows while reusing the scalar path for mixed or non-ASCII windows |

---

## 7. Configuration reference

### 7.1 Active env vars

| Var | Effect |
|---|---|
| `NSPA_RT_PRIO=80` | Master gate. Sets RT priority ceiling, activates all four PI paths, enables the RT dispatcher shape, and turns on the RT-keyed memory follow-ons (`mlockall()`, automatic hugetlb promotion, heap arena hugetlb backing). When unset, the RT-specific paths stand down. |
| `NSPA_RT_POLICY=FF` | SCHED_FIFO (vs RR). Same-prio RR quantum-slices the audio thread; FIFO eliminates. |
| `NSPA_SCHED_OBS_INTERVAL_MS=N` | Opt-in sched observability sampler. Default OFF. Writes `/dev/shm/nspa-obs.<pid>` periodically. |
| `NSPA_FLUSH_THROTTLE_MS=8` | `flush_window_surfaces` throttle on `x11drv` MainThread. **Default ON at 8.** Set `N` to retune; `0` disables. |
| `NSPA_URING_RECV=1` | Socket RECVMSG `io_uring` path. **Default ON.** Set `0` to force the older recv path. |
| `NSPA_URING_SEND=1` | Socket SENDMSG `io_uring` path. **Default ON.** Set `0` to force the older send path. |
| `NSPA_DISABLE_EPOLL=1` | A/B PREEMPT_RT poll vs epoll on wineserver main loop. Default upstream (epoll). |
| `WINEPRELOADREMAPVDSO=force\|skip\|on-conflict` | vDSO preloader behaviour. Default `on-conflict`. |

### 7.2 RT priority mapping (with `NSPA_RT_PRIO=80`)

Formula: `fifo_prio = nspa_rt_prio_base - (31 - nt_band)`, clamped to `[1..98]`.

| Win32 label | Win32 value | NT band | FIFO priority |
|---|---|---|---|
| IDLE (realtime class) | -15 | 16 | 65 |
| LOWEST | -2 | 22 | 71 |
| BELOW_NORMAL | -1 | 23 | 72 |
| NORMAL | 0 | 24 | 73 |
| ABOVE_NORMAL | 1 | 25 | 74 |
| HIGHEST | 2 | 26 | 75 |
| **TIME_CRITICAL** | 15 | 31 | **80** |
| wineserver main | — | — | **64** (auto-derive = `NSPA_RT_PRIO - 16`) |

`NSPA_RT_PRIO` is the *ceiling*, not a midpoint. `TIME_CRITICAL` is
special-cased to NT band 31 and maps exactly to that ceiling. Standard
REALTIME-class priorities scale linearly below it.

---

## 8. Doc index

State boards and architecture deep-dives produced by the project:

| Doc | Subject |
|---|---|
| `current-state.md` | This document — state of the art on 2026-05-10 |
| `client-scheduler-architecture.gen.html` | spawn-main + `ntdll_sched`, default-class and RT-class scheduler hosts, and the consumers routed through them |
| `cs-pi.gen.html` | Critical Section Priority Inheritance (CS-PI v2.3) — twelve-section deep dive |
| `condvar-pi-requeue.gen.html` | `RtlSleepConditionVariableCS` `FUTEX_WAIT_REQUEUE_PI` slow path |
| `aggregate-wait-and-async-completion.gen.html` | Aggregate-wait plus same-thread async completion architecture |
| `gamma-channel-dispatcher.gen.html` | Gamma request/reply transport plus post-1010 aggregate-wait dispatcher loop |
| `thread-and-process-shared-state.gen.html` | server-published thread/process snapshots, query bypass coverage, and zero-time process/thread waits |
| `ntsync-pi-driver.gen.html` | NTSync PI kernel overlay: PI baseline, channel transport, aggregate-wait, and later kernel hardening |
| `ntsync-userspace.gen.html` | Wine in-process sync path: handle-to-fd cache, client-created sync objects, direct wait/signal helpers, and dispatcher-facing wrappers |
| `io_uring-architecture.gen.html` | `io_uring` integration for file I/O, async `CreateFile`, and socket RECVMSG / SENDMSG |
| `local-section-architecture.gen.html` | client-side file-backed sections built on top of local-file handles |
| `hot-path-optimizations.gen.html` | cross-cutting optimization choices: published-state caching, TEB-relative hot state, cache/slab layout, helper inlining, SIMD string/Unicode loops, and GUI flush trims |
| `msg-ring-architecture.gen.html` | msg-ring v1 + v2 design notes |
| `memory-and-large-pages.gen.html` | large pages, working-set reporting, working-set quota bookkeeping, and shared-memory backing choices |
| `nspa-local-file-architecture.gen.html` | NT-local file bypass (`NtCreateFile` short-circuit) |
| `nt-local-stubs.gen.html` | NT-local stub pattern, including local sections, local events, and sched-hosted timer dispatch |
| `shmem-ipc.gen.html` | NSPA shmem IPC primitives (γ + redraw + paint-cache) |
| `nspa-rt-test.gen.html` | nspa_rt_test PE harness reference |
| `architecture.gen.html` | Whole-system architecture overview |
| `decoration-loop-investigation.gen.html` | X11 windowing decoration-loop bug 57955 case study |
| `sync-primitives-research.gen.html` | Background research on sync primitive selection |

The architecture-heavy pieces added through 2026-05-10 are covered
in the public docs set, including the client scheduler, local events,
socket `io_uring`, gamma, aggregate-wait, hook cache, thread/process
shared-state readers, local-file, local sections, hot-path optimizations,
memory follow-ons, msg-ring, and the decomposition notes.

---

*Generated 2026-05-10. State board reflects the 2026-05-10 set on kernel `6.19.11-rt1-1-nspa`.*
