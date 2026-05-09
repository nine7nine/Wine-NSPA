# Wine-NSPA -- Win32 Condvar PI (Requeue-PI)

This page is the design and implementation reference for the Win32 condvar PI bridge, including the requeue-PI syscall pairing, correctness envelope, and validation results.

---

## Table of Contents

1. [Overview](#1-overview)
2. [The Problem](#2-the-problem)
3. [Architecture](#3-architecture)
4. [Condvar-to-Mutex Mapping Table](#4-condvar-to-mutex-mapping-table)
5. [Syscall Interface](#5-syscall-interface)
6. [Correctness Properties](#6-correctness-properties)
7. [Relationship to Existing PI Infrastructure](#7-relationship-to-existing-pi-infrastructure)
8. [Test Results](#8-test-results)
9. [Files Changed](#9-files-changed)

---

## 1. Overview

Win32 condvar PI bridges `RtlSleepConditionVariableCS` to the Linux kernel's requeue-PI mechanism. When a `SCHED_FIFO` (RT) thread waits on a condition variable protected by a PI-enabled critical section, the kernel atomically requeues the waiter from the condvar futex onto the CS's PI mutex on signal. This eliminates the priority inversion window between condvar wake and CS reacquire that exists in the standard Win32 condvar path.

The implementation uses two Linux futex operations that form a matched pair:

- **`FUTEX_WAIT_REQUEUE_PI`** -- the waiter sleeps on the condvar futex but declares a PI mutex it expects to be requeued onto
- **`FUTEX_CMP_REQUEUE_PI`** -- the signaler atomically wakes/requeues waiters from the condvar futex onto that PI mutex

The entire condvar PI path is gated behind `nspa_cs_pi_active()` -- when inactive (no `NSPA_RT_PRIO` set), the code is byte-identical to upstream Wine. The gate also requires `RecursionCount == 1` (non-recursive lock hold) because the kernel's PI mutex has no recursion concept.

---

## 2. The Problem

The standard Win32 `SleepConditionVariableCS` implementation has a structural priority inversion gap. Between the moment a waiter is woken from the condvar and the moment it reacquires the critical section, there is no PI protection -- a low-priority thread holding the CS will not be boosted, and the RT waiter can be preempted by medium-priority threads (classic priority inversion).

### Priority Inversion Gap Diagram

<div class="diagram-container">
<svg width="100%" viewBox="0 0 900 520" xmlns="http://www.w3.org/2000/svg">
  <style>
    .cv-box { fill: #24283b; stroke: #9aa5ce; stroke-width: 1.5; rx: 6; }
    .cv-box-nspa { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 6; }
    .cv-box-danger { fill: #2a1a1a; stroke: #f7768e; stroke-width: 2; rx: 6; }
    .cv-box-kernel { fill: #1a1a2a; stroke: #bb9af7; stroke-width: 1.5; rx: 6; }
    .cv-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .cv-label-sm { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .cv-label-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cv-label-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cv-label-yellow { fill: #e0af68; font-size: 12px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cv-label-cyan { fill: #7dcfff; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .cv-label-muted { fill: #c0caf5; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .cv-label-accent { fill: #7aa2f7; font-size: 12px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .cv-arrow { stroke: #9aa5ce; stroke-width: 1.5; fill: none; }
    .cv-arrow-green { stroke: #9ece6a; stroke-width: 2; fill: none; }
    .cv-arrow-red { stroke: #f7768e; stroke-width: 2; fill: none; }
    .cv-divider { stroke: #6b7398; stroke-width: 1; stroke-dasharray: 8,4; }
    .cv-danger-zone { fill: #f7768e; fill-opacity: 0.08; stroke: #f7768e; stroke-width: 1.5; stroke-dasharray: 4,3; rx: 6; }
    .cv-safe-zone { fill: #9ece6a; fill-opacity: 0.06; stroke: #9ece6a; stroke-width: 1.5; stroke-dasharray: 4,3; rx: 6; }
  </style>

  <!-- Column headers -->
  <text x="225" y="25" class="cv-label-accent" text-anchor="middle">Before: Standard Win32 Path</text>
  <text x="675" y="25" class="cv-label-accent" text-anchor="middle">After: Requeue-PI Path (NSPA)</text>
  <line x1="450" y1="10" x2="450" y2="505" class="cv-divider"/>

  <!-- === LEFT COLUMN: Standard path === -->

  <!-- Step 1: capture + leave -->
  <rect x="30" y="45" width="380" height="35" rx="6" class="cv-box"/>
  <text x="220" y="60" class="cv-label" text-anchor="middle">capture value</text>
  <text x="220" y="73" class="cv-label-sm" text-anchor="middle">val = *(LONG*)&amp;condvar-&gt;Ptr</text>

  <line x1="220" y1="80" x2="220" y2="95" class="cv-arrow"/>

  <rect x="30" y="95" width="380" height="35" rx="6" class="cv-box"/>
  <text x="220" y="110" class="cv-label" text-anchor="middle">RtlLeaveCriticalSection</text>
  <text x="220" y="123" class="cv-label-sm" text-anchor="middle">CS released (FUTEX_UNLOCK_PI)</text>

  <line x1="220" y1="130" x2="220" y2="145" class="cv-arrow"/>

  <!-- Step 2: wait -->
  <rect x="30" y="145" width="380" height="35" rx="6" class="cv-box"/>
  <text x="220" y="160" class="cv-label" text-anchor="middle">RtlWaitOnAddress (condvar futex)</text>
  <text x="220" y="173" class="cv-label-muted" text-anchor="middle">sleeping... no PI protection</text>

  <line x1="220" y1="180" x2="220" y2="195" class="cv-arrow"/>

  <!-- Step 3: WAKE -->
  <rect x="30" y="195" width="380" height="30" rx="6" class="cv-box"/>
  <text x="220" y="215" class="cv-label-cyan" text-anchor="middle">WAKE (signaler increments condvar)</text>

  <line x1="220" y1="225" x2="220" y2="245" class="cv-arrow-red"/>

  <!-- DANGER ZONE -->
  <rect x="25" y="245" width="390" height="95" rx="6" class="cv-danger-zone"/>
  <text x="220" y="265" class="cv-label-red" text-anchor="middle">PRIORITY INVERSION GAP</text>
  <text x="220" y="282" class="cv-label-sm" text-anchor="middle">RT waiter is runnable but does NOT own CS</text>
  <text x="220" y="297" class="cv-label-sm" text-anchor="middle">Low-prio thread may hold CS with no PI boost</text>
  <text x="220" y="312" class="cv-label-sm" text-anchor="middle">Medium-prio threads can preempt RT waiter</text>
  <text x="220" y="327" class="cv-label-red" text-anchor="middle">Unbounded delay possible</text>

  <line x1="220" y1="340" x2="220" y2="360" class="cv-arrow-red"/>

  <!-- Step 4: reacquire -->
  <rect x="30" y="360" width="380" height="35" rx="6" class="cv-box"/>
  <text x="220" y="375" class="cv-label" text-anchor="middle">RtlEnterCriticalSection</text>
  <text x="220" y="388" class="cv-label-sm" text-anchor="middle">FUTEX_LOCK_PI (may block again)</text>

  <line x1="220" y1="395" x2="220" y2="415" class="cv-arrow"/>

  <rect x="30" y="415" width="380" height="30" rx="6" class="cv-box"/>
  <text x="220" y="434" class="cv-label-muted" text-anchor="middle">finally own CS again</text>

  <!-- Timeline label -->
  <text x="15" y="245" class="cv-label-muted" style="writing-mode: tb;" text-anchor="middle">time</text>

  <!-- === RIGHT COLUMN: Requeue-PI path === -->

  <!-- Step 1: capture + register -->
  <rect x="480" y="45" width="390" height="35" rx="6" class="cv-box-nspa"/>
  <text x="675" y="60" class="cv-label-green" text-anchor="middle">condvar_pi_register(condvar, pi_mutex)</text>
  <text x="675" y="73" class="cv-label-sm" text-anchor="middle">map condvar -&gt; CS LockSemaphore</text>

  <line x1="675" y1="80" x2="675" y2="95" class="cv-arrow-green"/>

  <!-- Step 2: clear CS + call unix -->
  <rect x="480" y="95" width="390" height="35" rx="6" class="cv-box-nspa"/>
  <text x="675" y="110" class="cv-label-green" text-anchor="middle">clear CS bookkeeping</text>
  <text x="675" y="123" class="cv-label-sm" text-anchor="middle">RecursionCount=0, OwningThread=0</text>

  <line x1="675" y1="130" x2="675" y2="145" class="cv-arrow-green"/>

  <!-- Step 3: unix syscall -->
  <rect x="480" y="145" width="390" height="50" rx="6" class="cv-box-kernel"/>
  <text x="675" y="162" class="cv-label" text-anchor="middle">NtNspaCondWaitPI (unix side)</text>
  <text x="675" y="177" class="cv-label-sm" text-anchor="middle">FUTEX_UNLOCK_PI(pi_mutex)</text>
  <text x="675" y="190" class="cv-label-sm" text-anchor="middle">FUTEX_WAIT_REQUEUE_PI(condvar, val, pi_mutex)</text>

  <line x1="675" y1="195" x2="675" y2="215" class="cv-arrow-green"/>

  <!-- Step 4: sleeping with requeue target -->
  <rect x="480" y="215" width="390" height="35" rx="6" class="cv-box-nspa"/>
  <text x="675" y="230" class="cv-label-green" text-anchor="middle">sleeping on condvar futex</text>
  <text x="675" y="243" class="cv-label-sm" text-anchor="middle">kernel knows requeue target = PI mutex</text>

  <line x1="675" y1="250" x2="675" y2="270" class="cv-arrow-green"/>

  <!-- Step 5: kernel requeue (safe zone) -->
  <rect x="475" y="270" width="400" height="85" rx="6" class="cv-safe-zone"/>
  <text x="675" y="290" class="cv-label-green" text-anchor="middle">KERNEL ATOMIC REQUEUE</text>
  <text x="675" y="307" class="cv-label-sm" text-anchor="middle">FUTEX_CMP_REQUEUE_PI moves waiter onto PI mutex</text>
  <text x="675" y="322" class="cv-label-sm" text-anchor="middle">Waiter owns PI mutex immediately on wake</text>
  <text x="675" y="337" class="cv-label-sm" text-anchor="middle">If contended: waiter is on PI chain (boosted)</text>
  <text x="675" y="349" class="cv-label-green" text-anchor="middle">Zero gap</text>

  <line x1="675" y1="355" x2="675" y2="375" class="cv-arrow-green"/>

  <!-- Step 6: restore -->
  <rect x="480" y="375" width="390" height="35" rx="6" class="cv-box-nspa"/>
  <text x="675" y="390" class="cv-label-green" text-anchor="middle">restore CS bookkeeping</text>
  <text x="675" y="403" class="cv-label-sm" text-anchor="middle">RecursionCount=1, OwningThread=GetCurrentThreadId()</text>

  <line x1="675" y1="410" x2="675" y2="425" class="cv-arrow-green"/>

  <rect x="480" y="425" width="390" height="30" rx="6" class="cv-box-nspa"/>
  <text x="675" y="444" class="cv-label-green" text-anchor="middle">condvar_pi_deregister, return SUCCESS</text>

  <!-- Legend -->
  <rect x="30" y="475" width="16" height="16" rx="6" class="cv-box"/>
  <text x="55" y="488" class="cv-label-muted">standard Win32</text>
  <rect x="180" y="475" width="16" height="16" rx="6" class="cv-box-nspa"/>
  <text x="205" y="488" class="cv-label-muted">NSPA PI path</text>
  <rect x="320" y="475" width="16" height="16" rx="6" class="cv-box-kernel"/>
  <text x="345" y="488" class="cv-label-muted">unix/kernel</text>
  <rect x="440" y="475" width="16" height="16" rx="6" class="cv-danger-zone"/>
  <text x="465" y="488" class="cv-label-muted">PI inversion gap</text>
  <rect x="600" y="475" width="16" height="16" rx="6" class="cv-safe-zone"/>
  <text x="625" y="488" class="cv-label-muted">atomic requeue (safe)</text>
</svg>
</div>

> **Key insight:** The standard path has a window between wake and CS reacquire where no PI protection exists. The requeue-PI path eliminates this entirely -- the kernel atomically moves the waiter from the condvar futex to the PI mutex chain, so the waiter either owns the CS immediately on wake or is on the PI chain (triggering priority boost) with zero gap.

---

## 3. Architecture

The condvar PI implementation spans the PE-unix boundary. The PE side (`dlls/ntdll/sync.c`) manages the condvar-to-mutex mapping table and CS bookkeeping. The unix side (`dlls/ntdll/unix/sync.c`) issues the actual futex syscalls. Three new Nt-level syscalls bridge the two.

### Call Flow Diagram

<div class="diagram-container">
<svg width="100%" viewBox="0 0 900 720" xmlns="http://www.w3.org/2000/svg">
  <style>
    .af-box-pe { fill: #24283b; stroke: #7aa2f7; stroke-width: 2; rx: 6; }
    .af-box-unix { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 2; rx: 6; }
    .af-box-kernel { fill: #2a1a1a; stroke: #f7768e; stroke-width: 1.5; rx: 6; }
    .af-box-map { fill: #1a1a2a; stroke: #bb9af7; stroke-width: 1.5; rx: 6; }
    .af-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .af-label-sm { fill: #c0caf5; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .af-label-green { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .af-label-red { fill: #f7768e; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .af-label-yellow { fill: #e0af68; font-size: 12px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .af-label-cyan { fill: #7dcfff; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .af-label-muted { fill: #c0caf5; font-size: 10px; font-family: 'JetBrains Mono', monospace; }
    .af-label-accent { fill: #7aa2f7; font-size: 11px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .af-arrow { stroke: #9aa5ce; stroke-width: 1.5; fill: none; }
    .af-arrow-green { stroke: #9ece6a; stroke-width: 2; fill: none; }
    .af-arrow-red { stroke: #f7768e; stroke-width: 1.5; fill: none; }
    .af-arrow-cyan { stroke: #7dcfff; stroke-width: 1.5; fill: none; }
    .af-divider { stroke: #6b7398; stroke-width: 1; stroke-dasharray: 8,4; }
    .af-boundary { fill: none; stroke: #6b7398; stroke-width: 1; stroke-dasharray: 5,3; rx: 6; }
  </style>

  <!-- Title -->
  <text x="450" y="22" class="af-label-yellow" text-anchor="middle">Win32 Condvar PI: Wait / Signal / Broadcast Flow</text>

  <!-- === WAIT PATH (left) === -->
  <rect x="15" y="35" width="420" height="665" rx="6" class="af-boundary"/>
  <text x="225" y="55" class="af-label-accent" text-anchor="middle">WAIT PATH</text>

  <!-- PE layer label -->
  <text x="30" y="75" class="af-label-muted">PE ntdll (sync.c)</text>

  <!-- Step 1: gate check -->
  <rect x="35" y="82" width="380" height="30" rx="6" class="af-box-pe"/>
  <text x="225" y="101" class="af-label" text-anchor="middle">nspa_cs_pi_active() &amp;&amp; RecursionCount == 1</text>

  <line x1="225" y1="112" x2="225" y2="127" class="af-arrow"/>

  <!-- Step 2: register -->
  <rect x="35" y="127" width="380" height="35" rx="6" class="af-box-map"/>
  <text x="225" y="143" class="af-label-cyan" text-anchor="middle">condvar_pi_register(condvar, &amp;crit-&gt;LockSemaphore)</text>
  <text x="225" y="156" class="af-label-sm" text-anchor="middle">insert into hash table (condvar addr -&gt; pi_mutex addr)</text>

  <line x1="225" y1="162" x2="225" y2="177" class="af-arrow"/>

  <!-- Step 3: clear CS -->
  <rect x="35" y="177" width="380" height="35" rx="6" class="af-box-pe"/>
  <text x="225" y="193" class="af-label" text-anchor="middle">clear CS bookkeeping</text>
  <text x="225" y="206" class="af-label-sm" text-anchor="middle">RecursionCount = 0, OwningThread = 0</text>

  <line x1="225" y1="212" x2="225" y2="227" class="af-arrow"/>

  <!-- PE-unix boundary -->
  <line x1="25" y1="232" x2="425" y2="232" class="af-divider"/>
  <text x="225" y="247" class="af-label-muted" text-anchor="middle">--- PE / unix boundary (syscall 0x00b1) ---</text>

  <!-- Unix layer label -->
  <text x="30" y="268" class="af-label-muted">Unix ntdll (unix/sync.c)</text>

  <!-- Step 4: NtNspaCondWaitPI -->
  <rect x="35" y="275" width="380" height="30" rx="6" class="af-box-unix"/>
  <text x="225" y="294" class="af-label-green" text-anchor="middle">NtNspaCondWaitPI(condvar, val, pi_mutex, timeout)</text>

  <line x1="225" y1="305" x2="225" y2="320" class="af-arrow-green"/>

  <!-- Step 5: UNLOCK_PI -->
  <rect x="35" y="320" width="380" height="30" rx="6" class="af-box-kernel"/>
  <text x="225" y="339" class="af-label-red" text-anchor="middle">futex(FUTEX_UNLOCK_PI, pi_mutex)</text>

  <line x1="225" y1="350" x2="225" y2="365" class="af-arrow-green"/>

  <!-- Step 6: WAIT_REQUEUE_PI -->
  <rect x="35" y="365" width="380" height="35" rx="6" class="af-box-kernel"/>
  <text x="225" y="381" class="af-label-red" text-anchor="middle">futex(FUTEX_WAIT_REQUEUE_PI,</text>
  <text x="225" y="394" class="af-label-red" text-anchor="middle">condvar, val, abstime, pi_mutex)</text>

  <line x1="225" y1="400" x2="225" y2="415" class="af-arrow-green"/>

  <!-- Step 7: sleeping -->
  <rect x="35" y="415" width="380" height="25" rx="6" class="af-box-unix"/>
  <text x="225" y="432" class="af-label-muted" text-anchor="middle">... sleeping (kernel holds requeue target) ...</text>

  <line x1="225" y1="440" x2="225" y2="455" class="af-arrow-green"/>

  <!-- Step 8: woken, own PI mutex -->
  <rect x="35" y="455" width="380" height="30" rx="6" class="af-box-kernel"/>
  <text x="225" y="474" class="af-label-green" text-anchor="middle">kernel requeues onto PI mutex -- own it on wake</text>

  <line x1="225" y1="485" x2="225" y2="500" class="af-arrow-green"/>

  <!-- EAGAIN fallback -->
  <rect x="35" y="500" width="380" height="35" rx="6" class="af-box-unix"/>
  <text x="225" y="516" class="af-label" text-anchor="middle">EAGAIN? (value changed = signal raced)</text>
  <text x="225" y="529" class="af-label-green" text-anchor="middle">FUTEX_LOCK_PI(pi_mutex) -- still own it</text>

  <!-- unix-PE boundary back -->
  <line x1="25" y1="550" x2="425" y2="550" class="af-divider"/>
  <text x="225" y="565" class="af-label-muted" text-anchor="middle">--- return to PE ---</text>

  <!-- Step 9: restore CS -->
  <rect x="35" y="575" width="380" height="35" rx="6" class="af-box-pe"/>
  <text x="225" y="591" class="af-label" text-anchor="middle">restore CS bookkeeping</text>
  <text x="225" y="604" class="af-label-sm" text-anchor="middle">RecursionCount = 1, OwningThread = tid</text>

  <line x1="225" y1="610" x2="225" y2="625" class="af-arrow"/>

  <!-- Step 10: deregister -->
  <rect x="35" y="625" width="380" height="30" rx="6" class="af-box-map"/>
  <text x="225" y="644" class="af-label-cyan" text-anchor="middle">condvar_pi_deregister(condvar)</text>

  <line x1="225" y1="655" x2="225" y2="670" class="af-arrow"/>

  <rect x="35" y="670" width="380" height="22" rx="6" class="af-box-pe"/>
  <text x="225" y="685" class="af-label" text-anchor="middle">return STATUS_SUCCESS</text>


  <!-- === SIGNAL PATH (right) === -->
  <rect x="465" y="35" width="420" height="360" rx="6" class="af-boundary"/>
  <text x="675" y="55" class="af-label-accent" text-anchor="middle">SIGNAL PATH</text>

  <text x="480" y="75" class="af-label-muted">PE ntdll (sync.c)</text>

  <!-- Step 1: lookup -->
  <rect x="485" y="82" width="380" height="35" rx="6" class="af-box-map"/>
  <text x="675" y="98" class="af-label-cyan" text-anchor="middle">condvar_pi_lookup(condvar)</text>
  <text x="675" y="111" class="af-label-sm" text-anchor="middle">hash table lookup -&gt; pi_mutex (or NULL = no PI waiters)</text>

  <line x1="675" y1="117" x2="675" y2="132" class="af-arrow"/>

  <!-- PE-unix boundary -->
  <line x1="475" y1="137" x2="875" y2="137" class="af-divider"/>
  <text x="675" y="152" class="af-label-muted" text-anchor="middle">--- PE / unix boundary (syscall 0x00b2) ---</text>

  <text x="480" y="172" class="af-label-muted">Unix ntdll (unix/sync.c)</text>

  <!-- Step 2: NtNspaCondSignalPI -->
  <rect x="485" y="179" width="380" height="30" rx="6" class="af-box-unix"/>
  <text x="675" y="198" class="af-label-green" text-anchor="middle">NtNspaCondSignalPI(condvar, pi_mutex)</text>

  <line x1="675" y1="209" x2="675" y2="224" class="af-arrow-green"/>

  <!-- Step 3: increment condvar -->
  <rect x="485" y="224" width="380" height="30" rx="6" class="af-box-unix"/>
  <text x="675" y="243" class="af-label-green" text-anchor="middle">InterlockedIncrement(condvar) -- 1 per signal</text>

  <line x1="675" y1="254" x2="675" y2="269" class="af-arrow-green"/>

  <!-- Step 4: CMP_REQUEUE_PI -->
  <rect x="485" y="269" width="380" height="35" rx="6" class="af-box-kernel"/>
  <text x="675" y="285" class="af-label-red" text-anchor="middle">futex(FUTEX_CMP_REQUEUE_PI,</text>
  <text x="675" y="298" class="af-label-red" text-anchor="middle">condvar, wake=1, requeue=0, pi_mutex, val)</text>

  <line x1="675" y1="304" x2="675" y2="319" class="af-arrow-green"/>

  <!-- Step 5: EAGAIN retry -->
  <rect x="485" y="319" width="380" height="35" rx="6" class="af-box-unix"/>
  <text x="675" y="335" class="af-label" text-anchor="middle">EAGAIN? re-read val, retry CMP_REQUEUE_PI</text>
  <text x="675" y="348" class="af-label-green" text-anchor="middle">kernel wakes 1 waiter onto PI mutex</text>

  <!-- === BROADCAST PATH (right, lower) === -->
  <rect x="465" y="415" width="420" height="190" rx="6" class="af-boundary"/>
  <text x="675" y="435" class="af-label-accent" text-anchor="middle">BROADCAST PATH</text>

  <text x="480" y="455" class="af-label-muted">PE ntdll (sync.c)</text>

  <rect x="485" y="462" width="380" height="30" rx="6" class="af-box-map"/>
  <text x="675" y="481" class="af-label-cyan" text-anchor="middle">condvar_pi_lookup(condvar) -&gt; pi_mutex</text>

  <line x1="675" y1="492" x2="675" y2="507" class="af-arrow"/>

  <text x="480" y="520" class="af-label-muted">Unix ntdll (unix/sync.c)</text>

  <rect x="485" y="527" width="380" height="30" rx="6" class="af-box-kernel"/>
  <text x="675" y="546" class="af-label-red" text-anchor="middle">FUTEX_CMP_REQUEUE_PI(condvar, 1, INT_MAX, pi_mutex)</text>

  <line x1="675" y1="557" x2="675" y2="572" class="af-arrow-green"/>

  <rect x="485" y="572" width="380" height="25" rx="6" class="af-box-unix"/>
  <text x="675" y="589" class="af-label-green" text-anchor="middle">wake 1, requeue all remaining onto PI mutex</text>

  <!-- Legend -->
  <rect x="35" y="700" width="14" height="14" rx="6" class="af-box-pe"/>
  <text x="57" y="712" class="af-label-muted">PE ntdll</text>
  <rect x="140" y="700" width="14" height="14" rx="6" class="af-box-unix"/>
  <text x="162" y="712" class="af-label-muted">unix ntdll</text>
  <rect x="250" y="700" width="14" height="14" rx="6" class="af-box-kernel"/>
  <text x="272" y="712" class="af-label-muted">kernel futex</text>
  <rect x="370" y="700" width="14" height="14" rx="6" class="af-box-map"/>
  <text x="392" y="712" class="af-label-muted">mapping table</text>
</svg>
</div>

---

## 4. Condvar-to-Mutex Mapping Table

The Win32 `WakeConditionVariable` API only takes the condvar address -- unlike POSIX `pthread_cond_signal` which has access to the mutex through the `pthread_cond_wait` call. But `FUTEX_CMP_REQUEUE_PI` requires *both* the condvar futex address and the PI mutex address. The signal side needs a way to find the PI mutex from only the condvar address.

### Solution: Open-Addressed Hash Table

A 64-entry open-addressed hash table with tombstone deletion and refcounting, shared by all threads in the process. The table maps condvar addresses to PI mutex addresses.

#### Operations

- **Register** (on wait entry, under spinlock): Hash condvar address, linear probe for matching or empty slot. If found, increment refcount. If new, insert with refcount=1. If table full, silently fall back to non-PI path.
- **Deregister** (on wait exit, under spinlock): Find matching entry, decrement refcount. On refcount reaching 0, replace entry with `CONDVAR_PI_TOMBSTONE` (preserves probe chains for other entries).
- **Lookup** (on signal, under spinlock): Linear probe from hash. Skip tombstones, stop at NULL. Return pi_mutex address or NULL (meaning no PI waiters -- fall back to normal signal path).

#### Why Tombstones

Open-addressing with linear probing cannot simply clear a slot on deletion -- it would break probe chains for entries that were inserted past the deleted slot. The standard solution is tombstone deletion: a deleted slot is marked with a sentinel value (`CONDVAR_PI_TOMBSTONE`) that lookup skips over but insertion can reuse.

#### Design Choices

- **64 entries** -- more than enough for typical Win32 applications (most have <10 active condvars)
- **Spinlock** -- not a PI mutex. The critical section is tiny (a few pointer comparisons), and the spinlock is only held during table operations, never across syscalls
- **Refcounting** -- multiple threads can wait on the same condvar simultaneously. The mapping entry stays alive until the last waiter deregisters

    struct condvar_pi_entry {
        const volatile void *condvar_addr;   /* key (or TOMBSTONE) */
        LONG                *pi_mutex_addr;  /* value */
        LONG                 refcount;       /* waiters using this entry */
    };

---

## 5. Syscall Interface

Three new Nt-level syscalls cross the PE-unix boundary. These are NSPA-specific extensions to the NT syscall table, numbered in the 0x00b1-0x00b3 range.

| Syscall | Number | Parameters | Description |
| --- | --- | --- | --- |
| `NtNspaCondWaitPI` | 0x00b1 | `condvar_futex, condvar_val, pi_mutex, timeout` | Wait on condvar with requeue-PI. Unlocks PI mutex, sleeps on condvar, gets requeued onto PI mutex on signal. |
| `NtNspaCondSignalPI` | 0x00b2 | `condvar_futex, pi_mutex` | Signal one waiter. Increments condvar, then `FUTEX_CMP_REQUEUE_PI` to wake 1, requeue 0. |
| `NtNspaCondBroadcastPI` | 0x00b3 | `condvar_futex, pi_mutex` | Broadcast to all waiters. Same as signal but wake 1, requeue INT_MAX. |

### Contract

`NtNspaCondWaitPI` **ALWAYS** returns with the PI mutex owned by the caller, regardless of how it returns:

- **Normal wake:** kernel requeued waiter onto PI mutex, waiter owns it
- **EAGAIN:** value mismatch (signal raced) -- falls through to `FUTEX_LOCK_PI` to acquire the mutex explicitly
- **Timeout:** `FUTEX_LOCK_PI` to reacquire, then return `STATUS_TIMEOUT`

This "always own on return" contract matches what the PE side expects: it clears CS bookkeeping before the syscall and restores it after, so the unix side must guarantee the PI mutex is held on every return path.

### Fallback

If `NtNspaCondWaitPI` returns `STATUS_NOT_SUPPORTED` (kernel too old, or futex ops unavailable), the PE side falls through to the standard Win32 condvar path with normal `RtlLeaveCriticalSection` / `RtlWaitOnAddress` / `RtlEnterCriticalSection`. The CS-PI leave/enter still provides PI protection during those calls -- the gap just isn't eliminated.

---

## 6. Correctness Properties

### No Lost Wakeups

`EAGAIN` from `FUTEX_WAIT_REQUEUE_PI` means the condvar value changed between our read and the futex call -- a signal raced with us. This is treated as "we were signaled" rather than an error. The waiter falls through to `FUTEX_LOCK_PI` to acquire the PI mutex, then returns `STATUS_SUCCESS`. No wakeup is lost.

### No Over-Increment

The signal path increments the condvar counter exactly once, then issues `FUTEX_CMP_REQUEUE_PI` with the post-increment value. On `EAGAIN` (another signal raced), it re-reads the current value and retries the `CMP_REQUEUE_PI` without incrementing again. This avoids the counter drifting upward and causing spurious wakeups.

### No Orphaned Waiters

The mapping table uses refcounting. Every `condvar_pi_register` increments the refcount, every `condvar_pi_deregister` decrements it. The entry is only cleared (tombstoned) when the refcount reaches zero. This ensures the signal path can always find the PI mutex address for active waiters, even if some waiters have already returned.

### Tombstone Probing

Open-addressing deletion uses `CONDVAR_PI_TOMBSTONE` sentinel values. Lookup probes skip tombstones (they are not the entry we want, but entries beyond them might be). Probe chains terminate only at a true NULL slot. Insertion can reuse tombstone slots, keeping table density manageable.

### Graceful Fallback

If the unix side detects that the kernel does not support `FUTEX_WAIT_REQUEUE_PI` (returns `ENOSYS`), it returns `STATUS_NOT_SUPPORTED`. The PE side catches this and falls through to the standard Win32 condvar path. This means Wine-NSPA can run on kernels without requeue-PI support -- the RT guarantees just degrade gracefully to the CS-PI-only path (PI on enter/leave, but gap between wake and enter).

---

## 7. Relationship to Existing PI Infrastructure

Win32 condvar PI is the fourth PI mechanism in Wine-NSPA. Together, these four paths provide priority inheritance coverage across the entire Wine synchronization surface:

| Path | Mechanism | Scope |
| --- | --- | --- |
| **CS-PI** | `FUTEX_LOCK_PI` on `LockSemaphore` | Win32 CriticalSection enter/leave |
| **NTSync PI** | Kernel ntsync driver with priority-ordered wakeup | Win32 Mutex / Semaphore / Event |
| **pi_cond requeue-PI** | `FUTEX_WAIT_REQUEUE_PI` in librtpi | Unix-side condvars (audio, gstreamer) |
| **Win32 condvar PI** | `FUTEX_WAIT_REQUEUE_PI` for `RtlSleepConditionVariableCS` | Win32 `SleepConditionVariableCS` |

> **SRW gap:** SRW-backed condvars (`RtlSleepConditionVariableSRW`) are *not* covered by this work. SRW locks have no PI mechanism -- this is an unsolved problem even in the Linux kernel (reader-writer locks with priority inheritance require tracking all readers, which is prohibitively expensive). Applications using `SleepConditionVariableSRW` in RT paths should switch to `SleepConditionVariableCS` for PI coverage.

### How the Paths Layer

- **CS-PI** provides the foundation: any `EnterCriticalSection` / `LeaveCriticalSection` gets PI protection via `FUTEX_LOCK_PI` on the `LockSemaphore` field.
- **Win32 condvar PI** builds on CS-PI: it reuses the same `LockSemaphore` PI mutex as the requeue target. The CS-PI mutex IS the condvar-PI mutex.
- **pi_cond requeue-PI** covers the unix side -- Wine's internal condition variables (used by the audio stack, gstreamer, etc.) that never cross the PE boundary.
- **NTSync PI** covers the kernel-level Win32 sync objects (Mutex, Semaphore, Event) that go through the ntsync driver.

---

## 8. Test Results

The `condvar-pi` test validates the requeue-PI path under contention: an RT waiter (`THREAD_PRIORITY_TIME_CRITICAL`, mapped to `SCHED_FIFO`) waits on a condvar while a normal-priority signaler sends signals and 4 CPU-bound load threads create scheduling pressure.

### Test Configuration

- 500 iterations per run
- RT waiter: `THREAD_PRIORITY_TIME_CRITICAL` (`SCHED_FIFO` at `NSPA_RT_PRIO`)
- Signaler: normal priority (`SCHED_OTHER`)
- Load threads: 4 CPU-bound spinners

### Latency Results

| Mode | avg wait | max wait | min wait |
| --- | --- | --- | --- |
| With PI (`NSPA_RT_PRIO=80`) | 129 us | **152 us** | 124 us |
| Without PI | 100 us | **263 us** | 29 us |

> **Key finding:** PI tightens the distribution -- max wait drops from 263 to 152 us (42% lower worst-case). The average is slightly higher with PI due to requeue overhead (extra kernel work for the atomic requeue), but the tail latency is dramatically better. For RT audio, worst-case matters more than average: a 263 us spike at the wrong moment causes a buffer underrun, while a consistent 129 us does not.

### Distribution Characteristics

- **With PI:** Tight distribution (124-152 us range = 28 us spread). The requeue-PI mechanism ensures deterministic wake-to-own timing.
- **Without PI:** Wide distribution (29-263 us range = 234 us spread). The 29 us minimum shows uncontended fast path, but the 263 us maximum shows the priority inversion gap under load.

### Full Suite Results

24 PASS / 0 FAIL / 0 TIMEOUT (12 tests x 2 modes in the current PE
matrix), no regressions after the later `dispatcher-burst` addition.

---

## 9. Files Changed

| File | Role |
| --- | --- |
| `dlls/ntdll/sync.c` | PE-side condvar PI implementation: mapping table (`condvar_pi_register` / `condvar_pi_deregister` / `condvar_pi_lookup`), modified `RtlSleepConditionVariableCS`, `RtlWakeConditionVariable`, `RtlWakeAllConditionVariable` |
| `dlls/ntdll/unix/sync.c` | Unix-side futex operations: `NtNspaCondWaitPI` (`FUTEX_UNLOCK_PI` + `FUTEX_WAIT_REQUEUE_PI` + `EAGAIN` fallback), `NtNspaCondSignalPI` (`FUTEX_CMP_REQUEUE_PI`), `NtNspaCondBroadcastPI` |
| `dlls/ntdll/ntsyscalls.h` | Syscall table entries: 0x00b1 (`NtNspaCondWaitPI`), 0x00b2 (`NtNspaCondSignalPI`), 0x00b3 (`NtNspaCondBroadcastPI`) for both i386 and x86_64 |
| `include/winternl.h` | Function declarations for the three new `NtNspaCond*PI` syscalls |
| `programs/nspa_rt_test/main.c` | Validation test: `cmd_condvar_pi` -- RT waiter + normal signaler + 4 load threads, 500 iterations, latency measurement |

---

Wine-NSPA Win32 Condvar PI Reference | Public 11.x documentation
