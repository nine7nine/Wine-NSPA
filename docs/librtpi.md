# Wine-NSPA -- librtpi (PI mutex / condvar)

This page documents Wine-NSPA's Wine-internal librtpi shim for
PI-aware Unix-side mutexes and condition variables, including the
recursive-mutex extension and the automated tree-wide sweep that moved
Wine call sites onto it.

## Table of Contents

1. [Overview](#1-overview)
2. [Why librtpi, not glibc pthread](#2-why-librtpi-not-glibc-pthread)
3. [Header-only shim, not vendored static lib](#3-header-only-shim-not-vendored-static-lib)
4. [`pi_mutex_t` -- futex PI on a raw word](#4-pi_mutex_t--futex-pi-on-a-raw-word)
5. [`NSPA_RTPI_MUTEX_RECURSIVE` extension](#5-nspa_rtpi_mutex_recursive-extension)
6. [`pi_cond_t` -- requeue-PI condvar](#6-pi_cond_t--requeue-pi-condvar)
7. [The librtpi sweep tool](#7-the-librtpi-sweep-tool)
8. [Compile-line discipline (`include/rtpi.h` forwarder)](#8-compile-line-discipline-includertpi-h-forwarder)
9. [Consumers in the Wine tree](#9-consumers-in-the-wine-tree)
10. [Commit history](#10-commit-history)
11. [References](#11-references)

---

## 1. Overview

librtpi is a small library that gives PE/Unix code two PI-aware
synchronization primitives:

- `pi_mutex_t` -- a mutex whose lock word is the operand of
  `FUTEX_LOCK_PI` / `FUTEX_UNLOCK_PI`, so the kernel maintains a PI
  chain on the holder for the duration of contention.
- `pi_cond_t` -- a condition variable that uses
  `FUTEX_WAIT_REQUEUE_PI` / `FUTEX_CMP_REQUEUE_PI` to atomically
  requeue waiters from the condvar word onto the paired mutex on
  signal, closing the wake-and-relock gap that exists with plain
  `FUTEX_WAIT`.

Upstream librtpi (`gitlab.com/linux-rt/librtpi`) is a Unix-native
static library. Wine-NSPA does not vendor that source tree; it carries
a header-only re-implementation of the same public API at
`libs/librtpi/rtpi.h`, plus a Wine-internal extension --
`NSPA_RTPI_MUTEX_RECURSIVE` -- that the upstream library deliberately
does not provide.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 380" xmlns="http://www.w3.org/2000/svg">
  <style>
    .lr-bg { fill: #1a1b26; }
    .lr-box { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .lr-mid { fill: #1f2535; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .lr-fast { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .lr-fix { fill: #2a1f14; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .lr-t { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .lr-s { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .lr-h { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .lr-g { fill: #9ece6a; font: bold 10px 'JetBrains Mono', monospace; }
    .lr-v { fill: #bb9af7; font: bold 10px 'JetBrains Mono', monospace; }
    .lr-y { fill: #e0af68; font: bold 10px 'JetBrains Mono', monospace; }
    .lr-line { stroke: #c0caf5; stroke-width: 1.2; fill: none; }
  </style>

  <rect x="0" y="0" width="940" height="380" class="lr-bg"/>
  <text x="470" y="28" text-anchor="middle" class="lr-h">librtpi shim: callers, primitives, kernel surface</text>

  <rect x="40" y="64" width="240" height="86" class="lr-box"/>
  <text x="160" y="90" text-anchor="middle" class="lr-t">Wine Unix-side callers</text>
  <text x="160" y="110" text-anchor="middle" class="lr-s">ntdll/unix, win32u, winex11.drv,</text>
  <text x="160" y="126" text-anchor="middle" class="lr-s">winejack.drv, winealsa.drv,</text>
  <text x="160" y="142" text-anchor="middle" class="lr-s">winegstreamer, file/cdrom/system</text>

  <rect x="320" y="64" width="240" height="86" class="lr-mid"/>
  <text x="440" y="90" text-anchor="middle" class="lr-v">libs/librtpi/rtpi.h</text>
  <text x="440" y="110" text-anchor="middle" class="lr-s">header-only, ~450 LoC</text>
  <text x="440" y="126" text-anchor="middle" class="lr-s">pi_mutex_t / pi_cond_t API</text>
  <text x="440" y="142" text-anchor="middle" class="lr-s">cached gettid in __thread var</text>

  <rect x="600" y="64" width="300" height="86" class="lr-fast"/>
  <text x="750" y="90" text-anchor="middle" class="lr-g">Linux futex syscalls</text>
  <text x="750" y="110" text-anchor="middle" class="lr-s">FUTEX_LOCK_PI / FUTEX_UNLOCK_PI / FUTEX_TRYLOCK_PI</text>
  <text x="750" y="126" text-anchor="middle" class="lr-s">FUTEX_WAIT_REQUEUE_PI / FUTEX_CMP_REQUEUE_PI</text>
  <text x="750" y="142" text-anchor="middle" class="lr-s">kernel rt_mutex PI chain</text>

  <line x1="280" y1="108" x2="320" y2="108" class="lr-line"/>
  <line x1="560" y1="108" x2="600" y2="108" class="lr-line"/>

  <rect x="40" y="186" width="400" height="86" class="lr-mid"/>
  <text x="240" y="210" text-anchor="middle" class="lr-v">pi_mutex_t (64-byte aligned union)</text>
  <text x="240" y="230" text-anchor="middle" class="lr-s">{ futex, flags, nspa_recursion } | pad[64]</text>
  <text x="240" y="248" text-anchor="middle" class="lr-s">futex word: TID | FUTEX_WAITERS | FUTEX_OWNER_DIED</text>
  <text x="240" y="264" text-anchor="middle" class="lr-s">user-space CAS fast path, FUTEX_*_PI on contention</text>

  <rect x="500" y="186" width="400" height="86" class="lr-mid"/>
  <text x="700" y="210" text-anchor="middle" class="lr-v">pi_cond_t (128-byte aligned union)</text>
  <text x="700" y="230" text-anchor="middle" class="lr-s">{ cond, flags, wake_id, state } | pad[128]</text>
  <text x="700" y="248" text-anchor="middle" class="lr-s">FUTEX_WAIT_REQUEUE_PI atomically requeues</text>
  <text x="700" y="264" text-anchor="middle" class="lr-s">waiter onto paired pi_mutex on wake</text>

  <rect x="40" y="296" width="860" height="68" class="lr-fix"/>
  <text x="470" y="320" text-anchor="middle" class="lr-y">NSPA extension: NSPA_RTPI_MUTEX_RECURSIVE</text>
  <text x="470" y="338" text-anchor="middle" class="lr-s">re-entrance counter, only touched by the current owner; no atomics on the recursion path</text>
  <text x="470" y="354" text-anchor="middle" class="lr-s">required for virtual_mutex (signal-handler re-entrance via guard-page stack-growth)</text>
</svg>
</div>

---

## 2. Why librtpi, not glibc pthread

`pthread_mutex_t` from glibc is NPTL-backed and does not carry PI by
default. glibc supports `PTHREAD_PRIO_INHERIT` as a mutex protocol
attribute, but:

- the cost is not a free lift -- it gates `pthread_mutex_lock` on
  internal NPTL bookkeeping and adds attribute walks the Wine code
  base does not carry,
- `pthread_mutex_t` is opaque to callers, so the kernel's PI
  primitive is two abstraction layers below user code, and
- `pthread_cond_t` has no requeue-PI variant exposed at the POSIX
  layer; the wake path is "wake the waiter, waiter re-locks the
  mutex", which leaves a window where no PI is in effect.

librtpi takes the inverse approach. The lock word *is* the futex
operand. There is no opaque pthread bookkeeping. The wake path on
the condvar side is an explicit
`FUTEX_CMP_REQUEUE_PI` so the kernel hands the waiter to the mutex's
PI chain atomically. That is semantically different from glibc's
POSIX pthread implementation, and the difference is visible at the
syscall trace level: librtpi calls are `SYS_futex` with the `_PI`
operations, glibc calls are not.

For Wine-NSPA's RT audio workload, that semantic difference is the
whole point. The audio thread (`SCHED_FIFO`, prio 80) acquiring an
internal Wine mutex held by a `SCHED_OTHER` worker has to inherit its
priority onto the holder until release. With glibc pthread that does
not happen for any of Wine's internal mutexes. With librtpi it
happens unconditionally for every converted call site, with no
runtime gating.

---

## 3. Header-only shim, not vendored static lib

Upstream librtpi is a small autotools project (Makefile.am,
`pi_mutex.c`, `pi_cond.c`, `pi_futex.h`, ~600 LoC, last release
2024). The earliest Wine-NSPA approach (NSPA RT v2.0) tried to vendor
the source tree under `libs/librtpi/` and build it as a Wine-internal
static library. That hit autotools obstacles repeatedly:

- Wine's `libs/` vendoring pattern is PE-cross-compiled (`musl`,
  `vkd3d`, `faudio`, `lcms2`, ...). librtpi is Unix-native C; it
  cannot be PE-cross-compiled at all.
- Building a Unix-native static lib under `libs/` has no Wine
  precedent. Every attempt produced configure-script regressions or
  missing-symbol link errors against the existing Wine build glue.
- Upstream is small, stable, and the API surface Wine-NSPA needs is
  even smaller (`pi_mutex_*` plus `pi_cond_*`).

NSPA RT v2.0.1 pivoted to a header-only re-implementation. The
`libs/librtpi/Makefile.in` declares no build target; it exists only
to host `rtpi.h`. The header re-implements the public API as inline
functions on top of the Linux futex syscalls Wine-NSPA already used
for CS-PI.

The resulting layout matches upstream's `pi_mutex_t` and
`pi_cond_t` field union exactly (down to the 64-byte / 128-byte
padding), so any code written against upstream librtpi compiles
unchanged against the NSPA shim. The NSPA additions
(`nspa_recursion`, `wake_id`, `state`) live inside the existing
padding; upstream callers that do not know about those fields are
unaffected.

---

## 4. `pi_mutex_t` -- futex PI on a raw word

The struct:

```c
typedef union pi_mutex {
    struct {
        uint32_t futex;          /* low 30 bits = owner TID,
                                  * bit 30 = FUTEX_OWNER_DIED,
                                  * bit 31 = FUTEX_WAITERS,
                                  * 0 when unowned */
        uint32_t flags;
        uint32_t nspa_recursion; /* NSPA extension; only touched
                                  * by the current owner */
    };
    uint8_t pad[64];
} pi_mutex_t __attribute__((aligned(64)));
```

The `flags` field carries `RTPI_MUTEX_PSHARED` to switch between
`FUTEX_*_PI` (process-shared) and `FUTEX_*_PI_PRIVATE` (process-local).

### Lock fast path

User-space CAS for the contention-free case:

```c
if (__atomic_compare_exchange_n(&mutex->futex, &expected, tid, 0,
                                __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
    return 0;
```

If the CAS fails because the mutex is already owned by the current
TID, the call returns `EDEADLK` (or bumps the recursion counter --
see Section 5).

If the CAS fails because the mutex is owned by another TID, the slow
path issues `FUTEX_LOCK_PI` (or its private variant), which blocks
the caller and applies PI to the holder until the mutex is released.

### Unlock fast path

```c
if ((mutex->futex & 0x3fffffffu) != tid) return EPERM;
if (__atomic_compare_exchange_n(&mutex->futex, &expected, 0, 0,
                                __ATOMIC_RELEASE, __ATOMIC_RELAXED))
    return 0;
/* slow path: kernel unlock, wakes the highest-priority waiter */
return syscall(SYS_futex, &mutex->futex, op, 0, NULL, NULL, 0);
```

If there are no waiters (`FUTEX_WAITERS` bit clear), the user-space
CAS releases the mutex; otherwise the kernel resolves the waiter
queue and wakes the highest-priority waiter.

### TID cache

Every `pi_mutex_lock` / `pi_mutex_unlock` needs `gettid()`. The
header caches the TID in a `__thread` variable:

```c
static __thread uint32_t nspa_rtpi_cached_tid;

static inline uint32_t nspa_rtpi_tid(void)
{
    uint32_t tid = nspa_rtpi_cached_tid;
    if (!tid) {
        tid = (uint32_t)syscall(SYS_gettid);
        nspa_rtpi_cached_tid = tid;
    }
    return tid;
}
```

First call per thread pays the syscall cost; every subsequent call is
a single load. There is no atomic on the cache because each thread
writes its own slot.

---

## 5. `NSPA_RTPI_MUTEX_RECURSIVE` extension

Upstream librtpi does not support recursive mutexes. That is a
deliberate library-design choice, not a kernel limitation -- the
kernel's `FUTEX_LOCK_PI` itself does not allow re-entrance, so a
recursive layer has to be entirely user-space.

Wine-NSPA needs recursion for at least one mutex: `virtual_mutex` in
`dlls/ntdll/unix/virtual.c`, which is genuinely re-entered from
within signal handlers. The guard-page stack-growth path
(`virtual_setup_exception`) re-enters the address-space lock from a
faulting thread that already holds it. Wine's pre-NSPA code achieved
that with `pthread_mutexattr_settype(..., PTHREAD_MUTEX_RECURSIVE)`;
the librtpi sweep cannot drop that mutex because plain `pi_mutex_t`
returns `EDEADLK` on self-re-lock.

The NSPA extension is minimal:

```c
#define NSPA_RTPI_MUTEX_RECURSIVE 0x10
```

When the flag is set on `pi_mutex_init`, `pi_mutex_lock` /
`pi_mutex_trylock` on a mutex already owned by the current thread
bump `nspa_recursion` instead of returning `EDEADLK`;
`pi_mutex_unlock` decrements it and only releases the futex word
when it hits zero:

```c
if ((mutex->futex & 0x3fffffffu) == tid) {
    if (mutex->flags & NSPA_RTPI_MUTEX_RECURSIVE) {
        mutex->nspa_recursion++;
        return 0;
    }
    return EDEADLK;
}
```

```c
if (mutex->flags & NSPA_RTPI_MUTEX_RECURSIVE) {
    if (mutex->nspa_recursion > 0) {
        mutex->nspa_recursion--;
        return 0;
    }
}
```

The recursion counter is only touched by the current owner (as
determined by the futex word), so no atomics are needed on it. The
extension is a strict superset: a mutex initialized without the flag
behaves exactly like upstream librtpi.

The `nspa_recursion` field lives in the existing 64-byte padding of
the union; binary layout is unchanged from upstream, and upstream
code that does not know about the field is unaffected.

### Recursive-mutex use sites in the Wine tree

| File                                   | Mutex                | Why recursive |
|----------------------------------------|----------------------|---------------|
| `dlls/ntdll/unix/virtual.c:3941`       | `virtual_mutex`      | signal-handler re-entrance via guard-page stack-growth path |
| `dlls/win32u/sysparams.c:5888`         | `user_mutex`         | nested win32u call paths |
| `dlls/win32u/gdiobj.c:1040`            | `gdi_lock`           | nested GDI object lookups |
| `dlls/winex11.drv/init.c:58`           | (winex11 lock)       | nested X11 driver locking |

---

## 6. `pi_cond_t` -- requeue-PI condvar

```c
typedef union pi_cond {
    struct {
        uint32_t cond;       /* sequence counter, incremented per signal */
        uint32_t flags;
        uint32_t wake_id;    /* signal generation, EAGAIN retry logic */
        uint32_t state;      /* RTPI_COND_STATE_READY */
    };
    uint8_t pad[128];
} pi_cond_t __attribute__((aligned(64)));
```

The condvar uses `FUTEX_WAIT_REQUEUE_PI` / `FUTEX_CMP_REQUEUE_PI` so
that waiters are atomically requeued from the condvar futex onto the
PI mutex's futex on signal. This closes the priority-inversion
window that exists with plain `FUTEX_WAIT`, where a woken thread has
to manually relock the mutex and there is a gap with no PI boost in
effect.

### Wait path

```text
pi_cond_timedwait(cond, mutex, abstime):
  cond->cond++
  wake_id = cond->wake_id
again:
  futex_id = cond->cond
  pi_mutex_unlock(mutex)
  ret = syscall(SYS_futex, &cond->cond, FUTEX_WAIT_REQUEUE_PI,
                futex_id, abstime, &mutex->futex, 0)
  if ret == 0: return 0          /* kernel requeued us; we own the mutex */
  pi_mutex_lock(mutex)            /* error path: relock manually */
  if errno == EAGAIN and state == READY:
    if cond->wake_id != wake_id:  return 0  /* signal raced us; stay awake */
    cond->cond++
    goto again
  return errno
```

### Signal path

```text
pi_cond_signal(cond, mutex):
again:
  cond->cond++
  cond->wake_id = cond->cond
  ret = syscall(SYS_futex, &cond->cond, FUTEX_CMP_REQUEUE_PI, 1,
                /* requeue 0 */, &mutex->futex, cond->cond)
  if ret >= 0: return 0
  if errno == EAGAIN: goto again
  return errno
```

`FUTEX_CMP_REQUEUE_PI` wakes one waiter and requeues zero (signal
wakes exactly one). `pi_cond_broadcast` is the same shape with
`requeue = INT_MAX`: wake one, requeue the rest directly onto the
mutex's PI chain so the thundering-herd path becomes "all woken
threads compete for the mutex's PI chain, kernel hands it to the
highest-priority requeued waiter on unlock".

### Pre-requeue history

The first version of the librtpi shim (NSPA RT v2.0) used plain
`FUTEX_WAIT` / `FUTEX_WAKE` with a sequence counter -- functionally
correct but not requeue-PI. Commit `43862d8b591` (2026-04-15)
upgraded it to the requeue-PI variant. After that the wait/wake gap
closed: every Wine-side condvar in the converted set retains PI
across the wake.

---

## 7. The librtpi sweep tool

`nspa/librtpi_sweep.py` is the automated rewriter that converts Wine
Unix-side `pthread_mutex_*` and `pthread_cond_*` use sites to the
librtpi equivalents. It runs against the Wine tree any time it needs
to re-apply the conversion (after a Wine version sync, after pulling
upstream patches that touched converted files, etc).

### Two-phase design

1. **Pairing discovery**: scan every target `.c` file, extract every
   `pthread_cond_wait(C, M)` / `pthread_cond_timedwait(C, M, T)` call,
   and build a multimap `cond_expr -> { mutex_expr, ... }` keyed on the
   textual expression of the cond argument.
2. **Rewrite**: walk each file's libclang AST and emit in-place
   rewrites for `pthread_*` -> `pi_*`. For
   `pthread_cond_signal` / `pthread_cond_broadcast`, look up the
   paired mutex in the map built in phase 1. (`pi_cond_signal` and
   `pi_cond_broadcast` need the paired mutex argument; upstream
   pthread does not.)

### Hard-fail rules

The sweep refuses to silently emit `FIXME`s or fall back to
heuristics:

- `pthread_cond_signal` / `broadcast` on a cond with no paired mutex
  anywhere in the target scope -> the cond is never used with
  `cond_wait`, which means dead code or analysis gap; refuse to
  sweep the file.
- `pthread_cond_signal` / `broadcast` on a cond with multiple paired
  mutexes that libclang AST scope analysis cannot disambiguate ->
  refuse to sweep.
- Any libclang parse error in a file -> refuse to sweep that file.

### Recursive mutexes

Mutexes initialized via
`pthread_mutexattr_settype(..., PTHREAD_MUTEX_RECURSIVE)` cannot be
converted by the sweep itself; the sweep detects and skips them so
they remain `pthread_mutex_t`. The
`NSPA_RTPI_MUTEX_RECURSIVE` extension is then applied by hand at
those specific sites (Section 5 lists the four current sites). This
keeps the sweep a "no decisions, full automation" tool: anything
that needs human judgment is left alone.

---

## 8. Compile-line discipline (`include/rtpi.h` forwarder)

Every Wine compile line carries `-Iinclude -I../include`. If a system
copy of upstream librtpi is installed at `/usr/include/rtpi.h`, that
path could shadow the NSPA header on some build configurations. That
matters because **upstream `pi_mutex_t` does not carry the
`nspa_recursion` field**: if any DLL accidentally compiled against
the system header, the resulting object code would mis-lay out
`pi_mutex_t` and silently misbehave at runtime -- different parts of
Wine would see different `pi_mutex_t` layouts and the recursive path
through `virtual_mutex` would break.

`include/rtpi.h` exists exactly to prevent that. It is a forwarder:

```c
#ifndef __WINE_INCLUDE_RTPI_H
#define __WINE_INCLUDE_RTPI_H

#include "../libs/librtpi/rtpi.h"

#endif
```

`include/` is searched first by every Wine compile line, so the
forwarder always wins before the system search path is consulted.
Every Wine DLL in the tree then automatically picks up the NSPA
version with no per-`Makefile.in` `-I$(top_srcdir)/libs/librtpi` hack.

---

## 9. Consumers in the Wine tree

The librtpi sweep + the manual recursive-mutex carries cover **57
files** under `dlls/`, `libs/`, `server/`, and `programs/`. Selected
sites:

| Subsystem        | File                                  | Notes                                    |
|------------------|---------------------------------------|------------------------------------------|
| ntdll/unix core  | `dlls/ntdll/unix/virtual.c`           | recursive `virtual_mutex` (signal handlers) |
| ntdll/unix core  | `dlls/ntdll/unix/server.c`            | server-side wait/signal helpers          |
| ntdll/unix core  | `dlls/ntdll/unix/sched.c`             | per-instance sched lock                  |
| ntdll/unix core  | `dlls/ntdll/unix/file.c`              | file-table mutex                         |
| ntdll/unix core  | `dlls/ntdll/unix/cdrom.c`             | cdrom device mutex                       |
| ntdll/unix core  | `dlls/ntdll/unix/system.c`            | system-info mutex                        |
| ntdll/unix nspa  | `dlls/ntdll/unix/nspa/rt.c`           | RT helpers                               |
| ntdll/unix nspa  | `dlls/ntdll/unix/nspa/local_file.c`   | local-file fast-path                     |
| ntdll/unix nspa  | `dlls/ntdll/unix/nspa/local_timer.c`  | sched-hosted local timers                |
| win32u           | `dlls/win32u/sysparams.c`             | recursive `user_mutex`                   |
| win32u           | `dlls/win32u/gdiobj.c`                | recursive `gdi_lock`                     |
| winex11.drv      | `dlls/winex11.drv/init.c`             | recursive driver lock                    |
| audio (JACK)     | `dlls/winejack.drv/jack.c`            | JACK callback PI                         |
| audio (JACK)     | `dlls/winejack.drv/jackmidi.c`        | MIDI ring                                |
| audio (ALSA)     | `dlls/winealsa.drv/alsa.c`            | ALSA stream lock                         |
| audio (ALSA)     | `dlls/winealsa.drv/alsamidi.c`        | ALSA MIDI                                |
| audio (Core)     | `dlls/winecoreaudio.drv/coremidi.c`   | CoreAudio MIDI                           |
| gstreamer        | `dlls/winegstreamer/wg_parser.c`      | parser state                             |
| gstreamer        | `dlls/winegstreamer/wg_allocator.c`   | allocator                                |
| nsiproxy         | `dlls/nsiproxy.sys/icmp_echo.c`       | ICMP table mutex                         |
| nsiproxy         | `dlls/nsiproxy.sys/ndis.c`            | NDIS table mutex                         |
| signal core      | `dlls/ntdll/unix/signal_x86_64.c`     | signal-frame mutex                       |

The sweep tool is re-runnable on each Wine version sync; the
recursive sites are stable manual carries.

---

## 10. Commit history

The commits below trace librtpi's introduction and evolution in the
Wine-NSPA tree. Times are author timestamps from `git log` on the
`wine-rt-claude/wine` submodule.

| Date       | Hash         | Subject                                                                |
|------------|--------------|------------------------------------------------------------------------|
| 2026-04-11 | `251a7fb62d7`| `libs/librtpi,nspa: NSPA RT v2.0 -- vendor librtpi + ast-grep sweep rule` |
| 2026-04-11 | `eaa66310021`| `libs/librtpi: NSPA RT v2.0.1 -- pivot to Wine-internal header-only rtpi.h` |
| 2026-04-11 | `fec786944e5`| `libs/librtpi: vendor PI-futex mutex library (header-only)`            |
| 2026-04-11 | `bc835f4ab2c`| `nspa: add librtpi_sweep.py -- automated pthread -> pi_* rewriter`     |
| 2026-04-11 | `e430344237a`| `nspa,dlls/ntdll/unix: relax sweep taint propagation + apply to ntdll/unix` |
| 2026-04-11 | `900f8b55a49`| `dlls/ntdll: apply librtpi sweep to thread.c (NSPA RT v2.1 first pass)`|
| 2026-04-11 | `dfe8e556c5d`| `include,dlls/win32u: sweep win32u + rtpi.h forwarder + gdi_driver.h conversion` |
| 2026-04-11 | `0dd738115ca`| `nspa,dlls: big librtpi sweep across remaining DLLs + fix cond pairing + header fixups` |
| 2026-04-15 | `43862d8b591`| `librtpi: upgrade pi_cond to FUTEX_WAIT_REQUEUE_PI / FUTEX_CMP_REQUEUE_PI` |
| 2026-04-15 | `d8bec787a1e`| `nspa: add pi_cond requeue-PI benchmark`                                |
| 2026-04-30 | `94a419cf6d4`| `nspa ntdll/unix/sched: per-instance refactor + pi_mutex (multi-class prep)` |

Notable later-than-bring-up commits:

- `1099e57371e` (`nspa rpc plan: 2.A clarified as no-op (CS-PI != librtpi)`) --
  explicit clarification that CS-PI (in `dlls/ntdll/sync.c`) and the
  librtpi sweep operate on *different* lock universes. CS-PI hooks
  Win32 `RtlEnterCriticalSection` process-wide when
  `NSPA_RT_PRIO` is set; librtpi converts Wine's *internal*
  Unix-side mutexes from `pthread_mutex_t` to `pi_mutex_t`. Win32
  CS DLLs (rpcrt4, ole32, etc.) get PI through CS-PI; they do not
  use librtpi.

---

## 11. References

### Wine-NSPA source

- `libs/librtpi/rtpi.h` -- the header-only implementation (~450
  LoC). Contains all `pi_mutex_*` and `pi_cond_*` inlines plus the
  `NSPA_RTPI_MUTEX_RECURSIVE` extension.
- `libs/librtpi/Makefile.in` -- present only to host `rtpi.h`; no
  build target.
- `include/rtpi.h` -- forwarder that ensures every Wine DLL
  picks up the NSPA header before any system librtpi header.
- `nspa/librtpi_sweep.py` -- two-phase libclang-based rewriter from
  `pthread_*` to `pi_*`.
- `dlls/ntdll/unix/virtual.c` (line 3941),
  `dlls/win32u/sysparams.c` (line 5888),
  `dlls/win32u/gdiobj.c` (line 1040),
  `dlls/winex11.drv/init.c` (line 58) -- the recursive-mutex carries.
- `wine/nspa/tests/pi_cond_bench.c` -- requeue-PI condvar benchmark.

### Upstream

- Upstream librtpi (`gitlab.com/linux-rt/librtpi`) -- the public API
  Wine-NSPA mirrors. The NSPA struct layouts are deliberately
  union-compatible, so any code written against upstream librtpi
  compiles against the NSPA shim.

### Cross-references

- [Critical Section PI](cs-pi.gen.html) -- the *separate* PI hook
  that operates on Win32 `CRITICAL_SECTION` process-wide. CS-PI and
  librtpi work on disjoint lock universes; the relationship is
  complementary, not stacked.
- [Win32 Condvar PI (Requeue-PI)](condvar-pi-requeue.gen.html) --
  the analogous requeue-PI work for `RtlSleepConditionVariableCS`.
- [NTSync PI Kernel](ntsync-pi-driver.gen.html) -- the kernel
  ntsync overlay that adds PI to NT-shape sync objects (mutex,
  semaphore, event, channel). librtpi covers Wine's *internal*
  Unix-side locks; ntsync covers the Win32 sync surface. Together
  with CS-PI and condvar-PI they form the full set of PI coverage
  paths in Wine-NSPA.
- [Sync Primitives Research](sync-primitives-research.gen.html) --
  background research on the Linux/Windows/glibc primitives that
  motivated the librtpi choice.
