# Wine Window Decoration Feedback Loop -- Investigation Report

Historical investigation retained for reference. X11 was fixed by removing the
`WS_EX_LAYERED` MWM exclusion. The Wayland path has additional probing but
remains unvalidated.

**Bug:** WineHQ bug 57955 -- maximized/resized window decorations oscillate
**Affects:** All compositors (KDE/KWin, GNOME/Mutter), both X11 and Wayland drivers, also Wine desktop mode
**Regression range:** Wine 8.21 -> late 9.0-rc (likely around Wine 9.16)
---

## The Bug

When a decorated window is maximized, resized, or moved, the window rect oscillates -- causing menu bar flicker, content gaps, self-resizing on drag, and bottom content cutoff. The loop is continuous and never converges.

Tested with Ableton Live 12 on KDE/KWin (XWayland), but the bug reproduces:
- On both `winex11.drv` and `winewayland.drv`
- In Wine desktop mode (no window manager at all)
- With any app that has standard Win32 decorations (WS_CAPTION | WS_THICKFRAME)

---

## Root Cause

The feedback loop is in **win32u's `set_window_pos` chain**, not in the display drivers. The cycle:

    ConfigureNotify (from WM or Wine desktop)
      -> WM_WINE_WINDOW_STATE_CHANGED
      -> NtUserSetWindowPos (with WM's constrained rect)
      -> calc_ncsize -> sends WM_NCCALCSIZE -> computes client rect with NC area
      -> get_window_surface -> get_visible_rect -> computes visible = window - NC offsets
      -> apply_window_pos -> stores rects, calls pWindowPosChanged
      -> driver reconfigures window -> ConfigureNotify with different rect
      -> LOOP

### Why the rects never converge

Wine's `get_visible_rect` (dlls/win32u/window.c:2072) computes the visible rect by subtracting NC offsets from the window rect using `NtUserAdjustWindowRect`. These offsets use **Wine's built-in NC metrics** (border=4, caption=30), which don't match any real window manager's frame:

| Metric | Wine (NtUserAdjustWindowRect) | KWin (_NET_FRAME_EXTENTS) |
| --- | --- | --- |
| Left border | 4 | 6 |
| Right border | 4 | 6 |
| Top (caption) | 30 | 27 |
| Bottom border | 4 | 6 |
| **Total** | **72** | **90** |

Each cycle, `window_rect_from_visible` converts the WM's ConfigureNotify rect back to a window rect using Wine's stored offsets. The mismatch produces a different window rect every time. Specifically, a constant **-48px height delta** per cycle (observed in traces):

    NSPA_CFG 0x1009a config_vis (389,59)-(2430,1818) stored_vis (389,59)-(2430,1899) stored_win (389,59)-(2430,1899)
      -> new_win (389,59)-(2430,1818) old_win (389,59)-(2430,1899) delta(0,0,0,-81) flags 0x16

### Three observable failure modes

| Symptom | Trigger | Mechanism |
| --- | --- | --- |
| Left drift (-1px/frame) | Window move | Visible rect offset mismatch -> position conversion error |
| Height growth (+4px/frame) | Window resize | NC bottom border (4) vs WM bottom frame (6) accumulates |
| Menu bar flicker | Maximize/restore | State transition recalculates NC, offsets flip |
| Bottom content cutoff | Maximize | Visible rect 2px too tall (Wine border=4 vs KWin frame=6) |

### The SWP_FRAMECHANGED amplifier

In `apply_window_pos` (dlls/win32u/window.c:2277):

    if (old_surface != new_surface) swp_flags |= SWP_FRAMECHANGED;

Any visible rect change that triggers a new surface forces `SWP_FRAMECHANGED`, which triggers `WM_NCCALCSIZE`, which recalculates the NC area, which changes the visible rect -- amplifying the loop.

---

## The Likely Regression Commit

**Wine 9.16** -- "Move visible rect computation out of the drivers"

This commit:
1. Created `get_mwm_decorations_for_style()` split from `get_mwm_decorations()`
2. Created `X11DRV_GetWindowStyleMasks()`
3. **Moved `get_visible_rect()` from the X11 driver to win32u**
4. Changed the EqualRect check: old code checked `window == client`, new code checks `window == visible`

Before this commit, the X11 driver computed the visible rect directly using its own knowledge of the WM's frame. After this commit, win32u computes it using `NtUserAdjustWindowRect` -- which returns Wine's built-in metrics, not the WM's actual metrics.

---

## What We Tried (Driver-Level Fixes)

### 1. `_NET_FRAME_EXTENTS` driver callback (`pGetFrameExtents`)

**Implementation:** Added `_NET_FRAME_EXTENTS` atom + PropertyNotify handler to X11 driver. New `pGetFrameExtents` callback in `struct user_driver_funcs`. When KWin reports its frame extents, `get_visible_rect` uses them instead of `NtUserAdjustWindowRect`.

**Result:** Callback works correctly (verified: 5834 calls with correct extents `(-6,-27,6,6)`). But the loop continues because the app re-inflates to its preferred size via `WM_WINDOWPOSCHANGED` response. The WM constrains back, Wine re-inflates, loop.

**Code is in place:** Atom, PropertyNotify handler, pGetFrameExtents callback, X11DRV_GetFrameExtents -- all implemented and working. May be useful once the win32u fix is in place.

### 2. MWM decoration suppression for custom-chrome windows

**Tried:** `EqualRect(window, visible) -> no decorations` (upstream check) and `EqualRect(window, client) -> no decorations`.

**Result:** Both created chicken-and-egg loops -- no decorations -> no frame -> check re-triggers -> decorations oscillate between present and absent. The `window == visible` check is self-fulfilling (no decorations -> vis==win -> check says no decorations).

### 3. NSPA win32u patch (bypass EqualRect for decorated windows)

**Implementation:** Changed `get_visible_rect` line 2084 to `if (EqualRect(window, client) && !style_mask && !ex_style_mask)` -- applied decoration offset even when client==window.

**Result:** Caused **4px/frame unbounded height growth** for all windows. Traced via diagnostic ERR: 3378 NCCALCSIZE calls in one session, height increasing by 4px each cycle.

---

## Key Technical Details for Investigators

### Relevant source files

| File | Function | Role |
| --- | --- | --- |
| `dlls/win32u/window.c:2072` | `get_visible_rect` | Computes visible rect from window rect using NC offsets |
| `dlls/win32u/window.c:3682` | `calc_ncsize` | Sends WM_NCCALCSIZE, computes client rect |
| `dlls/win32u/window.c:2151` | `get_window_surface` | Calls get_visible_rect, creates surface |
| `dlls/win32u/window.c:2251` | `apply_window_pos` | Stores rects, calls driver, forces FRAMECHANGED on surface change |
| `dlls/win32u/window.c:3935` | `set_window_pos` | Main SWP entry: calc_winpos -> calc_ncsize -> get_window_surface -> apply_window_pos |
| `dlls/win32u/window.c:4778` | `update_window_state` | Lightweight SWP that recalculates visible rect |
| `dlls/win32u/message.c:2224` | `WM_WINE_WINDOW_STATE_CHANGED` | Entry from driver ConfigureNotify -> NtUserSetWindowPos |
| `include/wine/gdi_driver.h:63` | `window_rect_from_visible` | Converts visible -> window using stored offsets |
| `dlls/winex11.drv/window.c:1812` | `window_update_client_config` | Converts ConfigureNotify -> SWP flags + rect |

### The visible rect model

    struct window_rects {
        RECT window;   // Full Win32 window area (including NC frame)
        RECT client;   // Client area (from WM_NCCALCSIZE)
        RECT visible;  // X11/Wayland surface area (from get_visible_rect)
    };

`visible = window - decoration_offsets` where offsets come from `NtUserAdjustWindowRect` (Wine's NC metrics). The problem: these offsets don't match the actual WM frame.

### How to reproduce

Any decorated window on any Linux WM. Simple test:

    wine notepad  # then maximize, resize, move -- watch for drift/flicker

Ableton Live is a good test case because it's large and the artifacts are very visible.

### Diagnostic traces (currently in code)

ERR-level traces prefixed with `NSPA_DBG` and `NSPA_CFG` are active:
- `NSPA_DBG` in `get_visible_rect`: shows which frame source is used (AdjustWindowRect vs WM extents)
- `NSPA_DBG` in `window_net_frame_extents_notify`: shows when _NET_FRAME_EXTENTS arrives
- `NSPA_CFG` in `window_update_client_config`: shows ConfigureNotify rect vs stored rects vs computed window rect, with delta

---

## Directions to Investigate

### 1. Fix `get_visible_rect` to use actual WM frame metrics

The `pGetFrameExtents` callback infrastructure is already in place and working. The challenge: making it work for ALL windows (standard NC and custom-chrome) without breaking the surface/drawing model.

Key constraint: the visible rect determines the surface size. If visible < window, the surface is smaller than the app's drawing area. For standard NC windows this is fine (NC area is drawn by Wine). For custom-chrome windows (client==window), the app expects to draw the full window.

### 2. Suppress the re-inflation in set_window_pos

Something in the SWP chain (possibly `WM_WINDOWPOSCHANGED` -> app response, or `WM_GETMINMAXINFO`, or `SWP_FRAMECHANGED` amplifier) re-inflates the window after the WM constrains it. Find what and suppress it for WM-initiated position changes.

The `SWP_NOSENDCHANGING` flag (set for maximized/fullscreen in `window_update_client_config`) partially addresses this but doesn't fully prevent the loop.

### 3. Break the surface-change -> FRAMECHANGED -> NCCALCSIZE loop

In `apply_window_pos`:

    if (old_surface != new_surface) swp_flags |= SWP_FRAMECHANGED;

This forces NC recalculation whenever the surface changes. If the visible rect changes by even 1px (due to the offset mismatch), a new surface is created, FRAMECHANGED fires, NCCALCSIZE runs, and the cycle amplifies.

Consider: only set FRAMECHANGED when the surface size actually changes, not just the surface pointer.

### 4. Tolerance-based suppression in the driver

In `window_update_client_config`, suppress position/size updates when the delta is within the known frame-mismatch tolerance. This is a band-aid but might be effective as a short-term fix.

### 5. Bisect the upstream regression

The bug was introduced between Wine 8.21 and 9.0-rc. Key commits to examine:
- Wine 9.16: moved visible rect computation from drivers to win32u
- Wine 9.15: merged `CreateLayeredWindow` with `CreateWindowSurface`
- Wine 10.8: fixed the uninitialized `ex_style_mask` follow-on from the 9.16 change

### 6. Compare with how Windows handles this

On Windows, there's no WM frame mismatch -- the visible rect IS the window rect. The NC area is drawn by USER32, not a window manager. Wine's model of "visible rect = window minus WM frame" is an abstraction that doesn't exist on Windows. The fix may need to rethink this abstraction entirely.

---

## Trace Logs

All logs are in `nspa/docs/logs/`. Key files:

| Log file | What it captures |
| --- | --- |
| `ableton_diag.log` | NSPA_VIS + NSPA_NC diagnostic traces -- shows 4px/frame growth with old NSPA patch, 3378 NCCALCSIZE calls proving the loop. **The file that proved the NSPA patch was wrong.** |
| `ableton_win.log` | Full `+win` WINEDEBUG trace -- shows calc_winpos/get_visible_rect/apply_window_pos flow for every SWP. **The file that shows the 1px left drift and height growth patterns.** |
| `ableton_frame.log` | pGetFrameExtents callback trace -- shows 5834 successful calls with correct extents `(-6,-27)-(6,6)`, proving the callback works but doesn't fix the loop. |
| `ableton_cfg.log` | NSPA_CFG trace (first run) -- shows ConfigureNotify->window_rect_from_visible conversion with zero offsets (vis==win), proving the offset mismatch is the proximate cause. |
| `ableton_cfg2.log` | NSPA_CFG trace with frame extents bypass -- shows correct offsets but -48px delta per cycle as app re-inflates via WM_WINDOWPOSCHANGED. |
| `ableton_client.log` | client==window MWM check -- shows decoration oscillation (frame extents flipping 6,6,27,6 <-> 0,0,0,0). |
| `ableton_mwm.log` | Restored upstream window==visible MWM check -- shows self-fulfilling no-decoration loop (frame extents permanently 0,0,0,0). |

### How to read the traces

**NSPA_DBG in get_visible_rect:**

    NSPA_DBG hwnd 0x1009a using WM frame extents (-6,-27)-(6,6)
    NSPA_DBG hwnd 0x1009a using AdjustWindowRect (-4,-30)-(4,4) (no frame extents yet)

**NSPA_CFG in window_update_client_config:**

    NSPA_CFG 0x1009a config_vis (389,59)-(2430,1818) stored_vis (389,59)-(2430,1899) stored_win (389,59)-(2430,1899) -> new_win (389,59)-(2430,1818) old_win (389,59)-(2430,1899) delta(0,0,0,-81) flags 0x16

- `config_vis`: what KWin reported in ConfigureNotify (the actual X11 window position)
- `stored_vis`/`stored_win`: what Wine has stored from last SWP cycle
- `new_win`: what window_rect_from_visible computed (will become the new SetWindowPos input)
- `delta`: difference between new_win and old_win (position_x, position_y, width_change, height_change)
- `flags`: SWP flags (0x16 = SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE|SWP_NOSENDCHANGING)

---

## Current Code State

The working tree has these NSPA changes vs upstream:
1. `_NET_FRAME_EXTENTS` infrastructure (atom, PropertyNotify, pGetFrameExtents callback) -- in place, working
2. `get_mwm_decorations`: always requests decorations for managed windows based on style (stable, no chicken-and-egg)
3. `get_visible_rect`: upstream behavior restored (EqualRect + NtUserAdjustWindowRect)
4. Diagnostic ERR traces (NSPA_DBG, NSPA_CFG) -- should be removed before default-on use
5. WS_EX_LAYERED MWM exclusion removed (from earlier session, still correct)
