# Wine-NSPA 11.x

### WIP -- Active Research & Development

This repository documents the ongoing research, implementation, and validation work for Wine-NSPA 11.x -- a real-time capable, priority-inheritance-aware build of Wine targeting PREEMPT_RT broadly, with professional audio workloads as a leading test case.

Wine-NSPA 11.x is a **work in progress** built on top of upstream Wine 11.6. Everything here is subject to change -- designs may be revised, features may be reworked or dropped, and nothing should be considered stable or final. This documentation tracks the evolving design decisions, test results, and research as the work progresses.

**[View Documentation](https://nine7nine.github.io/Wine-NSPA/)**

---

## Documentation

### Architecture & Design

| Document | Description |
|----------|-------------|
| [Aggregate-Wait and Async Completion](https://nine7nine.github.io/Wine-NSPA/aggregate-wait-and-async-completion.gen.html) | Landed kernel 1010 + dispatcher Phase 2/3 architecture: `NTSYNC_IOC_AGGREGATE_WAIT`, per-process dispatcher-owned `io_uring`, and same-thread CQE drain / reply. The 2026-04-30 Phase 4 / 1011 follow-ons build on this base. |
| [Architecture Overview](https://nine7nine.github.io/Wine-NSPA/architecture.gen.html) | Master system map: client / wineserver / kernel layering, shipped bypass surfaces, residual wineserver floor, and links into the dedicated subsystem docs below. |
| [Audio Stack](https://nine7nine.github.io/Wine-NSPA/audio-stack.gen.html) | winejack.drv (WASAPI + MIDI via JACK), nspaASIO bridge (ASIO -> WASAPI exclusive -> winejack -> JACK), Phase F zero-latency bufferSwitch inside the JACK callback. |
| [Client Scheduler Architecture](https://nine7nine.github.io/Wine-NSPA/client-scheduler-architecture.gen.html) | spawn-main + `ntdll_sched` substrate: per-process `wine-sched` / `wine-sched-rt` hosts, async close queue, sched-hosted local timers, and the current client-side helper-thread consolidation model. |
| [Critical Section PI](https://nine7nine.github.io/Wine-NSPA/cs-pi.gen.html) | FUTEX_LOCK_PI on `CRITICAL_SECTION`: fast / slow path, PI chain, gating, fallback. v2.3 stable. |
| [Gamma Channel Dispatcher](https://nine7nine.github.io/Wine-NSPA/gamma-channel-dispatcher.gen.html) | Hybrid ntsync + wineserver request plane: single per-process channel transport, aggregate-wait over channel + uring eventfd + shutdown eventfd, and post-1011 TRY_RECV2 burst drain. |
| [Hook Cache](https://nine7nine.github.io/Wine-NSPA/hook-cache.gen.html) | Two-tier Win32 hook chain cache. Tier 1 server-side count rebuild + Tier 2 full chain snapshot in queue_shm; clients walk the chain locally without RPC. |
| [io_uring I/O Architecture](https://nine7nine.github.io/Wine-NSPA/io_uring-architecture.gen.html) | Shipped `io_uring` surface: Phase 1 file I/O, dispatcher-owned async `CreateFile`, and Phase 4.8 socket `RECVMSG` / `SENDMSG`, plus ntsync `uring_fd` integration. |
| [Local-File Bypass Architecture](https://nine7nine.github.io/Wine-NSPA/nspa-local-file-architecture.gen.html) | NtCreateFile bypass for read-only regular files: client-private handle range, per-process table, shared inode-aggregation shmem with seqlock + PSHARED PI mutex bucket lock. ~28,500 file opens offloaded per Ableton startup. |
| [Message Ring Architecture](https://nine7nine.github.io/Wine-NSPA/msg-ring-architecture.gen.html) | Cross-thread PostMessage / SendMessage via per-queue memfd rings. Includes Phase A redraw-window push ring, Phase B1.0 paint-cache fastpath, Phase C get_message bypass (paused), and the MR1 / MR2 / MR4 audit fix-pack. |
| [NT Local Stubs](https://nine7nine.github.io/Wine-NSPA/nt-local-stubs.gen.html) | Client-side NT bypass catalog: local-file, anonymous local events, and sched-hosted `local_timer` / `local_wm_timer`, plus the shared rules for fallback, promotion, and cross-process arbitration. |
| [NTSync PI Kernel Driver](https://nine7nine.github.io/Wine-NSPA/ntsync-driver.gen.html) | Patch series 1003-1011: PI primitives, channel object, thread-token pass-through, RT alloc-hoist, hardening fixes, `NTSYNC_IOC_AGGREGATE_WAIT`, and `NTSYNC_IOC_CHANNEL_TRY_RECV2`. |
| [Win32 Condvar PI (Requeue-PI)](https://nine7nine.github.io/Wine-NSPA/condvar-pi-requeue.gen.html) | FUTEX_WAIT_REQUEUE_PI for RtlSleepConditionVariableCS: condvar-to-mutex mapping, three new syscalls, zero-gap PI. |
| [Wineserver Decomposition Plan](https://nine7nine.github.io/Wine-NSPA/wineserver-decomposition.gen.html) | Long-horizon plan to decompose wineserver after enough state migrates out via the bypass trajectories. Phases 1-2 shipped; aggregate-wait kernel/userspace slice landed; timer/fd-poll remainder still queued. |

### Test Results & Validation

| Document | Description |
|----------|-------------|
| [RT Test Harness](https://nine7nine.github.io/Wine-NSPA/nspa-rt-test.gen.html) | Two-layer validation harness: native ntsync suite plus the PE matrix, with `dispatcher-burst` for gamma coverage and the post-v8 targeted sched/socket validators documented alongside it. |
| [State of The Art](https://nine7nine.github.io/Wine-NSPA/current-state.gen.html) | Current shipped-state board: defaults, exact validation totals, performance deltas, targeted 2026-05-02 follow-on results, and the remaining gated work. |
| [Test Suite Comparison](https://nine7nine.github.io/Wine-NSPA/nspa-test-comparison.gen.html) | Current published v8 matrix plus preserved historical reports, with a post-v8 addendum for the 2026-05-02 targeted scheduler / local-event / socket validations. |

### Historical / Superseded

| Document | Description |
|----------|-------------|
| [Shmem IPC (legacy)](https://nine7nine.github.io/Wine-NSPA/shmem-ipc.gen.html) | The v1.5 / v2.4 per-thread pthread + userspace `sched_setscheduler` boost dispatcher. Superseded by the gamma channel dispatcher; retained for historical context. |
| [Decoration Loop Investigation](https://nine7nine.github.io/Wine-NSPA/decoration-loop-investigation.gen.html) | Ableton Live 12 windowing debug (WineHQ bug 57955). X11 fixed, Wayland untested. Investigation complete. |
| [Sync Primitives Research](https://nine7nine.github.io/Wine-NSPA/sync-primitives-research.gen.html) | Background research on SRW spin, condvar PI, adaptive CS across Windows / glibc / Linux kernel. Research archive. |

---

## Status

**WIP.** The 11.x tree's current published full-suite boundary remains Layer 1 native ntsync 3 PASS / 0 FAIL plus Layer 2 PE matrix 24 PASS / 0 FAIL / 0 TIMEOUT. The newer shipped 2026-05-02 carries are documented as targeted follow-on validation rather than a synthetic v9.

Immediate follow-on dispatcher tuning also landed on top of that shipped base: ACQ_REL fences, inlined dispatcher helpers, allocator debug poison / valgrind stubs gated out of production builds, and inlined `read_request_shm` on the gamma hot path.

The 2026-05-02 shipped follow-ons are larger client-side moves: spawn-main + `ntdll_sched` is now default-on, eligible `local_timer` / `local_wm_timer` work has moved onto the shared `wine-sched-rt` host (`run-rt-probe-validation.sh` 10/10 PASS), anonymous local events are default-on (Ableton playback system CPU `40-57%` -> `~35%`), and socket `RECVMSG` / `SENDMSG` are default-on (`socket-io` deferred path `+6.5%` throughput, `-6.8%` p99, `0/2000` failures).

The 2026-05-01 shipped follow-ons remain in tree as well: the `winex11.drv` alpha-bit flush loop is AVX2-vectorized (`x11drv_surface_flush` 6.72% -> 2.39%, total `winex11.so` 6.76% -> 2.43%, bit-identical output), and the top Tier 1 compatibility/log-noise cleanup landed (`~565` stub prints per Ableton run -> `~5` first-time prints, plus `ShutdownBlockReasonCreate/Destroy` now succeed silently instead of failing with `ERROR_CALL_NOT_IMPLEMENTED`).

This is an active research branch -- code is not released and the architecture is still evolving.

Key areas under active work:

- **5 PI coverage paths**: CS-PI, NTSync PI, pi_cond requeue-PI, Win32 condvar PI, kernel-atomic IPC PI via gamma channels
- **Bypass trajectories**: most shipped default-on; paint-cache validating; Phase C `get_message` bypass paused mid-development; the remaining server-managed file/socket/event surfaces are now narrower after the client scheduler, local-event, and socket-SQE carries
- **NTSync kernel driver**: patch series 1003-1011 in production; current module `10124FB81FDC76797EF1F91`
- **Wineserver decomposition**: long-horizon plan with bypass-trajectories-as-prereqs; Phases 1-2 shipped, aggregate-wait slice landed, and the residual timer/fd-poll problem is smaller after the 2026-05-02 client-side moves
- **Application compatibility**: Ableton Live 12 + VST hosts; PE-only Wine-NSPA build matrix (x86_64 + Wow64 i386)

---

## Related

- [Linux-NSPA Kernel](https://github.com/nine7nine/Linux-NSPA-pkgbuild) -- Custom PREEMPT_RT kernel with NTSync PI patches
- [librtpi](https://github.com/nine7nine/librtpi) -- PI mutex / condvar library (vendored into Wine-NSPA with a recursive `pi_mutex` extension for `virtual_mutex` re-entrance)
- [Wine-NSPA Wiki](https://github.com/nine7nine/Wine-NSPA/wiki) -- Installation and configuration (8.x)
