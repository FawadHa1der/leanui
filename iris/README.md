# Verified concurrency kernels: iris-lean, translated to threads, side by side with JavaScript

Ordinary JavaScript doing multithreaded work on a shared resource, next to the same work done by
code proved correct in [iris-lean](https://github.com/leanprover-community/iris-lean). Five
scenarios (counters, a lock zoo, an audio-style ring, disjoint tiles, lost wakeups) run every way
JavaScript would do them, plus the verified way, at 1, 2, 4 and 8 threads, in Node and in a
cross-origin isolated page. The design and its review are in `docs/design.md` and
`docs/critique.md`; the review's corrections are binding, and this is the design's stage 1.

iris-lean proves programs written in HeapLang, a small untyped language whose threads interleave
with sequentially consistent memory. Here such programs are proved, then translated, from the very
constants the theorems are about, by a translator written in Lean: into JavaScript over one
`SharedArrayBuffer` with `Atomics`, and into C11 with `seq_cst` atomics (built natively, or to
wasm32 with Emscripten pthreads). A reference interpreter for HeapLang tests the translation.

The proofs do not remove locks; an algorithm does, and the proof shows that the algorithm is safe
in every interleaving. Most of the "no lock" kernels here get there by ownership (each thread owns
its shard, its band, its slot), and the proofs say exactly that. They say nothing about speed,
progress or the memory model of plain accesses ("What is not proved", below), and the scenarios
include one where the proof cannot help at all (S11).

The library and the apps do not depend on this directory: the main `lake build` and the wasm64
builds never read it. It has its own Lean (4.36.0, the release iris-lean pins; the main build is
on 4.34.0) and its own build in `iris/.lake` (about 700 MB, ignored by git). Nothing generated is
committed.

## How it fits together

```
LeanUIIris/Kernels/*.lean, iris-lean's Lib     a HeapLang Val (e.g. FutexMutex.acquire) and its theorem
        │  the same constant, imported
        ▼
LeanUIIris/Programs.lean, Manifest.lean        whole programs (each with the result it must give) and
        │                                      libraries (kernels the harness calls from JavaScript)
        ▼
Gen.lean (lake exe iris-gen)  ──  Translate.lean (trusted)  ──▶ dist/iris/gen/js/*.mjs ─▶ rt/launch.mjs (whole programs)
                              │                             │                          └▶ rt/embed.mjs  (lib_*.mjs, called from Workers)
                              │                             └─▶ dist/iris/gen/c/*.c    ─▶ rt/hl_rt.h, cc or emcc
                              └─ Interp.lean ─▶ the interpreter's results, in dist/iris/gen/manifest.json
                                                              │
bench/ (harness.mjs in Node, page/ in a browser) ◀────────────┘  lanes, proof chips from the manifest
```

The generator finds the kernels in each program and each library export by comparing terms with
the proved constants (Lean's `=` on `Val`), and records them and their theorems in the manifest.
A kernel therefore cannot drift from its proof: there is no second copy to drift. The proof chips
of the harness and the page take their kernels and theorems from that manifest; each lane's scope
and its trusted and not-proved lines are written by hand, per lane kind in `bench/chips.mjs` and
per lane in its scenario module.

## What is proved

Every theorem below is checked by `lake build` and depends on `propext`, `Classical.choice` and
`Quot.sound` only: `LeanUIIris/Axioms.lean` runs `#print axioms` on each inside `#guard_msgs`, so
a `sorry` or a new axiom fails the build. `test/node.mjs` checks that every theorem the manifest
names is in that guard.

### Kernels

| Kernel | Code and proof | Theorems | What they say |
|---|---|---|---|
| `SpinLock` | iris-lean `Lib/SpinLock.lean` | `newlock_spec`, `try_acquire_spec`, `acquire_spec`, `release_spec` | A lock, an instance of iris-lean's `Lock` interface: `acquire` returns the lock's resource `R` with an exclusive token, so mutual exclusion is ownership of `R`. |
| `TicketLock` | iris-lean `Lib/TicketLock.lean` | `newlock_spec`, `waitLoop_spec`, `acquire_spec`, `release_spec` | The same `Lock` spec. FIFO order is not part of it. |
| `RwSpinLock` | iris-lean `Lib/RwSpinLock.lean` | `newlock_spec`, `acquireReader_spec`, `releaseReader_spec`, `acquireWriter_spec`, `releaseWriter_spec` (and the two `tryAcquire…`) | Readers get a fraction of the resource, the writer all of it. |
| `FutexMutex` | `Kernels/FutexMutex.lean` | `newlock_spec`, `slow_spec`, `acquire_spec`, `release_spec`, `isLock_iff`, `instLock` | Drepper's three-state mutex, which parks waiters instead of spinning: the same `Lock` spec (`instLock` is the instance). The lock word stays in {0, 1, 2}. |
| `FutexNoWake` | `Kernels/FutexNoWake.lean` | `releaseNoWake_spec`, `instLock`, `criticalNoWake_spec` | `FutexMutex` with its `futexWake` removed, a lost-wakeup bug: the very same `Lock` spec, so `critical_spec` covers its critical section too. The proof cannot see a liveness bug (S11). |
| `Critical` | `Kernels/Critical.lean` | `critical_spec`, `criticalSpin_spec`, `criticalTicket_spec`, `criticalFutex_spec` | One critical section (check two cells are equal, bump both) proved once for every `Lock` instance: if it returns, it returns `true`. The three locks of S2 get the same theorem. |
| `Hints` | `Kernels/Hints.lean` | `futexWait_spec`, `futexWake_spec` | Two functions that do nothing in HeapLang; the translator turns them into `Atomics.wait` and `Atomics.notify`. |
| `Counter` | iris-lean `Lib/Counter.lean` | `newcounter_mono_spec`, `incr_mono_spec`, `read_mono_spec`, `newcounter_contrib_spec`, `incr_contrib_spec`, `read_contrib_spec`, `read_contrib_spec_1` | A CAS-loop counter: a read returns at least any lower bound its caller holds, and per-thread fractional contributions add up to the value (ghost fractions over one shared cell, not physical shards). Not logically atomic. |
| `AtomicCounter` | `Kernels/AtomicCounter.lean` | `faaIncr_spec`, `casIncr_spec`, `casIncr_seq` | `faaIncr` (one `faa`) and `casIncr` (a CAS loop) are logically atomic: `<<l ↦ n>> incr l <<l ↦ n+1 \| RET n>>`, so a client can open its own invariant around the call. |
| `Shards` | `Kernels/Shards.lean` | `bump_spec`, `shardCount_spec` | `n` threads each count `k` in a cell they own and add it to their own shard: every shard ends `k` higher. ParMap-style ownership; no invariant, no ghost state, no read-modify-write atomics. |
| `Treiber` | `Kernels/Treiber.lean`, `Kernels/TreiberAtomic.lean` | `newStack_spec`, `push_spec`, `pop_spec`; `newStackA_spec`, `pushA_spec`, `popA_spec` | A pop returns a pushed element together with the resource its pusher gave up. The second set gives push and pop logically atomic specs against an abstract list (the Iris form of linearizability; the link to histories is not formalised in Lean). Nodes are never freed, which is why there is no ABA. |
| `SpscRing` | `Kernels/SpscRing.lean` | `rb_init`, `tryPush_spec`, `tryPop_spec` | A bounded single-producer, single-consumer ring: the i-th push hands `P i v` to the i-th pop. With `P i v := v = msgs[i]` that is FIFO with nothing lost or duplicated. |
| `ParMap` | `Kernels/ParMap.lean` | `pmap_spec` | A fork-join map of a pure function over an array, each thread owning a disjoint half: no invariant, no ghost state, no read-modify-write atomics. Pointwise only: a stencil (a blur) needs a different spec. |
| `ParMapG` | `Kernels/ParMapG.lean` | `seqMap_spec`, `pmapG_spec` | ParMap with a grain size: parts of at most `g` cells are mapped sequentially, so `W` bands need `W` threads instead of one per cell. The same ownership proof. |
| `Mandel` | `Kernels/Mandel.lean` | `iter_spec`, `mandel_spec` | `mandel` computes the Lean function `Mandel.g` (a pixel's Mandelbrot iteration count, fixed point): the per-element spec `pmapG_spec` needs, so S5's whole fork-join render is covered. |
| `Spawn`, `Par` | iris-lean `Lib/Spawn.lean`, `Lib/Par.lean` | `spawn_spec`, `join_spec`, `par_spec` | `join` returns a value satisfying the spawned thread's postcondition; `e1 ‖ e2` returns both results. The join spins. |
| `Quicksort` | iris-lean `Lib/Quicksort.lean` | `quicksort_spec` and the helpers' specs | Sequential: sorted, and a permutation of the input. |

### Whole programs

Three programs have a theorem about the exact program that is translated, not only about its
kernels (`adequate .NotStuck`: from any initial state, in every interleaving, no thread gets stuck,
and the main thread's value, if it returns one, is the one stated):

| Program | Theorem | Returns |
|---|---|---|
| `let l := ref 0; (faaIncr l ‖ faaIncr l); !l` | `TwoThreads.twoIncr_adequate` | `2` |
| a producer pushes 10 and 20 through a ring of capacity 2, a consumer pops twice | `SpscClient.spscClient_adequate` | `(10, 20)`: in order, none lost, none duplicated |
| build a list of 40 ints, quicksort it, check it is sorted | iris-lean's `Quicksort.sortAndCheckAdequate` | `true` |

Every other program is a driver around kernels (`Programs.lean`: thread fan-out, loops, checks).
Its kernels are proved; the driver is unproved glue, and the manifest says so for each program
(`"scope"`).

### The translation

| Theorem | What it says |
|---|---|
| `Translate.cas_word_iff` | For the word encoding (below): whenever HeapLang's `CmpXchg` is defined (the expected value is unboxed), two words are equal exactly when the values are, so a HeapLang CAS is one `Atomics.compareExchange`. |

## What a theorem guarantees

Under sequentially consistent memory, with unbounded integers and a heap that never reuses a
location, the theorems give two kinds of guarantee:

1. **The three whole programs.** In every interleaving no thread, forked ones included, gets
   stuck (no use of an unallocated cell, no CAS on values HeapLang cannot compare, no `faa` on a
   non-integer, no failed assertion), and if the main thread returns, its value is the one stated.
   Nothing says that it returns.
2. **A kernel.** Each triple holds at a call whose caller owns its precondition: the call does
   not get stuck, and if it returns, its value satisfies the specification (mutual exclusion as
   ownership of `R`, FIFO hand-off of `P i v`, a pop returning what a push gave up, every pixel
   `g` of its index). The preconditions are the protocol: one producer and one consumer for
   `SpscRing`, the two cells touched only under the lock for `Critical`, disjoint parts for
   `ParMap`, `ParMapG` and `Shards`, and only the holder releases a `Lock`. In the drivers and
   the JavaScript glue, nothing checks this: a driver that calls `tryPop` from two threads gets
   values the theorem does not promise, and so does `small_spsc_early`, whose mutant producer
   breaks the ring's invariant under the proved `tryPop`.

That is safety and partial correctness, nothing more.

## What is not proved

- **Liveness.** A program that deadlocks or spins forever satisfies every specification here.
  Fairness (TicketLock's FIFO order), starvation, lost wakeups and the termination of CAS loops
  are not stated, and iris-lean has no logic for them. S11 makes this concrete: `FutexNoWake`
  never wakes a waiter and is proved exactly as `FutexMutex` is.
- **"Lock-free" and "wait-free".** These words describe algorithms here, never theorems:
  `faaIncr` is one atomic step; the ring's `tryPush`/`tryPop` have no loops; a CAS loop or a
  Treiber CAS fails only because another succeeded. Blocking primitives built without a mutex word
  (a futex wait, the event count of S11, ParMap's spinning join) are called blocking.
- **Weak memory.** HeapLang is sequentially consistent, and so is every translated program,
  because every shared access is emitted as a SeqCst atomic. The faster variants that use plain
  accesses for shared words (a ring that publishes its indices with plain stores, a seqlock with
  plain data) cannot even be stated: they need a weak-memory logic iris-lean does not have.
- **Performance.** Nothing at all.
- **The data plane.** Where a payload sits in ordinary typed arrays (S4's `ring-dataplane` lane:
  samples in a `Float32Array`), the proof covers the protocol, not the JavaScript that touches the
  bytes. Such lanes are labelled "verified protocol, trusted data plane" (L3p), and S4 shows the
  injected bug living exactly there.
- **The world around the program**: host APIs (`postMessage`, Web Locks, IndexedDB), a thread
  that is killed (HeapLang threads never die), and the JavaScript that calls a kernel.

## What is trusted

| Item | Status |
|---|---|
| The translator, `Translate.lean` (about 580 lines) | Not verified. Tested: each program's result on real threads must match the result HeapLang's semantics gives, worked out by hand or by the reference interpreter under four schedules (`test/node.mjs`). |
| The reference interpreter, `Interp.lean` | Reuses iris-lean's substitution, operators, heap and `Loc.fresh`; the evaluation contexts, head steps and scheduler are transcribed from `Semantics.lean`, not proved equal to `BaseStep`. |
| The encoding: one Int32 word per value | The CAS lemma is proved (`cas_word_iff`). That the runtimes build the same words (about 20 lines each) is trusted. Integers are 29-bit: a result outside ±2^28 traps instead of wrapping, so a completed run computes HeapLang's result but a run can stop (S1's wrap lanes show both behaviours). `faa` detects overflow only after the wrapped word is in the cell: the thread that wrapped it traps, and other threads may compute on the wrapped value until something stops them: the launcher's teardown, the C exit, or a harness lane's stop flag. Through `rt/embed.mjs` alone, nothing does. HeapLang's integers are unbounded, so the proofs say nothing here; only bounded words (the futex word) are known to fit. Ring indices and counters trap after 2^28 operations. |
| SC on real hardware | JavaScript's and C11's memory models give sequential consistency to programs whose racing accesses are all SeqCst atomics, which is how every HeapLang access is emitted. Plain accesses initialise a fresh block before its pointer is published, and read immutable blocks: a happens-before argument, not a proof. |
| No free, no GC | The heap never reuses a location, as in HeapLang; that is why the Treiber stack has no ABA problem here. Memory only grows: a run that allocates per operation stops with "out of memory" when the buffer is full, so runs are sized for it (64 MB for whole programs, 16 MB for a library heap; no stage-1 kernel allocates per operation). Unusable as is for a long-running page. |
| The runtimes, `rt/` | The allocator, the fork queue, the thread pools, the futex hints, the embedding (`embed.mjs`). A delayed thread is one more interleaving, so scheduling cannot break safety. The JS launcher grows its pool when a fork finds no idle thread; the C pool is fixed and can hang (liveness), never compute a wrong value. A trap (stuck, overflow, out of memory) ends a whole program: the launcher terminates every thread and the C program exits. In a library lane it is an exception in the calling thread only (`rt/embed.mjs`): the harness then raises a stop flag that the lane's loops poll, and another worker may finish its loop first. |
| The glue | The JavaScript that calls a kernel through `rt/embed.mjs` (which cells it passes, the loop around the call) and, in L3p lanes, the data plane. The same glue drives the JS lanes. |
| Futex hints | Their no-op specs are proved; that the translator recognises exactly these two values is trusted. A wait is timed (20 ms), so a lost wakeup delays a waiter; it cannot strand it. |
| Prophecies | Erased by the translator; iris-lean proves erasure sound (`ProphErasure.lean`), but the translator's erasure is its own. |
| Drivers | Unproved, except the three whole programs. |
| Toolchains | Lean, Node/V8, the C compiler, Emscripten, the browser. |

## The scenarios

Each scenario runs the same work on the same shared resource in several lanes. The headline pair
is idiomatic JavaScript against the same algorithm verified, driven by the same JavaScript loop;
the harness reports throughput, CPU time per operation (`process.cpuUsage`, Node only), fairness
(Jain's index over per-thread counts), and every correctness violation it can count.

| Kind | Lane |
|---|---|
| L0 | broken on purpose (a racy `x++`, publishing before writing, a misplaced notify, or broken glue around a verified kernel): violations are recorded, never required, and its speed is never shown (V8 collapses the racy loops) |
| L1 | idiomatic JavaScript: `Atomics.add`, a futex mutex, `postMessage` with transfer, Web Locks |
| L2 | the same algorithm as the verified kernel, by hand in JavaScript |
| L3 | verified, payload in the heap: the kernel and everything it touches are HeapLang, every access an SC atomic (fully covered, sometimes slow) |
| L3p | verified protocol, trusted data plane: the payload is in ordinary typed arrays |
| L4n, L4w | the same HeapLang program through C11 to native code, or to wasm32 with Emscripten pthreads (Node only) |
| M | a HeapLang mutant with no proof: what the proof would have rejected |

Library kernels (`gen/js/lib_*.mjs`) are called from harness Workers through `rt/embed.mjs`
(L3, L3p); whole programs (`bench_*`) run on the HeapLang thread pool, with their HeapLang driver
(L3 "whole program", L4), three times per row: every run's value must be the expected one, and a
JavaScript run that has not returned after 120 s, or a native or wasm program whose three runs
take longer, fails the row. Fuzz mode adds random delays before shared-memory operations, in the
translated runtime and at labelled points of the JavaScript lanes: more interleavings, not a fair
speed comparison. Zero violations under fuzz is evidence
about the trusted base (translator, runtime, glue), not a property of the proofs.

**S1, counters** (`bench/scenarios/s1.mjs`). W threads add 1 to one counter: a racy
`a[0] = a[0] + 1` (L0), `Atomics.add` (L1) against `AtomicCounter.faaIncr` (L3), a
`compareExchange` loop by hand against `casIncr` and iris-lean's `Counter.incr`, counting locally
with one `Atomics.add` at the end (L1: no memory traffic per increment at all), and shards: each
thread owns a padded cell (L2) against `Shards.shardCount` (L3, whole program; its proof is
ParMap-style ownership). The wrap lanes start near the top of the integers: `Atomics.add` wraps to
a negative number without a word; the verified counter traps, though only after the wrapped word
is in the cell, so the other worker keeps adding to the wrapped counter until its loop ends or it
sees the harness's stop flag (usually the loop ends first).

**S2, the lock zoo** (`s2.mjs`). W threads take a lock, check that two cells are equal and bump
both. A futex mutex by hand (L1), spin and ticket locks by hand (L2) against
`Critical.criticalFutex`, `criticalSpin`, `criticalTicket` (L3: one theorem, `critical_spec`, for
all three), Web Locks in the page, and native and wasm32 builds of the futex and spin programs.
In every lane the lock and the two cells sit on separate cache lines; a ticket lock's two
counters share one, by hand as in iris-lean's `TicketLock`. The kill test terminates a Worker
while it holds the lock: every lock word in a `SharedArrayBuffer` stays taken, verified or not;
Web Locks are released when the holder dies.

**S4, the glitch counter** (`s4.mjs`). W producer/consumer pairs; the consumer takes one
128-sample quantum every 2.67 ms, standing in for an AudioWorklet ("tick"), or as fast as it can
("stress", where races show). Lanes: a ring by hand (L2) and its publish-before-write bug (L0),
block buffers transferred back and forth with `postMessage` (L1), `SpscRing` carrying every
sample in the heap (L3), `SpscRing` carrying block numbers with the samples in a `Float32Array`
(L3p), the same verified ring with glue that fills a block after pushing it (L0: the proof is
unchanged, the data is stale), and the HeapLang mutant `tryPushEarly` (M; the reference
interpreter also finds its stale reads, `small_spsc_early`). The L3p lane's safety rests on a
trusted argument in the glue: block t is written into payload slot t mod (capacity + 2) before
it is pushed.

**S5, disjoint tiles** (`s5.mjs`). A 256×256 Mandelbrot (1 to 200 iterations per pixel) on W
threads: tiles claimed with a racy `next = next + 1` (L0), bands returned by transfer (L1), bands
written into one `SharedArrayBuffer` (L2), tiles claimed with `Atomics.add` (L2; its "each tile
exactly once" proof is stage 2's `Claim`), and `ParMapG.pmapG` with the proved `Mandel.mandel`
over the image in the heap (L3, L4). The verified algorithm has no lock and no read-modify-write
atomics (translated, every heap access is an SC Atomics load or store); ownership of disjoint
halves is the whole proof, and its join spins. Its times include allocating, initialising and
summing the image, which the JS lanes do outside the timing: on the 4-vCPU VM about 0.7 ms in C,
and in JavaScript about 2 ms at W = 1 and 5 to 7 ms above (the HeapLang main thread can land on a
pool thread that has not compiled the loops yet; CI machine, to be re-measured on the reference
Mac). It has no data-plane lane: `pmapG_spec` constrains the final array, not how often a foreign
callback would run, so a fast lane writing pixels outside the heap needs the `Claim` proof first.
Every lane's checksum must equal `Σ Mandel.g`, computed in Lean.

**S11, the lost-wakeup hunt** (`s11.mjs`). Sleepers wait with `Atomics.wait` for an event count;
the correct protocol (L2) and three classic mistakes (L0: notify before the store, notify the
wrong word, notify one waiter of several), each waiter rescued by a 5 ms watchdog. Then the
verified pair: the critical section under `FutexMutex` and under `FutexNoWake`; the runtime counts
the futex waits that only the 20 ms timeout ended. Both locks satisfy the same `Lock` spec, so one
theorem (`critical_spec`) covers the section under each; the behaviour is not the same. That
rescue timeout, not a proof, is what keeps the system alive, as QED64's once-a-second kick does
(`qed64/README.md`).

### Results

`node iris/bench/harness.mjs --json FILE` writes every row; `node iris/bench/summary.mjs FILE
--readme` regenerates this section from it. The tables below come from
`docs/results/stage1-harness.json`, a full run (W = 1, 2, 4, 8, fuzz off and on) on a 4-vCPU
cloud VM; two more runs with fuzz off, on the same VM the same hour, give the ranges quoted
below. Read them as ratios within one run, and re-measure on the reference Mac (ARM: a weaker
memory model, where the racy lanes may fail differently). W = 8 is oversubscribed; S4 runs 2W
threads, so there W = 4 is too. In Chromium (`test/page.mjs`), the Web Locks lane ran without a
violation, and in the kill test a Web Lock held by a terminated Worker was granted to the next
request about 11 ms later, while every lock word in a `SharedArrayBuffer` stayed taken.

<!-- results:begin -->
Measured 2026-11-20 on linux x64, 4 logical cores, Node v22.23.5. CI machine numbers: read them as ratios within one run; re-measure on the reference Mac.

**S1 · Counters: lost-update roulette**

| lane | kind | W=1 | W=2 | W=4 | W=8 | CPU ns/op (W=8) | fairness (W=8) | violations, all runs | note |
|---|---|--:|--:|--:|--:|--:|--:|---|---|
| a[0] = a[0] + 1 (no synchronisation) | L0 | — | — | — | — |  | 0.584 | lost updates 948442292 | 91% of the increments lost; V8 collapses this loop, so no speed |
| Atomics.add (idiomatic) | L1 | 75.0 | 14.3 | 9.4 | 9.0 | 429.7 | 0.959 | 0 |  |
| faaIncr (verified FAA, translated) | L3 | 72.5 | 15.0 | 8.5 | 9.1 | 390 | 0.945 | 0 |  |
| compareExchange loop by hand | L2 | 55.8 | 10.7 | 5.6 | 4.1 | 961.3 | 0.968 | 0 |  |
| casIncr (verified CAS loop, translated) | L3 | 43.3 | 7.9 | 6.1 | 6.1 | 640.9 | 0.991 | 0 |  |
| iris-lean's Counter.incr (CAS loop) | L3 | 43.5 | 7.7 | 4.4 | 7.9 | 505.8 | 0.938 | 0 |  |
| count locally, one Atomics.add at the end | L1 | 257.4 | 590.4 | 1084.6 | 886.4 | 4.5 | 0.965 | 0 | V8 keeps the count in a register: no memory traffic per increment |
| own padded shard, Atomics load+store (Shards' algorithm) | L2 | 42.8 | 106.9 | 192.4 | 217.5 | 18.3 | 0.958 | 0 |  |
| Shards.shardCount (verified, whole program on the pool) | L3 | 52.4 | 99.2 | 137.8 | 194.6 | 19.9 |  | 0 |  |
| Shards.shardCount → C11 → native | L4n | 99.3 | 154.8 | 334.0 | 307.4 | 11.9 |  | 0 |  |
| Shards.shardCount → C11 → wasm32 | L4w | 100.5 | 172.1 | 346.3 | 274.3 |  |  | 0 |  |
| faaIncr driver → C11 → native | L4n | 122.4 | 32.5 | 23.0 | 22.4 | 156.4 |  | 0 |  |
| faaIncr driver → C11 → wasm32 | L4w | 104.4 | 16.4 | 11.0 | 14.2 |  |  | 0 |  |
| Atomics.add from 2^31 − wrap | L1 |  | — |  |  |  |  | wrapped silently 2 | final value -2147479648 (Int32 wrapped, no error) |
| faaIncr from 2^28 − wrap | L3 |  | trap |  |  |  |  | 0 | trap: integer overflow: result outside the 29-bit encoding (HeapLang ints are unbounded) |

**S2 · Lock zoo: one theorem, very different locks**

| lane | kind | W=1 | W=2 | W=4 | W=8 | CPU ns/op (W=8) | fairness (W=8) | violations, all runs | note |
|---|---|--:|--:|--:|--:|--:|--:|---|---|
| no lock | L0 | — | — | — | — |  | 0.969 | torn reads 24554266, lost updates 12899009 |  |
| futex mutex by hand (Drepper), plain body | L1 | 27.6 | 14.5 | 11.2 | 11.2 | 275.4 | 0.988 | 0 |  |
| FutexMutex + critical section (verified) | L3 | 13.0 | 3.4 | 4.6 | 5.0 | 636.9 | 0.987 | 0 |  |
| CAS spin lock by hand, plain body | L2 | 27.9 | 3.5 | 2.1 | 0.766 | 4825.1 | 0.821 | 0 |  |
| SpinLock + critical section (verified) | L3 | 15.6 | 2.5 | 1.8 | 1.1 | 3614.1 | 0.831 | 0 |  |
| ticket lock by hand, plain body | L2 | 24.0 | 4.3 | 1.9 | 0.002 | 1972330.4 | 0.61 | 0 |  |
| TicketLock + critical section (verified) | L3 | 11.6 | 2.5 | 1.3 | 0.012 | 319498.5 | 0.501 | 0 |  |
| Web Locks (navigator.locks), one request per section | L1 | skipped |  |  |  |  |  |  | Node 22 has no navigator.locks |
| criticalFutex driver → C11 → native (50,000 sections per thread) | L4n | 39.0 | 12.5 | 14.0 | 14.0 | 200.4 |  | 0 |  |
| criticalFutex driver → C11 → wasm32 (50,000 sections per thread) | L4w | 26.7 | 10.7 | 9.6 | 11.5 |  |  | 0 |  |
| criticalSpin driver → C11 → native (50,000 sections per thread) | L4n | 40.1 | 6.8 | 2.5 | 1.5 | 2614.1 |  | 0 |  |
| criticalSpin driver → C11 → wasm32 (50,000 sections per thread) | L4w | 35.6 | 9.7 | 2.8 | 1.9 |  |  | 0 |  |
| kill test: spin lock by hand | L2 |  | hung |  |  |  |  | 0 | hung (no acquire within 1000 ms) |
| kill test: futex mutex by hand | L1 |  | hung |  |  |  |  | 0 | hung (no acquire within 1000 ms) |
| kill test: SpinLock (verified) | L3 |  | hung |  |  |  |  | 0 | hung (no acquire within 1000 ms) |
| kill test: TicketLock (verified) | L3 |  | hung |  |  |  |  | 0 | hung (no acquire within 1000 ms) |
| kill test: FutexMutex (verified) | L3 |  | hung |  |  |  |  | 0 | hung (no acquire within 1000 ms) |
| kill test: Web Locks | L1 | skipped |  |  |  |  |  |  | Node 22 has no navigator.locks |

**S4 · SPSC ring: the glitch counter**

| lane | kind | W=1 | W=2 | W=4 | W=8 | CPU ns/op (W=8) | fairness (W=8) | violations, all runs | note |
|---|---|--:|--:|--:|--:|--:|--:|---|---|
| ring by hand, tail published before the slot is written | L0 | — | — | — | — |  |  | 0 | 0 underruns in 1202 ticks |
| ring by hand, tail published before the slot is written, consumer flat out | L0 | — | — | — | — |  |  | stale or reordered 145691 |  |
| postMessage, block buffers transferred back and forth | L1 | 0.046 | 0.093 | 0.177 | 0.379 | 2036 |  | 0 | 6 underruns in 1205 ticks |
| postMessage, block buffers transferred back and forth, consumer flat out | L1 | 20.2 | 38.2 | 46.8 | 51.3 | 75.8 |  | 0 |  |
| ring by hand (Atomics indices, plain Float32 slots) | L2 | 0.048 | 0.096 | 0.192 | 0.383 | 1389.7 |  | 0 | 0 underruns in 1205 ticks |
| ring by hand (Atomics indices, plain Float32 slots), consumer flat out | L2 | 137.1 | 291.4 | 68.2 | 36.8 | 108 |  | 0 |  |
| SpscRing, one sample per item, payload in the heap | L3 | 0.048 | 0.096 | 0.192 | 0.383 | 1988 |  | 0 | 0 underruns in 1208 ticks |
| SpscRing, one sample per item, payload in the heap, consumer flat out | L3 | 3.6 | 6.2 | 2.1 | 0.725 | 5373.2 |  | 0 |  |
| SpscRing carries block numbers, samples in a Float32Array | L3p | 0.048 | 0.096 | 0.192 | 0.383 | 1601 |  | 0 | 0 underruns in 1207 ticks |
| SpscRing carries block numbers, samples in a Float32Array, consumer flat out | L3p | 84.0 | 225.3 | 97.5 | 27.6 | 143.6 |  | 0 |  |
| the verified ring, but the glue fills the block after pushing it | L0 | — | — | — | — |  |  | 0 | 0 underruns in 1208 ticks |
| the verified ring, but the glue fills the block after pushing it, consumer flat out | L0 | — | — | — | — |  |  | stale or reordered 53516 |  |
| tryPushEarly (HeapLang mutant: publishes, then writes) | M | — | — | — | — |  |  | 0 | 0 underruns in 1206 ticks |
| tryPushEarly (HeapLang mutant: publishes, then writes), consumer flat out | M | — | — | — | — |  |  | stale or reordered 25378 |  |

**S5 · Disjoint tiles: a parallel Mandelbrot without locks**

| lane | kind | W=1 | W=2 | W=4 | W=8 | CPU ns/op (W=8) | fairness (W=8) | violations, all runs | note |
|---|---|--:|--:|--:|--:|--:|--:|---|---|
| tiles claimed with next = next + 1 (no atomics) | L0 | — | — | — | — |  |  | double claims 9 |  |
| each Worker returns its band as a transferred buffer | L1 | 2.9 | 5.4 | 6.3 | 10.0 | 368.8 |  | 0 | slowest thread 2.21× the mean |
| one SharedArrayBuffer, a band per Worker (ParMapG by hand) | L2 | 2.8 | 2.3 | 6.3 | 7.7 | 344.9 |  | 0 | slowest thread 2.31× the mean |
| tiles of 8 rows claimed with Atomics.add (not verified yet) | L2 | 3.1 | 5.5 | 12.3 | 10.8 | 356.9 |  | 0 | slowest thread 2.02× the mean |
| ParMapG.pmapG with Mandel.mandel (verified, whole program on the pool) | L3 | 0.845 | 1.5 | 2.6 | 2.5 | 1141.4 |  | 0 | the time includes allocating, initialising and summing the image (on the 4-vCPU VM, about 2 ms at W = 1 and 5 to 7 ms above) |
| the same → C11 → native | L4n | 6.3 | 9.3 | 8.9 | 8.0 | 335.7 |  | 0 | the time includes allocating, initialising and summing the image (on the 4-vCPU VM, about 0.7 ms) |
| the same → C11 → wasm32 | L4w | 4.1 | 7.9 | 5.5 | 7.4 |  |  | 0 | the time includes allocating, initialising and summing the image (on the 4-vCPU VM, about 0.7 ms) |

**S11 · Lost-wakeup hunt: where the proof does not help**

| lane | kind | W=1 | W=2 | W=4 | W=8 | CPU ns/op (W=8) | fairness (W=8) | violations, all runs | note |
|---|---|--:|--:|--:|--:|--:|--:|---|---|
| event count: store, bump epoch, notify all | L2 | 0.031 | 0.040 | 0.044 | 0.048 | 32890 |  | 0 | 0 lost wakeups rescued by the 5 ms watchdog (200 cycles) |
| mutant: notify before the store | L0 | 0.030 | 0.002 | 0.003 | 0.012 | 39483.1 |  | 0 | 38 lost wakeups rescued by the 5 ms watchdog (200 cycles) |
| mutant: notify the state word, not the epoch | L0 | 0.000 | 0.000 | 0.001 | 0.002 | 51221.2 |  | 0 | 1575 lost wakeups rescued by the 5 ms watchdog (200 cycles) |
| mutant: notify one waiter of several | L0 | 0.028 | 0.000 | 0.001 | 0.002 | 48215 |  | 0 | 1338 lost wakeups rescued by the 5 ms watchdog (200 cycles) |
| FutexMutex critical section (verified) | L3 | 14.9 | 4.1 | 4.3 | 5.7 | 558.6 | 0.987 | 0 | 0 of 16644 futex waits ended only by the 20 ms timeout |
| FutexNoWake: futexWake removed (verified too) | L3 | 15.3 | 13.5 | 14.7 | 13.0 | 92.1 | 0.883 | 0 | 105 of 105 futex waits ended only by the 20 ms timeout |

Kinds: L0 broken (correctness counts only); L1 idiomatic JavaScript; L2 same algorithm, by hand in JavaScript; L3 verified, payload in the heap; L3p verified protocol, trusted data plane; L4n verified, C11 → native; L4w verified, C11 → wasm32; M HeapLang mutant, no proof. "—": not shown (a broken lane's speed means nothing). Throughput is operations per microsecond, all threads together, fuzz off; S4 counts samples, S5 pixels, S11 wakeups. Fairness is Jain's index over the threads' counts (1: equal shares).
<!-- results:end -->

What the numbers say, honestly:

- **The translation, not the proof, sets the verified lanes' speed.** Where the work is one
  hardware atomic (S1's FAA) the verified lane runs within 25% of `Atomics.add`, and the verified
  shards at 0.7 to 1.2 times the speed of the same algorithm by hand. Where a kernel does
  arithmetic or SC accesses, the translated JavaScript is slower than JavaScript by hand: every
  integer operation is checked for overflow, and every heap access is an atomic. For S5's
  Mandelbrot the hand-written bands are 1.5 to 5.6 times faster, a ratio that also counts the
  verified lane's setup and sum. For S2's critical section the translation costs 1.8 to 2.9 times
  at W = 1; at W ≥ 2 the futex mutex keeps that gap (1.8 to 4.3), while at W = 2 and 4 the
  verified spin and ticket locks run from parity to 1.8 times slower than the same locks by hand.
  At W = 8, oversubscribed, both swing from run to run: the verified spin lock from 1.4 times
  faster to 1.3 times slower, the ticket lock from 6 times faster to 10 times slower. In the
  stage-1 run, with the verified lock and cells on one cache line, they were 1.9 to 2.7 times
  slower at every W ≥ 2: much of that gap was false sharing, not the translation. The same
  HeapLang compiled through C runs at 0.9 to 4 times the speed of hand-written JavaScript
  natively, and 0.6 to 3.4 times as wasm32 (slowest: the futex mutex at W = 1). Each range spans
  three runs on the 4-vCPU CI machine (the tables show the first; a single ratio can move a lot
  from run to run), to be re-measured on the reference Mac.
- **The large wins come from not sharing**, and those are the protocols the proofs state:
  shards, disjoint bands, a ring's single writer per index. Locally counted increments (V8 keeps
  them in a register) are faster still and need no proof.
- **The proof does not choose the lock.** The three verified locks share one theorem; the spin and
  ticket locks collapse under contention and oversubscription, the futex mutex degrades
  gracefully, and none survives a dead holder. Web Locks do.
- **Bugs in the data plane pass the proof.** The verified ring with publish-before-write glue
  delivers stale blocks under stress, with the same proved kernels and theorems as the correct
  lane, and at audio pacing the bug almost never shows.
- **Liveness bugs pass the proof.** `FutexNoWake` is proved; every one of its futex waits ends
  only by the 20 ms timeout. Its throughput even goes up (a parked thread stops contending) while
  its fairness drops: throughput alone would call the bug an optimisation.
- **Stress tests are probabilistic.** The racy claimer of S5 doubled a handful of tiles in some
  runs and none in others; the ring bug shows only with the consumer flat out. The proofs are not
  probabilistic, but they cover less than the stress tests do.

### Against the design

Stage 1 of `docs/design.md`, with the review's corrections:

- **Done:** S1, S2 (with oversubscription and the kill test), S4 (a Worker on a 2.67 ms tick
  standing in for the AudioWorklet; both verified lanes; the bug in three places), S5 (static
  bands, a pointwise kernel), S11; the coverage table below; the harness (W sweep, fuzz mode, CPU
  time per operation, JSON); the page with a proof chip per lane; a CI job.
- **New proofs the plan did not foresee**, because the review showed stage 1 needed them:
  `Shards` (sharded counting is ParMap-style ownership, not `Counter`'s ghost fractions),
  `ParMapG` and `Mandel` (a grain size, and a pointwise kernel proved to compute its Lean function,
  so S5's render is covered from fork to join), `Critical` (one critical section for every `Lock`),
  and `FutexNoWake` (the lost-wakeup mutant, proved).
- **Not yet:** S3, the triple buffer (stage 2); latency percentiles, the page's frame gaps and the
  memory-growth fault; the wasm lanes in the page (they run in Node); a real AudioWorklet, which
  needs a translator mode without futex hints (worklets cannot block); the page and the wasm lane
  in CI.

## Every JavaScript threading mechanism, and its counterpart here

The mechanisms are the catalogue's (`docs/js-catalogue.md`, A1–A17).

| Mechanism | In this suite | iris counterpart | Verdict |
|---|---|---|---|
| Dedicated Worker (A1) | every lane of the page runs in module Web Workers; the HeapLang pool threads are Workers | HeapLang `fork`, run by a pool thread; a harness Worker calls kernels through `rt/embed.mjs` | threads: yes. `worker.terminate()`: none, HeapLang threads never die; the S2 kill test measures what happens |
| Node `worker_threads` (A11) | the Node harness, `rt/run.mjs` | as for Workers | as above. libuv's pool, `cluster` and `child_process` share no user memory: nothing to model |
| `SharedArrayBuffer` + `Atomics` load, store, add, compareExchange, exchange (A8) | every L1–L3 lane | HeapLang `Load`, `Store`, `FAA`, `CmpXchg`, `Xchg`, each emitted as one SeqCst Atomics operation (`cas_word_iff` for CAS) | the core. The proofs assume SC, which holds because every shared access is an Atomics operation |
| Plain typed-array access to shared memory (A8) | JS bodies under a lock (S2), ring slots (S4), bands (S5), the L3p data plane | none. Plain access is sound only under an ownership discipline, which is trusted; racy plain access needs a weak-memory logic iris-lean lacks | trusted (L3p) or out of reach |
| `Atomics.wait` / `notify` (A8) | futex mutexes (S2, S11), event counts (S11), a sleeping producer (S4) | `Hints.futexWait` / `futexWake`: HeapLang no-ops with proved specs, translated to wait and notify | safety is kept; wakeups are liveness, not proved (`FutexNoWake`) |
| `Atomics.waitAsync` (A8) | the launcher's main thread; S4's postMessage consumer | none in HeapLang: it lives in the runtime, where a delay is one more interleaving | runtime only |
| `Atomics.pause` (A8, A17) | not used (Node 22 lacks it) | would be one more proved no-op hint | none yet |
| `postMessage`, structured clone, Transferables (A5) | S4: block buffers transferred back and forth; S5: bands returned by transfer | none: HeapLang has no channels. The verified ring replaces it for data (S4); a channel spec could enter a proof only as a hypothesis | the browser enforces transfer at run time; nothing to prove |
| `MessageChannel` / `MessagePort` (A6) | S4's postMessage lane (one channel per pair) | none: a transport | host API |
| `BroadcastChannel` (A7) | not used | none useful | none, because its only honest spec is "may drop"; it gives no mutual exclusion |
| Web Locks (A9) | S2: a lane and the kill test (page only; Node 22 has no `navigator.locks`) | could be stated as a hypothesis instance of iris-lean's `Lock`, so `critical_spec` would cover its clients; not done | host API. Released when the holder dies, which no SAB lock is |
| `SharedWorker` (A2) | not used | none needed | none, because it shares no memory: a single-threaded actor, for which plain Lean suffices |
| Service Worker (A3) | not used | none | none, because it cannot block, shares no memory and is killed when idle; its hazards are lifecycle |
| AudioWorklet (A4) | S4's 2.67 ms consumer stands in for it, in a Worker | the consumer's side is `SpscRing.tryPop`: loop-free, no hints (worklets cannot block) | stage 2 runs it in a real `AudioWorkletProcessor`; deadlines are liveness |
| PaintWorklet, AnimationWorklet (A4) | not used | none | none, because one is stateless and the other never shipped |
| OffscreenCanvas, `transferToImageBitmap` (A5) | not used | none | the idiomatic way to render from a Worker without sharing a frame; S3 (stage 2) |
| WebAssembly threads, Emscripten pthreads (A10) | L4w lanes: HeapLang → C11 → `emcc -pthread`, in Node | the same HeapLang through the C target | trusted translator and toolchain. Not LeanUI's Lean → wasm64; not yet in the page |
| Cross-origin isolation, COOP/COEP (A12) | every lane needs it; the page refuses without it and shows only what is proved | none | a deployment precondition, and the reason LeanUI ships single-threaded |
| OPFS sync access handles, IndexedDB, localStorage (A13, A14) | not used | could be hypotheses: an exclusive handle as a points-to, a transaction as a logically atomic update | host APIs; not scheduled |
| One thread: `await`, microtasks, timers, `scheduler.postTask` (A15) | the page's main thread awaits its Workers | HeapLang `fork` over-approximates run-to-completion | not needed: plain Lean theorems suffice for a sequential update loop |
| WebGPU, WebGL compute (A16) | not used | none | none, because the GPU memory model is out of scope |
| Coming: shared structs with `Atomics.Mutex` / `Condition` (A17) | not available | `Atomics.Mutex` would be one more hypothesis `Lock` | watch |

## Building and testing

    iris/build.sh [--no-native] [--no-wasm]   # lake build, then dist/iris/{gen,rt,bench,native,wasm} and the page
    node iris/test/node.mjs                   # provenance, statistics, interpreter, embedding, every program on js, native, wasm
    node iris/bench/harness.mjs [--quick]     # the scenarios at W = 1, 2, 4, 8, fuzz off and on; exit 1 on a verified-lane violation
    node iris/rt/run.mjs dist/iris/gen/js/large_counter_futex.mjs --pool 4 --runs 5

`build.sh` runs Lake on the toolchain `iris/lean-toolchain` names (elan installs it), called by
path; `LEAN_BIN` overrides it. The first build needs the network: Lake fetches iris-lean at the
commit `iris/lakefile.toml` pins, with batteries and Qq. A cold build takes about 5 minutes on 4
vCPUs (iris-lean 3 minutes, then compiling it to native code once, which the generator needs);
afterwards the proofs check in seconds. `lake build` inside `iris/` checks every proof and the
axiom guard without generating anything.

The native lane is built when `cc` is available, the wasm lane when `emcc` is (on `PATH`, or named
by `EMCC`, with `EM_CONFIG` for an emsdk that is not activated); otherwise they are "not built",
and the tests and the harness skip them, except that the tests fail on a backend that `--backends`
names (CI passes `--backends js,native`). A program that does not compile fails the build.

`test/node.mjs` checks, in order:

1. **Provenance.** Every theorem the manifest names is in the axiom guard; the generator found the
   expected kernel in the programs that must call it; every library export is a kernel's constant,
   except the two named negative controls.
2. **Translator statistics.** Futex hints survive wherever FutexMutex is called, and a self tail
   call becomes a loop. A dropped hint changes no result (an earlier translator lost every
   `futexWake` and no value changed), so only these counts catch it.
3. **The reference interpreter**, under four schedules, gives the hand-worked result of every small
   program, and finds the racy counter's lost updates and the ring mutant's stale reads.
4. **The embedding**: the library kernels called from JavaScript give their results.
5. **Every program on every built backend** gives HeapLang's result, or traps where the encoding
   must; a backend built only in part fails, and so does one named in `--backends` and not
   built. The racy controls are recorded, never required: stress results are probabilistic.

The page (`dist/iris/index.html`) runs the same scenario modules in module Web Workers, with a proof
chip per lane (what is proved, the scope, what is trusted, what is not proved): its kernels and
theorems come from the manifest, the rest is written by hand, per lane kind in `bench/chips.mjs`
and per lane in `bench/scenarios/`. It needs cross-origin isolation; without it, it shows only
the theorem table and why. It is not linked from the site.

    .lake/build/bin/leanui serve dist --port 5391 --coop &
    node iris/test/page.mjs http://127.0.0.1:5391 chromium      # every scenario, then the refusal without COOP/COEP
    node iris/test/browser.mjs http://127.0.0.1:5391 chromium   # single programs on the browser launcher

(Playwright as `tests/browser/playwright.mjs` finds it; `LEANUI_PLAYWRIGHT_FROM` names another.)

CI (`.github/workflows/ci.yml`, job `iris`) builds with its own toolchain and a cached
`iris/.lake`, runs `test/node.mjs` on JavaScript and native code, and a short harness run that
fails on a verified-lane violation; the harness JSON is uploaded as the `iris-bench` artifact.
The wasm lane and the page test need Emscripten and the main build's `leanui` binary, and are not
in that job yet.

## The embedding ABI

A library module (`gen/js/lib_*.mjs`, one per entry of `Manifest.libs`) exports the proved
constants under their Lean names, each through its uncurried entry:

```js
import * as E from './rt/embed.mjs';
const lib = await import('./gen/js/lib_locks.mjs');
const heap = E.newHeap(lib);                         // once
const { K } = E.open(heap, lib);                     // in every thread that calls a kernel
const lk = K['FutexMutex.newlock'](E.UNIT), a = E.alloc(1, E.int(0)), b = E.alloc(1, E.int(0));
K['Critical.criticalFutex'](lk, a, b) === E.TRUE;    // critical_spec: always
```

Arguments and results are encoded words (`E.int`, `E.toInt`, `E.option`, `E.cell`). Any Worker
may open a heap: it gets its own allocation buffer. What the caller does around a call is glue.

## Files

| | |
|---|---|
| `LeanUIIris/Kernels/` | HeapLang kernels with their proofs, one structure per file |
| `LeanUIIris/Translate.lean`, `Translate/Encoding.lean` | the translator (programs and libraries); the word encoding and `cas_word_iff` |
| `LeanUIIris/Interp.lean` | the reference interpreter and the test schedules |
| `LeanUIIris/Programs.lean` | the programs translated: drivers around kernels, the harness's whole programs, the ring mutant, semantic edge cases |
| `LeanUIIris/Manifest.lean` | what is proved about each kernel; each program with its expected result; the libraries |
| `LeanUIIris/Axioms.lean` | the axiom guard |
| `Gen.lean` | `lake exe iris-gen <dir>`: the translated programs, the libraries and `manifest.json` |
| `rt/runtime.mjs`, `embed.mjs`, `pool.mjs`, `launch.mjs`, `run.mjs`, `worker.mjs` | the JavaScript runtime (fuzz mode, wait counters), the embedding, a pool thread, the launcher shared by Node and the page, the Node command |
| `rt/browser/` | the same launcher in a page, with module Web Workers |
| `rt/hl_rt.h`, `rt/hl_main.h` | the C runtime and its thread pool |
| `bench/` | the harness: `core.mjs` (runs a lane), `chips.mjs` (lane kinds, proof chips, the verdict), `kernels.mjs` (the hand-written JavaScript), `scenarios/`, the Node and page hosts, `harness.mjs`, `summary.mjs` |
| `page/` | the side-by-side page, copied to `dist/iris/` |
| `test/node.mjs`, `test/page.mjs`, `test/browser.mjs` | the tests above |
| `docs/` | the design, its review, the JavaScript catalogue, and the research record (`docs/research/`) |

## Adding a kernel

1. `LeanUIIris/Kernels/X.lean`: the HeapLang `Val`s and their proofs, and an import in
   `LeanUIIris.lean`.
2. `Manifest.lean`: an entry in `kernels` (its constants through `vals%`, its theorems), and a
   program that calls it in `programs` with the result HeapLang gives, or an export in `libs`.
3. `Axioms.lean`: a guard for each new theorem.
4. A lane in `bench/scenarios/`, naming the library and the exports it uses, so its chip is built.
5. `iris/build.sh && node iris/test/node.mjs && node iris/bench/harness.mjs --quick`.

## Updating iris-lean

iris-lean moves fast, and the proofs follow its proof mode closely. Change `rev` in
`lakefile.toml`, set `lean-toolchain` to the Lean release the new revision pins (its own
`Iris/lean-toolchain`), run `lake update` in `iris/`, then `iris/build.sh` and the tests, and
budget time for repairing proofs (`docs/research/iris-audit.md` lists the friction).
