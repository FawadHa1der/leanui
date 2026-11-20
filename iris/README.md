# Verified concurrency kernels: iris-lean, translated to threads

The verified side of a side-by-side threads suite: ordinary JavaScript doing multithreaded work on
a shared resource, next to the same work done by code proved correct in
[iris-lean](https://github.com/leanprover-community/iris-lean). The design and its review are in
`docs/design.md` and `docs/critique.md`; this directory is its stage 0, the foundation the
scenarios will run on.

iris-lean proves programs written in HeapLang, a small untyped language whose threads interleave
with sequentially consistent memory. Here such programs are proved, then translated, from the
very constants the theorems are about, by a translator written in Lean: into JavaScript over one
`SharedArrayBuffer` with `Atomics`, and into C11 with `seq_cst` atomics (built natively, or to
wasm32 with Emscripten pthreads). A reference interpreter for HeapLang tests the translation.

The proofs do not remove locks; an algorithm does, and the proof shows the algorithm is safe in
every interleaving. They say nothing about speed, progress or the memory model of plain accesses
("What is not proved", below).

The library and the apps do not depend on this directory: the main `lake build` and the wasm64
builds never read it. It has its own Lean (4.36.0, the release iris-lean pins; the main build is
on 4.34.0) and its own build in `iris/.lake` (about 700 MB, ignored by git). Nothing generated is
committed.

## How it fits together

```
LeanUIIris/Kernels/*.lean, iris-lean's Lib     a HeapLang Val (e.g. FutexMutex.acquire) and its theorem
        │  the same constant, imported
        ▼
LeanUIIris/Programs.lean, Manifest.lean        programs that call kernels, the result each must give,
        │                                      which kernels each calls and what is proved about them
        ▼
Gen.lean (lake exe iris-gen)  ──  Translate.lean (trusted)  ──▶ dist/iris/gen/js/*.mjs  ─▶ rt/runtime.mjs, Node or a page
                              │                             └─▶ dist/iris/gen/c/*.c     ─▶ rt/hl_rt.h, cc or emcc
                              └─ Interp.lean ─▶ the interpreter's results, in dist/iris/gen/manifest.json
```

The generator finds the kernels in each program by comparing the program's closures with the
proved constants (Lean's `=` on `Val`), and records them, their theorems and the program's closed
theorem, if it has one, in the manifest. A kernel therefore cannot drift from its proof: there is
no second copy to drift.

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
| `Hints` | `Kernels/Hints.lean` | `futexWait_spec`, `futexWake_spec` | Two functions that do nothing in HeapLang; the translator turns them into `Atomics.wait` and `Atomics.notify`. |
| `Counter` | iris-lean `Lib/Counter.lean` | `newcounter_mono_spec`, `incr_mono_spec`, `read_mono_spec`, `newcounter_contrib_spec`, `incr_contrib_spec`, `read_contrib_spec`, `read_contrib_spec_1` | A CAS-loop counter: a read returns at least any lower bound its caller holds, and per-thread fractional contributions add up to the value. Not logically atomic. |
| `AtomicCounter` | `Kernels/AtomicCounter.lean` | `faaIncr_spec`, `casIncr_spec`, `casIncr_seq` | `faaIncr` (one `faa`) and `casIncr` (a CAS loop) are logically atomic: `<<l ↦ n>> incr l <<l ↦ n+1 \| RET n>>`, so a client can open its own invariant around the call. |
| `Treiber` | `Kernels/Treiber.lean`, `Kernels/TreiberAtomic.lean` | `newStack_spec`, `push_spec`, `pop_spec`; `newStackA_spec`, `pushA_spec`, `popA_spec` | A pop returns a pushed element together with the resource its pusher gave up. The second set gives push and pop logically atomic specs against an abstract list (the Iris form of linearizability; the link to histories is not formalised in Lean). Nodes are never freed, which is why there is no ABA. |
| `SpscRing` | `Kernels/SpscRing.lean` | `rb_init`, `tryPush_spec`, `tryPop_spec` | A bounded single-producer, single-consumer ring: the i-th push hands `P i v` to the i-th pop. With `P i v := v = msgs[i]` that is FIFO with nothing lost or duplicated. |
| `ParMap` | `Kernels/ParMap.lean` | `pmap_spec` | A fork-join map of a pure function over an array, each thread owning a disjoint half: no invariant, no ghost state, no atomics. Pointwise only: a stencil (a blur) needs a different spec. |
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

For a HeapLang program built from the named constants, in every interleaving, under sequentially
consistent memory, with unbounded integers and a heap that never reuses a location:

1. no thread, forked ones included, ever gets stuck: no use of an unallocated cell, no CAS on
   values HeapLang cannot compare, no `faa` on a non-integer, no failed assertion;
2. if a thread returns, its value satisfies the specification: mutual exclusion as ownership of
   `R`, FIFO hand-off of `P i v`, a pop returning what a push gave up.

That is safety and partial correctness, nothing more.

## What is not proved

- **Liveness.** A program that deadlocks or spins forever satisfies every specification here.
  Fairness (TicketLock's FIFO order), starvation, lost wakeups and the termination of CAS loops
  are not stated, and iris-lean has no logic for them. "Wait-free" and "lock-free" are claims about
  the algorithms (`faaIncr` is one atomic step; the ring's operations have no loops; a Treiber CAS
  fails only because another succeeded), not theorems.
- **Weak memory.** HeapLang is sequentially consistent, and so is every translated program,
  because every shared access is emitted as a SeqCst atomic. The faster variants that use plain
  accesses for shared words (a ring that publishes its indices with plain stores, a seqlock with
  plain data) cannot even be stated: they need a weak-memory logic iris-lean does not have.
- **Performance.** Nothing at all.
- **The data plane.** Every program here keeps everything in the HeapLang heap. Where a later
  scenario keeps a payload in ordinary typed arrays (ring slots, pixels), the proof covers the
  protocol, not the JavaScript that touches the bytes; such lanes will say "verified protocol,
  trusted data plane".
- **The world around the program**: host APIs (`postMessage`, Web Locks, IndexedDB), a thread
  that is killed (HeapLang threads never die), and the JavaScript that calls a kernel.

## What is trusted

| Item | Status |
|---|---|
| The translator, `Translate.lean` (about 560 lines) | Not verified. Tested: each program's result on real threads must match the result HeapLang's semantics gives, worked out by hand or by the reference interpreter under four schedules (`test/node.mjs`). |
| The reference interpreter, `Interp.lean` | Reuses iris-lean's substitution, operators, heap and `Loc.fresh`; the evaluation contexts, head steps and scheduler are transcribed from `Semantics.lean`, not proved equal to `BaseStep`. |
| The encoding: one Int32 word per value | The CAS lemma is proved (`cas_word_iff`). That the runtimes build the same words (about 20 lines each) is trusted. Integers are 29-bit: a result outside ±2^28 traps instead of wrapping, so a completed run computes HeapLang's result but a run can stop. HeapLang's integers are unbounded, so the proofs say nothing here; only bounded words (the futex word) are known to fit. |
| SC on real hardware | JavaScript's and C11's memory models give sequential consistency to programs whose racing accesses are all SeqCst atomics, which is how every HeapLang access is emitted. Plain accesses initialise a fresh block before its pointer is published, and read immutable blocks: a happens-before argument, not a proof. |
| No free, no GC | The heap never reuses a location, as in HeapLang; that is why the Treiber stack has no ABA problem here. Memory only grows: a run that allocates per operation stops with "out of memory" when the buffer (256 MB by default, 64 MB in the tests) is full, so runs are sized for it. Unusable as is for a long-running page. |
| The runtimes, `rt/` | The allocator, the fork queue, the thread pools, the futex hints. A delayed thread is one more interleaving, so scheduling cannot break safety. The JS launcher grows its pool when a fork finds no idle thread; the C pool is fixed and can hang (liveness), never compute a wrong value. A trap (stuck, overflow, out of memory) ends the whole run: the launcher stops every thread, the C program exits. |
| Futex hints | Their no-op specs are proved; that the translator recognises exactly these two values is trusted. A wait is timed (20 ms), so a lost wakeup delays a waiter; it cannot strand it. |
| Prophecies | Erased by the translator; iris-lean proves erasure sound (`ProphErasure.lean`), but the translator's erasure is its own. |
| Drivers | Unproved, except the three whole programs. |
| Toolchains | Lean, Node/V8, the C compiler, Emscripten, the browser. |

## Building and testing

    iris/build.sh [--no-native] [--no-wasm]   # lake build, then dist/iris/{gen,rt,native,wasm}
    node iris/test/node.mjs                   # provenance, statistics, interpreter, then every program on js, native, wasm
    node iris/rt/run.mjs dist/iris/gen/js/large_counter_futex.mjs --pool 4 --runs 5

`build.sh` runs Lake on the toolchain `iris/lean-toolchain` names (elan installs it), called by
path; `LEAN_BIN` overrides it. The first build needs the network: Lake fetches iris-lean at the
commit `iris/lakefile.toml` pins, with batteries and Qq. A cold build takes about 5 minutes on 4
vCPUs (iris-lean 3 minutes, then compiling it to native code once, which the generator needs);
afterwards the proofs check in seconds. `lake build` inside `iris/` checks every proof and the
axiom guard without generating anything.

The native lane is built when `cc` is available, the wasm lane when `emcc` is (on `PATH`, or named
by `EMCC`); otherwise they are "not built" and the test skips them.

`test/node.mjs` checks, in order:

1. **Provenance.** Every theorem the manifest names is in the axiom guard, and the generator found
   the expected kernel in the programs that must call it.
2. **Translator statistics.** Futex hints survive wherever FutexMutex is called, and a self tail
   call becomes a loop. A dropped hint changes no result (an earlier translator lost every
   `futexWake` and no value changed), so only these counts catch it.
3. **The reference interpreter**, under four schedules, gives the hand-worked result of every small
   program.
4. **Every program on every built backend** gives HeapLang's result, or traps where the encoding
   must. Concurrent programs run three times; the larger ones do thousands of contended operations
   (4 threads × 20,000 increments, a 50,000-item ring, a Treiber stack). The racy control is
   recorded, never required: it loses updates on every backend and in the interpreter, but a
   stress test is probabilistic.

`test/browser.mjs` runs a few programs in module Web Workers on a cross-origin isolated page:

    .lake/build/bin/leanui serve dist --port 5391 --coop &
    node iris/test/browser.mjs http://127.0.0.1:5391 chromium

(Playwright as `tests/browser/playwright.mjs` finds it; `LEANUI_PLAYWRIGHT_FROM` names another.)

All timings so far come from a shared 4-vCPU cloud VM: read them as ratios, and re-measure on the
reference Mac, whose ARM memory model is weaker than x86's.

## Files

| | |
|---|---|
| `LeanUIIris/Kernels/` | HeapLang kernels with their proofs, one structure per file |
| `LeanUIIris/Translate.lean`, `Translate/Encoding.lean` | the translator; the word encoding and `cas_word_iff` |
| `LeanUIIris/Interp.lean` | the reference interpreter and the test schedules |
| `LeanUIIris/Programs.lean` | the programs translated: drivers around kernels, semantic edge cases |
| `LeanUIIris/Manifest.lean` | what is proved about each kernel; each program with its expected result |
| `LeanUIIris/Axioms.lean` | the axiom guard |
| `Gen.lean` | `lake exe iris-gen <dir>`: the translated programs and `manifest.json` |
| `rt/runtime.mjs`, `pool.mjs`, `launch.mjs`, `run.mjs`, `worker.mjs` | the JavaScript runtime, a pool thread, the launcher shared by Node and the page, the Node command |
| `rt/browser/` | the same launcher in a page, with module Web Workers |
| `rt/hl_rt.h`, `rt/hl_main.h` | the C runtime and its thread pool |
| `test/node.mjs`, `test/browser.mjs` | the tests above |
| `docs/` | the design, its review, the JavaScript catalogue, and the research record (`docs/research/`) |

## Adding a kernel

1. `LeanUIIris/Kernels/X.lean`: the HeapLang `Val`s and their proofs, and an import in
   `LeanUIIris.lean`.
2. `Manifest.lean`: an entry in `kernels` (its constants through `vals%`, its theorems), and a
   program that calls it in `programs`, with the result HeapLang gives.
3. `Axioms.lean`: a guard for each new theorem.
4. `iris/build.sh && node iris/test/node.mjs`.

## Updating iris-lean

iris-lean moves fast, and the proofs follow its proof mode closely. Change `rev` in
`lakefile.toml`, set `lean-toolchain` to the Lean release the new revision pins (its own
`Iris/lean-toolchain`), run `lake update` in `iris/`, then `iris/build.sh` and the tests, and
budget time for repairing proofs.
