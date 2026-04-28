# Wine-NSPA — State of The Art

**Date:** 2026-04-28
**Author:** Jordan Johnston
**Kernel:** `6.19.11-rt1-1-nspa` (PREEMPT_RT_FULL, production)
**ntsync module:** `srcversion A250A77651C8D5DAB719FE2`
**Wine submodule HEAD:** `ac823311aba` (Wine 11.6 + NSPA fork)
**Superproject HEAD:** `c4ecdf9`

---

## Where we are

Wine-NSPA closed a major audit-and-fix cycle on 2026-04-28. The arc that
opened with a 5-minute Ableton lockup under the new paint-cache bypass
(2026-04-25) ran through a KASAN-armed kernel session that turned up
four ntsync bugs, then a focused 1576-LOC walk of the wine-userspace
ring code that turned up three more pre-existing bugs of the
silent-contract-violation class. All seven are shipped. Two clean
Ableton runs followed: run-3 with the historical config (paint-cache
OFF) and run-4 with the previously-locking config (`NSPA_ENABLE_PAINT_CACHE=1`)
past the 5-minute threshold, both clean end-to-end.

The investigation halted feature velocity for a stretch, but the bugs
fixed sat on the critical RT-sync path that every remaining bypass
calls into — so paying that bill now on a contained surface beats
paying it mid-feature-rollout. The kernel is solid (~370M ops zero
errors across native + stress + soak + PE matrix), the userspace
fix-pack is shipped, and Phase C get_message bypass — paused
mid-development to investigate the lockup — is the obvious resume
target for the next session.

What the project looks like today: one small kernel module
(~3kLOC) plus a Wine fork that increasingly bypasses wineserver
through bounded shmem rings, all gated by a single env var
(`NSPA_RT_PRIO`) so upstream-Wine bytewise behaviour is unchanged
when the gate is off.

---

## 1. Kernel state

### 1.1 Kernel and module

| Item | Value |
|---|---|
| Kernel | `6.19.11-rt1-1-nspa` |
| Scheduler | `PREEMPT_RT_FULL` |
| ntsync `.ko` | `/lib/modules/6.19.11-rt1-1-nspa/kernel/drivers/misc/ntsync.ko` |
| ntsync srcversion | `A250A77651C8D5DAB719FE2` |
| Module ref count | 0 idle |
| Sources | `/home/ninez/pkgbuilds/Linux-NSPA-pkgbuild/linux-nspa-6.19.11-1.src/linux-nspa/src/linux-6.19.11/drivers/misc/ntsync.{c,h}` |

### 1.2 Patch stack on top of upstream ntsync

| # | Patch | Summary | Status |
|---|---|---|---|
| 1003 | Priority inheritance | Mutex owner PI boost, priority-ordered waiter queues, raw_spinlock + rt_mutex hardening | Shipped |
| 1004 | Channels | Per-process kernel-mediated request/reply channel object (gamma dispatcher backbone) | Shipped |
| 1005 | Thread-token | Per-thread token carried across channel sends; backs gamma T1/T2/T3 | Shipped |
| 1006 | RT alloc-hoist | Hoist `kfree`/`kmalloc` out from under `raw_spinlock` (six sites; pi_work pool/cleanup pattern) | Shipped |
| 1007 | Channel exclusive recv | `wait_event_interruptible_exclusive` + `wake_up_interruptible` — closes thundering-herd on channel waiter wake | Shipped |
| 1008 | EVENT_SET_PI deferred boost | Stage boost decision under `obj_lock`, apply inline at wait-return — no worker thread, no timer | Shipped |
| 1009 | channel_entry refcount | `refcount_t` on `ntsync_channel_entry`; closes REPLY-vs-cleanup UAF caught by KASAN in `test-channel-stress` | Shipped |

The full plan from the 2026-04-26 hardening session is at
`/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/nspa/docs/ntsync-rt-audit.md`
and validation totals at `project_ntsync_prod_kernel_validation_20260427`.

### 1.3 Validation totals against `A250A77651C8D5DAB719FE2`

| Layer | Run | Result | Ops | Errors |
|---|---|---|---|---|
| Native sanity | `run-rt-suite.sh native` | 2/2 PASS | small | 0 |
| Native stress | `event-set-pi 60s 8x8` | PASS | ~158M | 0 |
| Native stress | `mutex-pi 30s 8h+4mtx` | PASS | ~12M | 0 |
| Native stress | `channel 30s 4x4` | PASS, SEND=REPLY perfect | ~52M | 0 |
| Native stress | `mixed-load 300s 13 workers` | PASS, all paths | ~145M | 0 |
| PE matrix | `nspa_rt_test.exe baseline+rt` | 22/22 PASS | n/a | 0 |
| Ableton run-3 | smoke level 4, paint-cache OFF | PASS | n/a | 0 |
| Ableton run-4 | smoke level 4 + 5-min soak, paint-cache ON | PASS | n/a | 0 |

**Cumulative: ~370M ops, zero syscall errors, zero dmesg splats,
refcnt=0 post-soak.**

The four bugs fixed in this cycle were:

1. **Bug 1** — test-cleanup asymmetry stranding R1 when R2 wins the channel race (test-only, exposed by bug 2).
2. **Bug 2** — channel RECV thundering-herd → wake-loss on REPLY (1007).
3. **Bug 3** — `EVENT_SET_PI` deferred boost worker UAF when waiter exited mid-boost (1008).
4. **Bug 4** — `ntsync_channel_entry` REPLY-vs-cleanup UAF, KASAN-caught in `test-channel-stress` (1009).

---

## 2. Wine state

### 2.1 Branch + recent commits

Wine-NSPA fork on top of Wine 11.6.

| Type | Ref |
|---|---|
| Submodule | `wine-rt-claude/wine` |
| HEAD | `ac823311aba` |
| Tip series | msg_ring v2 fix-pack (2026-04-27) |

### 2.2 Recent fix pack — 2026-04-27 wine userspace audit

Three pre-existing bugs in `dlls/win32u/nspa/msg_ring.c` of the
silent-contract-violation class (same shape as the upstream
"Disallow Win32 va_list" fix), found by focused 1576-LOC audit walk
after ntsync was proven sound. Audit doc at
`wine/nspa/docs/wine-nspa-lockup-audit-20260427.md`.

| ID | Class | One-liner |
|---|---|---|
| MR1 | Reply-slot ABA | `__pad` repurposed as `reply_gen`; sender stamps post-reserve, receiver checks `slot->generation == expected_gen` before write. ABA-driven misdirected `LRESULT` would corrupt state under high cross-thread sync send rate. |
| MR2 | `FUTEX_PRIVATE` on shared memfd | `FUTEX_WAKE_PRIVATE`/`FUTEX_WAIT_PRIVATE` on `MAP_SHARED` memfd defeats cross-process matching (per-mm hash). Switched to non-private variants. |
| MR4 | POST wake-loss | POST dual-signal-fail rolled back slot `READY → EMPTY`, decremented `pending_count`, returned FALSE so caller falls back to authoritative server post. If consumer beat the rollback, keep return-TRUE. |

P2 (`local_wm_timer.c`), P3 (`local_file.c` client side), and P5
(`__pad` field sweep across NSPA shmem) walked end-to-end and confirmed
clean of the same bug class.

Bugs left as-is per audit (perf cliff or by-design):

- **MR3** — peer-cache slot leak under thread churn; ~30 LOC GC pass deferred.
- **MR5** — recursive `nspa_process_sent_messages` inside futex wait; by design (cross-send deadlock protection).
- **MR6** — `pending_count++` ordered before `state = READY`; sub-µs benign window.
- **MR7** — `mlock` silent failure; config-dependent (RLIMIT_MEMLOCK).

### 2.3 Recent commits at the tip

    ac823311aba  nspa docs: wine-NSPA lockup audit 2026-04-27
    9b4172e2bbc  nspa msg_ring v2: MR1 ABA + MR2 cross-process futex + MR4 POST wake-loss
    d7d7ec9d1ca  nspa tests: extend mixed-load to full driver coverage (sem + wait_all + pulse)
    dcc2d0c0f97  nspa tests: mixed-load stress — concurrent events + mutexes + channels
    eddf67d7587  nspa tests: mutex-pi-stress + channel-stress (catch the channel_entry UAF)
    05e689e4a18  nspa tests: ntsync Bug 1 fix + EVENT_SET_PI stress + suite skip-list
    9b13a757860  nspa_rt_test: seqlock-bound add Subtest B (queue-bits via GetQueueStatus)
    9e51ed5f907  nspa: harden retry loops at SCHED_FIFO callsites (audit §4.1)
    4f2c29bb1b2  nspa msg-ring v2 B1.0: revert paint-cache default to OFF
    b5e8dcab3eb  nspa gamma T3: flip dispatcher token consumption default ON
    9b6e2a108e1  nspa Phase B: flip openat lock-drop default ON post-1006

---

## 3. Active features

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

| Subsystem | Status | Default | Brief | Doc |
|---|---|---|---|---|
| **Gamma channel dispatcher** | Shipped | ON | Per-process kernel-mediated channel via ntsync 1004; T1+T2+T3 thread-token consumed; replaces legacy per-thread shmem pthread dispatcher | `gamma-channel-dispatcher.gen.html` (TBD) |
| **Phase A — `open_fd` refactor** | Shipped | ON | `fchdir+open` → `openat`; first step toward holding `global_lock` for less of the open path | `open-fd-phases.gen.html` (TBD) |
| **Phase B — `openat` lock-drop** | Shipped | ON | Release `global_lock` around `openat()` so audio thread requests aren't blocked by slow file syscalls during drum-load. Post-1006 default-on flip. | same as above |
| **Hook tier 1+2 cache** | Shipped | ON | Server-side cache rebuild + client cache reader; 26.7k/26.7k cache hit on Ableton 165s, `server_dispatch=0` | `hook-cache.gen.html` (TBD) |
| **CS-PI v2.3** | Shipped | ON when `NSPA_RT_PRIO` set | Recursive `pi_mutex` extension on top of vendored librtpi; LockSemaphore field repurposed | `cs-pi.gen.html` |
| **Condvar PI requeue** | Shipped | ON when `NSPA_RT_PRIO` set | `FUTEX_WAIT_REQUEUE_PI`; `RtlSleepConditionVariableCS` slow path; v6 ship | `condvar-pi-requeue.gen.html` |
| **librtpi vendoring** | Shipped | n/a | Header-only at `wine-rt-claude/include/rtpi.h` forwarder → `libs/librtpi/rtpi.h` | (vendored) |
| **NT-local file** (`nspa_local_file`) | Shipped | ON | `NtCreateFile` bypass for unix-name-resolvable paths; check_and_publish_open + bucket_lock seqlock | `nspa-local-file-architecture.gen.html` |
| **NT-local timer** (`nspa_local_timer`) | Shipped | ON | NT timer object client-resolution | (within local_timer.c) |
| **NT-local WM timer** (`nspa_local_wm_timer`) | Shipped | ON | `SetTimer` userspace path; `(win, id, msg)` tuple as built-in ABA discriminator | (within local_wm_timer.c) |
| **msg-ring v1 (POST/SEND/REPLY)** | Shipped | ON | Bounded mpmc shmem ring for `PostMessage`/`SendMessage`/reply between Wine threads in the same process | `msg-ring-architecture.gen.html` |
| **msg-ring v2 B1.0 paint-cache** | Shipped | **OFF** (gated) | Cross-process redraw cache for `WM_PAINT` fast-path; passed run-4 with paint-cache=1 past 5-min threshold; needs second validation run + long-soak before flipping default-on | `msg-ring-architecture.gen.html` |
| **msg-ring v2 Phase C get_message** | **WIP, paused** | n/a | Last bypass piece for window-message path; design notes at `wine/nspa/docs/msg-ring-v2-phase-bc-handoff.md`. After C lands, window messages are fully out of wineserver | (handoff doc only) |
| **io_uring Phase 1 (socket I/O)** | Shipped | ON when `NSPA_RT_PRIO` set | ALERTED-state interception; ntsync `uring_fd` extension (kernel patch 1004 in old numbering) | `io_uring-architecture.gen.html` |
| **io_uring Phase 2/3** | Pending | n/a | File I/O / async write coverage; not started | (no doc) |
| **Wineserver `global_lock` PI** | Shipped | ON when `NSPA_RT_PRIO` set | `pthread_mutex` → `pi_mutex` on `server/fd.c:global_lock`; CFS holders boost via PI chain when v2.4-boosted dispatcher contends | `cs-pi.gen.html` §wineserver |
| **vDSO preloader (Jinoh Kang port)** | Shipped | ON | Full 13-patch port (01–07, 09, 11–13); EHDR unmap (06) intentionally omitted on static-pie x86_64 | (within preloader.c) |
| **NSPA priority mapping** | Shipped | ON when `NSPA_RT_PRIO` set | `fifo_prio = nspa_rt_prio_base - (31 - nt_band)`, clamped `[1..98]`; TIME_CRITICAL pinned to ceiling | `current-state.gen.html` (this doc, §4) |

### 3.3 Audio stack

| Component | Status | Brief |
|---|---|---|
| `winejack.drv` | Shipped | Phase 1 MIDI + Phase 2 WASAPI audio + future MIDI through unified driver |
| `nspaASIO` Phase F | Shipped | Zero-latency `bufferSwitch` invoked **inside** the JACK RT callback — same-period output, no double-buffering hop |
| Native `winealsa`/`winepulse`/`wineoss` | Drop planned | Once winejack is fully stable; not removed yet |

---

## 4. Validation status

### 4.1 What's clean

- ntsync module `A250A77651C8D5DAB719FE2` against prod kernel `6.19.11-rt1-1-nspa`: 370M ops, 0 errors, 0 KASAN splats (debug-tree validation), 0 lockdep splats.
- nspa_rt_test PE matrix: 22/22 PASS (baseline + RT).
- Ableton Live 12 Lite — full smoke level 4 — **two clean runs on 2026-04-28**:
  - **Run-3**: paint-cache OFF (default config). Drum-track-load-while-playing × multiple, audio clean, exit 0.
  - **Run-4**: `NSPA_ENABLE_PAINT_CACHE=1` (the historical 5-min-lockup config). Past 5-min threshold without incident, multiple drum-load cycles, audio clean, exit 0.

### 4.2 What's gated awaiting more validation

- **`NSPA_ENABLE_PAINT_CACHE=1`** — one clean run is necessary but
  not sufficient per `feedback_validate_before_default_on.md`. Required
  before flipping default-on:
  - Second run on a different day / cold start.
  - Long-soak (>30 min playback + idle).
  - Workload variation (record arming, plugin scan, freeze track) to vary load shape from "demo + drum-load" alone.
- **`NSPA_DISABLE_EPOLL`** — runtime A/B for poll vs epoll on the wineserver main loop; defaults to epoll (upstream behaviour).

### 4.3 What can't be definitively confirmed

- **F5 paint-cache 5-min lockup** — historically reproducible with
  `NSPA_ENABLE_PAINT_CACHE=1` on the pre-fix wine. Run-4 cleared the
  same workload + duration cleanly. Working hypothesis: **MR1 (reply-slot
  ABA) was driving F5**, since paint-cache amplifies cross-thread sync
  send rate, and an ABA-driven misdirected `LRESULT` builds up
  state-machine corruption faster than the off-paint-cache baseline.
  Cannot be confirmed without a from-scratch repro on the pre-fix
  binary while bpftrace-armed — not worth the cost given the matching
  fix set and the clean post-fix validation run.

### 4.4 Observations from run-4

The user surfaced two architectural signals during run-4 that are
worth banking:

1. **Idle CPU clean** — meaningful regression-vs-rollback signal.
   The earlier Codex 1007–1011 series (rolled back per
   `feedback_dont_shotgun_audit_into_unfound_bug`) made idle CPU /
   DSP usage horrible. The current 1007 (3-LOC `wait_event_interruptible_exclusive`)
   + 1008 (deferred-boost staged under `obj_lock`, applied inline at
   wait-return — no worker thread/timer) + 1009 (`refcount_t`, one
   atomic per channel entry) are minimal-overhead by construction.
2. **GUI pauses but audio continues during drum-load** — RT priority
   isolation working as designed. Two mechanisms compose: SCHED_FIFO
   at `NSPA_RT_PRIO=80` preempts the GUI thread doing the drum-load,
   and Phase B `nspa_openat_lockdrop` releases `global_lock` around
   `openat()` so the wineserver dispatcher doesn't block audio thread
   requests during the slow file syscall. Lends credence to the
   wineserver decomposition plan when it's time to circle back.

---

## 5. Open work, in priority order

1. **Second paint-cache validation run** — different day / cold start
   plus long-soak (>30 min) plus workload variation. Closes the F5
   chapter. After that, flip `NSPA_ENABLE_PAINT_CACHE` default-on.
2. **msg-ring v2 Phase C get_message bypass** — paused mid-development.
   Design notes in `wine/nspa/docs/msg-ring-v2-phase-bc-handoff.md`.
   After C lands, window messages are fully out of wineserver.
3. **io_uring Phase 2 + 3** — file I/O and async write coverage
   on top of the Phase 1 socket-I/O ALERTED-state interception. Phase
   1 has been shipped and stable for months.
4. **`wine_sechost_service` device-IRP poll** — ~530 polls/s, 63k
   `get_next_device_request` per Ableton run; audit Q2
   (payload-distribution) is the gate before any bypass design.
5. **Wineserver decomposition Phase 3** — timer thread + aggregate-wait
   + FD poll thread splits. Plan at
   `wine/nspa/docs/wineserver-decomposition-plan.md`. Followed
   sequentially after enough state migrates out via bypasses (Phase
   C makes the decomposition cheaper).
6. **MR3 GC pass** — peer-cache slot leak under thread churn;
   ~30 LOC; perf cliff, not lockup. Defer until somebody hits it.
7. **CS DYNAMIC_SPIN substitution** — `RTL_CRITICAL_SECTION_FLAG_DYNAMIC_SPIN`
   FIXME stub for CRT heap; plan is ~4000 spincount gated behind
   `!nspa_cs_pi_active()`. Low priority.
8. **Wow64 clean rebuild** — 32-bit (i386) DLLs may be stale. Required
   for 32-bit VST plugins and older games. Medium priority.

---

## 6. Recent investigation arc — 2026-04-26 → 2026-04-28

The three-day arc is worth recording in one place because it
illustrates how Wine-NSPA's failure modes cross the kernel/userspace
boundary and how the discipline of "trace before audit" plays out.

**2026-04-26 morning** — msg-ring v2 B1.0 paint-cache shipped
default-on (commit `70d55350bef`). Ableton ran fine for 4–5 minutes
then locked into pure userspace deadlock. Mechanism unexplained;
paint-cache reverted to default-off (commit `4f2c29bb1b2`) the same
day.

**2026-04-26 afternoon** — assumed kernel-side, given the symptom
shape (silent userspace stall, no kernel splat). Spent the day on a
five-patch ntsync "audit-finding" series (1007–1011) without ever
tracing the original `EVENT_SET_PI` slab UAF. All five were rolled
back per `feedback_dont_shotgun_audit_into_unfound_bug`. The cost
of skipping the trace step was a full day of wasted patch-writing.

**2026-04-27 morning** — installed the debug kernel
(`linux-nspa-debug` with `slub_debug=FZPU` + `kfence` + KASAN). Ran
the test suite. KASAN fired in `test-channel-stress`: REPLY's
`wake_up_all` racing `SEND_PI`'s `kfree(e)`. **Root caused.** Same bug
class as the rolled-back 1008/1009 — but now with a backtrace. Clean
fix was `refcount_t` on `ntsync_channel_entry`, ~15 LOC. Three more
bugs surfaced in sequence: channel-RECV thundering-herd (1007 — clean
fix `wait_event_interruptible_exclusive`, 3 LOC), `EVENT_SET_PI`
deferred boost (1008 — staged under `obj_lock`, applied inline), test
cleanup asymmetry (Bug 1 — test-only).

**2026-04-27 afternoon** — debug kernel itself proved unstable under
heavy PREEMPT_RT load (`MAX_LOCKDEP_CHAINS too low`, `__might_sleep`
warnings, `softlockup_panic=1` configured). Module rebuilt for
production kernel `6.19.11-rt1-1-nspa`, swapped over `BD93BECF` →
`A250A77651C8D5DAB719FE2`. Validation ran clean: 370M ops, zero errors.

**2026-04-27 evening** — pivoted to wine-userspace audit on the
working hypothesis that remaining lockups are now wine-side. 1576-LOC
walk of `dlls/win32u/nspa/msg_ring.c` found three pre-existing bugs:
MR1 (reply-slot ABA), MR2 (`FUTEX_PRIVATE` on shared memfd), MR4
(POST dual-signal-fail wake-loss). All shipped same evening
(`9b4172e2bbc`). P2/P3/P5 follow-up audits all clean.

**2026-04-28 daytime** — Ableton run-3 PASS (paint-cache OFF).
Closed the lockup investigation. Then run-4 with
`NSPA_ENABLE_PAINT_CACHE=1` PASS, past the historical 5-min threshold,
likely incidentally fixing F5 via MR1.

**The takeaway** — the bugs found were all on the critical RT-sync
path that every remaining bypass (Phase C, io_uring 2/3, sechost)
calls into. They would have surfaced regardless, just attributed to
whichever bypass was being shipped at the time. Better paid now on a
contained surface than mid-feature-rollout. The discipline lesson —
trace before audit — is captured in
`feedback_dont_shotgun_audit_into_unfound_bug.md` and remains the
operating principle going forward.

---

## 7. Configuration reference

### 7.1 Active env vars

| Var | Effect |
|---|---|
| `NSPA_RT_PRIO=80` | Master gate. Sets RT priority ceiling and activates all four PI paths. When unset, Wine-NSPA is byte-identical to upstream Wine. |
| `NSPA_RT_POLICY=FF` | SCHED_FIFO (vs RR). Same-prio RR quantum-slices the audio thread; FIFO eliminates. |
| `NSPA_OPENFD_LOCKDROP=1` | Phase B `openat` lock-drop. **Default ON post-1006.** |
| `NSPA_DISPATCHER_USE_TOKEN=1` | Gamma T3 thread-token consumption in dispatcher. **Default ON.** |
| `NSPA_ENABLE_PAINT_CACHE=1` | msg-ring v2 B1.0 paint-cache. **Default OFF.** Awaiting second validation run. |
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
| `current-state.md` | This document — state of the art on 2026-04-28 |
| `cs-pi.gen.html` | Critical Section Priority Inheritance (CS-PI v2.3) — twelve-section deep dive |
| `condvar-pi-requeue.gen.html` | `RtlSleepConditionVariableCS` `FUTEX_WAIT_REQUEUE_PI` slow path |
| `ntsync-driver.gen.html` | NTSync kernel driver patch stack (1003–1006 era; 1007+ pending update) |
| `io_uring-architecture.gen.html` | io_uring Phase 1 socket-I/O ALERTED-state interception |
| `msg-ring-architecture.gen.html` | msg-ring v1 + v2 design notes |
| `nspa-local-file-architecture.gen.html` | NT-local file bypass (`NtCreateFile` short-circuit) |
| `shmem-ipc.gen.html` | NSPA shmem IPC primitives (γ + redraw + paint-cache) |
| `nspa-rt-test.gen.html` | nspa_rt_test PE harness reference |
| `architecture.gen.html` | Whole-system architecture overview |
| `decoration-loop-investigation.gen.html` | Wine 11.6 X11 windowing decoration-loop bug 57955 |
| `sync-primitives-research.gen.html` | Background research on sync primitive selection |

Several subsystems shipped since the Apr 16 doc generation are not yet
documented: gamma channel dispatcher, Phase A+B `open_fd`, hook tier
1+2 cache, NT-local timer / WM timer, the msg-ring v2 paint-cache fix
arc. These will follow in the same doc-sweep that produced this
state board.

---

*Generated 2026-04-28. Wine submodule `ac823311aba`, ntsync
`A250A77651C8D5DAB719FE2`, kernel `6.19.11-rt1-1-nspa`.*
