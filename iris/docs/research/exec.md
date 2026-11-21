# Running iris-lean HeapLang programs on real threads: the execution path

> Kept from the research that preceded `iris/`. Paths starting `<scratchpad>/iris/` or `iris/`
> name the research scratchpad, which no longer exists: the evidence they cite is in this
> directory (`README.md` maps it), and the code is now in `iris/` itself (`../../README.md`).

Agent: exec. Date: 2026-11-20. Code: `iris/exec/` (paths below are relative to
`<scratchpad>/iris/`).
Machine: 4-vCPU cloud VM shared with other agents, Node 22.23.5, clang 18, Emscripten 6.0.5.
Every time below is a CI-machine number. Read the ratios, not the milliseconds, and re-measure on
the reference Mac.

## TL;DR

* **It runs, on all three targets.** `Exec.Translate` is a translator written in Lean. It takes the
  very `Iris.HeapLang.Exp`/`Val` constants that iris-lean proves things about (`SpinLock.acquire`,
  `TicketLock.*`, `Counter.incr`, `RwSpinLock.*`, `Spawn.spawn/join`, `Par.par`,
  `Quicksort.quicksort`, plus the Treiber stack proved by the iris-audit agent) and prints either
  (a) an ES module that runs on `worker_threads` over one `SharedArrayBuffer` with `Atomics`, or
  (b) a C11 file that uses `__atomic` seq_cst operations. The C file builds natively with
  `-pthread`, or to **wasm32 with Emscripten pthreads**, which is LeanUI's own Lean → C → wasm
  route, here with threads.
* **Tests: 37 of 37 pass on every backend** (JS, native C, wasm). Each translated program is
  checked against an executable HeapLang reference interpreter written in Lean. That interpreter
  reuses iris-lean's own `Exp.subst`, `BinOp.eval`, `UnOp.eval`, `State`, `State.initHeap` and
  `Loc.fresh`, and runs every program under 3 random schedules. The cases include right-to-left
  evaluation order, `rec f f` shadowing, `tdiv`/`tmod` by 0, unboxed equality, CAS on `none()`,
  prophecy erasure, fork/spawn/par, and small instances of every concurrent benchmark.
* **Speed against hand-written JS** (full table in §5). Translated to JS, the verified programs
  run at **0.96–1.3× hand-written JS for FAA/CAS counters**, **1.6–2.3× for contended locks**
  (the ticket lock reaches 6.5× once it convoys) and 1.1× for the Treiber stack. Single-threaded overhead is 1.2–3.5×. The translation pays for its uniform
  encoding: tag and overflow checks, an indirect call per closure application, and a seq_cst
  atomic on *every* heap access, including inside critical sections. The **C11 → native/wasm
  backends of the same HeapLang terms are at or below hand-written JS** in most rows. Under
  contention the algorithm dominates (FAA < CAS < futex mutex << spin < ticket), not the
  translation.
* **Pushing iris-lean further: a verified *blocking* lock.** HeapLang cannot block, so every
  verified iris-lean lock spins. I added two **"semantic no-op" futex hints**, proved in iris-lean
  to be no-ops, which the translator maps to `Atomics.wait`/`Atomics.notify`. I then wrote
  Drepper's 3-state futex mutex in HeapLang and **proved it correct in iris-lean**
  (`src/Exec/FutexMutexProof.lean`: `newlock_spec`, `acquire_spec`, `release_spec`, the same
  spec as iris-lean's `SpinLock`, with only the standard axioms). It is the best *translated*
  lock under contention: at 4 threads it is about 4× faster than iris-lean's verified `SpinLock`
  and 6× faster than `TicketLock`, and at 8 threads on 4 vCPUs about 8× faster than `SpinLock`.
  In JS it is still about 2× slower than the same algorithm written by hand. Native C and wasm
  come within about 1.1–1.4× of it.
* **The same generated modules also run in a browser:** headless Chromium 157, on a COOP/COEP
  page (`crossOriginIsolated: true`), with module Web Workers. The results are identical
  (`bench/browser.log`).
* **One trusted gap closed by proof (G2):** `src/Exec/EncodingProof.lean` proves `cas_word_iff`:
  for an unboxed expected value, machine-word equality coincides with HeapLang's structural
  equality. So a single `Atomics.compareExchange` on words is exactly HeapLang's `CmpXchg`.
* **What Iris does not give you:** compiled code, termination or liveness, weak-memory
  reasoning, bounded ints, `free`, or blocking. Each of these is a trusted gap. They are listed
  precisely in §6, each with what would close it.

## 1. The pipeline

```
iris-lean Lib (proved)            drivers (Exec/Programs.lean, unproved glue)
  SpinLock.acquire : Val ─┐         counterSpin t k : Exp := hl% let c := ref(#0); ... &SpinLock.acquire lk ...
  Counter.incr     : Val ─┼──────►  ONE Lean term of type Iris.HeapLang.Exp
  Par.par, Spawn.* : Val ─┘                    │
                                    Exec.Translate.translate (Lean, ~590 lines, NOT verified)
                         ┌─────────────────────┴──────────────────────┐
                 out/<p>.mjs  + rt/runtime.mjs                 out/c/<p>.c + rt/hl_rt.h, hl_main.h
                 rt/run.mjs: worker_threads pool,              clang -O2 -pthread  → out/native/<p>
                 one SharedArrayBuffer                         emcc -pthread       → out/wasm/<p>.{js,wasm}
```

The translator is written in **Lean**, not JS or Rust, for three reasons. (1) Its input is the
Lean constant itself: `&SpinLock.acquire` in a driver *is* the `Val` that `acquire_spec` is
stated about. There is no re-parsing and no second copy that could drift from the proof. (2) The
derived `DecidableEq` on `Val` comes for free, and the translator uses it to deduplicate closures
and to recognise the futex intrinsics. (3) If the translator is ever verified, the proof would
live in the same Lean development as `BaseStep`.
`lake env lean --run src/Gen.lean out` translates all 79 programs in about 1 s. With the reference
interpreter running the 37 test programs under 3 schedules each, it takes about 30 s.

## 2. Design decisions (and why)

**Value encoding: one Int32 word per HeapLang value.** The low 3 bits are a tag:

| tag | meaning | notes |
|---|---|---|
| 0 | `int n`, `n = w >> 3` | 29-bit signed; `+`/`-` work directly on the words; overflow → trap |
| 1 | `loc l` (cell index) | `l +ₗ i` is word addition |
| 2/3, 4/5 | `injL`/`injR` of an int/loc literal | immediate, so `none()`, `some(#c)` and `some(#l)` cost no allocation |
| 6 | pointer to an immutable block `[hdr, …]` | pairs, closures, `injL/injR` of boxed values |
| 7 | unit / true / false / poison, and `injL`/`injR` of them | `none() = injl(#())` is the word 39 |

The point of this layout: **every HeapLang value that `Val.isUnboxed` accepts has exactly one
immediate word.** HeapLang's `=` and CmpXchg are only defined when `Val.compareSafe` holds (at
least one side unboxed), and under that condition structural equality *is* word equality. So
`cas` is one `Atomics.compareExchange` (`Atomics.compareExchange(H, l>>3, expected, new) === expected`).
The Treiber stack's `cas(s, hd, some(ref …))` and Spawn's `none()`/`some(v)` protocol work
unchanged. When both sides are boxed, HeapLang is stuck, and the proof rules that out.

**Heap.** The heap is one `SharedArrayBuffer`/`int32_t[]`. Allocation is a bump allocator with
per-thread 32K-cell TLABs; refilling a TLAB costs one `Atomics.add`. There is **no free and no
GC.** That matches HeapLang: `Free` turns a cell into `none` and `Loc.fresh` never reuses it. It
is also why the verified Treiber stack has no ABA problem here. It is a real memory leak, though:
`qsort_20k` uses about 13 MB of heap per run.

**Memory accesses.** HeapLang `Load`/`Store`/`CmpXchg`/`Xchg`/`FAA` become
`Atomics.load/store/compareExchange/exchange/add` in JS and `__atomic_*_n(…, __ATOMIC_SEQ_CST)` in
C. All shared accesses are SC atomics, so every execution is sequentially consistent: the
interleaving model Iris reasons about (§6, G4). Plain accesses appear in exactly two places:
initialising a freshly allocated block before its pointer is published, and reading immutable
blocks (pairs, closure environments) whose pointer was obtained through an SC atomic or the fork
queue. Both are justified by happens-before through synchronizes-with in the JS and C11 memory
models. This is an argument, not a proof.

**Evaluation order.** HeapLang evaluates **right to left** (`ECtxItem`: `appR`, `binOpR`,
`pairR`, `storeR` and `cmpXchgR` go first). The translator hoists every operand into a `const` in
that order. The test `(faa(l,1), faa(l,10))` yields `(10, 0)`. A naive left-to-right JS translation
would give `(0, 1)`.

**Closures are defunctionalised.** Each `rec f x := …` gets a code id. A closure is a block
`[code<<3|4, free vars…]` in the *shared* heap, so a closure can be stored in a cell, sent to
another thread, or forked. `callv` dispatches through `FUNS[code]`. A closed `Val.rec_` (every
library function) becomes a static closure at a fixed address. Known calls are compiled as direct
calls and **uncurried** (`rec f x y z := …` gets a 3-ary entry). **Self tail calls become loops**,
which is essential here: every spin loop in HeapLang is a self-recursive function, and JS has no
tail-call optimisation. Other recursion stays recursion. `Quicksort.partition`/`append` recurse to
the depth of the list, which overflowed the default 4 MB worker stack at 20k elements, so the
launcher now gives workers 64 MB (C: 8 MB pthread stacks).

**Substitution semantics, matched exactly.** `betaS` substitutes `f` before `x`. So in
`rec f f := f` the body refers to the closure, not the argument. The environment is built so that
`f` shadows the first parameter and the later curried parameters shadow both (test
`rec-self-shadows-arg`).

**Fork.** `fork e` builds the thunk closure and pushes its word onto an MPMC ticket queue in the
shared heap. Pool threads take tickets and park with `Atomics.wait` (C: futex) until their slot is
filled. HeapLang has unboundedly many threads. In JS the launcher **grows** the pool on demand: when
a fork finds no waiting thread it bumps a counter, and the Node main thread, which never runs
HeapLang code, watches that counter with `Atomics.waitAsync` and spawns workers. The C runtime's pool
is fixed: a program that needs more simultaneously live threads than the pool can hang (liveness),
but never compute a wrong value. A delayed thread is just an unfair schedule, and Iris adequacy
covers every schedule.

**Prophecies are erased.** `NewProph` becomes a dummy literal, and `Resolve e p v` evaluates `v`, then
`p`, then `e`. iris-lean has the theorem that justifies this
(`Iris/HeapLang/ProphErasure.lean`, `erasure`: an adequate program stays adequate with prophecies
erased). The erasure *function* there is not the one I implemented, though: mine is trusted.

**Futex hints (the "semantic no-op" trick).** HeapLang has no blocking primitive, so every
wait (`acquire`, `join`, ticket wait) is a spin. Spinning is fine with fewer threads than cores and
terrible once threads outnumber them. `src/Exec/Intrinsics.lean` defines

```lean
def futexWait : Val := hl_val% λ futex_wait_loc futex_wait_expected, #()
def futexWake : Val := hl_val% λ futex_wake_loc, #()
```

and `src/Exec/Hints.lean` **proves in iris-lean** `{{ True }} futexWait l v {{ RET #(); True }}`
and the same for `futexWake` (`#print axioms`: only `propext`, `Classical.choice`, `Quot.sound`).
With them, `src/Exec/FutexMutexProof.lean` proves **Drepper's futex mutex** correct (mutual
exclusion, with `R` handed over), using the invariant
`∃ n, l ↦ #n ∗ ⌜n ∈ {0,1,2}⌝ ∗ (if n = 0 then locked γ ∗ R else True)`. `release` uses
`faa(l, -1)`; when that returns 2 (contended), it stores 0 and wakes one waiter. In the proof the
token's exclusivity rules out "the invariant already holds R". The waits are discharged by
`wp_apply futexWait_spec` (the call is opaque to `wp_pures` because `futexWait` is a constant).
The contended path `slow` is a separate function, proved by Löb induction over the observed word.
The invariant also proves the lock word stays in {0,1,2}, so the 29-bit encoding cannot overflow
*for this word* (G3), without any extra work.
The translator recognises these two values by `DecidableEq` and emits
`Atomics.wait(H, l, v, 20ms)` / `Atomics.notify(H, l, 1)` (C: `emscripten_futex_wait`/`SYS_futex`).
This keeps every Iris safety result: a futex wait writes no memory and only *delays* the calling
thread, so a delay is one more interleaving of the same HeapLang steps. The finite timeout means
a lost wake-up can only cost time, so we never need a liveness proof of the wake-up protocol
(Iris cannot give one). With this, `Exec.Hints` contains Drepper's 3-state futex mutex, iris-lean's
`SpinLock` with hints added, and a `Spawn`/`Par` whose `join` parks. One bug this exposed: the
first version lost every `futexWake`, because `futexWake l` is itself a one-argument beta-redex and
the translator's `let` rule fired first. Semantics were preserved, since the hint is a no-op, but
its effect was gone. The intrinsic check now runs before the `let` rule. **Lesson: the translator
can silently drop performance-relevant structure without any test failing, so the stats counters
in `out/manifest.json` (`futex-wake: 1`) are worth checking.**

## 3. How to run

```
cd iris/exec/iris-lean/Iris            # copy of upstream iris-lean 100ed29 (+ an `Exec` lean_lib)
TC=~/.elan/toolchains/leanprover--lean4---v4.36.0/bin
$TC/lake build Exec                     # translator, programs, interpreter, hint proofs
$TC/lake env $TC/lean --run ../../src/Gen.lean ../../out     # -> out/*.mjs, out/c/*.c, out/manifest.json
cd ../..
node rt/run.mjs out/counter_spin_t4.mjs --pool 4 --runs 3    # one program on worker_threads
node bench/run-tests.mjs 3 js|native|wasm                    # differential tests (37 programs)
bench/build-native.sh; bench/build-wasm.sh                    # C backends (wasm uses an existing emsdk read-only)
node bench/side-by-side.mjs --runs 5 --reps 2                 # -> bench/results.{md,json}  (--only <regex>)
node bench/browser-run.mjs counter_futex_t4:4 treiber_t4:4    # same modules in headless Chromium (COOP/COEP)
```

## 4. Testing: what was checked against what

* `bench/tests.log`, `bench/tests-native.log`, `bench/tests-wasm.log`: **37/37 pass on each
  backend.** 24 sequential edge cases each have a hand-derived HeapLang result, cross-checked
  against the reference interpreter. 13 small concurrent instances are compared with the
  interpreter's result under 3 random schedules (`counter_{cas,faa,spin,ticket,futex,spinhint}`,
  `rw`, `treiber`, `par_sum`, `pfib`, `pfib_hint`, `qsort`, `fork_many`).
* The **reference interpreter** (`src/Exec/Interp.lean`, 200 lines) reuses iris-lean's computable
  definitions wherever they exist. Only the evaluation-context decomposition, the head-step case
  split and the scheduler are mine, transcribed from `ECtxItem.fill` and `BaseStep`. It is not
  proved equal to `BaseStep` (§6, G1).
* **Provenance of the "verified" labels.** The iris-lean `Lib` values are used as-is (upstream
  `100ed29`). For the Treiber stack, I checked that `iris/iris-audit/proofs/Treiber.lean`
  elaborates against the same iris-lean and prints `push_spec`/`pop_spec` with only `propext`,
  `Classical.choice` and `Quot.sound`, and that its `newStack`/`push`/`pop` text is byte-identical
  to the copy in `Programs.lean`. `FutexMutexProof`, `Hints` and `EncodingProof` are mine and
  build as part of `lake build Exec`.
* **Negative control.** `counterRacy` (`c ← !c + #1` without a lock) loses updates in the
  *HeapLang interpreter* (31/33/32 of 45 under 3 schedules) and on real threads (e.g. 252423 of
  800000). The race belongs to the program, not to the translation. No Iris proof of "result =
  t·k" exists for it, because the invariant cannot be re-established between the load and the
  store.
* **The one deliberate divergence.** `#268435455 + #1` is `268435456` in HeapLang (the
  interpreter says so). Every backend **traps** instead. The same thing happened, unplanned, in two
  benchmark drivers: `Σ i*i` over 4M elements and the Treiber sum over 100k pushes. Both are fine
  HeapLang programs whose values exceed 2^28, so the translation stopped with "integer overflow"
  instead of printing a wrong number (`seq_sum_overflow` row).

## 5. Results: side by side

Each cell is the median over 5 runs in a process, then the median of 2 processes. Times are in
ms, total operations in parentheses. Columns: hand-written JS; then the iris-lean HeapLang program
translated to JS, to native C, and to C → wasm. Full table with results and ratios:
`iris/exec/bench/results.md` / `results.json`. The machine was **busy**: load average 19–21
during the run, from other agents' Lean/Emscripten builds (the run was at `nice -5`). The
contended rows are noisy, with run-to-run spread up to 2–3× (compare
`bench/side-by-side.run1-partial.log`). Trust the ordering, not the digits.

| scenario (threads, ops) | JS hand-written | HL → JS | HL → C native | HL → C → wasm |
|---|---|---|---|---|
| FAA counter (1, 200k) | 2.4 | 3.0 | 2.1 | 2.5 |
| CAS counter = `Counter.incr` (1, 200k) | 3.7 | 4.4 | 2.1 | 2.1 |
| spin lock = `SpinLock` (1, 200k) | 4.4 (all-SC body: 7.5) | 7.6 | 3.8 | 4.0 |
| ticket lock = `TicketLock` (1, 200k) | 5.7 | 20.0 | 3.5 | 4.2 |
| futex mutex = `FutexMutex`, proved (1, 200k) | 4.8 | 8.4 | 3.8 | 4.3 |
| FAA counter (4, 800k) | 86 | 89 | 34 | 75 |
| CAS counter = `Counter.incr` (4, 800k) | 137 | 147 | 91 | 86 |
| spin lock = `SpinLock` (4, 800k) | 320 (all-SC body: 434) | 524 | 399 | 413 |
| ticket lock = `TicketLock` (4, 800k) | 355 | 817 | 521 | 390 |
| **futex mutex = `FutexMutex`** (4, 800k) | **62** | **132** | **71** | **86** |
| `SpinLock` + hints (4, 800k) | – | 272 | 228 | 120 |
| no lock, racy (4, 800k) | 1.1 → **~400k of 800k** | 80 → ~325–390k | 55 → ~370–430k | 53 → ~375k |
| spin lock (8 on 4 vCPU, 400k) | 266 | 417 | 225 | 310 |
| CAS counter (8 on 4 vCPU, 400k) | 80 | 77 | 41 | 49 |
| **futex mutex (8 on 4 vCPU, 400k)** | **26** | **52** | **33** | **34** |
| ticket lock (8 on 4 vCPU, only 16k) | **3140** | **20573** | **2659** | 10 (threads did not overlap: `max_live` 3; reruns 4 ms / 142 ms, native rerun 12.8 s) |
| readers/writer = `RwSpinLock` (4, 400k, 10% writes) | 86 | 160 | 74 | 112 |
| Treiber stack (4, 80k push+pop) | 13.4 | 15.0 | 12.6 | 16.3 |
| Σ over 4M, sequential | 9.8 | 22.9 | 10.4 | 8.1 |
| Σ over 4M, `Par.par` halves (2) | 5.5 | 16.0 | 4.0 | 4.2 |
| Σ with `i*i` (exceeds 2^28) | – | **trap** | **trap** | **trap** |
| fib 32, sequential | 20.4 | 24.5 | 13.7 | 19.4 |
| fib 32, 4 leaves via `Par` (4) | 19.3 | 35.0 | 29.2 | 25.5 |
| fib 32, 64 leaves, spin-join (63 forks) | – | 208 | 188 | 88 |
| fib 32, 64 leaves, **hinted join** | – | 62 | **9.2** | **12.1** |
| `Quicksort.quicksort` 20k (1) | 29.6 (`Array.sort`: 10.3) | 35.1 | 27.7 | 13.3 |
| 1000 tiny tasks | 4.9 (postMessage pool) | 55.9 (pool grows to ~300 Workers) | 3.5 | 4.1 |
| 50 tasks, a new Worker each | 920 | – | – | – |

Browser (headless Chromium 157, COOP/COEP, module Workers, `bench/browser.log`): `SpinLock`
counter 457 ms, `FutexMutex` counter 93 ms, Treiber 13.4 ms, hinted `pfib` 38 ms. The results
are correct and the times are in the same range as Node.

How to read it:

1. **Single-thread overhead of the translation** (T=1): HL→JS costs 1.2–1.8× hand-written JS for
   counters and locks, and 3.5× for `TicketLock`, whose lock is a heap *pair* of refs, so every
   `fst(lk)` is an extra read. The C backends of the same terms are at or below hand-written JS.
   So the word encoding and the checks are cheap. What costs is V8 running the generated code: an
   indirect `callv` per closure call (the `rep` loop calls a closure), `const` temporaries,
   overflow checks, and **seq_cst accesses inside critical sections**. The hand-written spin lock
   with an all-SC body takes 7.5 ms against 4.4 ms with a plain body, about the whole gap to the
   translated 7.6 ms. Using plain accesses there is precisely what Iris cannot justify (G4).
2. **Under contention the algorithm dominates.** FAA is 1.0× and CAS 1.07× hand-written at 4
   threads, and the CAS loop is even 0.96× at 8 threads. Locks are 1.6–2.3×.
3. **Blocking beats spinning, and is now verifiable.** The futex mutex is the best lock in every
   column at T≥2: 4× (`SpinLock`) and 6× (`TicketLock`) faster at 4 threads, 8× faster than
   `SpinLock` at 8 threads on 4 vCPUs. Its hand-written JS twin is still about 2× faster than the
   translation (62 vs 132 ms), and native/wasm land in between (71/86 ms). Simply adding hints
   to `SpinLock` helps much less, because its release notifies unconditionally (native 27.7 ms vs
   3.8 ms uncontended: a syscall per release). Drepper's 3-state protocol exists to avoid exactly
   that.
4. **Oversubscription:** the ticket lock (verified FIFO hand-off) collapses in *every*
   implementation once threads outnumber cores: 16k operations take seconds. It is bimodal
   (it convoys only when the threads actually overlap), and the proof says nothing about it,
   because it is a liveness/performance property.
5. **The racy control** loses about half the updates in all four columns. The hand-written plain
   `++` is 70× faster than the SC translation, and just as wrong. A translation can only make a
   racy program slower, never correct: Iris's contribution is that the *proof attempt fails*.
6. **Fork/join:** coarse `Par.par` is as good as hand-written in C (4.0 vs 5.5 ms). HL→JS is
   slower (16 ms) mainly because the sequential loop itself is 2.3× slower. A deep `Par` tree
   with spin-join (63 forks, at most about 30 live threads on 4 vCPUs) is pathological (88–208
   ms). The **hinted join** (proof unchanged up to no-op steps) cuts it to 62 ms (JS), 9.2 ms
   (native) and 12.1 ms (wasm).
7. **Lock-free Treiber stack: near parity (1.12×)**, although each node is 4 cells (a ref plus a
   pair block, never freed) against 2 by hand.
8. **Verified sequential code is not slow:** `Quicksort.quicksort` is 1.19× the same algorithm on
   GC'd JS objects, and the wasm build (13 ms) beats both. `Array.prototype.sort`, a different
   algorithm, takes 10 ms.
9. **Thread creation:** the JS launcher's on-demand growth makes a burst of 1000 forks cost 56
   ms. Workers start slowly, so the pool over-provisions to about 300. Fixed pools (C: 3.5 ms) and
   a postMessage pool (4.9 ms) are 10× better, and a fresh Worker per task costs about 18 ms
   each. A production runtime should pre-size the pool and grow it lazily, with hysteresis.

## 6. What is trusted, precisely, and what would close each gap

| # | Trusted item | Why it matters | What would close it |
|---|---|---|---|
| G1 | **The translator** `Exec.Translate` (≈590 lines of Lean; peepholes: `cas`/`fst(cmpXchg)`, `let`, uncurrying, self-tail-call → loop, static closures, intrinsics) | Iris's theorems are about `BaseStep`, not about the JS/C text | Write a small-step semantics for the target subset (a "JSlite" over a word heap) in Lean and prove a forward simulation `translate e` ⊑ `e` (per-thread, plus an interleaving lemma, since every shared step is one atomic op). Cheaper first step: prove the reference interpreter's `step` sound for `BaseStep`, and keep differential testing (done) |
| G2 | **Value encoding** (29-bit ints, tags, uniqueness of unboxed words) | `cas` correctness depends on "structural = word equality for compare-safe values" | **Partly closed:** `EncodingProof.cas_word_iff` proves it for the Lean-side encoding (`encLit`/`encInj`) against any representation of the cell value (an immediate or a tag-6 pointer). Still trusted: that `mkInjL`/`mkInjR`/literal emission in the JS/C runtime compute the same words (≈20 lines), and that block pointers carry tag 6 |
| G3 | **Unbounded ints vs 29-bit words** | HeapLang `Int` is unbounded. We trap on overflow (fail-stop), so every *completed* run computes the HeapLang result, but runs can stop | Either (a) prove in Iris that values stay in range (add `⌜|n| < 2^28⌝` to invariants: easy for counters, it is just another conjunct), or (b) switch to a BigInt64/boxed-bignum encoding (slower; BigInt64 `Atomics` allocate) |
| G4 | **SC vs the JS/C11/wasm memory models** | Iris reasons about interleavings (SC). We use **only** seq_cst atomics for shared accesses. JS's model guarantees SC for programs whose only racing accesses are SeqCst `Atomics` of one size, and C11 the same for `memory_order_seq_cst` | Fine as long as the translation never uses plain/relaxed accesses for shared cells. The *cost* is real (`spin-sc` vs `spin`: a SeqCst load/store in the critical section). To use plain or acquire/release accesses you need a weak-memory logic (iRC11, Cosmo, Rocq Iris's `gpfsl`), which iris-lean does not have, or a proof that the access is unshared (ownership: `l ↦ v` exclusively held, a property Iris *does* know but does not export to the translator) |
| G5 | **Plain init/immutable-read argument** (happens-before) | Initialising a fresh block with plain stores, then publishing it with an SC atomic | A memory-model lemma ("publication through SC atomics"), standard but unproved here. Alternatively make every write atomic (costs a few %) |
| G6 | **No `free`, no GC** | Matches HeapLang exactly (and gives ABA-freedom), but leaks: unusable for a long-running UI | A tracing GC over the word heap. It is semantically invisible (it reclaims only unreachable cells), but that needs a proof about reachability in HeapLang, and **reuse breaks the "fresh location" reasoning that makes Treiber ABA-free**. Programs relying on that would need hazard pointers/epochs, re-verified |
| G7 | **Scheduling** | HeapLang threads are unbounded and the scheduler is arbitrary (not even fair). JS pool grows on demand; C pool is fixed | Safety is unaffected (adequacy covers all schedules). Termination needs fairness *and* a liveness logic (Iris does not do liveness; TaPL/Trillium/LiLi-style extensions do). A spin-`join` tree (`pfib d=6`) needs one OS thread per live HeapLang thread |
| G8 | **Runtime** (`rt/runtime.mjs`, `rt/hl_rt.h`): allocator, fork queue, `callv`, overflow checks, decode | Ordinary concurrent code, tested only | Small enough to verify separately (e.g. the ticket queue in HeapLang + Iris itself, then translate it!) |
| G9 | **Prophecy erasure as implemented** | Theorem exists (`ProphErasure.erasure`), my erasure function is separate | Use iris-lean's erasure function directly in the translator |
| G10 | **Futex hints** | Recognition by `DecidableEq` plus two runtime functions. The no-op specs *are* proved | Proved no-ops reduce the trust to "Atomics.wait has no effect on memory", which is in the JS spec |
| G11 | **Drivers** (`rep`, `spawnN`, `joinAll`, `onThreads`), `HintedSpinLock`, `HintedSpawn` are **not proved**. **`FutexMutex` is proved** (`FutexMutexProof.lean`) | The *library* functions are verified; whole-program claims like "counterSpin returns t·k" are not | Prove the drivers with existing Lib specs: `Counter.lean`'s contribution counter (`ccounter`) plus `Spawn.join_spec` give "result = t·k" for `counterCas`. `HintedSpinLock`/`HintedSpawn` are the iris-lean proofs plus one `wp_apply futexWait_spec`/`futexWake_spec` each |
| G12 | **Toolchains**: Lean compiler for the translator, V8/Node, clang, Emscripten, the browser | As for any program | n/a |

What Iris proofs *do* buy at runtime, honestly: **for the library code, if a thread finishes,
the property in its spec holds** (mutual exclusion, so `!c` is never torn; Treiber pops return
pushed values; `join` returns the spawned thread's value), and **no thread ever gets stuck** (no
CAS on non-comparable values, no use of an unallocated location, no non-int `faa`), **under every
interleaving**. That is exactly the class of bug that lock-free JavaScript gets wrong, as the
racy row shows. Iris says nothing about speed, fairness, termination or deadlock-freedom: the
TicketLock proof establishes mutual exclusion, not FIFO fairness as a liveness property. It also
says nothing about the JS that surrounds the translated module.

## 7. What this means for LeanUI (honest)

* **Every multi-threaded variant needs `SharedArrayBuffer`, which needs a cross-origin-isolated
  page (COOP + COEP headers).** That is exactly why LeanUI's wasm build is single-threaded
  (`docs/TOOLCHAIN.md`, "Why single-threaded"). Verified lock-free code does not change that
  constraint, so threads stay opt-in, for pages that can send those headers.
* The C11 backend fits LeanUI's toolchain, which already goes Lean → C → Emscripten. But it is a
  *separate* wasm module with its own shared memory: HeapLang values are not Lean objects, and
  LeanUI's runtime is wasm64 without threads. Mixing the two would need the threaded runtime
  (the QED64 fork has one) plus a marshalling layer.
* HeapLang is a small untyped ML. It is a good language for **the concurrent kernel** (a lock, a
  queue, a work-stealing deque, a counter, a ring buffer between a UI thread and a worker), not for
  a UI. The realistic architecture: an iris-lean-verified kernel translated to JS/wasm, called
  from hand-written or Lean-generated code through a narrow API. The proof then covers only the
  kernel.
* "Without locks" is not what Iris gives you. Iris lets you *verify* lock-free code (CAS loops,
  FAA, Treiber, ticket protocols) and locks alike. Whether lock-free is *faster* is a separate,
  empirical question, and the table answers it per scenario. A blocking futex mutex beats every
  spinning algorithm once threads outnumber cores.

## 7b. Which JavaScript concurrency mechanisms this execution path covers

The labels A1–A17 and B1–B20 are those of `iris/js-catalogue.md` (the catalogue agent).

| mechanism | status here |
|---|---|
| A8 SharedArrayBuffer + Atomics | **the target**: every HeapLang heap op is one `Atomics` op on an Int32Array |
| A11 Node `worker_threads`, A1 dedicated Workers | **runs** in Node (`rt/run.mjs`) and in **Chromium** (`rt/browser/index.html` + module Workers, served with COOP/COEP by `rt/browser/serve.mjs`, driven by `bench/browser-run.mjs`). The page's main thread never blocks: it uses `Atomics.waitAsync` |
| A10 WebAssembly threads / Emscripten pthreads | **runs**: the C11 backend + `emcc -pthread` (37/37 tests) |
| A12 COOP/COEP | **required** by everything above. This is the reason LeanUI ships single-threaded |
| `Atomics.wait`/`notify` (futex) | **expressible** only through the two proved-no-op hints. They must not run on a browser main thread (`Atomics.wait` throws there), which is why the HeapLang main thread always runs in a worker |
| A4 AudioWorklet | could host translated code that never waits (spin-only); hints must be disabled there |
| A5–A7 postMessage / MessageChannel / BroadcastChannel | not HeapLang primitives. A verified queue in the shared heap replaces them for data |
| A2 SharedWorker, A3 Service Worker, A9 Web Locks, A13 OPFS, A14 IndexedDB, A16 GPU | **out of reach**: not shared-memory (or not the same agent cluster). Iris has nothing to say about them without a new language |
| A15 one-thread concurrency (async/await, microtasks) | a different backend would be needed: `fork` becomes a microtask, with a yield at every loop back-edge (HeapLang spin loops never yield). Not built |

| pattern | run here | iris-lean status |
|---|---|---|
| B1 shared counters | FAA, CAS (`Counter.incr`), lock-protected, racy control | library verified; driver not |
| B2 mutual exclusion | `SpinLock`, `TicketLock`, **futex mutex** | all three verified (the futex mutex by me) |
| B6 readers/writer | `RwSpinLock` | verified |
| B10 fork-join | `Par.par`, recursive `pfib`, hinted join | `par` verified, hinted join = proof + no-op |
| B9 lock-free stack | Treiber | verified by the iris-audit agent |
| B3 semaphore, B4 condvar/eventcount, B5 barrier, B7 once, B8 SPSC ring (arrays: `allocn` + `+ₗ` are supported), B16 cancellation flag, B20 hash map | not written | all expressible in HeapLang and translatable today; each needs a program + proof |
| B12 seqlock, B11 Chase–Lev work stealing | not written | the SC versions are expressible, but the point of both is cheaper-than-SC ordering, which iris-lean cannot reason about (G4) |
| B14 RCU/epochs, B15 cross-thread refcounting | not written | both are about *freeing* memory. With HeapLang's never-reuse model they degenerate to "leak" (G6) |
| B18/B19 cross-tab | out of reach | not shared memory |

## 8. Files

* `iris/exec/src/Exec/Translate.lean` is the translator (JS and C targets).
* `iris/exec/src/Exec/Programs.lean` has the drivers, the edge-case tests and the small concurrent instances.
* `iris/exec/src/Exec/Hints.lean` has the futex no-op proofs, `FutexMutex`, `HintedSpinLock` and `HintedSpawn`. `iris/exec/src/Exec/Intrinsics.lean` defines the two hint values.
* `iris/exec/src/Exec/FutexMutexProof.lean` is the iris-lean proof of the futex mutex, and `iris/exec/src/Exec/EncodingProof.lean` the proof that word equality matches HeapLang's CAS.
* `iris/exec/src/Exec/Interp.lean` is the reference interpreter. `iris/exec/src/Gen.lean` translates everything and writes the manifest.
* `iris/exec/rt/runtime.mjs`, `worker.mjs` and `run.mjs` are the JS runtime and Node launcher, and `iris/exec/rt/browser/` the browser launcher. `iris/exec/rt/hl_rt.h` and `hl_main.h` are the C runtime and pool.
* `iris/exec/bench/baselines.mjs` holds the hand-written JS. `side-by-side.mjs` is the harness, `run-tests.mjs` the differential tests, and `build-{native,wasm}.sh` build the C backends.
* `iris/exec/out/` holds the generated `*.mjs`, `c/*.c`, `native/*`, `wasm/*` and `manifest.json` (per-program translation stats).
* `iris/exec/bench/results.md` and `results.json` hold the measurements. `tests-{js,native,wasm}.log` are the test logs, `browser.log` the browser run, and `side-by-side.run1-partial.log` an earlier, noisier partial run.
* `iris/exec/iris-lean/` is a copy of upstream iris-lean at `100ed29`, built with Lean 4.36.0. The only change is an `Exec` `lean_lib` added to `lakefile.toml`.
