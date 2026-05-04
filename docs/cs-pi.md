# Wine-NSPA -- Critical Section Priority Inheritance (CS-PI)

This page is the design and implementation reference for Wine-NSPA's `RTL_CRITICAL_SECTION` priority-inheritance path, from lock acquisition mechanics down to fallback behavior and validation history.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Upstream Wine vs NSPA Comparison](#2-upstream-wine-vs-nspa-comparison)
3. [LockSemaphore Repurposing](#3-locksemaphore-repurposing)
4. [Fast Path (Uncontended)](#4-fast-path-uncontended)
5. [Slow Path (Contended)](#5-slow-path-contended)
6. [Release Path](#6-release-path)
7. [TID Source](#7-tid-source)
8. [Gating Mechanism](#8-gating-mechanism)
9. [Recursive Locking](#9-recursive-locking)
10. [Fallback Behavior](#10-fallback-behavior)
11. [SRW Lock Spin Phase](#11-srw-lock-spin-phase)
12. [Validation](#12-validation)

---

## 1. Overview

`RTL_CRITICAL_SECTION` is the most contended lock primitive in Wine. Every heap allocation, loader operation, DllMain serialization, GDI call, and most application/plugin code exercises critical sections. In a typical DAW workload running 50-100 VST plugins, thousands of CS acquire/release pairs happen per audio callback period (typically 2-5 ms at 48 kHz with a 128-sample buffer).

The core problem: **priority inversion**. When an RT audio thread (SCHED_FIFO, priority 80+) blocks on a critical section held by a normal-priority thread (SCHED_OTHER), the holder cannot run because the RT thread is monopolizing the CPU. Under CFS, the holder competes with dozens of other SCHED_OTHER threads for time slices. The RT thread's audio callback deadline passes. The result is an audible glitch -- an xrun.

Windows does not implement priority inheritance on `CRITICAL_SECTION`. Windows' NT scheduler has its own mechanisms for mitigating inversion (priority boosting on wakeup, quantum donation), but these are heuristic and non-deterministic. NSPA's CS-PI is novel: it grafts Linux's kernel `rt_mutex` PI protocol onto Wine's `RTL_CRITICAL_SECTION`, giving every CS acquire/release pair the same deterministic, transitive priority inheritance that POSIX `pthread_mutex` with `PTHREAD_PRIO_INHERIT` provides.

**Key properties of CS-PI:**

- **Transitive.** If thread A (FIFO 90) waits on CS1 held by thread B (FIFO 50), which waits on CS2 held by thread C (OTHER), thread C is boosted to FIFO 90. Chains of arbitrary depth are handled by the kernel's rt_mutex infrastructure.
- **Race-free.** The kernel manages the PI chain atomically. No user-space priority tracking, no TOCTOU windows.
- **Zero-cost when inactive.** When `NSPA_RT_PRIO` is unset, every CS function short-circuits to upstream Wine's legacy implementation. No CAS, no TID lookup, no branch misprediction penalty beyond the initial state check.
- **Graceful degradation.** If the kernel lacks `FUTEX_LOCK_PI` support (pre-2.6.18, effectively impossible in 2026), CS-PI permanently disables itself and falls through to the legacy keyed-event path.

### Source Files

| File | Content |
| --- | --- |
| `dlls/ntdll/sync.c` lines 149-495 | PE-side CS-PI: design comment, state machine, fast/slow/release paths |
| `dlls/ntdll/unix/sync.c` lines 144-168, 4057-4156 | Unix-side: futex helpers, `NtNspaGetUnixTid`, `NtNspaLockCriticalSectionPI`, `NtNspaUnlockCriticalSectionPI` |
| `dlls/ntdll/unix/unix_private.h` lines 150-181 | `nspa_unix_tid` field in `ntdll_thread_data`, C_ASSERT offset validation |

---

## 2. Upstream Wine vs NSPA Comparison

The following diagram shows the complete acquire and release flow for both upstream Wine and NSPA CS-PI, side by side. The left column is upstream Wine's legacy path; the right column is NSPA's PI-enabled path. Both start from the same `RtlEnterCriticalSection` entry point.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 920" xmlns="http://www.w3.org/2000/svg">
  <!-- Background -->
  <rect width="960" height="920" fill="#1a1b26" rx="6"/>

  <!-- Title -->
  <text x="480" y="30" text-anchor="middle" fill="#c0caf5" font-size="15" font-weight="bold">RTL_CRITICAL_SECTION: Upstream Wine vs NSPA CS-PI</text>

  <!-- Column headers -->
  <rect x="20" y="45" width="440" height="32" rx="6" fill="#24283b" stroke="#7dcfff" stroke-width="1.5"/>
  <text x="240" y="66" text-anchor="middle" fill="#c0caf5" font-size="12" font-weight="bold">UPSTREAM WINE (no PI)</text>

  <rect x="500" y="45" width="440" height="32" rx="6" fill="#24283b" stroke="#7dcfff" stroke-width="1.5"/>
  <text x="720" y="66" text-anchor="middle" fill="#7dcfff" font-size="12" font-weight="bold">NSPA CS-PI (FUTEX_LOCK_PI)</text>

  <!-- Divider -->
  <line x1="480" y1="45" x2="480" y2="900" stroke="#6b7398" stroke-width="1" stroke-dasharray="6,4"/>

  <!-- ============ UPSTREAM ACQUIRE ============ -->
  <!-- Entry -->
  <rect x="40" y="95" width="400" height="28" rx="6" fill="#24283b" stroke="#bb9af7" stroke-width="1"/>
  <text x="240" y="114" text-anchor="middle" fill="#bb9af7" font-size="10">RtlEnterCriticalSection(&amp;cs)</text>

  <line x1="240" y1="123" x2="240" y2="143" stroke="#9ece6a" stroke-width="1.5"/>

  <!-- Spin phase -->
  <rect x="40" y="143" width="400" height="28" rx="6" fill="#24283b" stroke="#e0af68" stroke-width="1"/>
  <text x="240" y="162" text-anchor="middle" fill="#e0af68" font-size="10">if (SpinCount) spin up to N iterations</text>

  <line x1="240" y1="171" x2="240" y2="191" stroke="#9ece6a" stroke-width="1.5"/>

  <!-- LockCount atomic -->
  <rect x="40" y="191" width="400" height="38" rx="6" fill="#24283b" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="240" y="208" text-anchor="middle" fill="#9ece6a" font-size="10" font-weight="bold">InterlockedIncrement(&amp;LockCount)</text>
  <text x="240" y="222" text-anchor="middle" fill="#c0caf5" font-size="9">-1 to 0 = won lock | &gt;= 0 = contended</text>

  <!-- Fork: uncontended vs contended -->
  <line x1="140" y1="229" x2="140" y2="252" stroke="#9ece6a" stroke-width="1.5"/>
  <line x1="340" y1="229" x2="340" y2="252" stroke="#f7768e" stroke-width="1.5"/>

  <!-- Uncontended -->
  <rect x="40" y="252" width="180" height="48" rx="6" fill="#1a3a1a" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="130" y="270" text-anchor="middle" fill="#9ece6a" font-size="9" font-weight="bold">UNCONTENDED</text>
  <text x="130" y="284" text-anchor="middle" fill="#c0caf5" font-size="8">Set OwningThread, RecursionCount</text>
  <text x="130" y="295" text-anchor="middle" fill="#c0caf5" font-size="8">Done -- pure userspace</text>

  <!-- Contended -->
  <rect x="240" y="252" width="200" height="48" rx="6" fill="#3a1a1a" stroke="#f7768e" stroke-width="1.5"/>
  <text x="340" y="270" text-anchor="middle" fill="#f7768e" font-size="9" font-weight="bold">CONTENDED</text>
  <text x="340" y="284" text-anchor="middle" fill="#c0caf5" font-size="8">RtlpWaitForCriticalSection()</text>
  <text x="340" y="295" text-anchor="middle" fill="#c0caf5" font-size="8">Keyed event wait (NtWaitForKeyedEvent)</text>

  <line x1="340" y1="300" x2="340" y2="320" stroke="#f7768e" stroke-width="1.5"/>

  <!-- Keyed event -->
  <rect x="240" y="320" width="200" height="55" rx="6" fill="#24283b" stroke="#f7768e" stroke-width="2"/>
  <text x="340" y="338" text-anchor="middle" fill="#f7768e" font-size="9" font-weight="bold">Keyed Event Wait</text>
  <text x="340" y="353" text-anchor="middle" fill="#c0caf5" font-size="8">NtWaitForKeyedEvent(LockSemaphore)</text>
  <text x="340" y="366" text-anchor="middle" fill="#ff9e64" font-size="8">NO PRIORITY INHERITANCE</text>

  <!-- Upstream release -->
  <text x="240" y="400" text-anchor="middle" fill="#c0caf5" font-size="11" font-weight="bold">--- Release ---</text>

  <rect x="40" y="412" width="400" height="28" rx="6" fill="#24283b" stroke="#bb9af7" stroke-width="1"/>
  <text x="240" y="431" text-anchor="middle" fill="#bb9af7" font-size="10">RtlLeaveCriticalSection(&amp;cs)</text>

  <line x1="240" y1="440" x2="240" y2="460" stroke="#9ece6a" stroke-width="1.5"/>

  <rect x="40" y="460" width="400" height="38" rx="6" fill="#24283b" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="240" y="477" text-anchor="middle" fill="#9ece6a" font-size="10">InterlockedDecrement(&amp;LockCount)</text>
  <text x="240" y="491" text-anchor="middle" fill="#c0caf5" font-size="9">&lt; 0 = no waiters | &gt;= 0 = wake one</text>

  <line x1="340" y1="498" x2="340" y2="518" stroke="#f7768e" stroke-width="1.5"/>

  <rect x="240" y="518" width="200" height="35" rx="6" fill="#3a1a1a" stroke="#f7768e" stroke-width="1"/>
  <text x="340" y="533" text-anchor="middle" fill="#f7768e" font-size="8">RtlpUnWaitCriticalSection()</text>
  <text x="340" y="546" text-anchor="middle" fill="#c0caf5" font-size="8">NtReleaseKeyedEvent -- FIFO wakeup</text>

  <!-- Upstream problem box -->
  <rect x="40" y="570" width="400" height="68" rx="6" fill="#2a1520" stroke="#f7768e" stroke-width="2"/>
  <text x="240" y="590" text-anchor="middle" fill="#f7768e" font-size="11" font-weight="bold">PROBLEM: Priority Inversion</text>
  <text x="240" y="607" text-anchor="middle" fill="#c0caf5" font-size="9">RT thread blocked on keyed event. Holder at SCHED_OTHER.</text>
  <text x="240" y="622" text-anchor="middle" fill="#ff9e64" font-size="9">Kernel has no knowledge of lock ownership. No boost possible.</text>
  <text x="240" y="635" text-anchor="middle" fill="#c0caf5" font-size="8">Result: unbounded inversion, audio xruns</text>

  <!-- ============ NSPA ACQUIRE ============ -->
  <!-- Entry -->
  <rect x="520" y="95" width="400" height="28" rx="6" fill="#24283b" stroke="#bb9af7" stroke-width="1"/>
  <text x="720" y="114" text-anchor="middle" fill="#bb9af7" font-size="10">RtlEnterCriticalSection(&amp;cs)</text>

  <line x1="720" y1="123" x2="720" y2="143" stroke="#9ece6a" stroke-width="1.5"/>

  <!-- PI gate check -->
  <rect x="520" y="143" width="400" height="28" rx="6" fill="#24283b" stroke="#7dcfff" stroke-width="1"/>
  <text x="720" y="162" text-anchor="middle" fill="#7dcfff" font-size="10">nspa_cs_pi_active() -- check NSPA_RT_PRIO</text>

  <line x1="720" y1="171" x2="720" y2="191" stroke="#9ece6a" stroke-width="1.5"/>

  <!-- Fast path CAS -->
  <rect x="520" y="191" width="400" height="48" rx="6" fill="#1a3a1a" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="720" y="208" text-anchor="middle" fill="#9ece6a" font-size="10" font-weight="bold">FAST PATH: CAS(LockSemaphore, 0, my_tid)</text>
  <text x="720" y="222" text-anchor="middle" fill="#c0caf5" font-size="9">InterlockedCompareExchange -- single atomic op</text>
  <text x="720" y="234" text-anchor="middle" fill="#c0caf5" font-size="8">+5ns overhead vs upstream | never leaves userspace</text>

  <!-- Fork: won vs contended -->
  <line x1="620" y1="239" x2="620" y2="262" stroke="#9ece6a" stroke-width="1.5"/>
  <line x1="820" y1="239" x2="820" y2="262" stroke="#f7768e" stroke-width="1.5"/>

  <!-- Won -->
  <rect x="520" y="262" width="180" height="38" rx="6" fill="#1a3a1a" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="610" y="278" text-anchor="middle" fill="#9ece6a" font-size="9" font-weight="bold">WON (CAS returned 0)</text>
  <text x="610" y="293" text-anchor="middle" fill="#c0caf5" font-size="8">Set OwningThread, RecursionCount=1</text>

  <!-- Contended: spin then syscall -->
  <rect x="720" y="262" width="200" height="38" rx="6" fill="#24283b" stroke="#e0af68" stroke-width="1"/>
  <text x="820" y="278" text-anchor="middle" fill="#e0af68" font-size="9">CONTENDED (CAS failed)</text>
  <text x="820" y="293" text-anchor="middle" fill="#c0caf5" font-size="8">Optional spin (SpinCount iters)</text>

  <line x1="820" y1="300" x2="820" y2="320" stroke="#f7768e" stroke-width="1.5"/>

  <!-- Syscall crossing -->
  <rect x="620" y="320" width="300" height="28" rx="6" fill="#24283b" stroke="#7dcfff" stroke-width="1.5"/>
  <text x="770" y="339" text-anchor="middle" fill="#7dcfff" font-size="10">NtNspaLockCriticalSectionPI(futex)</text>

  <line x1="770" y1="348" x2="770" y2="368" stroke="#7dcfff" stroke-width="1.5"/>

  <!-- PE/Unix boundary -->
  <line x1="520" y1="368" x2="920" y2="368" stroke="#e0af68" stroke-width="1" stroke-dasharray="4,3"/>
  <text x="920" y="365" text-anchor="end" fill="#e0af68" font-size="8">PE / Unix boundary</text>

  <line x1="770" y1="368" x2="770" y2="388" stroke="#7dcfff" stroke-width="1.5"/>

  <!-- futex_lock_pi -->
  <rect x="620" y="388" width="300" height="28" rx="6" fill="#24283b" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="770" y="407" text-anchor="middle" fill="#9ece6a" font-size="10">futex(addr, FUTEX_LOCK_PI_PRIVATE, ...)</text>

  <line x1="770" y1="416" x2="770" y2="436" stroke="#7dcfff" stroke-width="1.5"/>

  <!-- Kernel / userspace boundary -->
  <line x1="520" y1="436" x2="920" y2="436" stroke="#ff9e64" stroke-width="1" stroke-dasharray="4,3"/>
  <text x="920" y="433" text-anchor="end" fill="#ff9e64" font-size="8">userspace / kernel boundary</text>

  <line x1="770" y1="436" x2="770" y2="456" stroke="#7dcfff" stroke-width="1.5"/>

  <!-- Kernel rt_mutex -->
  <rect x="560" y="456" width="360" height="65" rx="6" fill="#24283b" stroke="#7dcfff" stroke-width="2"/>
  <text x="740" y="475" text-anchor="middle" fill="#7dcfff" font-size="10" font-weight="bold">Kernel rt_mutex PI Chain</text>
  <text x="740" y="492" text-anchor="middle" fill="#9ece6a" font-size="9">1. Read owner TID from futex word</text>
  <text x="740" y="506" text-anchor="middle" fill="#9ece6a" font-size="9">2. Boost owner to waiter's priority</text>
  <text x="740" y="518" text-anchor="middle" fill="#c0caf5" font-size="8">Transitive: chains propagated through nested locks</text>

  <!-- NSPA release -->
  <text x="720" y="548" text-anchor="middle" fill="#c0caf5" font-size="11" font-weight="bold">--- Release ---</text>

  <rect x="520" y="560" width="400" height="28" rx="6" fill="#24283b" stroke="#bb9af7" stroke-width="1"/>
  <text x="720" y="579" text-anchor="middle" fill="#bb9af7" font-size="10">RtlLeaveCriticalSection(&amp;cs) -- nspa_cs_leave_pi()</text>

  <line x1="620" y1="588" x2="620" y2="610" stroke="#9ece6a" stroke-width="1.5"/>
  <line x1="820" y1="588" x2="820" y2="610" stroke="#f7768e" stroke-width="1.5"/>

  <!-- Uncontended release -->
  <rect x="520" y="610" width="180" height="48" rx="6" fill="#1a3a1a" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="610" y="627" text-anchor="middle" fill="#9ece6a" font-size="9" font-weight="bold">NO WAITERS</text>
  <text x="610" y="641" text-anchor="middle" fill="#c0caf5" font-size="8">CAS(LockSemaphore, tid, 0)</text>
  <text x="610" y="653" text-anchor="middle" fill="#c0caf5" font-size="8">Pure userspace -- no syscall</text>

  <!-- Contended release -->
  <rect x="720" y="610" width="200" height="48" rx="6" fill="#3a1a1a" stroke="#f7768e" stroke-width="1.5"/>
  <text x="820" y="627" text-anchor="middle" fill="#f7768e" font-size="9" font-weight="bold">FUTEX_WAITERS SET</text>
  <text x="820" y="641" text-anchor="middle" fill="#c0caf5" font-size="8">NtNspaUnlockCriticalSectionPI()</text>
  <text x="820" y="653" text-anchor="middle" fill="#c0caf5" font-size="8">Kernel hands off to highest-pri waiter</text>

  <!-- NSPA solution box -->
  <rect x="520" y="678" width="400" height="68" rx="6" fill="#152a1a" stroke="#9ece6a" stroke-width="2"/>
  <text x="720" y="698" text-anchor="middle" fill="#9ece6a" font-size="11" font-weight="bold">SOLUTION: Kernel PI Chain</text>
  <text x="720" y="715" text-anchor="middle" fill="#c0caf5" font-size="9">Holder boosted to RT waiter's scheduling priority.</text>
  <text x="720" y="730" text-anchor="middle" fill="#c0caf5" font-size="9">Kernel sees ownership via futex word TID. Boost is instant.</text>
  <text x="720" y="743" text-anchor="middle" fill="#9ece6a" font-size="8">Result: bounded inversion, deterministic audio</text>

  <!-- Comparison table at bottom -->
  <rect x="40" y="770" width="880" height="130" rx="6" fill="#24283b" stroke="#3b4261" stroke-width="1"/>
  <text x="480" y="792" text-anchor="middle" fill="#7aa2f7" font-size="12" font-weight="bold">Comparison Summary</text>

  <!-- Headers -->
  <text x="60" y="815" fill="#c0caf5" font-size="9" font-weight="bold">Property</text>
  <text x="340" y="815" text-anchor="middle" fill="#c0caf5" font-size="9" font-weight="bold">Upstream Wine</text>
  <text x="700" y="815" text-anchor="middle" fill="#7dcfff" font-size="9" font-weight="bold">NSPA CS-PI</text>

  <line x1="60" y1="822" x2="900" y2="822" stroke="#3b4261" stroke-width="0.5"/>

  <text x="60" y="838" fill="#c0caf5" font-size="9">Wait mechanism</text>
  <text x="340" y="838" text-anchor="middle" fill="#c0caf5" font-size="9">Keyed event (NtWaitForKeyedEvent)</text>
  <text x="700" y="838" text-anchor="middle" fill="#9ece6a" font-size="9">FUTEX_LOCK_PI (kernel rt_mutex)</text>

  <text x="60" y="855" fill="#c0caf5" font-size="9">Priority inheritance</text>
  <text x="340" y="855" text-anchor="middle" fill="#f7768e" font-size="9">None</text>
  <text x="700" y="855" text-anchor="middle" fill="#9ece6a" font-size="9">Full transitive PI via kernel</text>

  <text x="60" y="872" fill="#c0caf5" font-size="9">Ownership tracking</text>
  <text x="340" y="872" text-anchor="middle" fill="#c0caf5" font-size="9">OwningThread (Win32 TID only)</text>
  <text x="700" y="872" text-anchor="middle" fill="#9ece6a" font-size="9">Futex word (Linux TID) + OwningThread</text>

  <text x="60" y="889" fill="#c0caf5" font-size="9">Uncontended cost</text>
  <text x="340" y="889" text-anchor="middle" fill="#c0caf5" font-size="9">1 atomic (InterlockedIncrement)</text>
  <text x="700" y="889" text-anchor="middle" fill="#c0caf5" font-size="9">1 atomic + 1 CAS (~5ns overhead)</text>
</svg>
</div>

---

## 3. LockSemaphore Repurposing

`RTL_CRITICAL_SECTION` has a `LockSemaphore` field typed as `HANDLE` (i.e., `PVOID` -- pointer-sized). In upstream Wine, this stores a handle to a keyed event object, lazily created on first contention. The keyed event is used as the park/unpark mechanism: contended acquires call `NtWaitForKeyedEvent(LockSemaphore)`, and releases with waiters call `NtReleaseKeyedEvent(LockSemaphore)`.

Under CS-PI, `LockSemaphore` is repurposed as a **FUTEX_LOCK_PI word**. The field is still pointer-sized, but only the low 32 bits are used, matching the `LONG` that `FUTEX_LOCK_PI` operates on. The bit layout follows the kernel's `futex.h` protocol exactly:

<div class="diagram-container">
<svg width="100%" viewBox="0 0 780 260" xmlns="http://www.w3.org/2000/svg">
  <rect width="780" height="260" fill="#1a1b26" rx="6"/>

  <text x="390" y="25" text-anchor="middle" fill="#c0caf5" font-size="13" font-weight="bold">LockSemaphore as FUTEX_LOCK_PI Word (32-bit layout)</text>

  <text x="60" y="50" text-anchor="middle" fill="#c0caf5" font-size="9">bit 31</text>
  <text x="130" y="50" text-anchor="middle" fill="#c0caf5" font-size="9">bit 30</text>
  <text x="450" y="50" text-anchor="middle" fill="#c0caf5" font-size="9">bits 29..0</text>

  <rect x="30" y="58" width="60" height="40" rx="6" fill="#24283b" stroke="#f7768e" stroke-width="2"/>
  <text x="60" y="83" text-anchor="middle" fill="#f7768e" font-size="11" font-weight="bold">W</text>

  <rect x="100" y="58" width="60" height="40" rx="6" fill="#24283b" stroke="#e0af68" stroke-width="2"/>
  <text x="130" y="83" text-anchor="middle" fill="#e0af68" font-size="11" font-weight="bold">D</text>

  <rect x="170" y="58" width="570" height="40" rx="6" fill="#24283b" stroke="#9ece6a" stroke-width="2"/>
  <text x="455" y="83" text-anchor="middle" fill="#9ece6a" font-size="11" font-weight="bold">Owner TID (Linux kernel TID, 30 bits)</text>

  <!-- FUTEX_WAITERS label (left-aligned) -->
  <line x1="60" y1="98" x2="60" y2="118" stroke="#7dcfff" stroke-width="1"/>
  <text x="60" y="133" text-anchor="middle" fill="#f7768e" font-size="9" font-weight="bold">FUTEX_WAITERS</text>
  <text x="60" y="146" text-anchor="middle" fill="#c0caf5" font-size="8">0x80000000</text>
  <text x="60" y="159" text-anchor="middle" fill="#c0caf5" font-size="8">Set by kernel when</text>
  <text x="60" y="170" text-anchor="middle" fill="#c0caf5" font-size="8">threads are blocked</text>

  <!-- FUTEX_OWNER_DIED label (shifted right ~40px from D box center) -->
  <line x1="130" y1="98" x2="170" y2="118" stroke="#7dcfff" stroke-width="1"/>
  <text x="170" y="133" text-anchor="middle" fill="#e0af68" font-size="9" font-weight="bold">FUTEX_OWNER_DIED</text>
  <text x="170" y="146" text-anchor="middle" fill="#c0caf5" font-size="8">0x40000000</text>
  <text x="170" y="159" text-anchor="middle" fill="#c0caf5" font-size="8">Set if owner exited</text>
  <text x="170" y="170" text-anchor="middle" fill="#c0caf5" font-size="8">without releasing</text>

  <!-- TID_MASK label -->
  <line x1="455" y1="98" x2="455" y2="118" stroke="#7dcfff" stroke-width="1"/>
  <text x="455" y="133" text-anchor="middle" fill="#9ece6a" font-size="9" font-weight="bold">TID_MASK = 0x3FFFFFFF</text>
  <text x="455" y="146" text-anchor="middle" fill="#c0caf5" font-size="8">Linux kernel TID of current lock owner</text>
  <text x="455" y="159" text-anchor="middle" fill="#c0caf5" font-size="8">Validated by kernel against /proc/&lt;tid&gt;</text>
  <text x="455" y="170" text-anchor="middle" fill="#c0caf5" font-size="8">0 = lock is free (no owner)</text>

  <rect x="30" y="190" width="720" height="55" rx="6" fill="#24283b" stroke="#3b4261" stroke-width="1"/>
  <text x="40" y="210" fill="#7aa2f7" font-size="10" font-weight="bold">PE-side constants (dlls/ntdll/sync.c):</text>
  <text x="40" y="228" fill="#9ece6a" font-size="10" font-family="monospace">#define NSPA_CS_FUTEX_WAITERS  0x80000000U</text>
  <text x="430" y="228" fill="#9ece6a" font-size="10" font-family="monospace">#define NSPA_CS_FUTEX_TID_MASK 0x3fffffffU</text>
</svg>
</div>

**Why this works without breaking the struct layout:**

- `RTL_CRITICAL_SECTION` layout is ABI-frozen. `LockSemaphore` is at a fixed offset. Applications that `sizeof(RTL_CRITICAL_SECTION)` are unaffected.
- The field is `HANDLE`-sized (`PVOID`), which is 8 bytes on x86_64 and 4 bytes on i386. The futex word uses only the low 32 bits. On x86_64, the upper 32 bits are implicitly zero (the field is cast to `LONG *`).
- Applications that inspect `LockSemaphore` expecting a valid HANDLE would see a small integer (a TID, typically in the range 1-32768). This is undocumented internal state; no known application introspects this field.
- `LockCount` is still maintained for external compatibility. Applications that poll `LockCount` to check if a CS is contended continue to work. However, `LockCount` is no longer the atomic-primary ownership word -- that role is now served by the futex word in `LockSemaphore`.

---

## 4. Fast Path (Uncontended)

The fast path handles the common case: the critical section is free, and the caller acquires it without contention. This executes entirely on the PE side, never crosses to Unix code, and never enters the kernel.

### Sequence

1. **Get Linux TID:** `nspa_get_unix_tid()` reads the cached TID from the TEB (a single memory load, ~2 ns). See [Section 7](#7-tid-source) for details.

2. **CAS the futex word:** `InterlockedCompareExchange(&LockSemaphore, my_tid, 0)`. If the field was 0 (lock free), it atomically writes `my_tid` and returns 0 (success). This is a single `lock cmpxchg` instruction on x86.

3. **Update bookkeeping:** `InterlockedIncrement(&LockCount)`, set `OwningThread = win_tid`, set `RecursionCount = 1`. These are for external compatibility with code that queries CS state.

### Cost

| Operation | Time |
| --- | --- |
| Upstream uncontended acquire | ~3 ns (1 atomic: `InterlockedIncrement`) |
| NSPA CS-PI uncontended acquire | ~8 ns (1 memory load + 1 CAS + 1 atomic) |
| Overhead | ~5 ns per uncontended acquire |

The 5 ns overhead is the cost of the CAS on `LockSemaphore` plus the TEB memory load. This is acceptable: in a DAW running at 48 kHz / 128 samples, a single audio callback period is 2,666,667 ns. Even 10,000 CS acquire/release pairs per callback add only 50 us of overhead -- under 2% of the callback budget.

### Code Path

    static inline BOOL nspa_cs_try_fast( RTL_CRITICAL_SECTION *crit, DWORD unix_tid )
    {
        LONG *futex = (LONG *)&crit->LockSemaphore;
        return InterlockedCompareExchange( futex, (LONG)unix_tid, 0 ) == 0;
    }

The function is `inline` -- the compiler emits the `lock cmpxchg` directly at each call site. No function call overhead.

---

## 5. Slow Path (Contended)

When the fast-path CAS fails (the futex word is non-zero, meaning another thread holds the lock), the slow path hands control to the kernel's `rt_mutex` PI infrastructure.

### Sequence

1. **Recursive check:** Before going to the kernel, check if the current thread already owns this CS (by comparing `OwningThread` against the Win32 TID). If yes, bump `RecursionCount` and return. This avoids calling `futex_lock_pi` on a lock we already hold, which would return `EDEADLK`. See [Section 9](#9-recursive-locking).

2. **Optional spin:** If `crit->SpinCount > 0`, retry the CAS up to `SpinCount` times with `YieldProcessor()` between attempts. This catches short critical sections that release before the spin budget expires, avoiding the syscall overhead.

3. **Publish waiter count:** `InterlockedIncrement(&LockCount)` before the syscall. This maintains LockCount semantics for external observers.

4. **Cross PE/Unix boundary:** Call `NtNspaLockCriticalSectionPI(futex)`. This is an Nt-style syscall that crosses from PE ntdll to Unix ntdll.

5. **Unix side:** `futex_lock_pi(futex)` -- a `syscall(__NR_futex, addr, FUTEX_LOCK_PI_PRIVATE, ...)`. The kernel:
   - Reads the owner TID from the futex word
   - Looks up the owner's task struct via the TID
   - Creates an `rt_mutex` backing the futex
   - Inserts the caller into the `rt_mutex` waiter tree (priority-ordered)
   - **Boosts the owner** to the caller's scheduling priority (if higher)
   - Blocks the caller until the owner releases

6. **Return:** When the owner releases and the kernel transfers ownership, `futex_lock_pi` returns 0. The futex word now contains the caller's TID (possibly with `FUTEX_WAITERS` set if more threads are waiting). The PE side sets `OwningThread` and `RecursionCount`.

### PI Chain Diagram

<div class="diagram-container">
<svg width="100%" viewBox="0 0 880 380" xmlns="http://www.w3.org/2000/svg">
  <!-- Background -->
  <rect width="880" height="380" fill="#1a1b26" rx="6"/>

  <text x="440" y="28" text-anchor="middle" fill="#c0caf5" font-size="14" font-weight="bold">PI Chain: RT Waiter to Kernel Boost</text>

  <!-- Layer labels (right side) -->
  <rect x="780" y="55" width="80" height="20" rx="6" fill="#24283b" stroke="#bb9af7" stroke-width="1"/>
  <text x="820" y="69" text-anchor="middle" fill="#bb9af7" font-size="8">User (PE)</text>

  <rect x="780" y="155" width="80" height="20" rx="6" fill="#24283b" stroke="#e0af68" stroke-width="1"/>
  <text x="820" y="169" text-anchor="middle" fill="#e0af68" font-size="8">User (Unix)</text>

  <rect x="780" y="230" width="80" height="20" rx="6" fill="#24283b" stroke="#ff9e64" stroke-width="1"/>
  <text x="820" y="244" text-anchor="middle" fill="#ff9e64" font-size="8">Kernel</text>

  <!-- Boundary lines -->
  <line x1="20" y1="140" x2="770" y2="140" stroke="#e0af68" stroke-width="0.8" stroke-dasharray="5,4"/>
  <line x1="20" y1="215" x2="770" y2="215" stroke="#ff9e64" stroke-width="0.8" stroke-dasharray="5,4"/>

  <!-- RT Waiter thread -->
  <rect x="40" y="55" width="160" height="65" rx="6" fill="#24283b" stroke="#f7768e" stroke-width="2"/>
  <text x="120" y="75" text-anchor="middle" fill="#f7768e" font-size="10" font-weight="bold">RT Waiter</text>
  <text x="120" y="90" text-anchor="middle" fill="#c0caf5" font-size="9">SCHED_FIFO prio 80</text>
  <text x="120" y="105" text-anchor="middle" fill="#c0caf5" font-size="8">CAS failed -- lock held</text>

  <!-- Arrow: waiter to futex word -->
  <line x1="200" y1="88" x2="280" y2="88" stroke="#f7768e" stroke-width="2"/>
  <text x="240" y="80" text-anchor="middle" fill="#f7768e" font-size="8">reads</text>

  <!-- Futex word (LockSemaphore) -->
  <rect x="285" y="55" width="200" height="65" rx="6" fill="#24283b" stroke="#7dcfff" stroke-width="2"/>
  <text x="385" y="75" text-anchor="middle" fill="#7dcfff" font-size="10" font-weight="bold">Futex Word</text>
  <text x="385" y="90" text-anchor="middle" fill="#c0caf5" font-size="9">&amp;crit-&gt;LockSemaphore</text>
  <text x="385" y="105" text-anchor="middle" fill="#e0af68" font-size="9">TID=4567 | WAITERS=1</text>

  <!-- Arrow: futex word to owner -->
  <line x1="485" y1="88" x2="560" y2="88" stroke="#7dcfff" stroke-width="2"/>
  <text x="523" y="80" text-anchor="middle" fill="#7dcfff" font-size="8">identifies</text>

  <!-- Lock holder thread -->
  <rect x="565" y="55" width="200" height="65" rx="6" fill="#24283b" stroke="#9ece6a" stroke-width="2"/>
  <text x="665" y="75" text-anchor="middle" fill="#9ece6a" font-size="10" font-weight="bold">Lock Holder</text>
  <text x="665" y="90" text-anchor="middle" fill="#c0caf5" font-size="9">SCHED_OTHER (TID 4567)</text>
  <text x="665" y="105" text-anchor="middle" fill="#c0caf5" font-size="8">Doing work inside CS...</text>

  <!-- Unix side: NtNspaLockCriticalSectionPI -->
  <rect x="80" y="150" width="280" height="45" rx="6" fill="#24283b" stroke="#e0af68" stroke-width="1.5"/>
  <text x="220" y="170" text-anchor="middle" fill="#e0af68" font-size="9" font-weight="bold">NtNspaLockCriticalSectionPI()</text>
  <text x="220" y="185" text-anchor="middle" fill="#c0caf5" font-size="8">futex_lock_pi(&amp;LockSemaphore)</text>

  <line x1="120" y1="120" x2="120" y2="150" stroke="#f7768e" stroke-width="1.5"/>

  <!-- Kernel rt_mutex -->
  <rect x="60" y="230" width="650" height="80" rx="6" fill="#24283b" stroke="#ff9e64" stroke-width="2"/>
  <text x="385" y="252" text-anchor="middle" fill="#ff9e64" font-size="11" font-weight="bold">Linux Kernel: rt_mutex PI Infrastructure</text>

  <!-- Inside kernel: 3 steps -->
  <rect x="80" y="262" width="180" height="35" rx="6" fill="#1a3a1a" stroke="#9ece6a" stroke-width="1"/>
  <text x="170" y="277" text-anchor="middle" fill="#9ece6a" font-size="8" font-weight="bold">1. Lookup owner task</text>
  <text x="170" y="290" text-anchor="middle" fill="#c0caf5" font-size="7">find_task_by_vpid(TID)</text>

  <line x1="260" y1="280" x2="285" y2="280" stroke="#9ece6a" stroke-width="1"/>

  <rect x="290" y="262" width="190" height="35" rx="6" fill="#2a1a1a" stroke="#f7768e" stroke-width="1"/>
  <text x="385" y="277" text-anchor="middle" fill="#f7768e" font-size="8" font-weight="bold">2. Create rt_mutex</text>
  <text x="385" y="290" text-anchor="middle" fill="#c0caf5" font-size="7">PI waiter tree (prio-ordered)</text>

  <line x1="480" y1="280" x2="505" y2="280" stroke="#9ece6a" stroke-width="1"/>

  <rect x="510" y="262" width="180" height="35" rx="6" fill="#1a2a1a" stroke="#e0af68" stroke-width="1.5"/>
  <text x="600" y="277" text-anchor="middle" fill="#e0af68" font-size="8" font-weight="bold">3. Boost owner</text>
  <text x="600" y="290" text-anchor="middle" fill="#9ece6a" font-size="7">SCHED_OTHER -&gt; SCHED_FIFO 80</text>

  <!-- Boost arrow back up to holder -->
  <line x1="665" y1="230" x2="665" y2="120" stroke="#e0af68" stroke-width="2.5"/>
  <text x="700" y="175" fill="#e0af68" font-size="9" font-weight="bold" transform="rotate(-90, 700, 175)">BOOST</text>

  <!-- Result annotation -->
  <rect x="60" y="325" width="650" height="38" rx="6" fill="#152a1a" stroke="#9ece6a" stroke-width="1.5"/>
  <text x="385" y="342" text-anchor="middle" fill="#9ece6a" font-size="10">Holder runs at SCHED_FIFO 80 until release.</text>
  <text x="385" y="356" text-anchor="middle" fill="#c0caf5" font-size="9">RT waiter sleeps on rt_mutex; release hands ownership to the highest-priority waiter.</text>

  <!-- syscall crossing -->
  <line x1="220" y1="195" x2="220" y2="230" stroke="#ff9e64" stroke-width="1.5"/>
</svg>
</div>

### Error Handling

- `EINTR`: The `futex_lock_pi` call is wrapped in a `do { } while (ret == -1 && errno == EINTR)` loop. Signal delivery restarts the wait.
- `ENOSYS`: Kernel lacks `FUTEX_LOCK_PI`. Returns `STATUS_NOT_SUPPORTED`, which triggers the fallback path (see [Section 10](#10-fallback-behavior)).
- Other errors: Returns `STATUS_UNSUCCESSFUL`. The PE side calls `RtlRaiseStatus()` to raise an exception -- this is a fatal condition indicating kernel-level corruption.

---

## 6. Release Path

Release is the mirror of acquire, with the same fast/slow split.

### Final Release (RecursionCount drops to 0)

1. **Clear bookkeeping:** Set `RecursionCount = 0`, `OwningThread = 0`. These must be cleared before the futex word is released, because once the futex word is zero, another thread can acquire the lock and see stale values.

2. **Uncontended release (fast):** `InterlockedCompareExchange(&LockSemaphore, 0, my_tid)`. If the CAS succeeds (the old value was exactly `my_tid` with no `FUTEX_WAITERS` bit), the lock is free. No syscall. Decrement `LockCount` and return.

3. **Contended release (slow):** If the CAS fails -- typically because the kernel set the `FUTEX_WAITERS` bit (0x80000000) on the futex word while a waiter blocked -- the old value is `my_tid | FUTEX_WAITERS`. The PE side calls `NtNspaUnlockCriticalSectionPI(futex)`, which invokes `futex(addr, FUTEX_UNLOCK_PI_PRIVATE, ...)`. The kernel:
   - Walks the `rt_mutex` waiter tree
   - Selects the highest-priority waiter
   - Atomically transfers the futex word's TID field to the selected waiter
   - Drops the PI boost on the releasing thread (restores original scheduling parameters)
   - Wakes the selected waiter

### Recursive Release (RecursionCount > 1)

If `RecursionCount > 1`, this is not the final unlock. Just decrement `RecursionCount` and `LockCount`, then return. The futex word stays unchanged (still contains our TID).

### Error Recovery

If `NtNspaUnlockCriticalSectionPI` returns `STATUS_NOT_SUPPORTED` (the extremely unlikely case where `FUTEX_LOCK_PI` worked but `FUTEX_UNLOCK_PI` returns ENOSYS), CS-PI logs an error, disables itself globally, and returns `STATUS_SUCCESS`. The futex word is stuck (contains a stale TID with `FUTEX_WAITERS` set), and future acquires on this specific CS will hang. This is accepted as a fatal diagnostic condition -- it should never happen on a consistent kernel.

---

## 7. TID Source

`FUTEX_LOCK_PI` requires the owner field in the futex word to be a valid **Linux kernel TID** (`pid_t` from `SYS_gettid`). The kernel validates this against its task list -- if the TID is invalid, `futex_lock_pi` returns `ESRCH`, and every contended acquire hangs.

Wine's `GetCurrentThreadId()` returns the **Win32 thread ID** from `TEB->ClientId.UniqueThread`. This is a wineserver-assigned value, unrelated to the Linux kernel TID. Using it directly causes `ESRCH`.

### Solution: Cached TID via TEB

The Unix-side `ntdll_thread_data` struct (embedded in the TEB's `GdiTebBatch` region) has an `nspa_unix_tid` field. This is populated on first access via `syscall(SYS_gettid)` and cached for the thread's lifetime.

**PE-side read (zero-syscall hot path):**

The PE side cannot include `unix_private.h` (it's Unix-only). Instead, it reads the TID at a hardcoded byte offset from `GdiTebBatch`:

    #ifdef _WIN64
    #define NSPA_UNIX_TID_OFFSET 0xf8
    #else
    #define NSPA_UNIX_TID_OFFSET 0x88
    #endif

    static inline DWORD nspa_get_unix_tid(void)
    {
        DWORD tid = *(volatile DWORD *)((char *)&NtCurrentTeb()->GdiTebBatch
                                        + NSPA_UNIX_TID_OFFSET);
        if (tid) return tid;
        return NtNspaGetUnixTid();  /* first call: populate via syscall */
    }

**Offset safety:** `C_ASSERT` checks in `unix_private.h` verify that `offsetof(struct ntdll_thread_data, nspa_unix_tid)` matches the PE-side literal. If the struct layout changes, the build fails.

**Cost:**
- Hot path (subsequent calls): ~2 ns (one memory load + branch-not-taken)
- Cold path (first call per thread): ~200-500 ns (one `syscall(SYS_gettid)` round trip)

The cold path fires at most once per thread. In a typical DAW with 20-50 threads, this is 20-50 syscalls total across the entire process lifetime -- negligible.

---

## 8. Gating Mechanism

CS-PI is gated on the `NSPA_RT_PRIO` environment variable. When the variable is unset, CS-PI is inactive and all CS functions execute the upstream Wine legacy path with zero overhead beyond a single branch on a cached state variable.

### Tri-State Machine

    nspa_cs_pi_state (static LONG):
      0  = uninitialized (first CS op on any thread triggers probe)
      1  = active (NSPA_RT_PRIO is set with a non-empty value)
      -1 = inactive (NSPA_RT_PRIO unset, or kernel returned ENOSYS)

### Why Not RtlQueryEnvironmentVariable_U

The obvious approach -- calling `RtlQueryEnvironmentVariable_U` to read the env var -- causes a **recursive stack overflow**. That function internally acquires critical sections (the PEB lock, the process heap lock). Those CS operations re-enter `nspa_cs_pi_active()`, which re-enters `RtlQueryEnvironmentVariable_U`, and so on. This was observed as `err:virtual:virtual_setup_exception` crashes on every PE binary launch.

### Direct PEB Scan

Instead, `nspa_cs_pi_active()` reads the PEB environment block directly:

    NtCurrentTeb()->Peb->ProcessParameters->Environment

This is a null-separated list of `L"VAR=value\0"` strings. The function walks the list comparing against `L"NSPA_RT_PRIO="` character by character, using no Rtl functions and no locks. This mirrors how the Windows loader reads environment variables before kernel32 is loaded.

### Race Safety

Multiple threads may call `nspa_cs_pi_active()` concurrently during the uninitialized phase. Each computes `new_state` independently, then publishes via `InterlockedCompareExchange(&nspa_cs_pi_state, new_state, 0)`. The first writer wins; all subsequent readers see the published value. Since all threads observe the same PEB environment, they all compute the same answer -- the race is benign.

---

## 9. Recursive Locking

`RTL_CRITICAL_SECTION` supports recursive acquisition: the same thread can enter a CS multiple times, incrementing `RecursionCount` each time, and must leave the same number of times.

CS-PI handles recursion without calling `futex_lock_pi` on a lock we already hold:

1. **On acquire:** After the fast-path CAS fails, check `crit->OwningThread == ULongToHandle(win_tid)`. If true, this is a recursive entry: bump `RecursionCount` and `LockCount`, return immediately. The futex word already contains our TID.

2. **On release:** If `RecursionCount > 1`, decrement it and `LockCount`, return immediately. The futex word stays unchanged. Only when `RecursionCount` drops to 0 is the futex word CAS'd back to zero (or the kernel unlock path invoked).

### Why This Matters

Calling `futex_lock_pi` when we already hold the futex would return `EDEADLK` (the kernel detects the self-deadlock via the rt_mutex chain). We must detect recursion in user space before the syscall. The OwningThread comparison is the canonical way -- it uses the Win32 TID, matching both the legacy path's check and external APIs like `RtlIsCriticalSectionLockedByThread`.

---

## 10. Fallback Behavior

CS-PI is a soft dependency on kernel `FUTEX_LOCK_PI` support. If the kernel returns `ENOSYS` (function not implemented), CS-PI disables itself permanently and all subsequent CS operations use upstream Wine's legacy keyed-event path.

### Trigger

The first `NtNspaLockCriticalSectionPI` call that receives `ENOSYS` returns `STATUS_NOT_SUPPORTED` to the PE side. The PE-side `nspa_cs_enter_pi` function:

1. Decrements `LockCount` (undoing the waiter count bump)
2. Calls `InterlockedExchange(&nspa_cs_pi_state, -1)` -- permanently disabling CS-PI
3. Returns `STATUS_RETRY`

The calling `RtlEnterCriticalSection` sees `STATUS_RETRY` and falls through to the legacy `InterlockedIncrement` / `RtlpWaitForCriticalSection` / keyed-event path.

### Scope

The disable is global and permanent (for the process lifetime). Once `nspa_cs_pi_state` is set to `-1`, `nspa_cs_pi_active()` returns `FALSE` on every subsequent call. All CS operations across all threads revert to upstream behavior.

### When This Fires

`FUTEX_LOCK_PI` has been in the Linux kernel since 2.6.18 (September 2006). Any kernel from the last 20 years supports it. On PREEMPT_RT kernels (which NSPA requires), it is always available. The fallback exists as a safety net for unusual kernel configurations (e.g., stripped embedded kernels), not as an expected code path.

---

## 11. SRW Lock Spin Phase

`RTL_SRWLOCK` is the other major user-space lock in Wine, used by the process heap, loader, and application code. NSPA adds a bounded spin phase to SRW lock acquisition, complementing CS-PI. These are independent optimizations for different lock types.

### Design

Windows SRW locks spin approximately 1024 iterations before parking via `NtWaitForAlertByThreadId`. Upstream Wine does zero spinning -- every contended acquire immediately calls `RtlWaitOnAddress`, which translates to a futex syscall. NSPA adds 256 spin iterations for normal threads before falling through to the wait.

    #define SRW_SPIN_COUNT 256

**RT threads skip spinning entirely.** An RT thread at `SCHED_FIFO` spinning on a lock held by a `SCHED_OTHER` thread would starve the holder -- the holder cannot make progress while the RT thread monopolizes the CPU. Better to fall through to the futex wait immediately, allowing the scheduler to handle priority properly (or, for CS, allowing PI to boost the holder).

**Single-CPU systems:** Spinning is disabled on uniprocessor systems. The holder cannot make progress while the spinner runs on the same (only) core.

### Relationship to CS-PI

SRW locks and critical sections are separate primitives with different internal architectures:

| Property | RTL_CRITICAL_SECTION | RTL_SRWLOCK |
| --- | --- | --- |
| Ownership tracking | Yes (OwningThread) | No |
| Recursive entry | Yes (RecursionCount) | No |
| PI under NSPA | Yes (FUTEX_LOCK_PI) | No (no owner to boost) |
| Spin phase under NSPA | Via SpinCount (existing) | 256 iters (new) |
| Wait mechanism | Keyed event / futex PI | RtlWaitOnAddress / futex |

SRW locks cannot have PI because they do not track ownership -- the kernel cannot know which thread to boost. The spin phase is the applicable optimization for SRW.

---

## 12. Validation

CS-PI is validated by three test programs in the NSPA RT test suite (`nspa_rt_test.exe`), run with `NSPA_RT_PRIO=80 NSPA_RT_POLICY=FF` on a `PREEMPT_RT` kernel.

### Test: cs-contention

**Purpose:** Validates that PI boost matches uncontended work time. A `SCHED_OTHER` holder does 200M-iteration busywork inside a CS (approximately 475 ms of CPU time). An RT waiter (`SCHED_FIFO 87`) blocks on the CS. Four `SCHED_OTHER` load threads compete for CPU. Under PI, the holder is boosted and the waiter's wait time matches the holder's work time. Without PI, CFS time-slices the holder against the load threads, inflating the wait.

**Results (v5, latest):**

| Metric | Value |
| --- | --- |
| Hold time per iteration | ~475 ms (work loop) |
| Waiter wait time (with PI) | 474-475 ms |
| Wait/hold ratio | ~1.00x (perfect) |
| Samples captured | 3/3 |
| Verdict | **PASS** |

The wait time matches the work time to within 1 ms, confirming the holder receives full CPU time under PI boost.

### Test: rapidmutex

**Purpose:** Throughput stress test. Four threads (1 RT + 3 load) perform 500,000 CS acquire/release cycles each on a shared critical section. Measures throughput, per-thread max wait, and correctness (shared counter).

**Results (v5, latest):**

| Metric | Baseline | RT (CS-PI) | Delta |
| --- | --- | --- | --- |
| Throughput | 319K ops/s | 327K ops/s | **+2.5%** |
| RT max wait | -- | 36 us | -- |
| RT avg wait | -- | 1 us | -- |
| Shared counter | 2,000,000 | 2,000,000 | correct |

**v4 to v5 improvement:** RT throughput improved from 312K to 327K ops/s (+4.7%). RT max wait dropped from 46 us to 36 us. These gains are attributed to SIMD memcpy/memmove optimizations reducing overhead in the CS fast path.

### Test: philosophers

**Purpose:** Dining philosophers with 5 diners, 2 forks each. Philosopher 0 is RT (`SCHED_FIFO`), philosophers 1-4 are `SCHED_OTHER`. Four background load threads. Validates transitive PI: philosopher 0 waiting on fork A, held by philosopher 1, who is waiting on fork B, held by philosopher 2 -- the PI chain propagates through the rt_mutex infrastructure.

**Results (v5, latest):**

| Metric | Value |
| --- | --- |
| Total meals | 250/250 (50 each) |
| Total elapsed | 205 ms |
| RT max wait | 1301 us |
| Spread (max-min meals) | 0 (perfect fairness) |
| Verdict | **PASS** |

The RT max wait varies between runs due to CFS load placement (v4 measured 601 us, v5 measured 1301 us -- both within acceptable range). The critical validation is that all meals complete without deadlock and the PI chain propagates correctly through nested lock acquisitions.

### v4 to v5 Summary

| Metric | v4 | v5 | Cause |
| --- | --- | --- | --- |
| rapidmutex RT throughput | 312K ops/s | 327K ops/s (+4.7%) | SIMD + SRW spin |
| rapidmutex RT max wait | 46 us | 36 us | Reduced lock transition overhead |
| cs-contention wait/hold ratio | ~1.00x | ~1.00x | Stable -- PI correct |
| philosophers meals | 250/250 | 250/250 | Stable -- transitive PI correct |
| fork-mutex RT elapsed | 1021 ms | 948 ms (-7.1%) | SIMD string ops in process setup |

---

*Wine-NSPA CS-PI documentation. Source: `dlls/ntdll/sync.c` (PE), `dlls/ntdll/unix/sync.c` (Unix). Generated 2026-04-15.*
