# Wine-NSPA Audio Stack

This page explains how Wine-NSPA moves Windows audio through winejack, how nspaASIO fits into that stack, and which timing-critical work stays inside the JACK callback.

## Table of Contents

1. [Overview](#1-overview)
2. [Backend constraints and JACK selection](#2-backend-constraints-and-jack-selection)
3. [Stack layering](#3-stack-layering)
4. [winejack.drv: the JACK backend for Wine](#4-winejackdrv-the-jack-backend-for-wine)
5. [WASAPI surface and shared mode](#5-wasapi-surface-and-shared-mode)
6. [Exclusive mode and the fast path](#6-exclusive-mode-and-the-fast-path)
7. [MIDI](#7-midi)
8. [nspaASIO: the ASIO bridge](#8-nspaasio-the-asio-bridge)
9. [Direct callback path: zero-latency bufferSwitch in the JACK callback](#9-direct-callback-path-zero-latency-bufferswitch-in-the-jack-callback)
10. [Intentionally unimplemented surfaces](#10-intentionally-unimplemented-surfaces)
11. [Deferred work](#11-deferred-work)
12. [Other audio drivers](#12-other-audio-drivers)
13. [Validation](#13-validation)
14. [References](#14-references)

---

## 1. Overview

The Wine-NSPA audio stack provides deterministic low-latency WASAPI and ASIO transport on PREEMPT_RT systems. Validation focuses on DAW workloads, but the same backend serves any Windows audio application that opens WASAPI or ASIO.

The audio stack consists of three components that work together:

1. **winejack.drv** is a Wine audio driver that exposes a JACK backend to Wine's WASAPI surface and to WinMM MIDI. It replaces the role that `winealsa.drv` and `winepulse.drv` play in upstream Wine. One driver, two transports: WASAPI audio over JACK audio ports, and WinMM MIDI over JACK MIDI ports.
2. **nspaASIO** is a vendored ASIO driver shipped as `dlls/nspaasio`. It implements the COM `IASIO` interface that DAWs probe for, and routes the ASIO callback model into a path that ends at `winejack.drv` and JACK. It does not ship its own JACK client; it delegates to winejack so that ASIO and WASAPI applications share a single transport.
3. **The direct callback path** closes the loop on latency. Instead of bouncing audio data through an intermediate ring buffer, it dispatches the ASIO `bufferSwitch` callback directly inside the JACK process callback, with a small futex-based handshake to wake the application's process thread. The data written by the host comes out the same JACK period it went in.

This document describes how those pieces fit together, what each one is responsible for, and which design decisions were forced by the constraint of running on a PREEMPT_RT kernel under JACK.

## 2. Backend constraints and JACK selection

Vanilla Wine ships three audio drivers: `winealsa.drv` (ALSA PCM), `winepulse.drv` (PulseAudio), and `wineoss.drv` (OSS). Each of them satisfies the WASAPI surface in their own way, and each of them runs into the same set of problems on a PREEMPT_RT kernel hosting a real-time audio workload.

**ALSA PCM is not RT-friendly when driven from a Wine timer thread.** The vanilla `winealsa.drv` audio path uses `NtDelayExecution` (a Sleep-equivalent) inside a timer loop to pace WASAPI period events. Sleeps under PREEMPT_RT are honored, but their wakeups are scheduled against the rest of the system, which means Wine's audio service thread wakes whenever the scheduler gets to it. Sleep granularity is not the same as JACK period granularity. The ALSA driver also accepts `AUDCLNT_SHAREMODE_EXCLUSIVE` but does only a token amount of work for it -- buffer-size rounding, no exclusive device claim, no format enforcement, no exclusive-mode timing. On a typical Ableton session this manifests as occasional missed deadlines that turn into xruns.

**PulseAudio routes audio through a userspace daemon that is not on the RT path.** PipeWire's PulseAudio compatibility layer is closer to RT-correct, but `winepulse.drv` is still talking to PulseAudio through its compatibility ABI, not directly to the underlying RT engine. There is an extra hop, and that hop costs both latency and predictability.

**OSS is a legacy compatibility path.** It remains in upstream Wine for older systems and is not a target backend for low-latency PREEMPT_RT workloads.

The deeper problem is that each of these drivers tries to *manufacture* a clock from the host system's general-purpose timing primitives -- a CLOCK_MONOTONIC sleep, an ALSA wakeup timed against PCM availability, a PulseAudio buffer-fill notification. None of those clocks were designed to be authoritative for a hard-real-time audio callback running at SCHED_FIFO 80+. On a PREEMPT_RT kernel they can be made *better*, but they cannot be made *deterministic*.

JACK is built around a different premise. The JACK process callback runs on a SCHED_FIFO thread inside the JACK server (or, with PipeWire-JACK, inside the PipeWire RT loop, which provides the same contract). The callback fires once per period at a frame boundary that the rest of the system has already committed to. Every JACK client on the box is woken by JACK and produces or consumes one period's worth of audio inside that callback. There is no separate clock; *the JACK callback is the clock*. That callback is the authoritative timing source for an RT-correct Wine audio driver.

Accordingly, the implementation uses a JACK-native Wine audio driver. That driver is `winejack.drv`.

## 3. Stack layering

The transport has three modes, selected by API surface.

**WASAPI shared mode** (Windows media players, browsers, generic apps):

    Win32 app -> mmdevapi -> WASAPI client interface
              -> winejack.drv (Unix side)
              -> JACK audio ports
              -> JACK / PipeWire RT engine
              -> hardware

**WASAPI exclusive mode** (DAWs that want a guaranteed buffer contract, or apps using AUDCLNT_STREAMFLAGS_EVENTCALLBACK):

    Win32 app -> mmdevapi -> WASAPI client (EXCLUSIVE + EVENTCALLBACK)
              -> winejack.drv exclusive event-driven path
              -> JACK audio ports
              -> JACK RT engine

**ASIO** (DAWs and plugin hosts that prefer the ASIO callback model: Reaper, Ableton, Cubase, FL Studio):

    Win32 app -> COM IASIO -> nspaASIO
              -> direct callback registration with winejack.drv
              -> JACK process callback dispatches bufferSwitch in-band
              -> JACK audio ports
              -> JACK RT engine

The *same* JACK transport carries all three modes. Multiple ASIO and WASAPI clients can coexist, and JACK handles graph-level mixing and routing. The stack does not implement Windows-style exclusive-device lockout; that behavior is discussed in Section 10.

MIDI takes a parallel path through the same driver:

    Win32 app -> WinMM MIDI -> winejack.drv (jackmidi.c)
              -> JACK MIDI ports
              -> external synths / soft synths / DAW MIDI tracks

WinMM MIDI is a separate JACK client (`wine-midi`) from the audio one (`wine-audio`). They have separate process callbacks, separate lifecycles, and separate port sets. Sharing a single client for audio and MIDI is possible but offers no real benefit -- JACK callbacks are cheap, and decoupling lets MIDI come up before audio is initialized and stay up after audio shuts down.

The three flavors above resolve into a single layered data path. Every Win32 audio API ultimately funnels through `mmdevapi` into `winejack.drv`'s Unix side, which holds the JACK client and the per-period process callback. The direct callback path shortcuts ASIO data past the WASAPI ring while still re-using the same JACK client, the same port set, and the same process callback. The diagram below shows the layering and which boundary each API surface enters at.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 580" xmlns="http://www.w3.org/2000/svg">
  <style>
    .lbl { fill: #c0caf5; font-family: 'JetBrains Mono', monospace; font-size: 12px; }
    .lbl-sm { fill: #c0caf5; font-family: 'JetBrains Mono', monospace; font-size: 10px; }
    .lbl-hdr { fill: #7aa2f7; font-family: 'JetBrains Mono', monospace; font-size: 14px; font-weight: bold; }
    .lbl-tier { fill: #7dcfff; font-family: 'JetBrains Mono', monospace; font-size: 11px; font-weight: bold; }
    .lbl-acc { fill: #bb9af7; font-family: 'JetBrains Mono', monospace; font-size: 11px; }
    .lbl-grn { fill: #9ece6a; font-family: 'JetBrains Mono', monospace; font-size: 10px; font-weight: bold; }
    .lbl-yel { fill: #e0af68; font-family: 'JetBrains Mono', monospace; font-size: 10px; }
    .lbl-mut { fill: #8c92b3; font-family: 'JetBrains Mono', monospace; font-size: 10px; }
    .box-pe { fill: #1a1b26; stroke: #7aa2f7; stroke-width: 1.5; }
    .box-bridge { fill: #24283b; stroke: #bb9af7; stroke-width: 1.5; }
    .box-driver { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; }
    .box-jack { fill: #1f2535; stroke: #7dcfff; stroke-width: 1.5; }
    .box-hw { fill: #2a2418; stroke: #e0af68; stroke-width: 1.5; }
    .conn { stroke: #565f89; stroke-width: 1.4; }
    .conn-fast { stroke: #bb9af7; stroke-width: 1.6; stroke-dasharray: 6 3; }
    .divider { stroke: #6b7398; stroke-width: 1; stroke-dasharray: 4 4; }
  </style>

  <text x="470" y="26" text-anchor="middle" class="lbl-hdr">Wine-NSPA audio data path -- three API surfaces, one JACK transport</text>

  <text x="20" y="62" class="lbl-tier">Win32 PE</text>
  <rect x="100" y="48" width="220" height="32" class="box-pe"/>
  <text x="210" y="68" text-anchor="middle" class="lbl">WASAPI shared (media player)</text>
  <rect x="350" y="48" width="220" height="32" class="box-pe"/>
  <text x="460" y="68" text-anchor="middle" class="lbl">WASAPI exclusive event-driven</text>
  <rect x="600" y="48" width="220" height="32" class="box-pe"/>
  <text x="710" y="68" text-anchor="middle" class="lbl">ASIO host (DAW + plugins)</text>

  <line x1="210" y1="80" x2="210" y2="110" class="conn"/>
  <line x1="460" y1="80" x2="460" y2="110" class="conn"/>
  <line x1="710" y1="80" x2="710" y2="110" class="conn"/>

  <text x="20" y="130" class="lbl-tier">Win32 ABI</text>
  <rect x="100" y="112" width="470" height="32" class="box-bridge"/>
  <text x="335" y="132" text-anchor="middle" class="lbl-acc">mmdevapi -- IAudioClient / IAudioRenderClient (WASAPI surface)</text>
  <rect x="600" y="112" width="220" height="32" class="box-bridge"/>
  <text x="710" y="132" text-anchor="middle" class="lbl-acc">nspaasio.dll -- IASIO COM</text>

  <line x1="210" y1="144" x2="210" y2="172" class="conn"/>
  <line x1="460" y1="144" x2="460" y2="172" class="conn"/>
  <line x1="710" y1="144" x2="710" y2="172" class="conn"/>

  <text x="20" y="194" class="lbl-tier">PE / Unix</text>
  <text x="20" y="208" class="lbl-mut">boundary</text>
  <line x1="80" y1="180" x2="900" y2="180" class="divider"/>

  <text x="20" y="246" class="lbl-tier">Wine driver</text>
  <text x="20" y="260" class="lbl-mut">(Unix side)</text>

  <rect x="100" y="220" width="720" height="120" class="box-driver"/>
  <text x="460" y="244" text-anchor="middle" class="lbl-grn">winejack.drv (jack.c) -- WASAPI client implementation, stream state machine</text>

  <rect x="120" y="258" width="200" height="32" class="box-driver"/>
  <text x="220" y="278" text-anchor="middle" class="lbl-sm">general path: interleaved ring</text>

  <rect x="340" y="258" width="200" height="32" class="box-driver"/>
  <text x="440" y="278" text-anchor="middle" class="lbl-sm">fast path: per-channel double-buf</text>

  <rect x="560" y="258" width="240" height="32" class="box-driver"/>
  <text x="680" y="278" text-anchor="middle" class="lbl-sm">Phase F: register_asio + futex pair</text>

  <text x="460" y="310" text-anchor="middle" class="lbl-yel">single JACK process callback services every active stream (shared / excl / Phase F)</text>
  <text x="460" y="326" text-anchor="middle" class="lbl-mut">pi_mutex_trylock against WASAPI threads -- no blocking inside RT callback</text>

  <line x1="210" y1="340" x2="210" y2="370" class="conn"/>
  <line x1="460" y1="340" x2="460" y2="370" class="conn"/>
  <line x1="710" y1="340" x2="710" y2="370" class="conn"/>

  <text x="20" y="392" class="lbl-tier">JACK</text>
  <rect x="100" y="372" width="720" height="48" class="box-jack"/>
  <text x="460" y="392" text-anchor="middle" class="lbl-acc">wine-audio JACK client -- output_1..N + input_1..N ports (deinterleaved float32)</text>
  <text x="460" y="410" text-anchor="middle" class="lbl-mut">SCHED_FIFO process_callback owns the period clock; wakes via libjack</text>

  <line x1="460" y1="420" x2="460" y2="450" class="conn"/>

  <text x="20" y="476" class="lbl-tier">JACK server</text>
  <rect x="100" y="452" width="720" height="40" class="box-jack"/>
  <text x="460" y="476" text-anchor="middle" class="lbl-acc">jackd / pipewire-jack RT engine -- graph mix, port routing, period scheduling</text>

  <line x1="460" y1="492" x2="460" y2="520" class="conn"/>

  <text x="20" y="546" class="lbl-tier">Hardware</text>
  <rect x="100" y="522" width="720" height="40" class="box-hw"/>
  <text x="460" y="546" text-anchor="middle" class="lbl-yel">ALSA hw: device -- USB / PCI audio interface, sample-rate clock owner</text>

  <text x="710" y="200" class="lbl-acc">Phase F shortcut:</text>
  <line x1="710" y1="160" x2="710" y2="172" class="conn-fast"/>
  <text x="855" y="280" class="lbl-mut">same-period</text>
  <text x="855" y="294" class="lbl-mut">zero-copy</text>
  <text x="855" y="308" class="lbl-mut">data lands at HW</text>
  <text x="855" y="322" class="lbl-mut">in 1 JACK period</text>
</svg>
</div>

The Phase F path (rightmost column) removes an extra JACK-period staging step. Instead of filling an intermediate ring and waiting for the next callback to consume it, the host's `bufferSwitch` data is emitted in the same JACK period in which it was produced.

## 4. winejack.drv: the JACK backend for Wine

`winejack.drv` lives at `dlls/winejack.drv/` in the Wine tree. It is a standard Wine audio driver in the sense that it presents the same Unix-side function table that `winealsa.drv` and `winepulse.drv` present to `mmdevapi`. The function table -- the set of `enum unix_funcs` entries declared in `unixlib.h` -- is what `mmdevapi`'s WASAPI client implementation calls into when it needs to enumerate endpoints, create a stream, push or pull a buffer, query the position, or report latency.

There are two source files:

- `dlls/winejack.drv/jack.c` -- the audio side. WASAPI surface, stream state machine, JACK process callback, format conversion, position and latency reporting, ASIO registration interface.
- `dlls/winejack.drv/jackmidi.c` -- the WinMM MIDI side. JACK MIDI input and output, lock-free ringbuffers between the WinMM thread and the JACK process callback, port enumeration, and the MIM/MOM notification surface.

The driver is registered in `configure.ac` and links against `libjack`. It builds as `winejack.so` and ships alongside the other Wine DLLs.

### MIDI first, then audio

The driver landed in two major slices. The first delivered MIDI -- `jackmidi.c` and the MIDI half of `unixlib.h`. At that point audio still went through `winealsa.drv` (with a small delegation that let `winealsa.drv` ask `winejack.drv` for its MIDI driver via `NSPA_JACK_MIDI=1`), so applications could get JACK MIDI without depending on the audio side. The second delivered WASAPI audio -- the function-table entries in `jack.c`, the stream lifecycle, and the JACK audio process callback. After that, MIDI and audio shared `winejack.drv` as a single Wine driver, and `winealsa.drv`'s MIDI delegation stopped being the recommended path.

### Internal layering

Inside `winejack.drv` the audio side is organized into eight loosely-coupled pieces:

1. **Endpoint and device management** -- enumerates physical JACK ports, groups them by client prefix, presents them to `mmdevapi` as audio endpoints.
2. **WASAPI stream state machine** -- Initialize / Start / Stop / Reset / Release transitions, error reporting on contract violation, lifecycle of one `IAudioClient` instance.
3. **Event-driven scheduler bridge** -- pull mode. The application sets up `AUDCLNT_STREAMFLAGS_EVENTCALLBACK`, calls `SetEventHandle`, and waits on the handle in a loop. winejack signals the event each JACK period.
4. **Timer-driven scheduler bridge** -- push mode. The application polls `GetCurrentPadding` on its own cadence and calls `GetBuffer` / `ReleaseBuffer` when it wants to. winejack maintains the buffer-state contract against a JACK-backed stream.
5. **JACK audio transport layer** -- one JACK client (`wine-audio`), one process callback that services every active stream, port registration on stream creation, port destruction on stream release.
6. **Timing, clock, and latency reporting** -- `IAudioClock::GetPosition`, `IAudioClient::GetStreamLatency`, `GetDevicePeriod`. Position is monotonic and synchronized with actual JACK frame progress.
7. **WinMM MIDI layer** (in `jackmidi.c`) -- `midiOutShortMsg`, `midiOutLongMsg`, `midiInStart`, callback dispatch, MIM/MOM notifications, ringbuffer plumbing.
8. **JACK MIDI transport layer** (in `jackmidi.c`) -- one JACK client (`wine-midi`), MIDI process callback, frame-aligned event timestamps, port registration per opened MIDI device.

The audio side runs to roughly 3000 lines in `jack.c`. MIDI is roughly 700 lines in `jackmidi.c`.

### Timing model

`winejack.drv` treats JACK callback timing as the authoritative engine. WASAPI-facing events, padding, periods, position, and latency are synthesized on top of that callback cadence.

WASAPI gives the application a contract: the device has a period, you'll be woken at period boundaries (or you can poll), padding is accurate, position monotonic. winejack honors that contract. But the contract is *synthesized* -- there is no Windows audio engine underneath. The JACK process callback fires, winejack updates internal state, and the next time the application reads padding or waits on its event, it sees a state consistent with one more JACK period having elapsed.

This is the same shape as `ASIO2WASAPI` (a native-Windows project that inverts the relationship: an ASIO driver that calls into a WASAPI exclusive client). Both are bridges from a callback-driven backend to the WASAPI ABI; the surface is identical, only the backend differs.

## 5. WASAPI surface and shared mode

`mmdevapi` calls into the audio driver through the `enum unix_funcs` function table. The headline entries on the audio side are:

- `get_endpoint_ids` -- what audio devices are available?
- `create_stream` -- open a stream against an endpoint, with a given format and share mode
- `release_stream` -- tear it down
- `start`, `stop`, `reset` -- transition the stream state machine
- `get_render_buffer` / `release_render_buffer` -- the WASAPI render contract
- `get_capture_buffer` / `release_capture_buffer` -- the capture contract
- `get_current_padding`, `get_next_packet_size`, `get_buffer_size`
- `get_position`, `get_frequency`, `get_latency`
- `set_volumes`, `set_event_handle`, `is_started`
- `get_mix_format`, `is_format_supported`, `get_device_period`

Each is satisfied by `winejack.drv` in terms of JACK state.

### Endpoint enumeration

JACK exposes a flat list of physical and virtual ports. winejack groups them into endpoints by client prefix (every `system:capture_*` becomes one capture endpoint, every `system:playback_*` one playback endpoint, and similarly for any other JACK clients with stable port-naming patterns -- a USB interface, a virtual cable, a soundcard exposed by PipeWire). The result is a small handful of endpoints that look enough like Windows audio devices for `mmdevapi` to enumerate.

Endpoint information is built once at first query. There is a known gap here -- device hotplug events from JACK do not refresh the endpoint list, so plugging in a USB interface after Wine is up requires a Wine restart to see the new endpoint. This is filed under deferred work; in practice DAW workflows tend to set up the audio environment before launching the DAW.

### Format negotiation

JACK speaks one format: deinterleaved 32-bit IEEE float, at one sample rate (whatever JACK was started with), at one buffer size (whatever JACK was configured for). Everything else is the driver's problem.

`get_mix_format` reports float32 at JACK's native rate. `is_format_supported` answers honestly:

- For shared mode, it accepts the rate JACK is running at, with the channel count requested, in any of int16 / int24 / int32 / float32 / float64. It returns `S_FALSE` (the "not exactly, but here's a closest match") for a sample-rate mismatch, providing JACK's rate as the closest match. This lets `mmdevapi`'s automatic SRC kick in via `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` when the application asks for it.
- For exclusive mode, it is strict. The format must be float32 (or one of the accepted integer formats) at JACK's rate. A rate mismatch returns `AUDCLNT_E_UNSUPPORTED_FORMAT` rather than `S_FALSE`. This is correct WASAPI behavior for an exclusive-mode device that does not own the hardware sample-rate clock.

`get_device_period` reports JACK's buffer size as both the minimum and default period. This is the only period winejack can support without introducing additional buffering.

### Format conversion

JACK is deinterleaved float32 per port. WASAPI is interleaved multi-channel in whatever format the application chose. Converting between them is the driver's job and happens in two places:

1. **Render path** -- the application's audio sits in a per-stream interleaved ring buffer in its native format. The JACK process callback reads from the ring, converts to float32 if needed, deinterleaves into per-channel JACK port buffers, and applies per-channel volume.
2. **Capture path** -- JACK port buffers are read in the process callback, interleaved into the application's format, and stored in the per-stream ring. The application reads the ring on its own cadence.

The conversions cover the standard WASAPI integer formats (int16, int24-in-32, int32) and the float formats (float32 passthrough, float64). For float32 at JACK rate, the only work in the render path is the deinterleave -- the format is already correct.

### Shared-mode behavior

Shared mode is straightforward. Multiple shared-mode streams open into a single `wine-audio` JACK client. JACK handles graph-level mixing the way it always does -- if two shared-mode streams write to the same endpoint, both end up at the JACK output port and JACK mixes them downstream. There is no per-stream mixer in winejack itself; the driver writes its converted sample data into JACK port buffers and lets JACK do the rest.

### The locking strategy

The JACK process callback runs at SCHED_FIFO and must not block. The application's WASAPI threads run at SCHED_OTHER (or, in the DAW case, SCHED_FIFO with a priority *below* the audio callback). They share state -- the per-stream ring buffer, the held-frames counter, the position counter.

The chosen scheme is a `pi_mutex_trylock` in the process callback. The Wine WASAPI threads take the mutex normally. The JACK callback `trylock`s; if it fails, that period outputs silence (or skips a capture), and a counter ticks. If the lock is held by a Wine thread when the callback fires, the kernel's PI machinery boosts that Wine thread to the JACK callback's priority -- but in practice the trylock-fallback path is what actually runs, because we don't want to wait on the application thread under any circumstance. The PI boost is a safety net, not a planned interaction.

This is the same PI-mutex pattern Wine-NSPA uses elsewhere (see CS-PI), so the mechanism is reused rather than reinvented.

### The two JACK clients

`winejack.drv` opens two JACK clients per Wine process:

- `wine-audio` -- the audio client. One process callback. All active WASAPI streams (shared, exclusive, fast path, slow path) hang off this one client. Ports are registered and unregistered as streams are created and released. The client is opened lazily on the first `create_stream` and stays alive until process exit.
- `wine-midi` -- the MIDI client. Separate process callback. Lives in `jackmidi.c`. Independent lifecycle; can be opened by an application that uses MIDI but no audio, and vice versa.

JACK clients are cheap on the JACK server side -- registering a new client is a few hundred microseconds, port registration is comparable -- so the two-client design adds no observable cost. The benefit is decoupling: a MIDI device that is opened, used, and closed during a DAW session does not perturb the audio client's port set, and a stream that is created and torn down on the audio side does not affect MIDI.

When PipeWire-JACK is the JACK server, the same two-client design applies. PipeWire's JACK compatibility layer is functionally complete for client-side semantics, including process callbacks at correct period boundaries and port registration; everything in this document applies to PipeWire-JACK as well as a native `jackd` server.

## 6. Exclusive mode and the fast path

WASAPI exclusive mode with `AUDCLNT_STREAMFLAGS_EVENTCALLBACK` is the path serious audio applications take. It is the path Ableton takes when configured against a WASAPI device. It is the path that an ASIO host's WASAPI fallback uses, and it is the path that `nspaASIO` uses when Phase F is unavailable.

The exclusive contract is tight:

- `hnsBufferDuration == hnsPeriodicity` (the application asks for an N-frame buffer and a period equal to that buffer). This is enforced.
- The stream signals an event handle every period.
- `GetBuffer` / `ReleaseBuffer` is a per-period write -- the application gets a buffer pointer, writes one period's worth, releases it, waits on the event for the next period.
- `GetCurrentPadding` reports zero or one period -- never multiple periods backed up, because the buffer is one period.

Mapping that to JACK:

- The buffer duration in frames is JACK's buffer size (or a multiple, if the application asked for more, in which case winejack adapts -- but for low-latency work, application equals JACK).
- The period event is signaled from the JACK process callback. The JACK callback fires once per period at the right wall-clock moment, and signaling the WASAPI event from inside the callback gives the application a wakeup synchronized with the JACK transport.
- `GetBuffer` returns a pointer into a per-stream double buffer. While the application writes one half, the JACK callback reads from the other half. After `ReleaseBuffer`, the next JACK callback reads the half that was just written and signals the event so the application can fill the other half.

### The fast path

For the common DAW case -- exclusive mode, event-driven, float32, JACK-native rate, channel count within JACK port budget -- winejack uses a fast path that strips out everything not needed for the float32-at-JACK-rate case.

The criteria, all required:

- `AUDCLNT_SHAREMODE_EXCLUSIVE`
- `AUDCLNT_STREAMFLAGS_EVENTCALLBACK`
- Format is IEEE float 32-bit
- Sample rate equals JACK's native rate
- Channel count fits within available JACK ports

When all of those hold, `create_stream` allocates per-channel double buffers (set A and set B, each one JACK period long) instead of an interleaved ring buffer. The application's `GetBuffer` returns a pointer to the write set; `ReleaseBuffer` deinterleaves into the per-channel write set. The JACK callback flips an atomic `rt_buf_idx` and `memcpy`s the read set straight into the JACK port buffers. No format conversion (float32 to float32), no volume application unless volume is non-unity, no ringbuffer head/tail bookkeeping. Just a buffer-index flip and a per-channel `memcpy`.

This is the same pattern wineasio uses internally to bridge ASIO double-buffer semantics to JACK. It is the right shape for the exclusive event-driven path because both ends agree on the period and the format -- the only thing that has to happen is moving the bytes.

When the fast-path criteria are *not* met -- shared mode, push mode, format mismatch, rate mismatch -- winejack falls back to the general path: interleaved ring buffer, format conversion, volume application, the works. The fast path is a per-stream optimization and adds no overhead when it isn't engaged.

### Padding and position

Padding (the number of frames queued but not yet consumed) is read by the application to decide how much to write. For exclusive event-driven mode it is approximately zero immediately after `ReleaseBuffer` -- because the JACK callback consumes the whole period in one go -- and full again immediately afterwards, until the next callback. The driver tracks `held_frames` atomically; the JACK callback subtracts what it consumed, the WASAPI thread adds what was released.

Position -- `IAudioClock::GetPosition` -- is read by DAWs for transport timing and drift compensation. The driver maintains a 64-bit frame counter that the JACK callback advances by the period size each time it runs, plus a QPC timestamp captured at the same point. The application gets a position that is monotonic, synchronized with actual JACK frame progress, and correlatable with QPC. Latency is reported via `jack_port_get_latency_range` -- the max of the range, conservative -- so DAWs can apply input-monitoring compensation correctly.

### Latency budget

For a session at 48 kHz with a 64-frame JACK period, the period is 1333 microseconds. The pre-Phase-F WASAPI exclusive path consumed roughly:

| Stage | Pre-Phase-F | After fast path | With Phase F |
|---|---|---|---|
| nspaASIO interleave | ~50 us | ~50 us | 0 (per-channel direct) |
| WASAPI `GetBuffer` overhead | ~5 us | ~2 us | n/a (no GetBuffer) |
| Ring buffer write | ~20 us | ~10 us (memcpy) | n/a |
| RT-side deinterleave + volume | ~30 us | ~10 us (memcpy) | ~10 us (memcpy) |
| Event signaling | ~100 us (`NtSetEvent`) | ~5 us (futex) | ~2 us (futex) |
| Timer drift | +-1 ms | 0 (JACK-synced) | 0 |
| Pre-fill latency | +period | 0 | 0 |

Phase F's full additive overhead per period, on top of the JACK period itself, is a couple of memcpys plus the futex round trip -- on the order of 30 microseconds for typical channel counts. That is well below the variance of the kernel scheduler and not measurable end-to-end against a clean JACK reference.

## 7. MIDI

`jackmidi.c` is the WinMM MIDI implementation. It opens a separate JACK client (`wine-midi`), registers JACK MIDI input and output ports per opened device, and bridges WinMM's `MOM_*` and `MIM_*` notification model to JACK's per-period event lists.

The shape:

- **Output**: `midiOutShortMsg` and `midiOutLongMsg` push into a lock-free ringbuffer. The JACK MIDI process callback drains the ringbuffer into `jack_midi_event_write` calls, in order, into the output port's per-period event buffer.
- **Input**: the JACK MIDI process callback reads `jack_midi_event_get` events from the input port and pushes them into a per-port ringbuffer. A WinMM thread on the application side drains that ringbuffer and dispatches `MIM_DATA` / `MIM_LONGDATA` callbacks.

The lock-free ringbuffers are the standard SPSC variety with atomic head and tail. The JACK process callback never blocks; the WinMM threads never block on the JACK callback.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 940 540" xmlns="http://www.w3.org/2000/svg">
  <style>
    .lbl { fill: #c0caf5; font-family: 'JetBrains Mono', monospace; font-size: 12px; }
    .lbl-sm { fill: #c0caf5; font-family: 'JetBrains Mono', monospace; font-size: 10px; }
    .lbl-hdr { fill: #7aa2f7; font-family: 'JetBrains Mono', monospace; font-size: 14px; font-weight: bold; }
    .lbl-tier { fill: #7dcfff; font-family: 'JetBrains Mono', monospace; font-size: 11px; font-weight: bold; }
    .lbl-grn { fill: #9ece6a; font-family: 'JetBrains Mono', monospace; font-size: 10px; font-weight: bold; }
    .lbl-yel { fill: #e0af68; font-family: 'JetBrains Mono', monospace; font-size: 11px; font-weight: bold; }
    .lbl-mut { fill: #8c92b3; font-family: 'JetBrains Mono', monospace; font-size: 10px; }
    .lbl-state { fill: #bb9af7; font-family: 'JetBrains Mono', monospace; font-size: 10px; }
    .box-app { fill: #1a1b26; stroke: #7aa2f7; stroke-width: 1.5; }
    .box-winmm { fill: #24283b; stroke: #bb9af7; stroke-width: 1.5; }
    .box-driver { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; }
    .box-jack { fill: #1f2535; stroke: #7dcfff; stroke-width: 1.5; }
    .box-state { fill: #2a2418; stroke: #e0af68; stroke-width: 1.5; }
    .box-ring { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.5; }
    .conn { stroke: #565f89; stroke-width: 1.4; }
    .conn-ring { stroke: #f7768e; stroke-width: 1.4; }
  </style>

  <text x="470" y="24" text-anchor="middle" class="lbl-hdr">WinMM MIDI flow + lifecycle (jackmidi.c, wine-midi JACK client)</text>

  <text x="220" y="58" text-anchor="middle" class="lbl-tier">OUTPUT (host -&gt; external)</text>
  <text x="720" y="58" text-anchor="middle" class="lbl-tier">INPUT  (external -&gt; host)</text>

  <rect x="60" y="74" width="320" height="36" class="box-app"/>
  <text x="220" y="97" text-anchor="middle" class="lbl">Win32 host: midiOutShortMsg / midiOutLongMsg</text>

  <rect x="560" y="74" width="320" height="36" class="box-app"/>
  <text x="720" y="97" text-anchor="middle" class="lbl">External MIDI source (keyboard / DAW track)</text>

  <line x1="220" y1="110" x2="220" y2="138" class="conn"/>
  <line x1="720" y1="110" x2="720" y2="138" class="conn"/>

  <rect x="60" y="140" width="320" height="36" class="box-winmm"/>
  <text x="220" y="163" text-anchor="middle" class="lbl-state">midi_out_data / midi_out_long_data (WinMM thread)</text>

  <rect x="560" y="140" width="320" height="36" class="box-jack"/>
  <text x="720" y="163" text-anchor="middle" class="lbl-state">JACK input port (jack_midi_event_get)</text>

  <line x1="220" y1="176" x2="220" y2="204" class="conn-ring"/>
  <line x1="720" y1="176" x2="720" y2="204" class="conn-ring"/>

  <rect x="60" y="206" width="320" height="48" class="box-ring"/>
  <text x="220" y="226" text-anchor="middle" class="lbl-yel">SPSC ringbuffer (8 KB) -- atomic head/tail</text>
  <text x="220" y="244" text-anchor="middle" class="lbl-mut">producer: WinMM    consumer: JACK callback</text>

  <rect x="560" y="206" width="320" height="48" class="box-ring"/>
  <text x="720" y="226" text-anchor="middle" class="lbl-yel">SPSC ringbuffer (8 KB) per port</text>
  <text x="720" y="244" text-anchor="middle" class="lbl-mut">producer: JACK callback    consumer: WinMM</text>

  <line x1="220" y1="254" x2="220" y2="282" class="conn-ring"/>
  <line x1="720" y1="254" x2="720" y2="282" class="conn-ring"/>

  <rect x="60" y="284" width="820" height="62" class="box-driver"/>
  <text x="470" y="306" text-anchor="middle" class="lbl-grn">jack_midi_process_cb (one wine-midi JACK client, RT thread)</text>
  <text x="220" y="324" text-anchor="middle" class="lbl-sm">drain output ring -&gt; jack_midi_event_write(port_buf, ev.time, data)</text>
  <text x="720" y="324" text-anchor="middle" class="lbl-sm">push input ev -&gt; (timestamp = base + ev.time/rate)</text>
  <text x="470" y="340" text-anchor="middle" class="lbl-mut">no allocation, no Wine call, no locks held inside the callback</text>

  <line x1="220" y1="346" x2="220" y2="372" class="conn"/>
  <line x1="720" y1="346" x2="720" y2="372" class="conn"/>

  <rect x="60" y="374" width="320" height="36" class="box-jack"/>
  <text x="220" y="397" text-anchor="middle" class="lbl-state">JACK output port -&gt; external MIDI device</text>

  <rect x="560" y="374" width="320" height="36" class="box-winmm"/>
  <text x="720" y="397" text-anchor="middle" class="lbl-state">WinMM dispatch -&gt; MIM_DATA / MIM_LONGDATA</text>

  <text x="470" y="446" text-anchor="middle" class="lbl-tier">Per-port lifecycle (DRVM_*)</text>

  <rect x="60" y="458" width="155" height="60" class="box-state"/>
  <text x="137" y="480" text-anchor="middle" class="lbl-state">DRVM_INIT</text>
  <text x="137" y="498" text-anchor="middle" class="lbl-mut">jack client</text>
  <text x="137" y="510" text-anchor="middle" class="lbl-mut">connect</text>

  <rect x="240" y="458" width="155" height="60" class="box-state"/>
  <text x="317" y="480" text-anchor="middle" class="lbl-state">MOM_OPEN / MIM_OPEN</text>
  <text x="317" y="498" text-anchor="middle" class="lbl-mut">port register</text>
  <text x="317" y="510" text-anchor="middle" class="lbl-mut">ringbuf alloc</text>

  <rect x="420" y="458" width="160" height="60" class="box-state"/>
  <text x="500" y="480" text-anchor="middle" class="lbl-state">RUNNING</text>
  <text x="500" y="498" text-anchor="middle" class="lbl-mut">events flow,</text>
  <text x="500" y="510" text-anchor="middle" class="lbl-mut">MIM_ERROR on overflow</text>

  <rect x="605" y="458" width="155" height="60" class="box-state"/>
  <text x="682" y="480" text-anchor="middle" class="lbl-state">MOM_CLOSE / MIM_CLOSE</text>
  <text x="682" y="498" text-anchor="middle" class="lbl-mut">port unregister</text>
  <text x="682" y="510" text-anchor="middle" class="lbl-mut">drain queue</text>

  <rect x="785" y="458" width="95" height="60" class="box-state"/>
  <text x="832" y="480" text-anchor="middle" class="lbl-state">DRVM_EXIT</text>
  <text x="832" y="498" text-anchor="middle" class="lbl-mut">walk arrays,</text>
  <text x="832" y="510" text-anchor="middle" class="lbl-mut">close leaks</text>

  <line x1="215" y1="488" x2="240" y2="488" class="conn"/>
  <line x1="395" y1="488" x2="420" y2="488" class="conn"/>
  <line x1="580" y1="488" x2="605" y2="488" class="conn"/>
  <line x1="760" y1="488" x2="785" y2="488" class="conn"/>
</svg>
</div>

The two ringbuffers are the synchronisation surface between the WinMM threads and the JACK process callback. Output's producer side and input's consumer side are owned by WinMM threads at SCHED_OTHER (or SCHED_FIFO under MMCSS naming when applicable); the other side of each ring is owned by the JACK RT callback. The lifecycle row at the bottom is the per-port progression: `DRVM_INIT` opens the JACK client lazily on first use, `MOM_OPEN` / `MIM_OPEN` registers a port and allocates its ring, the RUNNING state is where the audit's six bug fixes sit, `MOM_CLOSE` / `MIM_CLOSE` unregisters cleanly, and `DRVM_EXIT` is the audit's leak-fix path that walks the destination and source arrays to close anything still open at process exit.

### Bugs and fixes (the MIDI audit)

A six-issue audit of `jackmidi.c` produced the following fixes. Each shipped as a separate commit.

**Input timestamp jitter.** The original code stamped MIDI input events with `get_time_msec()` *at dequeue time* -- that is, when the WinMM thread drained the ringbuffer, not when JACK saw the event. JACK provides a per-event frame offset (`ev.time`) within the period, but the dequeue-time approach ignored it entirely. The result was that multiple events in the same period got the same timestamp and the next-period boundary added up to one full JACK period of jitter on every event. For DAWs that record MIDI -- a keyboard playing into a piano roll -- that jitter is audible as smeared timing.

The fix is to compute the timestamp at *enqueue* time, in the JACK callback, as `base_time + (ev.time * 1000 / jack_rate)`. Sub-millisecond resolution, no smearing. This was the largest single contributor to the "clunky MIDI" feel that motivated the audit.

**Silent message drops on overflow.** `midi_out_data` (the short-message path) silently dropped messages when the ringbuffer was full and returned `NOERROR`. `midi_out_long_data` (the SysEx path) was worse -- it not only dropped the message but set `MHDR_DONE` and fired `MOM_DONE`, lying to the application about completion. The fix is to report the failure honestly: `MIDIERR_NOTREADY` for short messages, no `MOM_DONE` for SysEx that didn't actually go out. Large SysEx dumps (patch banks, firmware uploads to hardware synths) are the visible failure mode here; they were silently truncating, which is the worst possible class of bug.

**`MODM_RESET` only sent CC 123.** The WinMM `MODM_RESET` reset behavior is documented as "All Notes Off" -- which on Windows means CC 123 (All Notes Off) *and* CC 120 (All Sound Off). Without CC 120, sustained notes and reverb tails on external synths keep ringing after the reset. The fix is to send both CCs on each MIDI channel during reset.

**No `MIM_ERROR` on dropped input.** When the input ringbuffer overflowed, events were silently swallowed. Windows expects `MIM_ERROR` for malformed or dropped short messages and `MIM_LONGERROR` for SysEx that couldn't be delivered. The fix wires up the appropriate notifications when the JACK callback can't enqueue.

**Output event timestamps were always frame 0.** Every output event was written with `jack_midi_event_write(..., 0, ...)`, putting all output at the start of the period regardless of when WinMM received the message. This piles up rapid messages at the same instant within the period. WinMM's API doesn't carry sub-period timing on the output side, so the impact is small, but the fix spreads events across the period based on arrival time.

**`DRVM_EXIT` was a no-op.** The driver's exit handler did nothing, so when an application exited without properly closing its MIDI ports, the JACK MIDI ports leaked. The fix walks the destination and source arrays and closes anything that's still open.

The MIDI audit deliberately kept its commits separate from the audio-side work in `jack.c`. MIDI bugs and audio bugs have different reproduction paths, different test surfaces, and different blast radii, and shipping them in one commit makes bisection harder when one of the changes regresses.

### MIDI process callback shape

The JACK MIDI process callback is a small, focused loop:

    jack_midi_process_cb(nframes, arg):
        for each registered output port:
            jack_midi_clear_buffer(port_buf)
            drain SPSC ringbuffer:
                read short or long event
                jack_midi_event_write(port_buf, frame_offset, data, len)
        for each registered input port:
            count = jack_midi_get_event_count(port_buf)
            for i in 0..count:
                jack_midi_event_get(&ev, port_buf, i)
                push (timestamp = base + ev.time/rate, data) into per-port SPSC ringbuffer

There is no allocation, no Wine call, no lock taken in the callback. SPSC ringbuffers are the standard atomic-head, atomic-tail variety with one producer (the WinMM thread on output, the JACK callback on input) and one consumer (the JACK callback on output, the WinMM dispatch thread on input). Capacity is sized for typical SysEx burst patterns -- 8 KB per direction -- which absorbs ordinary patch-bank transfers without overflow.

## 8. nspaASIO: the ASIO bridge

`dlls/nspaasio/` is a Wine-side COM DLL that implements the `IASIO` interface. It is the audio driver name a DAW sees when it asks Windows for a list of installed ASIO drivers, and it is what gets loaded when "nspaASIO" is selected from the DAW's audio device menu.

ASIO is Steinberg's audio driver model and is the de facto standard for low-latency audio on Windows. DAWs prefer it over WASAPI for two reasons: ASIO predates WASAPI and has a longer track record on professional audio hardware, and ASIO's callback model exposes a cleaner notion of "fill this output buffer right now" than WASAPI's pull-from-event loop. From a DAW author's perspective, ASIO is the easy path.

The job of `nspaASIO` is to be the ASIO driver Windows audio applications expect, while routing the audio data into a path that ends at JACK. It does *not* talk to JACK directly. There is already a Wine project that does that -- `wineasio`, which implements `IASIO` and opens a JACK client of its own. `nspaASIO` deliberately takes a different shape.

### The layered model

Conceptually, nspaASIO is an ASIO-to-WASAPI-exclusive bridge. When a DAW asks `nspaASIO` to start, `nspaASIO` (in the slow path) opens a `IAudioClient` on the default endpoint in exclusive mode with `EVENTCALLBACK`, sets the buffer duration to the ASIO buffer size, and runs an event-loop thread that does `WaitForSingleObject` on the WASAPI event, then calls the host's `bufferSwitch` callback, then writes the buffer through `GetBuffer` / `ReleaseBuffer`. That `IAudioClient` is backed by `winejack.drv`, so the audio ends up at JACK -- but the layering is clean: ASIO talks to WASAPI, WASAPI talks to JACK.

The mapping table looks like:

| ASIO concept | WASAPI exclusive equivalent |
|---|---|
| `ASIOCreateBuffers(bufferSize)` | `IAudioClient::Initialize(EXCLUSIVE, EVENTCALLBACK, hnsBufferDuration=bufferSize)` |
| `ASIOStart()` -> bufferSwitch | `SetEventHandle()` then a wait-loop that calls `GetBuffer`/`ReleaseBuffer` |
| `ASIOGetLatencies()` | `IAudioClient::GetStreamLatency()` plus per-port JACK latency |
| `ASIOGetSampleRate()` | mix-format sample rate |
| `ASIOGetBufferSize()` | `IAudioClient::GetBufferSize()` |
| Double-buffer swap | per-period `GetBuffer`/`ReleaseBuffer` |

### Why the layered model

The alternative -- having nspaASIO open its own JACK client -- is what `wineasio` does, and it is a simpler architecture for the ASIO use case alone. But it forks the audio code. The same Wine prefix running an ASIO DAW *and* a WASAPI media player *and* a WinMM game now has two JACK clients, two sets of latency-reporting decisions, and two sets of bugs to fix. By going through WASAPI exclusive, nspaASIO and any WASAPI exclusive application share the same `winejack.drv` code path, the same JACK client, the same format conversion logic, the same locking strategy.

This is the third major layer of the winejack stack: MIDI first, then WASAPI audio, then the ASIO bridge that sits on top.

### What's in `nspaasio.c`

The file (~1200 lines) implements the `IASIO` COM vtable: `init`, `start`, `stop`, `getChannels`, `getSampleRate`, `setSampleRate`, `getBufferSize`, `createBuffers`, `disposeBuffers`, `controlPanel`, `future`, `outputReady`, plus the standard COM `QueryInterface` / `AddRef` / `Release`. Most entries are thin -- they translate the ASIO call into a sequence of WASAPI calls or look up a value cached at `init` time.

The interesting entries are `createBuffers` and `start`. `createBuffers` allocates the ASIO buffer pool (per-channel float32 arrays, size 2 -- the standard ASIO double buffer), sets up the WASAPI exclusive client, and *attempts to register with winejack for the direct callback path*. If that registration succeeds, `start` becomes a thin pass-through; if it fails, `start` spins up the play_thread that runs the WASAPI fallback loop.

## 9. Direct callback path: zero-latency bufferSwitch in the JACK callback

The direct callback path gives ASIO applications the same single-period latency as a native JACK client. The idea, in one sentence: *don't run the ASIO bufferSwitch on a separate Wine thread that reads from a buffer the JACK callback wrote -- run bufferSwitch from inside the JACK callback itself, with a futex handshake to a Wine thread that supplies the Win32 thread context.*

### The problem this path solves

The pre-Phase-F (slow-path) ASIO chain looks like this:

    JACK process callback (thread T_jack):
        write capture data into the WASAPI ring buffer (at time t)
        signal the WASAPI event

    Wine play_thread (thread T_play, SCHED_FIFO):
        wake from WaitForSingleObject(WASAPI event)
        call bufferSwitch(buf_idx, ASIOTrue)  -- host fills output (at time t+epsilon)
        write the output via GetBuffer/ReleaseBuffer into the WASAPI ring

    Next JACK process callback (at time t+period):
        read output from the WASAPI ring (at time t+period)
        memcpy into JACK port buffers

The data the host wrote at `t+epsilon` doesn't come out of JACK until `t+period`. That's an entire JACK period of added output latency, on top of whatever the JACK period itself is. For a 64-frame period at 48 kHz that's an extra 1.3 ms; for 256 frames it's 5.3 ms. ASIO drivers with their own JACK clients (wineasio) don't have this added period because they run bufferSwitch *inside* the JACK callback; the WASAPI ring buffer is what costs the period.

The direct callback path removes the period.

### The direct callback architecture

The direct callback path adds a small registration interface between `nspaASIO` and `winejack.drv`. When `nspaASIO::createBuffers` runs and the conditions are met (float32, JACK rate, channel count fits), nspaASIO calls a winejack-private Unix-side function that registers the ASIO callback's buffer pointers and a handshake state. From that point on, the JACK process callback knows about the ASIO stream and dispatches it in-band.

Inside one JACK period:

    JACK process callback (thread T_jack):
        1. Copy JACK capture ports -> ASIO input buffers (memcpy per channel)
        2. CAS handshake state: IDLE -> CAPTURE_READY
        3. futex_wake the play_thread
        4. futex_wait for handshake state == OUTPUT_READY (timeout = 2 * period)
        5. Copy ASIO output buffers -> JACK port buffers (memcpy per channel)
        6. Flip buf_index, reset handshake state to IDLE

    play_thread (thread T_play, Wine, SCHED_FIFO):
        1. Unix call asio_wait_callback (futex_wait for CAPTURE_READY)
        2. bufferSwitch(buf_index, ASIOTrue) -- host fills output
        3. Unix call asio_signal_complete (CAS -> OUTPUT_READY, futex_wake T_jack)

Steps 2 through 4 of the JACK callback take place *while the play_thread is running bufferSwitch*. The JACK callback is parked on a futex and is not consuming CPU. When the host returns from bufferSwitch and the play_thread CASes the state to OUTPUT_READY, the JACK callback wakes, copies the output, and returns. That output goes out the JACK port at the *same period*. The application's data lands at the audio interface in one period, not two.

The futex round trip is on the order of 1 to 2 microseconds on PREEMPT_RT. The full period budget at 48 kHz / 64 frames is 1333 microseconds, of which a typical bufferSwitch consumes 300-800 microseconds in a moderate plugin chain. The handshake overhead is in the noise.

### The PE/Unix boundary

There is one structural complication. The JACK callback runs on a Unix thread (`pthread`-managed by libjack). The play_thread is a Wine PE thread, and the `bufferSwitch` callback is Win32 code that requires a valid Wine thread context (TEB, TLS, exception handling). The futex handshake has to bridge those two worlds.

A PE thread cannot call `syscall(SYS_futex)` directly; the syscall path goes through the Wine NT layer. To work around this, the direct callback path adds four new entries to the audio function table in `mmdevapi/unixlib.h`:

- `register_asio` -- nspaASIO's `createBuffers` calls this with the buffer pointers and channel count
- `unregister_asio` -- nspaASIO's `disposeBuffers` calls this
- `asio_wait_callback` -- the play_thread blocks here until CAPTURE_READY
- `asio_signal_complete` -- the play_thread calls this after bufferSwitch returns

Each is exported from `mmdevapi.spec` and wrapped in `mmdevapi/main.c`. The wrappers are thin; they just dispatch to the active driver's Unix function table. On the Unix side (`winejack.drv/jack.c`), the four functions manipulate the futex word directly. The play_thread crosses the PE/Unix boundary twice per period -- once to wait, once to signal -- which is cheap given the wrapping is a normal Wine unix-call.

Other audio drivers (`winealsa.drv`, `winepulse.drv`, `wineoss.drv`) needed stub entries for the four new function-table slots. Those stubs return `STATUS_NOT_IMPLEMENTED`; ASIO over those drivers falls back to the slow path. Once those drivers are dropped from the build (see Section 12), the stubs become irrelevant.

### Same-period diagram

<div class="diagram-container">
<svg width="100%" viewBox="0 0 800 380" xmlns="http://www.w3.org/2000/svg">
  <style>
    .lbl { fill: #c0caf5; font: 12px monospace; }
    .lbl-dim { fill: #8c92b3; font: 11px monospace; }
    .lbl-hdr { fill: #7aa2f7; font: 13px monospace; font-weight: bold; }
    .lbl-thr { fill: #e0af68; font: 12px monospace; font-weight: bold; }
    .lbl-step { fill: #9ece6a; font: 11px monospace; }
    .lbl-fx { fill: #bb9af7; font: 11px monospace; font-style: italic; }
    .box-jack { fill: #24283b; stroke: #7aa2f7; stroke-width: 1.5; }
    .box-play { fill: #24283b; stroke: #f7768e; stroke-width: 1.5; }
    .box-fx { fill: #1f2335; stroke: #bb9af7; stroke-width: 1; stroke-dasharray: 4 3; }
    .timeline { stroke: #3b4261; stroke-width: 1; }
    .period { stroke: #ff9e64; stroke-width: 1.5; stroke-dasharray: 6 4; }
    .handshake { stroke: #bb9af7; stroke-width: 1.2; }
  </style>

  <text x="400" y="22" text-anchor="middle" class="lbl-hdr">One JACK period under Phase F</text>

  <line x1="80" y1="60" x2="80" y2="320" class="period" />
  <line x1="720" y1="60" x2="720" y2="320" class="period" />
  <text x="80" y="50" text-anchor="middle" class="lbl-dim">t = period start</text>
  <text x="720" y="50" text-anchor="middle" class="lbl-dim">t + period</text>

  <text x="40" y="110" class="lbl-thr">T_jack</text>
  <text x="40" y="125" class="lbl-dim">SCHED_FIFO</text>
  <text x="40" y="138" class="lbl-dim">JACK RT</text>

  <line x1="80" y1="105" x2="720" y2="105" class="timeline" />

  <rect x="90" y="90" width="100" height="32" rx="3" class="box-jack" />
  <text x="140" y="105" text-anchor="middle" class="lbl-step">capture -> ASIO</text>
  <text x="140" y="118" text-anchor="middle" class="lbl-dim">memcpy</text>

  <rect x="195" y="90" width="80" height="32" rx="3" class="box-jack" />
  <text x="235" y="105" text-anchor="middle" class="lbl-step">CAS + wake</text>
  <text x="235" y="118" text-anchor="middle" class="lbl-dim">CAPTURE_READY</text>

  <rect x="280" y="90" width="295" height="32" rx="3" class="box-fx" />
  <text x="427" y="105" text-anchor="middle" class="lbl-fx">futex_wait OUTPUT_READY (T_jack parked)</text>
  <text x="427" y="118" text-anchor="middle" class="lbl-dim">no CPU consumed</text>

  <rect x="580" y="90" width="80" height="32" rx="3" class="box-jack" />
  <text x="620" y="105" text-anchor="middle" class="lbl-step">output -> JACK</text>
  <text x="620" y="118" text-anchor="middle" class="lbl-dim">memcpy</text>

  <rect x="665" y="90" width="50" height="32" rx="3" class="box-jack" />
  <text x="690" y="105" text-anchor="middle" class="lbl-step">flip</text>
  <text x="690" y="118" text-anchor="middle" class="lbl-dim">IDLE</text>

  <text x="40" y="220" class="lbl-thr">T_play</text>
  <text x="40" y="235" class="lbl-dim">SCHED_FIFO</text>
  <text x="40" y="248" class="lbl-dim">Wine PE</text>

  <line x1="80" y1="215" x2="720" y2="215" class="timeline" />

  <rect x="90" y="200" width="180" height="32" rx="3" class="box-fx" />
  <text x="180" y="215" text-anchor="middle" class="lbl-fx">futex_wait CAPTURE_READY</text>
  <text x="180" y="228" text-anchor="middle" class="lbl-dim">parked</text>

  <rect x="280" y="200" width="290" height="32" rx="3" class="box-play" />
  <text x="425" y="215" text-anchor="middle" class="lbl-step">bufferSwitch(buf_idx, true)</text>
  <text x="425" y="228" text-anchor="middle" class="lbl-dim">host fills output (Win32 ctx)</text>

  <rect x="575" y="200" width="85" height="32" rx="3" class="box-play" />
  <text x="617" y="215" text-anchor="middle" class="lbl-step">CAS + wake</text>
  <text x="617" y="228" text-anchor="middle" class="lbl-dim">OUTPUT_READY</text>

  <line x1="270" y1="122" x2="270" y2="200" class="handshake" />
  <line x1="660" y1="232" x2="660" y2="155" class="handshake" />
  <line x1="660" y1="155" x2="580" y2="155" class="handshake" />

  <text x="285" y="170" class="lbl-fx">futex_wake (1)</text>
  <text x="565" y="173" class="lbl-fx">futex_wake (2)</text>

  <text x="80" y="320" class="lbl-dim">data flow: JACK capture -&gt; ASIO input -&gt; bufferSwitch</text>
  <text x="80" y="338" class="lbl-dim">-&gt; ASIO output -&gt; JACK port</text>
  <text x="80" y="356" class="lbl-dim">handshake: IDLE -&gt; CAPTURE_READY -&gt; OUTPUT_READY -&gt; IDLE   (one JACK period)</text>
  <text x="80" y="374" class="lbl-dim">audio out the JACK port at end of same period the host filled</text>
</svg>
</div>

### Why the play_thread is needed at all

A reasonable question is why this path doesn't just call `bufferSwitch` directly from the JACK process callback, with no play_thread. The answer is the Win32 thread context. ASIO host code (the DAW's audio engine, the plugin chain, the VSTs) expects a valid Wine thread when it runs -- it allocates from the heap, takes critical sections, calls Win32 APIs. The JACK process thread is a Unix `pthread` created by libjack and has no Wine context. Constructing one on the fly from a JACK callback is risky -- signal masks, TLS, exception scopes all have to be set up correctly, and any mistake takes down the host.

`wineasio` does take this approach (it uses `jack_set_thread_creator` to construct Wine threads from JACK's thread spawner), but it predates the modern Wine PE/Unix split and operates in a different threading model. The direct callback design preserves the cleaner split: Unix code stays Unix, PE code stays PE, the futex bridges them. The play_thread is a small, persistent Wine thread whose only job is to wake on a futex, run `bufferSwitch`, and signal another futex. It is cheap, predictable, and stays out of the way of the JACK callback.

### Priority configuration

The play_thread is created at `AvSetMmThreadCharacteristics` priority, which on Wine-NSPA maps to a SCHED_FIFO priority *below* the JACK callback's priority. The intent is that the JACK callback (which runs at JACK's process-callback priority, typically RT 80 or higher depending on JACK configuration) is always preemptable up to it -- but the bufferSwitch work runs at high enough priority to not be displaced by ordinary application threads. The exact priority comes from the NSPA priority-mapping table; see the CS-PI document for the details on how Wine-NSPA derives RT priorities from the audio thread's `MMCSS` task name.

The handshake state is a single 32-bit `int` shared between the play_thread and the JACK callback. The CAS sequence is `IDLE -> CAPTURE_READY -> OUTPUT_READY -> IDLE`, and a malformed transition (state observed in an unexpected value) is treated as a protocol error: the JACK callback drops to silence for that period and a counter ticks. In practice the transitions are deterministic; the only error path is timeout, which fires if `bufferSwitch` takes more than two periods to return -- in that case the audio is clearly broken at the host level, and dropping the period is the correct response.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 920 460" xmlns="http://www.w3.org/2000/svg">
  <style>
    .lbl { fill: #c0caf5; font-family: 'JetBrains Mono', monospace; font-size: 12px; }
    .lbl-sm { fill: #c0caf5; font-family: 'JetBrains Mono', monospace; font-size: 10px; }
    .lbl-hdr { fill: #7aa2f7; font-family: 'JetBrains Mono', monospace; font-size: 14px; font-weight: bold; }
    .lbl-state { fill: #e0af68; font-family: 'JetBrains Mono', monospace; font-size: 13px; font-weight: bold; }
    .lbl-trans { fill: #bb9af7; font-family: 'JetBrains Mono', monospace; font-size: 10px; }
    .lbl-trans-em { fill: #bb9af7; font-family: 'JetBrains Mono', monospace; font-size: 11px; font-weight: bold; }
    .lbl-mut { fill: #8c92b3; font-family: 'JetBrains Mono', monospace; font-size: 10px; }
    .lbl-grn { fill: #9ece6a; font-family: 'JetBrains Mono', monospace; font-size: 10px; }
    .lbl-red { fill: #f7768e; font-family: 'JetBrains Mono', monospace; font-size: 10px; font-weight: bold; }
    .state { fill: #1f2335; stroke: #e0af68; stroke-width: 2.2; }
    .state-err { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.8; }
    .legend { fill: #24283b; stroke: #3b4261; stroke-width: 1; }
    .conn { stroke: #bb9af7; stroke-width: 1.8; }
    .conn-err { stroke: #f7768e; stroke-width: 1.5; stroke-dasharray: 6 3; }
    .conn-loop { stroke: #bb9af7; stroke-width: 1.8; fill: none; }
  </style>

  <text x="460" y="26" text-anchor="middle" class="lbl-hdr">Phase F handshake state machine -- one period</text>
  <text x="460" y="44" text-anchor="middle" class="lbl-mut">int handshake_state shared between T_jack and T_play; CAS transitions only</text>

  <rect x="380" y="70" width="160" height="78" rx="8" class="state"/>
  <text x="460" y="98" text-anchor="middle" class="lbl-state">IDLE</text>
  <text x="460" y="116" text-anchor="middle" class="lbl-sm">period boundary</text>
  <text x="460" y="132" text-anchor="middle" class="lbl-mut">T_jack: ready to fire</text>
  <text x="460" y="146" text-anchor="middle" class="lbl-mut">T_play: futex_wait</text>

  <rect x="700" y="220" width="180" height="78" rx="8" class="state"/>
  <text x="790" y="248" text-anchor="middle" class="lbl-state">CAPTURE_READY</text>
  <text x="790" y="266" text-anchor="middle" class="lbl-sm">capture buf populated</text>
  <text x="790" y="282" text-anchor="middle" class="lbl-mut">T_jack: futex_wait OUTPUT</text>
  <text x="790" y="296" text-anchor="middle" class="lbl-mut">T_play: bufferSwitch()</text>

  <rect x="380" y="345" width="160" height="78" rx="8" class="state"/>
  <text x="460" y="373" text-anchor="middle" class="lbl-state">OUTPUT_READY</text>
  <text x="460" y="391" text-anchor="middle" class="lbl-sm">host wrote output</text>
  <text x="460" y="407" text-anchor="middle" class="lbl-mut">T_jack: copy + flip</text>
  <text x="460" y="421" text-anchor="middle" class="lbl-mut">T_play: futex_wait</text>

  <rect x="40" y="220" width="170" height="78" rx="8" class="state-err"/>
  <text x="125" y="248" text-anchor="middle" class="lbl-red">SILENCE / DROP</text>
  <text x="125" y="266" text-anchor="middle" class="lbl-sm">timeout = 2 * period</text>
  <text x="125" y="282" text-anchor="middle" class="lbl-mut">T_jack: zero output</text>
  <text x="125" y="296" text-anchor="middle" class="lbl-mut">period counter++</text>

  <line x1="540" y1="130" x2="700" y2="240" class="conn"/>
  <text x="615" y="178" class="lbl-trans-em">CAS: IDLE -&gt; CAPTURE_READY</text>
  <text x="615" y="192" class="lbl-trans">T_jack copies capture, futex_wake T_play</text>

  <path d="M780 298 L780 330 L540 330 L540 380" class="conn"/>
  <text x="565" y="332" class="lbl-trans-em">CAS: CAPTURE_READY -&gt; OUTPUT_READY</text>
  <text x="565" y="346" class="lbl-trans">T_play returns from bufferSwitch, futex_wake T_jack</text>

  <path d="M 380 380 Q 250 380 250 230 Q 250 130 380 130" class="conn-loop"/>
  <text x="170" y="166" class="lbl-trans-em">CAS: OUTPUT_READY -&gt; IDLE</text>
  <text x="170" y="180" class="lbl-trans">T_jack copies output -&gt; JACK ports, flip buf_idx</text>

  <line x1="700" y1="285" x2="210" y2="270" class="conn-err"/>
  <text x="320" y="222" class="lbl-red">timeout: bufferSwitch &gt; 2 periods</text>

  <line x1="380" y1="120" x2="210" y2="245" class="conn-err"/>
  <text x="225" y="200" class="lbl-red">malformed transition (protocol error)</text>

  <rect x="40" y="78" width="220" height="86" class="legend"/>
  <text x="50" y="96" class="lbl-trans-em">legend</text>
  <line x1="50" y1="108" x2="80" y2="108" class="conn"/>
  <text x="88" y="112" class="lbl-sm">normal CAS transition</text>
  <line x1="50" y1="126" x2="80" y2="126" class="conn-err"/>
  <text x="88" y="130" class="lbl-sm">timeout / malformed</text>
  <text x="50" y="150" class="lbl-mut">all transitions: __atomic_compare_exchange</text>

  <text x="460" y="450" text-anchor="middle" class="lbl-grn">one JACK period total: IDLE -&gt; CAPTURE_READY -&gt; OUTPUT_READY -&gt; IDLE</text>
</svg>
</div>

The state field is a single 32-bit integer; every transition is a `__atomic_compare_exchange` on it. The two threads coordinate without a shared lock or condition variable -- the futex pair (one per direction) plus the CAS state is the entire IPC surface inside the audio period. Errors are noisy but recoverable: a timeout drops one period to silence, the counter ticks, and the next period restarts the cycle from IDLE. There is no recovery state machine because there is no useful recovery -- if `bufferSwitch` ran long, the data it produced is no longer fresh by the time it returns.

### Fallback

If direct callback registration fails -- non-float32 format, channel mismatch, bug in the registration path -- nspaASIO falls back to the WASAPI slow path described in Section 8. The application still works, just with one extra period of latency. There is no version of the code where the application sees an error because this path is unavailable; it is a strict performance enhancement on top of a working WASAPI fallback.

The driver description seen by the DAW is just "nspaASIO" regardless of which path is active. There is no special internal-name string in the DAW-visible UI; the distinction is internal only.

### Earlier direct-buffer design

The earlier per-channel direct-buffer plan was the design where nspaASIO and winejack agreed on per-channel float32 buffer pointers and exchanged data without any interleave step. nspaASIO's play_thread would copy ASIO channels into winejack's per-channel buffers; winejack's RT callback would copy from those into JACK port buffers; total cost two memcpys per channel per period, no format conversion.

The direct callback path is strictly better for the ASIO case because it removes the period of latency that the earlier design could not. The earlier design existed in a partial form (the fast-path per-channel double buffers in Section 6 are descended from it), but the nspaASIO-side direct-buffer access was superseded before it was completed. The fast path on the WASAPI exclusive side remains -- it serves any non-ASIO exclusive WASAPI stream that meets the criteria.

## 10. Intentionally unimplemented surfaces

A few things that look like gaps but are deliberate non-features.

**Sample-rate switching.** ASIO's `setSampleRate()` returns `ASE_NoClock` if the requested rate doesn't match JACK. JACK owns the sample rate -- changing it requires restarting the JACK server, and it isn't a Wine client's place to do that. A real Windows ASIO driver might switch the hardware sample-rate clock on demand, but JACK is fixed by design. This is correct JACK behavior, not a bug.

**WASAPI exclusive at non-JACK rate.** Same reasoning. The driver could in principle add SRC to support exclusive streams at arbitrary rates, but that adds latency and defeats the purpose of exclusive mode. The driver returns `AUDCLNT_E_UNSUPPORTED_FORMAT` for rate mismatches in exclusive mode and lets the application either resample on its side or accept JACK's rate.

**Exclusive-mode lockout.** On real Windows hardware, exclusive mode locks every other application out of the audio device. The Wine-NSPA stack does not enforce this. Two ASIO applications can coexist; an ASIO application and a WASAPI application can coexist; a WASAPI exclusive stream does not preclude a WASAPI shared stream. JACK handles the mixing at the graph level.

This is intentional and follows JACK's graph model. Wineasio has the same behavior. Workloads that require Windows-style exclusive-device lockout should not expect it from this stack.

**Spatial audio (`ISpatialAudioClient`).** No Wine driver implements this and there is no near-term reason to.

**Auxiliary device** (legacy CD-audio volume control). Irrelevant in 2026.

## 11. Deferred work

These are real gaps that aren't shipped yet, in priority order.

**Loopback capture.** `get_loopback_capture_device` is stubbed. JACK can do loopback via port routing, but the Wine driver doesn't expose it as a WASAPI loopback endpoint. OBS, Discord, Audacity loopback recording, and similar use cases need this. Tracking but not yet on the audio stack roadmap.

**Device hotplug.** Endpoint enumeration is built once at first query and not refreshed. Hot-plugging a USB audio interface requires a Wine restart to see the new endpoint. JACK exposes graph-change callbacks that could drive a refresh; the wiring is straightforward, the deferral is just bandwidth.

**`IMMNotificationClient` device-change notifications.** Applications that respond to audio-device hotplug (changing output to a USB headset on connect) don't get notified because the notifications aren't fired. Same root cause as the hotplug deferral.

**Capture fast path.** Only the render path has the per-channel double-buffer fast path. Capture goes through the general interleaved path. Low priority because ASIO capture uses Phase F directly, and the capture rate of typical DAW workloads is far less critical than the render rate.

**ASIO control panel.** `controlPanel()` is a no-op. Some DAWs offer "Open Driver Panel" as a convenience for setting buffer sizes and channel counts. A simple Wine dialog could expose JACK buffer-size and channel-count selection. Nice UX improvement, not on the critical path.

**ASIO future selectors.** `future()` rejects every selector. `kAsioCanReportOverload`, `kAsioSupportsTimeInfo`, `kAsioCanTimeCode` should respond correctly where supported.

**ASIO `outputReady`.** Returns `ASE_NotPresent`. With Phase F driving timing from the JACK callback, this could return `ASE_OK` and let some hosts optimize. Marginal.

**Multiple ASIO device entries.** Some DAWs expect one ASIO driver per physical audio device. nspaASIO appears as a single driver. The DAW's device selector inside nspaASIO would have to expose JACK port groupings as virtual devices. Doable, not done.

**Raw-mode reporting.** `AUDCLNT_STREAMFLAGS_RAWMODE` is ignored. Correct behavior for JACK (no APOs to bypass) but the WASAPI ABI lets applications query whether raw mode is supported, and the answer should be "yes" rather than silently ignored.

## 12. Other audio drivers

`winealsa.drv`, `winepulse.drv`, and `wineoss.drv` are all still present in the source tree because Wine's build system expects them and because they share function-table definitions with `winejack.drv` via `mmdevapi/unixlib.h`. The four new function-table entries Phase F added (`register_asio`, `unregister_asio`, `asio_wait_callback`, `asio_signal_complete`) have stub implementations in each of those drivers that return `STATUS_NOT_IMPLEMENTED`. The MIDI delegation that `winealsa.drv` does (`alsa_midi_get_driver` returning the winejack MIDI driver when `NSPA_JACK_MIDI=1` is set) is still wired up.

The plan, once `winejack.drv` is fully validated for shared, exclusive, and ASIO paths and the deferred items are no longer blocking, is to drop these other drivers from the Wine-NSPA build entirely. The user runs PipeWire with the JACK interface; everything routes through JACK already; the other drivers add no value and can interfere with routing. Disabling them in `configure.ac` (or removing them from the build set) is mechanical. At that point the stub function-table entries become dead code and the Phase F additions to `mmdevapi/unixlib.h` can be split into a winejack-specific header rather than the shared one.

This is filed as future work and not yet executed. The drivers stay in the build for now, as a safety net during the period when winejack still has deferred items.

## 13. Validation

The audio stack has been exercised against a handful of real-world DAW workloads during development. A non-exhaustive list:

- **Ableton Live 12** at 48 kHz, 64-frame and 128-frame JACK periods, both via the WASAPI exclusive path and via nspaASIO with Phase F. Tracked sessions of 30+ tracks with VST instruments and effects, drum-rack lookups during playback, plugin-window UI redraw under transport.
- **vsthost** as a lightweight ASIO host, used to validate `nspaASIO` against synthetic plugin chains -- known good for catching `bufferSwitch` reentrancy and timing bugs without a full DAW's complexity.
- **Chromaphone 3** (32-bit and 64-bit builds) as a standalone ASIO synthesizer, validated end-to-end through `nspaASIO` Phase F. The 32-bit build doubles as a Wow64 bridge test for the audio path.
- **Various media players and browsers** on the WASAPI shared path, validating that shared streams coexist with active ASIO streams without underrun on either side.

The MIDI side has been exercised against external hardware synths over USB-MIDI (Korg, Roland, Novation) for input-timing validation, and against soft-synth plugins inside Ableton for output-timing and SysEx handling.

The validation surface is informal -- there is no PE-side audio test harness comparable to `nspa_rt_test` for the sync primitives -- because the failure modes are perceptual (audible glitches, MIDI smear, latency feel) rather than assertable. Periodic regressions are caught by listening, not by exit code. This is a known limitation; building a deterministic audio reproducer that exercises bufferSwitch reentrancy and JACK callback timing without false positives is non-trivial.

The kernel side -- the PI mutex behavior, the futex round-trip latency under PREEMPT_RT, the SCHED_FIFO priority chain -- has been validated indirectly through the larger Wine-NSPA RT validation suite (`run-rt-suite`, the ntsync test harnesses). When those tests pass clean, the audio path's RT assumptions hold.

## 14. References

### Source

- `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/winejack.drv/jack.c` -- WASAPI audio over JACK, JACK process callback, Phase F registration interface, format conversion
- `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/winejack.drv/jackmidi.c` -- WinMM MIDI over JACK MIDI
- `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/winejack.drv/unixlib.h` -- shared function table for the audio side
- `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/winejack.drv/Makefile.in` -- build configuration, links libjack
- `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/nspaasio/nspaasio.c` -- IASIO COM implementation, WASAPI exclusive client, Phase F registration call
- `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/nspaasio/nspaasio.spec` -- DLL exports
- `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/nspaasio/asio.h` -- vendored ASIO SDK header
- `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/mmdevapi/unixlib.h` -- shared function table including the four Phase F entries
- `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/mmdevapi/main.c` -- PE-side wrappers for the Phase F unix calls
- `/home/ninez/pkgbuilds/Wine-NSPA/wine-rt-claude/wine/dlls/mmdevapi/mmdevapi.spec` -- exports the Phase F wrappers

### Related Wine-NSPA docs

- `cs-pi.gen.html` -- the PI mutex used by `winejack.drv`'s process-callback `trylock`
- `architecture.gen.html` -- system-level overview
- `current-state.gen.html` -- shipping status across Wine-NSPA components
