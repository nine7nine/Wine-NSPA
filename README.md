# Wine-NSPA:
### A Real-Time Capable and Proaudio-Centric Build of Wine(-TKG).

![My Image](/examples/images/Wine-NSPA_desktop.png)

__Wine-NSPA Wiki;__ https://github.com/nine7nine/Wine-NSPA/wiki
 Wine-NSPA focuses on the integration of performance enhancements and RT related features that help proaudio apps run better. Currently, Fsync/futex_waitv is the prefered method for improving syncronization primitives support, which requires kernel-level support (linux-5.16+). I have implemented improved Scheduling and RT support via out-of-tree patchwork and my own modifications to Wine. This fork also integrates the out-of-tree Wineserver Shared Memory patchset, the Wine Low Fragmentation Heap patchwork and a number of other out-of-tree patchsets. Some of these other features require kernel-level support.

Wine-NSPA is currently based on Wine-7.5; due to newer versions having some regressions and bugs that affect some applications that I use (showstopping bugs). Wine-7.5 seems to be fairly solid and I don't have any desire to chase every development release. That said; I do pickup upstream bugfixes, MRs and the occasional patch from WineHQ Bugzilla. Additionally, Wine-TKG is used as a base; as it's a powerful build system, flexible, easy to use and significantly reduces maintenance burden. It also supports Archlinux / Makepkg, which makes building and packaging Wine a straightforward process.

As mentioned above, some features in Wine-NSPA require kernel support. I provide my own kernel sources + Archlinux 
PKGBUILDs for my own custom kernel. Found here;

* Linux-NSPA PKGBUILD - https://github.com/nine7nine/Linux-NSPA-pkgbuild
* Linux-NSPA Kernel Sources - https://github.com/nine7nine/Linux-NSPA

note: This is a Customized Realtime Linux kernel.

__Credits/Shoutouts:__

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
