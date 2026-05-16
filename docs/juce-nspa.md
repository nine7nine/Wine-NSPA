# Wine-NSPA -- JUCE-NSPA

This page documents the JUCE fork that builds JUCE as a Linux winelib host for
Windows VST2 and VST3 plugins on top of Wine-NSPA.

## Table of Contents

1. [Overview](#1-overview)
2. [Why a separate fork exists](#2-why-a-separate-fork-exists)
3. [Build and runtime pivot](#3-build-and-runtime-pivot)
4. [Plugin loading and discovery](#4-plugin-loading-and-discovery)
5. [Per-instance dispatch and synchronization](#5-per-instance-dispatch-and-synchronization)
6. [Editor embedding and message pumping](#6-editor-embedding-and-message-pumping)
7. [Integration with Wine-NSPA](#7-integration-with-wine-nspa)
8. [Current scope](#8-current-scope)
9. [References](#9-references)

---

## 1. Overview

JUCE-NSPA is a JUCE fork that runs JUCE as a Linux binary while still hosting
Windows plugin binaries in-process through Wine.

The load-bearing changes are:

- winelib build support instead of a native Windows-only assumption
- PE plugin loading through Wine's `LoadLibraryW()` path
- per-instance Win32 dispatch for plugin lifecycle and audio calls
- Wine-NSPA-aware synchronization for the host-side dispatcher
- an X11 embed component that bridges JUCE peers to Wine HWND-backed editor
  windows

The point is not "JUCE on Linux" in the general sense. The point is a Linux
host process that can load Windows VST2 and VST3 modules directly and keep
their Win32 GUI and callback rules intact.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .jn-bg { fill: #1a1b26; }
    .jn-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.4; rx: 8; }
    .jn-app { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .jn-host { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .jn-plug { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .jn-note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .jn-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .jn-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .jn-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .jn-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .jn-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .jn-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .jn-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .jn-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .jn-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
    .jn-line-p { stroke: #bb9af7; stroke-width: 1.3; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="430" class="jn-bg"/>
  <text x="480" y="28" text-anchor="middle" class="jn-title">JUCE-NSPA runtime shape</text>

  <rect x="45" y="86" width="250" height="118" class="jn-app"/>
  <text x="170" y="112" text-anchor="middle" class="jn-head-g">Linux app / host UI</text>
  <text x="170" y="136" text-anchor="middle" class="jn-small">JUCE event loop, X11 peer, native app shell</text>
  <text x="170" y="152" text-anchor="middle" class="jn-small">creates `WineHWNDEmbedComponent` for editors</text>
  <text x="170" y="168" text-anchor="middle" class="jn-small">owns foreign X11 parent window</text>

  <rect x="355" y="70" width="250" height="150" class="jn-host"/>
  <text x="480" y="96" text-anchor="middle" class="jn-head-b">JUCE-NSPA winelib host</text>
  <text x="480" y="120" text-anchor="middle" class="jn-small">winegcc / wineg++ build</text>
  <text x="480" y="136" text-anchor="middle" class="jn-small">Win32 ABI shims, `LoadLibraryW()`, Win32 dispatch</text>
  <text x="480" y="152" text-anchor="middle" class="jn-small">PI-aware dispatcher and explicit message pump</text>
  <text x="480" y="168" text-anchor="middle" class="jn-small">X11 embed handoff through Wine-NSPA</text>

  <rect x="665" y="86" width="250" height="118" class="jn-plug"/>
  <text x="790" y="112" text-anchor="middle" class="jn-head-p">Windows plugin module</text>
  <text x="790" y="136" text-anchor="middle" class="jn-small">VST2 `.dll` or VST3 PE module</text>
  <text x="790" y="152" text-anchor="middle" class="jn-small">Win32 editor window and plugin callbacks</text>
  <text x="790" y="168" text-anchor="middle" class="jn-small">runs in the same Linux process through Wine</text>

  <line x1="295" y1="145" x2="355" y2="145" class="jn-line-g"/>
  <line x1="605" y1="145" x2="665" y2="145" class="jn-line-b"/>

  <rect x="190" y="282" width="580" height="84" class="jn-note"/>
  <text x="480" y="310" text-anchor="middle" class="jn-head-y">Load-bearing split</text>
  <text x="480" y="328" text-anchor="middle" class="jn-small">Linux app structure stays native, but plugin load and callback ownership</text>
  <text x="480" y="344" text-anchor="middle" class="jn-small">still follow Win32 rules inside the same process</text>
  <text x="480" y="360" text-anchor="middle" class="jn-small">Wine-NSPA supplies the embed primitive</text>
  <text x="480" y="376" text-anchor="middle" class="jn-small">and the RT-aware Win32 runtime beneath that host layer</text>
</svg>
</div>

---

## 2. Why a separate fork exists

Upstream JUCE can already build Linux hosts and Windows hosts, but it does not
provide the combined shape this stack needs:

- a Linux binary
- loading Windows VST2 and VST3 modules in-process
- keeping Win32 callback and windowing rules intact
- integrating with Wine-NSPA's X11 embed and RT-oriented runtime rules

That is why the work lives as a fork instead of a small application-side patch
set.

| Concern | Generic JUCE host assumption | JUCE-NSPA shape |
|---|---|---|
| Binary model | native Linux host or native Windows host | Linux winelib host that still drives Win32 plugin code |
| Plugin module loading | native Linux `.so` or Windows-native host side | Windows PE modules through Wine `LoadLibraryW()` |
| GUI embedding | toolkit-native child windows or native Windows HWNDs | Wine HWND-backed editor embedded under a Linux X11 peer |
| Host-side sync | generic host mutex / condvar choices | PI-aware wrappers where the winelib dispatcher layer needs Wine-NSPA-compatible behavior |

The fork therefore exists to provide a framework substrate for Linux
applications that want to host Windows plugins through Wine-NSPA without
re-solving the same low-level Win32 and X11 boundary issues.

---

## 3. Build and runtime pivot

JUCE-NSPA changes JUCE from "build a Linux host for Linux plugins" or
"build a Windows host for Windows plugins" into "build a Linux binary that
still drives Win32 plugin code in-process."

The pivot has three parts:

| Area | Current behavior |
|---|---|
| Toolchain | winelib build via `winegcc` / `wineg++` instead of a native Linux or native Windows host build |
| ABI surface | Windows-facing plugin boundaries use Win32 calling conventions where needed, including VST3 `PLUGIN_API = __stdcall` and audited VST2 `ms_abi` call sites |
| Character width and path handling | winelib-specific `WCHAR` / path helpers keep JUCE's host code aligned with Wine's 16-bit `WCHAR` and DOS-path loading model |

The fork is intentionally Linux-only. It assumes a Linux host process and a
Wine runtime underneath that process. It is not trying to stay portable to
other JUCE-supported host platforms.

---

## 4. Plugin loading and discovery

The plugin-loading surface is split by format.

### 3.1 VST3

The VST3 side loads PE plugin modules through Wine's `LoadLibraryW()` path.
That is paired with:

- bundle resolver logic that accepts single-file Windows VST3 modules
- Winelib-safe path conversion helpers
- Win32 ABI fixes in the embedded VST3 SDK host layer

### 3.2 VST2

The VST2 side adds the corresponding Windows-module assumptions:

- scanner looks for `.dll`, not `.so`
- scanner rejects non-PE candidates
- VST2 function boundaries are cast through `ms_abi` where JUCE's generic host
  layer would otherwise assume native Linux calling conventions

The point is to make the host discover and load Windows plugins directly,
instead of pretending that Linux plugin conventions still apply.

---

## 5. Per-instance dispatch and synchronization

JUCE-NSPA does not run all plugin work through one global helper thread.
Instead, the current host model is per-instance.

| Surface | Current behavior |
|---|---|
| VST3 lifecycle + audio | per-instance Win32 dispatcher |
| VST2 host plumbing | per-instance dispatcher plus shared winelib support code |
| Shared sync wrappers | vendored `PiMutex` / `PiCond` wrappers over Wine-NSPA-compatible `rtpi.h` |

Two details matter here.

### 5.1 The dispatcher is PI-aware where the host needs it

The vendored `PiMutex` / `PiCond` wrappers exist for the host-side dispatcher
and shared sync surfaces that need Wine-NSPA-compatible priority inheritance.
They are not a claim that JUCE's entire locking surface was replaced.

JUCE's own POSIX `CriticalSection` path already uses
`PTHREAD_PRIO_INHERIT` on RT builds. The dedicated `PiMutex` / `PiCond`
wrappers are for the host's winelib-facing synchronization layer, including
process-shared mode for the cases that need a shared-memory rendezvous shape.

### 5.2 The host keeps plugin instances isolated

Per-instance dispatch avoids cross-plugin queue coupling. One plugin instance's
lifecycle or audio callback work does not need to share a generic host queue
with the next instance just because both live inside the same process.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 410" xmlns="http://www.w3.org/2000/svg">
  <style>
    .pd-bg { fill: #1a1b26; }
    .pd-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.4; rx: 8; }
    .pd-inst { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .pd-sync { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .pd-plug { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .pd-note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .pd-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .pd-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .pd-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .pd-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .pd-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .pd-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .pd-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .pd-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
    .pd-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .pd-line-p { stroke: #bb9af7; stroke-width: 1.3; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="410" class="pd-bg"/>
  <text x="480" y="28" text-anchor="middle" class="pd-title">Per-instance dispatch and PI-aware sync</text>

  <rect x="70" y="96" width="230" height="100" class="pd-inst"/>
  <text x="185" y="122" text-anchor="middle" class="pd-head-b">plugin instance A</text>
  <text x="185" y="144" text-anchor="middle" class="pd-small">own Win32 dispatch lane</text>
  <text x="185" y="160" text-anchor="middle" class="pd-small">own lifecycle + audio callback ownership</text>

  <rect x="365" y="72" width="230" height="148" class="pd-sync"/>
  <text x="480" y="98" text-anchor="middle" class="pd-head-g">host sync layer</text>
  <text x="480" y="122" text-anchor="middle" class="pd-small">`PiMutex` / `PiCond` wrappers</text>
  <text x="480" y="138" text-anchor="middle" class="pd-small">process-private now, process-shared shape available</text>
  <text x="480" y="154" text-anchor="middle" class="pd-small">Wine-NSPA-compatible PI semantics</text>
  <text x="480" y="170" text-anchor="middle" class="pd-small">no single global host lock required</text>

  <rect x="660" y="96" width="230" height="100" class="pd-plug"/>
  <text x="775" y="122" text-anchor="middle" class="pd-head-p">plugin instance B</text>
  <text x="775" y="144" text-anchor="middle" class="pd-small">independent dispatch lane</text>
  <text x="775" y="160" text-anchor="middle" class="pd-small">no unrelated instance queue coupling</text>

  <line x1="300" y1="146" x2="365" y2="146" class="pd-line-b"/>
  <line x1="595" y1="146" x2="660" y2="146" class="pd-line-g"/>

  <rect x="180" y="274" width="600" height="90" class="pd-note"/>
  <text x="480" y="310" text-anchor="middle" class="pd-head-y">Why this matters</text>
  <text x="480" y="330" text-anchor="middle" class="pd-small">plugin callback ownership stays close to each instance,</text>
  <text x="480" y="346" text-anchor="middle" class="pd-small">while the host sync layer still follows Wine-NSPA PI rules where it matters</text>
</svg>
</div>

---

## 6. Editor embedding and message pumping

Editor hosting has two parts:

1. `WineHWNDEmbedComponent` creates a real Wine HWND and acquires its backing
   X11 child window
2. the component embeds that child under the JUCE peer's X11 window through
   `WM_X11DRV_NSPA_EMBED_WINDOW`

The component also owns an explicit Win32 message pump:

- `PeekMessageW()`
- `TranslateMessage()`
- `DispatchMessageW()`

That pump is required because the Linux JUCE host loop is not a native Win32
message loop, but the embedded editor HWNDs and their child windows still
expect one.

The same component also keeps screen-position tracking split correctly:

- `SetWindowPos()` updates Wine's Win32-side window rects
- `XMoveResizeWindow()` keeps the X11 child at the correct parent-relative
  location under the JUCE peer

This is what lets a Linux JUCE app host Win32 editors in-process without
falling back to a generic wrapper window or a second out-of-process GUI host.

### 6.1 `WineHWNDEmbedComponent` responsibilities

The embed component is where most of the winelib host-side GUI work lives.

| Responsibility | Current behavior |
|---|---|
| Win32 surface creation | creates a real top-level Wine HWND with `CreateWindowExW()` |
| X11 child lookup | resolves the backing `wine_x11_window` for that HWND |
| Embed handoff | sends `WM_X11DRV_NSPA_EMBED_WINDOW` to hand the child to Wine's embed path |
| Win32 pump | runs a `PeekMessageW()` / `TranslateMessage()` / `DispatchMessageW()` loop on a timer |
| Geometry sync | uses `SetWindowPos()` for Wine rects and `XMoveResizeWindow()` for host-relative X11 placement |

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 400" xmlns="http://www.w3.org/2000/svg">
  <style>
    .eh-bg { fill: #1a1b26; }
    .eh-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.4; rx: 8; }
    .eh-host { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .eh-w32 { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .eh-x11 { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .eh-note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .eh-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .eh-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .eh-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .eh-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .eh-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .eh-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .eh-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .eh-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="400" class="eh-bg"/>
  <text x="480" y="28" text-anchor="middle" class="eh-title">Embed component responsibilities</text>

  <rect x="70" y="92" width="230" height="112" class="eh-host"/>
  <text x="185" y="118" text-anchor="middle" class="eh-head-g">JUCE peer / Linux side</text>
  <text x="185" y="142" text-anchor="middle" class="eh-small">owns the foreign X11 parent</text>
  <text x="185" y="158" text-anchor="middle" class="eh-small">supplies peer-relative bounds</text>
  <text x="185" y="174" text-anchor="middle" class="eh-small">drives layout and visibility</text>

  <rect x="365" y="76" width="230" height="144" class="eh-w32"/>
  <text x="480" y="102" text-anchor="middle" class="eh-head-b">`WineHWNDEmbedComponent`</text>
  <text x="480" y="126" text-anchor="middle" class="eh-small">creates Wine HWND</text>
  <text x="480" y="142" text-anchor="middle" class="eh-small">looks up the backing X11 child</text>
  <text x="480" y="158" text-anchor="middle" class="eh-small">sends the embed message</text>
  <text x="480" y="174" text-anchor="middle" class="eh-small">pumps the Win32 queue on a timer</text>
  <text x="480" y="190" text-anchor="middle" class="eh-small">keeps Win32 and X11 geometry aligned</text>

  <rect x="660" y="92" width="230" height="112" class="eh-x11"/>
  <text x="775" y="118" text-anchor="middle" class="eh-head-p">plugin editor window</text>
  <text x="775" y="142" text-anchor="middle" class="eh-small">Win32 editor HWND</text>
  <text x="775" y="158" text-anchor="middle" class="eh-small">embedded X11 child under the JUCE peer</text>
  <text x="775" y="174" text-anchor="middle" class="eh-small">receives normal Win32 messages</text>

  <line x1="300" y1="148" x2="365" y2="148" class="eh-line-g"/>
  <line x1="595" y1="148" x2="660" y2="148" class="eh-line-b"/>

  <rect x="170" y="280" width="620" height="70" class="eh-note"/>
  <text x="480" y="308" text-anchor="middle" class="eh-head-y">Why the component exists</text>
  <text x="480" y="326" text-anchor="middle" class="eh-small">it packages the Wine HWND, the X11 embed handoff,</text>
  <text x="480" y="342" text-anchor="middle" class="eh-small">the Win32 message pump, and the dual Win32/X11 geometry sync</text>
</svg>
</div>

---

## 7. Integration with Wine-NSPA

JUCE-NSPA is not just "JUCE under Wine." It depends on specific Wine-NSPA
surfaces.

| Surface | Use in JUCE-NSPA |
|---|---|
| `WM_X11DRV_NSPA_EMBED_WINDOW` / `WM_X11DRV_NSPA_EMBED_DONE` | embeds Wine editor windows under a Linux JUCE peer without reimplementing Wine's embedded-window bookkeeping |
| Wine `LoadLibraryW()` path | loads Windows VST2 and VST3 modules in-process |
| vendored `rtpi.h` wrappers | provides `PiMutex` / `PiCond` wrappers for the host-side dispatcher layer, including a process-shared-compatible shape |
| Win32 runtime under Wine-NSPA | supplies the Win32 message queue and window semantics the embedded editor path still relies on |

This is also where the port's practical advantages come from:

- no extra out-of-process GUI bridge for editor hosting
- no separate plugin wrapper protocol just to call VST2 or VST3 entry points
- a framework-level embed and dispatch model that applications can reuse
- host-side PI wrappers that already match the rest of the Wine-NSPA stack

Those are implementation advantages, not product claims. They reduce the
amount of application-specific host code needed above the framework layer.

---

## 8. Current scope

The current JUCE-NSPA surface is:

| Area | Current behavior |
|---|---|
| Plugin formats | Windows VST2 and VST3 |
| GUI embedding | Wine HWND-backed editor windows inside Linux JUCE peers |
| Host type | Linux-only winelib host |
| Current application consumer | Element-NSPA |

JUCE-NSPA is a framework fork, not an end-user host by itself. Its public value
is that application ports can build on one Winelib + Wine-NSPA substrate
instead of re-solving the same VST loading, Win32 dispatch, and editor embed
problems separately.

---

## 9. References

- `modules/juce_gui_extra/embedding/juce_WineHWNDEmbedComponent.h`
- `modules/juce_gui_extra/native/juce_WineHWNDEmbedComponent_linux.cpp`
- `modules/juce_audio_processors_headless/format_types/juce_winelib_pi_sync.h`
- `modules/juce_audio_processors/format_types/juce_VSTPluginFormat.cpp`
- `modules/juce_audio_processors/format_types/juce_VST3PluginFormat.cpp`
- [NSPA X11 Embed Protocol](nspa-x11-embed-protocol.gen.html)
- [Element-NSPA](element-plugin-host.gen.html)
