# Wine-NSPA:
### A Real-Time Capable and Proaudio-Centric Build of Wine(-TKG).

![My Image](/examples/images/Wine-NSPA_desktop.png)

__Wine-NSPA Wiki;__ https://github.com/nine7nine/Wine-NSPA/wiki
_________________________

### Preface:

Wine-NSPA focuses on the integration of performance enhancements and RT related features that help proaudio apps run better. Currently, Fsync/futex_waitv is the prefered method for improving syncronization primitives support, which requires kernel-level support (linux-5.16+). I have implemented improved Scheduling and RT support via out-of-tree patchwork and my own modifications to Wine. This fork also integrates the out-of-tree Wineserver Shared Memory patchset, the Wine Low Fragmentation Heap patchwork and a number of other out-of-tree patchsets. Some of these other features require kernel-level support.

![](https://github.com/nine7nine/Wine-NSPA/blob/main/examples/images/terminal-banner.png)

Wine-NSPA is currently based on Wine-7.5; due to newer versions having some regressions and bugs that affect some applications that I use (showstopping bugs). Wine-7.5 seems to be fairly solid and I don't have any desire to chase every development release. That said; I do pickup upstream bugfixes, MRs and the occasional patch from WineHQ Bugzilla. Additionally, Wine-TKG is used as a base; as it's a powerful build system, flexible, easy to use and significantly reduces maintenance burden. It also supports Archlinux / Makepkg, which makes building and packaging Wine a straightforward process.
_________________________

### Feature-sets (non-exhaustive)

* NSPA-Specific Wine-RT Implementation - Almost all wine threads use real-time scheduling (both Round-Robin and FIFO)
* Wineserver Shared Memory support - based on the 7.5 patchset with minor changes to rebase on NSPA
* Esync / Fsync - based on the Proton implementation (Wine-TKG/staging is way behind on Fsync support / patchwork)
* Wine Low Fragmentation Heap Patchwork - Based on the 7.5 patchset with some changes / additional patches
* Winserver + Ntdll backports - in some cases, sync'd with upstream.
* MSVCRT backports - sync'd to upstream, includes task scheduler changes
* Keyed Events Linux Futexes Implementation - includes MSVCRT concurrency modifications
* Performance optimizations of various componenets in Wine. (eg: memcmp, memove avx, etc)
* Significant backports and Bugfixes from Wine-Git, Wine's bug tracker, OpenGLFreak's wine patchwork and Proton
* Hacks to improve Wine for NSPA usage (eg: killing update window, killing dragndrop spam for NI plugins, etc)
* Loader/vDSO performance optimizations (backported)
* Proton's CPU Topology Overrides (latest implementation)
* Various Locking improvements
_________________________

### Linux-NSPA:

As mentioned above, some features in Wine-NSPA do require kernel support. For that reason, I maintain my own linux kernel sources + Archlinux 
PKGBUILDs. You can find my archlinux package (sources) and kernel sources repository linked below;

* Linux-NSPA PKGBUILD - https://github.com/nine7nine/Linux-NSPA-pkgbuild
* Linux-NSPA Kernel Sources - https://github.com/nine7nine/Linux-NSPA

_note: This is a Customized Realtime Linux kernel._
_________________________

### Wine-NSPA-Patched: 

* Fully patched wine-NSPA sources: https://github.com/nine7nine/Wine-NSPA-patched

_note: all of the commits are squashed, due to how Wine-TKG generates patches. I'm mainly providing patched sources, as some may find it useful. 
Likewise, I've also considered using pre-patched sources for building and automateed testing and/or analysis tools._
_________________________

### Credits/Shoutouts:

* WineHQ: https://www.winehq.org/
* Wine-Staging: https://github.com/wine-staging/wine-staging
* Wine-TKG: https://github.com/Frogging-Family/wine-tkg-git
* RBernon's Wine Repo: https://github.com/rbernon/wine
* Openglfreak Repo: https://github.com/openglfreak/wine-tkg-userpatches
* Valve's Proton: https://github.com/ValveSoftware/Proton
* Realtime Linux: https://wiki.linuxfoundation.org/realtime/start
* CachyOS Linux: https://github.com/CachyOS/linux-cachyos 
* Jack Audio Connection Kit: https://jackaudio.org/
* Pipewire: https://gitlab.freedesktop.org/pipewire/pipewire
* FalkTX: https://github.com/falkTX/Carla
* Robbert-vdh: https://github.com/robbert-vdh/yabridge
* Arch Linux: https://archlinux.org/
* Linuxaudio: https://linuxaudio.org/

_Other people of note: Jack Winter, Paul Davis and the whole Linuxaudio community._
