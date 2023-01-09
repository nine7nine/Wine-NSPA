# Wine-NSPA:
### A Real-Time Capable and Proaudio-Centric Build of Wine(-TKG).

![My Image](/examples/images/Wine-NSPA_desktop.png)

__Wine-NSPA Wiki;__ https://github.com/nine7nine/Wine-NSPA/wiki
_________________________

### IMPORTANT:

 - While I have begun Wine-NSPA-8.0 development: I Do NOT recommend using or building Wine-NSPA-devel. It's highly experiemental and there are some issues with Upstream Wine that need to be addressed (some really annoying bugs/instability caused by upstream). I expect now that the 'Feature Freeze' has begun, we should start seeing some of the bugs / regressions getting fixed, but it'll take a bit of time... Please use Wine-NSPA-7.5, it is rather stable and works well. I will eventually promote / replace 7.5, when 8.0 is ready.

### Preface:

Wine-NSPA focuses on the integration of performance enhancements and RT related features that help proaudio apps run better. Currently, Fsync/futex_waitv is the prefered method for improving synchronization primitives support, which requires kernel-level support (linux-5.16+). I have implemented improved Scheduling and RT support via out-of-tree patchwork, and my own modifications to Wine. This fork also integrates the out-of-tree Wineserver Shared Memory patchset, a Multi-threaded Wineserver implementation (shmem per Thread patch), the Wine Low Fragmentation Heap patchwork, and a number of other out-of-tree patchsets. Some of these other features do require kernel-level support. (but Wine-NSPA will work without them too).

![](https://github.com/nine7nine/Wine-NSPA/blob/main/examples/images/terminal-banner.png)

Wine-NSPA is currently based on Wine-7.5; due to newer versions having some regressions and bugs that affect some applications that I use (showstopping bugs). Wine-7.5 seems to be fairly solid and I don't have any desire to chase every development release. That said; I do pickup upstream bugfixes, MRs and the occasional patch from WineHQ Bugzilla. Additionally, Wine-TKG is used as a base; as it's a powerful build system, flexible, easy to use and significantly reduces maintenance burden. It also supports Archlinux / Makepkg, which makes building and packaging Wine a straightforward process.

_________________________

### Features (non-exhaustive)

* **NSPA-Specific Wine-RT Implementation**
* **Improved multi-threading / scheduling support**
* **Various Locking, Atomics & Membarrier Optmizations/Improvements**
* **Kernelbase linux-thread RT hooking for TIME_CRITICAL threads*** 
* **Wineserver Shared Memory support**
* **Wineserver SHMEM Per Thread (Server Requests/Replies)**
* **Esync / Fsync Proton 7.0-experimental implementation**
* **Wine Low Fragmentation Heap Patchwork**
* **Keyed Events Linux Futexes Implementation**
* **Numerous Performance Optimizations**
* **Significant backports and Bugfixes**
* **Winserver + Ntdll backports**
* **MSVCRT backports/updates**
* **Hacks to improve Wine for NSPA usage**
* **Loader/vDSO performance Optimizations**
* **Proton's CPU Topology Overrides**

*note: too many other bits to list here*
_________________________

### Linux-NSPA:

As mentioned above, some features in Wine-NSPA do require kernel support. For that reason, I maintain my own Archlinux 
PKGBUILDs. You can find my archlinux package (sources) and kernel sources repository linked below;

* Linux-NSPA PKGBUILD - https://github.com/nine7nine/Linux-NSPA-pkgbuild

_note: This is a Customized Realtime Linux kernel._

I HIGHLY suggest that you use Linux-NSPA with Wine-NSPA over any other kernel. Vanilla distribution kernels are often not configured for optimal performance and more often than not: poorly configured for proaudio / realtime workloads. On top of that; I have patchwork that may not only improve performance, but actually resolve issues that may be wine-specific (such as the rwlock/rw_semaphore issues on RT that may crash some wine applications).
_________________________

### DPC Latency Checker

DPC Latency Checker is used in older versions of Windows to verify if your system is suitable for realtime performance. Assuming you have decent hardware (higher specs, solid MOBO, etc) AND You've configured your system very well you can use DPC Latency Checker with Wine-NSPA:

![](https://github.com/nine7nine/Wine-NSPA/blob/main/examples/images/Dpc_Latency_Test.png)

NOTE: this isn't a substitute for rt-tests, hackbench, cyclictest and friend;: but will help indicate if your Wine-NSPA / system setup is actually usable for ProAudio.

### Windows DAW / Heavy ProAudio Application Support

![](https://github.com/nine7nine/Wine-NSPA/blob/main/examples/images/Live11.png)
Preview: Ableton Live 11 running in Wine-NSPA-7.5 with a number of patches/fixes to better support it.

Currently, I'm working with some experimental patchwork to improve multithreading, scalability and my RT support. This should get heavy applications like Ableton Live 11 working nicely in Wine-NSPA. This work is partially complete, but I'm also tracking Ableton Live support/documentation here: https://github.com/nine7nine/Wine-NSPA/issues/4 ...

### Future Work && Plans

Wine-NSPA will be rebased on Wine-8.0+ in the future, but only when 8.0+ becomes more suitable. Atm, Wine-8.0-rc has problems/regressions, when compared to Wine-7.5... The performance is lacking, there are some nasty bugs and overall it's just not good enough for me.* I prefer to have reliable builds that are usuable. Right now, my Wine-7.5 builds are just significatly better than newer versions of Wine (for a variety of reasons).

### Credits/Shoutouts:

* WineHQ: https://www.winehq.org/
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


