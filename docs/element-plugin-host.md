# Wine-NSPA -- Element-NSPA

This page documents the Element-NSPA application port that hosts Windows
plugins through JUCE-NSPA and Wine-NSPA while also exposing a JACK-first native
MIDI path inside the same graph.

## Table of Contents

1. [Overview](#1-overview)
2. [Why a separate port exists](#2-why-a-separate-port-exists)
3. [Host bootstrap](#3-host-bootstrap)
4. [Plugin surface and scan policy](#4-plugin-surface-and-scan-policy)
5. [JACK-first MIDI graph path](#5-jack-first-midi-graph-path)
6. [Editor and UI behavior](#6-editor-and-ui-behavior)
7. [Relationship to JUCE-NSPA and Wine-NSPA](#7-relationship-to-juce-nspa-and-wine-nspa)
8. [Current scope](#8-current-scope)
9. [References](#9-references)

---

## 1. Overview

Element-NSPA is a Linux winelib build of Element that hosts Windows VST2 and
VST3 plugins in-process through Wine. It is not just "Element built with a
different compiler". The port changes the runtime contract at three different
surfaces:

- Windows plugin load and scan policy
- Win32 editor embedding inside a native Linux UI tree
- JACK-first native MIDI integration for the graph itself

That last point matters. The current Element JACK build is no longer treating
ALSA-seq as the primary MIDI surface and then bolting JACK on afterward. It now
has native JACK MIDI input/output ports, per-port graph nodes, sample-offset
preserving ingress, and per-port outbound routing. The implementation is still
work-in-progress, but it is already functional and load-bearing.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 560" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ov-bg { fill: #1a1b26; }
    .ov-lane { fill: #1f2535; stroke: #3b4261; stroke-width: 1.2; rx: 10; }
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
    .ov-line-r { stroke: #f7768e; stroke-width: 1.4; fill: none; stroke-dasharray: 5,3; }
  </style>

  <rect x="0" y="0" width="980" height="560" class="ov-bg"/>
  <text x="490" y="26" text-anchor="middle" class="ov-title">Element-NSPA: application policy + winelib plugin hosting + JACK-first MIDI</text>

  <rect x="24" y="52" width="932" height="468" class="ov-lane"/>
  <text x="42" y="72" class="ov-small">single Linux process, mixed native + Wine-backed responsibilities</text>

  <rect x="46" y="94" width="250" height="158" class="ov-native"/>
  <text x="171" y="118" text-anchor="middle" class="ov-head-g">Element application layer</text>
  <text x="171" y="140" text-anchor="middle" class="ov-small">plugin manager, graph editor, session/UI shell</text>
  <text x="171" y="156" text-anchor="middle" class="ov-small">async plugin-path editor under winelib</text>
  <text x="171" y="172" text-anchor="middle" class="ov-small">toolbar-free plugin windows for embedded editors</text>
  <text x="171" y="188" text-anchor="middle" class="ov-small">root graph owns top-level JACK MIDI routing choices</text>
  <text x="171" y="214" text-anchor="middle" class="ov-text">application policy lives here</text>

  <rect x="364" y="82" width="252" height="182" class="ov-host"/>
  <text x="490" y="106" text-anchor="middle" class="ov-head-b">JUCE-NSPA / winelib host substrate</text>
  <text x="490" y="128" text-anchor="middle" class="ov-small">winegcc / wineg++ build, PE module loading</text>
  <text x="490" y="144" text-anchor="middle" class="ov-small">Win32 ABI fixes, `LoadLibraryW()`, per-instance dispatch</text>
  <text x="490" y="160" text-anchor="middle" class="ov-small">`WineHWNDEmbedComponent` + Win32 pump</text>
  <text x="490" y="176" text-anchor="middle" class="ov-small">`WM_X11DRV_NSPA_EMBED_WINDOW` / `EMBED_DONE` handshake</text>
  <text x="490" y="202" text-anchor="middle" class="ov-text">framework layer reused by the app</text>

  <rect x="684" y="94" width="250" height="158" class="ov-plugin"/>
  <text x="809" y="118" text-anchor="middle" class="ov-head-p">Windows plugins</text>
  <text x="809" y="140" text-anchor="middle" class="ov-small">VST2 `.dll` and VST3 PE modules</text>
  <text x="809" y="156" text-anchor="middle" class="ov-small">editor HWNDs embedded under Linux peers</text>
  <text x="809" y="172" text-anchor="middle" class="ov-small">Win32 message flow and plugin callbacks stay intact</text>
  <text x="809" y="198" text-anchor="middle" class="ov-text">loaded in-process through Wine</text>

  <rect x="46" y="308" width="888" height="128" class="ov-jack"/>
  <text x="490" y="334" text-anchor="middle" class="ov-head-y">JACK-first audio / MIDI engine inside Element</text>
  <text x="490" y="356" text-anchor="middle" class="ov-small">audio callback and JACK process callback are the same RT thread in practice</text>
  <text x="490" y="372" text-anchor="middle" class="ov-small">native `midi_in_N` ingress preserves JACK sample offsets into JUCE MidiBuffers</text>
  <text x="490" y="388" text-anchor="middle" class="ov-small">`JackMidiInputNode` reads per-port buffers</text>
  <text x="490" y="404" text-anchor="middle" class="ov-small">`JackMidiOutputNode` stages outbound events per port</text>
  <text x="490" y="420" text-anchor="middle" class="ov-small">current outbound path is one-period delayed through an mlocked ringbuffer</text>
  <text x="490" y="436" text-anchor="middle" class="ov-small">sample-accurate output scheduling is still follow-up work</text>

  <rect x="110" y="454" width="760" height="46" class="ov-note"/>
  <text x="490" y="482" text-anchor="middle" class="ov-head-r">Result</text>
  <text x="490" y="498" text-anchor="middle" class="ov-small">Windows plugin hosting, native JACK MIDI routing, and Linux UI/editor ownership</text>
  <text x="490" y="512" text-anchor="middle" class="ov-small">all live in one process, but they are not the same layer</text>

  <line x1="296" y1="174" x2="364" y2="174" class="ov-line-g"/>
  <line x1="616" y1="174" x2="684" y2="174" class="ov-line-b"/>
  <path d="M171 252 L171 308" class="ov-line-g"/>
  <path d="M490 264 L490 308" class="ov-line-b"/>
  <path d="M809 252 L809 308" class="ov-line-p"/>
  <path d="M490 308 L490 252" class="ov-line-r"/>
</svg>
</div>

---

## 2. Why a separate port exists

Upstream Element is not designed around a Linux winelib host for Windows
plugins. The application layer still has to make decisions that are more
specific than the JUCE framework layer:

- which plugin formats belong in this process
- how scan paths should be derived from `WINEPREFIX`
- how early the host has to bootstrap COM and Win32 process-class state
- how plugin editor windows should fit a Linux UI tree once they are real Wine
  HWND-backed children
- how JACK MIDI should be treated in the graph when the primary plugin-host
  target is a low-latency JACK workflow

That is why this is an application port, not just "JUCE-NSPA plus a build
file."

| Concern | Generic Element assumption | Element-NSPA shape |
|---|---|---|
| Plugin target | native Linux formats plus platform-native host formats | Windows VST2 and VST3 through winelib + Wine |
| Scan defaults | native host defaults | Wine-prefix VST/VST3 directories are part of the default scan surface |
| Runtime bootstrap | native app bootstrap | namespace-scope `SetPriorityClass()` + `OleInitialize()` before plugin init |
| Editor hosting | native plugin editor assumptions | embedded Wine HWND-backed editor windows in the Linux UI |
| MIDI shape on JACK builds | generic Linux MIDI backends | JACK-first native MIDI ports plus graph nodes; ALSA-seq is no longer the central model |

---

## 3. Host bootstrap

Element performs winelib host initialization before plugin code gets a chance
to run static constructors.

The current bootstrap does two things at namespace scope:

- `SetPriorityClass(GetCurrentProcess(), REALTIME_PRIORITY_CLASS)`
- `OleInitialize(nullptr)`

The order matters. Process-class promotion happens first so any helper threads
spawned during COM or plugin initialization inherit the intended Win32 priority
class before Wine-NSPA maps those priorities to Linux scheduler state.

This mirrors the host-side bootstrap used by the other Wine-NSPA winelib hosts:
plugin code should see a valid OLE environment and the correct process-class
state before its own initialization tree starts.

---

## 4. Plugin surface and scan policy

The Element port narrows its plugin surface to the Windows formats that make
sense inside this winelib host.

| Area | Current behavior |
|---|---|
| VST3 | enabled |
| VST2 | enabled, using the system Steinberg VST2 SDK 2.4 |
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

The 32-bit `Program Files (x86)` paths are intentionally not added. This host
is x86_64 winelib, so 32-bit plugin DLLs are not loadable here and would only
pollute scan results with permanently broken entries.

### 4.2 Plugin-path UI

The plugin-path editor is also adjusted for the winelib host model:

- VST and VST3 path editing stays visible in the UI
- the modal path editor runs asynchronously instead of blocking the event loop
- fresh installs pick up the Wine-prefix defaults even before the user edits
  scan paths manually

The practical goal is that a clean Wine prefix plus a clean Element profile can
still find Windows plugins without requiring the user to know the port's
internal assumptions first.

---

## 5. JACK-first MIDI graph path

The current Element JACK MIDI implementation is **functional WIP**. The
important distinction is between "not finished" and "not real". This is not a
placeholder anymore. The following pieces are live now:

- native JACK MIDI input and output port registration
- user-configurable JACK MIDI port counts
- per-port enable masks read directly by the RT callback
- a combined graph-wide JACK MIDI input surface
- per-port `JackMidiInputNode` and `JackMidiOutputNode`
- optional Program Change -> `setCurrentProgram()` translation on the input
  node

### 5.1 What "JACK-first" means right now

`JackAudioIODevice::process()` is the timing authority. JACK ingress, Element's
audio callback, graph MIDI consumption, and outbound MIDI staging all happen on
that same callback thread.

Current inbound shape:

1. `jack_midi_event_get()` reads events from each enabled `midi_in_N` port.
2. Element writes those bytes into:
   - `currentPeriodMidiInput` for the graph-wide "any JACK MIDI" path
   - `currentPeriodMidiInputPerPort[N]` for explicit per-port routing
3. Each event keeps `jack_midi_event_t::time` as its sample offset within the
   current JACK period.
4. `AudioEngine` reads the combined buffer on the same callback thread.
5. `JackMidiInputNode` reads one per-port buffer on that same callback thread.

Current outbound shape:

1. `JackMidiOutputNode` iterates its incoming `juce::MidiBuffer`.
2. Each event is written into `outMidiRb` as
   `[port][size_lo][size_hi][raw bytes...]`.
3. On the next JACK period, the same callback drains `outMidiRb`.
4. Events are written to `jack_midi_event_write()` on `midi_out_N` at sample
   offset `0`.

That last point is why this is still WIP. Ingress is same-period and preserves
sample offsets. Egress is per-port and fully functional, but currently lands on
the next period at offset `0`. The code deliberately chooses correctness and RT
safety first, then finer output scheduling later.

### 5.2 Not literally zero-copy, but zero-thread-hop

The current implementation is **not** literal end-to-end zero-copy:

- ingress copies JACK event bytes into JUCE `MidiBuffer` storage
- egress copies outbound events into the mlocked JACK ringbuffer

What it *does* remove is the wrong abstraction boundary:

- no ALSA-seq millisecond quantization as the primary JACK-build path
- no helper consumer thread between JACK ingress and Element graph consumption
- no cross-thread handoff before the graph sees the event

So the current value is best described as **JACK-first, same-thread, and
sample-offset-preserving on ingress**, not as "every byte stays in place
forever".

At a code-shape level, the current callback path looks like this:

```cpp
for (int port = 0; port < midiInputPorts.size(); ++port) {
    void* jackBuf = jack_port_get_buffer(midiInputPorts[port], numFrames);
    jack_midi_event_t ev {};

    for (uint32_t i = 0; jack_midi_event_get(&ev, jackBuf, i) == 0; ++i) {
        currentPeriodMidiInput.addEvent(ev.buffer, ev.size, (int) ev.time);
        currentPeriodMidiInputPerPort[port].addEvent(ev.buffer, ev.size,
                                                     (int) ev.time);
    }
}

for (const auto meta : outputMidi) {
    outMidiRb.write(&portIndex, 1);
    outMidiRb.write(&sizeLo, 1);
    outMidiRb.write(&sizeHi, 1);
    outMidiRb.write(meta.data, meta.numBytes);
}
```

That is the current contract in one screen: same-period JACK ingress writes
directly into the per-period JUCE buffers with preserved sample offsets, while
egress stages per-port bytes for the next callback period.

### 5.3 Port model and graph exposure

The host now exposes JACK MIDI as actual graph topology instead of a hidden
device side effect.

| Surface | Current behavior |
|---|---|
| Port counts | audio and MIDI both use the same Auto / 2 / 4 / 8 / 16 / 32 shape |
| Input exposure | graph-wide combined JACK MIDI input plus one `JackMidiInputNode` per configured port |
| Output exposure | one `JackMidiOutputNode` per configured `midi_out_N` port |
| Port enable state | input/output enable masks are atomically read once per JACK period |
| Graph UI | right-click menu lists live `midi_in_N` / `midi_out_N` entries with connection state |

`JackMidiInputNode` also has one focused extra behavior: it can optionally
translate inbound MIDI Program Change into a message-thread
`setCurrentProgram()` walk over every downstream plugin reachable through MIDI
connections. The MIDI Program Change event itself is still forwarded in the RT
stream; the extra dispatcher call is additive, not a replacement.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 620" xmlns="http://www.w3.org/2000/svg">
  <style>
    .jm-bg { fill: #1a1b26; }
    .jm-lane { fill: #1f2535; stroke: #3b4261; stroke-width: 1.2; rx: 10; }
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
    .jm-line-r { stroke: #f7768e; stroke-width: 1.4; fill: none; stroke-dasharray: 5,3; }
  </style>

  <rect x="0" y="0" width="980" height="620" class="jm-bg"/>
  <text x="490" y="26" text-anchor="middle" class="jm-title">Element JACK MIDI: same-period ingress, next-period egress</text>

  <rect x="28" y="50" width="924" height="534" class="jm-lane"/>

  <rect x="48" y="88" width="250" height="166" class="jm-rt"/>
  <text x="173" y="112" text-anchor="middle" class="jm-head-g">JACK process callback / RT thread</text>
  <text x="173" y="136" text-anchor="middle" class="jm-small">authoritative timing source</text>
  <text x="173" y="152" text-anchor="middle" class="jm-small">reads `jack_midi_event_get()` from enabled `midi_in_N`</text>
  <text x="173" y="168" text-anchor="middle" class="jm-small">preserves `ev.time` as sample offset within this period</text>
  <text x="173" y="184" text-anchor="middle" class="jm-small">later drains `outMidiRb` into `midi_out_N` on the next period</text>
  <text x="173" y="210" text-anchor="middle" class="jm-text">same thread also runs Element's audio callback</text>

  <rect x="364" y="76" width="252" height="190" class="jm-buf"/>
  <text x="490" y="100" text-anchor="middle" class="jm-head-b">Per-period MIDI state inside `JackAudioIODevice`</text>
  <text x="490" y="124" text-anchor="middle" class="jm-small">`currentPeriodMidiInput`</text>
  <text x="490" y="140" text-anchor="middle" class="jm-small">combined buffer for graph-wide JACK MIDI ingress</text>
  <text x="490" y="164" text-anchor="middle" class="jm-small">`currentPeriodMidiInputPerPort[N]`</text>
  <text x="490" y="180" text-anchor="middle" class="jm-small">per-port buffers for explicit routing nodes</text>
  <text x="490" y="204" text-anchor="middle" class="jm-small">cleared at the start of every period</text>
  <text x="490" y="220" text-anchor="middle" class="jm-small">read synchronously by the graph on the same callback</text>

  <rect x="682" y="88" width="230" height="166" class="jm-node"/>
  <text x="797" y="112" text-anchor="middle" class="jm-head-p">Element graph layer</text>
  <text x="797" y="136" text-anchor="middle" class="jm-small">AudioEngine consumes combined JACK MIDI input</text>
  <text x="797" y="152" text-anchor="middle" class="jm-small">`JackMidiInputNode(port=N)` consumes one per-port buffer</text>
  <text x="797" y="168" text-anchor="middle" class="jm-small">optional PC relay triggers message-thread `setCurrentProgram()` walk</text>
  <text x="797" y="184" text-anchor="middle" class="jm-small">`JackMidiOutputNode(port=N)` stages outbound events</text>
  <text x="797" y="210" text-anchor="middle" class="jm-text">per-port graph routing is real now</text>

  <rect x="110" y="324" width="760" height="154" class="jm-ring"/>
  <text x="490" y="348" text-anchor="middle" class="jm-head-y">Outbound staging path</text>
  <text x="490" y="372" text-anchor="middle" class="jm-small">`JackMidiOutputNode` writes `[port][size_lo][size_hi][data...]` into mlocked `outMidiRb`</text>
  <text x="490" y="388" text-anchor="middle" class="jm-small">writer and reader are the same RT thread at different points in the callback cycle</text>
  <text x="490" y="404" text-anchor="middle" class="jm-small">drain happens at the start of the next JACK period</text>
  <text x="490" y="420" text-anchor="middle" class="jm-small">and writes to `jack_midi_event_write(..., sample_offset=0)`</text>
  <text x="490" y="430" text-anchor="middle" class="jm-text">functional now; finer outbound sample scheduling is a follow-up</text>

  <rect x="184" y="508" width="612" height="48" class="jm-note"/>
  <text x="490" y="534" text-anchor="middle" class="jm-head-r">Current truth</text>
  <text x="490" y="550" text-anchor="middle" class="jm-small">not literal zero-copy, but no helper-thread hop between JACK ingress</text>
  <text x="490" y="566" text-anchor="middle" class="jm-small">and graph consumption, and no ALSA-seq-first timing model</text>

  <line x1="298" y1="170" x2="364" y2="170" class="jm-line-g"/>
  <line x1="616" y1="170" x2="682" y2="170" class="jm-line-b"/>
  <path d="M797 254 L797 324" class="jm-line-p"/>
  <path d="M236 324 L236 254" class="jm-line-r"/>
  <path d="M236 254 L236 324" class="jm-line-y"/>
</svg>
</div>

---

## 6. Editor and UI behavior

The editor path follows JUCE-NSPA's embedded Win32 GUI model, so plugin editor
windows are still real Wine HWND-backed windows inside a Linux UI tree.

Element adds a small but important application policy layer on top:

- the `PluginWindow` toolbar path is disabled so the embedded editor fills the
  content area instead of reserving dead chrome
- plugin path dialogs run asynchronously so the winelib host does not stall its
  own event processing during file chooser use
- the Lua side bypasses glibc's `setjmp` macro rewrite so the runtime stays on
  glibc's `setjmp()` instead of resolving into Wine's MSVCRT `_setjmp` path

The port also inherits the newer embed contract from Wine-NSPA:

- `WM_X11DRV_NSPA_EMBED_DONE` is the explicit completion fence if the host wants
  one
- the host owns X11 sizing of the embedded child
- Wine owns the Win32-side rect state and message semantics

That split is why the editor path behaves like one coherent window instead of a
Linux wrapper pretending to be the plugin.

---

## 7. Relationship to JUCE-NSPA and Wine-NSPA

Element-NSPA sits on top of both framework and runtime layers.

| Layer | Use in Element-NSPA |
|---|---|
| JUCE-NSPA | winelib build support, VST2/VST3 Windows-plugin loading, Win32 dispatch, and editor embedding substrate |
| Wine-NSPA X11 embed protocol | embeds plugin editor HWNDs under Linux host windows without a second wrapper protocol |
| Wine-NSPA Win32 runtime | supplies the window/message model and Wine-side plugin module loading path |
| Element-specific JACK layer | exposes JACK-first MIDI routing inside the graph on top of the same host process |

The practical advantages of the ported shape are technical:

- plugin scan and load rules match the actual Windows-plugin target set
- the host does not need a sidecar GUI bridge just to display editors
- JACK MIDI enters the graph on the same RT callback thread that owns the audio
  period
- application code can treat Windows VST hosting and native JACK routing as one
  runtime, even though they live on different layers internally

---

## 8. Current scope

The current Element port is intentionally narrow.

| Boundary | Current behavior |
|---|---|
| Host architecture | Linux-only x86_64 winelib host |
| Supported Windows plugin formats | VST2 and VST3 |
| Linux-native plugin formats in this process | excluded |
| JACK MIDI status | functional WIP: ingress, egress, per-port nodes, and PC relay are live; outbound scheduling and graph-surface cleanup still have follow-up work |
| Scan path policy | 64-bit Windows-plugin directories only |

This page therefore describes a specific application port shape, not a claim
that every Element feature or every native-Linux plugin surface should live in
the same process as the winelib Windows-plugin host.

---

## 9. References

- `src/main.cc`
- `src/utils.cpp`
- `src/pluginmanager.cpp`
- `src/ui/pluginmanagercomponent.cpp`
- `src/ui/pluginwindow.cpp`
- `src/engine/jack.{h,cpp}`
- `src/nodes/jackmidiinputnode.hpp`
- `src/nodes/jackmidioutputnode.hpp`
- `src/services/engineservice.cpp`
- `src/ui/grapheditorcomponent.cpp`
- [JUCE-NSPA](juce-nspa.gen.html)
- [NSPA X11 Embed Protocol](nspa-x11-embed-protocol.gen.html)
