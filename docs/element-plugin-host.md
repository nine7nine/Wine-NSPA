# Wine-NSPA -- Lulada

Lulada is a Linux Digital Audio Workstation built on a winelib runtime. It
combines DAW sequencing, recording, automation, JACK-native audio/MIDI, and
in-process Windows VST2, VST3, and CLAP plugins in one Linux application.

## Table of Contents

1. [Overview](#1-overview)
2. [DAW surfaces](#2-daw-surfaces)
3. [System architecture](#3-system-architecture)
4. [Session View and Arrangement](#4-session-view-and-arrangement)
5. [MIDI authoring](#5-midi-authoring)
6. [Sampler and automation](#6-sampler-and-automation)
7. [JACK audio and MIDI engine](#7-jack-audio-and-midi-engine)
8. [Windows plugin runtime](#8-windows-plugin-runtime)
9. [Window embedding and UI policy](#9-window-embedding-and-ui-policy)
10. [Runtime boundary](#10-runtime-boundary)
11. [References](#11-references)

---

## 1. Overview

Lulada is the Wine-NSPA DAW application. Its core application model is a
modular music-production environment: clip launching, linear arrangement,
multi-track recording, tracker sequencing, piano-roll editing, sample playback,
automation, JACK routing, and plugin processing are all part of the same
session graph.

The Windows-plugin path is an implementation capability inside that DAW. VST2,
VST3, and CLAP plugins are loaded in-process through JUCE-NSPA and Wine-NSPA,
so plugin DSP, plugin editors, JACK graph routing, and the DAW transport all
share one Linux process.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 560" xmlns="http://www.w3.org/2000/svg">
  <style>
    .lu-bg { fill: #1a1b26; }
    .lu-frame { fill: #1f2535; stroke: #6b7398; stroke-width: 1.2; rx: 12; }
    .lu-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 10; }
    .lu-blue { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 10; }
    .lu-purple { fill: #261d35; stroke: #bb9af7; stroke-width: 1.8; rx: 10; }
    .lu-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 10; }
    .lu-red { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.6; rx: 10; }
    .lu-title { fill: #7aa2f7; font: bold 15px 'JetBrains Mono', monospace; }
    .lu-hg { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .lu-hb { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .lu-hp { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .lu-hy { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .lu-hr { fill: #f7768e; font: bold 11px 'JetBrains Mono', monospace; }
    .lu-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .lu-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .lu-line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .lu-line-b { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
    .lu-line-p { stroke: #bb9af7; stroke-width: 1.4; fill: none; }
    .lu-line-y { stroke: #e0af68; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="980" height="560" class="lu-bg"/>
  <text x="490" y="28" text-anchor="middle" class="lu-title">Lulada Digital Audio Workstation</text>
  <rect x="26" y="54" width="928" height="468" class="lu-frame"/>

  <rect x="58" y="92" width="250" height="134" class="lu-green"/>
  <text x="183" y="116" text-anchor="middle" class="lu-hg">Composition surfaces</text>
  <text x="183" y="140" text-anchor="middle" class="lu-small">Session View clip grid + scenes</text>
  <text x="183" y="156" text-anchor="middle" class="lu-small">Arrangement / Timeline lanes</text>
  <text x="183" y="172" text-anchor="middle" class="lu-small">tracker and piano-roll MIDI editors</text>
  <text x="183" y="188" text-anchor="middle" class="lu-small">multi-track recording and region editing</text>

  <rect x="365" y="92" width="250" height="134" class="lu-blue"/>
  <text x="490" y="116" text-anchor="middle" class="lu-hb">DAW engine</text>
  <text x="490" y="140" text-anchor="middle" class="lu-small">modular graph and nested subgraphs</text>
  <text x="490" y="156" text-anchor="middle" class="lu-small">sampler, automation, MIDI tools</text>
  <text x="490" y="172" text-anchor="middle" class="lu-small">disk-streamed playback and recording</text>
  <text x="490" y="188" text-anchor="middle" class="lu-small">sample-accurate launch and MIDI timing</text>

  <rect x="672" y="92" width="250" height="134" class="lu-purple"/>
  <text x="797" y="116" text-anchor="middle" class="lu-hp">Windows plugin runtime</text>
  <text x="797" y="140" text-anchor="middle" class="lu-small">VST2, VST3, and CLAP PE modules</text>
  <text x="797" y="156" text-anchor="middle" class="lu-small">loaded in-process through Wine-NSPA</text>
  <text x="797" y="172" text-anchor="middle" class="lu-small">Win32 editor HWNDs embedded in UI</text>
  <text x="797" y="188" text-anchor="middle" class="lu-small">async plugin instantiation path</text>

  <rect x="120" y="304" width="330" height="116" class="lu-yellow"/>
  <text x="285" y="328" text-anchor="middle" class="lu-hy">JACK-native transport</text>
  <text x="285" y="352" text-anchor="middle" class="lu-small">audio callback is the period boundary</text>
  <text x="285" y="368" text-anchor="middle" class="lu-small">combined and per-port JACK MIDI buffers</text>
  <text x="285" y="384" text-anchor="middle" class="lu-small">direct same-period output writes</text>

  <rect x="530" y="304" width="330" height="116" class="lu-red"/>
  <text x="695" y="328" text-anchor="middle" class="lu-hr">Native Linux shell</text>
  <text x="695" y="352" text-anchor="middle" class="lu-small">GL-backed application window</text>
  <text x="695" y="368" text-anchor="middle" class="lu-small">Wayland peer support, X11 fallback</text>
  <text x="695" y="384" text-anchor="middle" class="lu-small">internal file choosers and graph UI</text>

  <rect x="204" y="454" width="572" height="44" class="lu-blue"/>
  <text x="490" y="476" text-anchor="middle" class="lu-text">one DAW session graph owns composition, routing, plugins,</text>
  <text x="490" y="492" text-anchor="middle" class="lu-text">automation, recording, and playback</text>

  <line x1="308" y1="159" x2="365" y2="159" class="lu-line-g"/>
  <line x1="615" y1="159" x2="672" y2="159" class="lu-line-b"/>
  <path d="M285 226 L285 304" class="lu-line-y"/>
  <path d="M490 226 L490 454" class="lu-line-b"/>
  <path d="M797 226 L797 304" class="lu-line-p"/>
</svg>
</div>

---

## 2. DAW surfaces

| Surface | Current implementation |
|---|---|
| Session View | clip grid, scenes, per-column track strips, scene launch, scene tempo/time-signature override, follow actions, stop buttons, and sample-accurate audio-thread launch scheduling |
| Arrangement / Timeline | audio and MIDI lanes, region move/resize/split/snap, looped regions, clip gain, Bezier fade curves, marker track, ruler interaction, and disk-streamed audio record/playback |
| Multi-track recording | track-oriented audio recording through disk-streaming services, with graph auto-wiring for the multi-track patchbay |
| Tracker | vendored VHT-style tracker engine, pattern grid, QWERTY note entry, per-cell FX columns, multi-pattern sequencing, per-row delay/probability/range, row-per-beat control, mute/solo, and MIDI recording |
| Piano-roll | MIDI note regions, viewport/zoom/tools, velocity lane, snap divisions, ruler, playhead, Alt-copy, axis lock, edge resize, clipboard, quantize, humanize, and scale-snap with live preview |
| MIDI clips | first-class sources shared by Session View and Arrangement, backed by copy-on-write MIDI note region data |
| Sampler | FT2-style mixer DSP, multi-instrument bank/slot workflow, volume/pan envelopes, voice-level FX, pitch/mod-wheel routing, four stereo bus outputs, AVX2 mix path, and session-global sample pool |
| Automation | copy-on-write automation point/region/track model, curve math, sample-accurate MIDI CC dispatch, touch-record FIFO, mute table, and session XML round-trip |
| Modular graph | audio, MIDI, JACK ports, sequencers, samplers, internal processors, and Windows plugins are routable nodes in the same graph |
| Plugin processing | in-process Windows VST2, VST3, and CLAP nodes run beside native DAW processors |

---

## 3. System architecture

Lulada separates DAW ownership from runtime substrate ownership. The DAW owns
the session model, graph topology, timeline, clip launching, MIDI editors,
sampler, automation, JACK policy, plugin scan policy, and UI presentation.
JUCE-NSPA and Wine-NSPA provide the Windows-plugin and native-peer substrate
used by that application.

| Layer | Responsibility |
|---|---|
| Lulada application shell | main window, view switching, session/document commands, graph UI, plugin manager, internal dialogs, and visual identity |
| Composition model | Session View cells/scenes plus Arrangement/Timeline lanes and regions |
| Authoring engines | tracker, piano-roll, sampler, automation, MIDI source/region services |
| Graph engine | audio/MIDI routing, internal processors, Windows plugin nodes, nested subgraphs, multi-track patchbay wiring |
| JACK engine | audio period boundary, native audio ports, native MIDI ports, same-period MIDI ingress/egress |
| JUCE-NSPA | winelib build support, Windows VST2/VST3/CLAP plugin formats, `WineHWNDEmbedComponent`, Wayland peer support, async plugin-load helper path |
| Wine-NSPA | Win32 loader/runtime, wineserver, Wine thread state, X11/Wayland embed protocol, Win32 priority mapping |

The important boundary is that plugin execution is one subsystem inside the
DAW. It does not define the whole application model.

---

## 4. Session View and Arrangement

Lulada has both live clip-launching and a linear arrangement model. Session
View is organized around cells, scenes, per-column track strips, follow
actions, scene-level tempo/time-signature overrides, and sample-accurate
launch scheduling on the audio thread. Arrangement/Timeline provides audio and
MIDI lanes with region authoring, marker navigation, loop ranges, clip gain,
fade curves, and disk-streamed audio playback/recording.

The two surfaces share clip data instead of acting as unrelated modes. MIDI
clips are first-class sources that can appear in Session View and Arrangement,
and the timeline services keep source/region/lane ownership explicit.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .sv-bg { fill: #1a1b26; }
    .sv-box { fill: #1f2535; stroke: #6b7398; stroke-width: 1.2; rx: 12; }
    .sv-green { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 10; }
    .sv-blue { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 10; }
    .sv-purple { fill: #261d35; stroke: #bb9af7; stroke-width: 1.8; rx: 10; }
    .sv-yellow { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 10; }
    .sv-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .sv-hg { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .sv-hb { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .sv-hp { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .sv-hy { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .sv-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .sv-line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .sv-line-b { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
    .sv-line-p { stroke: #bb9af7; stroke-width: 1.4; fill: none; }
  </style>
  <rect x="0" y="0" width="980" height="430" class="sv-bg"/>
  <text x="490" y="28" text-anchor="middle" class="sv-title">Shared clip model: live launching and linear arrangement</text>
  <rect x="34" y="56" width="912" height="334" class="sv-box"/>

  <rect x="74" y="102" width="250" height="132" class="sv-green"/>
  <text x="199" y="126" text-anchor="middle" class="sv-hg">Session View</text>
  <text x="199" y="150" text-anchor="middle" class="sv-small">clip cells, scenes, follow actions</text>
  <text x="199" y="166" text-anchor="middle" class="sv-small">per-scene tempo / time signature</text>
  <text x="199" y="182" text-anchor="middle" class="sv-small">audio-thread launch scheduler</text>

  <rect x="365" y="102" width="250" height="132" class="sv-blue"/>
  <text x="490" y="126" text-anchor="middle" class="sv-hb">Shared sources and regions</text>
  <text x="490" y="150" text-anchor="middle" class="sv-small">MIDI note regions and audio regions</text>
  <text x="490" y="166" text-anchor="middle" class="sv-small">copy-on-write source data</text>
  <text x="490" y="182" text-anchor="middle" class="sv-small">lane / playlist ownership</text>

  <rect x="656" y="102" width="250" height="132" class="sv-purple"/>
  <text x="781" y="126" text-anchor="middle" class="sv-hp">Arrangement / Timeline</text>
  <text x="781" y="150" text-anchor="middle" class="sv-small">audio + MIDI lanes</text>
  <text x="781" y="166" text-anchor="middle" class="sv-small">move / resize / split / snap</text>
  <text x="781" y="182" text-anchor="middle" class="sv-small">loop, gain, fades, markers</text>

  <rect x="236" y="286" width="508" height="58" class="sv-yellow"/>
  <text x="490" y="312" text-anchor="middle" class="sv-hy">Graph execution</text>
  <text x="490" y="330" text-anchor="middle" class="sv-small">clip, timeline, MIDI, sampler, automation, and plugin nodes render through the same graph</text>

  <line x1="324" y1="168" x2="365" y2="168" class="sv-line-g"/>
  <line x1="615" y1="168" x2="656" y2="168" class="sv-line-b"/>
  <path d="M490 234 L490 286" class="sv-line-p"/>
</svg>
</div>

---

## 5. MIDI authoring

Lulada has two main MIDI composition surfaces.

| Surface | Role |
|---|---|
| Tracker | pattern-first MIDI sequencing with QWERTY entry, per-cell FX columns, block editing, multi-pattern sequences, row-level timing/probability/range controls, track loop controls, and mute/solo |
| Piano-roll | note-region editing with velocity lane, snap divisions, ruler/playhead, drag/trim/copy gestures, clipboard, quantize, humanize, scale-snap, and live preview |

Both editors feed the same MIDI source/region infrastructure. That matters for
the DAW model: tracker phrases, piano-roll clips, Session View cells, and
Arrangement MIDI regions are not separate plugin-host side channels. They are
composition data inside the project.

---

## 6. Sampler and automation

The sampler is an internal DAW instrument, not an external dependency. It uses
an FT2-style mixer core with multi-instrument bank/slot workflow, volume and
pan envelopes, voice-level FX, pitch/mod-wheel routing, four stereo bus
outputs, and an AVX2 SIMD mix kernel. The session-global sample pool exposes
128 banks with 32 slots per bank, and sample-bank state round-trips through
the session.

Automation is also internal to the engine. The current implementation uses a
copy-on-write automation model with point, region, and track objects, curve
math, target dispatch, sample-accurate MIDI CC output, a touch-record FIFO,
and session XML round-trip.

---

## 7. JACK audio and MIDI engine

The Linux build is JACK-first. JACK is the audio transport, MIDI transport, and
the timing boundary for realtime graph execution. ALSA-seq is disabled in this
build.

Current inbound MIDI path:

1. `JackAudioIODevice::process()` reads each enabled `midi_in_N` port with
   `jack_midi_event_get()`.
2. Events are written into `currentPeriodMidiInput` for graph-wide MIDI input
   and `currentPeriodMidiInputPerPort[N]` for explicit per-port nodes.
3. The original JACK sample offset is preserved.
4. `AudioEngine`, `MidiEngine`, and `JackMidiInputNode` consume those buffers
   during the same period.

Current outbound MIDI path:

1. the JACK callback clears and caches enabled `midi_out_N` buffers before the
   graph renders
2. `JackMidiOutputNode` and `JackMidiOutputAllNode` write directly through
   `writeJackMidiOutput()`
3. `jack_midi_event_write()` receives the caller's sample offset for the
   current period
4. cached output buffers are invalidated before the callback returns

The graph exposes JACK MIDI as topology: combined input, per-port input nodes,
per-port output nodes, and broadcast output nodes are explicit graph surfaces.

---

## 8. Windows plugin runtime

Windows plugin support is integrated into the DAW process through JUCE-NSPA
and Wine-NSPA.

| Surface | Current behavior |
|---|---|
| VST2 | enabled through the system Steinberg VST2 SDK 2.4 |
| VST3 | enabled for Windows VST3 modules loaded through the winelib runtime |
| CLAP | enabled under `__WINE__` through JUCE-NSPA `CLAPPluginFormat` for Windows `.clap` PE DLLs |
| LV2 / LADSPA / AU | not registered in the winelib configuration |
| Built-in nodes | sampler, tracker, MIDI tools, audio FX, and internal processors remain native Lulada nodes |

The scan surface is limited to 64-bit Windows-plugin directories inside the
active `WINEPREFIX`:

- `drive_c/Program Files/Common Files/VST2`
- `drive_c/Program Files/Steinberg/VstPlugins`
- `drive_c/Program Files/Common Files/VST`
- `drive_c/Program Files/Common Files/VST3`
- `drive_c/Program Files/Common Files/CLAP`
- `drive_c/users/<user>/AppData/Local/Programs/Common/CLAP`

`Program Files (x86)` is intentionally excluded because the host is x86_64
winelib and cannot load 32-bit plugin DLLs.

Interactive plugin add uses an asynchronous creation path. Lulada requests
node creation, JUCE-NSPA performs plugin instantiation on a winelib
`CreateThread` worker, then completion returns to the message thread for node
attachment and UI update. Large plugin descriptors and port lists therefore do
not block the DAW shell while they are materialized.

---

## 9. Window embedding and UI policy

Lulada uses JUCE-NSPA's embedded Win32 editor layer for plugin UI surfaces.
Plugin editors are Wine HWND-backed windows embedded under the DAW's native
Linux window tree.

| Surface | Owner | Current behavior |
|---|---|---|
| Main DAW shell | Lulada | GL-backed native application window, Session View, Arrangement, graph, mixer/channel surfaces, plugin manager, and internal dialogs |
| X11 plugin embed | JUCE-NSPA + Wine-NSPA | `WineHWNDEmbedComponent` creates the Win32 editor HWND and Wine-NSPA embeds the native X11 child under the host peer |
| Wayland plugin embed | JUCE-NSPA + Wine-NSPA | JUCE-NSPA owns the host `wl_display`; Wine creates a child `wl_surface` and installs it as a subsurface of the JUCE peer |
| Message pump | JUCE-NSPA | whole-thread queue pumping, input-first passes, and bounded general drain |
| Dialog policy | Lulada | Open Session, Save As, Import Graph, and Export Graph use JUCE internal choosers parented on the main content component |

The UI layer also uses a type-color system so graph blocks, wires, and channel
strips identify Audio I/O, JACK MIDI, VST2, VST3, CLAP, and internal nodes
without relying on plugin names.

---

## 10. Runtime boundary

| Boundary | Current behavior |
|---|---|
| Application type | Linux x86_64 Digital Audio Workstation |
| Runtime model | winelib application using Wine-NSPA for Win32 plugin execution |
| Window system | Wayland when available, X11 fallback |
| Audio/MIDI backend | JACK |
| Windows plugin formats | VST2, VST3, CLAP |
| Linux-native external plugin formats | excluded in the winelib configuration |
| Built-in processors | native Lulada graph nodes |
| Project model | session graph with clip, arrangement, tracker, piano-roll, sampler, automation, plugin, and routing state |

Startup prepares Wine state before plugin code executes: the host ensures a
wineserver socket exists, promotes the process with
`SetPriorityClass(GetCurrentProcess(), REALTIME_PRIORITY_CLASS)`, and calls
`OleInitialize(nullptr)` before plugin initialization reaches static
constructor-heavy code paths.

---

## 11. References

- `src/main.cc`
- `src/pluginmanager.cpp`
- `src/pluginprocessor.cpp`
- `src/plugineditor.cpp`
- `src/engine/graphmanager.cpp`
- `src/engine/jack.hpp`
- `src/engine/jack.cpp`
- `src/engine/clapprovider.cpp`
- `src/ui/sessionview.hpp`
- `src/ui/sessionview.cpp`
- `src/ui/arrangementview.hpp`
- `src/ui/arrangementview.cpp`
- `src/ui/pianoroll/pianoroll_view.cpp`
- `src/ui/pianoroll/pianoroll_grid.cpp`
- `src/ui/pianoroll/quantize_dialog.cpp`
- `src/ui/pluginwindow.cpp`
- `src/ui/pluginmanagercomponent.cpp`
- `src/ui/mainwindow.cpp`
- `src/ui/style_v1.cpp`
- `src/nodes/tracker.hpp`
- `src/nodes/tracker.cpp`
- `src/nodes/trackereditor.cpp`
- `src/nodes/sampler.hpp`
- `src/nodes/sampler.cpp`
- `src/nodes/midiplayer.cpp`
- `src/nodes/audioclip.cpp`
- `src/nodes/jackmidiinputnode.hpp`
- `src/nodes/jackmidioutputnode.hpp`
- `src/nodes/jackmidiinputallnode.hpp`
- `src/nodes/jackmidioutputallnode.hpp`
- `src/services/timeline/lane.hpp`
- `src/services/timeline/playlist.hpp`
- `src/services/timeline/midi_note_region.hpp`
- `src/services/audiostreaming/disk_stream.cpp`
- `src/services/audiostreaming/playback_ds.cpp`
- `src/services/audiostreaming/record_ds.cpp`
- `src/services/automation/automation_engine.cpp`
- `src/dsp/automation/automation_track.hpp`
- `src/dsp/automation/automation_region.hpp`
- `src/services/samplebankpool.cpp`
- `src/services/arrangementtracksservice.cpp`
- `CMakeLists.txt`
- [JUCE-NSPA](juce-nspa.gen.html)
- [NSPA X11 Embed Protocol](nspa-x11-embed-protocol.gen.html)
- [NSPA Wayland Embed Protocol](nspa-wayland-embed-protocol.gen.html)
