# Wine-NSPA 11.x

### WIP -- Active Research & Development

This repository documents the ongoing research, implementation, and validation work for Wine-NSPA 11.x -- a real-time capable, priority-inheritance-aware build of Wine targeting professional audio workloads.

Wine-NSPA 11.x is a **work in progress** built on top of upstream Wine 11.6. Everything here is subject to change -- designs may be revised, features may be reworked or dropped, and nothing should be considered stable or final. This documentation tracks the evolving design decisions, test results, and research as the work progresses.

**[View Documentation](https://nine7nine.github.io/Wine-NSPA/)**

---

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture Overview](https://nine7nine.github.io/Wine-NSPA/architecture.gen.html) | System architecture: RT priority mapping, CS-PI, NTSync PI, io_uring, SRW spin, pi_cond requeue-PI, Win32 condvar PI, SIMD optimizations. 9 SVG diagrams. |
| [Win32 Condvar PI](https://nine7nine.github.io/Wine-NSPA/condvar-pi-requeue.gen.html) | FUTEX_WAIT_REQUEUE_PI for RtlSleepConditionVariableCS: condvar-to-mutex mapping, 3 new syscalls, zero-gap PI. 2 SVG diagrams. |
| [Critical Section PI](https://nine7nine.github.io/Wine-NSPA/cs-pi.gen.html) | FUTEX_LOCK_PI on CRITICAL_SECTION: fast/slow path, PI chain, gating, fallback. |
| [NTSync Kernel Driver](https://nine7nine.github.io/Wine-NSPA/ntsync-driver.gen.html) | NTSync driver architecture: upstream vs NSPA, 5 kernel patches, PI boost, uring_fd. |
| [io_uring Architecture](https://nine7nine.github.io/Wine-NSPA/io_uring-architecture.gen.html) | Phase 1-3 io_uring integration: file I/O bypass, socket I/O via ALERTED-state interception, ntsync uring_fd. 2 SVG diagrams. |
| [Shmem IPC Architecture](https://nine7nine.github.io/Wine-NSPA/shmem-ipc.gen.html) | Per-thread shared memory IPC: dispatcher model, PI boost protocol, global_lock PI. |
| [State of The Art](https://nine7nine.github.io/Wine-NSPA/current-state.gen.html) | Test dashboard: 11 tests across v3/v5/v6, NTSync driver status, PI chain validation. |
| [Test Suite Comparison](https://nine7nine.github.io/Wine-NSPA/nspa-test-comparison.gen.html) | Full v3/v5/v6 comparison with per-thread metrics and latency data. |
| [RT Test Harness](https://nine7nine.github.io/Wine-NSPA/nspa-rt-test.gen.html) | Test architecture, subcommands, runner script, watchdog, benchmarks. |
| [Sync Primitives Research](https://nine7nine.github.io/Wine-NSPA/sync-primitives-research.gen.html) | SRW spin, condvar PI, adaptive CS -- Windows vs glibc vs kernel analysis. |
| [Decoration Loop Investigation](https://nine7nine.github.io/Wine-NSPA/decoration-loop-investigation.gen.html) | Ableton Live 12 windowing debug (WineHQ bug 57955). |

---

## Status

**WIP.** The 11.x tree passes its validation suite (22/22 tests, baseline + RT) and is used for day-to-day development. This is an active research branch -- code is not released and the architecture is still evolving.

Key areas under active work:
- 4 PI coverage paths: CS-PI, NTSync PI, pi_cond requeue-PI, Win32 condvar PI
- io_uring integration (all 3 phases committed, benchmarking ongoing)
- NTSync kernel driver PI patches (5 patches, validated on Linux-NSPA 6.19.11-rt1)
- Application compatibility (Ableton Live 12, VST hosts)

---

## Related

- [Linux-NSPA Kernel](https://github.com/nine7nine/Linux-NSPA-pkgbuild) -- Custom PREEMPT_RT kernel with NTSync PI patches
- [librtpi](https://github.com/nine7nine/librtpi) -- PI mutex/condvar library
- [Wine-NSPA Wiki](https://github.com/nine7nine/Wine-NSPA/wiki) -- Installation and configuration (8.x)
