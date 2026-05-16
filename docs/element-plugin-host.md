# Wine-NSPA -- Element-NSPA

This page documents the Element-NSPA port that hosts Windows plugins through
JUCE-NSPA and Wine-NSPA.

## Table of Contents

1. [Overview](#1-overview)
2. [Why a separate port exists](#2-why-a-separate-port-exists)
3. [Host bootstrap](#3-host-bootstrap)
4. [Plugin formats and search paths](#4-plugin-formats-and-search-paths)
5. [Editor and UI behavior](#5-editor-and-ui-behavior)
6. [Integration with Wine-NSPA and JUCE-NSPA](#6-integration-with-wine-nspa-and-juce-nspa)
7. [Intentional boundaries](#7-intentional-boundaries)
8. [References](#8-references)

---

## 1. Overview

Element-NSPA is an application port that runs Element as a Linux winelib
binary while hosting Windows VST2 and VST3 plugins through Wine.

The port sits on top of JUCE-NSPA's framework changes, then adds the
application-level work Element needs:

- winelib host bootstrap before any plugin static initialization
- plugin-format selection and scanning rules that match a Windows-plugin host
- Wine-prefix path discovery so a fresh host finds Windows plugins
- editor-window behavior that matches the embedded Win32 GUI path

The result is not a generic Linux Element build. It is a Linux-hosted,
Wine-backed Windows plugin host.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .el-bg { fill: #1a1b26; }
    .el-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.4; rx: 8; }
    .el-app { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .el-host { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .el-plug { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .el-note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .el-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .el-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .el-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .el-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .el-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .el-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .el-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .el-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .el-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
    .el-line-p { stroke: #bb9af7; stroke-width: 1.3; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="430" class="el-bg"/>
  <text x="480" y="28" text-anchor="middle" class="el-title">Element winelib host layout</text>

  <rect x="45" y="86" width="230" height="118" class="el-app"/>
  <text x="160" y="112" text-anchor="middle" class="el-head-g">Element app shell</text>
  <text x="160" y="136" text-anchor="middle" class="el-small">graph, transport, plugin manager UI</text>
  <text x="160" y="152" text-anchor="middle" class="el-small">native Linux process, JUCE event loop</text>
  <text x="160" y="168" text-anchor="middle" class="el-small">scan path editing and editor windows</text>

  <rect x="335" y="70" width="290" height="150" class="el-host"/>
  <text x="480" y="96" text-anchor="middle" class="el-head-b">winelib host runtime</text>
  <text x="480" y="120" text-anchor="middle" class="el-small">`SetPriorityClass()` + `OleInitialize()` before plugin load</text>
  <text x="480" y="136" text-anchor="middle" class="el-small">JUCE-NSPA VST2 / VST3 loading and Win32 dispatch</text>
  <text x="480" y="152" text-anchor="middle" class="el-small">Wine-NSPA X11 embed path for plugin editors</text>
  <text x="480" y="168" text-anchor="middle" class="el-small">Wine-prefix VST path discovery</text>

  <rect x="685" y="86" width="230" height="118" class="el-plug"/>
  <text x="800" y="112" text-anchor="middle" class="el-head-p">Windows plugins</text>
  <text x="800" y="136" text-anchor="middle" class="el-small">VST2 `.dll` and VST3 PE modules</text>
  <text x="800" y="152" text-anchor="middle" class="el-small">editor HWNDs embedded into Linux UI</text>
  <text x="800" y="168" text-anchor="middle" class="el-small">loaded in-process through Wine</text>

  <line x1="275" y1="145" x2="335" y2="145" class="el-line-g"/>
  <line x1="625" y1="145" x2="685" y2="145" class="el-line-b"/>

  <rect x="170" y="286" width="620" height="82" class="el-note"/>
  <text x="480" y="314" text-anchor="middle" class="el-head-y">Application-level port</text>
  <text x="480" y="334" text-anchor="middle" class="el-small">JUCE-NSPA provides the framework substrate, but Element still needs</text>
  <text x="480" y="350" text-anchor="middle" class="el-small">its own scan policy, UI behavior, and runtime bootstrap as an application host</text>
</svg>
</div>

---

## 2. Why a separate port exists

Upstream Element is not built around a Linux winelib host for Windows plugins.
The port exists because the application has to make decisions that are more
specific than the JUCE framework layer:

- which plugin formats belong in this winelib process
- how scan paths should be derived from `WINEPREFIX`
- how the host should bootstrap COM and Win32 priority state before plugin load
- how the editor window and plugin-manager UI should behave once the plugin is
  a Wine-hosted Win32 surface instead of a native Linux plugin view

That is why this is an application port, not just "JUCE-NSPA plus a build
file."

| Concern | Generic Element assumption | Element-NSPA shape |
|---|---|---|
| Target plugin surface | native Linux formats plus platform-native host formats | Windows VST2 and VST3 through winelib + Wine |
| Default scan paths | native host defaults | Wine-prefix VST/VST3 directories are part of the default scan surface |
| Runtime bootstrap | native app bootstrap | OLE and Win32 process-class state prepared before plugin init |
| Editor hosting | native plugin editor assumptions | embedded Wine HWND-backed editor windows inside the Linux UI |

---

## 3. Host bootstrap

Element performs winelib host initialization before plugin code gets a chance
to run static constructors.

The current bootstrap does two things at namespace scope:

- `SetPriorityClass(GetCurrentProcess(), REALTIME_PRIORITY_CLASS)`
- `OleInitialize(nullptr)`

The order matters. Process-class promotion happens first so any helper threads
spawned during COM or plugin initialization inherit the intended Win32 priority
class.

This mirrors the host-side bootstrap needed by other Wine-NSPA Winelib hosts:
plugin code should see a valid OLE environment and the correct process-class
state before its own initialization tree starts.

---

## 4. Plugin formats and search paths

The Element port narrows its plugin surface to the Windows formats that make
sense inside a winelib host.

| Area | Current behavior |
|---|---|
| VST3 | enabled |
| VST2 | enabled, using the system Steinberg VST2 SDK 2.4 |
| LV2 | not registered under `__WINE__` |
| LADSPA | not registered under `__WINE__` |

The LV2 and LADSPA exclusions are deliberate. They are Linux-native plugin
formats, and loading them inside the same winelib process would bring in
unrelated native plugin trees and their copies of framework globals. For this
host, that is the wrong process boundary.

### 3.1 Wine-prefix path discovery

Element also augments default search paths with Windows-plugin directories
inside `WINEPREFIX`.

Current additions are:

- `drive_c/Program Files/Common Files/VST2`
- `drive_c/Program Files/Steinberg/VstPlugins`
- `drive_c/Program Files/Common Files/VST`
- `drive_c/Program Files/Common Files/VST3`

The 32-bit `Program Files (x86)` paths are intentionally not added. This host
is x86_64 winelib, so 32-bit plugin DLLs are not loadable here and would only
pollute scan results with permanently broken entries.

### 3.2 Plugin-path UI

The plugin-path editor is also adjusted for the winelib host model:

- VST and VST3 path editing stays visible in the UI
- the modal path editor runs asynchronously instead of blocking the event loop
- fresh installs pick up the Wine-prefix defaults even before the user edits
  scan paths manually

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .sp-bg { fill: #1a1b26; }
    .sp-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.4; rx: 8; }
    .sp-g { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .sp-b { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .sp-p { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .sp-r { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.8; rx: 8; }
    .sp-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .sp-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .sp-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .sp-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .sp-head-r { fill: #f7768e; font: bold 11px 'JetBrains Mono', monospace; }
    .sp-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .sp-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .sp-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .sp-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
    .sp-line-p { stroke: #bb9af7; stroke-width: 1.3; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="420" class="sp-bg"/>
  <text x="480" y="28" text-anchor="middle" class="sp-title">Scan surface under the winelib Element host</text>

  <rect x="70" y="96" width="220" height="100" class="sp-g"/>
  <text x="180" y="122" text-anchor="middle" class="sp-head-g">default path builder</text>
  <text x="180" y="144" text-anchor="middle" class="sp-small">JUCE defaults + `WINEPREFIX` augmentation</text>
  <text x="180" y="160" text-anchor="middle" class="sp-small">VST and VST3 stay discoverable on a fresh install</text>

  <rect x="370" y="78" width="220" height="136" class="sp-b"/>
  <text x="480" y="104" text-anchor="middle" class="sp-head-b">enabled formats</text>
  <text x="480" y="128" text-anchor="middle" class="sp-small">VST</text>
  <text x="480" y="144" text-anchor="middle" class="sp-small">VST3</text>
  <text x="480" y="160" text-anchor="middle" class="sp-small">scan UI remains visible for both</text>
  <text x="480" y="176" text-anchor="middle" class="sp-small">path editor keeps the event loop alive</text>

  <rect x="670" y="96" width="220" height="100" class="sp-p"/>
  <text x="780" y="122" text-anchor="middle" class="sp-head-p">plugin load target</text>
  <text x="780" y="144" text-anchor="middle" class="sp-small">64-bit Windows plugin modules only</text>
  <text x="780" y="160" text-anchor="middle" class="sp-small">no `(x86)` auto-seed in this host</text>

  <rect x="300" y="276" width="360" height="74" class="sp-r"/>
  <text x="480" y="304" text-anchor="middle" class="sp-head-r">intentionally excluded</text>
  <text x="480" y="324" text-anchor="middle" class="sp-small">LV2 and LADSPA stay out of the winelib process</text>

  <line x1="290" y1="146" x2="370" y2="146" class="sp-line-g"/>
  <line x1="590" y1="146" x2="670" y2="146" class="sp-line-b"/>
</svg>
</div>

---

## 5. Editor and UI behavior

The editor path follows JUCE-NSPA's embedded Win32 GUI model, so plugin editor
windows are still real Wine HWND-backed windows inside a Linux UI tree.

Element adds two application-level adjustments on top of that:

- the PluginWindow toolbar is disabled in the current port so the plugin editor
  fills the full content area instead of leaving a dead gap
- editor window behavior is aligned to the host's embedded-child layout rather
  than the older internal toolbar reservation assumptions

This keeps the application UI aligned to the Winelib plugin host shape instead
of preserving native-Linux assumptions that no longer fit.

The port also carries one winelib-specific runtime fix in the Lua side:
`setjmp` use is written in a form that bypasses glibc's macro rewrite and keeps
the runtime on glibc's `setjmp()` implementation instead of resolving into
Wine's MSVCRT `_setjmp` path.

### 5.1 Application-level adjustments

The application port carries a small set of Element-specific choices above the
JUCE-NSPA framework layer.

| Area | Current behavior |
|---|---|
| Plugin-window chrome | toolbar path is disabled so the embedded editor fills the full content area |
| Path editing UI | plugin path editor uses an async modal flow so file choosers still open under the winelib host |
| Format list in the UI | VST and VST3 stay exposed; LV2/LADSPA do not become active scan targets in this process |
| Lua runtime | `setjmp` macro bypass keeps the runtime on glibc's `setjmp()` path |

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 390" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ap-bg { fill: #1a1b26; }
    .ap-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.4; rx: 8; }
    .ap-app { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .ap-host { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .ap-ui { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .ap-note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .ap-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .ap-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .ap-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .ap-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .ap-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .ap-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .ap-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .ap-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="390" class="ap-bg"/>
  <text x="480" y="28" text-anchor="middle" class="ap-title">Element-NSPA application policy on top of JUCE-NSPA</text>

  <rect x="65" y="94" width="240" height="104" class="ap-app"/>
  <text x="185" y="120" text-anchor="middle" class="ap-head-g">Element application layer</text>
  <text x="185" y="144" text-anchor="middle" class="ap-small">plugin manager, node graph, editor windows</text>
  <text x="185" y="160" text-anchor="middle" class="ap-small">application-level scan and UI decisions</text>

  <rect x="360" y="80" width="240" height="132" class="ap-host"/>
  <text x="480" y="106" text-anchor="middle" class="ap-head-b">host policy</text>
  <text x="480" y="130" text-anchor="middle" class="ap-small">Wine-prefix path augmentation</text>
  <text x="480" y="146" text-anchor="middle" class="ap-small">LV2/LADSPA exclusion in this process</text>
  <text x="480" y="162" text-anchor="middle" class="ap-small">OLE + process-class bootstrap before plugin init</text>
  <text x="480" y="178" text-anchor="middle" class="ap-small">winelib-safe path editor and runtime fixes</text>

  <rect x="655" y="94" width="240" height="104" class="ap-ui"/>
  <text x="775" y="120" text-anchor="middle" class="ap-head-p">visible result</text>
  <text x="775" y="144" text-anchor="middle" class="ap-small">Windows plugins scan and open normally</text>
  <text x="775" y="160" text-anchor="middle" class="ap-small">embedded editors fit the host UI without extra chrome</text>

  <line x1="305" y1="146" x2="360" y2="146" class="ap-line-g"/>
  <line x1="600" y1="146" x2="655" y2="146" class="ap-line-b"/>

  <rect x="180" y="272" width="600" height="68" class="ap-note"/>
  <text x="480" y="300" text-anchor="middle" class="ap-head-y">Scope</text>
  <text x="480" y="318" text-anchor="middle" class="ap-small">these are application decisions above the JUCE-NSPA framework layer,</text>
  <text x="480" y="334" text-anchor="middle" class="ap-small">not generic framework behavior</text>
</svg>
</div>

---

## 6. Integration with Wine-NSPA and JUCE-NSPA

Element-NSPA sits on top of both framework and runtime layers.

| Layer | Use in Element-NSPA |
|---|---|
| JUCE-NSPA | Winelib build support, VST2/VST3 Windows-plugin loading, Win32 dispatch, and editor embedding substrate |
| Wine-NSPA X11 embed protocol | embeds plugin editor HWNDs under Linux host windows |
| Wine-NSPA Win32 runtime | supplies the window/message model and Wine-side plugin module loading path |
| Wine-NSPA-oriented PI layer | inherited where JUCE-NSPA's dispatcher and sync wrappers use vendored `rtpi.h` |

The practical advantages of the ported shape are therefore technical:

- plugin scan and load rules match the actual Windows-plugin target set
- the host does not need a second wrapper layer just to display plugin editors
- application code can treat Windows VST2 and VST3 hosting as part of the
  normal Element runtime instead of a sidecar process boundary

The port still depends on the lower layers for the hard parts. Element itself
adds the application policy, bootstrap order, and UI behavior on top.

---

## 7. Intentional boundaries

The current Element port is intentionally narrow.

| Boundary | Current behavior |
|---|---|
| Host architecture | Linux-only x86_64 winelib host |
| Supported Windows plugin formats | VST2 and VST3 |
| Linux-native plugin formats in this process | excluded |
| Scan path policy | 64-bit Windows-plugin directories only |

This page is therefore about a specific application port shape, not a claim
that every Element feature or every native-Linux plugin surface should live in
the same process as the winelib Windows-plugin host.

---

## 8. References

- `src/main.cc`
- `src/utils.cpp`
- `src/pluginmanager.cpp`
- `src/ui/pluginmanagercomponent.cpp`
- `src/ui/pluginwindow.cpp`
- [JUCE-NSPA](juce-nspa.gen.html)
- [NSPA X11 Embed Protocol](nspa-x11-embed-protocol.gen.html)
