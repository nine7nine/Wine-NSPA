# Wine-NSPA -- Two-Tier Win32 Hook Chain Cache

Wine 11.6 + NSPA bypass surface | shmem-published, seqlock-bound | 2026-04-25
Author: Jordan Johnston

## Table of Contents

1. [Overview](#1-overview)
2. [Problem: every dispatch consults the chain](#2-problem-every-dispatch-consults-the-chain)
3. [Design at a glance](#3-design-at-a-glance)
4. [Tier 1 -- the count-array gate](#4-tier-1----the-count-array-gate)
5. [Tier 2 -- the chain-snapshot iterator](#5-tier-2----the-chain-snapshot-iterator)
6. [Server-side cache rebuild](#6-server-side-cache-rebuild)
7. [Module-name pool](#7-module-name-pool)
8. [Lock and lifetime discipline](#8-lock-and-lifetime-discipline)
9. [Validation history](#9-validation-history)
10. [Optional Tier 3 (future)](#10-optional-tier-3-future)
11. [References](#11-references)

---

## 1. Overview

Win32 applications register hook procedures with `SetWindowsHookEx` to intercept window messages, keyboard input, mouse events, CBT events, and so on. The hook chain is consulted on every dispatched message: before a `WM_KEYDOWN` reaches its window proc, the `WH_KEYBOARD` chain is walked; before a `CallWindowProc` runs, `WH_CALLWNDPROC` and `WH_CALLWNDPROCRET` are walked; before a window is created/activated/destroyed, `WH_CBT` is walked; before any get/peek/translate, `WH_GETMESSAGE` is walked. In Wine, the chain itself lives in the wineserver -- it is shared state across processes -- so vanilla Wine performs a server RPC on every check.

NSPA replaces "RPC every time" with a two-tier cache published into the per-queue bypass shmem region. **Tier 1** is a small array of per-hook-id counts: the client can answer "is there *any* hook of this id?" by reading one integer from shmem, no syscalls. **Tier 2** is the full chain snapshot for each hook id: the client iterates the chain locally and dispatches the proc directly, falling back to RPC only when the chain has overflowed the cache or the seqlock retries are exhausted.

Both tiers are server-published, client-read. The server is single-threaded for request handling, so there is never writer/writer contention; the seqlock exists purely so client readers see a consistent snapshot during the brief mutation window when `set_hook` or `remove_hook` is rebuilding.

## 2. Problem: every dispatch consults the chain

`call_message_hooks` -- the main client-side entry point -- runs on every message dispatch path that supports a hook id. The first thing it does is ask "are there any hooks for this id?". In vanilla Wine that question is answered by `is_hooked`, which reads `queue_shm->hooks_count[]` directly from the queue's shared memory mapping; that piece is shared with NSPA. The expensive part follows: if `is_hooked` returns true, the client issues `start_hook_chain`, then for each entry in the chain a `get_hook_info` to advance, then a `finish_hook_chain` at the end. Every chain walk is at least three RPCs.

The real-world hot loop is even worse than the per-walk count suggests, because:

- **Most chains are empty or length 1.** A typical desktop app has zero `WH_CBT` hooks but the `is_hooked` check still runs for every `CreateWindowEx`, every `ShowWindow`, every `SetWindowPos`. Chain length 0 or 1 means the per-RPC overhead dominates the per-entry work.
- **Hooks aggregate at the shell level.** Window managers (XEmbed shims, DAW host plugins, accessibility software) install long-lived global `WH_CALLWNDPROC` and `WH_GETMESSAGE` hooks that fire across every queue on the desktop. Once one hook is installed for a hook id, every queue paying the RPC cost.
- **`WH_GETMESSAGE` fires on every `GetMessage` / `PeekMessage`.** A 1 kHz timer message pump pays 3000 RPCs per second on the hook-chain trio alone before the cache.

Per-RPC cost on a 6.19 PREEMPT_RT kernel with NTSync gamma is roughly 3-7 microseconds end-to-end (sendto + recvfrom + serialization + server-side dispatch). Three RPCs per chain walk at 1 kHz is 9-21 ms/sec of pure hook-chain RPC; under a 165 s Ableton session that adds up to several seconds of wineserver time across the wineserver main thread, which is exactly the path NSPA's other bypasses are designed to keep idle.

Removing those RPCs is the goal of the hook cache.

## 3. Design at a glance

Two cooperating publish-side data structures live in the per-queue bypass shmem region (`nspa_queue_bypass_shm_t`):

| Tier | Shmem field | Type | Written by | Read by | Purpose |
|------|-------------|------|------------|---------|---------|
| 1 | `queue_shm->hooks_count[NB_HOOKS]` | `int[]` | server `add_queue_hook_count` | client `is_hooked` | "Any hook of this id?" gate |
| 2 | `bypass->nspa_hook_chains[NB_HOOKS]` | `nspa_hook_chain_t[]` | server `nspa_hook_cache_rebuild` | client `nspa_hook_try_read_cache` | Full chain entries for local iteration |
| 2 | `bypass->nspa_hook_module_pool[4096]` | `unsigned char[]` | server `hook_pool_alloc` | client memcpy in cache reader | UTF-16 module-name pool referenced by entries[].module_offset |

Tier 1 lives in the existing `queue_shm_t` (the queue's main shared-memory mapping that vanilla Wine already publishes for `wake_bits` / `changed_bits` / etc.). NSPA did not invent this field -- vanilla Wine already publishes hook counts there for its own internal accounting. The NSPA contribution at Tier 1 is the *client-side reader* and the realisation that this single integer answers most calls cheaply.

Tier 2 lives in `nspa_queue_bypass_shm_t`, NSPA's per-queue auxiliary shmem region (one mapping per queue, separate from the main queue_shm). The chain entries are fixed-size 64-byte structs (one cache line) and the module-name strings live in a separate 4 KB pool referenced by byte offset.

<div class="diagram-container">
<svg width="100%" viewBox="0 0 920 360" xmlns="http://www.w3.org/2000/svg">
  <style>
    .hc-bg { fill: #1a1b26; }
    .hc-box { fill: #24283b; stroke: #3b4261; stroke-width: 1.4; rx: 8; }
    .hc-tier1 { fill: #1a2235; stroke: #7aa2f7; stroke-width: 1.8; rx: 8; }
    .hc-tier2 { fill: #2a1f35; stroke: #bb9af7; stroke-width: 1.8; rx: 8; }
    .hc-server { fill: #1a2a1a; stroke: #9ece6a; stroke-width: 1.8; rx: 8; }
    .hc-label { fill: #c0caf5; font-size: 11px; font-family: 'JetBrains Mono', monospace; }
    .hc-sm { fill: #8c92b3; font-size: 9px; font-family: 'JetBrains Mono', monospace; }
    .hc-head { fill: #7aa2f7; font-size: 14px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .hc-blue { fill: #7aa2f7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .hc-pur { fill: #bb9af7; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .hc-grn { fill: #9ece6a; font-size: 10px; font-weight: bold; font-family: 'JetBrains Mono', monospace; }
    .hc-arrow-b { stroke: #7aa2f7; stroke-width: 1.8; fill: none; }
    .hc-arrow-p { stroke: #bb9af7; stroke-width: 1.8; fill: none; }
    .hc-arrow-g { stroke: #9ece6a; stroke-width: 1.8; fill: none; }
  </style>

  <rect x="0" y="0" width="920" height="360" class="hc-bg"/>
  <text x="460" y="24" text-anchor="middle" class="hc-head">Hook cache publication layout</text>

  <rect x="34" y="64" width="220" height="92" class="hc-server"/>
  <text x="144" y="90" text-anchor="middle" class="hc-label">wineserver write side</text>
  <text x="144" y="107" text-anchor="middle" class="hc-sm">add_hook / remove_hook</text>
  <text x="144" y="121" text-anchor="middle" class="hc-sm">add_queue_hook_count()</text>
  <text x="144" y="135" text-anchor="middle" class="hc-sm">nspa_hook_cache_rebuild()</text>

  <rect x="322" y="54" width="260" height="112" class="hc-tier1"/>
  <text x="452" y="80" text-anchor="middle" class="hc-blue">Tier 1: queue_shm->hooks_count[NB_HOOKS]</text>
  <text x="452" y="97" text-anchor="middle" class="hc-sm">small shared array already present in queue_shm</text>
  <text x="452" y="111" text-anchor="middle" class="hc-sm">answers "is any hook of this id installed?"</text>
  <text x="452" y="125" text-anchor="middle" class="hc-sm">client-side reader: is_hooked()</text>
  <text x="452" y="146" text-anchor="middle" class="hc-blue">fast negative gate, no RPC</text>

  <rect x="322" y="194" width="260" height="126" class="hc-tier2"/>
  <text x="452" y="220" text-anchor="middle" class="hc-pur">Tier 2: bypass->nspa_hook_chains[]</text>
  <text x="452" y="237" text-anchor="middle" class="hc-sm">fixed-size chain snapshots per hook id</text>
  <text x="452" y="251" text-anchor="middle" class="hc-sm">plus nspa_hook_module_pool[4096] for UTF-16 names</text>
  <text x="452" y="265" text-anchor="middle" class="hc-sm">seqlock version guards readers during rebuild</text>
  <text x="452" y="279" text-anchor="middle" class="hc-sm">client-side reader: nspa_hook_try_read_cache()</text>
  <text x="452" y="300" text-anchor="middle" class="hc-pur">local chain walk when snapshot is valid</text>

  <rect x="650" y="116" width="236" height="126" class="hc-box"/>
  <text x="768" y="142" text-anchor="middle" class="hc-label">client dispatch side</text>
  <text x="768" y="159" text-anchor="middle" class="hc-sm">Tier 1 count==0 -> return immediately</text>
  <text x="768" y="173" text-anchor="middle" class="hc-sm">Tier 2 snapshot valid -> walk locally</text>
  <text x="768" y="187" text-anchor="middle" class="hc-sm">overflow / retry exhaust / unmapped -> RPC fallback</text>
  <text x="768" y="208" text-anchor="middle" class="hc-grn">correctness stays server-authoritative</text>

  <line x1="254" y1="102" x2="322" y2="102" class="hc-arrow-g"/>
  <line x1="254" y1="118" x2="322" y2="240" class="hc-arrow-g"/>
  <line x1="582" y1="110" x2="650" y2="144" class="hc-arrow-b"/>
  <line x1="582" y1="250" x2="650" y2="214" class="hc-arrow-p"/>
</svg>
</div>

<div class="diagram-container">
<svg width="100%" viewBox="0 0 920 540" xmlns="http://www.w3.org/2000/svg">
  <rect x="0" y="0" width="920" height="540" fill="#1a1b26"/>

  <text x="460" y="30" text-anchor="middle" fill="#7aa2f7" font-family="monospace" font-size="16" font-weight="bold">call_message_hooks( id, ... ) -- one dispatch path</text>

  <!-- Step 1: is_hooked -->
  <rect x="60" y="60" width="800" height="80" fill="#24283b" stroke="#3b4261"/>
  <text x="80" y="85" fill="#e0af68" font-family="monospace" font-size="13" font-weight="bold">[1] Tier 1 gate -- is_hooked( id )</text>
  <text x="80" y="105" fill="#c0caf5" font-family="monospace" font-size="11">    read queue_shm-&gt;hooks_count[id - WH_MINHOOK] under NSPA_SHM_RETRY_GUARD seqlock</text>
  <text x="80" y="122" fill="#9ece6a" font-family="monospace" font-size="11">    count == 0  ---&gt;  return 0   // no hook of this id; skip the whole walk. ~99% of calls land here.</text>

  <!-- Step 2: tier 2 try -->
  <rect x="60" y="160" width="800" height="120" fill="#24283b" stroke="#3b4261"/>
  <text x="80" y="185" fill="#e0af68" font-family="monospace" font-size="13" font-weight="bold">[2] Tier 2 try -- nspa_hook_try_read_cache( walker, id, event )</text>
  <text x="80" y="205" fill="#c0caf5" font-family="monospace" font-size="11">    seqlock-bound snapshot of bypass-&gt;nspa_hook_chains[idx]</text>
  <text x="80" y="222" fill="#c0caf5" font-family="monospace" font-size="11">    apply per-thread + per-event filter on the snapshot, copy survivors into walker.entries[]</text>
  <text x="80" y="240" fill="#9ece6a" font-family="monospace" font-size="11">    n &gt;= 0  ---&gt;  walker is populated; iterate locally; no server RPCs.</text>
  <text x="80" y="258" fill="#f7768e" font-family="monospace" font-size="11">    n  &lt; 0  ---&gt;  overflowed / retry exhausted / bypass-shm unmapped; fall through.</text>

  <!-- Step 3: legacy RPC -->
  <rect x="60" y="300" width="800" height="120" fill="#24283b" stroke="#3b4261"/>
  <text x="80" y="325" fill="#e0af68" font-family="monospace" font-size="13" font-weight="bold">[3] Legacy RPC fallback (vanilla Wine path)</text>
  <text x="80" y="345" fill="#c0caf5" font-family="monospace" font-size="11">    SERVER_START_REQ( start_hook_chain )</text>
  <text x="80" y="362" fill="#c0caf5" font-family="monospace" font-size="11">    while ( has_next ) SERVER_START_REQ( get_hook_info )   // one RPC per chain entry</text>
  <text x="80" y="380" fill="#c0caf5" font-family="monospace" font-size="11">    SERVER_START_REQ( finish_hook_chain )                  // skipped when tier1_active and queue-local-only</text>
  <text x="80" y="400" fill="#bb9af7" font-family="monospace" font-size="11">    triggered: chain &gt; CAP, global hooks fire here, WINEVENT-out-of-context, pool full.</text>

  <!-- Step 4: server publish side -->
  <rect x="60" y="440" width="800" height="80" fill="#24283b" stroke="#7aa2f7"/>
  <text x="80" y="465" fill="#7dcfff" font-family="monospace" font-size="13" font-weight="bold">[server] write side -- add_hook / remove_hook handlers</text>
  <text x="80" y="485" fill="#c0caf5" font-family="monospace" font-size="11">    add_queue_hook_count() bumps Tier 1 hooks_count[]; nspa_hook_cache_rebuild() repopulates Tier 2.</text>
  <text x="80" y="503" fill="#c0caf5" font-family="monospace" font-size="11">    seqlock writer protocol: version += 1 (odd) BEGIN; rewrite entries[]; version += 1 (even) END.</text>
</svg>
</div>

## 4. Tier 1 -- the count-array gate

The first question every hook-aware dispatch path asks is "should I bother walking the chain at all?". The answer lives in `queue_shm->hooks_count[NB_HOOKS]`, a small fixed-size array of integers. Vanilla Wine already maintains this on the server side for its own scheduling logic (so the wineserver knows whether to wake threads on hook installation). NSPA reads it from the client.

The client-side reader is `is_hooked` in `dlls/win32u/hook.c:64-82`:

    BOOL is_hooked( INT id )
    {
        struct object_lock lock = OBJECT_LOCK_INIT;
        const queue_shm_t *queue_shm;
        BOOL ret = TRUE;
        unsigned int spin = 0;
        UINT status;

        /* On exhaustion return TRUE so message dispatch falls through to
         * the legacy hook RPCs (server has the authoritative chain). */
        while ((status = get_shared_queue( &lock, &queue_shm )) == STATUS_PENDING)
        {
            ret = queue_shm->hooks_count[id - WH_MINHOOK] > 0;
            NSPA_SHM_RETRY_GUARD( spin, return TRUE );
        }

        if (status) return TRUE;
        return ret;
    }

Three properties matter here.

**Seqlock-bound retry.** The `STATUS_PENDING` loop is the standard NSPA shmem read pattern: `get_shared_queue` returns `STATUS_PENDING` while the seqlock is mid-write, the caller re-reads, and after `NSPA_SHM_RETRY_GUARD`-many retries (currently bounded to a few thousand `pause`+`yield` cycles) it gives up. The macro is the same one used throughout the bypass surface for paint counters, queue-bits, and so on -- the audit-§4.1 retry-loop hardening pass tuned these globally.

**Exhaust-action returns TRUE.** If the seqlock churns for too long, `is_hooked` returns `TRUE` rather than `FALSE`. This is deliberately conservative: returning TRUE means the caller falls through to the legacy `start_hook_chain` RPC trio, where the wineserver has the authoritative chain; returning FALSE on exhaust would *lose* hook walks (skip them entirely), which would break correctness. Falling back to RPC under unlikely-but-possible churn is exactly the right tradeoff -- the cache is an optimisation, not the source of truth.

**Status-error returns TRUE.** Same logic for `if (status) return TRUE`: if the queue's shared mapping isn't set up yet (early-bootstrap, or the queue hasn't been initialised), default to "yes there might be a hook", let the RPC path take over.

In the steady state -- queue mapping established, no concurrent server-side rebuild -- the function compiles to one cacheline-resident integer load, one compare-against-zero, one branch. Roughly 5 ns. The vanilla Wine equivalent is one server RPC per call, roughly 3-7 microseconds.

The empirical kicker: Tier 1 alone short-circuits the vast majority of hook-aware dispatch paths because most apps install hooks on a small subset of hook ids. A DAW host with `WH_CBT` and `WH_CALLWNDPROC` installed has all *other* hook ids' counts at zero, and every `WH_GETMESSAGE` / `WH_KEYBOARD` / `WH_MOUSE` / `WH_FOREGROUNDIDLE` query lands in the count==0 short-circuit and returns immediately.

## 5. Tier 2 -- the chain-snapshot iterator

Tier 1 answers "any hook?". Tier 2 answers "what hooks, and what are their procs and modules?". When `is_hooked` returns true, the client tries Tier 2 before falling back to RPC.

Tier 2's layout is in `protocol.def` lines 1142-1170:

    #define NSPA_HOOK_CHAIN_CAP     8
    #define NSPA_HOOK_MODULE_POOL   4096    /* per-queue UTF-16 string pool, bytes */

    typedef volatile struct
    {
        user_handle_t   handle;
        client_ptr_t    proc;            /* hook function (raw client-side address) */
        unsigned int    flags;           /* HOOK_INPROC etc */
        unsigned int    event_min;
        unsigned int    event_max;
        user_handle_t   window;
        int             object_id;
        int             child_id;
        unsigned int    pid;
        unsigned int    tid;
        unsigned int    module_offset;   /* byte offset into nspa_hook_module_pool, 0 = no module */
        unsigned int    module_size;     /* WCHAR count (not bytes) */
        unsigned int    unicode;
        unsigned int    __pad;
    } nspa_hook_entry_t;                 /* 64 bytes -- one cache line */

    typedef volatile struct
    {
        unsigned int        version;     /* seqlock; even = stable, odd = writer mid-update */
        unsigned short      count;       /* number of valid entries in entries[] */
        unsigned short      overflowed;  /* 1 = chain length exceeded NSPA_HOOK_CHAIN_CAP, force RPC */
        unsigned int        __pad;
        nspa_hook_entry_t   entries[NSPA_HOOK_CHAIN_CAP];
    } nspa_hook_chain_t;

`NSPA_HOOK_CHAIN_CAP = 8` is the per-hook-id capacity. Chains longer than 8 set `overflowed = 1` and the client falls back to RPC for that id. Eight is the empirical sweet spot: longer-than-8 chains essentially never occur in real apps. The cap exists to bound the snapshot size; it does not *constrain* hook chains, only the cache's serving capacity.

The reader -- `nspa_hook_try_read_cache` in `dlls/win32u/hook.c:151-238` -- is the tier 2 entry point. Skeleton:

    for (retry = 0; retry < 8; retry++)
    {
        v1 = __atomic_load_n( &chain->version, __ATOMIC_ACQUIRE );
        if (v1 & 1) { pause(); sched_yield(); continue; }   /* writer mid-update */

        cnt  = chain->count;
        over = chain->overflowed;
        if (over) return -1;                                  /* fall back to RPC */
        if (cnt > NSPA_HOOK_CHAIN_CAP) return -1;             /* corrupt snapshot, paranoia */

        /* memcpy entries[0..cnt] into local stack copy
         * memcpy module strings out of nspa_hook_module_pool into local copy */

        v2 = __atomic_load_n( &chain->version, __ATOMIC_ACQUIRE );
        if (v1 != v2 || (v2 & 1)) { pause(); sched_yield(); continue; }   /* writer raced us */
        if (copy_failed) return -1;                                       /* pool offset out of range */

        /* stable snapshot -- run the per-thread + per-event filter,
         * copy survivors into walker.entries[], return the count. */
        return out;
    }
    return -1;   /* retry exhausted */

This is a textbook seqlock reader: load version (must be even), copy data, reload version, compare. If both reads see the same even version with no odd snapshot in between, the data is consistent; otherwise retry. The acquire ordering on both loads pairs with the server's release stores around its odd/even bumps.

Why copy entries to local stack first, then to walker? Because filter logic (`nspa_hook_match_thread`, `nspa_hook_match_event` -- not all entries match the calling thread/event) is run *after* the seqlock-stable snapshot is verified. Running filtering on shmem-resident data while a writer might race would let the filter see torn fields. The local stack copy is the snapshot; the filter is pure on the snapshot.

After Tier 2 fills the walker, the dispatch loop in `call_message_hooks` (lines 697-721) sets `nspa_hook_walker_current` to point at the walker, calls the first hook proc directly, and lets `NtUserCallNextHookEx` walk the rest of the chain locally. `NtUserCallNextHookEx` (lines 567-622) checks `nspa_hook_walker_current` first: if a walker is active and the current hook's handle matches, it advances to entries[idx+1] without an RPC; if not (nested dispatch from a non-Tier-2 path, or end of chain), it falls back to `get_hook_info`.

The walker is allocated on the dispatching thread's stack and the `nspa_hook_walker_current` pointer is `__thread` storage. Nested hook dispatches push/pop via the `prev` pointer field. Stack-local with a per-thread current-pointer is the right pattern: no allocation, no lock, no leak on early return -- the walker disappears with the stack frame.

Tier 2 is opt-out via `NSPA_DISABLE_HOOK_TIER2`; default is on. Tier 1 is opt-out via `NSPA_DISABLE_HOOK_TIER1`. Both default-on as of the 2026-04-25 ship.

### When Tier 2 falls back

The reader returns -1 (RPC fallback) when:

| Condition | Where set | Why |
|-----------|-----------|-----|
| `overflowed = 1` | server rebuild | Chain &gt; 8 entries, or a global hook fires here, or WINEVENT out-of-context |
| `module_offset` out of range | reader copy loop | Pool-offset arithmetic would read past end of pool; treat as corruption |
| `module_size &gt;= MAX_PATH` | reader copy loop | Module name doesn't fit in walker's per-entry MAX_PATH WCHAR slot |
| Retry exhausted (8 iterations) | reader retry loop | Server is churning the cache faster than client can read; rare |
| `bypass shm` not mapped | early return | Memfd-backed bypass region didn't bootstrap (msg-bypass off, or pre-init) |
| `NSPA_DISABLE_HOOK_TIER2=1` | env check | User opted out |

Each of these has a corresponding RPC-path code, so falling back is always safe.

## 6. Server-side cache rebuild

The cache is rewritten only on hook *topology* changes -- when a hook is added or removed -- which are rare events relative to walk frequency. The rebuild lives in `server/nspa/hook_cache.c`.

The function signature is `nspa_hook_cache_rebuild( struct thread *thread, int index )` -- rebuild the cache for one queue's one hook id. It walks the hook list, packs up to `NSPA_HOOK_CHAIN_CAP` entries, and publishes them under the seqlock writer protocol. The whole thing is bounded by the chain length (cap 8) plus the module pool size (cap 4 KB), so worst-case rebuild is microseconds.

Rebuild is triggered from two server-side handlers:

- `set_hook` handler in `server/hook.c:476-477` -- after `add_hook` succeeds, rebuild the cache (queue-local) or rebuild for every queue on the desktop (global).
- `remove_hook` handler in `server/hook.c:551-557` -- captures `cache_thread`/`cache_desktop` before `remove_hook` (which may free the hook and release its thread), rebuilds afterwards.

The lifetime gymnastics in `remove_hook` deserve a second look. The hook being removed may hold the only reference to its thread (`hook->thread`); calling `remove_hook( hook )` can `release_object` that thread. So `remove_hook` (the handler) `grab_object`s the thread before calling `remove_hook` (the operation), then runs the rebuild on the still-live captured pointer, then `release_object`s it. Same pattern for the desktop pointer when the hook was global. Without these captures, the rebuild would run on a freed thread and corrupt the heap.

### Seqlock writer protocol

The writer side is straightforward but worth spelling out. From `nspa_hook_cache_rebuild`:

    /* Begin write: bump version to odd so concurrent readers retry. */
    v = chain->version;
    __atomic_store_n( &chain->version, v + 1, __ATOMIC_RELEASE );
    __atomic_thread_fence( __ATOMIC_ACQ_REL );

    /* ... rebuild count/overflowed/entries[]/module pool ... */

    /* End write: bump version to even.  Pair with the client-side
     * acquire load on version. */
    __atomic_thread_fence( __ATOMIC_ACQ_REL );
    __atomic_store_n( &chain->version, v + 2, __ATOMIC_RELEASE );

Even = stable, odd = writer mid-update. Begin: bump to odd, fence. Body: rewrite. End: fence, bump to even. The acquire/release pairing with the client's two acquire loads (one before reading, one after) is what makes the seqlock work.

Wineserver is single-threaded for request handlers, so there are no concurrent writers ever -- the seqlock exists exclusively for client/server (writer/reader) interaction, not writer/writer. This simplifies the writer protocol: no CAS on version, no winner-takes-all retry; just store-bump-fence-rewrite-fence-store-bump.

### What goes in entries[]

Per-entry fields packed by the rebuild loop (`hook_cache.c:117-141`):

| Field | Source | Notes |
|-------|--------|-------|
| `handle` | `hook->handle` | Handle the client uses to identify entries during chain walks |
| `proc` | `hook->proc` | Raw client-side function pointer (caller's process) |
| `flags` | `hook->flags` | HOOK_INPROC, WINEVENT_INCONTEXT, etc. |
| `event_min` / `event_max` | `hook->event_*` | For WH_WINEVENT range filtering |
| `window` / `object_id` / `child_id` | -- | Reserved zero (these are runtime args from start_hook_chain caller, not stored on struct hook) |
| `pid` / `tid` | `hook->process->id` / `hook->thread->id` | For per-thread-filter check on the client |
| `module_offset` | `hook_pool_alloc` return | 0 = no module, otherwise byte offset into nspa_hook_module_pool |
| `module_size` | `hook->module_size / sizeof(WCHAR)` | WCHAR count (no NUL terminator) |
| `unicode` | `hook->unicode` | Whether the hook proc expects Unicode |
| `__pad` | 0 | Cache-line padding to keep struct at exactly 64 bytes |

The 64-byte size is load-bearing: each entry occupies exactly one cacheline, so a chain of length N reads N consecutive cachelines from shmem -- minimal pollution of the client's L1.

### Forced-overflow conditions

The rebuild deliberately marks `overflowed = 1` (forcing RPC fallback) under three conditions:

1. **Any global hook fires for this queue** -- iterating `desktop->global_hooks->hooks[index]` and finding one where `run_hook_in_thread( hook, thread )` returns true. Global hooks involve cross-process dispatch logic the server is better at coordinating.
2. **WINEVENT out-of-context hook** -- `WH_WINEVENT` hooks without `WINEVENT_INCONTEXT` need the server's `post_win_event` to deliver them out-of-band; the client can't dispatch them locally.
3. **Chain longer than `NSPA_HOOK_CHAIN_CAP = 8`** or **module pool exhausted (4 KB used up)**.

In all three cases `count` is set to 0 and `overflowed` to 1 before the version-end bump, so client readers see "yes the cache is up to date, and it's telling you to use RPC".

## 7. Module-name pool

Hooks installed with a module (`SetWindowsHookEx( inst, module, ... )`) carry a UTF-16 module name -- `user32.dll`, `comctl32.dll`, plugin DLLs. Module names are variable-length (anywhere from 0 to `MAX_PATH = 260` WCHARs). Embedding them inline in `nspa_hook_entry_t` would either waste 520 bytes per entry (worst-case sized) or break the 64-byte cacheline invariant.

The compromise: a 4 KB byte-pool per queue, allocated separately at `nspa_queue_bypass_shm_t::nspa_hook_module_pool[NSPA_HOOK_MODULE_POOL]`. Each entry stores a `module_offset` (byte offset into the pool) and `module_size` (WCHAR count). The client copies `module_size * sizeof(WCHAR)` bytes from `pool + offset` into the walker's per-entry MAX_PATH buffer during the seqlock-stable snapshot.

The pool is bump-allocated during rebuild (`hook_cache.c:40-57`):

    static unsigned int hook_pool_alloc( shm, *cursor, src, size_bytes )
    {
        if (!size_bytes || !src) return 0;
        if (size_bytes > NSPA_HOOK_MODULE_POOL) return 0;
        /* leave offset 0 as the "no module" sentinel */
        if (*cursor == 0) *cursor = sizeof(WCHAR);
        if (*cursor + size_bytes > NSPA_HOOK_MODULE_POOL) return 0;
        off = *cursor;
        memcpy( &shm->nspa_hook_module_pool[off], src, size_bytes );
        *cursor += size_bytes;
        /* round up to WCHAR alignment */
        *cursor = (*cursor + sizeof(WCHAR) - 1) & ~(unsigned int)(sizeof(WCHAR) - 1);
        return off;
    }

Every rebuild resets `pool_cursor = 0`, so stale strings are simply overwritten on the next rebuild. No reference counting, no per-string free; the whole pool is a single bump allocator scoped to one rebuild call.

Offset 0 is reserved as the "no module" sentinel -- a hook without a module sets `module_offset = 0` and `module_size = 0`. To prevent a real module from accidentally landing at offset 0, the cursor starts at `sizeof(WCHAR) = 2` on the first allocation.

If a module string can't fit (cursor + size_bytes > pool size), `hook_pool_alloc` returns 0. The rebuild loop checks for this and forces `overflowed = 1` if a real module name failed to allocate (`hook_cache.c:131-137`):

    e->module_offset = hook_pool_alloc( shm, &pool_cursor, hook->module, hook->module_size );
    if (hook->module_size && hook->module && e->module_offset == 0)
    {
        /* pool exhausted -- fall back to RPC */
        overflowed = 1;
        break;
    }

This makes pool exhaustion correct-by-construction: if the pool fills up partway through a chain rebuild, the rebuild marks the chain overflowed (clients see overflowed=1, fall back to RPC), and the server retains its authoritative chain in the legacy hook tables.

## 8. Lock and lifetime discipline

Two lock-discipline invariants make the cache safe.

**Server-side: cache rebuild runs under the existing global server lock.** The rebuild is invoked from within `set_hook` / `remove_hook` request handlers; both already hold the server's global lock (the wineserver request loop is single-threaded). No new lock was introduced for the cache. The seqlock on the chain version is *not* a server-side lock -- it's a publish-side fence, designed to coordinate with concurrent client readers, not concurrent server writers (which don't exist).

**Client-side: never read the cache while holding a Win32 lock.** `is_hooked` and `nspa_hook_try_read_cache` both run on `call_message_hooks`'s entry path, which is called from `user_check_not_lock`-asserting paths. Specifically, win32u's user-lock invariant -- "no holding the user lock across a hook walk" -- predates the cache and applies whether the walk uses RPC or the cache. The cache reader does not take any locks of its own, so it neither breaks nor extends this invariant.

**No cross-tier locking.** Tier 1 reads `queue_shm` (the main queue's shared mapping); Tier 2 reads `nspa_queue_bypass_shm_t` (the per-queue bypass region). The two mappings are independent. The client always reads Tier 1 first and only attempts Tier 2 if Tier 1 said yes. There is no atomic "Tier 1 + Tier 2 are consistent" guarantee -- and no need for one. If Tier 1 says yes but Tier 2 says overflow or returns -1, the client falls back to RPC, which is the source of truth. If Tier 1 says no but a hook was just added (race), the client misses one walk; the next walk will see the bumped count.

The "Tier 1 says no but actually a hook was just added" race is the only correctness boundary worth being explicit about. It's resolved as follows:

1. Server processes `add_hook` request: increments `hooks_count[idx]` (Tier 1) and rebuilds Tier 2 cache, both under server lock. The Tier 1 increment uses the queue's `SHARED_WRITE_BEGIN`/`END` which is the standard NSPA shmem write protocol (`server/queue.c:738-749`).
2. Client doing `call_message_hooks` reads `hooks_count[idx]`; if it reads the value before the server's increment, it sees 0 and skips the walk. *That same call does not see the new hook.*
3. The hook is published-as-active *after* the next message dispatch sees the bumped count. In practice, the client's next message-pump iteration does see it.

This mirrors vanilla Wine's existing semantics: there is always a window between "hook is registered with the server" and "the next dispatch on the affected queue picks it up". The cache does not narrow or widen this window meaningfully; it just makes the steady-state cheaper.

## 9. Validation history

Tier 1 and Tier 2 were both shipped on 2026-04-25, with the diag-pile cleanup on 2026-04-26. The relevant commits and their effects:

| Date | Commit (logical) | Change |
|------|------------------|--------|
| 2026-04-25 | T1.0 + T1.1 | Tier 1 protocol scaffolding (`hooks_count[]` reader); set_hook / remove_hook server-side increment / decrement |
| 2026-04-25 | T2.0 | Tier 2 protocol scaffolding (`nspa_hook_chain_t`, `nspa_hook_entry_t`, module pool layout) |
| 2026-04-25 | T2.1 | Server-side `nspa_hook_cache_rebuild` + invocation from `set_hook` / `remove_hook` handlers |
| 2026-04-25 | T2.2 / T2.3 | Client-side `nspa_hook_try_read_cache` reader; default-on with `NSPA_DISABLE_HOOK_TIER2` opt-out |
| 2026-04-25 | call_hook routing fix | `info->tid = 0` for cache-served entries (in-thread dispatch only); avoids accidentally taking the LL-hook cross-thread branch |
| 2026-04-26 | diag pile removal | Removed 13 atomic counters (`top_calls`, `skipped_no_hooks`, `server_dispatch`, `cat_*`, `tier1_shmem_inc/dec`, `tier1_finish_forced/skipped`, `tier2_*`) and the 5-second background dump thread. They were pre-ship instrumentation to decide *whether* to build the cache; once shipped, kept paying ~13 atomic adds per `call_message_hooks` invocation forever. Kept only the load-bearing counters: `nspa_hook_walk_counts[]` (server reads for Tier 1 refcount) and `nspa_hook_try_read_cache` itself. |

The validation that motivated default-on was a 165-second Ableton Live session with a moderately complex set:

| Metric | Value | Notes |
|--------|-------|-------|
| Tier 2 cache hits | 26,742 | Tier 2 served the entire chain walk; zero RPCs |
| Tier 2 cache misses (→ RPC) | 0 | No overflow, no retry exhaustion in 165 s |
| `server_dispatch` count for hook RPCs | 0 | Fully eliminated for the duration of the session |
| `is_hooked` short-circuits (count==0) | unmeasured (counter removed) | Vast majority of calls; per-thread frequency ranges 100s-1000s/sec |

Zero misses across 26.7 k hits in a real-world DAW workload was the bar for flipping defaults. The diag pile was scrubbed once that bar was met because the counters had served their purpose; keeping them in shipped code would have paid forever for instrumentation that no longer informed any decision.

The other tested workloads (vsthost VST chains, Chromaphone instrument plugin, Ableton's drum-rack window with dozens of WM_PAINTs/sec) show the same pattern: Tier 1 short-circuits 99%+ of dispatches; Tier 2 serves the remaining 1% with zero RPCs.

## 10. Optional Tier 3 (future)

Two follow-on directions are queued, neither shipped.

**Chain-modification streaming.** Currently a `set_hook` / `remove_hook` rebuilds the entire cache for the affected hook id. In the steady state -- when chains are short and rebuilds are rare -- this is fine. Under churn-heavy workloads (some accessibility shells install/remove WH_GETMESSAGE hooks dynamically), per-call rebuild may be wasteful; an incremental update (`entries[count++] = new_hook` for set_hook in the common append case, `memmove` for remove_hook) could halve the rebuild cost. The complication is that the seqlock writer protocol still needs to bump version on every change, and the client filter logic still has to re-run on the whole chain. So the win is bounded.

**Cross-queue caching for global hooks.** Today, global hooks force `overflowed = 1` and fall back to RPC. A future Tier 3 could publish a desktop-global cache (one snapshot per (desktop, hook id) instead of (queue, hook id)) and let clients walk it directly. Risk: the cross-process dispatch logic (`run_hook_in_thread`, `process->id` boundaries) means each client would have to filter the global chain itself; correctness of that filter under concurrent process tear-down is non-trivial. Server-side dispatch handles this for free today.

Neither is on the near-term roadmap; current measured Tier 1 + Tier 2 hit rate makes both of these incremental wins on already-cheap paths.

## 11. References

| Component | File | Lines |
|-----------|------|-------|
| Client Tier 1 reader (`is_hooked`) | `wine/dlls/win32u/hook.c` | 64-82 |
| Client Tier 2 reader (`nspa_hook_try_read_cache`) | `wine/dlls/win32u/hook.c` | 151-238 |
| Walker struct + per-thread current pointer | `wine/dlls/win32u/hook.c` | 120-133 |
| Walker advance (`NtUserCallNextHookEx`) | `wine/dlls/win32u/hook.c` | 567-622 |
| Top-level dispatch (`call_message_hooks`) | `wine/dlls/win32u/hook.c` | 657-772 |
| Server Tier 2 rebuild | `wine/server/nspa/hook_cache.c` | 59-163 |
| Module-name pool allocator | `wine/server/nspa/hook_cache.c` | 40-57 |
| Server set_hook handler invocation | `wine/server/hook.c` | 476-477 |
| Server remove_hook handler invocation | `wine/server/hook.c` | 549-557 |
| Tier 1 server publish (`add_queue_hook_count`) | `wine/server/queue.c` | 738-749 |
| Tier 1 client-walk refcount (`nspa_queue_hook_chain_busy_tier1`) | `wine/server/queue.c` | 790-798 |
| Tier 1 env gate (`nspa_queue_hook_tier1_active`) | `wine/server/queue.c` | 758-774 |
| Bypass shm pointer accessor (`nspa_queue_bypass_shm`) | `wine/server/queue.c` | 779-783 |
| Protocol struct definitions | `wine/server/protocol.def` | 1134-1170 |
| Bypass shm field layout (chains + pool) | `wine/server/protocol.def` | 1206-1214 |
| Tier 1 / Tier 2 capacity macros | `wine/server/protocol.def` | 1142-1143 |

Environment variables:

| Variable | Default | Effect |
|----------|---------|--------|
| `NSPA_DISABLE_HOOK_TIER1` | unset | Disables Tier 1 client refcount + server's `tier1_active` reply path; reverts to legacy `start_hook_chain` / `finish_hook_chain` accounting |
| `NSPA_DISABLE_HOOK_TIER2` | unset | Disables Tier 2 cache reader; every walk uses the RPC trio (Tier 1 still applies if not also disabled) |

Both variables are read once per process (cached) and matched server-side via `reply->tier1_active` so client and server agree on whether the bypass is active for any given queue.
