# Wine-NSPA 11.x

### Architecture, Implementation, and Validation

This repository publishes the public design, architecture, and validation
documentation for Wine-NSPA 11.x -- a PREEMPT_RT-focused fork of Wine 11.8
with end-to-end priority inheritance, kernel-mediated IPC, client-side NT
surfaces, and RT-oriented memory and I/O work.

**[View Documentation](https://nine7nine.github.io/Wine-NSPA/)**

---

## Documentation

### Architecture & Design

| Document | Description |
|----------|-------------|
| [Aggregate-Wait and Async Completion](https://nine7nine.github.io/Wine-NSPA/aggregate-wait-and-async-completion.gen.html) | Aggregate-wait, same-thread CQE drain, and async completion ownership. |
| [Architecture Overview](https://nine7nine.github.io/Wine-NSPA/architecture.gen.html) | System map for the current client, wineserver, and kernel layers. |
| [Audio Stack](https://nine7nine.github.io/Wine-NSPA/audio-stack.gen.html) | winejack, nspaASIO, and the RT callback audio path. |
| [Client Scheduler Architecture](https://nine7nine.github.io/Wine-NSPA/client-scheduler-architecture.gen.html) | `wine-sched`, `wine-sched-rt`, close queue, and sched-hosted timers. |
| [Critical Section PI](https://nine7nine.github.io/Wine-NSPA/cs-pi.gen.html) | Priority inheritance for `CRITICAL_SECTION`. |
| [Gamma Channel Dispatcher](https://nine7nine.github.io/Wine-NSPA/gamma-channel-dispatcher.gen.html) | Kernel-mediated wineserver IPC, aggregate-wait, and burst drain. |
| [Hook Cache](https://nine7nine.github.io/Wine-NSPA/hook-cache.gen.html) | Tier 1 + Tier 2 Win32 hook-chain caching. |
| [Hot-Path Optimizations](https://nine7nine.github.io/Wine-NSPA/hot-path-optimizations.gen.html) | TEB state, cache layout, SIMD string/Unicode loops, and other cost trims. |
| [io_uring I/O Architecture](https://nine7nine.github.io/Wine-NSPA/io_uring-architecture.gen.html) | File, socket, and async `CreateFile` use of `io_uring`. |
| [librtpi (PI mutex / condvar)](https://nine7nine.github.io/Wine-NSPA/librtpi.gen.html) | Wine’s internal PI mutex and condvar shim. |
| [Local-File Bypass Architecture](https://nine7nine.github.io/Wine-NSPA/nspa-local-file-architecture.gen.html) | Local regular-file and explicit-directory handling. |
| [Local Section Bypass](https://nine7nine.github.io/Wine-NSPA/local-section-architecture.gen.html) | Client-side unnamed file-backed sections on local-file handles. |
| [Message Ring Architecture](https://nine7nine.github.io/Wine-NSPA/msg-ring-architecture.gen.html) | Message rings, redraw push, paint cache, and empty-poll caching. |
| [Memory, Sections, Large Pages, and Working-Set Support](https://nine7nine.github.io/Wine-NSPA/memory-and-large-pages.gen.html) | Sections, large pages, working-set support, and shared-memory backing. |
| [NT Local Stubs](https://nine7nine.github.io/Wine-NSPA/nt-local-stubs.gen.html) | The NT-local stub pattern and the active stub surfaces. |
| [NTSync PI Kernel](https://nine7nine.github.io/Wine-NSPA/ntsync-pi-driver.gen.html) | Kernel-side ntsync overlay, PI, channels, and aggregate-wait. |
| [NTSync Userspace Sync](https://nine7nine.github.io/Wine-NSPA/ntsync-userspace.gen.html) | Wine-side ntsync cache, wait/signal path, and zero-time waits. |
| [Thread and Process Shared-State Bypass](https://nine7nine.github.io/Wine-NSPA/thread-and-process-shared-state.gen.html) | Published thread/process snapshots and zero-time waits. |
| [NSPA X11 Embed Protocol](https://nine7nine.github.io/Wine-NSPA/nspa-x11-embed-protocol.gen.html) | Atomic X11 embedding for Winelib hosts with Wine HWND children. |
| [Win32 Condvar PI (Requeue-PI)](https://nine7nine.github.io/Wine-NSPA/condvar-pi-requeue.gen.html) | Priority inheritance for Win32 condition variables. |
| [Wineserver Decomposition](https://nine7nine.github.io/Wine-NSPA/wineserver-decomposition.gen.html) | Residual wineserver scope and decomposition path. |

### Applications

| Document | Description |
|----------|-------------|
| [Element-NSPA](https://nine7nine.github.io/Wine-NSPA/element-plugin-host.gen.html) | Element port for Windows VST2 and VST3 hosting on Wine-NSPA. |
| [JUCE-NSPA](https://nine7nine.github.io/Wine-NSPA/juce-nspa.gen.html) | JUCE fork for Linux winelib hosting of Windows plugins. |
| [Yabridge-NSPA](https://nine7nine.github.io/Wine-NSPA/yabridge-nspa.gen.html) | Linux VST bridge fork aligned to Wine-NSPA RT and PI rules. |

### Test Results & Validation

| Document | Description |
|----------|-------------|
| [RT Test Harness](https://nine7nine.github.io/Wine-NSPA/nspa-rt-test.gen.html) | Native ntsync tests, PE matrix, and targeted follow-on validators. |
| [State of The Art](https://nine7nine.github.io/Wine-NSPA/current-state.gen.html) | Current defaults, validation totals, and measured results. |
| [Test Suite Comparison](https://nine7nine.github.io/Wine-NSPA/nspa-test-comparison.gen.html) | Validation baselines, methodology breaks, and archive lineage. |

### Historical / Superseded

| Document | Description |
|----------|-------------|
| [Shmem IPC (legacy)](https://nine7nine.github.io/Wine-NSPA/shmem-ipc.gen.html) | The v1.5 / v2.4 per-thread pthread + userspace `sched_setscheduler` boost dispatcher. Superseded by the gamma channel dispatcher; retained for historical context. |
| [Decoration Loop Investigation](https://nine7nine.github.io/Wine-NSPA/decoration-loop-investigation.gen.html) | Ableton Live 12 windowing debug (WineHQ bug 57955). X11 fixed, Wayland untested. Investigation complete. |
| [Sync Primitives Research](https://nine7nine.github.io/Wine-NSPA/sync-primitives-research.gen.html) | Background research on SRW spin, condvar PI, adaptive CS across Windows / glibc / Linux kernel. Research archive. |

---

## Status

The current archived full-suite boundary is Layer 1 native ntsync
`3 PASS / 0 FAIL / 0 SKIP` plus Layer 2 PE matrix
`32 PASS / 0 FAIL / 0 TIMEOUT` (`v9-validation-default`). Newer work is
documented as targeted follow-on validation on top of that baseline.

Current highlights:

- client scheduler hosts, local events, local timers, and socket `io_uring`
  send/recv are on the normal path
- widened local-file coverage and local sections keep more file and mapping
  work client-side
- thread/process shared-state readers also power zero-time process and
  thread waits
- msg-ring, empty-poll caching, x86_64 TEB hot state, cacheline-shaped
  userspace sync, and AVX2 string/Unicode loops further reduce hot-path
  overhead
- RT memory follow-ons include `mlockall()`, automatic hugetlb promotion,
  heap hugepage backing, and the safety/fallback fixes around them

---

## Related

- [Linux-NSPA Kernel](https://github.com/nine7nine/Linux-NSPA-pkgbuild) -- Custom PREEMPT_RT kernel with NTSync PI patches
- [librtpi](https://github.com/nine7nine/librtpi) -- upstream-tracking PI mutex / condvar library. Wine-NSPA carries a Wine-internal *header-only* re-implementation of the same public API at `libs/librtpi/rtpi.h`, plus the `NSPA_RTPI_MUTEX_RECURSIVE` extension required by `virtual_mutex` and a few other recursive sites. See the [librtpi documentation page](https://nine7nine.github.io/Wine-NSPA/librtpi.gen.html) for details.
- [Wine-NSPA Wiki](https://github.com/nine7nine/Wine-NSPA/wiki) -- Installation and configuration (8.x)
