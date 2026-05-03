# Sync Primitives Research: SRW Spin, Adaptive CS, Condvar PI

Historical research archive retained as background for the CS-PI,
condvar-PI, and SRW-spin design choices.

---

## 1. Windows Behavior (what apps expect)

### SRW Locks

- **Spin count:** ~1024 iterations hardcoded, using `pause` instruction
- **Spin on single CPU:** Disabled (forced to 0)
- **Parking:** NtWaitForAlertByThreadId (same as WaitOnAddress), per-thread futex
- **Bit layout (x64):** bit0=exclusive_held, bit1=waking, bit2=multi_shared, bit3=shared_waiters, upper bits=shared_count OR wait_block_ptr
- **Wait blocks:** Stack-allocated on waiter's stack, linked list
- **PI support:** NONE. Windows has no PI for SRW locks. Only kernel Mutant objects get PI.
- **Wake:** NtAlertThreadByThreadId (single) or NtAlertMultipleThreadByThreadId (all)

### Critical Sections

- **Default SpinCount:** 0 (unless caller sets it)
- **RTL_CRITICAL_SECTION_FLAG_DYNAMIC_SPIN:** System substitutes ~2000-4000, ignores caller's value
- **Heap lock SpinCount:** 4000
- **Spin loop:** test LockCount -> YieldProcessor() -> decrement counter -> repeat
- **Early bailout:** if LockCount > 0 (multiple waiters), stop spinning
- **PI support:** NONE on Windows. Our NSPA CS-PI via FUTEX_LOCK_PI is novel.

### WaitOnAddress

- **No internal spin phase.** Goes directly to kernel wait.
- **Callers** (SRW locks) do their own spinning before calling WaitOnAddress.

### Condition Variables

- **No PI.** Pure user-mode, kernel doesn't know what resource is waited on.

---

## 2. Linux/glibc Behavior (what our platform provides)

### glibc Adaptive Mutex (PTHREAD_MUTEX_ADAPTIVE_NP)

- **Spin count:** 100 iterations (fixed, `MAX_ADAPTIVE_COUNT`)
- **Algorithm:** Simple loop -- `atomic_load_relaxed` + `_mm_pause()`, decrement counter
- **No exponential backoff, no contention adaptation, no owner-on-CPU check**
- **After 100 spins:** Falls through to `futex(FUTEX_WAIT)`
- **Key weakness vs kernel:** Spins blindly without knowing if owner is running

### glibc pthread_rwlock

- **Spin count:** ZERO. No spinning at all -- direct `futex(FUTEX_WAIT)` on contention
- **Writer preference (NONRECURSIVE_NP):** When writer waiting, new readers block
- **Uses two futex addresses** (readers/writers) for selective waking
- **Note:** PTHREAD_RWLOCK_PREFER_WRITER_NP is a no-op (identical to PREFER_READER)

### Linux Kernel rwsem (CONFIG_RWSEM_SPIN_ON_OWNER)

- **The gold standard for rwlock spinning.** Three-layer approach:
- **Layer 1 -- Entry gate** (`rwsem_can_spin_on_owner`):
  - Skip if `need_resched()`, NONSPINNABLE bit set, or owner NOT on CPU
  - Key insight: **only spin if owner is actively running on a CPU core**
- **Layer 2 -- OSQ (Optimistic Spin Queue):**
  - MCS-style queue lock serializes spinners -- only ONE thread spins on the rwsem at a time
  - Others queue behind the OSQ head, spinning on their own local variable (cache-friendly)
- **Layer 3 -- Owner-spin loop** (`rwsem_spin_on_owner`):
  - **No fixed iteration count** -- spins as long as same owner is on-CPU
  - After 1000 iterations without owner change, adds `cpu_relax()`
  - RT tasks get only ONE extra retry when owner is NULL
- **Reader-owned spin:** Time-capped at `(10 + nr_readers/2)us`, max 25us
  - Checked every 16 iterations to avoid sched_clock() overhead
- **Handoff:** After 4ms in wait queue, writer sets handoff bit (forced transfer)
  - RT/DL tasks set handoff immediately (no timeout)

### Linux Kernel Mutex Adaptive Spin (CONFIG_MUTEX_SPIN_ON_OWNER)

- Same OSQ + owner-on-CPU pattern as rwsem
- Only spin while owner task is running on a CPU core
- Falls to sleep when owner goes off-CPU or `need_resched()`
- **Unbounded iteration count** (bounded by owner's time on CPU)

### PI for Read-Write Locks -- State of the Art

- **Linux kernel:** PI for rwlocks is **explicitly unsupported**
  - Documentation: "only a single owner may own a lock (i.e. no read-write lock support)"
  - Fundamental problem: PI requires single owner, rwlocks have N readers
  - Multi-reader PI is undefined for SCHED_DEADLINE (what bandwidth per reader?)
- **PREEMPT_RT approach:** Rebuild rw_semaphore on rt_mutex
  - Writers acquire rt_mutex first (get PI from blocked readers)
  - Readers in slow path go through rt_mutex (acquire+release)
  - **Asymmetry:** Readers CAN boost waiting writer, but writer CANNOT boost multiple readers
  - Known limitation: low-priority reader can starve high-priority writer
- **No FUTEX_RDLOCK_PI or equivalent** exists in Linux
- **Academic:** RWPIP (Reader-Writer Priority Inheritance Protocol) requires O(N) boosts per writer block -- never productively deployed
- **Practical answer for RT:** Avoid rwlocks in RT-critical paths. Use PI mutexes, RCU, or seqlocks.

---

## 3. Upstream Wine vs Wine-NSPA Implementation

### SRW Locks (dlls/ntdll/sync.c)

| Aspect | Upstream Wine | Wine-NSPA (v5) |
| --- | --- | --- |
| Spin count | 0 -- straight to RtlWaitOnAddress | **256 iterations** (commit `005b55b4d8d`) |
| RT behavior | Same as normal threads | **RT threads skip spin entirely** (SCHED_FIFO starvation prevention) |
| Wait path | RtlWaitOnAddress -> FIFO queue -> futex_wait | Same (spin is before this path) |
| PI support | None | None (SRW PI deferred -- unsolved problem) |

**Bit layout (both):** `struct srw_lock { short exclusive_waiters; unsigned short owners; }` = 4 bytes.
Wait is via RtlWaitOnAddress -> user-space FIFO queue -> NtWaitForAlertByThreadId -> futex_wait.
No spin in RtlWaitOnAddress itself -- the spin phase is in the acquire functions.

### Critical Sections (dlls/ntdll/sync.c)

| Aspect | Upstream Wine | Wine-NSPA |
| --- | --- | --- |
| Contended path | Keyed event wait (NtWaitForKeyedEvent) | **FUTEX_LOCK_PI** (kernel rt_mutex PI chain) |
| Spin loop | Fixed YieldProcessor, bailout on LockCount > 0 | Same spin loop, PI path handles contention |
| DYNAMIC_SPIN flag | FIXME stub | FIXME stub (planned) |
| PI support | None | **Full PI via nspa_cs_enter_pi()** |

### Condition Variables (dlls/ntdll/sync.c + libs/librtpi/rtpi.h)

| Aspect | Upstream Wine | Wine-NSPA (v5) |
| --- | --- | --- |
| Win32 condvar (RtlSleepConditionVariableCS) | RtlWaitOnAddress, no PI | Same (no PI -- uses RtlWaitOnAddress, not pi_cond) |
| Unix-side condvar (pi_cond_t) | Not present | **FUTEX_WAIT_REQUEUE_PI** (commit `43862d8b591`) |
| pi_cond consumers | N/A | ntdll file I/O, virtual memory, audio drivers, gstreamer |
| PI gap on wake | N/A | **Closed** -- kernel atomically requeues waiter onto PI mutex |

### RtlWaitOnAddress (dlls/ntdll/sync.c)

- **Same in both upstream and NSPA:** No spin phase. Compare-under-spinlock -> FIFO queue -> NtWaitForAlertByThreadId -> futex_wait.
- 256-entry hash table of futex_queues indexed by addr >> 4.
- Indirect futex: does NOT futex on the lock word -- futexes on per-thread alert entry.

---

## 4. librtpi Integration

### What librtpi provides

- **pi_mutex_t:** FUTEX_LOCK_PI-based mutex, user-space CAS fast path
- **pi_cond_t:** Condition variable with FUTEX_WAIT_REQUEUE_PI / FUTEX_CMP_REQUEUE_PI
- **No pi_rwlock_t.** Reader-writer locks not supported (PI for rwlocks is unsolved)

### Wine-NSPA integration

- Tree-wide `pthread_mutex` -> `pi_mutex` replacement (ntdll unix, audio drivers, gstreamer, winebus)
- CS-PI via raw FUTEX_LOCK_PI in sync.c (PE-side critical sections)
- pi_cond with requeue-PI in all condvar consumers
- Recursive pi_mutex extension (`NSPA_RTPI_MUTEX_RECURSIVE`) for virtual_mutex
- Header-only implementation: `libs/librtpi/rtpi.h`

---

## 5. Comparison Table

| Implementation | Spin Count | Algorithm | Owner-Aware | PI Support |
| --- | --- | --- | --- | --- |
| **Windows SRW** | ~1024 (fixed) | test + pause loop | No | No |
| **Windows CS** | 0 or caller-set (DYNAMIC_SPIN: ~2000-4000) | test + YieldProcessor | No | No (kernel Mutant only) |
| **glibc adaptive mutex** | 100 (fixed) | atomic_load + pause | No | Separate (PTHREAD_PRIO_INHERIT) |
| **glibc rwlock** | 0 (no spinning) | Direct futex wait | No | No |
| **Kernel mutex** | Unbounded (owner-tracking) | OSQ + spin while owner on CPU | **Yes** | Via rt_mutex on PREEMPT_RT |
| **Kernel rwsem (writer)** | Unbounded (owner) + 10-25us (reader-owned) | OSQ + owner tracking + time cap | **Yes** | Partial (writer only) on PREEMPT_RT |
| **Upstream Wine SRW** | 0 (no spinning) | Direct RtlWaitOnAddress | No | No |
| **Wine-NSPA SRW** | **256 (fixed, RT skips)** | test + YieldProcessor | No | No |
| **Upstream Wine CS** | Static (caller-set) | YieldProcessor + early bailout | No | No |
| **Wine-NSPA CS** | Static (caller-set) | YieldProcessor + early bailout | No | **FUTEX_LOCK_PI** |
| **Wine-NSPA pi_cond** | N/A | FUTEX_WAIT_REQUEUE_PI | N/A | **Requeue-PI (atomic)** |

---

## 6. Remaining Design Work

### A -- CS DYNAMIC_SPIN (Planned)

Implement `RTL_CRITICAL_SECTION_FLAG_DYNAMIC_SPIN` properly:
- Substitute system default spincount (~4000, matching Windows)
- Gate behind `!nspa_cs_pi_active()` -- when PI is active, the kernel handles contention better than userspace spinning
- Low priority since the PI path is the primary contention mechanism

### C2 -- SRW PI (Deferred Indefinitely)

SRW locks have no owner by design. PI requires an owner. This is unsolved even in the Linux kernel:
- No `FUTEX_RDLOCK_PI` or equivalent exists
- PREEMPT_RT's rwsem approach (serialize writers through rt_mutex) has known reader-starvation issues
- Windows itself has no SRW PI -- apps don't expect it

**Decision:** Don't pursue. Focus PI effort on CS (done) and condvar (done). For RT paths that need PI, apps should use CriticalSection not SRW.

---

## 7. Implementation Status

1. **B -- SRW spin phase** -- **IMPLEMENTED** (commit `005b55b4d8d`)
   - 256-iteration spin in `RtlAcquireSRWLockExclusive` and `RtlAcquireSRWLockShared`
   - RT threads (NSPA_RT_PRIO active) skip spinning entirely
   - Disabled on single-CPU systems
   - Validated: 429 ntdll sync tests, 0 failures. RT suite 20/20 PASS.

2. **C1 -- pi_cond requeue-PI** -- **IMPLEMENTED** (commit `43862d8b591`)
   - `FUTEX_WAIT_REQUEUE_PI` / `FUTEX_CMP_REQUEUE_PI` in `libs/librtpi/rtpi.h`
   - Closes PI gap across all pi_cond consumers (ntdll, audio, gstreamer)
   - Benchmark: worst-case max 53.8us -> 31.6us (-41%) under RT load
   - RT suite 20/20 PASS.

3. **A -- CS DYNAMIC_SPIN** -- **Planned**
   - Implement `RTL_CRITICAL_SECTION_FLAG_DYNAMIC_SPIN` (~4000 spincount)
   - Gate behind `!nspa_cs_pi_active()`
   - Low priority (PI path handles most contention)

4. **C2 -- SRW PI** -- **Deferred indefinitely**
   - Unsolved problem, even Linux kernel doesn't have rwlock PI
   - Documented as a known limitation

---

## 8. Open Questions

- [x] ~~Benchmark: SRW zero-spin cost~~ -- Implemented srw-bench subcommand
- [x] ~~FUTEX_WAIT_REQUEUE_PI compatibility~~ -- Works, kernel 2.6.31+ (2009)
- [ ] Should SRW spin count be tunable via env var for benchmarking?
- [ ] CS DYNAMIC_SPIN: what spincount do Windows apps actually request?
