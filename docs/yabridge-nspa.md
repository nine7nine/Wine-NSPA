# Wine-NSPA -- Yabridge-NSPA

This page documents the yabridge fork aligned to Wine-NSPA's RT scheduling,
priority-inheritance, and userspace-sync model.

## Table of Contents

1. [Overview](#1-overview)
2. [Why a separate fork exists](#2-why-a-separate-fork-exists)
3. [Process shape](#3-process-shape)
4. [RT ownership and priority mapping](#4-rt-ownership-and-priority-mapping)
5. [Per-callback transport](#5-per-callback-transport)
6. [Current format coverage](#6-current-format-coverage)
7. [Startup and lifecycle hardening](#7-startup-and-lifecycle-hardening)
8. [Relationship to Wine-NSPA](#8-relationship-to-wine-nspa)
9. [References](#9-references)

---

## 1. Overview

Yabridge-NSPA is a yabridge fork for native Linux DAWs hosting Windows VST2,
VST3, and CLAP plugins through Wine-NSPA. It keeps yabridge's basic split
between a native Linux plugin library and a Winelib `yabridge-host`, but it
changes the hot path to match Wine-NSPA's RT rules instead of treating Wine as
generic userspace.

The load-bearing changes are:

- Wine-side thread promotion goes through Win32 priority APIs so Wine-NSPA's
  RT-band mapping applies.
- Cross-process audio rendezvous uses `pi_mutex_t` + `pi_cond_t` instead of a
  socket-only callback path.
- Fixed-layout metadata travels through the shared L2 region directly instead
  of being fully serialized every block.
- Startup, teardown, and crash handling are tightened around DAW exit,
  wineserver cold start, and stale shared-memory artifacts.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .yb-bg { fill: #1a1b26; }
    .yb-layer { fill: #1f2535; stroke: #3b4261; stroke-width: 1.2; }
    .yb-daw { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .yb-host { fill: #2a1f35; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .yb-shm { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .yb-kern { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .yb-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.2; rx: 8; }
    .yb-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .yb-head-g { fill: #9ece6a; font: bold 12px 'JetBrains Mono', monospace; }
    .yb-head-p { fill: #bb9af7; font: bold 12px 'JetBrains Mono', monospace; }
    .yb-head-y { fill: #e0af68; font: bold 12px 'JetBrains Mono', monospace; }
    .yb-head-b { fill: #7aa2f7; font: bold 12px 'JetBrains Mono', monospace; }
    .yb-text { fill: #c0caf5; font: 11px 'JetBrains Mono', monospace; }
    .yb-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .yb-line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .yb-line-p { stroke: #bb9af7; stroke-width: 1.4; fill: none; }
    .yb-line-y { stroke: #e0af68; stroke-width: 1.4; fill: none; }
    .yb-line-b { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="430" class="yb-bg"/>
  <text x="480" y="28" text-anchor="middle" class="yb-title">Yabridge-NSPA process shape</text>

  <rect x="40" y="60" width="300" height="230" class="yb-daw"/>
  <text x="60" y="86" class="yb-head-g">DAW process (native Linux)</text>
  <text x="60" y="102" class="yb-small">plugin-lib side loaded into Carla / Ardour / Element / similar hosts</text>

  <rect x="68" y="122" width="244" height="58" class="yb-box"/>
  <text x="190" y="146" text-anchor="middle" class="yb-text">plugin-lib bridge</text>
  <text x="190" y="162" text-anchor="middle" class="yb-small">VST2 / VST3 / CLAP entry points, host callbacks, control sockets</text>

  <rect x="68" y="198" width="244" height="58" class="yb-box"/>
  <text x="190" y="222" text-anchor="middle" class="yb-text">DAW audio thread</text>
  <text x="190" y="238" text-anchor="middle" class="yb-small">calls `process()` / `processReplacing()` and blocks on the L2 rendezvous</text>

  <rect x="370" y="112" width="220" height="126" class="yb-shm"/>
  <text x="480" y="138" text-anchor="middle" class="yb-head-y">AudioControlShm</text>
  <text x="480" y="158" text-anchor="middle" class="yb-small">per-instance or per-bridge shared region</text>
  <text x="480" y="176" text-anchor="middle" class="yb-small">request lock + cond</text>
  <text x="480" y="192" text-anchor="middle" class="yb-small">reply lock + cond</text>
  <text x="480" y="208" text-anchor="middle" class="yb-small">fixed-layout metadata + bounded fallback to bitsery/socket</text>

  <rect x="620" y="60" width="300" height="230" class="yb-host"/>
  <text x="640" y="86" class="yb-head-p">wine-host process (Winelib under Wine-NSPA)</text>
  <text x="640" y="102" class="yb-small">`yabridge-host.exe` + Windows plugin DLL/module</text>

  <rect x="648" y="122" width="244" height="58" class="yb-box"/>
  <text x="770" y="146" text-anchor="middle" class="yb-text">audio worker / dispatch loop</text>
  <text x="770" y="162" text-anchor="middle" class="yb-small">TIME_CRITICAL via Win32 APIs, same-thread plugin callback execution</text>

  <rect x="648" y="198" width="244" height="58" class="yb-box"/>
  <text x="770" y="222" text-anchor="middle" class="yb-text">Windows plugin module</text>
  <text x="770" y="238" text-anchor="middle" class="yb-small">VST2 / VST3 / CLAP implementation and any plugin-spawned workers</text>

  <rect x="120" y="330" width="720" height="62" class="yb-kern"/>
  <text x="480" y="356" text-anchor="middle" class="yb-head-b">Wine-NSPA substrate used by the bridge</text>
  <text x="480" y="372" text-anchor="middle" class="yb-small">vendored `rtpi.h`, Win32 priority mapping, wineserver warm-start</text>
  <text x="480" y="386" text-anchor="middle" class="yb-small">pidfd teardown, and Wine-side sync fixes</text>

  <line x1="312" y1="227" x2="370" y2="175" class="yb-line-g"/>
  <line x1="590" y1="175" x2="648" y2="151" class="yb-line-y"/>
  <line x1="190" y1="290" x2="190" y2="330" class="yb-line-g"/>
  <line x1="770" y1="290" x2="770" y2="330" class="yb-line-p"/>
  <line x1="480" y1="238" x2="480" y2="330" class="yb-line-y"/>
</svg>
</div>

The fork does not replace yabridge's overall model. It changes which primitive
owns the timing-critical boundary between the DAW and the Wine-host process.

---

## 2. Why a separate fork exists

Upstream yabridge targets stock Wine plus generic Linux scheduling and IPC.
Wine-NSPA changes the assumptions under that bridge:

- thread priority wants to flow through `SetPriorityClass()` and
  `SetThreadPriority()`, not direct `sched_setscheduler()` calls
- cross-process callback waits want priority inheritance, not a socket-only
  round-trip
- the shared sync ABI must match Wine-NSPA's `rtpi.h` layout on both the native
  and Winelib sides
- plugin startup and teardown now happen in a process that already has RT-aware
  wineserver, userspace sync, and tighter scheduling behavior

| Concern | Generic yabridge shape | Yabridge-NSPA shape |
|---|---|---|
| Audio-thread promotion | direct Linux scheduler calls | Win32 priority APIs so Wine-NSPA's mapping and process-class rules apply |
| Cross-process callback wait | unix socket send/recv and ordinary wakeup | `pi_mutex` + `pi_cond` rendezvous with cross-process PI |
| Shared sync ABI | external or system-provided primitive choice | vendored Wine-NSPA `rtpi.h` so both halves use one `pi_mutex_t` / `pi_cond_t` layout |
| Audio metadata path | serialized request/reply payload every block | fixed-layout direct fields for the hot metadata, with bounded fallback |
| Host startup and teardown | generic Wine spawn + polling watchdog | wineserver pre-warm, pidfd exit detection, PID-tagged cleanup |

This is why the fork is code, not just packaging or environment defaults.
Wine-NSPA-specific rules live on both sides of the bridge.

---

## 3. Process shape

Yabridge-NSPA still has the same two major halves:

- a native Linux plugin library loaded directly into the DAW
- a `yabridge-host` Winelib process that loads the Windows plugin module

The important change is what happens on the callback boundary.

- Control, editor, and recursive host/plugin traffic still use the established
  socket transport.
- The timing-critical audio callback path uses a dedicated shared region backed
  by `AudioControlShm`.
- The shared region is created on the native side and attached on the
  `yabridge-host` side.
- VST2 uses one dedicated audio rendezvous path for the bridge.
- VST3 and CLAP use per-instance rendezvous regions for their process callback.

That keeps the hard RT path narrow without rewriting the rest of yabridge's
control-plane logic.

---

## 4. RT ownership and priority mapping

The fork removes the old assumption that yabridge should decide Linux FIFO
priorities itself.

Instead:

- `yabridge-host` sets `REALTIME_PRIORITY_CLASS` at process scope
- wine-host worker threads and dispatch loops use
  `SetThreadPriority(THREAD_PRIORITY_TIME_CRITICAL)`
- scoped module-load and plugin-init brackets use
  `ScopedTimeCriticalBoost` so plugin-spawned workers inherit the intended RT
  entitlement
- demotion restores the previous Win32 thread priority instead of forcing the
  caller back to `SCHED_OTHER`

That has two practical effects:

1. Wine-NSPA, not yabridge, owns the mapping from Win32 priority bands to
   Linux scheduler state.
2. Plugin worker threads created during `LoadLibrary`, static initialization,
   or plugin initialization inherit an RT-capable parent at the point where the
   kernel checks entitlement.

The fork also removes two older mechanisms that became redundant once the
kernel-side PI handoff was in place:

| Removed assumption | Replacement |
|---|---|
| direct `sched_setscheduler(..., 5)` promotion in wine-host | `SetThreadPriority()` routed through Wine-NSPA |
| 10-second userspace priority resync and per-request `new_realtime_priority` fields | per-callback PI handoff through the shared rendezvous |

The point is to let the DAW thread's effective priority reach the Wine-host
worker during the callback, not to mirror scheduler state in userspace on a
timer.

---

## 5. Per-callback transport

The hot path uses a dedicated `AudioControlShm` rendezvous region with one
request lock/cond pair and one reply lock/cond pair.

The key invariant is that the cross-process lock is **not** held across the
plugin's callback body.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .tr-bg { fill: #1a1b26; }
    .tr-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.2; rx: 8; }
    .tr-daw { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .tr-host { fill: #2a1f35; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .tr-shm { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .tr-note { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.6; rx: 8; }
    .tr-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .tr-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .tr-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .tr-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .tr-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .tr-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .tr-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .tr-line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .tr-line-p { stroke: #bb9af7; stroke-width: 1.4; fill: none; }
    .tr-line-y { stroke: #e0af68; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="420" class="tr-bg"/>
  <text x="480" y="28" text-anchor="middle" class="tr-title">Audio callback rendezvous</text>

  <rect x="40" y="92" width="240" height="86" class="tr-daw"/>
  <text x="160" y="118" text-anchor="middle" class="tr-head-g">DAW audio thread</text>
  <text x="160" y="140" text-anchor="middle" class="tr-small">populate request metadata</text>
  <text x="160" y="156" text-anchor="middle" class="tr-small">signal request cond, then wait on reply cond</text>

  <rect x="360" y="66" width="240" height="138" class="tr-shm"/>
  <text x="480" y="92" text-anchor="middle" class="tr-head-y">AudioControlShm</text>
  <text x="480" y="116" text-anchor="middle" class="tr-small">request lock + cond</text>
  <text x="480" y="132" text-anchor="middle" class="tr-small">fixed-layout metadata or bounded fallback payload</text>
  <text x="480" y="148" text-anchor="middle" class="tr-small">reply lock + cond</text>
  <text x="480" y="176" text-anchor="middle" class="tr-text">same callback ownership, cross-process PI handoff</text>

  <rect x="680" y="92" width="240" height="86" class="tr-host"/>
  <text x="800" y="118" text-anchor="middle" class="tr-head-p">wine-host audio worker</text>
  <text x="800" y="140" text-anchor="middle" class="tr-small">wake, copy request, release request lock</text>
  <text x="800" y="156" text-anchor="middle" class="tr-small">run plugin callback, then publish reply</text>

  <line x1="280" y1="135" x2="360" y2="135" class="tr-line-g"/>
  <line x1="600" y1="135" x2="680" y2="135" class="tr-line-y"/>

  <rect x="250" y="242" width="460" height="78" class="tr-note"/>
  <text x="480" y="268" text-anchor="middle" class="tr-head-b">Load-bearing invariant</text>
  <text x="480" y="286" text-anchor="middle" class="tr-small">plugin `process()` / `processReplacing()` runs with no cross-process mutex held</text>
  <text x="480" y="302" text-anchor="middle" class="tr-small">locks only cover state transition, memcpy, and cond signaling</text>

  <rect x="110" y="340" width="740" height="46" class="tr-box"/>
  <text x="480" y="366" text-anchor="middle" class="tr-text">request side: direct metadata when fixed-shape, fallback when oversized or variable-shape</text>
</svg>
</div>

This transport does two different jobs:

1. **Wait/ownership**: the DAW thread and Wine-host worker hand off one audio
   callback with cross-process priority inheritance.
2. **Payload carriage**: fixed-layout hot metadata can stay in the shared
   region directly, while oversized or variable cases still have a bounded
   fallback.

The direct-layout work is what made the remaining serialization cost small
enough to stop dominating the bridge:

- request-side process context / time info / transport structs live in fixed
  fields
- hot event and parameter surfaces have fixed-layout ring or array forms
- response-side output events and output parameter changes also use the shared
  envelope

On a representative ACE VST3 capture with the direct envelope enabled, the
remaining bitsery encode/decode surface dropped to roughly `0.10%` of
`yabridge-host` CPU, while `pi_mutex_lock` itself sat at roughly `0.01%`.

---

## 6. Current format coverage

The fork uses one design, but not every plugin API needs the exact same
attachment points.

| Format | Hot callback path | What stays on the older control path |
|---|---|---|
| VST2 | dedicated L2 audio rendezvous for `processReplacing()` / audio processing, plus a PI mutex on the next-buffer MIDI queue | dispatcher/control socket traffic and non-audio host callbacks |
| VST3 | per-instance L2 rendezvous for `IAudioProcessor::process()` | object construction, editor/control traffic, and other infrequent interfaces |
| CLAP | per-instance L2 rendezvous for `clap_plugin->process()` | params/state/control surfaces outside the process callback |

Fixed-layout metadata coverage also differs slightly by format:

| Format | Direct metadata carried in the shared envelope |
|---|---|
| VST2 | `VstTimeInfo` and the bounded reply path |
| VST3 | `ProcessContext`, fixed-shape event ring, bounded parameter queues, response-side output events and parameter queues |
| CLAP | `clap_event_transport_t`, fixed-shape event ring, and response-side output events |

The envelope path is the normal path. The explicit runtime gate that used to
enable or disable the NSPA L2 transport was removed; the bridge uses the fast
path by default and falls back only when a particular callback shape does not
fit the bounded region.

---

## 7. Startup and lifecycle hardening

The yabridge fork also tightens the non-steady-state edges that matter in real
plugin-hosting sessions.

| Area | Final behavior |
|---|---|
| Module path exposure | module loads use DOS-path conversion so plugin-side `GetModuleFileNameW()` sees a parseable Windows path instead of a raw `\\\\?\\unix\\...` host path |
| Plugin load entitlement | `LoadLibrary` and selected plugin-init calls are bracketed with a scoped TIME_CRITICAL boost so worker threads spawned during `DllMain` or init inherit the intended RT entitlement |
| Cold wineserver startup | the host side pre-warms wineserver before launching `yabridge-host`, avoiding a class of cold-spawn failures in hosts that hit the first Wine launch of the session |
| Host startup failure | startup failure no longer aborts the native DAW; the bridge closes sockets and returns an error instead of taking the whole host down |
| DAW exit detection | pidfd-based watchdog wakes on parent exit instead of relying only on a coarse polling timer |
| Stale artifacts | endpoint names carry a PID sentinel, and plugin-lib initialization performs one-shot orphan cleanup in `${XDG_RUNTIME_DIR}` and `/dev/shm` |

These are not separate features from the audio transport. They are what make
the transport survivable in long DAW sessions, repeated scans, and crash or
SIGKILL scenarios.

---

## 8. Relationship to Wine-NSPA

Yabridge-NSPA is not part of the Wine tree, but it is intentionally coupled to
Wine-NSPA in a few load-bearing places.

- It vendors Wine-NSPA's `rtpi.h` because both halves of the bridge must agree
  on one `pi_mutex_t` / `pi_cond_t` layout. Mixing generic system librtpi with
  Wine-NSPA's header-only implementation is not a safe ABI choice.
- It routes thread promotion through Win32 APIs because Wine-NSPA already owns
  the mapping from Win32 priority classes/bands to Linux scheduler state.
- It benefits from Wine-NSPA-side sync and startup fixes, but it does not
  re-implement those rules locally.
- It is adjacent to the [Audio Stack](audio-stack.gen.html), not a replacement
  for it. `nspaASIO` and `winejack.drv` solve Wine-native Windows audio APIs;
  Yabridge-NSPA solves the Linux-DAW-to-Windows-plugin bridge.

The practical view is simple: Wine-NSPA makes the Wine side RT-correct, and
Yabridge-NSPA carries those rules across the native/Linux-to-Wine plugin
boundary.

---

## 9. References

### Source

- `yabridge/src/common/rtpi.h` -- vendored Wine-NSPA `rtpi.h`
- `yabridge/src/common/pi_sync.h` -- C++ RAII wrappers for `pi_mutex_t` / `pi_cond_t`
- `yabridge/src/common/audio-control-shm.{h,cpp}` -- shared L2 rendezvous region and direct-struct envelope
- `yabridge/src/wine-host/nspa_rt.h` -- Win32 priority helpers and scoped RT load bracket
- `yabridge/src/wine-host/host.cpp` -- `REALTIME_PRIORITY_CLASS` process setup
- `yabridge/src/wine-host/utils.{h,cpp}` -- pidfd watchdog registration and DOS-path conversion helpers
- `yabridge/src/plugin/orphan-cleanup.{h,cpp}` -- PID-tagged endpoint cleanup
- `yabridge/src/plugin/bridges/vst2*` -- VST2 bridge-side L2 use
- `yabridge/src/plugin/bridges/vst3*` -- VST3 bridge-side L2 use
- `yabridge/src/plugin/bridges/clap*` -- CLAP bridge-side L2 use
- `yabridge/src/wine-host/bridges/vst2*` -- VST2 Wine-host audio worker and callback path
- `yabridge/src/wine-host/bridges/vst3*` -- VST3 Wine-host process callback path
- `yabridge/src/wine-host/bridges/clap*` -- CLAP Wine-host process callback path

### Related Wine-NSPA docs

- `audio-stack.gen.html` -- Wine-native JACK / WASAPI / ASIO path
- `librtpi.gen.html` -- the PI mutex / condvar API Yabridge-NSPA vendors
- `ntsync-userspace.gen.html` -- Wine-side wait/signal and userspace sync model
- `architecture.gen.html` -- system-level view of the larger Wine-NSPA stack
