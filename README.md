# Wine-NSPA:
### A Real-Time Capable and Proaudio-Centric Build of Wine(-TKG).

![My Image](/examples/images/Wine-NSPA_desktop.png)

_________________________

## Preface:

Wine-NSPA aims to be a real-time capable, highly-deterministic, and proaudio-centric build of Wine. The focus is making pro-audio software run well in Wine-NSPA; quite similar to how Wine-Proton focuses on making Games run well in Wine-Proton. 

This requires having more robust and complete Real-Time scheduling integration, using Futexes for Windows Synchronization primitives, making Wineserver multi-threaded, and so on. It also involves leveraging performane optimizations, along with including workarounds and hacks whenever necessary to not only make software work, but run well. I use Wine-TKG build system to simplify patch management and reduce maintainance-time. This also allow easy integration of Wine-Staging, and also other advanced configurations && customizations.

_________________________

## Features (non-exhaustive)

* **Wine-NSPA-Specific Wine-RT Implementation**
* **Improved multi-threading / scheduling support**
* **Various Locking, Atomics & Membarrier Optmizations/Improvements**
* **Implement get/setProcessWorkingSetSize with Memory Locking**
* **Wineserver SHMEM Per Thread (Server Requests/Replies)**
* **Wine Qpc-rdTSC Optimizations Hacks**
* **CS Dynamic Spinning with Adaptive Yielding**
* **Large/Huge Pages Suport within Wine-NSPA**
* **Esync / Fsync Proton 9.0+ implementation**
* **Keyed Events Linux Futexes Implementation**
* **Numerous Performance Optimizations**
* **Significant backports and Bugfixes**
* **Hacks to improve Wine for NSPA usage**
* **Loader/vDSO performance Optimizations**
* **Proton's CPU Topology Overrides**
* **Improved Debugging Support**
* **Wineserver + Ntdll backports**
* **MSVCRT backports/updates**
* **IOSB backports/updates**

*note: too many other bits to list here, but you get the idea!*

_________________________

### Pi Mutexes Support (Optional)

I have been working on replacing Wine's pthread_mutex implementation with PI Mutexes, via Librpti: https://github.com/nine7nine/librtpi ... This means implementing Priority Inheritance within Wine-NSPA, which has some tangible benefits/advantages: 

__"...to bridge the gap between the glibc pthread implementation and a functionally correct priority inheritance for pthread locking primitives, such as pthread_mutex and pthread_condvar. Specifically, priority based wakeup is required for correct operation, in contrast to the more time-based ordered wakeup groups in the glibc pthread condvar implementation.".__

Check the Installation instructions, as this requires a couple of manual steps: 

https://github.com/nine7nine/Wine-NSPA/wiki/Installation

This is totally optional, However: My own local builds use Pi Mutexes and I am looking into integration of this library / PI Mutexes into Wine-NSPA builds (by default, explicitly). So it's probably worth buiding this into your own builds anyway. 

_________________________

## Wine-NSPA Wiki 

NOTE: Please read the Wiki. There are necessary steps for getting Wine-NSPA working properly. By default, without setting environment variable in `/etc/environment` wine-NSPA won't work correctly, for example. 

https://github.com/nine7nine/Wine-NSPA/wiki 

_________________________

## Linux-NSPA:

As mentioned above some features in Wine-NSPA do require kernel support. For that reason, I maintain my own Archlinux 
PKGBUILDs. You can find my archlinux package (sources) and kernel sources repository linked below;

* Linux-NSPA PKGBUILD - https://github.com/nine7nine/Linux-NSPA-pkgbuild

_note: This is a Customized Realtime Linux kernel._

It is recommended to use my kernel (or another RT kernel, especially if using PI Mutexes). I do not use/test other kernels, especially not poorly configured distro kernels that aren't setup to be deterministic or offer low-latency.

...and before anyone flames about this, or thinks I am flaming:

__Stock Arch kernel (Cyclictest):__

```
# /dev/cpu_dma_latency set to 0us
policy: fifo: loadavg: 3.10 1.11 0.40 1/437 3469           

T: 0 ( 2745) P:90 I:200 C: 178254 Min:      1 Act:    2 Avg:    2 Max:     161
T: 1 ( 2746) P:90 I:200 C: 178244 Min:      1 Act:    2 Avg:    2 Max:     212
T: 2 ( 2747) P:90 I:200 C: 178235 Min:      1 Act:    2 Avg:    2 Max:     161
T: 3 ( 2748) P:90 I:200 C: 178222 Min:      1 Act:    2 Avg:    2 Max:     510
T: 4 ( 2749) P:90 I:200 C: 178213 Min:      1 Act:    2 Avg:    2 Max:     350
T: 5 ( 2750) P:90 I:200 C: 178205 Min:      1 Act:    2 Avg:    2 Max:     548
T: 6 ( 2751) P:90 I:200 C: 178199 Min:      1 Act:    2 Avg:    2 Max:     175
T: 7 ( 2752) P:90 I:200 C: 178186 Min:      1 Act:    2 Avg:    2 Max:     619
```

__Linux-NSPA (Cyclictest):__

```
# /dev/cpu_dma_latency set to 0us
policy: fifo: loadavg: 4.12 2.36 1.80 1/877 7224          

T: 0 ( 7210) P:90 I:200 C:  38605 Min:      1 Act:    2 Avg:    2 Max:      44
T: 1 ( 7211) P:90 I:200 C:  38583 Min:      1 Act:    1 Avg:    2 Max:      51
T: 2 ( 7212) P:90 I:200 C:  38578 Min:      1 Act:    2 Avg:    2 Max:      55
T: 3 ( 7213) P:90 I:200 C:  38564 Min:      1 Act:    1 Avg:    2 Max:      46
T: 4 ( 7214) P:90 I:200 C:  38550 Min:      1 Act:    2 Avg:    2 Max:      43
T: 5 ( 7215) P:90 I:200 C:  38538 Min:      1 Act:    2 Avg:    2 Max:      63
T: 6 ( 7216) P:90 I:200 C:  38525 Min:      1 Act:    1 Avg:    1 Max:      43
T: 7 ( 7217) P:90 I:200 C:  38513 Min:      1 Act:    1 Avg:    2 Max:      44
```

While not an extensive stresstest - you get the idea, stock kernels are non-deterministic.

The differences are staggering.

_________________________

## Windows DAW / Heavy ProAudio Application Support

![](https://github.com/nine7nine/Wine-NSPA/blob/main/examples/images/Live11.png)

I've worked to improve multithreading, scalability and my RT support within Wine-NSPA. This should now allow heavy applications like Ableton Live 12 to work acceptably in Wine-NSPA. This work is almost complete, but I'm also tracking Ableton Live support/documentation here: https://github.com/nine7nine/Wine-NSPA/issues/4 ... 

In the case of Ableton Live: I've solved all of the show-stoping issues, preventing it from running nicely. This won't automatically solve certain VSTs or presets from using high CPU usage, but well-supported software in Wine should run decently. Mileage will vary, of course! 

_________________________

## DPC Latency Checker

DPC Latency Checker is used in older versions of Windows to verify if your system is suitable for realtime performance. Assuming you have decent hardware (higher specs, well-designed mobo, interrupts layout, good drivers, etc), AND you've configured your system very well. You can use DPC Latency Checker with Wine-NSPA. ( you can google and find DPC Latency Checker v1.40, if you like ).

![](https://github.com/nine7nine/Wine-NSPA/blob/main/examples/images/Dpc_Latency_Test.png)

The above is from my Microsoft Surface 7. It's a decently designed PC running Linux-NSPA on a well-configured Arch Linux system. NOTE: this isn't a substitute replacement for rt-tests (cyclictest, hackbench) for testing a linux system: but will help indicate if your Wine-NSPA / linux system setup is actually usable for ProAudio.
_________________________

### Credits/Shoutouts:

* WineHQ: https://www.winehq.org/
* WineHQ Gitlab: https://gitlab.winehq.org/wine
* Wine-Staging: https://github.com/wine-staging/wine-staging
* Wine-TKG: https://github.com/Frogging-Family/wine-tkg-git
* RBernon's Wine Repo: https://github.com/rbernon/wine
* Openglfreak Repo: https://github.com/openglfreak/wine-tkg-userpatches
* Valve's Proton: https://github.com/ValveSoftware/Proton
* Realtime Linux: https://wiki.linuxfoundation.org/realtime/start
* Jack Audio Connection Kit: https://jackaudio.org/
* Pipewire: https://gitlab.freedesktop.org/pipewire/pipewire
* WineASIO: https://github.com/wineasio/wineasio
* FalkTX: https://github.com/falkTX/Carla
* Robbert-vdh: https://github.com/robbert-vdh/yabridge
* Arch Linux: https://archlinux.org/
* Linuxaudio: https://linuxaudio.org/

_Other people of note: Jack Winter, Paul Davis and the whole Linuxaudio community._
