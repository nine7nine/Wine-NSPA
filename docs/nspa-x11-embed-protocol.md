# Wine-NSPA -- NSPA X11 Embed Protocol

This page documents Wine-NSPA's X11 embed protocol for winelib hosts that need
to place a Wine HWND-backed X11 child under a foreign Linux parent window.

## Table of Contents

1. [Overview](#1-overview)
2. [Public contract](#2-public-contract)
3. [Embed lifecycle](#3-embed-lifecycle)
4. [Geometry and resize ownership](#4-geometry-and-resize-ownership)
5. [Consumer pump discipline](#5-consumer-pump-discipline)
6. [Input and drag correctness](#6-input-and-drag-correctness)
7. [Current consumers](#7-current-consumers)
8. [References](#8-references)

---

## 1. Overview

The embed protocol gives a winelib host one supported way to reparent a Wine
window into a foreign X11 parent without reimplementing Wine's embedded-window
bookkeeping itself.

The problem it solves is not just `XReparentWindow()`. A working host also
needs Wine to:

- flip the window into embedded mode
- register the foreign parent for host-window tracking
- preserve the correct parent-relative origin at the moment embedded mode locks
- avoid emitting the wrong X11 move/size requests after the handoff
- keep Win32 hit-testing and cursor math coherent while the host moves or
  resizes the embedded surface

Wine-NSPA exposes that as a small driver-private message contract instead of
making each host rebuild the old wrapper-window and synthetic event machinery.

---

## 2. Public contract

The supported interface lives in `include/wine/nspa_x11_embed.h`.

| Symbol | Meaning |
|---|---|
| `WM_X11DRV_NSPA_EMBED_WINDOW` | request atomic embed under an external X11 parent |
| `WM_X11DRV_NSPA_EMBED_DONE` | async completion message posted after reparent + map + state settle |

### 2.1 `WM_X11DRV_NSPA_EMBED_WINDOW`

Send the message to the top-level Wine HWND that owns the X11 child.

| Field | Meaning |
|---|---|
| `wParam` | X11 `Window` id of the foreign parent |
| `lParam` | `MAKELPARAM(peerX, peerY)` using parent-relative coordinates |

`peerX` and `peerY` are load-bearing. Wine locks embedded-mode position state
when the window flips into embedded mode, so the initial reparent has to use
the host's intended parent-relative origin.

### 2.2 `WM_X11DRV_NSPA_EMBED_DONE`

Wine posts `WM_X11DRV_NSPA_EMBED_DONE` back to the same HWND after:

- `XReparentWindow()`
- `XMapWindow()`
- the WM state cycle has settled

The message is asynchronous. It lands on the HWND's message queue and is
observed when the host's Win32 message pump runs.

### 2.3 Consumer responsibilities

The protocol does not make the host passive. After the embed handoff:

- the host owns X11 parentage
- the host owns X11 sizing with `XMoveResizeWindow()` or equivalent
- the host still uses `SetWindowPos()` so Wine's Win32-side rects track the
  correct absolute screen location
- the host pumps the embedded HWND's thread queue with a bounded general drain

That split is deliberate: Wine keeps Win32 state authoritative, while the host
keeps the X11 embed tree authoritative.

### 2.4 Minimal host-side flow

The working host-side sequence is small, but each step is load-bearing:

```cpp
SendMessageW(embedHwnd, WM_X11DRV_NSPA_EMBED_WINDOW,
             (WPARAM) foreignParent,
             MAKELPARAM(peerX, peerY));

for (;;) {
    while (PeekMessageW(&msg, nullptr, WM_MOUSEFIRST, WM_MOUSELAST, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    while (PeekMessageW(&msg, nullptr, WM_KEYFIRST, WM_KEYLAST, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    const auto deadlineMs = now_ms() + 4;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_X11DRV_NSPA_EMBED_DONE)
            goto embed_done;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
        if (now_ms() >= deadlineMs)
            break;
    }

    poll_linux_host_events();
}

embed_done:
    ;
```

After that completion edge, the host still owns X11 geometry:

```cpp
SetWindowPos(embedHwnd, 0, screenX, screenY, width, height, SWP_NOZORDER);
XMoveResizeWindow(display, wineChild, peerX, peerY, width, height);
```

That split is the protocol. `SetWindowPos()` keeps Wine's Win32-side rects
honest; `XMoveResizeWindow()` keeps the foreign-parent X11 tree honest.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 420" xmlns="http://www.w3.org/2000/svg">
  <style>
    .ep-bg { fill: #1a1b26; }
    .ep-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.4; rx: 8; }
    .ep-host { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .ep-msg { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .ep-w32 { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .ep-x11 { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .ep-note { fill: #1f2435; stroke: #6b7398; stroke-width: 1.2; rx: 8; }
    .ep-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .ep-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .ep-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .ep-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .ep-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .ep-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .ep-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .ep-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .ep-line-y { stroke: #e0af68; stroke-width: 1.3; fill: none; }
    .ep-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
    .ep-line-p { stroke: #bb9af7; stroke-width: 1.3; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="420" class="ep-bg"/>
  <text x="480" y="28" text-anchor="middle" class="ep-title">NSPA X11 embed handshake</text>

  <rect x="40" y="88" width="200" height="110" class="ep-host"/>
  <text x="140" y="114" text-anchor="middle" class="ep-head-g">winelib host</text>
  <text x="140" y="136" text-anchor="middle" class="ep-small">owns foreign X11 parent</text>
  <text x="140" y="152" text-anchor="middle" class="ep-small">computes `peerX`, `peerY`</text>
  <text x="140" y="168" text-anchor="middle" class="ep-small">calls `SendMessageW()`</text>

  <rect x="290" y="88" width="180" height="110" class="ep-msg"/>
  <text x="380" y="114" text-anchor="middle" class="ep-head-y">embed request</text>
  <text x="380" y="136" text-anchor="middle" class="ep-small">`WM_X11DRV_NSPA_EMBED_WINDOW`</text>
  <text x="380" y="152" text-anchor="middle" class="ep-small">`wParam = parent X11 Window`</text>
  <text x="380" y="168" text-anchor="middle" class="ep-small">`lParam = MAKELPARAM(peerX, peerY)`</text>

  <rect x="520" y="88" width="180" height="110" class="ep-w32"/>
  <text x="610" y="114" text-anchor="middle" class="ep-head-b">win32u routing</text>
  <text x="610" y="136" text-anchor="middle" class="ep-small">driver-private message range</text>
  <text x="610" y="152" text-anchor="middle" class="ep-small">message reaches `winex11.drv`</text>
  <text x="610" y="168" text-anchor="middle" class="ep-small">from PE or winelib caller</text>

  <rect x="750" y="88" width="170" height="110" class="ep-x11"/>
  <text x="835" y="114" text-anchor="middle" class="ep-head-p">`winex11.drv`</text>
  <text x="835" y="136" text-anchor="middle" class="ep-small">reparent + mark embedded</text>
  <text x="835" y="152" text-anchor="middle" class="ep-small">map child X11 window</text>
  <text x="835" y="168" text-anchor="middle" class="ep-small">post `EMBED_DONE`</text>

  <line x1="240" y1="143" x2="290" y2="143" class="ep-line-g"/>
  <line x1="470" y1="143" x2="520" y2="143" class="ep-line-y"/>
  <line x1="700" y1="143" x2="750" y2="143" class="ep-line-b"/>

  <rect x="160" y="260" width="640" height="96" class="ep-note"/>
  <text x="480" y="288" text-anchor="middle" class="ep-head-b">Stable result</text>
  <text x="480" y="308" text-anchor="middle" class="ep-small">Wine's Win32-side rects keep tracking the child HWND</text>
  <text x="480" y="324" text-anchor="middle" class="ep-small">the host owns the foreign X11 parent and future X11 sizing</text>
  <text x="480" y="340" text-anchor="middle" class="ep-small">the embed handshake ends with `WM_X11DRV_NSPA_EMBED_DONE` instead of a timing guess</text>

  <line x1="835" y1="198" x2="835" y2="228" class="ep-line-p"/>
  <line x1="835" y1="228" x2="480" y2="228" class="ep-line-p"/>
  <line x1="480" y1="228" x2="480" y2="260" class="ep-line-p"/>
</svg>
</div>

---

## 3. Embed lifecycle

The runtime sequence is:

1. the host creates a real top-level Wine HWND
2. the host resolves the backing X11 child and the foreign X11 parent
3. the host sends `WM_X11DRV_NSPA_EMBED_WINDOW`
4. `winex11.drv` reparents the child at the supplied parent-relative origin
5. Wine flips the window to embedded mode and records the foreign parent
6. Wine maps the X11 child and posts `WM_X11DRV_NSPA_EMBED_DONE`

Two details matter:

- the reparent happens before embedded-mode position locking
- the embed path is idempotent with respect to parent changes, so the same HWND
  can be re-embedded under a new parent when the host changes peer structure

This is why the protocol replaces a pile of host-local X11 bookkeeping instead
of just hiding one `XReparentWindow()` call.

---

## 4. Geometry and resize ownership

After the embed handoff, geometry ownership is intentionally split.

| Path | Owner | Why |
|---|---|---|
| parent-relative X11 position and size | host | the host owns the foreign parent window tree |
| Win32 `RECT` state, hit-testing, and message dispatch | Wine | the plugin still runs as a Win32 window |

In practice that means:

- the host calls `SetWindowPos()` when the embedded child moves in screen space
- the host also calls `XMoveResizeWindow()` or `xcb_configure_window()` on the
  embedded X11 child when the parent-relative X11 geometry changes
- Wine suppresses its own X11 position and size emission for
  `nspa_embedded` windows so the embedder stays authoritative at the X11 layer

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 390" xmlns="http://www.w3.org/2000/svg">
  <style>
    .go-bg { fill: #1a1b26; }
    .go-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.4; rx: 8; }
    .go-host { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .go-w32 { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .go-x11 { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .go-note { fill: #2a2418; stroke: #e0af68; stroke-width: 1.6; rx: 8; }
    .go-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .go-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .go-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .go-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .go-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .go-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .go-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .go-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .go-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
    .go-line-p { stroke: #bb9af7; stroke-width: 1.3; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="390" class="go-bg"/>
  <text x="480" y="28" text-anchor="middle" class="go-title">Geometry split after embedding</text>

  <rect x="60" y="90" width="250" height="104" class="go-host"/>
  <text x="185" y="116" text-anchor="middle" class="go-head-g">host layout</text>
  <text x="185" y="138" text-anchor="middle" class="go-small">peer-relative area changes</text>
  <text x="185" y="154" text-anchor="middle" class="go-small">toolbar offsets, parent moves, resize callbacks</text>
  <text x="185" y="170" text-anchor="middle" class="go-small">host decides X11 child geometry</text>

  <rect x="355" y="90" width="250" height="104" class="go-w32"/>
  <text x="480" y="116" text-anchor="middle" class="go-head-b">Win32 side</text>
  <text x="480" y="138" text-anchor="middle" class="go-small">`SetWindowPos()` updates Wine rects</text>
  <text x="480" y="154" text-anchor="middle" class="go-small">mouse hit-testing and plugin window messages stay correct</text>
  <text x="480" y="170" text-anchor="middle" class="go-small">no host-local synthetic message translation needed</text>

  <rect x="650" y="90" width="250" height="104" class="go-x11"/>
  <text x="775" y="116" text-anchor="middle" class="go-head-p">X11 side</text>
  <text x="775" y="138" text-anchor="middle" class="go-small">host calls `XMoveResizeWindow()`</text>
  <text x="775" y="154" text-anchor="middle" class="go-small">Wine suppresses its own X11 move/size emission</text>
  <text x="775" y="170" text-anchor="middle" class="go-small">foreign parent remains authoritative</text>

  <line x1="310" y1="143" x2="355" y2="143" class="go-line-g"/>
  <line x1="605" y1="143" x2="650" y2="143" class="go-line-b"/>

  <rect x="145" y="248" width="670" height="74" class="go-note"/>
  <text x="480" y="276" text-anchor="middle" class="go-head-y">Why the split exists</text>
  <text x="480" y="296" text-anchor="middle" class="go-small">Wine owns Win32 semantics, but the host owns the foreign X11 parent tree</text>
  <text x="480" y="312" text-anchor="middle" class="go-small">keeping both layers authoritative in their own domain</text>
  <text x="480" y="328" text-anchor="middle" class="go-small">avoids duplicate move logic and stale geometry</text>
</svg>
</div>

---

## 5. Consumer pump discipline

`WM_X11DRV_NSPA_EMBED_DONE` is only one part of the consumer contract. The
host-side message pump also matters.

The incorrect shape is an unbounded `while (PeekMessage)` drain on the same
thread that must return to X11 polling. A redraw-heavy plugin can keep the
queue non-empty with `WM_TIMER` and `WM_PAINT`, which means:

- the Win32 pump never returns
- the Linux host stops polling X11
- queued X11 mouse and keyboard input never reaches the plugin editor

The required shape is:

| Rule | Why |
|---|---|
| pump the whole thread queue, not just the top-level HWND | child editor windows carry paint, mouse, and keyboard traffic |
| dispatch mouse and keyboard ranges ahead of the general drain | redraw-heavy backlogs should not bury interactive input |
| bound the general drain by time or message count | the host thread must return to X11 polling predictably |

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 430" xmlns="http://www.w3.org/2000/svg">
  <style>
    .pd-bg { fill: #1a1b26; }
    .pd-host { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .pd-input { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .pd-gen { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .pd-x11 { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .pd-warn { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.6; rx: 8; }
    .pd-note { fill: #1f2435; stroke: #6b7398; stroke-width: 1.2; rx: 8; }
    .pd-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .pd-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .pd-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .pd-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .pd-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .pd-head-r { fill: #f7768e; font: bold 11px 'JetBrains Mono', monospace; }
    .pd-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .pd-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .pd-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .pd-line-y { stroke: #e0af68; stroke-width: 1.3; fill: none; }
    .pd-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
    .pd-line-p { stroke: #bb9af7; stroke-width: 1.3; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="430" class="pd-bg"/>
  <text x="480" y="28" text-anchor="middle" class="pd-title">Bounded consumer pump for embedded Wine HWNDs</text>

  <rect x="44" y="94" width="184" height="110" class="pd-host"/>
  <text x="136" y="120" text-anchor="middle" class="pd-head-g">host tick</text>
  <text x="136" y="142" text-anchor="middle" class="pd-small">JUCE timer callback</text>
  <text x="136" y="158" text-anchor="middle" class="pd-small">or host event-loop turn</text>
  <text x="136" y="174" text-anchor="middle" class="pd-small">same thread also polls X11</text>

  <rect x="274" y="94" width="184" height="110" class="pd-input"/>
  <text x="366" y="120" text-anchor="middle" class="pd-head-y">input-first pass</text>
  <text x="366" y="142" text-anchor="middle" class="pd-small">drain `WM_MOUSEFIRST..LAST`</text>
  <text x="366" y="158" text-anchor="middle" class="pd-small">then `WM_KEYFIRST..LAST`</text>
  <text x="366" y="174" text-anchor="middle" class="pd-small">whole thread queue, `hwnd = nullptr`</text>

  <rect x="504" y="94" width="184" height="110" class="pd-gen"/>
  <text x="596" y="120" text-anchor="middle" class="pd-head-b">general drain</text>
  <text x="596" y="142" text-anchor="middle" class="pd-small">all remaining Win32 messages</text>
  <text x="596" y="158" text-anchor="middle" class="pd-small">bounded by time or count</text>
  <text x="596" y="174" text-anchor="middle" class="pd-small">stop after `EMBED_DONE` or the budget</text>

  <rect x="734" y="94" width="184" height="110" class="pd-x11"/>
  <text x="826" y="120" text-anchor="middle" class="pd-head-p">return to host poll</text>
  <text x="826" y="142" text-anchor="middle" class="pd-small">service X11 button, motion, key</text>
  <text x="826" y="158" text-anchor="middle" class="pd-small">keep editor interaction live</text>
  <text x="826" y="174" text-anchor="middle" class="pd-small">host retains wall-clock fairness</text>

  <line x1="228" y1="150" x2="274" y2="150" class="pd-line-g"/>
  <line x1="458" y1="150" x2="504" y2="150" class="pd-line-y"/>
  <line x1="688" y1="150" x2="734" y2="150" class="pd-line-b"/>

  <rect x="126" y="258" width="708" height="72" class="pd-note"/>
  <text x="480" y="286" text-anchor="middle" class="pd-head-b">Current consumer shapes</text>
  <text x="480" y="306" text-anchor="middle" class="pd-small">JUCE-NSPA: input-first mouse/keyboard passes + 4 ms general-drain budget</text>
  <text x="480" y="322" text-anchor="middle" class="pd-small">Element-NSPA: inherits JUCE-NSPA exactly</text>
  <text x="480" y="338" text-anchor="middle" class="pd-small">Yabridge-NSPA: input-first passes + 20-message cap, extended to 8192 for JUCE floods</text>

  <rect x="166" y="350" width="628" height="56" class="pd-warn"/>
  <text x="480" y="382" text-anchor="middle" class="pd-head-r">Failure mode avoided</text>
  <text x="480" y="398" text-anchor="middle" class="pd-small">an unbounded general drain can loop forever on `WM_TIMER` + `WM_PAINT`</text>
  <text x="480" y="414" text-anchor="middle" class="pd-small">and starve the host's X11 poll</text>
</svg>
</div>

---

## 6. Input and drag correctness

Two follow-on pieces keep embedded editors usable under host motion and plugin
cursor save/restore behavior.

### 6.1 Host-drag rect propagation

When the host moves the embedded child at the X11 layer, Wine also updates the
Win32-side rect state for the embedded HWND. That keeps:

- USER32 hit-testing
- screen-to-client coordinate translation
- plugin code that queries window position

in sync with the host's actual X11 layout.

### 6.2 Button-state freeze and cursor-jump suppression

During click-drag-release sequences, plugins may save screen coordinates on
mouse-down and call `SetCursorPos()` on release. Mid-drag rect churn can make
that restore point wrong.

Wine-NSPA therefore:

- freezes host-drag rect updates while mouse buttons are held on an embedded
  child
- suppresses the cursor-warp-on-release mismatch that showed up on embedded
  VST editors

The result is not a generic mouse optimization. It is targeted correctness for
embedded Win32 editors living inside foreign X11 hosts.

---

## 7. Current consumers

The protocol is currently used by Wine-NSPA winelib hosts that embed Win32
plugin editors into native Linux UI trees.

| Consumer | Use |
|---|---|
| JUCE-NSPA | `WineHWNDEmbedComponent` creates a real Wine HWND, pumps the full thread queue with input-first mouse/keyboard passes, and bounds the general drain to 4 ms per timer tick |
| Element-NSPA | inherits JUCE-NSPA's embed component, X11 sizing split, and bounded input-first pump for VST2, VST3, and CLAP editors |
| Yabridge-NSPA | keeps a wrapper window as the immediate host-owned parent, hands the Wine child off through the atomic embed message, and uses input-first passes plus a capped general drain in `HostBridge::handle_events()` |

The protocol stays intentionally small. It is a Wine-side primitive for hosts
that already manage a foreign X11 parent, not a full host toolkit.

---

## 8. References

- `include/wine/nspa_x11_embed.h`
- `dlls/win32u/message.c`
- `dlls/winex11.drv/window.c`
- `dlls/winex11.drv/mouse.c`
- [JUCE-NSPA](juce-nspa.gen.html)
- [Element-NSPA](element-plugin-host.gen.html)
- [Yabridge-NSPA](yabridge-nspa.gen.html)
