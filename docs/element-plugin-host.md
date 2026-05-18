# Wine-NSPA -- Element-NSPA

This page documents the Element application port that hosts Windows VST2, VST3,
and CLAP plugins through JUCE-NSPA and Wine-NSPA while using JACK as the native
audio and MIDI transport.

## Table of Contents

1. [Overview](#1-overview)
2. [Why a separate port exists](#2-why-a-separate-port-exists)
3. [Host bootstrap](#3-host-bootstrap)
4. [Plugin surface and scan policy](#4-plugin-surface-and-scan-policy)
5. [JACK-first audio and MIDI graph path](#5-jack-first-audio-and-midi-graph-path)
6. [Editor, dialogs, and UI layer](#6-editor-dialogs-and-ui-layer)
7. [Relationship to JUCE-NSPA and Wine-NSPA](#7-relationship-to-juce-nspa-and-wine-nspa)
8. [Current scope](#8-current-scope)
9. [References](#9-references)

---

## 1. Overview

Element-NSPA is a Linux winelib build of Element that hosts Windows plugins
in-process through Wine. It is not just "Element built with a different
compiler." The port changes the runtime contract at four surfaces:

- Windows plugin format selection and scan policy
- asynchronous plugin instantiation under winelib
- embedded Win32 editor and dialog behavior inside a native Linux UI tree
- JACK-first audio and MIDI routing inside the graph itself

The current application layer is also retuned for the same host model:

- the main window runs under one GL-backed shell
- internal file choosers replace native OS dialog assumptions under winelib
- the graph and mixer surfaces use per-node-type accents so Windows plugin
  formats and JACK-native nodes are legible inside the same graph

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 560" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ov-bg { fill: #1a1b26; }
    .ov-lane { fill: #1f2535; stroke: #6b7398; stroke-width: 1.2; rx: 10; }
    .ov-native { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .ov-host { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .ov-plugin { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .ov-jack { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .ov-note { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.6; rx: 8; }
    .ov-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .ov-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .ov-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .ov-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .ov-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .ov-head-r { fill: #f7768e; font: bold 11px 'JetBrains Mono', monospace; }
    .ov-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .ov-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .ov-line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .ov-line-b { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
    .ov-line-p { stroke: #bb9af7; stroke-width: 1.4; fill: none; }
    .ov-line-y { stroke: #e0af68; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="980" height="560" class="ov-bg"/>
  <text x="490" y="26" text-anchor="middle" class="ov-title">Element-NSPA: application policy on top of JUCE-NSPA, Wine-NSPA, and JACK</text>

  <rect x="24" y="52" width="932" height="468" class="ov-lane"/>
  <text x="42" y="72" class="ov-small">single Linux process, mixed native + Wine-backed responsibilities</text>

  <rect x="46" y="94" width="250" height="158" class="ov-native"/>
  <text x="171" y="118" text-anchor="middle" class="ov-head-g">Element application layer</text>
  <text x="171" y="140" text-anchor="middle" class="ov-small">plugin manager, graph editor, session shell</text>
  <text x="171" y="156" text-anchor="middle" class="ov-small">GL-backed main window + dark UI baseline</text>
  <text x="171" y="172" text-anchor="middle" class="ov-small">internal file choosers embedded on the main window</text>
  <text x="171" y="188" text-anchor="middle" class="ov-small">node-type accents for Audio I/O, JACK MIDI, VST2, VST3, CLAP</text>
  <text x="171" y="214" text-anchor="middle" class="ov-text">application policy lives here</text>

  <rect x="364" y="82" width="252" height="182" class="ov-host"/>
  <text x="490" y="106" text-anchor="middle" class="ov-head-b">JUCE-NSPA / winelib host substrate</text>
  <text x="490" y="128" text-anchor="middle" class="ov-small">winegcc / wineg++ build, PE module loading</text>
  <text x="490" y="144" text-anchor="middle" class="ov-small">VST2, VST3, and CLAP host formats</text>
  <text x="490" y="160" text-anchor="middle" class="ov-small">Win32 ABI fixes, `LoadLibraryW()`, `CreateThread` async load</text>
  <text x="490" y="176" text-anchor="middle" class="ov-small">`WineHWNDEmbedComponent` + Win32 pump</text>
  <text x="490" y="202" text-anchor="middle" class="ov-text">framework layer reused by the app</text>

  <rect x="684" y="94" width="250" height="158" class="ov-plugin"/>
  <text x="809" y="118" text-anchor="middle" class="ov-head-p">Windows plugins</text>
  <text x="809" y="140" text-anchor="middle" class="ov-small">VST2 `.dll`, VST3 PE module, CLAP `.clap` PE DLL</text>
  <text x="809" y="156" text-anchor="middle" class="ov-small">editor HWNDs embedded under Linux peers</text>
  <text x="809" y="172" text-anchor="middle" class="ov-small">Win32 message flow and plugin callbacks stay intact</text>
  <text x="809" y="198" text-anchor="middle" class="ov-text">loaded in-process through Wine</text>

  <rect x="46" y="308" width="888" height="128" class="ov-jack"/>
  <text x="490" y="334" text-anchor="middle" class="ov-head-y">JACK-first audio and MIDI engine</text>
  <text x="490" y="356" text-anchor="middle" class="ov-small">JACK is the sole Linux audio + MIDI transport in this build</text>
  <text x="490" y="372" text-anchor="middle" class="ov-small">sample-accurate MIDI ingress lands in combined and per-port buffers</text>
  <text x="490" y="388" text-anchor="middle" class="ov-small">`JackMidiInputNode` / `JackMidiOutputNode` and `(...All)` nodes expose that routing</text>
  <text x="490" y="404" text-anchor="middle" class="ov-small">outbound MIDI writes go directly to the current JACK period's port buffers</text>
  <text x="490" y="430" text-anchor="middle" class="ov-text">audio and native MIDI live on the same timing surface</text>

  <rect x="110" y="454" width="760" height="46" class="ov-note"/>
  <text x="490" y="482" text-anchor="middle" class="ov-head-r">Result</text>
  <text x="490" y="498" text-anchor="middle" class="ov-small">Windows plugin hosting, native JACK routing, and the Linux application shell</text>
  <text x="490" y="512" text-anchor="middle" class="ov-small">share one process, but each layer keeps a distinct ownership boundary</text>

  <line x1="296" y1="174" x2="364" y2="174" class="ov-line-g"/>
  <line x1="616" y1="174" x2="684" y2="174" class="ov-line-b"/>
  <path d="M171 252 L171 308" class="ov-line-g"/>
  <path d="M490 264 L490 308" class="ov-line-b"/>
  <path d="M809 252 L809 308" class="ov-line-p"/>
</svg>
</div>

---

## 2. Why a separate port exists

Upstream Element is not designed around a Linux winelib host for Windows
plugins. The application layer still has to make decisions that are more
specific than the JUCE framework layer:

- which plugin formats belong in this process
- how scan paths should be derived from `WINEPREFIX`
- how early the host has to bootstrap wineserver, COM, and Win32 process-class
  state
- how plugin editor windows and file choosers should behave once the app is a
  Linux shell wrapped around Wine-hosted plugin state
- how JACK MIDI should be treated in the graph when the primary target is a
  low-latency JACK workflow

That is why this is an application port, not just "JUCE-NSPA plus a build
file."

| Concern | Generic Element assumption | Element-NSPA shape |
|---|---|---|
| Plugin target | native Linux formats plus platform-native host formats | Windows VST2, VST3, and CLAP through winelib + Wine |
| Scan defaults | native host defaults | Wine-prefix VST/VST3/CLAP directories are part of the default scan surface |
| Runtime bootstrap | native app bootstrap | wineserver pre-warm plus Win32 process-class and OLE init before plugin load |
| Editor hosting | native plugin editor assumptions | embedded Wine HWND-backed editor windows in the Linux UI |
| Dialog model | native or OS-host file choosers | JUCE-internal choosers embedded on the main window |
| MIDI shape on JACK builds | generic Linux MIDI backends | JACK-first native MIDI ports and graph nodes; ALSA is disabled |

---

## 3. Host bootstrap

Element performs winelib host initialization before plugin code gets a chance
to run static constructors.

The current bootstrap does three things:

1. ensure a wineserver socket exists, spawning `wineserver -p` if needed
2. `SetPriorityClass(GetCurrentProcess(), REALTIME_PRIORITY_CLASS)`
3. `OleInitialize(nullptr)`

The order matters.

- wineserver must exist before the first Win32 call
- process-class promotion happens before `OleInitialize()` so any helper
  threads spawned during COM or plugin initialization inherit the intended
  Win32 priority class
- plugin code then sees a valid OLE environment and the correct Wine-NSPA
  priority mapping before its own initialization tree starts

The wineserver pre-warm is a host-side defensive step. It avoids a cold-start
window where the first Wine client in Element's process tree can race an
uninitialized wineserver.

---

## 4. Plugin surface and scan policy

The Element port narrows its plugin surface to the Windows formats that make
sense inside this winelib host.

| Area | Current behavior |
|---|---|
| VST3 | enabled |
| VST2 | enabled, using the system Steinberg VST2 SDK 2.4 |
| CLAP | enabled under `__WINE__` through JUCE-NSPA `CLAPPluginFormat` |
| LV2 | not registered under `__WINE__` |
| LADSPA | not registered under `__WINE__` |

The LV2 and LADSPA exclusions are deliberate. They are Linux-native plugin
formats, and loading them inside the same winelib process would pull unrelated
native plugin trees and their copies of framework globals into the same address
space. For this host, that is the wrong process boundary.

### 4.1 Wine-prefix path discovery

Element augments default scan paths with Windows-plugin directories inside
`WINEPREFIX`.

Current additions are:

- `drive_c/Program Files/Common Files/VST2`
- `drive_c/Program Files/Steinberg/VstPlugins`
- `drive_c/Program Files/Common Files/VST`
- `drive_c/Program Files/Common Files/VST3`
- `drive_c/Program Files/Common Files/CLAP`
- `drive_c/users/<user>/AppData/Local/Programs/Common/CLAP`

The 32-bit `Program Files (x86)` paths are intentionally not added. This host
is x86_64 winelib, so 32-bit plugin DLLs are not loadable here and would only
pollute scan results with permanently broken entries.

### 4.2 CLAP registration under winelib

Under `__WINE__`, Element uses JUCE-NSPA's CLAP host format instead of
Element's native Linux CLAP provider.

That split exists to avoid double registration:

- native Linux CLAP remains the right path for a native Linux Element build
- winelib Element wants Windows `.clap` PE DLLs through Wine `LoadLibraryW()`
- the winelib build therefore registers `CLAPPluginFormat` and gates off the
  native `CLAPProvider`

The current CLAP scan path is also in-process under winelib. The scanner-worker
IPC used for other formats is not yet reliable enough for the Winegcc CLAP
path, so CLAP file enumeration and factory probing stay in the main process.

### 4.3 Asynchronous instantiation

Interactive plugin add is no longer a message-thread synchronous load.

Current shape:

1. Element requests `createGraphNodeAsync`
2. JUCE-NSPA uses its winelib `CreateThread` worker to perform plugin creation
3. completion returns to the message thread
4. Element finalizes the new node in two pieces:
   - message-thread metadata and `resetPorts()`
   - worker-thread block-hiding/property shaping before attachment

That keeps the UI responsive while large plugin descriptors and port lists are
being materialized.

---

## 5. JACK-first audio and MIDI graph path

The current Element JACK MIDI implementation is a live part of the host model.
This Linux build disables ALSA and uses JACK as the native audio and MIDI
transport.

### 5.1 Timing and data path

`JackAudioIODevice::process()` is the timing authority. JACK ingress, Element's
audio callback, graph MIDI consumption, and outbound MIDI emission all happen on
that same callback thread.

Current inbound shape:

1. `jack_midi_event_get()` reads events from each enabled `midi_in_N` port
2. Element writes those events into:
   - `currentPeriodMidiInput` for the graph-wide JACK MIDI ingress
   - `currentPeriodMidiInputPerPort[N]` for explicit per-port routing
3. each event keeps `jack_midi_event_t::time` as its sample offset within the
   current JACK period
4. `AudioEngine` merges the combined buffer into the graph's top-level
   `MidiBuffer`
5. `JackMidiInputNode` reads one per-port buffer directly on that same RT
   thread
6. `MidiEngine` callbacks also see the same JACK-period events

Current outbound shape:

1. the JACK process callback clears and caches every enabled `midi_out_N`
   port buffer before the graph runs
2. `JackMidiOutputNode` and `JackMidiOutputAllNode` call
   `writeJackMidiOutput()`
3. `writeJackMidiOutput()` writes directly to libjack with the caller's sample
   offset for the current period
4. `consumeMidiOutputActivity()` reports whether any output write landed during
   that period, which drives the UI Tx indicator

So the current contract is:

- same-period input
- same-period output
- sample offsets preserved in both directions
- no helper-thread hop
- no ringbuffer period delay on the normal output path

### 5.2 Graph exposure and routing

The host exposes JACK MIDI as actual graph topology instead of a hidden device
side effect.

| Surface | Current behavior |
|---|---|
| Port counts | audio and MIDI both use the same Auto / 2 / 4 / 8 / 16 / 32 shape |
| Input exposure | graph-wide combined JACK MIDI input plus one `JackMidiInputNode` per configured port |
| Output exposure | one `JackMidiOutputNode` per configured `midi_out_N` port plus `JackMidiOutputAllNode` |
| Port enable state | input/output enable masks are atomically read once per JACK period |
| Graph UI | right-click menus expose live `midi_in_N` / `midi_out_N` node insertion |
| Legacy Graph I/O MIDI pseudo-nodes | hidden on JACK builds because JACK MIDI nodes are the real routing surface |

`JackMidiInputNode` also has one focused extra behavior: it can optionally
translate inbound MIDI Program Change into a message-thread
`setCurrentProgram()` walk over every downstream plugin reachable through MIDI
connections. The MIDI Program Change event itself is still forwarded in the RT
stream; the extra dispatcher call is additive, not a replacement.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 620" xmlns="http://www.w3.org/2000/svg">
  <style>
    .jm-bg { fill: #1a1b26; }
    .jm-lane { fill: #1f2535; stroke: #6b7398; stroke-width: 1.2; rx: 10; }
    .jm-rt { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .jm-buf { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .jm-node { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .jm-ring { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .jm-note { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.6; rx: 8; }
    .jm-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .jm-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .jm-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .jm-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .jm-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .jm-head-r { fill: #f7768e; font: bold 11px 'JetBrains Mono', monospace; }
    .jm-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .jm-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .jm-line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .jm-line-b { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
    .jm-line-p { stroke: #bb9af7; stroke-width: 1.4; fill: none; }
    .jm-line-y { stroke: #e0af68; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="980" height="620" class="jm-bg"/>
  <text x="490" y="26" text-anchor="middle" class="jm-title">Element JACK MIDI: same-period ingress and direct same-period egress</text>

  <rect x="28" y="50" width="924" height="534" class="jm-lane"/>

  <rect x="48" y="88" width="250" height="166" class="jm-rt"/>
  <text x="173" y="112" text-anchor="middle" class="jm-head-g">JACK process callback / RT thread</text>
  <text x="173" y="136" text-anchor="middle" class="jm-small">authoritative timing source</text>
  <text x="173" y="152" text-anchor="middle" class="jm-small">reads `jack_midi_event_get()` from enabled `midi_in_N`</text>
  <text x="173" y="168" text-anchor="middle" class="jm-small">preserves `ev.time` as sample offset within this period</text>
  <text x="173" y="184" text-anchor="middle" class="jm-small">clears + caches enabled `midi_out_N` port buffers before graph render</text>
  <text x="173" y="210" text-anchor="middle" class="jm-text">same thread also runs Element's audio callback</text>

  <rect x="364" y="76" width="252" height="190" class="jm-buf"/>
  <text x="490" y="100" text-anchor="middle" class="jm-head-b">Per-period MIDI state inside `JackAudioIODevice`</text>
  <text x="490" y="124" text-anchor="middle" class="jm-small">`currentPeriodMidiInput`</text>
  <text x="490" y="140" text-anchor="middle" class="jm-small">combined buffer for graph-wide JACK MIDI ingress</text>
  <text x="490" y="164" text-anchor="middle" class="jm-small">`currentPeriodMidiInputPerPort[N]`</text>
  <text x="490" y="180" text-anchor="middle" class="jm-small">per-port buffers for explicit routing nodes</text>
  <text x="490" y="204" text-anchor="middle" class="jm-small">`cachedOutBufs[N]` for direct current-period output writes</text>
  <text x="490" y="220" text-anchor="middle" class="jm-small">all valid for the lifetime of this callback only</text>

  <rect x="682" y="88" width="230" height="166" class="jm-node"/>
  <text x="797" y="112" text-anchor="middle" class="jm-head-p">Element graph layer</text>
  <text x="797" y="136" text-anchor="middle" class="jm-small">AudioEngine consumes combined JACK MIDI input</text>
  <text x="797" y="152" text-anchor="middle" class="jm-small">`JackMidiInputNode(port=N)` consumes one per-port buffer</text>
  <text x="797" y="168" text-anchor="middle" class="jm-small">`JackMidiOutputNode(port=N)` writes direct to libjack</text>
  <text x="797" y="184" text-anchor="middle" class="jm-small">`JackMidiOutputAllNode` broadcasts to every enabled output port</text>
  <text x="797" y="210" text-anchor="middle" class="jm-text">per-port graph routing is part of the engine now</text>

  <rect x="110" y="324" width="760" height="154" class="jm-ring"/>
  <text x="490" y="348" text-anchor="middle" class="jm-head-y">Output write contract</text>
  <text x="490" y="372" text-anchor="middle" class="jm-small">the callback opens each enabled JACK MIDI output buffer before graph processing</text>
  <text x="490" y="388" text-anchor="middle" class="jm-small">graph nodes call `writeJackMidiOutput(...)` during that same period</text>
  <text x="490" y="404" text-anchor="middle" class="jm-small">`jack_midi_event_write()` receives the original sample offset,</text>
  <text x="490" y="420" text-anchor="middle" class="jm-small">not `0` and not next period</text>
  <text x="490" y="436" text-anchor="middle" class="jm-small">cached output-buffer pointers are invalidated after the callback returns</text>
  <text x="490" y="452" text-anchor="middle" class="jm-text">same thread, same period, one libjack copy</text>

  <rect x="184" y="508" width="612" height="48" class="jm-note"/>
  <text x="490" y="534" text-anchor="middle" class="jm-head-r">Current truth</text>
  <text x="490" y="550" text-anchor="middle" class="jm-small">no ALSA-first path, no helper-thread hop, and no period-delayed JACK MIDI egress</text>

  <line x1="298" y1="170" x2="364" y2="170" class="jm-line-g"/>
  <line x1="616" y1="170" x2="682" y2="170" class="jm-line-b"/>
  <path d="M797 254 L797 324" class="jm-line-p"/>
  <path d="M236 254 L236 324" class="jm-line-y"/>
</svg>
</div>

---

## 6. Editor, dialogs, and UI layer

The editor path follows JUCE-NSPA's embedded Win32 GUI model, so plugin editor
windows are still real Wine HWND-backed windows inside a Linux UI tree.

Element adds application policy on top:

- the `PluginWindow` toolbar path is disabled so the embedded editor fills the
  content area instead of reserving host chrome
- Open Session, Save As, Import Graph, and Export Graph use JUCE's internal
  file chooser with the main content component as the parent
- the Lua side bypasses glibc's `setjmp` macro rewrite so the runtime stays on
  glibc's `setjmp()` instead of resolving into Wine's MSVCRT `_setjmp` path

The internal chooser policy matters under winelib:

- Wine's `IFileDialog` path does not surface reliably here
- KDE / zenity bridges are not the normal path for this binary
- top-level non-native dialogs come up with poor decoration behavior
- embedding the chooser on the main window keeps dialog ownership inside the
  same Linux shell as the rest of the application

### 6.1 Graph shell and visual system

Element's UI layer is not just a reskin. The recent changes move the host
toward a clearer separation between application shell, graph topology, and
plugin format identity.

Current UI-side decisions:

- the main `DocumentWindow` uses one GL context for the shell around the graph
- the app uses a flat dark baseline across menu bar, popup menus, headers, and
  content panes
- graph blocks, wires, and channel strips use a shared type-color mapping
- JACK builds hide the older Graph I/O MIDI pseudo-surfaces and expose JACK
  MIDI as explicit graph nodes and preference controls instead
- Audio/MIDI I/O node UX is tightened around inline channels and port-count
  synchronization

The current accent map is code, not theme metadata:

| Surface | Accent |
|---|---|
| Audio I/O | green |
| MIDI I/O and JACK MIDI | orange |
| VST2 | indigo |
| VST3 | purple |
| CLAP | cyan |
| Element-internal nodes | pink |

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ui-bg { fill: #1a1b26; }
    .ui-app { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .ui-shell { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .ui-edit { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .ui-note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .ui-warn { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.6; rx: 8; }
    .ui-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .ui-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .ui-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .ui-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .ui-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .ui-head-r { fill: #f7768e; font: bold 11px 'JetBrains Mono', monospace; }
    .ui-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .ui-line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .ui-line-b { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
    .ui-line-p { stroke: #bb9af7; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="980" height="430" class="ui-bg"/>
  <text x="490" y="26" text-anchor="middle" class="ui-title">Element-NSPA UI policy: shell, dialogs, and graph identity</text>

  <rect x="54" y="82" width="250" height="132" class="ui-app"/>
  <text x="179" y="108" text-anchor="middle" class="ui-head-g">Main application shell</text>
  <text x="179" y="132" text-anchor="middle" class="ui-small">GL-backed `DocumentWindow`</text>
  <text x="179" y="148" text-anchor="middle" class="ui-small">flat dark menu bar + popup menus</text>
  <text x="179" y="164" text-anchor="middle" class="ui-small">session shell and graph container</text>

  <rect x="364" y="82" width="252" height="132" class="ui-shell"/>
  <text x="490" y="108" text-anchor="middle" class="ui-head-b">Embedded dialog and editor policy</text>
  <text x="490" y="132" text-anchor="middle" class="ui-small">JUCE internal file choosers parented on main content</text>
  <text x="490" y="148" text-anchor="middle" class="ui-small">toolbar-free plugin windows</text>
  <text x="490" y="164" text-anchor="middle" class="ui-small">Wine HWND editors embedded through JUCE-NSPA</text>

  <rect x="676" y="82" width="250" height="132" class="ui-edit"/>
  <text x="801" y="108" text-anchor="middle" class="ui-head-p">Graph and mixer identity</text>
  <text x="801" y="132" text-anchor="middle" class="ui-small">Audio I/O = green, JACK MIDI = orange</text>
  <text x="801" y="148" text-anchor="middle" class="ui-small">VST2 = indigo, VST3 = purple, CLAP = cyan</text>
  <text x="801" y="164" text-anchor="middle" class="ui-small">same accents on blocks, wires, and channel strips</text>

  <rect x="182" y="268" width="616" height="86" class="ui-note"/>
  <text x="490" y="294" text-anchor="middle" class="ui-head-y">JACK-build UI consequences</text>
  <text x="490" y="312" text-anchor="middle" class="ui-small">Graph I/O MIDI pseudo-surfaces are hidden.</text>
  <text x="490" y="328" text-anchor="middle" class="ui-small">JACK MIDI becomes explicit node and preference UI.</text>
  <text x="490" y="344" text-anchor="middle" class="ui-small">Port-count controls and node editors line up with the same</text>
  <text x="490" y="360" text-anchor="middle" class="ui-small">native JACK MIDI engine the RT callback uses.</text>

  <rect x="216" y="378" width="548" height="32" class="ui-warn"/>
  <text x="490" y="399" text-anchor="middle" class="ui-head-r">Design constraint</text>
  <text x="490" y="414" text-anchor="middle" class="ui-small">the host shell stays Linux-native even though plugin editors</text>
  <text x="490" y="430" text-anchor="middle" class="ui-small">and plugin code are Wine-backed</text>

  <line x1="304" y1="148" x2="364" y2="148" class="ui-line-g"/>
  <line x1="616" y1="148" x2="676" y2="148" class="ui-line-b"/>
  <path d="M490 214 L490 268" class="ui-line-p"/>
</svg>
</div>

---

## 7. Relationship to JUCE-NSPA and Wine-NSPA

Element-NSPA sits on top of both framework and runtime layers.

| Layer | Use in Element-NSPA |
|---|---|
| JUCE-NSPA | winelib build support, VST2/VST3/CLAP Windows-plugin loading, async `CreateThread` load path, Win32 dispatch, and editor embedding substrate |
| Wine-NSPA X11 embed protocol | embeds plugin editor HWNDs under Linux host windows without a second wrapper protocol |
| Wine-NSPA Win32 runtime | supplies the window/message model, Win32 process priority mapping, and Wine-side plugin module load path |
| Element-specific JACK layer | exposes JACK-native audio and MIDI routing inside the graph on top of the same host process |

Element-NSPA therefore is not a thin build wrapper. It is an application port
that binds one specific app shell to the JUCE-NSPA framework layer and to the
Wine-NSPA runtime rules underneath it.

---

## 8. Current scope

| Boundary | Current behavior |
|---|---|
| Host architecture | Linux-only x86_64 winelib host |
| Supported Windows plugin formats | VST2, VST3, and CLAP |
| Linux-native plugin formats in this process | excluded under `__WINE__` |
| Audio and MIDI transport on Linux build | JACK |
| Dialog model | JUCE internal choosers parented on the main window |
| JACK MIDI graph surface | graph-wide and per-port input nodes, per-port and broadcast output nodes |
| Scan path policy | 64-bit Windows-plugin directories only |

This page therefore describes a specific application-port shape, not a claim
that every Element feature or every native-Linux plugin surface should live in
the same process as the winelib Windows-plugin host.

---

## 9. References

- `src/main.cc`
- `src/pluginmanager.cpp`
- `src/utils.cpp`
- `src/engine/graphmanager.cpp`
- `src/engine/jack.hpp`
- `src/engine/jack.cpp`
- `src/nodes/jackmidiinputnode.hpp`
- `src/nodes/jackmidiinputallnode.hpp`
- `src/nodes/jackmidioutputnode.hpp`
- `src/nodes/jackmidioutputallnode.hpp`
- `src/services/guiservice.cpp`
- `src/services/sessionservice.cpp`
- `src/ui/mainwindow.cpp`
- `src/ui/nodechannelstrip.hpp`
- `src/ui/style_v1.cpp`
- [JUCE-NSPA](juce-nspa.gen.html)
- [NSPA X11 Embed Protocol](nspa-x11-embed-protocol.gen.html)
