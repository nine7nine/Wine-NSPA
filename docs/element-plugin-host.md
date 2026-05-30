# Wine-NSPA -- Lulada

This page documents Lulada, a modular Linux winelib DAW derived from Element
and built around Wine-NSPA, JUCE-NSPA, in-process Win32 plugin hosting, and
JACK-native audio/MIDI.

## Table of Contents

1. [Overview](#1-overview)
2. [DAW architecture](#2-daw-architecture)
3. [DAW feature surface](#3-daw-feature-surface)
4. [Runtime bootstrap](#4-runtime-bootstrap)
5. [Plugin surface and scan policy](#5-plugin-surface-and-scan-policy)
6. [JACK-first audio and MIDI graph path](#6-jack-first-audio-and-midi-graph-path)
7. [Editor, dialogs, and UI layer](#7-editor-dialogs-and-ui-layer)
8. [Relationship to JUCE-NSPA and Wine-NSPA](#8-relationship-to-juce-nspa-and-wine-nspa)
9. [Application boundary](#9-application-boundary)
10. [References](#10-references)

---

## 1. Overview

Lulada is a modular Linux DAW with in-process Win32 plugin support. The
application shell, Session View, Arrangement/Timeline, tracker, piano-roll,
sampler, automation engine, JACK engine, plugin manager, embedded editors, and
Wine-backed runtime all live in one Linux process with explicit ownership
boundaries between the native and Win32 parts.

The load-bearing subsystems are:

- a native Linux DAW shell with graph editing, session UI, Session View-style
  launching, multi-track recording, tracker sequencing, MIDI/piano-roll
  sequencing, internal dialogs, and GL-backed rendering
- a fully modular graph where audio, MIDI, JACK ports, sequencers, internal
  processors, and Windows plugins are routable production nodes
- Arrangement/Timeline audio and MIDI lanes with region authoring,
  disk-streamed record/playback, looped regions, gain, and fades
- tracker and piano-roll as equal MIDI authoring surfaces, with MIDI clips
  usable from both Session View and Arrangement
- sampler and automation systems that are part of the DAW engine, not external
  plugin requirements
- JACK-first audio and MIDI routing exposed as graph topology, including
  explicit per-port MIDI nodes
- Windows VST2, VST3, and CLAP plugin loading through JUCE-NSPA and Wine-NSPA
- embedded Win32 plugin editors inside native X11 or Wayland host windows
- runtime bootstrap that prepares wineserver, COM, process priority, and Wine
  thread state before plugin code runs

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
  <text x="490" y="26" text-anchor="middle" class="ov-title">Lulada: DAW shell, JACK engine, and Windows plugin runtime in one process</text>

  <rect x="24" y="52" width="932" height="468" class="ov-lane"/>
  <text x="42" y="72" class="ov-small">single Linux process, native DAW surfaces plus Wine-backed plugin surfaces</text>

  <rect x="46" y="94" width="250" height="158" class="ov-native"/>
  <text x="171" y="118" text-anchor="middle" class="ov-head-g">Lulada application layer</text>
  <text x="171" y="140" text-anchor="middle" class="ov-small">Session View + Arrangement/Timeline</text>
  <text x="171" y="156" text-anchor="middle" class="ov-small">tracker + piano-roll MIDI authoring</text>
  <text x="171" y="172" text-anchor="middle" class="ov-small">sampler, automation, plugin manager</text>
  <text x="171" y="188" text-anchor="middle" class="ov-small">GL-backed shell + embedded internal dialogs</text>
  <text x="171" y="214" text-anchor="middle" class="ov-text">music-production UI and session model live here</text>

  <rect x="364" y="82" width="252" height="182" class="ov-host"/>
  <text x="490" y="106" text-anchor="middle" class="ov-head-b">JUCE-NSPA / winelib host substrate</text>
  <text x="490" y="128" text-anchor="middle" class="ov-small">winegcc / wineg++ build, PE module loading</text>
  <text x="490" y="144" text-anchor="middle" class="ov-small">in-process Win32 VST2, VST3, and CLAP</text>
  <text x="490" y="160" text-anchor="middle" class="ov-small">Win32 ABI fixes, `LoadLibraryW()`, `CreateThread` async load</text>
  <text x="490" y="176" text-anchor="middle" class="ov-small">X11 or Wayland `WineHWNDEmbedComponent` + bounded Win32 pump</text>
  <text x="490" y="202" text-anchor="middle" class="ov-text">framework layer provides the Win32 plugin substrate</text>

  <rect x="684" y="94" width="250" height="158" class="ov-plugin"/>
  <text x="809" y="118" text-anchor="middle" class="ov-head-p">Windows plugins</text>
  <text x="809" y="140" text-anchor="middle" class="ov-small">VST2 `.dll`, VST3 PE module, CLAP `.clap` PE DLL</text>
  <text x="809" y="156" text-anchor="middle" class="ov-small">editor HWNDs embedded under X11 or Wayland peers</text>
  <text x="809" y="172" text-anchor="middle" class="ov-small">Win32 message flow and plugin callbacks stay intact</text>
  <text x="809" y="198" text-anchor="middle" class="ov-text">loaded in-process through Wine</text>

  <rect x="46" y="308" width="888" height="128" class="ov-jack"/>
  <text x="490" y="334" text-anchor="middle" class="ov-head-y">JACK-first audio and MIDI engine</text>
  <text x="490" y="356" text-anchor="middle" class="ov-small">JACK is the sole Linux audio + MIDI transport in this build</text>
  <text x="490" y="372" text-anchor="middle" class="ov-small">sample-accurate MIDI ingress lands in combined and per-port buffers</text>
  <text x="490" y="388" text-anchor="middle" class="ov-small">native JACK MIDI nodes expose per-port routing in the graph</text>
  <text x="490" y="404" text-anchor="middle" class="ov-small">disk-streamed audio lanes and MIDI lanes run from the same timeline model</text>
  <text x="490" y="430" text-anchor="middle" class="ov-text">audio and native MIDI live on the same timing surface</text>

  <rect x="110" y="454" width="760" height="46" class="ov-note"/>
  <text x="490" y="482" text-anchor="middle" class="ov-head-r">Result</text>
  <text x="490" y="498" text-anchor="middle" class="ov-small">the DAW shell, JACK graph, and Windows plugin runtime share one process,</text>
  <text x="490" y="512" text-anchor="middle" class="ov-small">but each layer keeps a distinct ownership boundary</text>

  <line x1="296" y1="174" x2="364" y2="174" class="ov-line-g"/>
  <line x1="616" y1="174" x2="684" y2="174" class="ov-line-b"/>
  <path d="M171 252 L171 308" class="ov-line-g"/>
  <path d="M490 264 L490 308" class="ov-line-b"/>
  <path d="M809 252 L809 308" class="ov-line-p"/>
</svg>
</div>

---

## 2. DAW architecture

Lulada keeps Element's graph-oriented lineage, but the application target is a
Wine-NSPA music-production environment. Plugin hosting is one subsystem inside
the DAW rather than the whole product shape.

The application-level decisions are:

- the DAW shell stays native Linux, with Wayland used when available and X11 as
  the fallback host window system
- JACK is the audio/MIDI transport and timing authority
- JACK MIDI is exposed as real graph topology rather than hidden device state
- Windows plugins are first-class graph nodes loaded in-process through Wine
- plugin editor windows are native-host children even though the editor HWNDs
  and plugin callbacks follow Win32 rules
- file choosers and plugin-window chrome stay inside the application shell
  instead of depending on native OS dialog behavior from inside winelib

| Concern | Generic Element lineage | Lulada architecture |
|---|---|---|
| Application role | graph-oriented audio host | DAW shell with graph editing, JACK routing, and Windows plugin production workflow |
| Plugin target | platform-native plugin formats | Windows VST2, VST3, and CLAP through winelib + Wine |
| Scan defaults | native host defaults | Wine-prefix VST/VST3/CLAP directories are part of the default scan surface |
| Runtime bootstrap | native app bootstrap | wineserver pre-warm plus Win32 process-class and OLE init before plugin load |
| Editor hosting | native plugin editor assumptions | embedded Wine HWND-backed editor windows in the X11 or Wayland Linux UI |
| Dialog model | native or OS-host file choosers | JUCE-internal choosers embedded on the main window |
| MIDI shape | generic Linux MIDI backend choices | JACK-first native MIDI ports and graph nodes; ALSA is disabled |

---

## 3. DAW feature surface

Lulada's current public DAW surface is centered on graph/session workflow plus
clip and sequence authoring. A load-bearing distinction is that Windows VST2,
VST3, and CLAP plugins run in-process inside the Linux DAW instead of through a
separate bridge process. The application presents audio I/O, JACK MIDI I/O,
sequencers, internal processors, and Windows plugin nodes as routable
production surfaces, with the JACK callback acting as the period boundary for
audio and MIDI.

| Surface | Current behavior |
|---|---|
| Session shell | single GL-backed main window with graph, mixer-facing UI, Session View-style launcher, plugin manager, and internal dialogs under one native Linux shell |
| Modular graph | audio I/O, JACK MIDI I/O, Windows plugins, sequencers, and internal processing surfaces are routable graph nodes |
| Arrangement / Timeline | audio and MIDI lanes, disk-streamed record/playback, move/resize/split/snap region authoring, looped regions, clip gain, and Bezier fades |
| Multi-track recording | audio and MIDI recording are organized as DAW tracks rather than one-off plugin-host capture |
| Clip launching | Session View-style workflow for launching and arranging musical material in a live-production shape |
| Tracker sequencing | tracker-style pattern sequencing is part of the composition surface |
| MIDI / piano-roll sequencing | piano-roll MIDI editing complements the tracker path for note and automation authoring |
| Sampler | FT2-style sampler engine with multi-instrument bank/slot workflow, envelopes, voice-level FX, session-global sample pool, and SIMD mix path |
| Automation | copy-on-write automation data model, sample-accurate MIDI CC, touch-record path, and session save/load round-trip |
| Audio transport | JACK is the Linux audio backend and timing authority |
| MIDI transport | JACK MIDI is enabled as graph topology, with combined input plus explicit per-port input and output nodes |
| In-process Win32 plugins | Windows VST2, VST3, and CLAP run inside the DAW process through the Wine-backed runtime |
| Plugin editors | Win32 plugin editor HWNDs embed inside the DAW window tree through X11 or Wayland host surfaces |
| Dialogs | session and graph file operations use JUCE internal choosers parented on the main window |
| Visual identity | graph blocks, wires, and mixer/channel surfaces use type colors for Audio I/O, JACK MIDI, VST2, VST3, CLAP, and internal nodes |

The result is a Linux DAW shell whose recording, clip, sequence, and realtime
graph surfaces are JACK-native while in-process Windows plugin nodes keep
Win32 loader, message, editor, and callback semantics intact.

---

## 4. Runtime bootstrap

Lulada performs winelib host initialization before plugin code gets a chance
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
window where the first Wine client in Lulada's process tree can race an
uninitialized wineserver.

---

## 5. Plugin surface and scan policy

Lulada narrows its plugin surface to the Windows formats that make
sense inside this Wine-NSPA DAW process.

| Area | Current behavior |
|---|---|
| VST3 | enabled |
| VST2 | enabled, using the system Steinberg VST2 SDK 2.4 |
| CLAP | enabled under `__WINE__` through JUCE-NSPA `CLAPPluginFormat` |
| Built-in nodes | sampler, tracker, MIDI tools, audio FX, and other internal graph processors stay native inside the DAW |
| LV2 | not registered under `__WINE__` |
| LADSPA | not registered under `__WINE__` |

The LV2 and LADSPA exclusions are deliberate. They are Linux-native plugin
formats, and loading them inside the same winelib DAW process would pull
unrelated native plugin trees and their copies of framework globals into the
same address space. For this application boundary, that is the wrong process
shape.

### 5.1 Wine-prefix path discovery

Lulada augments default scan paths with Windows-plugin directories inside
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

### 5.2 CLAP registration under winelib

Under `__WINE__`, Lulada uses JUCE-NSPA's CLAP host format instead of
upstream Element's native Linux CLAP provider.

That split exists to avoid double registration:

- native Linux CLAP remains the right path for a native Linux Element build
- Lulada wants Windows `.clap` PE DLLs through Wine `LoadLibraryW()`
- the winelib build therefore registers `CLAPPluginFormat` and gates off the
  native `CLAPProvider`

The current CLAP scan path is also in-process under winelib. The scanner-worker
IPC used for other formats is not yet reliable enough for the Winegcc CLAP
path, so CLAP file enumeration and factory probing stay in the main process.

### 5.3 Asynchronous instantiation

Interactive plugin add is no longer a message-thread synchronous load.

Current shape:

1. Lulada requests `createGraphNodeAsync`
2. JUCE-NSPA uses its winelib `CreateThread` worker to perform plugin creation
3. completion returns to the message thread
4. Lulada finalizes the new node in two pieces:
   - message-thread metadata and `resetPorts()`
   - worker-thread block-hiding/property shaping before attachment

That keeps the UI responsive while large plugin descriptors and port lists are
being materialized.

---

## 6. JACK-first audio and MIDI graph path

The JACK path is part of the DAW architecture, not just a device backend. This
Linux build disables ALSA and uses JACK as the native audio and MIDI transport.

### 6.1 Timing and data path

`JackAudioIODevice::process()` is the timing authority. JACK ingress, Lulada's
audio callback, graph MIDI consumption, and outbound MIDI emission all happen on
that same callback thread.

Current inbound shape:

1. `jack_midi_event_get()` reads events from each enabled `midi_in_N` port
2. Lulada writes those events into:
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

### 6.2 Graph exposure and routing

Lulada exposes JACK MIDI as actual graph topology instead of a hidden device
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
  <text x="490" y="26" text-anchor="middle" class="jm-title">Lulada JACK MIDI: same-period ingress and direct same-period egress</text>

  <rect x="28" y="50" width="924" height="534" class="jm-lane"/>

  <rect x="48" y="88" width="250" height="166" class="jm-rt"/>
  <text x="173" y="112" text-anchor="middle" class="jm-head-g">JACK process callback / RT thread</text>
  <text x="173" y="136" text-anchor="middle" class="jm-small">authoritative timing source</text>
  <text x="173" y="152" text-anchor="middle" class="jm-small">reads `jack_midi_event_get()` from enabled `midi_in_N`</text>
  <text x="173" y="168" text-anchor="middle" class="jm-small">preserves `ev.time` as sample offset within this period</text>
  <text x="173" y="184" text-anchor="middle" class="jm-small">clears + caches enabled `midi_out_N` port buffers before graph render</text>
  <text x="173" y="210" text-anchor="middle" class="jm-text">same thread also runs Lulada's audio callback</text>

  <rect x="364" y="76" width="252" height="190" class="jm-buf"/>
  <text x="490" y="100" text-anchor="middle" class="jm-head-b">Per-period MIDI state inside `JackAudioIODevice`</text>
  <text x="490" y="124" text-anchor="middle" class="jm-small">`currentPeriodMidiInput`</text>
  <text x="490" y="140" text-anchor="middle" class="jm-small">combined buffer for graph-wide JACK MIDI ingress</text>
  <text x="490" y="164" text-anchor="middle" class="jm-small">`currentPeriodMidiInputPerPort[N]`</text>
  <text x="490" y="180" text-anchor="middle" class="jm-small">per-port buffers for explicit routing nodes</text>
  <text x="490" y="204" text-anchor="middle" class="jm-small">`cachedOutBufs[N]` for direct current-period output writes</text>
  <text x="490" y="220" text-anchor="middle" class="jm-small">all valid for the lifetime of this callback only</text>

  <rect x="682" y="88" width="230" height="166" class="jm-node"/>
  <text x="797" y="112" text-anchor="middle" class="jm-head-p">Lulada graph layer</text>
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

## 7. Editor, dialogs, and UI layer

The editor path follows JUCE-NSPA's embedded Win32 GUI model, so plugin editor
windows are real Wine HWND-backed windows inside the DAW's native Linux UI
tree.

Lulada does not add another embed protocol on top of that layer. Editor
windows inherit JUCE-NSPA's `WineHWNDEmbedComponent`, which means:

- the whole editor thread queue is pumped, not just the top-level HWND
- mouse and keyboard ranges drain before the general queue
- the remaining queue uses the same 4 ms budget as JUCE-NSPA
- X11 sessions use the X11 embed protocol and host-owned X11 sizing
- Wayland sessions use the Wayland embed protocol and host-owned subsurface
  parentage on the adopted host `wl_display`

The DAW layer adds application policy on top:

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

### 7.1 Inherited embed boundary

The DAW reuses the JUCE-NSPA embed substrate directly. The split
between framework ownership and application ownership is:

| Surface | Owner | Current behavior |
|---|---|---|
| Wine HWND creation and native peer lookup | JUCE-NSPA | `WineHWNDEmbedComponent` creates the HWND and resolves the X11 child or Wayland host parent |
| Embed message and completion edge | JUCE-NSPA + Wine-NSPA | X11 uses `WM_X11DRV_NSPA_EMBED_WINDOW`; Wayland uses `WM_WAYLANDDRV_NSPA_EMBED_WINDOW` |
| Queue pump discipline | JUCE-NSPA | whole-thread queue, input-first passes, 4 ms general drain |
| Native/Win32 geometry split | JUCE-NSPA + Wine-NSPA | `SetWindowPos()` keeps Wine rects coherent; the host peer keeps native parent-relative sizing coherent |
| Plugin-window chrome and chooser policy | Lulada | toolbar-free editor shell and in-app file choosers parented on the main content component |

### 7.2 Wayland host mode

Lulada enables the JUCE-NSPA Wayland peer backend for winelib builds. On a
Wayland session the JUCE-NSPA layer owns the native `wl_display` and peer
surfaces, then publishes that display to `winewayland.drv` before Wine creates
plugin editor surfaces. Wine validates that the host parent and Wine child are
on the same display, creates a fresh `wl_surface` for the HWND, and installs it
as a `wl_subsurface` of the JUCE-NSPA peer.

The Wayland path is runtime-selected. If `WAYLAND_DISPLAY` is absent, the host
continues through the X11 embed path.

### 7.3 Graph shell and visual system

The UI layer separates application shell, graph topology, plugin format
identity, and JACK routing state.

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
| Internal nodes | pink |

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
  <text x="490" y="26" text-anchor="middle" class="ui-title">Lulada UI policy: shell, dialogs, and graph identity</text>

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

## 8. Relationship to JUCE-NSPA and Wine-NSPA

Lulada uses JUCE-NSPA for the Win32 plugin framework layer and Wine-NSPA for
the runtime surfaces that make that framework viable in an RT-oriented Linux
DAW.

| Layer | Use in Lulada |
|---|---|
| JUCE-NSPA | winelib build support, VST2/VST3/CLAP Windows-plugin loading, JUCE-NSPA Wayland peer support, async `CreateThread` load path, and the bounded input-first `WineHWNDEmbedComponent` editor layer |
| Wine-NSPA X11 embed protocol | embeds plugin editor HWNDs under X11 host windows while leaving X11 sizing and the consumer pump discipline on the host side |
| Wine-NSPA Wayland embed protocol | embeds plugin editor HWNDs as Wayland subsurfaces under JUCE-NSPA Wayland peers using the shared host `wl_display` |
| Wine-NSPA Win32 runtime | supplies the window/message model, Win32 process priority mapping, and Wine-side plugin module load path |
| Lulada JACK layer | exposes JACK-native audio and MIDI routing inside the graph on top of the same host process |

The important boundary is that JUCE-NSPA and Wine-NSPA provide the plugin and
runtime substrate. Lulada owns the DAW shell, graph/session model, JACK routing
policy, plugin scan policy, editor presentation, and user-facing workflow.

---

## 9. Application boundary

| Boundary | Current behavior |
|---|---|
| Application architecture | Linux-only x86_64 winelib DAW |
| Host window system | Wayland when available, X11 fallback |
| Supported Windows plugin formats | VST2, VST3, and CLAP |
| Linux-native plugin formats in this process | excluded under `__WINE__` |
| Audio and MIDI transport on Linux build | JACK |
| Dialog model | JUCE internal choosers parented on the main window |
| JACK MIDI graph surface | graph-wide and per-port input nodes, per-port and broadcast output nodes |
| Scan path policy | 64-bit Windows-plugin directories only |

This page describes the current Lulada application boundary: a native Linux DAW
shell with a Wine-backed Windows plugin runtime, not a general claim that every
native-Linux plugin surface should live in the same process.

---

## 10. References

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
- `CMakeLists.txt`
- [JUCE-NSPA](juce-nspa.gen.html)
- [NSPA X11 Embed Protocol](nspa-x11-embed-protocol.gen.html)
- [NSPA Wayland Embed Protocol](nspa-wayland-embed-protocol.gen.html)
