# The threads suite: design

**Read this first.** Below is the design as written before any code, then an adversarial review
of it in `critique.md`. The review's corrections are binding: where they and the text below
disagree, the corrections win.

1. **The same constant.** A translated program uses the very Lean constant its theorem is about,
   imported from the proof module, never a text copy. The research prototype had a different
   `faaIncr` and a copied Treiber stack; `iris/` fixes both, and its generator finds each kernel in
   a program by comparing terms (`../README.md`).
2. **"Lock-free" and "wait-free"** name only non-blocking kernels: the triple buffer, the ring's
   try operations, disjoint tiles, Treiber. Barriers, once, semaphores and event counts are
   *blocking primitives built without a mutex word*.
3. **The data plane.** Where a payload (ring slots, tile pixels, frames) lives in ordinary typed
   arrays, the proof covers the protocol, not the JavaScript that touches the bytes. Such a scenario
   gets two verified lanes, labelled so: "verified, payload in the heap" (fully covered, every
   access an SC atomic, slow) and "verified protocol, trusted data plane" (fast, the glue trusted).
   §1.3 has SC-DRF backwards: it says only that race-free programs behave as SC; that the data
   plane is race-free is the trusted discipline.
4. **Comparisons.** The racy L0 lanes report correctness counts only, never speed: V8 collapses
   those loops. The headline is idiomatic JavaScript with `Atomics` against the same algorithm
   verified (L2 against L3), and the gap is translator overhead, not a cost of the proof; L1 is
   context. Every row also reports CPU time per operation (`process.cpuUsage`).
5. **"Linearizable"** only where proved. `TreiberAtomic` is a logically atomic spec; the link to
   linearizability over histories is not formalised in Lean.
6. **Sharded counters** are proved by ParMap-style ownership plus a join, not by `Counter`'s
   `ccounter`, which is ghost fractions over one shared cell. The "≈250× for shards" figure comes
   from a plain loop V8 optimises away; quote no ratio for a translated lane before measuring it.
7. **Heap growth.** HeapLang never reuses a location and neither does the translator's heap. Size
   runs so that kernels do not run out of it (a Treiber node costs 4 cells and more; a kernel that
   allocates per operation fills 256 MB in seconds), and say so.
8. **Range invariants** close the 29-bit gap only for bounded words (the futex word, the triple
   buffer's `mid`). Counters, ring indices, `gen` and `seq` stay fail-stop; only a re-proof with
   modular indices fixes a ring.
9. **L4 is not "our Lean → wasm code".** It is HeapLang → C → wasm32 with its own heap and thread
   pool. LeanUI's own Lean code first appears in L5.
10. **Scope.** Iris proves safety and partial correctness only: no liveness, no weak memory, no
    performance. The translator and the runtimes are trusted.

Paths that start `iris/…` below refer to the research scratchpad the design was written in, which
no longer exists. The code now lives in this directory's parent (`../README.md`), and the evidence
the text cites is in `research/`.

---

Written 2026-11-20. This design combines four completed investigations:

- the JS catalogue: `iris/js-catalogue.md`, 17 mechanisms (A1–A17) and 25 patterns (B1–B25);
- the iris-lean audit: `iris/iris-audit.md`, 7 new proofs;
- the execution path: `iris/exec.md`, a HeapLang → JS / C11 / wasm translator, 37/37 tests on three backends, and a verified futex mutex;
- Lean threads in LeanUI's wasm64: `iris/lean-threads.md`.

All paths starting `iris/` are under
`<scratchpad>/`. Nothing in
`/home/user/leanui` was changed. Every timing quoted comes from a shared, busy 4-vCPU x86 cloud VM.
Read each one as a ratio within one run. These are CI-machine numbers and must be re-measured on the
reference Mac, which is ARM with a weaker memory model; several tests below are built for exactly
that difference.

---

## 0. The answer in brief

1. **Iris does not generate lock-free code, and it does not remove locks. The algorithm does.**
   - iris-lean proves properties of *HeapLang* programs: an untyped, sequentially consistent ML
     with unbounded integers and a heap that never reuses addresses.
   - What runs is a *translation* of the very same Lean `Val` the theorem is about. A translator
     written in Lean (from the exec investigation) emits JS over a `SharedArrayBuffer` with
     `Atomics`, or C11 `seq_cst`, which builds natively or to wasm with Emscripten pthreads. The
     translator is trusted, not verified.
   - The suite therefore compares the following, all running the same scenario on the same shared
     resource:
     - the usual JavaScript: a lock or messages;
     - a deliberately broken JavaScript variant;
     - the same lock-free algorithm written by hand in JS;
     - the verified kernel, translated to JS and to C → wasm;
     - later, LeanUI's own Lean → wasm64 code calling that kernel.
2. **"No locks" comes from four places:**
   - *ownership partitioning*: disjoint tiles, per-worker shards, the three slots of a triple buffer,
     the free and full halves of a ring;
   - *a single writer per word*: the indices of an SPSC ring, a seqlock's sequence number;
   - *one hardware read-modify-write*: claiming work with FAA, inserting once with CAS;
   - *immutability plus publication*: Treiber nodes, a configuration root swapped in one step.

   Separation logic states exactly these four. The proof certifies that they are enough, in every
   interleaving. That certificate is what justifies deleting the mutex.
3. **The large measured wins come from not sharing, not from replacing a lock with a CAS.** On 4
   workers:
   - one contended `Atomics.add`: 9–32 increments/µs;
   - sharded counters: 7,800–8,500/µs (catalogue §1.2);
   - an SPSC ring that publishes its index every 64 items is about 16× faster than one that
     publishes per item;
   - a triple buffer was the fastest snapshot method on both the writer and reader side, with 0 torn
     snapshots.

   Every one of these is an ownership protocol that iris-lean can prove. Those proofs, not CAS
   counters, are the flagship scenarios.
4. **Proved today, and runnable now:**
   - From upstream iris-lean `Lib`: SpinLock, TicketLock, RwSpinLock, the CAS counter, Spawn/Par
     and sequential Quicksort.
   - From the audit:
     - logically atomic FAA and CAS counters;
     - a closed two-thread theorem;
     - ParMap: fork-join over disjoint slices, with no synchronisation;
     - Treiber stack, both as a bag and linearizable;
     - a bounded SPSC ring with exact FIFO delivery, plus a closed client theorem.
   - From exec:
     - Drepper's futex mutex;
     - two futex hints proved to be no-ops;
     - the CAS word-encoding lemma.
   - All of these build with only the standard axioms, and the translated programs pass 37/37
     tests against a reference HeapLang interpreter on JS, native and wasm.
   - **Stage 1 of the plan needs no new proof.**
5. **New proofs that would pay off most:**
   - triple buffer ("60 fps without tearing");
   - FAA work claimer (dynamic tiles, each claimed exactly once);
   - once;
   - semaphore;
   - SPSC ring with batched publication and modular indices;
   - whole-program theorems for the benchmark drivers ("this run returns exactly t·k").
6. **What Iris can never give here:**
   - liveness: deadlock, lost wakeups (QED64's "HARDENING #52" is one), starvation, convoys,
     lock-freedom of CAS loops;
   - weak-memory reasoning: plain racy accesses, which are the fastest variants in two tests;
   - performance;
   - a verified translation;
   - anything about host APIs (`postMessage`, Web Locks, IndexedDB, OPFS) beyond stated
     hypotheses;
   - anything about worker death.

   One test is a scenario built so that the proof does *not* help (S11, the lost-wakeup hunt).
7. **Where JS's own tools, or plain Lean, are enough:**
   - one `Atomics.add`;
   - `postMessage` with transfer, which is zero-copy and checked by the browser;
   - Web Locks for coarse cross-tab exclusion;
   - Lean's purity for parallel bands;
   - plain Lean theorems for LeanUI's sequential update loop.

   Iris earns its keep only on lock-free ownership-transfer protocols whose bugs show up in stress
   tests only some of the time and only on some platforms. The injected ring bug read 2,504 stale
   items in one run and 8,796 in another, out of 2,000,000.
8. **Plan:** a new top-level `iris/` directory, separate like `vir/` and `qed64/`, with its own
   Lean 4.36.0 toolchain and its own `.lake`. It holds:
   - kernels, proofs, translator and runtimes;
   - a Node harness;
   - an opt-in, cross-origin-isolated page at `/iris/`;
   - its own CI job.

   Stage 1, four scenarios with existing proofs, is a working and honest demo in about 1–1.5 weeks.

---

## 1. What exactly is compared

### 1.1 The pipeline

```
  iris-lean (pinned 100ed29e, Lean 4.36.0)              iris/ in the repo (own toolchain, own .lake)
  ┌──────────────────────────────────────────┐          ┌────────────────────────────────────────────┐
  │ HeapLang Val  e.g. SpscRing.tryPush       │──proof──▶│ theorem tryPush_spec  (#print axioms =      │
  │ (a Lean constant)                         │          │   propext, Classical.choice, Quot.sound)    │
  └───────────────┬──────────────────────────┘          └────────────────────────────────────────────┘
                  │ the SAME constant (no re-typing, no parsing)
                  ▼
        Translate (Lean, ~590 lines, TRUSTED; tested 37/37 vs a reference interpreter)
          ├──▶ ES module: Int32Array over one SharedArrayBuffer, every heap op one Atomics op   (lane L3)
          └──▶ C11 __atomic seq_cst ──▶ emcc -pthread ──▶ wasm32 + Workers                     (lane L4)
                                     └─▶ (stage 3) linked into a LeanUI wasm64 app via FFI     (lane L5)
        manifest.json: program → kernel constants → theorem names → axioms → trusted items → stats
```

The kernel can never drift from the proof: `&SpinLock.acquire` in a driver *is* the `Val` that
`acquire_spec` is about (`exec.md` §1). The translation itself is the main trusted item (G1, §7.3).

### 1.2 The lanes of every scenario

| lane | what it is | verified? |
|---|---|---|
| **L0 js-broken** | the deliberately wrong JS a developer plausibly writes: a racy `x++`, publishing before writing, a missing fresh bit, an in-place filter across tiles, a check-then-act. Where possible, the same bug also exists as a HeapLang term, to produce a counterexample (§5) | refuted, where a counterexample exists |
| **L1 js-idiomatic** | what JS code usually does: a lock (a hand-written futex mutex; Web Locks in the browser) or messages (`postMessage` clone or transfer, a transferable stream) | no (host API) |
| **L2 js-lockfree** | the *same algorithm* as the verified kernel, written by hand the way a JS developer would. Sometimes it uses plain accesses where the author believes they are safe; these are the fast, unproved variants | no |
| **L3 hl→js** | the verified HeapLang kernel, translated to an ES module over a SAB, with `Atomics` for every access | yes (kernel), trusted translation |
| **L4 hl→wasm** | the same kernel, translated to C11 seq_cst and built with `emcc -pthread` to wasm32: "our Lean → wasm code" | yes (kernel), trusted translation and toolchain |
| **L5 lean-wasm64** (stage 3) | LeanUI-shaped. Either a LeanUI wasm64 instance per Worker (the current single-threaded runtime) calling the kernel through JS, or a threaded wasm64 build (the lean-threads route) linking the L4 C | yes (kernel); Lean's runtime is trusted |

L1 against L3/L4 is the pair the user asked for. L0 shows what goes wrong without care. L2 shows
that the proof is not where the speed comes from: L2 and L3 run the same algorithm.

### 1.3 Three planes, made explicit

1. **Control plane: the verified kernel.** Indices, flags, claims, the lock word: everything that
   decides who owns what. It is HeapLang, proved and translated, with every access a SeqCst atomic.
2. **Data plane: payload under ownership.** Pixels, audio samples, frame contents.
   - These live in ordinary typed arrays (`Float32Array`, `Uint8ClampedArray`) next to the
     kernel's heap.
   - Hand-written JS or Lean touches slot *i* only while the kernel's spec says it owns slot *i*.
     In the proof this ownership is the abstract resource parameter: `P i v` in `SpscRing`, `P x`
     in Treiber, `Tile i` in the claimer.
   - Plain accesses here are race-free by the JS/wasm SC-DRF theorem (Watt et al., PLDI 2020),
     provided the data plane keeps to that discipline. The discipline is **trusted**, but it is
     small and local: "touch only what you were handed".
   - Lean code that *computes* a tile or frame is pure, so Lean's semantics already rules out races
     inside it. Only the copy into the owned slot is an effect.
3. **Host plane: browser APIs.** `postMessage`, Web Locks, IndexedDB, OPFS. Their specs enter the
   proofs only as *hypotheses* of theorems (a `Lock` instance, a logically atomic update), never as
   global axioms.

### 1.4 What each result row shows

- **Correctness counters.** Lost updates, torn snapshots, stale or duplicated or out-of-order items,
  over-capacity entries, underruns, frames that go back in time, double claims. A green 0 is expected
  for every verified lane.
- **Throughput.** Ops/µs summed over workers, at W ∈ {1, 2, 4, cores, 2×cores}. On the 4-vCPU VM
  that is W = 1, 2, 4, 8; on the Mac, use its own core count.
- **Latency.** p50 / p99 / max (fine timers need isolation, which the page has).
- **Fairness.** min/max, and Jain's index (Σx)²/(n·Σx²).
- **Main thread.** The longest `requestAnimationFrame` gap while the lanes run.
- **Memory.** High-water mark (`performance.measureUserAgentSpecificMemory` on isolated pages;
  `process.memoryUsage` in Node).
- **Time to first violation** for broken lanes: how many ops pass before a stress test catches the bug.
- **A proof chip**, built from the manifest and never hand-written:
  - the theorem names;
  - one line saying what they say;
  - the scope: library function only, or the whole program;
  - `#print axioms`;
  - the trusted items (G1–G12) that apply;
  - "not proved: liveness, performance, ints beyond ±2^28 (trap), worker death".

---

## 2. Every JavaScript threading mechanism and its Lean/Iris counterpart

Labels:

- **[P]** provable today under SC;
- **[N]** needs a new but routine proof;
- **[R]** a research port (from Rocq Iris);
- **[L]** liveness, not provable with Iris WP;
- **[W]** needs a weak-memory logic iris-lean lacks;
- **[A]** a host API, usable only as a hypothesis;
- **[T]** trusted translation.

| # | JS mechanism | Lean/Iris counterpart | Verdict | Scenarios |
|---|---|---|---|---|
| A1 | Dedicated Worker | HeapLang `fork`. L3 runs it on a pool Worker over the SAB, L4 on a pthread. `worker.terminate()` cannot be modelled: HeapLang threads never die. Pool sizing and Worker start-up are runtime matters (G7) | counterpart [P]; death [L]; pool [T] | all; the kill test in S2 |
| A2 | SharedWorker | No shared memory with pages (it is a different agent cluster). Its state is a single-threaded actor, and a plain Lean proof of the actor's step function suffices, with no Iris. MessagePort delivery is [A] | **no Iris counterpart needed** | S17 (JS-only lane) |
| A3 | Service Worker | **None.** It cannot block, shares no memory with the page, and is killed when idle. Its hazards are about lifecycle (version skew, install/activate races), not memory. Concurrent `fetch` handlers interleave at `await`, which falls under A15 at most | none (honest) | — |
| A4 | Worklets | **AudioWorklet:** the consumer is `SpscRing.tryPop`. It has no loops, so it gets the wait-freedom certificate (§6). It uses no futex hints, because worklets cannot block; the translator will offer a "no-block" mode that rejects hints. Deadlines are [L] and measured. **PaintWorklet:** stateless, so pure Lean, nothing for Iris. **AnimationWorklet/LayoutWorklet:** never shipped or still experimental (probe: `CSS.animationWorklet` undefined in Chrome 157) | ring [P]; deadline [L]; scheduling [A] | S4 |
| A5 | `postMessage`, clone, Transferables | No HeapLang primitive. Two counterparts: (a) a **verified SAB channel** (the ring, Treiber, the claimer), whose specs *move ownership* (`P i v`), so "detach" happens at proof time with zero copies and zero checks at run time; (b) for clients of the real `postMessage`, a channel spec as a hypothesis. The right tool for that is Actris, which exists only in Rocq | (a) [P]; (b) [A] | S3, S4, S16 |
| A6 | MessageChannel / MessagePort | The transport is [A]. A request-id correlation table on top is a HeapLang map [N]. Synchronous-RPC deadlock (synckit style) is [L] | partial | S16 note |
| A7 | BroadcastChannel | A lossy fan-out with no acknowledgements and no ordering across senders. The only honest spec is "may drop", which proves nothing useful; it gives no mutual exclusion | **none useful** | S17 (JS-only lane) |
| A8 | SharedArrayBuffer + Atomics | **The core.** `Load/Store/CmpXchg/Xchg/FAA` map to `Atomics.load/store/compareExchange/exchange/add`. One-word CAS is exact by `EncodingProof.cas_word_iff`. `sub` is FAA of −n; `and/or/xor` are CAS loops. `wait`/`notify` are the proved no-op hints `futexWait`/`futexWake` (`exec/src/Exec/Hints.lean`). `waitAsync` lives only in the runtime. `pause` should become a further proved no-op hint. Plain typed-array access is allowed only for owned payload (§1.3), and is [W] whenever it races | [P] + [T]; racy plain [W] | S1–S16 |
| A9 | Web Locks | A *hypothesis* instance of iris-lean's `Lock` class (`newlock_spec`, `acquire`/`release`, `isLock`/`locked`), so client proofs are real. Shared mode corresponds to the `RwLock` interface. "Released when the context dies" is not expressible, so the kill test is measured only | [A] | S2, S10, S17 |
| A10 | wasm threads / Emscripten pthreads | L4: HeapLang → C11 seq_cst → `emcc -pthread`, 37/37 tests. L5: a LeanUI wasm64 threaded build plus the C kernel, prototyped by hand (`lean-threads.md` §5) | [P] + [T] | all; L5 in stage 3 |
| A11 | Node `worker_threads` | The harness host, the same as A1/A8. The libuv threadpool, `cluster` and `child_process` share no user memory, so there is **nothing to model** | host | Node harness |
| A12 | COOP/COEP (cross-origin isolation) | A deployment precondition of every SAB lane, with nothing to prove. Without isolation the page refuses and shows only the static proof table. This is why LeanUI ships single-threaded (`docs/TOOLCHAIN.md`) | precondition | page |
| A13 | OPFS sync access handles | An exclusive handle is a full points-to on a file seen as an array [A]. With `readwrite-unsafe`, a client locking protocol can be proved on top [N]. Not scheduled | [A]+[N] | (stage 4, optional) |
| A14 | IndexedDB, localStorage, Cache | A read-write transaction is a logically atomic update of the stores (iris-lean `atomic_update`) [A]. localStorage get/set are two separate atomic steps, so its read-modify-write is *exactly* the racy counter, and the proof fails in the same place: a teaching example | [A]; negative example | S17 |
| A15 | Single-thread async (await, microtasks, timers) | HeapLang `fork` over-approximates run-to-completion, so a proof carries over [P]. For LeanUI's sequential update loop a **plain Lean theorem is simpler** and enough. A "cooperative backend" (fork as a microtask, yields at loop back-edges) would run verified kernels on non-isolated pages; it is not built | [P], but plain Lean suffices | S12 |
| A16 | WebGPU / WebGL compute | **None.** The GPU memory model is out of scope. `mapAsync` ownership could be an [A] spec | none | — |
| A17 | Coming: shared structs with `Atomics.Mutex`/`Condition` (TC39 stage 2), main-thread `Atomics.wait`, wasm shared-everything threads, `Atomics.pause` (shipped in browsers, not Node 22) | `Atomics.Mutex` would be one more hypothesis `Lock` instance and a new L1 baseline once shipped. Main-thread wait would let hints run on the page. Shared-everything threads would be a future translator target. `pause` becomes a hint | watch | — |

---

## 3. The suite at a glance

The "B" column names the catalogue pattern. "Proof" says what exists (✓), what is new and routine
(N), and what is research (R).

| ID | Scenario (what real code does) | B | L0 broken / L1 idiomatic / L2 lock-free by hand | Verified kernel and theorems | Proof | "No lock" because | Stage |
|---|---|---|---|---|---|---|---|
| **S1** | Lost-update roulette: statistics, progress, FPS counters | B1 | `a[0]++` / futex mutex, Web Locks / `Atomics.add`, CAS loop, shards | `faaIncr_spec`, `casIncr_spec` (logically atomic), `Counter.incr` (`incr_mono_spec`), sharded `ccounter` (`incr_contrib_spec`), closed `twoIncr_adequate`; new whole-program `counterFaa_adequate t k` | ✓ (+N) | one hardware RMW; shards = ownership | 1 |
| **S2** | Lock zoo, plus kill and oversubscription | B2, B6, A9 | no lock / Web Locks, futex / spin, ticket, RW | `SpinLock`, `TicketLock`, `RwSpinLock`, `FutexMutex`: identical `Lock` spec | ✓ | n/a (locks): same proof, very different behaviour | 1 |
| **S3** | 60 fps without tearing: a simulation Worker feeds the renderer | B13, A5 | shared frame unsynchronised / clone per frame, transfer ping-pong, mutex / hand triple buffer | new `TripleBuffer.publish`/`fetch`: no tear, versions monotone, wait-free | N | three slots, ownership swapped by one `xchg` | 2 |
| **S4** | Glitch counter: SPSC audio ring into an AudioWorklet | B8, A4, B22 | publish-before-write, plain indices / `postMessage` per block, batched transfer / ringbuf.js style | `SpscRing.tryPush_spec`/`tryPop_spec`, `spscClient_adequate`; new batched and modular-index variants | ✓ (+N) | single writer per index; slot ownership | 1 (Node), 2 (worklet) |
| **S4b** | QED64's real stdin ring (`qed64/lane/core.js` lines 24–53) | B8, B4 | — | new HeapLang model of READ/WRITE/CLOSED/WAKE (bytes, mod cap): safety only | N | single writer per cursor | 3 |
| **S5** | Parallel image filter on disjoint tiles (blur; uneven Mandelbrot) | B10, A1 | in-place blur across tiles, double claims / `postMessage` bands (clone, transfer) / SAB static split, hand FAA claimer | `ParMap.pmap_spec` (static); new `Claim` (each tile exactly once); input halo read through a fractional points-to | ✓ + N | disjoint output, read-only input, one FAA per tile | 1 (static), 2 (claimer) |
| **S6** | Verified job pool / work queue | B9, B21 | untagged arena Treiber (ABA) / mutex queue, `postMessage` pool / tagged arena Treiber | `Treiber.push_spec`/`pop_spec`, `TreiberAtomic` (linearizable); nodes never reused. Arena with tags: R | ✓ / R | CAS on head; immutable nodes | 2 (✓), 4 (R) |
| **S7** | Barrier stencil: Life 512² in bands | B5 | barrier without generation / main-thread "done"/"go" / hand generation barrier | new `Barrier` whose ownership flips each phase (write own band ↔ read all bands) | N (hard) | phase-wise ownership exchange | 3 |
| **S8** | Pose record: seqlock vs triple buffer; the SC-assumption demo on ARM | B12, B23 | no sync, plain-data seqlock / mutex / plain-data seqlock | new SC `Seqlock` with Atomics data (ghost history); plain-data version is [W] | N; [W] | single writer plus validation | 3 |
| **S9** | Once: glyph atlas or lookup table | B7 | double-checked plain flag / main thread builds then posts / hand 3-state once | new `Once`: oneshot from Excl + Agree | N | CAS on uninit → running | 2 |
| **S10** | Semaphore: at most N decoders at once | B3 | check-then-decrement / Web Locks N slots / hand CAS permits + futex | new `Semaphore` (tokens) | N | CAS on the permit count | 2 |
| **S11** | Lost-wakeup hunt: the scenario where the proof does **not** help | B4 | notify before store, wrong word, notify(1) / — / epoch event count | `EventCount` safety [N]; no lost wakeup is [L] | N + [L] | — | 2 |
| **S12** | Stale search results (async on one thread) | B24, A15 | naive `await` / AbortController / sequence guard | plain Lean theorem about a LeanUI `update`; HeapLang fork model as a comparison | N | a monotone sequence number | 3 |
| **S13** | Insert-only intern table / glyph cache | B20 | check-then-insert / mutex map, per-worker maps merged / hand CAS table | new `InternTable`: ghost map with Agree entries | N | CAS empty → key; entries immutable | 3 |
| **S14** | Reference-counted buffer pool | B15 | plain decrement / main-thread pool / `Atomics.sub` refcount | new `RcPool`: counting fractions plus cancellable invariant, so the last release regains full ownership | N | the last decrement owns the buffer | 3 |
| **S15** | Cancellation flag | B16 | plain poll / `terminate()`, AbortSignal via message / Atomics flag | new `Cancel`: monotone flag, no output after cancel is observed | N (small) | one monotone bit | 2 |
| **S16** | Flood and backpressure | B17, A5, A6 | unbounded `postMessage` / transferable stream / unverified ring | `SpscRing` capacity invariant | ✓ | bounded slots | 2 |
| **S17** | Cross-tab leader and IndexedDB counter (N tabs) | B18, B19, A2, A7, A9, A14 | localStorage election, split transactions / Web Locks, single transaction / SharedWorker | client proofs over hypotheses: Web Locks as `Lock`, IndexedDB transaction as an atomic update | N + [A] | the host does the locking | 4 (optional) |
| **S18** | Hot configuration swap (RCU-style) | B14 | in-place mutation / clone to all / pointer swap with arena reuse | new `Publish`: root `xchg`, persistent nodes. Reclamation: R (hazard pointers and epochs, kaist-cp/smr-verification) | N; R | immutability plus one swap | 4 |
| **S19** | Research corner: atomic snapshot (prophecies), Chase-Lev work stealing, Vyukov MPMC, Herlihy-Wing | B11, B23, B9 | — | ports from Rocq | R | — | 4 |
| **S20** | Mutation tournament across all kernels | B25 | — | all | — | — | 2 onward |

Coverage check:

- **Patterns.** Every pattern B1–B25 appears above. B6 is inside S2; B21 is in S6 and in the runtime
  allocator note; B22 is a fault injected into S4.
- **Mechanisms.** Every mechanism A1–A17 has a row in §2. Those with no counterpart (A3, A7, A16)
  say why.

---

## 4. Scenario cards

Each card gives:

- **JS:** the JavaScript lanes;
- **Kernel:** the verified HeapLang program, as a sketch;
- **Spec:** what is proved and what is not;
- **Runs:** the targets;
- **Measure:** what is measured;
- **Faults:** the fault injection and broken variant;
- **No lock:** where the absence of locks comes from;
- **Expect:** the honest prediction, with prior data where it exists.

### S1. Lost-update roulette (B1)

- **JS:**
  - L0 `i32[0] = i32[0] + 1`;
  - L1 a hand-written Drepper futex mutex around `x++` in Node, plus Web Locks in the browser
    (each call is a promise round trip, so only at coarse granularity);
  - L2 `Atomics.add`, a `compareExchange` loop, padded per-worker shards, and "count locally,
    publish once".
- **Kernel:**
  - `faaIncr := λ l, faa(l, #1)`;
  - `Counter.incr`, iris-lean's CAS loop (`Lib/Counter.lean` lines 29–35);
  - a sharded counter with one cell per worker, summed at the join.
- **Spec:**
  - `faaIncr_spec`/`casIncr_spec` are logically atomic:
    `<<{∀∀ n, l ↦ #n}>> incr #l <<{l ↦ #(n+1) | RET #n}>>` (`iris-audit/proofs/AtomicCounter.lean`).
  - `twoIncr_adequate` is a closed theorem: every interleaving of two FAA threads returns 2.
  - The contribution spec (`ccounter`, `incr_contrib_spec`, `read_contrib_spec_1`) is the proof
    that sharded counting adds up.
  - **New (stage 2):** `counterFaa_adequate t k` and `counterCas_adequate t k`, closed theorems for
    the very benchmark drivers (`rep`, `onThreads`, `Spawn.join_spec`), saying the result is
    exactly t·k.
  - With these the page can show "theorem predicts 800,000" next to the observed value.
  - **Not proved:** fairness, termination of the CAS loop (it is lock-free, not wait-free), and
    anything about Int32.
- **Runs:** L3 and L4 for FAA, CAS and shards. L5 (stage 3) adds the Lean counters measured in
  `lean-threads.md` §4.5, in a threaded wasm64 build:
  - `IO.Ref` get then set (L0, loses updates);
  - `IO.Ref.modify` (a spin lock in disguise);
  - `Std.Mutex`;
  - C11 `faaIncr` / `casIncr`;
  - per-task shards.
- **Measure:** lost updates, increments/µs at W = 1…8, Jain's index, and time to first lost update.
- **Faults:**
  - schedule fuzzing (§5.3);
  - a **wrap start** at 2^31−10 for JS lanes and at 2^28−10 for translated lanes;
  - a HeapLang `counterRacy` that the reference interpreter refutes (it lost 31/33/32 of 45 updates
    under three schedules, `exec.md` §4).
- **No lock:** one hardware RMW. Better still, no sharing at all: shards.
- **Expect:**
  - L0 loses 43–71% of updates (catalogue §1.2) and about 50% in every backend (`exec.md` §5).
  - L3 FAA runs at 0.96–1.3× hand-written JS.
  - At W=4 the CAS loop (5–31/µs) is no better than a futex mutex (12–13/µs).
  - Shards are about 250× faster than any shared counter, and the proof of the shards is the
    contribution spec.
  - At the wrap start, HeapLang's unbounded `Int` meets JS Int32 wrap and the translator's 29-bit
    trap: the JS lanes silently wrap, while L3/L4 **trap (fail-stop)**. The proof says nothing about
    either.

### S2. Lock zoo under oversubscription, plus the kill test (B2, B6, A9)

- **JS:**
  - L0: no lock, with a two-word invariant `a == b` checked by readers;
  - L1: Web Locks (browser) and a hand-written futex mutex;
  - L2: hand-written spin, ticket and RW spin locks.
- **Kernel:** `SpinLock`, `TicketLock`, `RwSpinLock` (upstream `Lib`) and `FutexMutex` (exec, with
  futex hints), each guarding `a ← !a+1; b ← !b+1`.
- **Spec:** every one is an instance of the `Lock` (or `RwLock`) interface, so `acquire` gives
  `locked γ ∗ R`. Mutual exclusion is ownership of `R`, so `a == b` always holds inside.
  **All four are proved equally safe. Nothing is proved about fairness, FIFO order, convoys or
  progress.**
- **Runs:** L3 and L4. The Web Locks lane runs only in the browser (Node 22 lacks `navigator.locks`).
- **Measure:** throughput, Jain's index, p99 acquire latency, W = 1…2×cores. Then:
  - **The kill test:** `worker.terminate()` while the lock is held. SAB locks (proved or not) hang
    forever, and the harness measures detection through `wait` timeouts. Web Locks release.
  - **Priority inversion:** an AudioWorklet that needs data guarded by a lock held by a slow Worker,
    counted as glitches.
- **Faults:** fuzzing; the kill test; oversubscription.
- **No lock:** none. This scenario exists to show "what the proof does not say".
- **Expect:**
  - The ticket lock collapses once threads outnumber cores, in every implementation: about 0
    increments/µs at W=6 (catalogue); 16k operations taking 3.1 s in JS and 20.6 s in HL→JS with 8
    threads on 4 vCPUs (`exec.md` §5).
  - The spin lock is unfair (fairness 0.17–0.49).
  - The verified futex mutex is the best translated lock (4× faster than `SpinLock` at W=4, 8× at
    W=8), yet still about 2× slower than the same algorithm by hand in JS. Part of that gap is the
    SeqCst accesses inside the critical section: hand-written JS with an all-SC body took 7.5 ms
    against 4.4 ms with a plain body.

### S3. "60 fps without tearing": the triple buffer (B13; the flagship new proof)

- **JS:**
  - L0: the simulation writes the shared frame in place while the renderer reads it (9.34% torn in
    the catalogue's 16-word probe);
  - L1: a structured clone per frame, transfer ping-pong of two ArrayBuffers, or a futex mutex;
  - L2: a hand triple buffer with `Atomics.exchange`.
- **Kernel** (sketch). Three payload slots. The cell `mid` holds slot + 4·fresh. The writer's and
  reader's own slot indices are thread-owned refs.
  ```
  publish := λ tb wref,  let old := xchg(mid tb, !wref + #4) in wref ← old % #4
  fetch   := λ tb rref,  if #4 ≤ !(mid tb) then (let old := xchg(mid tb, !rref) in rref ← old % #4; #true)
                         else #false
  ```
- **Spec:**
  - The invariant owns exactly the middle slot's payload. The writer token owns its slot; the
    reader token owns its slot, which holds frame version v.
  - `publish` hands over a complete frame and records its version in a ghost max-nat.
  - `fetch` returns a frame with version v' ≥ v, and v' was published at some point. While it holds
    the slot, the reader owns the **whole** frame exclusively.
  - That gives **no torn frame and no time travel**, as a separation-logic consequence. The writer
    can never touch a slot the reader holds.
  - Both operations are loop-free, so they get the **wait-freedom certificate** (§6.3).
  - **Not proved:** that the reader sees *every* frame (it may skip; that is by design), and the
    frame rate.
- **Runs:**
  - L3 and L4 for the control plane.
  - The payload lives in three `Float32Array`/`Uint8ClampedArray` slots in the data plane (§1.3).
  - LeanUI variant (stage 2–3): the simulation is a Lean Life 512² stepping in a Worker, through a
    single-threaded wasm64 instance per Worker. That instance copies its board into the owned slot.
- **Measure:**
  - torn frames: each frame carries a checksum stripe, and the page draws torn frames visibly;
  - frames shown twice, frames skipped, and staleness in versions;
  - main-thread ms per frame and writer and reader rates.
- **Faults:** jank on the main thread (50 ms), a GC storm in the producer, fuzzing.
- **Broken variant (proof rejects):** drop the fresh bit, so the reader always swaps. The reader can
  then swap its *older* frame back in and show a frame older than the last. The monotone-version
  postcondition cannot be re-established, and Explore (§5.2) finds the trace. Stress shows it as
  "version went backwards" events.
- **No lock:** three buffers, and ownership passes by one `xchg`.
- **Expect:** in the catalogue probe the triple buffer was the fastest of every method (7.75 writer
  and 7.86 reader snapshots per µs, 0 torn), against 4.37 / 1.79 for a futex mutex. The proof
  certifies the best variant, not the slowest, and the payload copies dominate the cost.

### S4. Glitch counter: an SPSC audio ring (B8, A4)

- **JS:**
  - L0: "publish before write" (stale data in 2,504 and 8,796 of 2 M items in two runs), and
    plain-index publication (racy, see below);
  - L1: one `postMessage` per 128-frame block, or batched transfer;
  - L2: a ringbuf.js-style ring with Atomics indices and plain slots.
- **Kernel:** `SpscRing.tryPush`/`tryPop` (`iris-audit/proofs/SpscRing.lean`): two monotone
  indices, slot `i % n`, no CAS. The new variants:
  - **batched publication**, where the producer caches the consumer's index and publishes its own
    every k slots (the same invariant; in the catalogue's hand-written version this was 82.9 against
    about 5 items/µs);
  - **modular indices** (see the trap below).
- **Spec:**
  - The i-th push hands over `P i v`, and the i-th pop receives exactly `P i v`.
  - With `P i v := ⌜v = msgs[i]⌝` this is FIFO with nothing lost and nothing duplicated. The closed
    `spscClient_adequate` proves it for a two-message client.
  - With `P i v :=` ownership of payload block i, it is a zero-copy hand-off of audio blocks.
  - `tryPop` is loop-free, so it is wait-free and safe for the real-time thread.
  - **Not proved:** underrun-freedom (a deadline [L]) and progress of a retrying producer.
- **Runs:**
  - Stage 1: Node, with a 2.67 ms tick standing in for the worklet.
  - Stage 2: an `AudioWorkletProcessor` importing the L3 module. A SAB reaches the worklet through
    its port on an isolated page; the translator's no-block mode is required there.
  - Sound: a sine wave is played (it needs a click), so underruns are *audible* as clicks.
- **Measure:**
  - underruns per minute;
  - out-of-order or stale blocks, detected by a sequence-number header word in each slot;
  - p99 latency from producer to sink;
  - items/µs.
- **Faults:**
  - main-thread jank, GC pressure, a producer stall;
  - **memory growth mid-run** (B22): the translator must re-derive views;
  - the **index-wrap start**.
- **The honest trap:** the translator's integers are 29-bit, so the indices **trap after 2^28 ≈ 268 M
  pushes**:
  - one slot per sample at 48 kHz: ≈ 93 minutes;
  - one slot per 128-frame block: ≈ 8.3 days.

  Hand-written JS with Int32 wraps after 2^31: 12.4 h per sample, 66 days per block. It stays
  correct only if `t − h` is computed modulo 2^32 (`(t - h) | 0`).

  The fix is a **re-proof with modular indices** (stage 2). The QED64 ring is modular already.
- **The ARM test:** the variant that publishes indices with plain stores (L2-fast) ran about 4×
  faster than the proved one and passed on x86 TSO (`iris-audit.md` §8). Under the JS model it is a
  data race with no happens-before from slot write to slot read. Run it on the Mac. No SC proof can
  cover it [W].
- **S4b, QED64's ring:** model the producer of `qed64/lane/core.js` and the consumer protocol (byte
  cursors mod cap, `free = (r − w − 1 + cap) % cap`, CLOSED, WAKE) in HeapLang, and prove safety: no
  byte read before it is written, nothing overwritten before it is read.
  - The real consumer is C++ inside `lean.wasm` (QED64 patch 0031), so the proof covers the
    *protocol design*, not that code.
  - The lost wakeup (#52) stays [L]; the once-a-second kick stays.

### S5. Disjoint tiles: a parallel image filter with zero synchronisation (B10, A1)

- **JS:**
  - L0, two broken variants:
    - **an in-place blur across tile boundaries**: a tile reads halo pixels that its neighbour may
      already have overwritten. The output checksum changes from run to run, and the page shows a
      heat map of the differences.
    - **a load-then-store claimer**: two workers claim the same tile, detected by per-tile claim
      counters.
  - L1: the main thread posts bands, by clone or by transfer, and gathers the results.
  - L2: a SAB with a static split, and a hand-written `Atomics.add` claimer.
- **Kernel:**
  - static: `ParMap.pmap` (recursive halving with `par`);
  - dynamic: new `Claim`:
    ```
    work := rec loop next n f := let i := faa(next, #1) in if i < n then (f i; loop next n f) else #()
    ```
- **Spec:**
  - `pmap_spec`: `a ↦∗ zs` becomes `a ↦∗ map g zs` with **no invariant, no ghost state and no
    atomics**. Disjointness alone, split at each `par`.
  - `Claim` (new): the invariant holds `∃ k, next ↦ #k ∗ [∗ i ∈ [k,n)] Tile i ∗ ghost(claimed)`.
    The FAA that returns i < n hands over `Tile i`. Each worker returns its claimed set, and the
    sets are disjoint and cover [0, n). So **every tile is processed exactly once**.
  - Input halos are shared read-only through fractional points-to: `in ↦∗{q}`.
  - In-place filtering is not provable at all, because it would need ownership of the neighbour's
    pixels. That is the L0 bug, rejected *by construction*.
  - Bonus: each worker's own claim loop runs at most n+1 iterations (`next` increases strictly), so
    it is wait-free. Proving that needs `twp` and HeapLang total adequacy, which iris-lean lacks
    today (§6).
- **Runs:**
  - L3/L4 for the claimer. The pixels are in the data plane.
  - L5 (stage 3), two variants:
    - (a) one LeanUI wasm64 instance per Worker runs the editor's blur on the tiles it claims,
      copying tiles in and out. This needs no threaded runtime and works today.
    - (b) a threaded wasm64 build with Lean tasks over pure bands (`lean-threads.md` §4.3: 1.6–2.2×
      on 4 busy threads with mimalloc, about 1× with dlmalloc).
- **Measure:** makespan, idle time per worker, imbalance (max/mean), speed-up at W = 1…8, run-to-run
  checksum variance. Use uneven Mandelbrot tiles to make dynamic claiming matter.
- **No lock:** separation logic. Writes are disjoint, input is read-only, and there is one FAA per
  tile.
- **Expect:**
  - For uniform work, a static split ≈ the claimer ≈ `postMessage` with transfer (a 64 MiB transfer
    costs 0.065 ms). **JS's own transfer already gives zero copies and no locks**, so the SAB
    version wins only on load balance and per-tile message latency (about 33 µs per round trip).
  - In Lean, ParMap's shared buffer was not meaningfully faster than pure bands plus concatenation
    (`lean-threads.md` §4.3). Purity already makes the Lean side race-free.

### S6. A verified job pool and work queue (B9, B21)

- **JS:**
  - L0: a Treiber free list over a SAB node arena with index reuse and **no tags**, with a delay
    injected between reading `head`/`next` and the CAS. ABA corrupts the list: lost or duplicated
    jobs, cycles.
  - L1: a mutex-protected array queue, or a `postMessage` worker pool (1,000 tiny tasks: 4.9 ms).
  - L2: the tagged arena Treiber.
- **Kernel:** `Treiber.push`/`pop` (`iris-audit`), with nodes as fresh cells that are never reused.
- **Spec:**
  - `push_spec`/`pop_spec` move a job's resource `P x` between threads.
  - `TreiberAtomic` gives a linearizable LIFO spec against an abstract list.
  - **The honest gap:** the verified version leaks nodes (4 cells per node, never freed), and that
    is precisely why it has no ABA. The arena version that production code runs is a *different
    program*.
  - Stage 4: `ArenaTreiber` models the arena and tags explicitly in HeapLang. The proof must fail
    for untagged nodes, because ABA is then visible in the model. With *bounded* tags (29-bit words,
    so roughly 13-bit tag plus 16-bit index) it also fails in general, because tags wrap. True
    safety needs hazard pointers or epochs (Rocq proofs exist; R).
- **Runs:** L3/L4. Exec measured the Treiber stack at 1.12× hand-written JS.
- **Measure:** jobs per µs, lost or duplicated jobs, list corruption, memory high-water.
- **Expect:** parity in speed, and a clear lesson about reclamation.

The runtime's own bump allocator (TLAB refill by `Atomics.add`) is a Claim-style FAA allocator. It
could be written in HeapLang and verified (closing part of G8).

### S7. Barrier stencil on Life 512² (B5)

- **JS:**
  - L0: a counter barrier without a generation or sense reversal. A fast thread re-enters the next
    phase before the reset, causing premature release (it reads half-updated bands) or deadlock.
  - L1: workers post "done", and the main thread posts "go" (two message latencies per generation).
  - L2: a hand-written generation barrier with futex waits.
- **Kernel:** `arrive := let g := !gen; let c := faa(count, #1); if c = n−1 then (count ← 0; gen ← g+1; wake) else wait-while(!gen = g)`.
- **Spec (new, the hardest routine proof here):** the barrier *exchanges resources*.
  - Before phase p, worker j owns `next[j]` exclusively and `cur[all]` at fraction 1/n.
  - It deposits both on arrival. The last arriver redistributes them as `cur[j]` exclusive and
    `next[all]` at 1/n under generation p+1. Each waiter, on seeing the new generation, takes its
    share through a token.
  - Result: reads never see a half-updated band, proved.
  - **Not proved:** that the barrier releases at all [L].
- **Runs:** L3/L4 with futex hints. Lean lane (stage 3): Life bands computed by Lean instances.
  LeanUI's own 40×25 board gets *slower* with any threading (0.21–0.65× at 4 tasks,
  `lean-threads.md` §4.3), so use 512².
- **Measure:** time per generation, barrier overhead against messages, effect of a straggler, board
  hash compared with the sequential reference.

### S8. Pose record: seqlock against triple buffer, the SC-assumption demonstration (B12)

- **JS:**
  - L0: no synchronisation (9.34% torn);
  - L1: a futex mutex;
  - L2: a seqlock with *plain* data (1.01 snapshots/µs on the reader side, 0 torn on x86).
- **Kernel:** an SC seqlock with Atomics data.
- **Spec (new):**
  - The invariant ties each data word to a ghost history: "if seq is even, the word equals
    `hist[seq/2]`".
  - The reader keeps a monotone lower bound s ≥ s1 from each read. Once s2 = s1, every read happened
    at seq = s1, so the snapshot is `hist[s1/2]`.
  - No prophecy is needed.
  - The plain-data version is [W] and cannot be stated: in the JS model, plain reads may move past
    the second `Atomics.load(seq)` (Boehm's seqlock problem).
- **Measure:** torn snapshots accepted, retries, reader rate, staleness. Run with K = 2, 16, 256
  words, **on x86 and on the Mac**.
- **Expect, honestly:** the verified seqlock is the *slow* one (0.10 against 1.01 snapshots/µs). The
  plain-data seqlock may accept torn snapshots on ARM that the SC proof says are impossible, because
  the proof is about a different memory model. The lesson is to pick a structure whose fast form is
  within the logic's reach: the triple buffer (S3) is both verifiable and fastest.

### S9. Once: a glyph atlas built once (B7)

- **JS:**
  - L0: double-checked locking with a plain "ready" flag stored before the table is complete
    (detected by a checksum), plus a load-then-store "who initialises" check (two initialisers);
  - L1: the main thread builds the table and posts it (a 1 MiB clone to each of 8 workers);
  - L2: a hand-written 3-state once with `Atomics.wait`.
- **Kernel:** CAS `0 → 1`, initialise, store 2, `futexWake`. Others wait while the state is 1.
- **Spec (new):**
  - `init` runs at most once.
  - Every caller returns the *same* table, through an Agree-based oneshot. Spawn's protocol is
    nearly this already.
  - **Not proved:** progress if the initialiser dies [L].
- **Measure:** count of `init` runs, first-use latency per worker. Kill test: terminate the
  initialiser in state 1 and count hangs. The mitigation, a timed wait plus an owner heartbeat, is
  not verified.

### S10. Semaphore: at most N concurrent decoders (B3)

- **JS:**
  - L0: load, test, store (more than N inside);
  - L1: Web Locks with N named slots, or a token queue on the main thread;
  - L2: hand-written CAS permits plus futex.
- **Kernel:** `acquire` = CAS n → n−1 if n > 0, else `futexWait`; `release` = FAA +1, then `futexWake`.
- **Spec (new):** N tokens; `acquire` yields a token and its resource. The harness's atomic
  in-section counter never exceeds N, as a corollary.
- **Mutation:** a release without an acquire. The proof fails, because a token is missing.
- **Measure:** maximum simultaneously inside, throughput against N, p99 wait.

### S11. Lost-wakeup hunt: the scenario where the proof does not help (B4)

- **JS:** an epoch event count:
  - the waiter reads the epoch, re-checks its condition, then calls `Atomics.wait(epoch, seen)`;
  - the notifier changes the state, increments the epoch, then notifies.
- **Mutants:** notify before the store; the wrong word; `notify(…, 1)` with several waiters.
- **Kernel and spec:** the safety of the event count is provable [N]. **Iris accepts all three
  mutants**, because the hints are proved no-ops, so a misplaced notify changes no safety fact.
  Lost wakeups are liveness [L].
- **Measure:** watchdog rescues per 10^6 sleep/wake cycles, with each waiter's wait bounded by a
  timeout. With exec's 20 ms timed waits a lost wakeup turns into latency rather than a hang. That
  design choice, not the proof, is what makes the system robust. QED64's once-a-second kick
  ("HARDENING #52", `qed64/README.md`) is the same idea.

### S12. Stale search results: async on one thread (B24, A15)

- **JS:**
  - L0: naive `await fetch` then render;
  - L1: an AbortController per request;
  - L2: a request sequence number that ignores older responses.
- **Lean:** in a LeanUI app the responses arrive as `Msg`s handled by a sequential `update`.
- **Spec:** a **plain Lean theorem**, with no Iris: for every ordering of responses, the rendered
  result belongs to the latest query. A HeapLang model (one fork per request, the guard as a
  monotone counter) is included only to show that Iris can say the same thing, at much greater
  cost.
- **Measure:** stale renders, time to the correct display, under random latency.

### S13. Insert-only intern table / glyph cache (B20)

- **JS:**
  - L0: check-then-insert with plain stores (duplicate ids);
  - L1: a mutex around the map, or per-worker maps merged at the end (often the fastest);
  - L2: a hand-written CAS table.
- **Kernel:** open addressing. CAS the key slot from empty to the key, then publish the value
  through a per-slot state word.
- **Spec (new):** a ghost map whose entries never change once written (Agree). Lookups never see a
  half-written entry, and each key gets exactly one id.
- **Honest limit:** HeapLang has no strings, so keys are ints. For example, (fontId, codepoint)
  packed into 28 bits is realistic for a glyph cache. String interning would need hashing outside
  the proof, and collisions would then be outside it too.

### S14. Reference-counted buffer pool (B15)

- **JS:**
  - L0: plain decrements (double frees and leaks, counted by poisoning freed buffers);
  - L1: a pool owned by the main thread, with messages;
  - L2: an `Atomics.sub` refcount.
- **Spec (new):** counting fractions plus a cancellable invariant. The release whose decrement
  returns 1 regains *full* ownership and returns the buffer to the free list.
- **Honest note:** HeapLang never frees here. "Free" means "give back to a verified pool with full
  ownership", so reuse is modelled honestly at the pool level. A lock-free pool free list brings S6's
  ABA question back.

### S15. Cancellation flag (B16)

- **JS:**
  - L0: a plain polled flag (the JS model allows the load to be hoisted out of the loop; V8 did not
    do it in the probe);
  - L1: `terminate()`, which loses state and can leave locks held, or an AbortSignal sent by
    message, which is seen only when the worker yields;
  - L2: an `Atomics.load` poll every k iterations.
- **Spec (new, small):** once the worker observes the cancel, it publishes no further output (the
  output counter is frozen, with monotone ghost state).
- **Measure:** latency from cancel to stop against the poll interval, and the cost of polling.

### S16. Flood: unbounded messages against a bounded verified ring (B17)

- **JS:**
  - L0/L1: `postMessage` from a producer 10× faster than the consumer (the heap grows with no
    bound);
  - L1: a transferable stream with a `highWaterMark`.
- **Kernel:** `SpscRing`, whose capacity invariant is part of the existing proof.
- **Measure:** memory high-water, end-to-end p99.

### S17. Cross-tab leader election and an IndexedDB counter (B18, B19; optional, stage 4)

- **Setup:** Playwright with N tabs.
- **Election lanes:**
  - L0: a localStorage timestamp election (two leaders at once);
  - L1: Web Locks "hold forever" plus a BroadcastChannel heartbeat;
  - a SharedWorker coordinator.
- **Counter lanes:** read and write in separate transactions (lost updates) against a single
  read-write transaction, plus an injected `await` inside the transaction
  (`TransactionInactiveError`).
- **Iris:** "at most one leader" is a corollary of a *hypothesis* that Web Locks satisfy `Lock`.
  The counter's correctness follows from a hypothesis that a transaction is an atomic update. The
  client proofs are real, but everything rests on the hypotheses. Failover time is [L] and only
  measured.

### S18. Hot configuration swap, RCU-style (B14; stage 4)

- **Kernel:** the writer builds an immutable configuration tree in fresh cells and publishes the
  root with one `xchg`. Readers traverse persistent nodes (`↦□`).
- **Spec:** publication only.
- **Honest note:** the old versions are garbage that the translator's heap never frees (a leak).
  Reclamation (hazard pointers, epochs) is a research port (Jung et al., OOPSLA 2023; RCU under weak
  memory, PLDI 2025).

### S19. Research corner (stage 4)

- an atomic snapshot by double collect, with prophecies (iris-lean has `newProph`/`resolve` lemmas
  but no tactics);
- the Chase-Lev deque (arXiv 2309.03642; Allain and Scherer, PLDI 2026);
- Vyukov's bounded MPMC queue;
- the Herlihy-Wing queue.

Each would be weeks of porting. In the uneven-tile test, the FAA claimer (S5) will probably beat
work stealing at W=4.

### S20. Mutation tournament (B25)

Apply one set of mutations to every kernel:

- reorder publish and write;
- drop a CAS check;
- turn an atomic access plain (JS lanes only; the HeapLang translation emits no plain shared
  accesses);
- drop a notify;
- remove the fresh bit or an ABA tag;
- use a release without an acquire;
- notify the wrong word.

For each mutant, record:

| column | meaning |
|---|---|
| proof | does the proof still check? Expected to fail for every SC-safety mutant and to *pass* for liveness-only mutants (S11) |
| refuted | does Explore find a counterexample in the HeapLang semantics (deterministic, bounded)? |
| x86 stress | is it caught by a 10 s fuzzed stress run, and after how many ops? |
| ARM stress | the same on the Mac |

This table is the single most honest picture of what the proofs buy.

---

## 5. Broken variants: making "the proof would have rejected it" concrete

A failed proof attempt alone is weak evidence: the proof script might just be brittle. Each broken
variant therefore gets up to four independent pieces of evidence.

### 5.1 The proof does not go through

The mutant's HeapLang term is checked against the original proof script. The failing step is
recorded (for publish-before-write, the invariant cannot be closed after the index store).

### 5.2 A counterexample in the same semantics (Explore)

`Explore.lean` extends exec's reference interpreter (`exec/src/Exec/Interp.lean`, which reuses
iris-lean's `Exp.subst`, `BinOp.eval`, `State` and `Loc.fresh`) from random schedules to **bounded
exhaustive** exploration: depth-first search over thread choices, with state hashing, for small
instances (t = 2, k = 1–2, ring capacity 2).

- For a broken kernel it prints the violating interleaving. The racy counter already loses updates
  in the interpreter under random schedules.
- For verified kernels it is a second, independent bounded check of the theorem on small
  instances. It also cross-checks the interpreter itself.

### 5.3 A refutation theorem in Lean (stage 3)

The trace is replayed as a derivation of iris-lean's own thread-pool step relation, which gives
`¬ adequate .NotStuck racy σ (· = #2)`. Iris's adequacy theorem is sound, so **no Iris proof of
that spec can exist**. That is the precise meaning of "the proof would have rejected it". It
requires a small tactic that decomposes evaluation contexts.

### 5.4 Stress and fuzzing (L0 in JS, and L3 built from the HeapLang mutant)

**Fuzz-mode translation.** The translator inserts busy-delays before shared heap operations in the
*generated code*. They touch no memory, so they only change the schedule, and every schedule is
already covered by adequacy. Fuzzing therefore *cannot* change a verified lane's results, while it
multiplies the failure rate of broken lanes. That asymmetry is a demonstrable property in its own
right.

The other faults:

- `worker.terminate()` mid-operation;
- 50 ms main-thread jank;
- GC storms;
- memory growth;
- wrap starts.

**Caveat:** stress results are probabilistic. Without a start barrier the racy counter came out
"correct" because the workers did not overlap (`iris-audit/js/run1.txt`). The ticket-lock convoy is
bimodal. Results also differ on ARM.

---

## 6. Taking iris-lean to its limit

These are ranked by value per unit of effort. Effort figures are estimates for a person fluent in
Iris. The agent wall-clock figures in the audit (2–7 min per proof) understate human effort a great
deal; the audit's own guidance is hours to a day per structure.

1. **Whole-program closed theorems for every benchmark driver** (`rep`, `onThreads`, `spawnN`,
   `joinAll`, using `Spawn.join_spec` and `ccounter`). The page can then print "theorem predicts X"
   next to the observed result. *Days. Stage 2.*
2. **Counterexamples and refutations for broken variants** (§5.2, §5.3). *Explore: days. Refutation
   tactic: 1–3 days. Stages 2–3.*
3. **A wait-freedom certificate for loop-free operations.**
   - A syntactic check over the very `Val`: no `rec`, and no calls to unknown closures.
   - HeapLang has no blocking, and adequacy rules out getting stuck, so such an operation finishes
     within a bounded number of its *own* steps whatever other threads do.
   - It is recorded in the manifest and shown on the chip ("wait-free (syntactic)").
   - It applies to `tryPush`/`tryPop`, `publish`/`fetch`, `faaIncr`, the seqlock writer and the
     claim step.
   - It says nothing about CAS loops (lock-free at best, unprovable) or spin locks.
   - *A day. Stage 2.*
4. **Range invariants that close G3 per kernel**, by adding `⌜|n| < 2^28⌝` to invariants. FutexMutex
   gets this for free ({0,1,2}). Plus **re-proving the SPSC ring with modular indices**, so it runs
   forever instead of trapping after 2^28 pushes. *Days. Stage 2.*
5. **Logically atomic (linearizable) specs for every kernel**, following the `TreiberAtomic` and
   `AtomicCounter` pattern, so kernels compose (for example a ring of claim tickets). *Days each.
   Stages 2–3.*
6. **Proved no-op intrinsics:** `futexWait`/`futexWake` exist; add `spinPause` (mapped to
   `Atomics.pause`) and a "no-block" translation mode for worklets. *Hours. Stage 1–2.*
7. **Data-race freedom from adequacy: the biggest performance lever.**
   - Add λRust-style non-atomic loads and stores to a fork of HeapLang ("HeapLang-NA"): a
     non-atomic write takes two steps, and any concurrent access to a cell being written is stuck.
   - The existing not-stuck adequacy then *proves* data-race freedom. JS and wasm SC-DRF then
     justify emitting **plain** accesses for owned cells: critical-section bodies, ring slots, frame
     payloads.
   - Measured headroom: a spin lock with a plain body at 4.4 ms against 7.5 ms all-SC (1.7×), plus
     the payload accesses in S3, S4 and S5.
   - Cost: it changes `Semantics.lean`, every primitive law and the proof-mode tactics. *Several
     weeks, high risk. Stage 4.*
   - It still cannot justify *racy* plain accesses (plain-index rings, plain-data seqlocks). Those
     need a weak-memory logic [W], and in the JS model they have no SC guarantee at all.
8. **Raw typed regions:** an intrinsic `allocRaw kind n` whose HeapLang meaning is `AllocN n #0`,
   with a proved range invariant (0 ≤ v < 256 for bytes). The translator maps it to a
   `Uint8Array`/`Float32Array` view, which would bring the data plane inside the proof. Floats have
   no HeapLang counterpart, so audio would use fixed-point. *1–2 weeks. Stage 4.*
9. **ABA in the model:** `ArenaTreiber` with explicit recycling, then hazard pointers or epochs
   ported from kaist-cp/smr-verification. *Weeks. Research. Stage 4.*
10. **Prophecy-based linearisation points:** an atomic snapshot, RDCSS, Herlihy-Wing. This first
    needs `wp_new_proph`/`wp_resolve` tactics, which are missing. *Weeks. Stage 4.*
11. **Shrinking the translator gap (G1):**
    - first, prove the reference interpreter's step sound for `BaseStep`, which makes §5.2's traces
      formal;
    - then a word-heap target semantics and a forward simulation for the translator's core,
      without peephole optimisations.

    *Months. Stage 4+.*
12. **Host APIs as hypotheses:** Web Locks as a `Lock` instance, an IndexedDB transaction as an
    atomic update, `postMessage` as a channel spec. These are section variables, not global
    `axiom`s, so an inconsistent host spec cannot leak into unrelated theorems. *Days each. Stage 4.*
13. **Termination (`twp`)** for bounded loops such as the claim loop (n+1 iterations of its own).
    This needs a port of HeapLang `heap_total` adequacy and the twp tactics, both missing from
    iris-lean (`iris-audit.md` §6). *1–2 weeks. Stage 4.*
14. **Upstream fixes that cut friction everywhere:**
    - `awp_apply`;
    - `ElimModal`/`ElimInv` instances so that `iinv` works on `atomic_acc` goals;
    - composition of ghost-state signatures (today the 9 `HeapLangS` entries are copied by hand).

What stays out of reach whatever the effort: lock-freedom and starvation-freedom (no liveness logic
in Lean; Trillium, Fairis and Lawyer are Rocq-only), weak-memory logics (iRC11, Cosmo), and the
browser itself.

---

## 7. The honest section

### 7.1 What a green proof chip guarantees

Consider the HeapLang program built from the named `Val`s. In **every** interleaving, under
sequentially consistent semantics, with unbounded integers and a heap that never reuses addresses:

1. No thread, forked ones included, ever gets stuck. That rules out use of unallocated or freed
   cells, CAS on incomparable values, non-int FAA, and failed asserts.
2. If the main thread returns, its value satisfies the spec. For library kernels, the spec holds
   at every call site that owns the precondition: mutual exclusion as ownership of `R`, FIFO hand-off
   of `P i v`, each tile exactly once, no torn frames.

For a library-only chip (stage 1), the drivers are trusted glue (G11). Whole-program theorems
(§6.1) remove that.

### 7.2 What it does not guarantee

- **Liveness.**
  - A deadlocking or livelocking program satisfies every spec here.
  - TicketLock's proof says nothing about FIFO fairness. The lock convoys under oversubscription
    in every backend.
  - Lost wakeups pass the proof (S11).
- **The running code.** The kernel is translated by a trusted translator (G1, about 590 lines of
  Lean) with trusted runtimes (G8). They were tested 37/37 against a reference interpreter on three
  backends, but not proved. The exec agent's first translator silently dropped every `futexWake`,
  and no result changed; only the statistics counters caught it.
- **The memory model.**
  - SC holds only because *every* shared access is emitted as a SeqCst atomic (JS and wasm SC-DRF).
  - Plain initialisation before publication and plain reads of immutable blocks rest on a
    happens-before argument (G5), not a proof.
  - The data plane's plain accesses rest on the ownership discipline (§1.3).
  - Racy plain accesses are [W] and outside the proof for good.
- **Integers.** HeapLang `Int` is unbounded. The translation traps outside ±2^28 (fail-stop: a
  completed run is HeapLang-correct, but runs can stop). Hand-written JS wraps silently at 2^31.
- **Memory reuse.** No free, no GC: the translated heap leaks. That is faithful, and it is what makes
  Treiber ABA-free, but it is unusable for a long-running UI without per-call arenas.
- **Thread death.** HeapLang threads never die, so the kill test is measured only.
- **Performance.** Nothing at all.
- **Host APIs.** Only hypotheses.
- **The JS around the kernel**, and **Lean's runtime**: atomic reference counting, the task manager
  and its burst serialisation, `IO.Ref`'s empty-cell spin (`lean-threads.md` §2).

### 7.3 The trusted base

The items are the G-table of `exec.md` §6, condensed.

| item | status |
|---|---|
| G1 translator | trusted; tested |
| G2 value encoding | the CAS word lemma is proved; the runtime's ~20 lines are trusted |
| G3 29-bit ints | fail-stop trap; closable per kernel by range invariants |
| G4 SC vs JS/C11/wasm | sound while all shared accesses are SC atomics; costs about 1.7× in critical sections |
| G5 plain init / immutable reads | happens-before argument |
| G6 no free | leaks; ABA-free |
| G7 scheduling and pool size | safety unaffected; the C pool is fixed and can hang |
| G8 runtime (allocator, fork queue) | trusted; could itself be verified |
| G9 prophecy erasure | a theorem exists; the implementation is separate |
| G10 futex hints | the no-op specs are proved; recognition is trusted |
| G11 drivers | unproved until §6.1 |
| G12 toolchains | Lean, V8, clang, Emscripten, the browser |

### 7.4 Performance: what to expect

All ratios are from the CI VM.

| question | evidence | expectation |
|---|---|---|
| Is the verified lane slower than hand-written lock-free JS? | HL→JS: counters 0.96–1.3×, locks 1.6–2.3×, Treiber 1.12×, single-thread overhead 1.2–3.5×. C→native/wasm: at or below hand-written JS in most rows (`exec.md` §5) | about the same for RMW-bound kernels; slower where SC accesses sit inside critical sections |
| Is lock-free faster than a lock? | W=4: CAS 5–31/µs against futex mutex 12–13/µs; the ticket lock collapses under oversubscription | **not automatically.** A futex mutex beats every spinning algorithm once threads outnumber cores |
| Where are the big wins? | shards ≈ 250×; batched ring ≈ 16×; triple buffer the fastest snapshot | **ownership.** These are exactly what separation logic proves |
| Fastest variants outside the proof | plain-index ring about 4×; plain-data seqlock about 10× the reader rate | [W]: in the JS model they are racy; they pass on x86 by luck of TSO and are to be tested on ARM |
| Lean threads in LeanUI | threaded wasm64 works; blur 1.6–2.2× with mimalloc, about 1× with dlmalloc; Life 40×25 *slower*; background work keeps the page at 60 fps | threads help heavy jobs and keeping the main thread free, not the update/diff loop |

### 7.5 Where JavaScript's own tools, or plain Lean, are enough

- **Most offloading:** `postMessage` with Transferables. It is zero-copy (0.065 ms per 64 MiB), and
  the browser enforces ownership dynamically by detaching the buffer. Nothing to prove; batch to
  amortise the 33 µs round trip.
- **Counters:** one `Atomics.add` is already a linearizable increment, and its proof is trivial.
  Shards are faster and need only "sum at the end".
- **Coarse exclusion across tabs and workers:** Web Locks. They are released when the context dies,
  which makes them more robust than any SAB lock, proved or not.
- **Parallel compute in Lean:** purity already rules out races, so there is no shared mutable state
  for Iris to reason about (`lean-threads.md` §7).
- **LeanUI's async ordering:** the update loop is sequential, so plain Lean theorems suffice (S12).
- **Small kernels:** bounded exhaustive exploration (Explore, or TLA+ / Porcupine on histories)
  finds most safety bugs at a fraction of the cost. Iris adds *unbounded* threads and operations,
  and specs that compose.
- **Soon:** if TC39 shared structs ship, `Atomics.Mutex`/`Condition` will make a JS lock one line.

Iris pays off on **lock-free ownership-transfer protocols with subtle ordering**: the ring's publish
order, the triple buffer's fresh bit, once, the claimer, the barrier's resource exchange, the intern
table, the refcount's last owner. These are exactly the places where stress tests are probabilistic
(2,504 against 8,796 stale items in two identical runs) and depend on the platform.

### 7.6 Risks to the project

- iris-lean moves fast (the pinned upstream commit is from the day of the audit). Pin the commit
  and budget proof maintenance at each bump.
- The proof-mode friction is real (`iris-audit.md` §6): telescope noise, no `awp_apply`, `iinv`
  breaking inside atomic accessors, ghost-state signatures written by hand.
- Toolchains differ: main 4.34.0, vir 4.36.0-rc1, qed64 4.35.0, iris-lean 4.36.0. The kernels
  therefore **cannot be imported** by LeanUI's Lean code. The bridge is generated JS or C files,
  not Lean imports.
- Every SAB lane needs COOP/COEP, the same reason LeanUI ships single-threaded. The page stays
  opt-in.
- The value is concentrated in a few kernels. Most LeanUI apps never need them (`lean-threads.md`
  §7).

---

## 8. Implementation plan for `/home/user/leanui`

### 8.1 Layout

There is a new top-level `iris/`, separate like `vir/` and `qed64/`:

- its own toolchain and `.lake`;
- the main `lake build`, the apps and the wasm64 build never read it;
- it writes `dist/iris/`.

```
iris/
  README.md            what is proved, tested and trusted, modelled on docs/PROOFS.md
  lean-toolchain       leanprover/lean4:v4.36.0     (iris-lean's)
  lakefile.toml        [[require]] name="iris" git="https://github.com/leanprover-community/iris-lean"
                       rev="100ed29e10b3b5e91d676d31ea708987882079e0" subDir="Iris"
                       (Lake's TOML decoder reads subDir for git requires)
                       libs: LeanUIIris; exe: iris-gen
  lake-manifest.json
  build.sh             lake build (all proofs) → lake exe iris-gen ../dist/iris/gen → [emcc wasm lane] → page
  LeanUIIris/
    Kernels/           HeapLang Vals: Counter, Locks (re-exports), FutexMutex, SpscRing, TripleBuffer, Claim,
                       ParMap, Treiber, Once, Semaphore, Cancel, EventCount, Barrier, Seqlock, InternTable, RcPool
    Proofs/            one file per kernel, then Axioms.lean: `#guard_msgs in #print axioms` for every
                       headline theorem (lake build fails on sorryAx or any new axiom, as LeanUI/Proofs/Keyed.lean does)
    Broken/            the mutants as HeapLang terms (racy counter, publish-before-write, no-fresh-bit, ...)
    Translate/         from iris/exec/src/Exec/Translate.lean, split: Encode, JS, C, Peephole, Intrinsics,
                       FuzzMode, NoBlock
    Hints.lean         proved no-op intrinsics (futexWait/Wake, spinPause)
    Interp.lean, Explore.lean    reference interpreter; bounded exhaustive schedules (§5.2)
    WaitFree.lean      the syntactic loop-free certificate (§6.3)
    Gen.lean           writes kernels/*.mjs, c/*.c, manifest.json: constants → theorems → axioms → G-items → stats
  rt/                  runtime.mjs, worker.mjs, hl_rt.h, hl_main.h (from iris/exec/rt), browser launcher
  suite/               harness.mjs (Node and browser), metrics.mjs (Jain, p99, rAF gaps), faults.mjs,
                       scenarios/<id>/{scenario.mjs, l0-broken.mjs, l1-idiomatic.mjs, l2-lockfree.mjs}
  pages/               index.html, iris.js, iris.css, audio-worklet.js   (copied to dist/iris/)
  test/                node.mjs (CI), browser.mjs (Playwright)
```

Nothing generated is committed. `iris/build.sh` regenerates it all, as `vir/build.sh` and
`qed64/build.sh` do.

### 8.2 Stages

Each stage ends in something that works. Efforts are estimates.

**Stage 0: scaffold (2–3 days)**
- Create `iris/`, pin iris-lean, and port in:
  - exec's translator, runtimes, interpreter, `Hints`, `FutexMutexProof` and `EncodingProof`;
  - the audit's seven proofs.
- Add the axioms guard.
- Write `iris/test/node.mjs` running exec's 37 differential tests on the JS backend, and on native
  if `cc` is available.
- Exit criteria:
  - `cd iris && lake build` passes (about 5 min cold on the VM: Iris 3m14s plus 1m24s of
    precompile);
  - the tests pass;
  - the README states the scope.

**Stage 1: the first honest demo (1–1.5 weeks). No new proof.**
- Scenarios:
  - **S1** counters;
  - **S2** lock zoo, with the kill test and oversubscription;
  - **S4** SPSC ring, with a Node 2.67 ms tick standing in for the worklet;
  - **S5** static disjoint tiles (ParMap).
- Lanes L0–L4. The wasm lane is built when `emcc` is present, otherwise the panel says "not built".
- The harness does:
  - a W sweep;
  - fuzz-mode delays;
  - the kill test;
  - wrap starts;
  - JSON output.
- Proof chips are generated from the manifest, library-only for now, with G11 shown.
- Evidence for broken variants comes from the interpreter's random schedules (racy counter,
  publish-before-write).
- The page `/iris/`:
  - runs the same modules in module Workers on an isolated page (exec's browser launcher);
  - outside isolation it shows only the static theorem table and why;
  - it is not linked from the site.
- Exit criteria:
  - the verified lanes show 0 violations over W ∈ {1,2,4,8} × fuzz on/off;
  - violations in broken lanes are recorded, not required;
  - the page runs under `leanui serve dist --coop` in Chromium;
  - the README's tables are regenerated from this harness's JSON.

**Stage 2: proofs that pay off (2–3 weeks)**
- New kernels with proofs:
  - **TripleBuffer** (S3, with the torn-frame canvas);
  - **Claim** (S5 dynamic, uneven Mandelbrot);
  - **Once** (S9), **Semaphore** (S10), **Cancel** (S15), **EventCount** safety (S11);
  - **batched and modular-index SPSC** (S4).
- Whole-program driver theorems (§6.1).
- Explore, with exhaustive small instances and counterexample traces.
- The wait-freedom certificate and range invariants.
- The mutation tournament S20, automated over the existing kernels.
- The flood test S16.
- Browser work:
  - the AudioWorklet glitch counter, with sound on click;
  - Web Locks lanes in S2.
- CI: the wasm lane through the existing Emscripten image (`toolchain/image.sh`, emsdk 6.0.5), and
  Playwright Chromium.

**Stage 3: LeanUI integration (2–3 weeks; part (b) depends on deciding on a threaded mode)**
- L5:
  - (a) one LeanUI wasm64 instance per Worker running the editor blur on claimed tiles. This needs
    no threaded runtime; copies in and out are measured.
  - (b) the threaded wasm64 route from `lean-threads.md` §6.2: namespaced translator C, an entry
    ABI, one shared thread pool, per-call arenas (about 2 weeks there). Its showcase is a JS
    decoder Worker feeding a Lean consumer through the verified ring, plus S1's Lean counter lanes.
- **S4b**, the QED64 stdin ring: protocol proof (safety only). The kick stays.
- **S7**, the barrier stencil on Life 512².
- **S12**, the plain Lean theorem on a LeanUI `update`.
- **S13**, the intern table, and **S14**, the refcount pool.
- Refutation theorems (§5.3) for two or three mutants.

**Stage 4: the limit (research, open-ended, each item optional)**
- HeapLang-NA, giving data-race freedom from adequacy and plain accesses in the translator (§6.7);
- raw typed regions;
- ArenaTreiber with ABA in the model;
- Vyukov MPMC;
- prophecy snapshot;
- Chase-Lev;
- the SC seqlock and the ARM plain-data experiments (S8);
- host hypotheses and the multi-tab S17;
- S18 publication;
- a cooperative single-thread backend for non-isolated pages;
- interpreter ⊑ `BaseStep`, then translator simulation;
- upstream iris-lean contributions.

Re-measuring on the reference Mac (ARM, more cores) closes every stage. The ARM-specific rows
(S4 plain indices, S8 plain data, S9 double-checked flag) only mean anything there.

### 8.3 The page (`dist/iris/index.html`)

- **Isolation gate.** If `crossOriginIsolated` is false, the page shows the theorem and trusted-items
  table (static, from the manifest) and explains why nothing runs.
- **Controls:**
  - a scenario picker;
  - W ∈ {1, 2, 4, cores, 2×cores} and a duration;
  - fault toggles: fuzz, jank, kill, wrap start, memory growth;
  - lane checkboxes for L0–L5, showing the lanes that were built.
- **Each lane panel shows:**
  - correctness counters (green 0 / red n);
  - ops/µs and a scaling sparkline;
  - p99 latency, Jain's index, the longest rAF gap and memory;
  - the proof chip, which expands to the theorems, the `#print axioms` output, the G-items, "not
    proved: …", and links to the HeapLang text and the generated JS.
- **Visual demos:**
  - a torn-frame canvas (S3, S8);
  - a tile-difference heat map between runs (S5);
  - audible underruns (S4, after a click);
  - a "theorem predicts / observed" line (S1, from stage 2).
- **Automation:** `window.__iris` exposes the results to Playwright, and there is a Download JSON
  button.
- **Serving:** only by `leanui serve dist --coop`. It is served on the site, isolated like `/race/`,
  only once stage 2 is stable. That needs a `deploy/` change and a line in `docs/DEPLOY.md`.

### 8.4 Tests

- **`iris/test/node.mjs`** (CI-required):
  1. differential tests: each translated program against the reference interpreter;
  2. verified lanes: 0 violations in a quick sweep, fuzz on and off;
  3. **chip provenance**: every lane that claims a theorem names one in the manifest, the theorem
     builds, and its axioms are a subset of {propext, Classical.choice, Quot.sound};
  4. **translator statistics**: expected intrinsic counts per program (for example `futex-wake ≥ 1`
     for FutexMutex), after exec's silent-drop bug;
  5. Explore: every broken variant yields a counterexample within its bound, and the small
     instances of verified kernels yield none;
  6. the overflow trap and wrap-start behaviour.

  Broken *stress* lanes are never required to fail in CI, because they are probabilistic. Their
  results are only recorded.
- **`iris/test/browser.mjs`** (Playwright Chromium; Firefox in stage 2):
  - the page boots under `--coop`;
  - one quick run per scenario, with 0 violations in the verified lanes;
  - the non-isolated page shows the refusal.
- **Lean:** `lake build` inside `iris/` checks every proof and the `#guard_msgs` axiom guards.

### 8.5 CI (`.github/workflows/ci.yml`)

Add a separate job, `iris`, that runs in parallel with `test`, so the main job's 180-minute budget
and caches are untouched:

- restore `~/.elan` (keyed on `iris/lean-toolchain`) and `iris/.lake` (keyed on the toolchain,
  `iris/lakefile.toml` and the manifest);
- run `iris/build.sh --no-wasm`, then `node iris/test/node.mjs`;
- from stage 2:
  - the wasm lane through `toolchain/image.sh`;
  - Playwright Chromium on a `leanui serve dist --coop` server. That needs the main build's
    `leanui` binary, so either depend on an artifact or build the CLI in the job.
- benchmarks: as with the existing `bench` label, `node iris/suite/harness.mjs --all --runs 5
  --json` is uploaded as an artifact and **never fails the build**.

The deploy job does not depend on `iris`.

---

## 9. Evidence index

All paths start `<scratchpad>/`
unless they begin with `/home/user/leanui`.

**JS catalogue**
- `iris/js-catalogue.md`
- Probes and outputs: `iris/catalogue/probes/{counter,snapshot,ring,pingpong,transfer,plainflag,features}.mjs` and `*.out`; `iris/catalogue/browser/{serve-probe,clone-probe}.mjs`, `probe.out`, `clone.out`

**iris-lean audit**
- `iris/iris-audit.md`
- Proofs: `iris/iris-audit/proofs/{AtomicCounter,TwoThreads,ParMap,Treiber,TreiberAtomic,SpscRing,SpscClient}.lean`
- Logs: `iris/iris-audit/build-iris.log`, `build-iristest.log`, `porting.csv`
- JS transcription: `iris/iris-audit/js/translate-check.mjs`, `run1.txt`, `run2.txt`

**Execution path**
- `iris/exec.md`
- Lean sources: `iris/exec/src/Exec/{Translate,Programs,Hints,Intrinsics,FutexMutexProof,EncodingProof,Interp}.lean`, `iris/exec/src/Gen.lean`
- Runtimes: `iris/exec/rt/{runtime,worker,run}.mjs`, `hl_rt.h`, `hl_main.h`, `rt/browser/`
- Results: `iris/exec/bench/results.md`, `results.json`, `browser.log`
- Test logs: `iris/exec/bench/tests-{js,native,wasm}.log`, each ending "37 passed, 0 failed, 1 notes" (re-checked with `grep` for this design)

**Lean threads**
- `iris/lean-threads.md`
- `iris/lean-threads/lab/{ThreadLab.lean,lab_ffi.c,lab_shim.c,build-wasm.sh,run-node.mjs}`, `lab/web/{bg.html,sab-apis.mjs}`, `lab/results/tables.md`

**iris-lean upstream** (commit `100ed29e`, Lean v4.36.0)
- `ext/iris-lean-upstream/Iris/lakefile.toml`
- `Iris/Iris/HeapLang/Lib/{Counter,SpinLock,TicketLock,RwSpinLock,Spawn,Par,Lock,RwLock,Array,Quicksort}.lean`
  - spec names checked with `grep`: `incr_mono_spec`, `ccounter`, `incr_contrib_spec`, `read_contrib_spec_1`, `spawn_spec`, `join_spec`, `par_spec`, `wp_par`, `newlock_spec`
- `Iris/Iris/ProgramLogic/{Adequacy,Atomic,TotalAdequacy,TotalWeakestPre}.lean`
- Lake's TOML `subDir` support: `~/.elan/toolchains/leanprover--lean4---v4.36.0/src/lean/lake/Lake/Load/Toml.lean` lines 295–319

**LeanUI repository**
- Separate subprojects to copy: `/home/user/leanui/vir/{README.md,lakefile.toml,build.sh}` and `/home/user/leanui/qed64/README.md`
- `/home/user/leanui/qed64/lane/core.js` lines 24–53 (the stdin ring; "HARDENING #52" at `qed64/README.md`)
- `/home/user/leanui/bench/race/lanes.mjs`, `bench/race/build.sh`
- `/home/user/leanui/docs/TOOLCHAIN.md` lines 23–36 ("Why single-threaded"; its "tasks run when forced" is inaccurate per `lean-threads.md` §2.4)
- `/home/user/leanui/docs/PROOFS.md` (the axiom-guard convention)
- `/home/user/leanui/.github/workflows/ci.yml` (job layout, `bench` label, `--coop` race server)
- `/home/user/leanui/tests/browser/run-all.sh`, `/home/user/leanui/toolchain/image.sh`

**Literature**
- Watt et al., "Repairing and Mechanising the JavaScript Relaxed Memory Model", PLDI 2020: https://arxiv.org/abs/2005.10554
- Iris Chase-Lev: https://arxiv.org/abs/2309.03642 and https://iris-project.org/pdfs/2026-pldi-parabs.pdf
- Iris SMR (hazard pointers, RCU): https://github.com/kaist-cp/smr-verification and https://iris-project.org/pdfs/2025-pldi-weak-smr.pdf
- TC39 shared structs: https://github.com/tc39/proposal-structs
