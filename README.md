# Wine-NSPA:
### A Real-Time Capable and Proaudio-Centric Build of Wine(-TKG).

![My Image](/examples/images/Wine-NSPA_desktop.png)

_________________________

![](https://github.com/nine7nine/Wine-NSPA/blob/main/examples/images/terminal-banner.png)

### Preface:

Wine-NSPA aims to be a real-time capable, highly-deterministic, and proaudio-centric build of Wine. The focus is making pro-audio software run well in Wine-NSPA; quite similar to how Wine-Proton focuses on making Games run well in Wine. 

This requires having more robust and complete Real-Time scheduling integration, using Futexes for Windows Synchronization primitives, making Wineserver multi-threaded, and so on. It also involves leveraging performane optimizations, along with including workarounds and hacks whenever necessary to not only make software work, but run well.

_________________________

### Features (non-exhaustive)

* **Wine-NSPA-Specific Wine-RT Implementation**
* **Improved multi-threading / scheduling support**
* **Various Locking, Atomics & Membarrier Optmizations/Improvements***
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
* **Winserver + Ntdll backports**
* **MSVCRT backports/updates**
* **ISOB backports/updates**

*note: too many other bits to list here, but you get the idea!*

### Pi Mutexes Support (Optional)

I have been working on replacing Wine's pthread_mutex implementation with PI Mutexes, via Librpti: https://github.com/nine7nine/librtpi ... This means implementing Priority Inheritance within Winei-NSPA, which has some tangible benefits/advantages: 

_"...to bridge the gap between the glibc pthread implementation and a functionally correct priority inheritance for pthread locking primitives, such as pthread_mutex and pthread_condvar. Specifically, priority based wakeup is required for correct operation, in contrast to the more time-based ordered wakeup groups in the glibc pthread condvar implementation."._

Check the Installation instructions, as this requires a couple of manual steps: 

https://github.com/nine7nine/Wine-NSPA/wiki/Installation

Totally optional, However: My own local builds use Pi Mutexes and I am looking into integration of this library / PI Mutexes into Wine-NSPA builds (by default, explicitly). So it's probably worth buiding this into your own builds anyway. 

_________________________

### Wine-NSPA Wiki 

https://github.com/nine7nine/Wine-NSPA/wiki 

NOTE: Please read the Wiki. There are necessary steps in there for getting Wine-NSPA working properly.

_________________________

### Linux-NSPA:

As mentioned above, some features in Wine-NSPA do require kernel support. For that reason, I maintain my own Archlinux 
PKGBUILDs. You can find my archlinux package (sources) and kernel sources repository linked below;

* Linux-NSPA PKGBUILD - https://github.com/nine7nine/Linux-NSPA-pkgbuild

_note: This is a Customized Realtime Linux kernel._

I HIGHLY suggest that you use Linux-NSPA with Wine-NSPA over any other kernel. Vanilla distribution kernels are often not configured for optimal performance, and more often than not: are poorly configured for proaudio / realtime workloads.
_________________________

### Windows DAW / Heavy ProAudio Application Support

![](https://github.com/nine7nine/Wine-NSPA/blob/main/examples/images/Live11.png)

I'm working hard to improve multithreading, scalability and my RT support. This should allow heavy applications like Ableton Live 12 working acceptably in Wine-NSPA. This work is almost complete, but I'm also tracking Ableton Live support/documentation here: https://github.com/nine7nine/Wine-NSPA/issues/4 ... 

In the case of Ableton Live: I've solved nearly all of the show-stoping issues, preventing it from running nicely. This won't automatically solve certain VSTs from hving high CPU usage, but well-supported software in Wine should run decently. Mileage will vary, of course!

_________________________

### DPC Latency Checker

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
