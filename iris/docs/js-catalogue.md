# How JavaScript uses threads and shared state (2025-2026), with side-by-side test ideas for iris-lean

> Kept from the research that preceded `iris/`. Paths starting `<scratchpad>/iris/` or `iris/`
> name the research scratchpad, which no longer exists: the evidence they cite is in `research/`
> (see its `README.md`), and the code is now in `iris/` itself (`../README.md`).

This is a catalogue. It lists every way a web page or a Node program runs code in parallel or shares
state. For each one it gives the shared resource, how access to it is synchronised, the usual patterns
and bugs, and a test that runs a plain JavaScript version next to an iris-lean-verified version.
Each entry is also tagged with what iris-lean can honestly prove about it (§2).

Everything here was written on 2026-11-20. The probes behind the numbers are in
`<scratchpad>/iris/catalogue/`
(`probes/` for Node, `browser/` for Chromium). The machine is a 4-vCPU cloud VM with Node v22.23.5
(V8 12.4) and HeadlessChrome 157.0.8103.78 (Playwright 1.63, `/opt/pw-browsers/chromium-1243`).
**Read every time below as a ratio, not an absolute.** These are CI-machine numbers and need
re-measuring on the reference Mac. The Mac is also ARM, whose hardware memory model is weaker than
x86's TSO, and that matters for the plain-access tests (§1.7, B12, C2).

---

## 0. Twelve things to keep in mind

1. **Iris does not remove locks; the algorithm does.** Lock-free JavaScript (a CAS counter, an SPSC
   ring, a triple buffer, a seqlock) can be written today without Lean. What iris-lean adds is a
   machine-checked proof that the lock-free version keeps its invariant in every interleaving
   allowed by HeapLang's sequentially consistent semantics. That proof is what gives the confidence
   to drop the mutex. The side-by-side tests should therefore compare three things: the idiomatic
   JS version (usually a lock or messages), the same lock-free algorithm hand-written in JS, and the
   verified HeapLang version translated to JS or wasm.
2. **The big wins measured here come from not sharing.** On this VM, with 4 workers, the counter
   numbers were:
   - one contended `Atomics.add`: 9-32 increments/us;
   - per-worker shards: 7,800-8,500/us;
   - "count locally, publish once": about 2,300/us.

   Likewise, an SPSC ring that publishes its index every 64 items was about 16x faster than one
   that publishes on every item (83 vs 5 items/us). Both wins come from ownership: which thread
   owns which memory, and when ownership passes. That is exactly what separation logic writes down.
   Iris's best story is "proven-safe ownership transfer", not "faster atomics".
3. **"Lock-free" is not automatically faster.** With 4 workers, a contended CAS counter (5-31/us)
   was no better than a futex mutex (12-13/us). A ticket lock collapsed to about 0 under
   oversubscription (6 workers on 4 vCPUs), in both runs. The iris-lean proofs of SpinLock and
   TicketLock say nothing about any of this: they cover safety, not progress or performance.
4. **Liveness is out of reach.** Iris's WP is partial correctness. Lost wakeups, deadlock, livelock,
   starvation and convoys (§5) cannot be ruled out by an iris-lean proof. The user's own repo has
   one: QED64 "kicks the mailbox" every second to recover from a lost wakeup
   (`/home/user/leanui/qed64/README.md` lines 60-61, "HARDENING #52"). The total WP in
   `Iris/Iris/ProgramLogic/TotalWeakestPre.lean` proves termination but has no fairness, so it
   cannot handle spin loops.
5. **The proofs assume SC; plain JS and wasm accesses are weaker.** JS `Atomics.*` operations are
   SeqCst. Plain TypedArray accesses are "Unordered": racing on them is not UB (unlike C11), but it
   gives weak results. Since Watt et al.'s repair (PLDI 2020), JS guarantees SC-DRF: a program whose
   SC executions have no data race on plain accesses behaves SC. So an HeapLang proof applies to a
   translation **only if** every access that can race is emitted as `Atomics.*`. Iris HeapLang
   cannot prove that: it has no race detection. §7 proposes a fix in the style of λRust.
6. **HeapLang is not SAB memory.** Its ints are unbounded (JS Int32 wraps). Its heap stores
   closures, pairs and sums (a SAB stores bytes). It never reuses an address: `free` leaves the
   location in the heap as `none` (`Semantics.lean` lines 408-411), and `allocN` needs locations
   that were never allocated (lines 403-407). So ABA cannot happen in HeapLang the way it does in a
   SAB free list (C6).
7. **Atomics.wait/notify has no HeapLang counterpart.** For safety it is sound to model `wait` as a
   no-op: correct code re-checks its condition, and a spurious return only adds interleavings.
   That proves nothing about blocking or wakeups.
8. **Browser-specific rules shape the design.**
   - `Atomics.wait` throws on the window's main thread. In Chrome 157 the message is "TypeError:
     Atomics.wait cannot be called in this context" (probe).
   - Only dedicated and shared worker agents may block. Worklets (AudioWorklet included), service
     workers and windows may not.
   - SharedArrayBuffer needs cross-origin isolation. Without it the `SharedArrayBuffer` global is
     undefined in Chrome 157. A shared `WebAssembly.Memory` can still be created, but posting it to
     a Worker throws `DataCloneError: SharedArrayBuffer transfer requires self.crossOriginIsolated`
     (probe).
   - LeanUI chose single-threaded wasm for exactly this reason (`/home/user/leanui/docs/TOOLCHAIN.md`,
     "Why single-threaded").
9. **Message passing is the default in JS, and it is ownership transfer.** Transferring an
   ArrayBuffer is O(1) and detaches the sender's buffer: 0.06 ms vs 157 ms to clone 64 MiB round
   trip (probe). That is separation logic's "send gives up ℓ ↦ v". But HeapLang has no channels.
   `postMessage` can only enter a proof as a trusted, axiomatised spec.
10. **Host APIs only enter as axioms.** IndexedDB transactions, Web Locks, OPFS handles,
    BroadcastChannel and SharedWorker can be stated as specs, for example as an instance of
    iris-lean's generic `Lock` interface (`Iris/Iris/HeapLang/Lib/Lock.lean`) or as a logically
    atomic update (`Iris/Iris/ProgramLogic/Atomic.lean`). Proofs about client code are real; the
    browser's side is trusted.
11. **Stress tests and proofs catch different bugs.** Use mutation tests (B25):
    - The injected "publish before write" ring bug was caught by a checksum in 2,504 and 8,796 of
      2,000,000 items in two runs. It is probabilistic, and likely to differ on ARM.
    - An Iris proof of the mutated ring cannot go through. That is deterministic, but only for
      safety and only under SC.
    - A dropped `notify` is caught by neither, only by a timeout.
12. **Which iris-lean pieces exist today.** HeapLang has `cmpXchg`, `xchg`, `faa`, `fork`, `allocN`,
    `free` and prophecies (`newProph`/`resolve`). On top of that there are invariants, cancellable
    invariants, non-atomic invariants, ghost maps and vars, tokens, later credits, and logically
    atomic triples. Already verified: Counter (a CAS loop), SpinLock, TicketLock, RwSpinLock,
    Spawn/join, Par, a Lock and RwLock interface, and Array helpers (`Iris/Iris/HeapLang/Lib/`, 2,824
    lines). Not there: queues, stacks, barriers, seqlocks, Chase-Lev, RCU, hazard pointers, and any
    weak-memory logic (iRC11, Cosmo and Compass are Coq-only).

---

## 1. What the probes measured (this VM; ratios only)

Reproduce with `cd …/scratchpad/iris/catalogue/probes && node counter.mjs 300 && node snapshot.mjs 300 16 && node ring.mjs && node pingpong.mjs && node transfer.mjs && node plainflag.mjs`,
and for Chromium `PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node ../browser/serve-probe.mjs && node ../browser/clone-probe.mjs`.
Raw outputs: `probes/*.out`, `browser/probe.out`, `browser/clone.out`.

### 1.1 Features

| Feature | Node 22.23.5 | Chrome 157, isolated | Chrome 157, not isolated |
|---|---|---|---|
| `SharedArrayBuffer` | yes | yes | **undefined** |
| `Atomics.wait` on the main thread | allowed (`timed-out`) | **throws TypeError** | no SAB |
| `Atomics.wait` in a dedicated worker | allowed | allowed | no SAB |
| `Atomics.waitAsync` | yes, but a pending one **does not keep a Worker alive** (§1.5) | yes | yes |
| `Atomics.pause` | **absent** | yes | yes |
| growable SAB (`maxByteLength`, `grow`) | yes | yes | no |
| shared `WebAssembly.Memory` | yes; validates `i32.atomic.rmw.add` | posts to a Worker | created, but **`postMessage` throws DataCloneError** |
| `navigator.locks` (Web Locks) | **absent** (added in a later Node line, experimental, `worker_threads.locks`) | yes; two requests ran in1,out1,in2,out2 | yes |
| `SharedWorker`, `AudioWorkletNode`, `CSS.paintWorklet` | n/a | yes, yes, yes | yes |
| `CSS.animationWorklet` | n/a | **undefined** (never shipped) | undefined |
| `OffscreenCanvas` / `transferControlToOffscreen` | n/a | yes; afterwards `getContext` throws InvalidStateError | same |
| transferable `ReadableStream` | n/a | yes | yes |
| OPFS `createSyncAccessHandle` (worker) | n/a | yes; a 2nd handle throws NoModificationAllowedError; two `readwrite-unsafe` handles allowed | same |
| `Float16Array`, `scheduler.postTask`/`yield` | no, n/a | yes | yes |

### 1.2 Shared counter

Workers increment one counter for a fixed time. The table gives increments/us for all workers
together, from two runs (300 ms and 500 ms). Source: `probes/counter.mjs`, outputs
`counter.out` and `counter.run2.out`.

| Way | W=1 | W=2 | W=4 | W=6 (oversubscribed) | Notes |
|---|---|---|---|---|---|
| plain `a[0]=a[0]+1` | 2,000-2,150* | 2,270-3,110* | 1,910-5,400* | | **lost 43-49% (W=2) and 67-71% (W=4)** of increments |
| `Atomics.add` | 98-102 | 15-21 | 9-32 | | correct |
| CAS loop (= iris-lean `Counter.incr`) | 49-55 | 9-38 | 5-31 | | correct |
| spin lock (= `SpinLock`) + plain increment | 47 | 7-24 | 2.6-4.1 (fairness 0.17-0.49) | 1.4-4.2 | correct, unfair |
| ticket lock (= `TicketLock`) | 36-37 | 4-8 | 0.04-2.8 | **≈0 in both runs** | fair until preempted, then convoy |
| futex mutex (Drepper, wait/notify) | 44-45 | 12-14 | 12-13 (fairness 0.74-0.86) | 13-13.5 | degrades gracefully |
| per-worker shard, padded to 64 B | 1,460-2,130* | 3,780-4,280* | 7,800-8,500* | | correct; scales |
| per-worker shard, one cache line | 2,170* | 3,580-4,230* | 5,290-5,470* | | **false sharing: about 0.65x of padded** |
| count locally, one `Atomics.add` at the end | 573-584 | 1,016-1,162 | 2,280-2,370 | | correct; scales |

\* About 1.4 cycles per increment, so V8 is optimising the plain loop (store sinking or
unrolling). The JS memory model allows this for unordered accesses. Fairness is the fewest
increments of any worker divided by the most. The variance between runs is large: noisy VM.

### 1.3 Snapshots of a 16-word record (one writer, one reader, 300 ms)

Source: `probes/snapshot.mjs`, output `snapshot.out`.

| Way | Writer updates/us | Reader snapshots/us | Torn snapshots accepted | Reader retries |
|---|---|---|---|---|
| no synchronisation | 3.90 | 3.76 | **9.34%** | 0 |
| seqlock, plain data accesses | 2.79 | 1.01 | 0 (on x86; not guaranteed by the JS model) | 6.9 M |
| seqlock, `Atomics` data accesses | 0.86 | 0.10 | 0 | 12.0 M |
| triple buffer (ownership passed with `Atomics.exchange`) | **7.75** | **7.86** | 0 | 0 (wait-free) |
| futex mutex | 4.37 | 1.79 | 0 | 0 |

### 1.4 Moving 2,000,000 ints from one Worker to another

Source: `probes/ring.mjs`, output `ring.out`.

| Way | Items/us | Correct? |
|---|---|---|
| SPSC ring, `Atomics` on head and tail on every item, consumer spins | 4.8-5.3 | yes |
| SPSC ring, cached indices, publishes every 64 items | **82.9** | yes |
| SPSC ring, both sides `Atomics.wait` when full or empty | 2.6-2.8 | yes |
| **failure injection:** publish the tail before writing the slot | 6.1-6.5 | **no: 2,504 and 8,796 items read stale** |
| one `postMessage` per item (N=200k) | 0.54-0.71 | yes |
| `postMessage` of 4,096-item batches, transferred | 56-71 | yes |

### 1.5 Round-trip latency between two Workers (us)

Source: `probes/pingpong.mjs`, output `pingpong.out`.

| Way | us |
|---|---|
| `postMessage` on a MessageChannel | 33-36 |
| `Atomics.wait`/`notify` | 27-28 |
| `Atomics.waitAsync`/`notify` | **The Worker exits mid-run** ("unsettled top-level await"): a pending `waitAsync` is not an event-loop handle in Node. 36 us with a keep-alive `setInterval`. |
| spinning on `Atomics.load` | 0.42-0.63 (burns two cores) |

### 1.6 Handing a buffer to a Worker and back (ms, median of 7)

Source: `probes/transfer.mjs`, output `transfer.out`.

| MiB | clone | transfer | SAB plus a flag |
|---|---|---|---|
| 1 | 1.81 | 0.085 | 0.039 |
| 16 | 18.1 | 0.057 | 0.040 |
| 64 | 156.8 | 0.065 | 0.039 |

After a transfer, `buf.byteLength === 0` and `buf.detached === true` (probe).

### 1.7 Polling a flag with a plain read

Source: `probes/plainflag.mjs`, output `plainflag.out`. V8 did **not** hoist the load: the plain
poll saw the flag, after 241 M polls (vs 24.7 M with `Atomics.load`, about 10x cheaper per poll).
The JS model would still allow hoisting, and another engine or a future V8 may do it. Do not
depend on it.

---

## 2. What iris-lean can prove: the labels used below

- **[P] Provable today** in iris-lean HeapLang, under SC, for safety and functional correctness.
  An existing library proof may already cover it.
- **[P+] Provable in principle, but needs new iris-lean work.** Prophecies, logically atomic specs
  and ghost state are present, but the proof is research-grade. Coq Iris has proofs to port.
- **[W] Needs a weak-memory logic.** This covers plain or relaxed accesses that race on purpose
  (seqlock with plain data, publication through plain stores). iris-lean has no weak-memory logic.
- **[L] A liveness or progress property:** deadlock-freedom, no lost wakeup, starvation-freedom,
  lock-freedom, bounded latency. Not provable with Iris WP.
- **[A] A host API.** The browser or Node implements it, and it can only be a trusted axiom (a spec
  with no proof).
- **[T] A translation trust gap.** The proof is about HeapLang. The running code is a translation
  of it (§7), and nothing verifies the translation.

---

## 3. The mechanisms

Each entry gives:

- **Shared:** the shared resource.
- **Sync:** how access to it is synchronised.
- **Patterns:** the canonical patterns.
- **Bugs:** the typical bugs.
- **Test:** the proposed side-by-side test, defined in §4 (B).
- **Iris:** what iris-lean can say about it.

### A1. Dedicated Web Workers (`new Worker(url, {type: "module"})`)
- Each Worker has its own isolate, heap and event loop. No JS object is shared.
- **Shared:** messages, SharedArrayBuffers, storage (IndexedDB, OPFS, Cache), Web Locks, the network.
- **Sync:** `postMessage` (per-port FIFO, asynchronous, no backpressure), Atomics on a SAB, and
  `Atomics.wait` (allowed here).
- **Uses:** compute offload; Emscripten pthreads (each pthread is a Worker); OffscreenCanvas
  rendering; OPFS sync I/O; LeanUI's async race lanes; QED64 (`/home/user/leanui/qed64/lane/qed64.worker.js`).
- **Patterns:** RPC with request ids (Comlink style), worker pools (piscina-like), fork-join over
  chunks, pipelines.
- **Bugs:**
  - Unbounded message queues.
  - Responses matched to the wrong request.
  - Use after transfer, which is silent: a view over a detached buffer has length 0 and reads
    `undefined`.
  - Startup cost (tens of ms).
  - `worker.terminate()` in the middle of a critical section leaves a SAB lock held forever. Web
    Locks are released on context death; SAB mutexes are not.
- **Test:** B10, B17, B16, and the kill test in B2.
- **Iris:** fork = Worker [P]. Termination mid-section cannot be modelled: HeapLang threads never
  die, and the waiters blocking forever is [L].

### A2. SharedWorker
- There is one instance per origin, URL and name, shared by every tab. Clients connect through a
  `MessagePort` in `onconnect`.
- **Shared:** the worker's in-memory state, which is a natural actor. A single event loop gives no
  data races, but state can still interleave across `await`.
- **Availability:** Chrome desktop, Firefox and Safari. Chrome for Android ran an origin trial
  (140-144), and the Chrome 148 beta (April 2026) re-enabled it while the Android lifecycle issues
  are investigated. Stable status is unclear.
- **Patterns:**
  - one WebSocket or one DB connection per origin;
  - cross-tab cache;
  - the single-writer actor.
- **Bugs:**
  - There is no "port closed" event, so clients leak unless heartbeats are used.
  - State is lost when the last tab closes.
  - Mobile kills it in the background.
- **Test:** B18, the cross-tab leader and actor.
- **Iris:** the actor is a sequential loop over a queue [P]. Port FIFO and delivery are [A].

### A3. Service Workers
- A per-scope network proxy for fetch, push and background sync. It is event-driven and killed
  when idle, so in-memory state is not durable.
- **Shared:** Cache Storage, IndexedDB, and `clients`.
- It cannot block: its agent's [[CanBlock]] is false. It is not in the page's agent cluster, so no
  SAB can be shared with it.
- **Sync:** `event.waitUntil`, `skipWaiting` and `clients.claim`.
- **Bugs:**
  - Version skew (an old page talking to a new SW).
  - Concurrent `fetch` events interleaving across `await` on an in-memory cache.
  - Install and activate races.
  - Global state assumed to survive termination.
- **Workaround for headers:** `coi-serviceworker` injects COOP/COEP on hosts that cannot set them.
- **Test:** B24, the async check-then-act test.
- **Iris:** mostly [A]. The async interleavings can be modelled as forked HeapLang threads [P],
  which over-approximates JS run-to-completion.

### A4. Worklets
- **AudioWorklet.** `process()` runs on the real-time audio thread for every 128-frame quantum
  (2.67 ms at 48 kHz). It must not block, allocate or wait for GC. `Atomics.wait` is not allowed
  (worklet agents cannot block). Its `port` is a MessagePort, which allocates.
  - Canonical design: an SPSC ring buffer in a SAB (ringbuf.js; Emscripten Wasm Audio Worklets).
    The producer in a Worker may `Atomics.wait`; the consumer in the worklet only polls.
  - Bugs: underruns (glitches), priority inversion (the RT thread waits on something a
    low-priority thread holds), GC pauses from `port.postMessage`.
  - **Test:** B8 (audio variant).
  - **Iris:** SPSC ring [P]; deadline [L]; RT scheduling [A].
- **PaintWorklet (CSS Painting API).** Chromium only (probe: present). It is stateless by design:
  the engine may run several global scopes in parallel and discard them. There is nothing shared
  to verify, and pure functions are Lean's natural fit anyway.
- **AnimationWorklet.** Never shipped (probe: `CSS.animationWorklet` undefined in Chrome 157).
  **LayoutWorklet** is still experimental. Neither needs a test.
- **Iris:** [P] for the SAB protocol, [A] for scheduling.

### A5. postMessage, structured clone and Transferables
- **Clone** is a deep copy, O(n): 64 MiB took 157 ms round trip (§1.6). Functions, DOM nodes,
  prototypes and Symbols are not cloned (DataCloneError, or the class is lost).
- **Transfer** is a move, O(1): the sender's buffer is detached (§1.6). Transferable types:
  - ArrayBuffer, MessagePort, ImageBitmap, OffscreenCanvas;
  - ReadableStream, WritableStream, TransformStream;
  - VideoFrame, AudioData, RTCDataChannel, MediaStreamTrack (Chromium), MediaSourceHandle.

  A SAB is not transferred. It is shared, so both sides see the same bytes (Node probe:
  `sabSharedByPostMessage: true`).
- **Ordering:** FIFO per port, nothing across ports. There is no backpressure.
- **Patterns:**
  - ping-pong buffers, the "transfer a buffer back and forth" double buffer;
  - zero-copy frames with OffscreenCanvas and VideoFrame;
  - stream piping.
- **Bugs:**
  - Use after transfer (silent).
  - Cloning large data every frame.
  - Unbounded queues when the producer outruns the consumer.
  - Assuming order across two ports.
- **Test:** B17 and B13.
- **Iris:** transfer is the cleanest ownership-transfer story there is. Model a channel spec as
  `send v : P v -∗ …` and `recv : … ∗ P v`, implemented by a verified HeapLang queue [P]. The real
  `postMessage` behind it is [A]. HeapLang has no channel primitive.

### A6. MessageChannel and MessagePort
- Two entangled ports. Ports are transferable, so two Workers can be wired directly to each other.
- Node adds `receiveMessageOnPort` (a synchronous receive), which combined with `Atomics.wait`
  gives a synchronous RPC (the synckit / make-synchronous pattern).
- **Bugs:**
  - Forgetting `port.start()` when using `addEventListener`.
  - Ports kept alive or leaked.
  - Deadlock in synchronous RPC: A waits for B, and B waits for A's event loop.
- **Iris:** [A] transport, with a [P] protocol on top (the request-id table).

### A7. BroadcastChannel
- Same-origin pub/sub across tabs, workers and iframes. The sender does not receive its own
  messages. There are no acks and no ordering across senders, and late joiners miss history.
- **Uses:** logout broadcast, cache invalidation, a "leader is alive" heartbeat.
- **Bugs:** split brain when used for election, missed messages, message storms.
- **Iris:** a lossy fan-out channel [A]. It gives no mutual exclusion, so use Web Locks for that.

### A8. SharedArrayBuffer and Atomics (the core)
- **Operations:**
  - `load`, `store`;
  - `add`, `sub`, `and`, `or`, `xor`, `exchange`, `compareExchange` (all return the old value);
  - `wait(i32|i64 array, i, expected, timeout)`, which returns `"ok"`, `"not-equal"` or
    `"timed-out"`;
  - `notify(…, count)`;
  - `waitAsync`, which returns `{async, value}`. Chrome since about 87-90 (sources differ), Safari 16.4, Firefox 145 (late 2025),
    Node yes.
  - `pause` (a spin-wait hint): Chrome 133, Firefox 137, Safari 18.4. Absent in Node 22 (probe).
  - `isLockFree(n)`.

  Atomics work on Int8/16/32, Uint8/16/32 and BigInt64/BigUint64. `wait`/`notify` only work on
  Int32Array and BigInt64Array. A SAB can be growable (ES2024; probe).
- **Memory model:**
  - Atomics are SeqCst. There is no acquire/release or relaxed variant and no standalone fence.
  - Plain accesses are Unordered: races are defined, not UB, but give weak results.
  - Only aligned unclamped-integer plain accesses are tear-free. Float32/Float64, Uint8Clamped and
    BigInt plain accesses may tear (spec `IsNoTearConfiguration`).
  - SC-DRF holds after the PLDI 2020 repair.
  - Cost on x86: `Atomics.store` is an XCHG (a full fence) and `Atomics.load` a plain MOV. On ARM
    (the Mac) they become LDAR/STLR-style instructions.
- **Requires:** cross-origin isolation (A12).
- **Shared:** raw bytes. Any structure has to be laid out by hand (indices, not pointers), and
  memory reclamation is manual.
- **Patterns:** every B pattern.
- **Bugs:** every C bug.
- **Iris:** the main target. CAS, xchg and FAA map 1:1, and `compareSafe` in CAS matches comparing
  integer slots [P]. `wait`/`notify` map to a no-op for safety [P], with no liveness [L]. Plain
  racing data needs [W]. Int32 wrap and the layout are [T].

### A9. Web Locks API (`navigator.locks.request(name, {mode, ifAvailable, steal, signal}, cb)`)
- **Locks:** asynchronous and named; exclusive or shared; scoped to the origin (storage bucket),
  across tabs and workers.
- **Lifetime:** a lock is held until the promise returned by `cb` settles, and **released
  automatically when the context dies**.
- **Inspection:** `query()` lists held and pending locks.
- **Availability:** Chrome 157 serialised two requests (probe). Node 22 lacks it; a later Node line
  adds `worker_threads.locks` (commit 9791ff3480, experimental).
- **Uses:**
  - leader election: hold a lock forever, and whoever gets it leads;
  - guarding multi-step IndexedDB or OPFS sequences;
  - one SharedWorker-like owner per origin.
- **Bugs:**
  - Deadlock through nested locks taken in different orders (nothing detects it).
  - `steal` breaks exclusion on purpose.
  - Holding a lock across a long `await` starves the others.
  - Too coarse for per-element data: each call is a promise round trip.
- **Test:** B18 and B2.
- **Iris:** state Web Locks as an [A] instance of iris-lean's `Lock` interface
  (`Iris/Iris/HeapLang/Lib/Lock.lean`: `newlock_spec`, `acquire`/`release` with `isLock`/`locked`).
  Client proofs are then real proofs. Shared mode maps to the `RwLock` interface
  (`Lib/RwLock.lean`).

### A10. WebAssembly threads and Emscripten pthreads
- **The instructions:** a shared `WebAssembly.Memory` (it needs a `maximum`); atomic
  load/store/rmw (add, sub, and, or, xor, xchg, cmpxchg); `memory.atomic.wait32`/`wait64`;
  `memory.atomic.notify`; `atomic.fence`.
- **Threads** are Workers instantiating the same module over the same memory.
- **Emscripten:**
  - `-pthread` turns this on.
  - `PTHREAD_POOL_SIZE` pre-spawns Workers, because creating a Worker needs the main thread to
    return to its event loop. Otherwise `pthread_create` followed by `join` on the main thread
    deadlocks.
  - `PROXY_TO_PTHREAD` runs `main` on a pthread. QED64 uses it (`qed64/lane/qed64.worker.js`
    line 2; `pthreadPoolSize` at line 97).
  - The main thread cannot `Atomics.wait`, so Emscripten busy-waits there
    (`ALLOW_BLOCKING_ON_MAIN_THREAD`).
  - System calls are proxied to the main runtime thread (`qed64/README.md` line 55).
  - Wasm Workers are a lighter alternative.
- **Other toolchains:** Rust has `wasm-bindgen-rayon` (work stealing).
- **Memory64 with shared memory:** QED64 does this (`qed64/lane/core.js` line 12).
- **Without isolation:** a page can create shared memory but cannot post it (probe).
- **LeanUI:** builds Lean's runtime single-threaded on purpose. That means no atomic RC and no TLS
  (TOOLCHAIN.md); on native macOS, the TLS lookup alone is about 2.5% of a diff.
- **Lean's threaded runtime:** marks objects shared between threads as MT and uses atomic RC for
  them. HeapLang has GC-like memory with no RC, so that cost and its correctness are not in any
  Iris model.
- **Shared-everything threads** (thread.spawn, shared globals, tables and functions) is a
  phase-2/3 proposal (sources disagree) with nothing shipped. Chromium has an intent to prototype
  main-thread `Atomics.wait`.
- **Iris:** a HeapLang-to-wasm translator (§7) [T]. The atomics map 1:1, and wasm follows the same
  SC-DRF model as JS (Watt, Rossberg, Pichon-Pharabod, OOPSLA 2019).

### A11. Node worker_threads, and Node's hidden threads
- **The API:**
  - `Worker`, `workerData`, `parentPort`, `isMainThread`;
  - `MessageChannel`, `BroadcastChannel`;
  - `receiveMessageOnPort`, `markAsUntransferable`, `moveMessagePortToContext`;
  - `resourceLimits`, `SHARE_ENV`, `terminate()`.

  `Atomics.wait` is allowed on Node's main thread (probe).
- **Hidden parallelism:** the libuv threadpool (default 4 threads, `UV_THREADPOOL_SIZE`) runs `fs`,
  `dns.lookup`, async `crypto` (pbkdf2, scrypt, randomBytes) and async `zlib`.
- **Processes:** `cluster` and `child_process` share no memory and communicate over IPC.
- **Pools:** Piscina, Tinypool, workerpool.
- **Bugs:**
  - A pending `waitAsync` does not keep a Worker alive, so it exits silently (probe, §1.5).
  - Threadpool starvation: four slow `fs` calls block `dns.lookup`.
  - `process.exit` in a worker kills only that worker.
  - Unhandled `'error'` events.
- **Test:** all the Node harnesses here.
- **Iris:** same as A8. Event-loop lifetime is [A] and [L].

### A12. Cross-origin isolation (COOP + COEP, or Document-Isolation-Policy)
- **Headers:** `Cross-Origin-Opener-Policy: same-origin` plus `Cross-Origin-Embedder-Policy:
  require-corp` (or `credentialless`) gives `crossOriginIsolated`.
- **Document-Isolation-Policy** isolates a single document without COOP/COEP. Chrome 137 desktop
  only; Android planned; no Firefox or Safari signal.
- **Costs:**
  - Third-party iframes, images and scripts need CORP or CORS.
  - OAuth popups lose `window.opener`.
  - Static hosts that cannot set headers need the `coi-serviceworker` hack.
  - Without isolation, timers are coarse (`/home/user/leanui/bench/race/race.js` line 318:
    "0.1 ms in Chrome").
- **In LeanUI:** the race page's QED64 lane requires it (`bench/race/lanes.mjs` line 52), and
  `leanui serve --coop` sends it.
- **Iris:** none. This is deployment, but it decides whether any SAB-based verified code can run
  at all.

### A13. OPFS sync access handles
- `FileSystemSyncAccessHandle` exists only in dedicated workers. By default it takes an **exclusive
  per-file lock**: a second handle throws NoModificationAllowedError (probe).
- Chrome added modes `read-only` and `readwrite-unsafe`. Several `readwrite-unsafe` handles are
  allowed at once (probe), and consistency becomes the app's job.
- **Uses:** SQLite-wasm (OPFS VFS, opfs-sahpool), DuckDB-wasm.
- **Bugs:**
  - The second tab cannot open the database.
  - A handle is not closed until the worker dies.
  - Torn multi-write updates without `flush` or a journal.
- **Iris:** an exclusive handle is a full points-to on a file-as-array [A]. With
  `readwrite-unsafe`, a client protocol (Web Locks or a SAB lock) must be proved [P] on top of an
  axiomatised file [A].

### A14. IndexedDB, localStorage and Cache Storage as shared resources
- **IndexedDB:**
  - Transactions have a scope (a set of object stores) and a mode. Read-only transactions run
    concurrently. Read-write transactions with **overlapping scopes are serialised in creation
    order**.
  - A transaction **auto-commits when no request is pending at the end of a task**, so awaiting a
    non-IDB promise inside it gives `TransactionInactiveError`.
  - `versionchange` blocks across tabs (`onblocked` and `onversionchange` must close
    connections).
  - Durability hints are `strict` or `relaxed`.
- **localStorage:** synchronous and cross-tab with **no locking** (the "storage mutex" was dropped),
  so read-modify-write across tabs loses updates. The `storage` event notifies other tabs.
- **Cache API:** no transactions.
- **Patterns:**
  - a read-modify-write inside one read-write transaction;
  - an outbox queue;
  - a leader that owns writes (with Web Locks).
- **Bugs:**
  - Lost updates when the read and the write are in separate transactions.
  - An inactive transaction across `await`.
  - Long transactions starving others.
  - Blocked upgrades.
- **Test:** B19.
- **Iris:** a read-write transaction is a logically atomic update of the stores' abstract state
  (iris-lean `atomic_update` and `atomic_wp`) [A]. Clients that compose transactions are [P].

### A15. Concurrency on one thread (async/await, microtasks, timers, scheduler.postTask/yield, requestIdleCallback)
- There are no threads but many interleavings: each `await` is a preemption point. Chrome 157 has
  `scheduler.postTask` and `scheduler.yield` (probe).
- **Bugs:**
  - Check-then-act across `await`.
  - Out-of-order responses: search-as-you-type showing stale results.
  - Double submission.
  - Re-entrancy in event handlers.
- **Relevance to LeanUI:** its update loop is sequential, and its async lanes answer later.
- **Test:** B24.
- **Iris:** HeapLang `fork` interleaves at every step. That is finer than JS's run-to-completion,
  so a proof is conservative and carries over [P]. Await points are [T].

### A16. GPU parallelism (WebGPU compute, WebGL)
- **WGSL:** `atomic<i32>`/`atomic<u32>`, `workgroupBarrier`, `storageBarrier`, and
  workgroup-shared memory.
- **Buffer mapping** (`mapAsync`) moves ownership between the CPU and the GPU: a mapped buffer
  cannot be used by the GPU.
- It is not JS threads, but it is the other parallel engine a UI has.
- **Iris:** the ownership protocol of mapping is [A]+[P]. The GPU memory model is out of scope.
  Listed for completeness; no test.

### A17. What is coming
- **Shared structs with `Atomics.Mutex` and `Atomics.Condition`:** TC39 Stage 2 (December 2024
  draft), V8 behind `--harmony-struct`. Fields never tear, and unlock goes through tokens. If it
  ships, "a mutex in JS" becomes one line, which shifts the baseline of every lock test.
- **Main-thread `Atomics.wait`:** a Chromium intent to prototype.
- **Wasm shared-everything threads.**
- **`Atomics.pause`:** shipped (Baseline 2025).

---

## 4. The patterns, each with a side-by-side test

Each test has three or four lanes:

- **(a) Idiomatic JS:** a lock, or messages.
- **(b) Hand-written lock-free JS:** the same algorithm as (c), unverified.
- **(c) Verified HeapLang:** the algorithm proved in iris-lean, translated to JS Atomics (or to a
  small wasm module) by the trusted translator (§7).
- **(d) Optionally, LeanUI wasm64 instances:** one single-threaded instance per Worker, calling (c)
  for the shared part.

The harness should be Node first (worker_threads, as in `probes/`), then a race-page lane
(`/home/user/leanui/bench/race/lanes.mjs`; async lanes in Workers already exist).

Common metrics:

- **Throughput:** ops/us summed, at W = 1, 2, 4 (= cores) and 6 (oversubscribed).
- **Latency:** p50, p99, max (`performance.now`, needs isolation for fine timers).
- **Fairness:** min/max, and Jain's index (Σx)² / (n·Σx²).
- **Correctness:** checksums, invariant checks, and a linearizability check of recorded
  histories. Porcupine runs on the Go at `/usr/local/go/bin/go`; a Wing-Gong checker in JS also
  works.
- **Under stress:**
  - schedule fuzzing: random `Atomics.pause` or busy-delays injected at labelled points;
  - main-thread jank: a 50 ms busy loop;
  - `worker.terminate()` mid-operation;
  - memory growth mid-operation;
  - counters started near 2^31 to force a wrap.

### B1. Shared counters and statistics (FPS counters, progress bars, request counts, histograms)
- **JS:**
  - (a) a mutex around `x++`;
  - (a') plain `x++` (wrong: §1.2 lost 43-71%);
  - (b) `Atomics.add`, or a CAS loop;
  - (b') per-worker shards, or count locally and publish once.
- **Iris:** [P] today. `Counter.incr` is the CAS loop (`Lib/Counter.lean` lines 29-35), with a
  monotone spec (`incr_mono_spec`) and a fractional "contribution" spec (`ccounter`,
  `incr_contrib_spec`, `read_contrib_spec_1`). The contribution spec is the proof that sharded
  counting adds up. A histogram is an array of such counters, with `Lib/Array.lean`.
- **Test, "lost-update roulette":**
  - W workers do K increments each, with random injected delays between the read and the write.
  - Report lost updates (plain), throughput and fairness, and a W sweep.
  - Add a wrap test: start at 2^31 − 10. The HeapLang proof assumes unbounded ints, so a JS
    Int32 counter wraps; translate to BigInt64 or prove modulo 2^32 [T].
- **Expected, honestly:** the verified CAS counter is exactly as fast as the hand-written one,
  because it is the same code. The big gain is from sharding (≈250x at W=4 in §1.2), which the
  contribution spec proves correct.

### B2. Mutual exclusion (spin lock, ticket lock, futex mutex, try-lock, timed lock)
- **Where:** guarding a multi-word structure in a SAB; Emscripten `pthread_mutex`; SQLite-wasm
  locking.
- **JS:**
  - (a) Web Locks (async, coarse);
  - (b) a CAS spin lock, a ticket lock (FAA), or the Drepper 3-state futex mutex on `wait`/`notify`.
- **Iris:** SpinLock and TicketLock are [P] today (`Lib/SpinLock.lean`, `Lib/TicketLock.lean`, both
  instances of the `Lock` interface). A futex mutex is [P]: `wait` is a no-op for safety, and the
  proof is a SpinLock-like invariant over the 0/1/2 states. Fairness, convoys and lost wakeups are
  [L].
- **Test, "lock zoo under oversubscription":**
  - Run W = 1..2×cores workers.
  - Measure throughput, Jain's index, and p99 hold-to-acquire latency.
  - §1.2 already shows ticket lock ≈ 0 at W=6 and spin lock unfair (0.17-0.49).
  - Add a **kill test**: `worker.terminate()` while the lock is held. SAB locks hang forever; Web
    Locks release. Measure time to detect, using `wait` timeouts plus owner ids.
  - Add a **priority-inversion test**: an AudioWorklet consumer (it cannot block) depends on a lock
    held by a slow Worker, counted as glitches per minute.
- **Expected, honestly:** all three SAB locks are proved equally safe, yet behave completely
  differently. Show this as "what the proof does not say".

### B3. Counting semaphore (limit concurrent decoders, fetches or GPU uploads to N)
- **JS:** (a) a semaphore on Web Locks (N named slots) or a token queue in the main thread;
  (b) a SAB permit count with a CAS decrement-if-positive, `Atomics.wait` on 0, and `notify` on
  release.
- **Iris:** [P]. The invariant "count + held = N" uses tokens (`Instances/Lib/Token.lean`) or Auth
  of a natural number. RwSpinLock's reader count (`tryAcquireReader`: CAS n → n+1 if n ≥ 0) is
  nearly a semaphore already.
- **Test:**
  - Run 8 workers through a 3-permit semaphore.
  - Assert that the maximum number simultaneously inside is ≤ 3, using an atomic in-section counter.
  - Measure throughput vs N.
  - Inject release-without-acquire (a mutation) and check that the proof fails.

### B4. Condition variables and event counts on wait/notify
- **Where:** producer/consumer sleep and wake; Emscripten `pthread_cond`; QED64's stdin ring WAKE
  word (`qed64/lane/core.js` lines 24-52: READ, WRITE, CLOSED and WAKE words, `Atomics.add(WAKE)`
  then `notify`).
- **JS:** an "epoch" event count: the waiter reads the epoch, re-checks the condition, then
  `Atomics.wait(epoch, seen)`. The notifier changes the state, then increments the epoch, then
  notifies.
- **Bugs:**
  - Waiting on a different word than the one that changed.
  - Notifying before publishing.
  - `notify(…, 1)` when several waiters need waking.
  - Waiting on the main thread (throws), or in a worklet (throws).
- **Iris:** safety [P]: the state machine of the epoch can be proved. The absence of lost wakeups
  is [L], which is exactly QED64's HARDENING #52.
- **Test, "lost-wakeup hunt":**
  - Run 10^6 sleep/wake cycles with schedule fuzzing between "check" and "wait".
  - Each waiter has a watchdog timeout that counts how often it rescued a lost wakeup.
  - Variants: correct epoch protocol, notify-before-store (mutation), and a wrong word (mutation).
- **Expected:** the proof catches neither mutation, because both are liveness. Say so.

### B5. Barriers (phases of a simulation step, a parallel layout pass, a frame's parallel stages)
- **JS:** (a) postMessage "done", with the main thread counting replies; (b) a sense-reversing or
  generation barrier: FAA the arrival count; the last arriver resets it and bumps the generation,
  then `notify` all; the others `wait` on the generation.
- **Iris:** [P+]. It needs a phase ghost state (Auth plus Frac per participant). Not in iris-lean;
  Coq iris_examples has barrier proofs to port.
- **Test:**
  - Run N phases × W workers, each phase writing a disjoint slice and then reading neighbours'
    slices.
  - Assert that no reader sees the previous phase's data (a stencil checksum).
  - Measure phase time, barrier overhead per phase vs postMessage, and the effect of a straggler.

### B6. Reader-writer locks (a shared config or scene graph read by many workers, written rarely)
- **JS:** (a) Web Locks `mode: "shared"`; (b) the SAB RW spin lock (a reader count, −1 for the
  writer).
- **Iris:** RwSpinLock is [P] today (`Lib/RwSpinLock.lean`: `tryAcquireReader`,
  `acquireWriter`, `releaseWriter` specs). Writer starvation is [L].
- **Test:**
  - Run a 95/5 and a 50/50 read/write mix, with W readers and 1 writer.
  - Report read throughput, writer p99 wait (starvation shows here), and a torn-read checker.
  - Compare with a seqlock (B12) and RCU/COW (B14) on the same data.

### B7. Lazy one-time initialisation (once): a font or glyph atlas, a wasm module compiled once, a lookup table
- **JS:** (a) the main thread initialises and posts the result to every worker; (b) a 3-state
  once (0 uninit, 1 running, 2 done): CAS 0→1, initialise, store 2, `notify` all. Others `wait`
  while 1.
- **Bugs:**
  - Double-checked locking with plain reads publishing a half-built table (needs [W] if plain).
  - The initialiser crashing while in state 1, so everyone waits forever.
- **Iris:** [P]. One-shot ghost state from Excl and Agree (`Algebra/Excl.lean`,
  `Algebra/Agree.lean`), the classic Iris "oneshot" example. Persistence after "done" comes from
  Agree.
- **Test:**
  - 8 workers race to initialise a 1 MiB table; check that exactly one runs `init`.
  - Inject: kill the initialiser mid-init (hang, [L]); omit the final store (the proof fails).
  - Measure first-use latency for each worker.

### B8. SPSC ring buffer (AudioWorklet queues, QED64's stdin ring, a log shipper, input event streams)
- **JS:**
  - (a) one `postMessage` per item (0.54-0.71 items/us, §1.4), or batched and transferred (56-71);
  - (b) a Lamport ring: `Atomics` on the indices, plain data (4.8-5.3), cached indices with
    batched publication (82.9), or a blocking variant with `wait`/`notify` (2.6-2.8).
- **Iris:**
  - [P] for the SC version with `Atomics` on both indices and data, or with data accessed only by
    the side that owns the slot.
  - The ownership argument is perfect for separation logic: slot i is owned by the producer when
    `tail − head < CAP` and i is in the free region, and by the consumer when it is in the filled
    region. Indices are monotone, so use Auth of a natural number, or MaxPrefixList for the
    contents (`Algebra/MaxPrefixList.lean`).
  - The plain data accesses in (b) are justified by SC-DRF only if the proof also shows that no two
    threads touch a slot concurrently. That is a [T] annotation argument (§7).
  - The cached-index variant needs exactly the same invariant, so batching is free proof-wise.
- **Failure injection:** "publish before write" (§1.4: 2,504-8,796 stale items per 2 M). The proof
  of the mutated ring fails at the publish step.
- **Test:**
  - **"glitch counter":** an AudioWorklet (or a Node stand-in with a 2.67 ms tick) consumes 128
    samples per tick from a producer Worker. Inject main-thread jank and GC pressure. Count
    underruns per minute and p99 producer-to-sink latency.
  - **"QED64 ring":** prove the actual stdin ring protocol of `qed64/lane/core.js` (READ, WRITE,
    CLOSED, WAKE), safety only. Run the existing QED64 lane with the HeapLang-derived producer in
    place of `Ring.pump`.

### B9. MPSC and MPMC queues (job queues, logging from many workers, a task inbox)
- **JS:**
  - (a) a mutex-protected ring;
  - (a') each worker posts to the main thread (an actor);
  - (b) a Vyukov bounded MPMC queue (a per-slot sequence number plus CAS on enqueue and dequeue
    positions);
  - (b') a Michael-Scott queue over a SAB node arena. It needs tagged indices against ABA, plus
    reclamation (B14).
- **Iris:**
  - Vyukov bounded MPMC is [P+]: per-slot ghost state and a logically atomic spec with
    `atomic_wp`. No iris-lean proof exists.
  - Michael-Scott and Herlihy-Wing queues are [P+] (Coq Iris proofs exist; Herlihy-Wing needs
    prophecies, which iris-lean has).
  - Over a SAB arena with recycling, ABA becomes real (C6). The HeapLang model must recycle indices
    explicitly, or the proof covers a different program [T].
- **Test, "MPMC torture":**
  - P producers and C consumers with unique tagged items. Check exactly-once delivery and per-producer
    FIFO.
  - Record histories and check linearizability (Porcupine).
  - Sweep P, C ∈ {1, 2, 4}; measure throughput and p99.
  - Mutation: remove the slot sequence check. The proof fails, and stress shows duplicates or
    losses.

### B10. Work queues and fork-join parallel map/reduce (image filters, diffing, parsing chunks, Mandelbrot tiles)
- **JS:**
  - (a) the main thread splits the work into W chunks and posts them;
  - (b) a shared index: `i = Atomics.add(next, CHUNK)` until `i ≥ N` (dynamic chunking);
  - (c) `Promise.all` over a worker pool.
- **Iris:**
  - Par and Spawn are [P] today (`Lib/Par.lean` `par_spec`/`wp_par`; `Lib/Spawn.lean`). `join` is
    a spin on a ref (lines 30-35), so the translation should use `wait`.
  - FAA claiming is [P]: each index is claimed exactly once, shown with a ghost set or tokens.
  - Disjoint output slices are plain separation (`Lib/Array.lean`).
  - The result: "every element computed exactly once, and the outputs do not overlap", proved, with
    no lock.
- **Test, "uneven Mandelbrot":**
  - Run 1024 tiles with very uneven cost: static partition vs dynamic FAA chunks vs work stealing
    (B11).
  - Measure makespan, idle time per worker, and load imbalance (max/mean).
  - Correctness: a checksum of the image, and that each tile is written once (a per-tile write
    counter).
  - **LeanUI variant:** a LeanUI-specific map, such as diffing N independent subtrees or computing
    N rows of a big table, with one single-threaded LeanUI wasm64 instance per Worker. The verified
    FAA claimer hands out work, and the outputs go into disjoint SAB slices.

### B11. Work stealing (rayon via wasm-bindgen-rayon, Cilk-style schedulers)
- **JS:** (a) B10's FAA queue (simpler, often good enough); (b) a Chase-Lev deque per worker
  (owner push/pop at the bottom, thieves CAS at the top).
- **Iris:** [P+] and research-grade, but done in Coq:
  - Jaemin Choi's Chase-Lev in Iris (arXiv 2309.03642; an iris/examples MR);
  - Jung et al., OOPSLA 2023 (Chase-Lev with reclamation);
  - Allain's thesis (2025) and Allain and Scherer (PLDI 2026, a verified work-stealing scheduler
    for OCaml 5).

  The proofs use prophecy variables. Porting is a big but well-defined job: iris-lean has the
  prophecy primitives.
- **Weak memory:** Chase-Lev in C11 needs a seq_cst fence between the owner's bottom store and its
  top load. In JS everything is SC, so it is fine with Atomics, and expensive.
- **Test:** the uneven Mandelbrot from B10, plus a recursive fork-join (parallel quicksort; note that
  iris-lean's `Lib/Quicksort.lean` is sequential over lists). Measure steals per second, makespan,
  and p99 task latency.
- **Expected:** FAA chunking likely wins at W=4. Stealing pays off with nested parallelism.

### B12. Seqlocks (a frequently-updated small record read by many: camera pose, mouse position, audio parameters)
- **JS:** (a) a mutex; (b) a seqlock (an odd/even sequence word with retries).
- **Measured** (§1.3): plain-data seqlock: reader 1.01 snapshots/us with 6.9 M retries.
  Atomics-data seqlock: 0.10. Triple buffer: 7.86.
- **Iris:**
  - The SC version with Atomics data is [P]: a ghost history of versions, and the reader's
    validation shows the snapshot equals the history entry for s1.
  - The plain-data version is [W]. In the JS model, plain reads may be reordered after the second
    `Atomics.load(seq)`; this is Boehm's seqlock problem from C11. It only "works" on x86 TSO here.
    Re-test on the Mac (ARM).
- **Test, "torn frame detector":**
  - The writer updates a K-word pose at 1 kHz; readers sample at 60 Hz and 10 kHz.
  - Report torn snapshots accepted, retries per read, reader throughput, and staleness in versions.
  - Run on x86 and ARM, and with K = 2, 16 and 256.
- **Expected:** on ARM, plain-data seqlocks may accept torn snapshots that the SC proof says are
  impossible. That is the clearest demonstration of the SC assumption.

### B13. Double and triple buffering (rendering, game state, video frames)
- **JS:**
  - (a) postMessage the frame (clone) or transfer the buffer back and forth (ping-pong ownership);
  - (b) a triple buffer: three slots, with the writer and reader each owning one and a "middle" slot
    swapped with `Atomics.exchange` (a fresh bit marks new data);
  - (c) OffscreenCanvas in a worker, where the browser does the buffering.
- **Measured** (§1.3): the triple buffer was the fastest on both sides (7.75 and 7.86/us), with 0
  torn and wait-free.
- **Iris:** [P] and the **flagship candidate**. The invariant owns exactly one buffer (the
  middle), each side owns its own, and HeapLang `xchg` swaps ownership. There are no plain races,
  so SC-DRF covers the plain data accesses, provided the [T] annotation is correct. It is small and
  complete, and a natural first port.
- **Test, "60 fps without tearing":**
  - A simulation Worker produces state at 240 Hz; a render loop consumes at 60 Hz.
  - Variants: a mutex, clone per frame, transfer ping-pong, and the triple buffer.
  - Measure torn frames, dropped frames, input-to-display latency (versions behind), and main-thread
    time per frame.
  - Add a mutation: swap without the fresh bit, so a frame is re-shown. That is a functional bug
    the proof catches.

### B14. Copy-on-write snapshots, RCU, epoch reclamation (immutable versions published by pointer swap)
- **Where:** a large shared read-mostly structure, such as a symbol table, routing table or theme,
  in a SAB arena.
- **JS:** (a) postMessage a new immutable copy to all workers (clone cost: §1.6); (b) build the new
  version in free arena space, then `Atomics.store(root, newIdx)`. Readers read the root and
  traverse. Reclamation needs epochs, hazard pointers or reference counts (B15).
- **Iris:**
  - Publication is [P]: an invariant on the root, with each version's cells immutable, persistent
    via Agree or a discardable fraction.
  - Reclamation is [P+]: Jung et al. OOPSLA 2023 verified hazard pointers and RCU in Iris under SC
    (kaist-cp/smr-verification); a PLDI 2025 follow-up does RCU under weak memory.
  - HeapLang's never-reused addresses hide the hard part unless the arena is modelled explicitly [T].
- **Test, "hot config reload":**
  - 4 readers do lookups while 1 writer publishes a new 1 MiB version every 10 ms.
  - Measure lookup p99, publish cost, memory high-water mark (no reclamation vs epochs), and
    reads of freed slots. Poison freed memory with a sentinel and count sentinel reads.

### B15. Reference counting across threads (shared buffer pools, Lean's own MT objects)
- **JS:** an `Atomics.add` refcount per pooled buffer. The thread whose `Atomics.sub` returns 1
  frees the buffer.
- **Bugs:**
  - Check-then-decrement races.
  - Increment from 0 (resurrection).
  - Plain decrements (lost) leading to double frees and leaks.
- **Note:** Lean's threaded runtime does exactly this for objects marked MT (atomic RC). LeanUI's
  single-threaded build avoids it (TOOLCHAIN.md).
- **Iris:** [P]. Counting permissions with fractions (`Algebra/Frac.lean`, `DFrac`, `UFrac`) or a
  counting Auth: the last decrement gets the full ownership back. Cancellable invariants
  (`Instances/Lib/CInvariants.lean`) let the last owner deallocate.
- **Test, "buffer pool churn":**
  - 4 workers acquire, share and release pooled buffers, 10^7 times.
  - Poison freed buffers; count use-after-free (sentinel reads), leaks (pool not full at the end)
    and double frees (a free-list duplicate check).
  - Mutation: a plain decrement. The proof fails, and stress shows leaks or double frees.

### B16. Cancellation (abort a long computation in a worker)
- **JS:**
  - (a) `worker.terminate()`: immediate, but it loses state and can leave SAB locks held (B2);
  - (b) an `AbortSignal` sent by postMessage: only seen when the worker yields to its event loop;
  - (c) a SAB cancel flag polled every k iterations with `Atomics.load`. A plain poll is allowed
    to be hoisted (§1.7: V8 didn't).
- **Iris:** [P] for "once cancelled, no new side effects are published" (a monotone flag:
  `Algebra/Numbers` max, or Agree). Cancellation latency is [L] and a measurement.
- **Test:** cancel at a random time and measure cancel-to-stop latency vs the poll interval, the
  throughput cost of polling, and whether partial output is consistent.

### B17. Message-passing actors, RPC and pipelines (Comlink, worker pools, streams)
- **JS:**
  - (a) postMessage RPC with request ids;
  - (b) transferable streams with backpressure (`highWaterMark`);
  - (c) SAB rings as channels (B8, B9).
- **Bugs:**
  - Unbounded queues: postMessage has no backpressure.
  - Lost replies when a worker dies.
  - Correlation-id mixups.
  - Cloning large payloads (use transfer).
- **Iris:** the actor's mailbox and the RPC table are [P] given a channel spec. The transport is [A].
- **Test, "flood":**
  - A producer sends faster than the consumer handles.
  - Compare postMessage (watch the heap grow), a transferable stream (bounded), and a verified SAB
    ring (bounded by construction).
  - Measure memory high-water mark and end-to-end p99.
  - Also run an RPC throughput sweep: clone vs transfer vs SAB (§1.6).

### B18. Cross-tab coordination: leader election, single connection, cross-tab mutual exclusion
- **JS:**
  - (a) a Web Locks "hold forever" leader, plus BroadcastChannel for data;
  - (b) a SharedWorker as the coordinator;
  - (c) legacy localStorage-timestamp elections (racy).
- **Iris:**
  - Web Locks as an [A] `Lock` instance makes "at most one leader" a [P] corollary.
  - The localStorage election cannot be proved, because there is no atomic RMW. That is a nice
    negative example.
- **Test (Playwright, N tabs):**
  - Kill or close the leader and measure failover time.
  - Count "two leaders at once" incidents (each leader writes its id with a timestamp to IndexedDB;
    count overlaps).
  - Compare Web Locks vs localStorage vs SharedWorker.

### B19. Storage read-modify-write across tabs and workers (IndexedDB counter, quota accounting, an outbox)
- **JS:** (a) the read and the write in separate transactions (loses updates); (b) both in one
  read-write transaction; (c) localStorage RMW (loses updates); (d) Web Lock plus IndexedDB.
- **Iris:** an IndexedDB read-write transaction as a logically atomic update [A]. The client
  composition is [P].
- **Test:**
  - N tabs or workers each do K increments.
  - Report lost updates, throughput, and the `TransactionInactiveError` rate when an `await` is
    inserted inside the transaction (failure injection).

### B20. Concurrent hash map, memo table or intern table (string interning, glyph cache, a shared memo for a parallel computation)
- **JS:** (a) a mutex around a SAB open-addressing table; (b) a lock-free insert-only table: CAS
  the key slot from empty to the key, then publish the value with a per-slot state word.
- **Iris:** [P]. Insert-only maps are monotone: a ghost map whose entries never change
  (`Instances/Lib/GhostMap.lean` with persistent or discarded entries, or Auth of a map with Agree
  values). The "never changes once written" part needs no locks and is an ideal Iris spec. Deletion
  or resizing is [P+].
- **Test:**
  - 4 workers intern 10^6 strings with 30% overlap.
  - Check that each string got one id, that no id was reused, and that lookups never see a
    half-written key.
  - Measure throughput vs a mutex, and vs per-worker maps merged at the end.

### B21. Shared allocators (bump allocation in a SAB arena, free lists)
- **JS:** (a) `Atomics.add(top, size)` bump allocation per request, or per-worker slabs; (b) a
  Treiber-stack free list with tagged indices.
- **Iris:**
  - The bump allocator is [P]: FAA hands out disjoint ranges, which become points-to over an array
    region.
  - The free list is [P+] if ABA is modelled, through the explicit arena [T].
- **Test, "ABA stress":**
  - A Treiber free list with and without version tags, with injected delays between reading `head`
    and `next` and the CAS.
  - Count corrupted lists: cycles and lost nodes.
  - Measure allocation throughput vs per-worker slabs.

### B22. Memory growth on shared memory
- **Where:** QED64 `core.js` line 38 (views are taken anew each time, because growing replaces
  the buffer); growable SAB; wasm `memory.grow` from another thread.
- **Bugs:** a stale view after growth gives out-of-range reads that return `undefined`.
- **Iris:** [T]. HeapLang memory never moves. The proof covers the protocol, and the translator
  must re-derive views.
- **Test:** grow memory while B8 runs. Count exceptions and stale views; measure the cost of
  re-deriving views.

### B23. Atomic snapshots of several counters and statistics (a consistent read of many words)
- **JS:** a seqlock (B12), a triple buffer (B13), or double-collect (read twice until equal).
- **Iris:** double-collect is [P+] with prophecies (the standard Iris atomic snapshot proof). It is
  a good showcase for the prophecy support in iris-lean (`Syntax.lean` `newProph`/`resolve`,
  `HeapLang/ProphErasure.lean`).
- **Test:** 4 updaters and 1 snapshotter. Check that each snapshot matches some instant
  (sum-invariant checks), and count retries.

### B24. Async races on one thread (A15)
- **JS:**
  - (a) naive `await fetch` then `setState`, so stale responses win;
  - (b) request sequence numbers, ignoring responses older than the latest;
  - (c) `AbortController` per request.
- **Iris:** [P]. Model each pending request as a forked thread and the UI state as a location; the
  sequence-number guard is a monotone counter invariant. This is directly about LeanUI apps.
- **Test:** search-as-you-type with random server latency. Count stale renders (the shown result
  does not match the latest query) and time to correct display.

### B25. Meta-test: mutation score, proof vs stress
Apply the same set of bug mutations to each pattern:

- reorder the publish and the data write;
- drop a CAS check;
- make an atomic plain;
- drop a `notify`;
- remove an ABA tag;
- use Int32 where the proof assumed ℤ;
- notify the wrong word.

Then record:

- whether the iris-lean proof still checks (expected: it fails for every SC-safety mutation, still
  passes for liveness-only mutations, and may pass for a plain-access mutation, because HeapLang
  does not tell plain and atomic apart unless §7's change is made);
- whether a 10-second stress test caught it, and after how many operations;
- whether it is caught on the Mac (ARM) but not on x86.

This table is the most honest single picture of what the proofs buy.

---

## 5. Bugs: what triggers each, and whether iris-lean rules it out

| # | Bug | Typical JS trigger | Probe or test | iris-lean |
|---|---|---|---|---|
| C1 | data race, lost update | plain `x++` on a SAB | §1.2: 43-71% lost | ruled out under SC [P]; the plain-vs-Atomics choice is [T] |
| C2 | torn read | multi-word record without a protocol; Float64 or BigInt plain accesses may tear | §1.3: 9.3% torn | multi-word: [P]; single-access tearing: below HeapLang's level (each access is atomic) [T] |
| C3 | stale read or missing publication | publish an index before writing the data | §1.4 ringBug | [P] (the proof fails) |
| C4 | visibility, hoisted polls | plain flag poll | §1.7 (V8 didn't hoist) | [W]/[T]: HeapLang loads always see the latest value |
| C5 | lost wakeup | notify before store, wrong word, `notify(1)` with many waiters | QED64 HARDENING #52 | **not ruled out** [L] |
| C6 | ABA | Treiber stack or free list over recycled SAB indices | B21 | **hidden by HeapLang** (addresses never reused) unless the arena is modelled [T] |
| C7 | deadlock | lock-order inversion; Web Locks nesting; Emscripten `pthread_create` + `join` on the main thread with an empty pool; synchronous RPC cycles | B2, A10 | partial correctness: a deadlocked program is "safe" [L] |
| C8 | livelock or starvation | CAS retry storms; spin lock unfairness | §1.2: spin fairness 0.17 | [L] |
| C9 | convoy, preemption collapse | ticket lock with more threads than cores | §1.2: ticket ≈0 at W=6 | [L] |
| C10 | priority inversion | AudioWorklet waiting on a lock held by a low-priority Worker | B2 | [L]/[A] |
| C11 | unbounded queues, memory blow-up | postMessage with no backpressure | B17 | bounded rings: the capacity invariant is [P] |
| C12 | false sharing | adjacent per-worker slots | §1.2: about 0.65x | not a correctness bug; out of scope |
| C13 | use after transfer | access after `postMessage(buf, [buf])` | §1.6: detached; silent zero length | the ownership discipline rules it out in the model [P]; the browser is [A] |
| C14 | stale view after growth | cached TypedArray over grown memory | B22 | [T] |
| C15 | event-loop lifetime | Node: a pending `waitAsync` does not keep the Worker alive | §1.5 | [A]/[L] |
| C16 | blocking where it is not allowed | `Atomics.wait` on the main thread, in a worklet or in a SW | §1.1: throws | [A] (the translator must pick `waitAsync` or spinning) |
| C17 | integer wrap | Int32 counters and tickets at 2^31 | B1 | HeapLang ℤ is unbounded [T] |
| C18 | transaction inactive or split RMW | `await` inside an IndexedDB transaction; separate read and write transactions | B19 | [A] |
| C19 | crash while holding a lock | `worker.terminate()` mid-section | B2 | [L]; Web Locks recover, SAB locks do not |
| C20 | version skew | an old page with a new Service Worker | A3 | out of scope |

---

## 6. Test matrix, by what is realistic

**Tier 1: the iris-lean libraries (or small new proofs) cover it today. Build these first.**

| Test | JS lanes | Verified lane | Proof base |
|---|---|---|---|
| B1 lost-update roulette (+ shards) | plain, mutex, `Atomics.add` | CAS counter, contribution-sharded counter | `Lib/Counter.lean` |
| B2 lock zoo + kill + oversubscription | Web Locks, futex | SpinLock, TicketLock (+ futex as a new proof) | `Lib/SpinLock.lean`, `Lib/TicketLock.lean`, `Lib/Lock.lean` |
| B6 RW mix | Web Locks shared, RW futex | RwSpinLock | `Lib/RwSpinLock.lean` |
| B10 uneven Mandelbrot (static, FAA, Par) | postMessage chunks | `par`, plus a new FAA claimer proof | `Lib/Par.lean`, `Lib/Spawn.lean`, `Lib/Array.lean` |
| B13 triple buffer, 60 fps | mutex, clone, transfer | **new, small**: xchg ownership swap | invariants + Excl tokens |
| B8 SPSC ring (glitch counter, QED64 ring) | postMessage, unverified ring | **new**: SPSC ring | Auth over naturals, MaxPrefixList |
| B7 once | main-thread init | **new**: oneshot | Excl + Agree |
| B3 semaphore | Web Locks slots | **new** | Token / Auth |

**Tier 2: new proofs of moderate difficulty.** B4 (safety only), B5 barrier, B12 seqlock (SC,
Atomics data), B15 refcount pool, B20 insert-only map, B21 bump allocator, B24 async sequence
guard, B9 Vyukov MPMC.

**Tier 3: research ports from Coq Iris.** B11 Chase-Lev (prophecies), B14 RCU and hazard pointers
(OOPSLA 2023), B23 atomic snapshot (prophecies), the Michael-Scott and Herlihy-Wing queues.

**Cannot be done in iris-lean at all.** Everything tagged [L]. Weak-memory variants [W]: the
plain-data seqlock, relaxed publication. Host API internals [A].

---

## 7. Constraints these patterns place on HeapLang → JS/wasm translation (for the translator owner)

1. **Plain vs atomic.** Emit `Atomics.*` for every location that is ever accessed while an invariant
   is open, and plain accesses only for locations accessed under full or exclusive ownership. Iris
   cannot see the difference today: HeapLang has no race detection. The fix, to take iris-lean
   further:
   - Add λRust-style non-atomic loads and stores to HeapLang, which **get stuck on a race**.
   - The existing adequacy theorem (`Iris/Iris/ProgramLogic/Adequacy.lean`, not-stuck) then
     **proves data-race freedom**.
   - JS and wasm SC-DRF then justifies the plain accesses.

   This is a real but bounded extension.
2. **Ints.** HeapLang ℤ maps to BigInt64 slots (slow), to Int32 plus a wrap side condition proved
   in Lean, or to a bounded-int fragment checked by the translator.
3. **Values.** Only ints, bools, unit and locations (as indices) fit in SAB cells. Pairs and sums
   need arena allocation. Closures cannot cross Workers (DataCloneError), so verify a first-order
   fragment.
4. **Allocation.** HeapLang `allocN` is fresh forever. A SAB arena recycles. Either never recycle
   (bump only), or model the arena explicitly in HeapLang so that ABA is in the proof.
5. **Waiting.** HeapLang spin loops (TicketLock `waitLoop`, Spawn `join`) can be emitted as
   `Atomics.wait`, `Atomics.waitAsync` or `Atomics.pause` loops. That is sound for safety, because
   wait is modelled as a no-op, and invisible to the proof. Pick by context: no `wait` on the main
   thread, in worklets or in SWs; Node `waitAsync` needs a keep-alive.
6. **fork.** Map it to a pool Worker (startup costs tens of ms, so pre-spawn) or to a task on an
   existing Worker.
7. **Host APIs** enter only as axioms with specs: Web Locks as `Lock`, IndexedDB as an atomic update,
   postMessage as a channel.
8. **Where Lean code runs.** LeanUI's wasm64 runtime is single-threaded. The realistic architecture
   is one LeanUI instance per Worker, each with its own non-shared memory, plus a separate shared
   region for the verified protocol. The region can be a SAB driven by translated JS, or a tiny
   wasm module with shared memory (Lean's own module cannot see it without multi-memory, and
   clang/Emscripten does not do multi-memory from C).

   Every protocol operation is then an FFI call, so batch (B8's cached-index ring is the template).
   The alternative, Lean's threaded runtime (as in QED64), puts atomic RC and TLS back into every
   object operation. That is what LeanUI removed.

---

## 8. Honest summary of the shortcomings

- Iris-lean proofs are about HeapLang under SC, for safety. Translation, int width, memory layout,
  reclamation, address reuse, plain-vs-atomic choice, liveness and performance are all outside the
  proof.
- On the measured evidence, the performance gains in JS concurrency come from ownership (sharding,
  batching, transfer, triple buffering), not from replacing a lock with a CAS. Iris is a good tool
  for proving ownership protocols correct, but it does not make them fast.
- The most practically important bug class in the user's own code (QED64's lost wakeup) is
  liveness, which Iris cannot address. A proof plus a watchdog is still the realistic design.
- Host APIs (postMessage, Web Locks, IndexedDB, OPFS) can only be axiomatised. Claims about them
  rest on the specs and on browser correctness.
- The JS memory model gives only SC atomics. So "relaxed and cheaper" algorithms are not even
  expressible with `Atomics`, and plain-access tricks need [W] logic that iris-lean lacks. The
  upside: no fence bugs in Atomics-only code.

---

## 9. Sources

- Project:
  - `/home/user/leanui/docs/TOOLCHAIN.md` ("Why single-threaded")
  - `/home/user/leanui/bench/race/lanes.mjs` lines 1-55
  - `/home/user/leanui/bench/race/race.js` line 318
  - `/home/user/leanui/qed64/README.md` lines 30, 55-61
  - `/home/user/leanui/qed64/lane/core.js` lines 10-53
  - `/home/user/leanui/qed64/lane/qed64.worker.js` lines 2, 97
- iris-lean upstream (commit 100ed29e, Lean v4.36.0), under
  `<scratchpad>/ext/iris-lean-upstream/Iris/`:
  - `Iris/HeapLang/Syntax.lean` lines 320-331: allocN, free, load, store, cmpXchg, xchg, faa, fork,
    newProph, resolve
  - `Iris/HeapLang/Semantics.lean` lines 403-411: allocN freshness, free leaves `none`
  - `Iris/HeapLang/Lib/{Counter,SpinLock,TicketLock,RwSpinLock,Spawn,Par,Lock,RwLock,Array,Quicksort}.lean`
  - `Iris/ProgramLogic/{Atomic,Adequacy,TotalWeakestPre}.lean`
  - `Iris/Instances/Lib/*` and `Iris/Algebra/*`
- Probes: `<scratchpad>/iris/catalogue/probes/`
  and `…/catalogue/browser/`, as listed in §1.
- Web:
  - Atomics.pause support: https://web-platform-dx.github.io/web-features-explorer/features/atomics-pause,
    https://groups.google.com/a/mozilla.org/g/dev-platform/c/w-Fn_1frOiM
  - Atomics.waitAsync (Firefox 145): https://caniuse.com/mdn-javascript_builtins_atomics_waitasync,
    https://web.dev/blog/web-platform-11-2025
  - Document-Isolation-Policy (Chrome 137 desktop): https://developer.chrome.com/blog/document-isolation-policy
  - SharedWorker on Android: https://groups.google.com/a/chromium.org/g/blink-dev/c/_Lsfs08XX5c,
    https://developer.chrome.com/blog/chrome-148-beta
  - Agents and [[CanBlock]]: https://html.spec.whatwg.org/multipage/webappapis.html,
    https://html.spec.whatwg.org/dev/worklets.html
  - JS memory model: https://tc39.es/ecma262/multipage/memory-model.html; tear-free rules:
    https://tc39.es/ecma262/2024/multipage/memory-model.html
  - Watt et al., "Repairing and Mechanising the JavaScript Relaxed Memory Model", PLDI 2020:
    https://arxiv.org/abs/2005.10554. "Weakening WebAssembly", OOPSLA 2019:
    https://people.mpi-sws.org/~rossberg/papers/Watt,%20Rossberg,%20Pichon-Pharabod%20-%20Weakening%20WebAssembly%20[Extended%20Draft].pdf
  - Shared structs, Atomics.Mutex/Condition (Stage 2): https://github.com/tc39/proposal-structs
  - Wasm shared-everything threads: https://github.com/webAssembly/shared-everything-threads
  - Node Web Locks commit: https://github.com/nodejs/node/commit/9791ff3480
  - Iris Chase-Lev: https://arxiv.org/abs/2309.03642, https://iris-project.org/pdfs/2026-pldi-parabs.pdf,
    https://iris-project.org/pdfs/2025-phd-allain.pdf
  - Iris SMR (hazard pointers, RCU): https://github.com/kaist-cp/smr-verification,
    https://park-sunho.github.io/assets/pdf/oopsla23_smr.pdf,
    https://iris-project.org/pdfs/2025-pldi-weak-smr.pdf
