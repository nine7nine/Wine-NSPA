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
| [Aggregate-Wait and Async Completion](https://nine7nine.github.io/Wine-NSPA/aggregate-wait-and-async-completion.gen.html) | Aggregate-wait plus same-thread async completion architecture: `NTSYNC_IOC_AGGREGATE_WAIT`, per-process dispatcher-owned `io_uring`, and same-thread CQE drain / reply. Later dispatcher and async-file follow-ons build on this base. |
| [Architecture Overview](https://nine7nine.github.io/Wine-NSPA/architecture.gen.html) | Master system map: client / wineserver / kernel layering, shipped bypass surfaces, residual wineserver floor, and links into the dedicated subsystem docs below. |
| [Audio Stack](https://nine7nine.github.io/Wine-NSPA/audio-stack.gen.html) | winejack.drv (WASAPI + MIDI via JACK), nspaASIO bridge (ASIO -> WASAPI exclusive -> winejack -> JACK), and zero-latency bufferSwitch inside the JACK callback. |
| [Client Scheduler Architecture](https://nine7nine.github.io/Wine-NSPA/client-scheduler-architecture.gen.html) | spawn-main + `ntdll_sched` substrate: per-process `wine-sched` / `wine-sched-rt` hosts, async close queue, sched-hosted local timers, and the current client-side helper-thread consolidation model. |
| [Critical Section PI](https://nine7nine.github.io/Wine-NSPA/cs-pi.gen.html) | FUTEX_LOCK_PI on `CRITICAL_SECTION`: fast / slow path, PI chain, gating, fallback. v2.3 stable. |
| [Gamma Channel Dispatcher](https://nine7nine.github.io/Wine-NSPA/gamma-channel-dispatcher.gen.html) | Hybrid ntsync + wineserver request plane: single per-process channel transport, aggregate-wait over channel + uring eventfd + shutdown eventfd, and post-1011 TRY_RECV2 burst drain. |
| [Hook Cache](https://nine7nine.github.io/Wine-NSPA/hook-cache.gen.html) | Two-tier Win32 hook chain cache. Tier 1 server-side count rebuild + Tier 2 full chain snapshot in queue_shm; clients walk the chain locally without RPC. |
| [io_uring I/O Architecture](https://nine7nine.github.io/Wine-NSPA/io_uring-architecture.gen.html) | Shipped `io_uring` surface: file I/O, dispatcher-owned async `CreateFile`, and socket `RECVMSG` / `SENDMSG`, plus ntsync `uring_fd` integration. |
| [Local-File Bypass Architecture](https://nine7nine.github.io/Wine-NSPA/nspa-local-file-architecture.gen.html) | Bounded local `NtCreateFile` path for regular files and explicit directories, with shared inode arbitration, selected downstream file fast paths, and lazy server-handle promotion only when the call leaves the local envelope. |
| [Local Section Bypass](https://nine7nine.github.io/Wine-NSPA/local-section-architecture.gen.html) | Client-side unnamed file-backed sections on top of local-file handles: local create / map / query / unmap / close, mapping-bit publication back into the file aggregate, and same-process duplicate promotion at the server boundary. |
| [Message Ring Architecture](https://nine7nine.github.io/Wine-NSPA/msg-ring-architecture.gen.html) | Cross-thread PostMessage / SendMessage via per-queue memfd rings. Includes the redraw-window push ring, the paint-cache fast path, the paused direct `get_message` work, and the MR1 / MR2 / MR4 audit fix-pack. |
| [Memory, Sections, Large Pages, and Working-Set Support](https://nine7nine.github.io/Wine-NSPA/memory-and-large-pages.gen.html) | Client-side sections, large-page allocation and mapping semantics, current-process working-set reporting, working-set quota bookkeeping, and the shared-memory backing choices behind request payloads, per-queue memfd regions, shared inode tables, and large-page mappings. |
| [NT Local Stubs](https://nine7nine.github.io/Wine-NSPA/nt-local-stubs.gen.html) | Client-side NT bypass catalog: local-file, anonymous local events, and sched-hosted `local_timer` / `local_wm_timer`, plus the shared rules for fallback, promotion, and cross-process arbitration. |
| [NTSync and In-Process Synchronization](https://nine7nine.github.io/Wine-NSPA/ntsync-driver.gen.html) | Kernel plus Wine userspace sync architecture: PI primitives, handle-to-fd caching, client-created anonymous sync handles, gamma channel transport, `NTSYNC_IOC_AGGREGATE_WAIT`, and `NTSYNC_IOC_CHANNEL_TRY_RECV2`. |
| [Win32 Condvar PI (Requeue-PI)](https://nine7nine.github.io/Wine-NSPA/condvar-pi-requeue.gen.html) | FUTEX_WAIT_REQUEUE_PI for RtlSleepConditionVariableCS: condvar-to-mutex mapping, three new syscalls, zero-gap PI. |
| [Wineserver Decomposition](https://nine7nine.github.io/Wine-NSPA/wineserver-decomposition.gen.html) | Long-horizon plan to decompose wineserver after enough state migrates out via the bypass trajectories. Aggregate-wait is already shipped; the residual timer/fd-poll/routing work remains queued. |

### Test Results & Validation

| Document | Description |
|----------|-------------|
| [RT Test Harness](https://nine7nine.github.io/Wine-NSPA/nspa-rt-test.gen.html) | Two-layer validation harness: native ntsync suite plus the PE matrix, with `dispatcher-burst` for gamma coverage and the post-v8 targeted sched/socket validators documented alongside it. |
| [State of The Art](https://nine7nine.github.io/Wine-NSPA/current-state.gen.html) | Current shipped-state board: defaults, exact validation totals, performance deltas, targeted 2026-05-02 and 2026-05-03 follow-on results, and the remaining open work. |
| [Test Suite Comparison](https://nine7nine.github.io/Wine-NSPA/nspa-test-comparison.gen.html) | Current published v8 matrix plus preserved historical reports, with a post-v8 addendum for the newer targeted scheduler / local-event / socket / local-file validations. |

### Historical / Superseded

| Document | Description |
|----------|-------------|
| [Shmem IPC (legacy)](https://nine7nine.github.io/Wine-NSPA/shmem-ipc.gen.html) | The v1.5 / v2.4 per-thread pthread + userspace `sched_setscheduler` boost dispatcher. Superseded by the gamma channel dispatcher; retained for historical context. |
| [Decoration Loop Investigation](https://nine7nine.github.io/Wine-NSPA/decoration-loop-investigation.gen.html) | Ableton Live 12 windowing debug (WineHQ bug 57955). X11 fixed, Wayland untested. Investigation complete. |
| [Sync Primitives Research](https://nine7nine.github.io/Wine-NSPA/sync-primitives-research.gen.html) | Background research on SRW spin, condvar PI, adaptive CS across Windows / glibc / Linux kernel. Research archive. |

---

## Status

**WIP.** The 11.x tree's current published full-suite boundary remains Layer 1 native ntsync 3 PASS / 0 FAIL plus Layer 2 PE matrix 24 PASS / 0 FAIL / 0 TIMEOUT. The newer shipped 2026-05-02 and 2026-05-03 carries are documented as targeted follow-on validation rather than a synthetic v9.

Immediate follow-on dispatcher tuning also landed on top of that shipped base: ACQ_REL fences, inlined dispatcher helpers, allocator debug poison / valgrind stubs gated out of production builds, and inlined `read_request_shm` on the gamma hot path.

The 2026-05-02 shipped follow-ons are larger client-side moves: spawn-main + `ntdll_sched` is now default-on, eligible `local_timer` / `local_wm_timer` work has moved onto the shared `wine-sched-rt` host (`run-rt-probe-validation.sh` 10/10 PASS), anonymous local events are default-on (Ableton playback system CPU `40-57%` -> `~35%`), and socket `RECVMSG` / `SENDMSG` are default-on (`socket-io` deferred path `+6.5%` throughput, `-6.8%` p99, `0/2000` failures).

The 2026-05-03 follow-ons keep pushing the file and memory surface client-side: local sections are now default-on (`NSPA_LOCAL_SECTION=0` disables), eligible unnamed file-backed sections can stay local for create / map / query / unmap / close, and the widened local-file envelope keeps more regular-file, directory, metadata, flush, and EOF traffic off wineserver. On the compared runs that cut `nspa_create_mapping_from_unix_fd` from `2,664` to `~800` (`-70%`) and `create_file` handler count from `7,845` to `5,658`.

The 2026-05-01 shipped follow-ons remain in tree as well: the `winex11.drv` alpha-bit flush loop is AVX2-vectorized (`x11drv_surface_flush` 6.72% -> 2.39%, total `winex11.so` 6.76% -> 2.43%, bit-identical output), and the top Tier 1 compatibility/log-noise cleanup landed (`~565` stub prints per Ableton run -> `~5` first-time prints, plus `ShutdownBlockReasonCreate/Destroy` now succeed silently instead of failing with `ERROR_CALL_NOT_IMPLEMENTED`).

This is an active research branch -- code is not released and the architecture is still evolving.

Key areas under active work:

- **5 PI coverage paths**: CS-PI, NTSync PI, pi_cond requeue-PI, Win32 condvar PI, kernel-atomic IPC PI via gamma channels
- **Bypass trajectories**: most shipped default-on, including paint-cache; the direct `get_message` bypass remains paused, and the remaining server-managed file/socket/event surfaces are now narrower after the client scheduler, local-event, and socket-SQE carries
- **NTSync + in-process sync**: PI primitives, direct wait/signal path, aggregate-wait, and `TRY_RECV2` are in production; current module `10124FB81FDC76797EF1F91`
- **Wineserver decomposition**: long-horizon plan with bypass-trajectories-as-prereqs; the early lock-discipline and thread-token slices are shipped, the aggregate-wait slice is landed, and the residual timer/fd-poll problem is smaller after the newer client-side moves
- **Application compatibility**: Ableton Live 12 + VST hosts; PE-only Wine-NSPA build matrix (x86_64 + Wow64 i386)

---

## Related

- [Linux-NSPA Kernel](https://github.com/nine7nine/Linux-NSPA-pkgbuild) -- Custom PREEMPT_RT kernel with NTSync PI patches
- [librtpi](https://github.com/nine7nine/librtpi) -- PI mutex / condvar library (vendored into Wine-NSPA with a recursive `pi_mutex` extension for `virtual_mutex` re-entrance)
- [Wine-NSPA Wiki](https://github.com/nine7nine/Wine-NSPA/wiki) -- Installation and configuration (8.x)
