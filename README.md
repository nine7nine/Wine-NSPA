# Wine-NSPA: 

![My Image](/examples/images/wine-nspa-Banner.png)

### A Real-Time Proaudio-Centric Build of Wine(-TKG). 

This fork tries to integrate all of the performance and RT related features, that help proaudio apps run better.
Fsync/futex_waitv is currently the prefered method for improving syncronization support. ( it requires kernel-level
support (linux-5.16+)). Wine-TKG is used as a base, as it's a powerful build system, flexible and easy to use.

Wine-NSPA has additional scheduling and RT capabilities; leveraging out-or-tree scheduling patches to do so. 
First, nice priorites can/are setup for all threads in Wine. Second, Real-Time priorities AND policies can also be 
setup for Wine's threads / application threads. In fact, the majority of threads in Wine-NSPA can be made RT and many 
of the threads are set to Real-Time without Wineserver. Ntdll has been modified to filter and set pthread && fsync
related threads to RT. Have a look below;

![My Image](/examples/images/wine-nspa_wine_proc_threads.png)

Here, we can see wine's own process threads are running as Real-Time. What you can't see here is that these threads
are mostly futex-related and are running with SCHED_RR policy, while the highest RT priority threads are FIFO. The main 
process threads do not run as Real-Time... 

Next, have a look at application threads; 
![My Image](/examples/images/wine-nspa_app_threads.png)

The very highest priority RT threads are FIFO (winAPI TIME_CRITICAL = -76); while all lower RT priority threads 
are SCHED_RR. Notably, the very loweest RT priority threads are important; _these are worker threads and the Wine-rt patch 
can't set them as RT properly._ <- Have you ever ran into a multi-processor mode in a plugin that causes xruns and 
glitching? Well, it's likely because the plugin's worker threads weren't running with Real-Time priorities.

In Wine-NSPA, various Environment Variables must be set for an application to make use of this fork's features.
You can find examples of running Proaudio apps AND also running apps where you don't want certain features or RT 
enabled. Have a look here; https://github.com/nine7nine/Wine-NSPA/tree/main/examples/bin

### List of useful Wine-NSPA env variables

* __WINE_RT_PRIO=78__ : Set RT thread Prioties from Wineserver -> Sets highest priority, then decrements by 2.
* __WINE_RT_POLICY="FF"__ : Set RT Policy from Wineserver. -> TIME_CRITICAL threads = SCHED_FIFO.
* __NTDLL_RT_PRIO=5__ : Set RT thread priorities from Ntdll -> NT threads: fsync'd APCs or non-winAPI pthreads. 
* __NTDLL_RT_POLICY="RR"__ : Set NTDLL scheduling policy. -> supports FF, RR and TS.
* __WINEESYNC=1__ : Esync server-side synchronization. -> Fsync is better.
* __WINEFSYNC=1__ : Fsync kernel-side synchronization. -> futex-based, futex_waitv (linux-5.16+).
* __WINEFSYNC_SPINCOUNT=128__ : Fsync spincount.
* __WINE_LOGICAL_CPUS_AS_CORES=1__ : treat logical cores as cpus.
* __WINE_LARGE_ADDRESS_AWARE=1__ : allow 32bit applications to use more memory.
* __STAGING_WRITECOPY=0__: Staging's writecopy patch. -> cannot be used with kernel writewatch.
* __WINE_DISABLE_KERNEL_WRITEWATCH=0__ : kernel writewatch. -> requires kernel support.

_This is a rough summary, for now. More details will be added later._

As mentioned above, some features in Wine-NSPA require kernel support. I provide my own kernel sources + Archlinux 
PKGBUILDs for my own custom kernel. Found here;

* Archlinux PKGBUILD - https://github.com/nine7nine/Linux-NSPA-pkgbuild
* My Linux Kernel Sources - https://github.com/nine7nine/Linux-NSPA

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





