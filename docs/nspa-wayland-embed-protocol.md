# Wine-NSPA -- NSPA Wayland Embed Protocol

This page documents the Wayland host/plugin embedding path for winelib hosts
that need Wine plugin surfaces to live inside a native Wayland application.

## Table of Contents

1. [Overview](#1-overview)
2. [Public contract](#2-public-contract)
3. [Display adoption](#3-display-adoption)
4. [Per-window embed lifecycle](#4-per-window-embed-lifecycle)
5. [Input and RT locking](#5-input-and-rt-locking)
6. [Relationship to X11 embedding](#6-relationship-to-x11-embedding)
7. [Current consumers](#7-current-consumers)
8. [References](#8-references)

---

## 1. Overview

The Wayland embed path lets a winelib host render Wine plugin windows as
`wl_subsurface` children of a host-owned `wl_surface`. It is the Wayland
counterpart to the X11 embed protocol, but the ownership model is stricter:
Wayland only allows subsurface parentage when both surfaces live on the same
`wl_display` connection.

Wine-NSPA solves that by letting the host publish its `wl_display` before
`winewayland.drv` initializes. In host mode, the driver adopts that display,
binds its own Wayland globals on the same connection, and creates plugin
surfaces as children of host surfaces.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 980 520" xmlns="http://www.w3.org/2000/svg">
  <style>
    .wy-bg { fill: #1a1b26; }
    .wy-lane { fill: #1f2535; stroke: #6b7398; stroke-width: 1.2; rx: 10; }
    .wy-host { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .wy-env { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .wy-wine { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .wy-plugin { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .wy-note { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.6; rx: 8; }
    .wy-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .wy-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .wy-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .wy-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .wy-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .wy-head-r { fill: #f7768e; font: bold 11px 'JetBrains Mono', monospace; }
    .wy-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .wy-text { fill: #c0caf5; font: 10px 'JetBrains Mono', monospace; }
    .wy-line-g { stroke: #9ece6a; stroke-width: 1.4; fill: none; }
    .wy-line-y { stroke: #e0af68; stroke-width: 1.4; fill: none; }
    .wy-line-b { stroke: #7aa2f7; stroke-width: 1.4; fill: none; }
    .wy-line-p { stroke: #bb9af7; stroke-width: 1.4; fill: none; }
  </style>

  <rect x="0" y="0" width="980" height="520" class="wy-bg"/>
  <text x="490" y="28" text-anchor="middle" class="wy-title">Wayland host/plugin embedding: one process, one wl_display, two ownership domains</text>

  <rect x="28" y="58" width="924" height="402" class="wy-lane"/>

  <rect x="54" y="104" width="220" height="132" class="wy-host"/>
  <text x="164" y="130" text-anchor="middle" class="wy-head-g">winelib host</text>
  <text x="164" y="152" text-anchor="middle" class="wy-small">JUCE-NSPA Wayland peer</text>
  <text x="164" y="168" text-anchor="middle" class="wy-small">owns the parent `wl_surface`</text>
  <text x="164" y="184" text-anchor="middle" class="wy-small">drives the event loop</text>
  <text x="164" y="208" text-anchor="middle" class="wy-text">calls `wine_nspa_wayland_set_display()`</text>

  <rect x="328" y="104" width="210" height="132" class="wy-env"/>
  <text x="433" y="130" text-anchor="middle" class="wy-head-y">process-local handoff</text>
  <text x="433" y="152" text-anchor="middle" class="wy-small">`WINE_NSPA_WAYLAND_HOST`</text>
  <text x="433" y="168" text-anchor="middle" class="wy-small">`WINE_NSPA_WAYLAND_DISPLAY`</text>
  <text x="433" y="184" text-anchor="middle" class="wy-small">value is PID-stamped</text>
  <text x="433" y="208" text-anchor="middle" class="wy-text">pre-driver initialization contract</text>

  <rect x="592" y="104" width="220" height="132" class="wy-wine"/>
  <text x="702" y="130" text-anchor="middle" class="wy-head-b">`winewayland.drv`</text>
  <text x="702" y="152" text-anchor="middle" class="wy-small">adopts host `wl_display`</text>
  <text x="702" y="168" text-anchor="middle" class="wy-small">binds compositor / subcompositor / seat</text>
  <text x="702" y="184" text-anchor="middle" class="wy-small">does not open a second connection</text>
  <text x="702" y="208" text-anchor="middle" class="wy-text">Wine-side window state remains authoritative</text>

  <rect x="204" y="306" width="250" height="94" class="wy-plugin"/>
  <text x="329" y="332" text-anchor="middle" class="wy-head-p">plugin HWND surface</text>
  <text x="329" y="354" text-anchor="middle" class="wy-small">fresh Wine `wl_surface`</text>
  <text x="329" y="370" text-anchor="middle" class="wy-small">role changes to foreign subsurface</text>
  <text x="329" y="386" text-anchor="middle" class="wy-small">position set parent-relative</text>

  <rect x="526" y="306" width="250" height="94" class="wy-note"/>
  <text x="651" y="332" text-anchor="middle" class="wy-head-r">host-owned parent</text>
  <text x="651" y="354" text-anchor="middle" class="wy-small">same display identity is verified</text>
  <text x="651" y="370" text-anchor="middle" class="wy-small">foreign-surface input enters are ignored</text>
  <text x="651" y="386" text-anchor="middle" class="wy-small">host keeps parent lifecycle authority</text>

  <line x1="274" y1="170" x2="328" y2="170" class="wy-line-g"/>
  <line x1="538" y1="170" x2="592" y2="170" class="wy-line-y"/>
  <path d="M702 236 L702 276 L329 276 L329 306" class="wy-line-b"/>
  <line x1="454" y1="354" x2="526" y2="354" class="wy-line-p"/>
</svg>
</div>

---

## 2. Public contract

The supported interface lives in `include/wine/nspa_wayland_embed.h`.

| Symbol | Meaning |
|---|---|
| `WINE_NSPA_WAYLAND_HOST` | host-mode marker; tells `winewayland.drv` to wait for display adoption instead of opening its own connection |
| `WINE_NSPA_WAYLAND_DISPLAY` | PID-stamped pointer handoff for the host `wl_display` |
| `wine_nspa_wayland_set_display()` | host helper that publishes the current process id and `wl_display` pointer |
| `WM_WAYLANDDRV_NSPA_EMBED_WINDOW` | request that a Wine HWND become a `wl_subsurface` of a host `wl_surface` |
| `WM_WAYLANDDRV_NSPA_EMBED_DONE` | async completion message posted after the subsurface install path runs |

The display handoff is process-local. Child Wine helper processes that inherit
the environment do not reuse the parent's pointer because the value is checked
against `getpid()`.

---

## 3. Display adoption

Wayland embedding has to avoid a load-order race. A driver export would be too
late because `winewayland.drv` initializes as soon as it is loaded. The host
therefore publishes the display pointer before the first Wine GUI call.

The host-side sequence is:

```cpp
setenv ("WINE_NSPA_WAYLAND_HOST", "1", 1);
wine_nspa_wayland_set_display (juceWaylandDisplay);
```

Then `winewayland.drv` initializes against the host connection:

1. read `WINE_NSPA_WAYLAND_HOST`
2. parse `WINE_NSPA_WAYLAND_DISPLAY`
3. accept it only if the PID matches the current process
4. bind `wl_compositor`, `wl_subcompositor`, `wl_shm`, `xdg_wm_base`,
   `wp_viewporter`, and `wl_seat` on that display
5. skip the normal `wl_display_connect()` path for this process

When the environment is absent or invalid, the Wayland driver follows the
normal standalone Wine path.

---

## 4. Per-window embed lifecycle

Once the plugin has an HWND, the host sends
`WM_WAYLANDDRV_NSPA_EMBED_WINDOW` to that window.

| Message field | Meaning |
|---|---|
| `wParam` | host parent `wl_surface*` |
| `lParam` | packed parent-relative `peerX`, `peerY` coordinates |

The driver path:

1. resolves `wayland_win_data` for the HWND
2. verifies that the foreign parent belongs to the adopted `wl_display`
3. destroys any existing Wine surface for that HWND
4. creates a fresh role-less `wl_surface`
5. assigns it as a `wl_subsurface` of the host parent
6. records embedded state and parent-relative coordinates
7. posts `WM_WAYLANDDRV_NSPA_EMBED_DONE`

The fresh-surface step is important. Wayland surface roles are not mutable once
a buffer has committed in a role such as `xdg_toplevel`, so the embed message
must run before plugin editor attach paths cause a first commit.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 960 390" xmlns="http://www.w3.org/2000/svg">
  <style>
    .wl-bg { fill: #1a1b26; }
    .wl-host { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .wl-msg { fill: #2a2418; stroke: #e0af68; stroke-width: 1.8; rx: 8; }
    .wl-wine { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .wl-plug { fill: #2a2137; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .wl-note { fill: #24283b; stroke: #6b7398; stroke-width: 1.2; rx: 8; }
    .wl-title { fill: #7aa2f7; font: bold 14px 'JetBrains Mono', monospace; }
    .wl-head-g { fill: #9ece6a; font: bold 11px 'JetBrains Mono', monospace; }
    .wl-head-y { fill: #e0af68; font: bold 11px 'JetBrains Mono', monospace; }
    .wl-head-b { fill: #7aa2f7; font: bold 11px 'JetBrains Mono', monospace; }
    .wl-head-p { fill: #bb9af7; font: bold 11px 'JetBrains Mono', monospace; }
    .wl-small { fill: #a9b1d6; font: 9px 'JetBrains Mono', monospace; }
    .wl-line-g { stroke: #9ece6a; stroke-width: 1.3; fill: none; }
    .wl-line-y { stroke: #e0af68; stroke-width: 1.3; fill: none; }
    .wl-line-b { stroke: #7aa2f7; stroke-width: 1.3; fill: none; }
    .wl-line-p { stroke: #bb9af7; stroke-width: 1.3; fill: none; }
  </style>

  <rect x="0" y="0" width="960" height="390" class="wl-bg"/>
  <text x="480" y="28" text-anchor="middle" class="wl-title">Per-window Wayland embed lifecycle</text>

  <rect x="42" y="88" width="190" height="102" class="wl-host"/>
  <text x="137" y="114" text-anchor="middle" class="wl-head-g">host peer</text>
  <text x="137" y="136" text-anchor="middle" class="wl-small">owns parent `wl_surface`</text>
  <text x="137" y="152" text-anchor="middle" class="wl-small">has adopted display live</text>
  <text x="137" y="168" text-anchor="middle" class="wl-small">sends embed message</text>

  <rect x="280" y="88" width="190" height="102" class="wl-msg"/>
  <text x="375" y="114" text-anchor="middle" class="wl-head-y">driver message</text>
  <text x="375" y="136" text-anchor="middle" class="wl-small">`WM_WAYLANDDRV_NSPA_EMBED_WINDOW`</text>
  <text x="375" y="152" text-anchor="middle" class="wl-small">parent surface + peer coords</text>
  <text x="375" y="168" text-anchor="middle" class="wl-small">before plugin attach commits</text>

  <rect x="518" y="88" width="190" height="102" class="wl-wine"/>
  <text x="613" y="114" text-anchor="middle" class="wl-head-b">winewayland.drv</text>
  <text x="613" y="136" text-anchor="middle" class="wl-small">verify same display</text>
  <text x="613" y="152" text-anchor="middle" class="wl-small">create fresh surface</text>
  <text x="613" y="168" text-anchor="middle" class="wl-small">assign foreign subsurface role</text>

  <rect x="756" y="88" width="162" height="102" class="wl-plug"/>
  <text x="837" y="114" text-anchor="middle" class="wl-head-p">plugin editor</text>
  <text x="837" y="136" text-anchor="middle" class="wl-small">renders into Wine surface</text>
  <text x="837" y="152" text-anchor="middle" class="wl-small">host surface is parent</text>
  <text x="837" y="168" text-anchor="middle" class="wl-small">completion message follows</text>

  <line x1="232" y1="139" x2="280" y2="139" class="wl-line-g"/>
  <line x1="470" y1="139" x2="518" y2="139" class="wl-line-y"/>
  <line x1="708" y1="139" x2="756" y2="139" class="wl-line-b"/>

  <rect x="170" y="260" width="620" height="70" class="wl-note"/>
  <text x="480" y="286" text-anchor="middle" class="wl-head-b">Role timing rule</text>
  <text x="480" y="306" text-anchor="middle" class="wl-small">the host sends the embed request before VST/CLAP editor attach calls</text>
  <text x="480" y="322" text-anchor="middle" class="wl-small">so the Wine surface can become a subsurface before the plugin commits a buffer</text>
</svg>
</div>

---

## 5. Input and RT locking

Two follow-on changes make the host-mode path usable for plugin editors in an
RT-oriented process.

| Area | Current behavior |
|---|---|
| Foreign-surface enter events | pointer and keyboard enter events on host-owned foreign surfaces are ignored by `winewayland.drv`; the host remains owner of its own surface focus |
| Driver mutexes | `winewayland.drv` internal pthread mutexes are converted to Wine-NSPA `pi_mutex_t` so Wayland driver locks follow the same priority-inheritance policy as the rest of the RT stack |
| Initialization guard | the lazy Wayland initialization path avoids a non-PI pthread mutex on the RT thread |

This matters because host-mode embedding puts native host surfaces and Wine
plugin surfaces in one process and one Wayland connection. The Wine driver must
not claim input focus for the host shell, and it must not introduce ordinary
pthread-mutex inversion into the RT process.

---

## 6. Relationship to X11 embedding

The X11 and Wayland protocols solve the same application problem with different
window-system primitives.

| Area | X11 path | Wayland path |
|---|---|---|
| Parent type | X11 `Window` id | `wl_surface*` |
| Wine child type | Wine X11 child window | Wine `wl_surface` |
| Attach primitive | `XReparentWindow()` + embedded-state bookkeeping | `wl_subsurface` under a foreign host surface |
| Connection rule | host and Wine can use independent X11 clients | host and Wine must share one `wl_display` |
| Display handoff | not needed | host publishes `wl_display` before driver init |
| Completion message | `WM_X11DRV_NSPA_EMBED_DONE` | `WM_WAYLANDDRV_NSPA_EMBED_DONE` |

The consumer pump discipline is shared: embedded editors need input-first queue
passes and a bounded general drain so plugin redraw or timer traffic cannot
starve the native host loop.

---

## 7. Current consumers

| Consumer | Use |
|---|---|
| JUCE-NSPA | provides the Wayland peer surface and exposes the host `wl_display` used by Wine-NSPA's Wayland driver |
| Lulada | enables the JUCE-NSPA Wayland backend for the application shell and embeds Windows plugin editors through the Wine-NSPA Wayland path on Wayland sessions |

Yabridge-NSPA still uses the X11 embed path because its editor bridge keeps a
wrapper X11 window as the immediate foreign parent.

---

## 8. References

- `include/wine/nspa_wayland_embed.h`
- `dlls/winewayland.drv/window.c`
- `dlls/winewayland.drv/wayland.c`
- `dlls/winewayland.drv/wayland_pointer.c`
- `dlls/winewayland.drv/wayland_keyboard.c`
- [NSPA X11 Embed Protocol](nspa-x11-embed-protocol.gen.html)
- [JUCE-NSPA](juce-nspa.gen.html)
- [Lulada](element-plugin-host.gen.html)
