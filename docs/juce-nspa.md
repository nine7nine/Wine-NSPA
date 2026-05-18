# Wine-NSPA -- JUCE-NSPA

This page documents the JUCE fork that builds JUCE as a Linux winelib host for
Windows VST2, VST3, and CLAP plugins on top of Wine-NSPA.

## Table of Contents

1. [Overview](#1-overview)
2. [Why a separate fork exists](#2-why-a-separate-fork-exists)
3. [Build and runtime pivot](#3-build-and-runtime-pivot)
4. [Plugin loading and discovery](#4-plugin-loading-and-discovery)
5. [Dispatch, synchronization, and async load](#5-dispatch-synchronization-and-async-load)
6. [Editor embedding and CLAP GUI ownership](#6-editor-embedding-and-clap-gui-ownership)
7. [Relationship to Wine-NSPA](#7-relationship-to-wine-nspa)
8. [Current scope](#8-current-scope)
9. [References](#9-references)

---

## 1. Overview

JUCE-NSPA is a JUCE fork that runs JUCE as a Linux binary while still hosting
Windows plugin binaries in-process through Wine.

The load-bearing changes are:

- winelib build support instead of a native Windows-only assumption
- PE plugin loading for Windows VST2, VST3, and CLAP modules
- x86_64 ABI shims where the Windows plugin boundary cannot follow the native
  Linux calling convention
- one-shot Win32 worker threads for asynchronous plugin creation under winelib
- per-instance Win32 dispatch lanes after the instance is live
- `PiMutex` / `PiCond` wrappers where the host-facing sync layer needs
  Wine-NSPA-compatible PI behavior
- `WineHWNDEmbedComponent` for VST2, VST3, and CLAP editors under a native
  Linux X11 peer

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 560" xmlns="http://www.w3.org/2000/svg">
  <style>
    .jn-bg { fill: #1a1b26; }
    .jn-lane { fill: #1f2535; stroke: #6b7398; stroke-width: 1.2; rx: 10; }
    .jn-app { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .jn-host { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .jn-plug { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .jn-sync { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .jn-note { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.6; rx: 8; }
    .jn-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .jn-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .jn-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .jn-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .jn-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .jn-head-r { fill: #f7768e; font: bold 11px 'JetBrains Mono', monospace; }
    .jn-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .jn-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .jn-line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .jn-line-b { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
    .jn-line-p { stroke: #bb9af7; stroke-width: 1.4; fill: none; }
    .jn-line-y { stroke: #e0af68; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="980" height="560" class="jn-bg"/>
  <text x="490" y="26" text-anchor="middle" class="jn-title">JUCE-NSPA: framework-level winelib substrate for Windows plugin hosting</text>

  <rect x="24" y="52" width="932" height="470" class="jn-lane"/>
  <text x="42" y="72" class="jn-small">framework responsibilities, not app-specific host policy</text>

  <rect x="44" y="94" width="250" height="160" class="jn-app"/>
  <text x="169" y="118" text-anchor="middle" class="jn-head-g">Linux host side</text>
  <text x="169" y="140" text-anchor="middle" class="jn-small">JUCE event loop, peer tree, X11 parent ownership</text>
  <text x="169" y="156" text-anchor="middle" class="jn-small">host windows stay native Linux objects</text>
  <text x="169" y="172" text-anchor="middle" class="jn-small">editor parents and bounds originate here</text>
  <text x="169" y="198" text-anchor="middle" class="jn-text">native shell stays native</text>

  <rect x="362" y="82" width="256" height="184" class="jn-host"/>
  <text x="490" y="106" text-anchor="middle" class="jn-head-b">JUCE-NSPA host substrate</text>
  <text x="490" y="128" text-anchor="middle" class="jn-small">winegcc / wineg++ build, Linux winelib process</text>
  <text x="490" y="144" text-anchor="middle" class="jn-small">PE module loading through `LoadLibraryW()`</text>
  <text x="490" y="160" text-anchor="middle" class="jn-small">VST2 `ms_abi`, VST3 `__stdcall`, CLAP `CLAP_ABI` shim</text>
  <text x="490" y="176" text-anchor="middle" class="jn-small">one-shot `CreateThread` load worker + per-instance dispatch</text>
  <text x="490" y="192" text-anchor="middle" class="jn-small">`PiMutex` / `PiCond` wrappers + `WineHWNDEmbedComponent`</text>
  <text x="490" y="218" text-anchor="middle" class="jn-text">framework-level Win32 ownership lives here</text>

  <rect x="686" y="94" width="250" height="160" class="jn-plug"/>
  <text x="811" y="118" text-anchor="middle" class="jn-head-p">Windows plugin side</text>
  <text x="811" y="140" text-anchor="middle" class="jn-small">VST2 `.dll`, VST3 PE module, CLAP `.clap` PE DLL</text>
  <text x="811" y="156" text-anchor="middle" class="jn-small">Win32 editor HWNDs and child windows</text>
  <text x="811" y="172" text-anchor="middle" class="jn-small">plugin callbacks still observe Win32 rules</text>
  <text x="811" y="198" text-anchor="middle" class="jn-text">same process, Wine-backed code</text>

  <rect x="126" y="318" width="728" height="126" class="jn-sync"/>
  <text x="490" y="342" text-anchor="middle" class="jn-head-y">Editor embed and thread ownership</text>
  <text x="490" y="366" text-anchor="middle" class="jn-small">`WineHWNDEmbedComponent` creates a real Wine HWND, resolves `wine_x11_window`,</text>
  <text x="490" y="382" text-anchor="middle" class="jn-small">sends `WM_X11DRV_NSPA_EMBED_WINDOW`, and pumps Win32 messages on a timer</text>
  <text x="490" y="398" text-anchor="middle" class="jn-small">CLAP editor setup runs directly on the JUCE message thread to avoid deadlock</text>
  <text x="490" y="414" text-anchor="middle" class="jn-small">with the same Win32 pump that must service `set_parent()` and `show()`</text>
  <text x="490" y="430" text-anchor="middle" class="jn-text">framework owns the Linux/X11 <-> Win32/HWND seam</text>

  <rect x="166" y="468" width="648" height="36" class="jn-note"/>
  <text x="490" y="491" text-anchor="middle" class="jn-head-r">Scope</text>
  <text x="490" y="505" text-anchor="middle" class="jn-small">Linux host structure stays native, but plugin load, editor HWNDs,</text>
  <text x="490" y="519" text-anchor="middle" class="jn-small">and callback ABI still follow Win32 rules inside the same process</text>

  <line x1="294" y1="176" x2="362" y2="176" class="jn-line-g"/>
  <line x1="618" y1="176" x2="686" y2="176" class="jn-line-b"/>
  <path d="M490 266 L490 318" class="jn-line-y"/>
</svg>
</div>

JUCE-NSPA is framework infrastructure. It exists so application ports can reuse
one host substrate instead of re-solving Win32 load, thread, and embed rules
per application.

---

## 2. Why a separate fork exists

Upstream JUCE already supports Linux hosts and Windows hosts, but it does not
provide the combined shape this stack needs:

- a Linux binary
- loading Windows VST2, VST3, and CLAP modules in-process
- keeping Win32 callback, TLS, and windowing rules intact
- integrating with Wine-NSPA's embed and RT-oriented synchronization rules

That is why this work lives as a fork instead of an application-side patch set.

| Concern | Generic JUCE host assumption | JUCE-NSPA shape |
|---|---|---|
| Binary model | native Linux host or native Windows host | Linux winelib host that still drives Win32 plugin code |
| Plugin module loading | native Linux `.so` or Windows-native host side | Windows PE modules through Wine `LoadLibraryW()` |
| Format surface | VST2/VST3 plus native-Linux assumptions | Windows VST2, VST3, and CLAP only |
| GUI embedding | toolkit-native child windows or native Windows HWNDs | Wine HWND-backed editor embedded under a Linux X11 peer |
| Threading model | generic async worker or message-thread deferred sync load | Win32-registered worker for plugin creation, then per-instance dispatch |
| Host-side sync | generic host mutex / condvar choices | PI-aware wrappers where the winelib dispatcher layer needs Wine-NSPA-compatible behavior |

The fork therefore provides a framework substrate for Linux applications that
want to host Windows plugins through Wine-NSPA without solving the same ABI,
thread-registration, and X11-embed issues independently.

---

## 3. Build and runtime pivot

JUCE-NSPA changes JUCE from "build a Linux host for Linux plugins" or
"build a Windows host for Windows plugins" into "build a Linux binary that
still drives Win32 plugin code in-process."

The pivot has three parts:

| Area | Current behavior |
|---|---|
| Toolchain | winelib build via `winegcc` / `wineg++` instead of a native Linux or native Windows host build |
| ABI surface | Windows-facing plugin boundaries use Win32 calling conventions where needed, including VST3 `PLUGIN_API = __stdcall`, audited VST2 `ms_abi` call sites, and CLAP `CLAP_ABI` under winelib x86_64 |
| Runtime assumptions | Wine provides the PE loader, Win32 thread state, and HWND/message model inside a Linux process |

The fork is intentionally Linux-only and x86_64-only. That is not just build
policy. The host shape depends on Wine's Linux winelib runtime, and the current
CLAP/VST ABI shims are specifically authored for the x86_64 Win32 boundary.

---

## 4. Plugin loading and discovery

The plugin-loading surface is split by format.

| Format | Current behavior |
|---|---|
| VST3 | loads single-file Windows PE modules through Wine `LoadLibraryW()` with Winelib-safe VST3 host fixes |
| VST2 | scans `.dll`, rejects non-PE candidates, and routes entry points through audited `ms_abi` call sites |
| CLAP | hosts Windows `.clap` PE DLLs through a dedicated CLAP format stack; there is no native-Linux `.so` CLAP path in this fork |

### 4.1 VST3

The VST3 side loads PE plugin modules through Wine's `LoadLibraryW()` path.
That is paired with:

- bundle resolver logic that accepts single-file Windows VST3 modules
- Winelib-safe path conversion helpers
- Win32 ABI fixes in the embedded VST3 SDK host layer

### 4.2 VST2

The VST2 side adds the corresponding Windows-module assumptions:

- scanner looks for `.dll`, not `.so`
- scanner rejects non-PE candidates
- VST2 function boundaries are cast through `ms_abi` where JUCE's generic host
  layer would otherwise assume the native Linux calling convention

### 4.3 CLAP

The CLAP side adds a third Windows plugin format to the same winelib host
substrate.

The current implementation is split in two:

- `CLAPPluginFormatHeadless` in `juce_audio_processors_headless`
- `CLAPPluginFormat` in `juce_audio_processors` for GUI/editor support

Important details:

- JUCE-NSPA vendors CLAP 1.2.0 headers into the tree
- the fork adds a winelib `CLAP_ABI` shim on x86_64 so host/plugin callbacks
  follow the Windows ABI instead of native SysV
- `JUCE_PLUGINHOST_CLAP` gates the format wiring
- the format only accepts Windows `.clap` PE DLLs; there is no Linux `.so`
  CLAP loader path here

The headless CLAP implementation already covers the load-bearing runtime
surfaces:

- module/factory enumeration
- instance lifecycle
- note-port probing at activate time
- transport injection from JUCE `AudioPlayHead`
- input MIDI translation into CLAP note or MIDI events
- output MIDI translation back into JUCE `MidiBuffer`

`acceptsMidi()` and `producesMidi()` are derived from the plugin's note-port
shape, not hardcoded.

### 4.4 CLAP event and transport bridge

The CLAP audio path does more than just "call process."

At block time:

1. JUCE `MidiBuffer` events are translated into CLAP events.
2. The bridge picks note encoding from the first input port's preferred
   dialect:
   - CLAP note dialect -> `CLAP_EVENT_NOTE_ON/OFF`
   - MIDI / MIDI-MPE dialect -> `CLAP_EVENT_MIDI`
3. `fillTransportFromPlayHead()` builds `clap_event_transport_t` from JUCE's
   `AudioPlayHead`.
4. Plugin output events are translated back into JUCE MIDI after `process()`
   returns.

Current output translation covers:

- note on / note off
- raw 3-byte MIDI

Current accepted-but-skipped surfaces include:

- parameter events
- note-expression events
- MIDI 2
- sysex

Those are omitted because they do not fit JUCE's `MidiBuffer` model directly.

---

## 5. Dispatch, synchronization, and async load

JUCE-NSPA does not run all plugin work through one global helper thread.
Instead, the current host model is per-instance after creation succeeds.

| Surface | Current behavior |
|---|---|
| VST3 lifecycle + audio | per-instance Win32 dispatcher |
| VST2 host plumbing | per-instance dispatcher plus shared winelib support code |
| CLAP lifecycle + audio | per-instance dispatcher, with CLAP main-thread and audio-thread roles tracked explicitly |
| Shared sync wrappers | vendored `PiMutex` / `PiCond` wrappers over Wine-NSPA-compatible `rtpi.h` |
| Async plugin creation | one-shot Wine `CreateThread` worker, callback returned to the JUCE message thread |

### 5.1 PI-aware sync where the host needs it

The vendored `PiMutex` / `PiCond` wrappers exist for the host-side dispatcher
and shared sync surfaces that need Wine-NSPA-compatible priority inheritance.
They are not a claim that JUCE's entire locking surface was replaced.

JUCE's own POSIX `CriticalSection` path already uses
`PTHREAD_PRIO_INHERIT` on RT builds. The dedicated `PiMutex` / `PiCond`
wrappers are for the host's winelib-facing synchronization layer, including
process-shared mode for the cases that need a shared-memory rendezvous shape.

### 5.2 Async load must use a Win32-registered thread

Under winelib, asynchronous plugin creation cannot use a plain pthread worker.

The reason is architectural:

- `LoadLibraryW()` and PE module initialization need Wine-owned thread state
- Wine's loader, SEH, and TEB assumptions are not satisfied by an arbitrary
  `std::thread` / pthread worker
- a plain pthread worker can crash in PE initialization because Wine does not
  own the thread's Win32 registration state

So JUCE-NSPA changes `createPluginInstanceAsync()` to:

1. spawn a one-shot worker with Wine `CreateThread`
2. run synchronous `createPluginInstance()` on that worker
3. hop the completion callback back to the JUCE message thread via
   `MessageManager::callAsync`

That keeps the documented JUCE callback contract intact while moving the actual
plugin load off the message thread.

### 5.3 Per-instance ownership stays isolated

Per-instance dispatch avoids cross-plugin queue coupling. One plugin instance's
lifecycle or audio callback work does not need to share a generic host queue
with the next instance just because both live inside the same process.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 440" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ad-bg { fill: #1a1b26; }
    .ad-host { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .ad-load { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .ad-inst { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .ad-sync { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .ad-note { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.6; rx: 8; }
    .ad-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .ad-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .ad-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .ad-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .ad-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .ad-head-r { fill: #f7768e; font: bold 11px 'JetBrains Mono', monospace; }
    .ad-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .ad-line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .ad-line-b { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
    .ad-line-p { stroke: #bb9af7; stroke-width: 1.4; fill: none; }
    .ad-line-y { stroke: #e0af68; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="980" height="440" class="ad-bg"/>
  <text x="490" y="28" text-anchor="middle" class="ad-title">Async creation on a Win32 worker, then per-instance dispatch</text>

  <rect x="46" y="104" width="210" height="112" class="ad-host"/>
  <text x="151" y="130" text-anchor="middle" class="ad-head-g">JUCE message thread</text>
  <text x="151" y="154" text-anchor="middle" class="ad-small">host requests async create</text>
  <text x="151" y="170" text-anchor="middle" class="ad-small">does not block UI while module loads</text>
  <text x="151" y="186" text-anchor="middle" class="ad-small">completion callback returns here</text>

  <rect x="308" y="80" width="182" height="160" class="ad-load"/>
  <text x="399" y="106" text-anchor="middle" class="ad-head-b">one-shot load worker</text>
  <text x="399" y="130" text-anchor="middle" class="ad-small">Wine `CreateThread`</text>
  <text x="399" y="146" text-anchor="middle" class="ad-small">valid TEB / SEH / loader state</text>
  <text x="399" y="162" text-anchor="middle" class="ad-small">runs `createPluginInstance()`</text>
  <text x="399" y="178" text-anchor="middle" class="ad-small">safe place for `LoadLibraryW()`</text>

  <rect x="544" y="80" width="182" height="160" class="ad-sync"/>
  <text x="635" y="106" text-anchor="middle" class="ad-head-y">shared host sync layer</text>
  <text x="635" y="130" text-anchor="middle" class="ad-small">`PiMutex` / `PiCond` wrappers</text>
  <text x="635" y="146" text-anchor="middle" class="ad-small">used where host-facing sync</text>
  <text x="635" y="162" text-anchor="middle" class="ad-small">needs Wine-NSPA PI behavior</text>

  <rect x="780" y="104" width="154" height="112" class="ad-inst"/>
  <text x="857" y="130" text-anchor="middle" class="ad-head-p">live instance</text>
  <text x="857" y="154" text-anchor="middle" class="ad-small">VST2 / VST3 / CLAP</text>
  <text x="857" y="170" text-anchor="middle" class="ad-small">owns its own Win32 lane</text>
  <text x="857" y="186" text-anchor="middle" class="ad-small">no global plugin queue</text>

  <rect x="194" y="296" width="592" height="72" class="ad-note"/>
  <text x="490" y="322" text-anchor="middle" class="ad-head-r">Why the split exists</text>
  <text x="490" y="340" text-anchor="middle" class="ad-small">plugin creation needs Wine-owned thread registration; steady-state callbacks</text>
  <text x="490" y="356" text-anchor="middle" class="ad-small">need per-instance ownership instead of one shared host queue</text>

  <line x1="256" y1="160" x2="308" y2="160" class="ad-line-g"/>
  <line x1="490" y1="160" x2="544" y2="160" class="ad-line-b"/>
  <line x1="726" y1="160" x2="780" y2="160" class="ad-line-y"/>
  <path d="M399 240 L399 296" class="ad-line-b"/>
  <path d="M857 216 L857 296" class="ad-line-p"/>
</svg>
</div>

---

## 6. Editor embedding and CLAP GUI ownership

Editor hosting has two parts:

1. `WineHWNDEmbedComponent` creates a real Wine HWND and acquires its backing
   X11 child window
2. the component embeds that child under the JUCE peer's X11 window through
   `WM_X11DRV_NSPA_EMBED_WINDOW`

The completion edge is explicit: Wine posts
`WM_X11DRV_NSPA_EMBED_DONE` back to the same HWND after the embed handshake has
reparented, mapped, and settled its WM state.

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

### 6.1 `WineHWNDEmbedComponent` responsibilities

| Responsibility | Current behavior |
|---|---|
| Win32 surface creation | creates a real top-level Wine HWND with `CreateWindowExW()` |
| X11 child lookup | resolves the backing `wine_x11_window` for that HWND |
| Embed handoff | sends `WM_X11DRV_NSPA_EMBED_WINDOW` to hand the child to Wine's embed path |
| Completion fence | handles `WM_X11DRV_NSPA_EMBED_DONE` if the host wants a deterministic "embed settled" point |
| Win32 pump | runs a `PeekMessageW()` / `TranslateMessage()` / `DispatchMessageW()` loop on a timer |
| Geometry sync | uses `SetWindowPos()` for Wine rects and `XMoveResizeWindow()` for host-relative X11 placement |

### 6.2 CLAP GUI calls stay on the JUCE message thread

The CLAP editor path uses the same embed substrate, but it adds one important
threading rule: the `clap.gui` lifecycle calls are performed directly on the
JUCE message thread.

That is deliberate. Routing them through the per-instance dispatcher would
deadlock the same thread that must keep the Win32 pump alive for `set_parent()`
and `show()`.

Current CLAP editor setup:

1. resolve `clap.gui` on the plugin's main thread
2. `is_api_supported(CLAP_WINDOW_API_WIN32, false)`
3. `create(CLAP_WINDOW_API_WIN32, false)`
4. `get_size()`
5. create and show `WineHWNDEmbedComponent`
6. `set_parent()` with the embed component's Wine HWND
7. `show()`
8. drive plugin-requested resize/close through a 30 Hz timer

Teardown is symmetrical: `hide()` then `destroy()` on the same JUCE message
thread, while `WineHWNDEmbedComponent` handles the deferred X11-side cleanup.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 470" xmlns="http://www.w3.org/2000/svg">
  <style>
    .cg-bg { fill: #1a1b26; }
    .cg-host { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .cg-msg { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .cg-wine { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .cg-plug { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .cg-note { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.6; rx: 8; }
    .cg-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .cg-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .cg-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .cg-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .cg-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .cg-head-r { fill: #f7768e; font: bold 11px 'JetBrains Mono', monospace; }
    .cg-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .cg-line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .cg-line-y { stroke: #e0af68; stroke-width: 1.4; fill: none; }
    .cg-line-b { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="980" height="470" class="cg-bg"/>
  <text x="490" y="26" text-anchor="middle" class="cg-title">CLAP editor handshake on the JUCE message thread</text>

  <rect x="48" y="82" width="220" height="250" class="cg-host"/>
  <text x="158" y="106" text-anchor="middle" class="cg-head-g">JUCE message thread</text>
  <text x="158" y="132" text-anchor="middle" class="cg-small">1. resolve `clap.gui`</text>
  <text x="158" y="148" text-anchor="middle" class="cg-small">2. `is_api_supported(WIN32)`</text>
  <text x="158" y="164" text-anchor="middle" class="cg-small">3. `create(WIN32)`</text>
  <text x="158" y="180" text-anchor="middle" class="cg-small">4. `get_size()`</text>
  <text x="158" y="196" text-anchor="middle" class="cg-small">5. add embed component</text>
  <text x="158" y="212" text-anchor="middle" class="cg-small">6. `set_parent(hwnd)`</text>
  <text x="158" y="228" text-anchor="middle" class="cg-small">7. `show()`</text>

  <rect x="304" y="82" width="184" height="250" class="cg-msg"/>
  <text x="396" y="106" text-anchor="middle" class="cg-head-y">Embed component</text>
  <text x="396" y="132" text-anchor="middle" class="cg-small">creates Wine HWND</text>
  <text x="396" y="148" text-anchor="middle" class="cg-small">resolves `wine_x11_window`</text>
  <text x="396" y="164" text-anchor="middle" class="cg-small">sends `EMBED_WINDOW`</text>
  <text x="396" y="180" text-anchor="middle" class="cg-small">pumps Win32 messages</text>
  <text x="396" y="196" text-anchor="middle" class="cg-small">tracks `EMBED_DONE`</text>
  <text x="396" y="212" text-anchor="middle" class="cg-small">timer also drives resize sync</text>

  <rect x="522" y="82" width="184" height="250" class="cg-wine"/>
  <text x="614" y="106" text-anchor="middle" class="cg-head-b">Wine embed path</text>
  <text x="614" y="132" text-anchor="middle" class="cg-small">reparents X11 child</text>
  <text x="614" y="148" text-anchor="middle" class="cg-small">settles embedded WM state</text>
  <text x="614" y="164" text-anchor="middle" class="cg-small">keeps Win32 rects authoritative</text>
  <text x="614" y="180" text-anchor="middle" class="cg-small">posts `EMBED_DONE`</text>

  <rect x="740" y="82" width="192" height="250" class="cg-plug"/>
  <text x="836" y="106" text-anchor="middle" class="cg-head-p">CLAP plugin GUI</text>
  <text x="836" y="132" text-anchor="middle" class="cg-small">Win32 parent API only</text>
  <text x="836" y="148" text-anchor="middle" class="cg-small">plugin-requested resizes land in atomics</text>
  <text x="836" y="164" text-anchor="middle" class="cg-small">30 Hz timer applies them to the host</text>
  <text x="836" y="180" text-anchor="middle" class="cg-small">plugin-close request closes the editor window</text>

  <rect x="170" y="370" width="640" height="68" class="cg-note"/>
  <text x="490" y="396" text-anchor="middle" class="cg-head-r">Why this stays on one thread</text>
  <text x="490" y="414" text-anchor="middle" class="cg-small">`set_parent()` and `show()` need the same message-thread pump that services</text>
  <text x="490" y="430" text-anchor="middle" class="cg-small">the embedded Wine HWND, so dispatcher-hopping would block the wrong thread</text>

  <line x1="268" y1="178" x2="304" y2="178" class="cg-line-g"/>
  <line x1="488" y1="178" x2="522" y2="178" class="cg-line-y"/>
  <line x1="706" y1="178" x2="740" y2="178" class="cg-line-b"/>
</svg>
</div>

---

## 7. Relationship to Wine-NSPA

JUCE-NSPA depends on specific Wine-NSPA surfaces.

| Surface | Use in JUCE-NSPA |
|---|---|
| `WM_X11DRV_NSPA_EMBED_WINDOW` / `WM_X11DRV_NSPA_EMBED_DONE` | embeds Wine editor windows under a Linux JUCE peer without reimplementing Wine's embedded-window bookkeeping |
| Wine `LoadLibraryW()` path | loads Windows VST2, VST3, and CLAP modules in-process |
| Wine `CreateThread` path | gives async plugin creation a Win32-registered worker thread with valid TEB/SEH/loader state |
| vendored `rtpi.h` wrappers | provides `PiMutex` / `PiCond` wrappers for the host-side dispatcher layer, including a process-shared-compatible shape |
| Win32 runtime under Wine-NSPA | supplies the Win32 message queue and window semantics the embedded editor path still relies on |

JUCE-NSPA is therefore not a generic Wine wrapper layer. It is a framework
fork written around Wine-NSPA's specific load, thread, sync, and embed rules.

---

## 8. Current scope

| Area | Current behavior |
|---|---|
| Host architecture | Linux-only x86_64 winelib host |
| Plugin formats | Windows VST2, VST3, and CLAP |
| Async instantiation | one-shot Wine `CreateThread` worker, callback returned to the JUCE message thread |
| GUI embedding | Wine HWND-backed editor windows inside Linux JUCE peers |
| Current application consumer | Element-NSPA |

JUCE-NSPA is a framework fork, not an end-user host by itself. Its value is
that application ports can build on one winelib + Wine-NSPA substrate instead
of re-solving the same module load, Win32 dispatch, and editor embed problems
separately.

---

## 9. References

- `modules/juce_audio_processors_headless/format/juce_AudioPluginFormat.cpp`
- `modules/juce_audio_processors_headless/format_types/juce_CLAPPluginFormatHeadless.h`
- `modules/juce_audio_processors_headless/format_types/juce_CLAPPluginFormatImpl.h`
- `modules/juce_audio_processors_headless/format_types/clap/juce_clap_winelib_abi.h`
- `modules/juce_audio_processors/format_types/juce_CLAPPluginFormat.cpp`
- `modules/juce_audio_processors/format_types/juce_VSTPluginFormat.cpp`
- `modules/juce_audio_processors/format_types/juce_VST3PluginFormat.cpp`
- `modules/juce_audio_processors_headless/format_types/juce_winelib_pi_sync.h`
- `modules/juce_gui_extra/embedding/juce_WineHWNDEmbedComponent.h`
- `modules/juce_gui_extra/native/juce_WineHWNDEmbedComponent_linux.cpp`
- [NSPA X11 Embed Protocol](nspa-x11-embed-protocol.gen.html)
- [Element-NSPA](element-plugin-host.gen.html)
