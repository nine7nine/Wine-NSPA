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
| [Aggregate-Wait and Async Completion](https://nine7nine.github.io/Wine-NSPA/aggregate-wait-and-async-completion.gen.html) | Plan for `NTSYNC_IOC_AGGREGATE_WAIT` plus the gamma-dispatcher async-completion restructure. Replaces the cross-thread Phase C bridge with same-thread aggregate-wait + inline CQE drain. |
| [Architecture Overview](https://nine7nine.github.io/Wine-NSPA/architecture.gen.html) | Master overview: layered architecture, subsystem map, RT priority mapping, links into the dedicated subsystem docs below. |
| [Audio Stack](https://nine7nine.github.io/Wine-NSPA/audio-stack.gen.html) | winejack.drv (WASAPI + MIDI via JACK), nspaASIO bridge (ASIO -> WASAPI exclusive -> winejack -> JACK), Phase F zero-latency bufferSwitch inside the JACK callback. |
| [Critical Section PI](https://nine7nine.github.io/Wine-NSPA/cs-pi.gen.html) | FUTEX_LOCK_PI on `CRITICAL_SECTION`: fast / slow path, PI chain, gating, fallback. v2.3 stable. |
| [Gamma Channel-Based Wineserver Dispatcher](https://nine7nine.github.io/Wine-NSPA/gamma-channel-dispatcher.gen.html) | Single per-process kernel-mediated wineserver IPC channel via NTSync. SEND_PI / RECV2 / REPLY ioctls, kernel-atomic priority inheritance, thread-token pass-through. Replaces the legacy per-thread shmem-pthread dispatcher. |
| [Hook Cache](https://nine7nine.github.io/Wine-NSPA/hook-cache.gen.html) | Two-tier Win32 hook chain cache. Tier 1 server-side count rebuild + Tier 2 full chain snapshot in queue_shm; clients walk the chain locally without RPC. |
| [io_uring I/O Architecture](https://nine7nine.github.io/Wine-NSPA/io_uring-architecture.gen.html) | Phase 1 file I/O bypass (shipped). Phase 2 sockets and Phase 3 pipes / named events queued. ntsync `uring_fd` integration. |
| [Local-File Bypass Architecture](https://nine7nine.github.io/Wine-NSPA/nspa-local-file-architecture.gen.html) | NtCreateFile bypass for read-only regular files: client-private handle range, per-process table, shared inode-aggregation shmem with seqlock + PSHARED PI mutex bucket lock. ~28,500 file opens offloaded per Ableton startup. |
| [Message Ring Architecture](https://nine7nine.github.io/Wine-NSPA/msg-ring-architecture.gen.html) | Cross-thread PostMessage / SendMessage via per-queue memfd rings. Includes Phase A redraw-window push ring, Phase B1.0 paint-cache fastpath, Phase C get_message bypass (paused), and the MR1 / MR2 / MR4 audit fix-pack. |
| [NT Local Stubs](https://nine7nine.github.io/Wine-NSPA/nt-local-stubs.gen.html) | The architectural pattern of client-side stubs that satisfy NT-API calls without crossing into wineserver. Currently shipped: `nspa_local_file`, `nspa_local_timer`, `nspa_local_wm_timer`. |
| [NTSync PI Kernel Driver](https://nine7nine.github.io/Wine-NSPA/ntsync-driver.gen.html) | Patch series 1003-1009: PI primitives, channel object, thread-token pass-through, RT alloc-hoist, channel exclusive recv, EVENT_SET_PI deferred boost, channel_entry refcount UAF fix. ~370M-op validated. |
| [Win32 Condvar PI (Requeue-PI)](https://nine7nine.github.io/Wine-NSPA/condvar-pi-requeue.gen.html) | FUTEX_WAIT_REQUEUE_PI for RtlSleepConditionVariableCS: condvar-to-mutex mapping, three new syscalls, zero-gap PI. |
| [Wineserver Decomposition Plan](https://nine7nine.github.io/Wine-NSPA/wineserver-decomposition.gen.html) | Long-horizon plan to decompose wineserver after enough state migrates out via the bypass trajectories. Phases 1-2 shipped; 3 queued; 4 long-horizon. |

### Test Results & Validation

| Document | Description |
|----------|-------------|
| [State of The Art](https://nine7nine.github.io/Wine-NSPA/current-state.gen.html) | Live state board: kernel + module versions, PI coverage, bypass status, validation totals, open work. |
| [RT Test Harness](https://nine7nine.github.io/Wine-NSPA/nspa-rt-test.gen.html) | Layer 1 native ntsync stress suite + Layer 2 PE matrix. Subcommands, runner, watchdog, benchmarks. |
| [Test Suite Comparison](https://nine7nine.github.io/Wine-NSPA/nspa-test-comparison.gen.html) | v3 -> v7 timeline. Per-thread metrics, latency data, and the principle that PASS / FAIL + KASAN-clean is authoritative across versions. |

### Historical / Superseded

| Document | Description |
|----------|-------------|
| [Shmem IPC (legacy)](https://nine7nine.github.io/Wine-NSPA/shmem-ipc.gen.html) | The v1.5 / v2.4 per-thread pthread + userspace `sched_setscheduler` boost dispatcher. Superseded by the gamma channel dispatcher; retained for historical context. |
| [Decoration Loop Investigation](https://nine7nine.github.io/Wine-NSPA/decoration-loop-investigation.gen.html) | Ableton Live 12 windowing debug (WineHQ bug 57955). X11 fixed, Wayland untested. Investigation complete. |
| [Sync Primitives Research](https://nine7nine.github.io/Wine-NSPA/sync-primitives-research.gen.html) | Background research on SRW spin, condvar PI, adaptive CS across Windows / glibc / Linux kernel. Research archive. |

---

## Status

**WIP.** The 11.x tree passes its validation suite (Layer 1 native ntsync stress + Layer 2 PE matrix 22/22 baseline + RT) and is used for day-to-day development. The investigation arc through 2026-04-26 -> 2026-04-28 closed major debt: 4 ntsync kernel-driver bugs fixed under KASAN-armed stress, 3 wine-userspace bugs fixed in the message ring (MR1 reply-slot ABA, MR2 cross-process futex, MR4 POST wake-loss), and 2 clean Ableton runs (paint-cache off + paint-cache on past the historical 5-min lockup threshold).

This is an active research branch -- code is not released and the architecture is still evolving.

Key areas under active work:

- **5 PI coverage paths**: CS-PI, NTSync PI, pi_cond requeue-PI, Win32 condvar PI, kernel-atomic IPC PI via gamma channels
- **Bypass trajectories**: most shipped default-on; paint-cache validating; Phase C `get_message` bypass paused mid-development; sechost device-IRP poll and io_uring 2/3 queued
- **NTSync kernel driver**: patch series 1003-1009 validated against ~370M ops on production kernel `6.19.11-rt1-1-nspa`
- **Wineserver decomposition**: long-horizon plan with bypass-trajectories-as-prereqs; Phases 1-2 shipped, 3+ queued
- **Application compatibility**: Ableton Live 12 + VST hosts; PE-only Wine-NSPA build matrix (x86_64 + Wow64 i386)

---

## Related

- [Linux-NSPA Kernel](https://github.com/nine7nine/Linux-NSPA-pkgbuild) -- Custom PREEMPT_RT kernel with NTSync PI patches
- [librtpi](https://github.com/nine7nine/librtpi) -- PI mutex / condvar library (vendored into Wine-NSPA with a recursive `pi_mutex` extension for `virtual_mutex` re-entrance)
- [Wine-NSPA Wiki](https://github.com/nine7nine/Wine-NSPA/wiki) -- Installation and configuration (8.x)
