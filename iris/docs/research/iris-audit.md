# iris-lean as a tool for "lock-free because proven": audit

> Kept from the research that preceded `iris/`. Paths starting `<scratchpad>/iris/` or `iris/`
> name the research scratchpad, which no longer exists: the evidence they cite is in this
> directory (`README.md` maps it), and the code is now in `iris/` itself (`../../README.md`).

Scope: upstream iris-lean (github.com/leanprover-community/iris-lean, commit `100ed29e`,
2026-11-20, Lean `v4.36.0`), built and exercised in a fresh 4-vCPU CI VM. Seven new
proofs of lock-free / lock-less structures were written and machine-checked. They are in
`<scratchpad>/iris/iris-audit/proofs/`.
All timings come from the CI machine and need re-measuring on the reference Mac. Treat them as ratios.

Short version:

* **What iris-lean can do today.** It proves real lock-free algorithms correct in about 100–330
  lines each. Each proof checks in 1.5–5 s. This audit proved: logically atomic FAA/CAS
  counters, a fork-join parallel map with no synchronisation, Treiber's stack (both an ownership
  spec and a linearizable spec), and a bounded SPSC ring buffer with FIFO delivery. There are
  also two closed, end-to-end theorems ("every interleaving is safe and returns X").
* **What it does not do.** It does not generate code, and it does not touch the code you run.
  The proofs are about *HeapLang*, an untyped, sequentially consistent ML-like language with
  unbounded integers and a garbage-collected heap. The proofs are not about Lean-compiled code,
  not about JS, and not about wasm. Using them takes a hand-written or tool-written translation,
  and that translation is trusted, not verified. The translation must also respect assumptions
  that JS/wasm break: weak memory for non-atomics, 32/64-bit wrap-around, and manual memory reuse
  (the ABA problem).
* **The value for LeanUI side-by-side tests.** It gives a precise *specification and safety
  argument* for the lock-free variant: which accesses must be atomic, which can be plain, and what
  ownership each thread holds. It does not give a faster or "lock-free by construction" artefact.

---

## 1. Build

| Step | Command | Result (CI VM) |
|---|---|---|
| toolchain | `~/.elan/toolchains/leanprover--lean4---v4.36.0` (already installed) | Lean 4.36.0 |
| deps | `Iris/lakefile.toml`: only `batteries` and `Qq` at `v4.36.0`, **no Mathlib** | light |
| library | `lake build Iris` | **3 min 14 s wall** (8 m 38 s user), 612 jobs, 0 errors (`iris-audit/build-iris.log`) |
| tests | `lake build IrisTest` | +19 s, 33 test modules, all pass (`iris-audit/build-iristest.log`) |
| downstream lib | first `lake build IrisAudit` | +1 min 24 s (`precompileLibrary = true` makes lake compile Iris to native code once) |

Slowest library files: `HeapLang.ProphErasure` 18 s, `HeapLang.Syntax` 17 s,
`HeapLang.Lib.Quicksort` 13 s, `Algebra.CMRA` 11 s, `HeapLang.ProofMode` 8.8 s.

Porting coverage, from the repo's own `scripts/check_porting.py` run against Iris-Rocq `8e490959`
(`iris-audit/porting.csv`): **6195 ported, 1607 deliberately ignored, 171 missing out of 7973
Rocq definitions**. All of `iris/program_logic/*` is ported, `atomic.v` included. The missing items are
concentrated in heap_lang (§6).

Work copy: `iris-audit/iris-lean/Iris/` (a copy of the upstream clone). I added one `[[lean_lib]] IrisAudit`
to its `lakefile.toml` and a symlink `IrisAudit -> ../../proofs`. Rebuild with
`cd …/iris-audit/iris-lean/Iris && lake build IrisAudit`.

## 2. HeapLang: what the proofs are about

`Iris/HeapLang/Syntax.lean`, `Semantics.lean` (468 lines, `BaseStep`):

* Values: `int` (**unbounded `Int`**), `bool`, `unit`, `loc` (`Loc.n : Int`, so pointer arithmetic
  works), `prophecy`, closures (`rec f x := e`), pairs, sums. No types: ill-typed programs get *stuck*.
* Heap: `allocN n v` (fresh block), `free` (**HeapLang does have `free`**: `freeS` sets the cell to
  `none`, and later accesses are stuck), `load`, `store`.
* Atomics, each one indivisible `BaseStep`:
  `cmpXchg l v1 v2` returns `(old, success)` and needs `compareSafe` (at least one side must be an
  "unboxed" literal or `injL/injR` of a literal, otherwise the step is **stuck**), plus
  `xchg`, `faa` (ints only). `cas(l,a,b)` is notation for `snd(cmpXchg …)`. There is no atomic
  and/or/xor/sub (use a CAS loop), and **no wait/notify (futex)**: blocking is spinning.
* `fork e` spawns a thread. The thread pool semantics (`ProgramLogic/ThreadPool.lean`) is an
  arbitrary interleaving of `BaseStep`s, which makes it **sequentially consistent**. Every heap
  access, including a plain `!l`/`l ← v`, is a single SC step. There is no notion of a data race
  and no non-atomic access mode.
* Prophecy: `newProph`, `resolve` (with `ProphErasure.lean` proving they can be erased). Used only
  by `LazyCoin`/`ClairvoyantCoin` examples; this is the tool for future-dependent linearisation
  points.

## 3. What a proof guarantees: adequacy

`ProgramLogic/Adequacy.lean`, `HeapLang/PrimitiveLaws.lean:144`:

```lean
theorem heap_adequacy [HeapLangGpreS .hasLC GF] (e : Exp) σ (φ : Val → Prop)
    (Hwp : ∀ [HeapLangGS .hasLC GF], ⊢ invHeapInv -∗ WP e {{ v, ⌜φ v⌝ }}) :
    adequate .NotStuck e σ (fun v _ => φ v)
structure adequate s e1 σ1 φ : Prop where
  adequate_result   : ∀ t2 σ2 v2, ([e1], σ1) -·->ₜₚ* (ofVal v2 :: t2, σ2) → φ v2 σ2
  adequate_not_stuck : ∀ t2 σ2 e2, s = .NotStuck → ([e1], σ1) -·->ₜₚ* (t2, σ2) → e2 ∈ t2 → NotStuck (e2, σ2)
```

So a closed theorem says, over **every reachable configuration of every interleaving**:

1. **Safety.** No thread, forked threads included, is ever stuck. That rules out use-after-free and
   access to unallocated memory, type confusion, `faa` on a non-int, CAS on boxed values, and a failing
   `assert`.
2. **Partial correctness of the main thread.** *If* the main thread reaches a value, it satisfies
   `φ`. Forked threads' results are visible only through what the proof put in invariants.

It does **not** say:
- termination, deadlock-freedom, lock-freedom, or fairness. `adequate` holds for a program that
  spins forever. Generic total weakest preconditions exist (`ProgramLogic/TotalAdequacy.lean`,
  `twp_*` lemmas), but HeapLang's `heap_total` adequacy and the `twp` tactics are *missing* (§6).
- anything about data races. There are none to speak of in SC HeapLang.
- anything about any other language.

`wp_invariance` (same file) also gives "a property established by an invariant holds in every
reachable state".

## 4. Logically atomic specifications

`ProgramLogic/Atomic.lean` (238 lines), `BI/Lib/Atomic.lean` (561 lines): `atomic_update`
(greatest fixpoint of `atomic_acc`), the TaDA/Iris triple
`<<{ ∀∀ x, α x }>> e @ E <<{ ∃∃ y, β x y | z, RET v ; POST }>>` (`atomic_wp`), with
`atomic_wp_seq(_step)`, `atomic_wp_inv`, `atomic_seq_wp_atomic`, `atomic_wp_mask_weaken`, the
`aacc_*`/`aupd_*` lemmas, an `ElimModal` instance that lets `imod AU` open an atomic update on a WP
goal, and tactics `iauintro` and `iaaccintro`.

Before this audit, **no HeapLang library used `atomic_wp`**. `IrisTest/Atomic.lean` only tests
notation and proof-mode plumbing. Rocq's `atomic_heap.v`, `increment.v` and `logatom_lock.v` are
missing (porting report). Proofs 1, 2 and 5 below are therefore, as far as this audit could find,
the first HeapLang proofs in iris-lean that use logical atomicity. They work.

## 5. The verified libraries

Build time in the table includes about 0.6–1 s of import loading. Rocq LOC is from the matching
`iris_heap_lang/lib/*.v` (Iris-Rocq `2fe2f450`).

| Lean file | LOC (Rocq) | check | What the spec says |
|---|---|---|---|
| `Lib/Lock.lean` | 100 (89) | 0.8 s | `Lock` class: `newlock`/`acquire`/`release` with `isLock γ lk R` (persistent), `locked γ` (exclusive), `acquire: {isLock} → locked ∗ R`. Mutual exclusion is expressed as ownership of `R`. |
| `Lib/SpinLock.lean` | 213 (102) | 2.6 s | CAS spin lock, instance of `Lock`, plus `try_acquire`. Safety only: no progress or fairness. |
| `Lib/TicketLock.lean` | 303 (156) | 4.8 s | Ticket lock (CAS on `next`, spin on `owner`), same `Lock` spec. **FIFO fairness is not in the spec.** |
| `Lib/RwLock.lean` | 104 (105) | 1.2 s | Interface: readers get `Φ q` for a fraction `q`, the writer gets `Φ 1`. |
| `Lib/RwSpinLock.lean` | 429 (380) | 4.2 s | Instance (reader count in an `Int`, CAS). |
| `Lib/Counter.lean` | 298 (167) | 3.6 s | CAS-loop `incr`, `read`. Two **non-atomic** specs: monotone counter (`Auth MaxNat` lower bounds) and counter with fractional contributions (`FracAuth`). |
| `Lib/Spawn.lean` | 151 (76) | 2.0 s | `spawn f` returns a join handle, `join h` returns `Ψ v`. A one-shot channel with a spin-wait join. |
| `Lib/Par.lean` | 77 (45) | 2.0 s | `e1 ‖ e2`: from `WP e1 {{Ψ1}}` and `WP e2 {{Ψ2}}`, get `Ψ1 v1 ∗ Ψ2 v2`. |
| `Lib/Array.lean` | 259 (273) | 3.9 s | `free`, `copyTo`, `clone`, `init` over `l ↦∗ vs` (sequential). |
| `Lib/Quicksort.lean` | 315 (no Rocq file) | 13 s | **Sequential** linked-list quicksort, sorted and a permutation, plus an end-to-end `adequate` theorem (`sortAndCheckAdequate`). Not parallel. |
| others | | | `Assert`, `Arith`, `Diverge`, `NondetBool` (fork), `LazyCoin`/`ClairvoyantCoin` (prophecy), `Unwrap`, `LandinsKnot`. |

Lean proofs run 1–2× longer than Rocq in lines (`Spawn` 151 vs 76, `TicketLock` 303 vs 156). That
comes mostly from explicit `iframe`/`isimp`/`subst` steps and more spelled-out invariant closing.

**HeapLang proof-mode tactics** (`HeapLang/ProofMode.lean`, `Tactic.lean`): `wp_bind`,
`wp_pure(s)`, `wp_rec`/`wp_lam`/`wp_let`/`wp_seq`/`wp_if`/`wp_match`/`wp_proj`/`wp_case`/`wp_op`/…,
`wp_apply`/`wp_smart_apply … with pat`, `wp_load`, `wp_store`, `wp_xchg`, `wp_faa`,
`wp_cmpxchg_suc`/`_fail`/`wp_cmpxchg with h1 h2`, `wp_alloc` (also `allocN`), `wp_free`,
`wp_value_head`, `wp_expr_simp`, `wp_finish`. General MoSeL tactics: `iintro icases ihave imod
iinv iloeb iinduction iframe isplitl/r iexists ileft/right icombine … gives … ipureintro isimp
ieval iunfold irewrite iauintro iaaccintro` (`docs/tactics.md`). **Missing compared with Rocq:**
`awp_apply`, twp tactics (all 16 `tac_twp_*`), `wp_new_proph`/`wp_resolve` tactics (only lemmas),
`wp_pure` with later credits, and `Atomic` instances for pure expressions (`rec_atomic`,
`binop_atomic`, …). The last ones matter: `atomic_seq_wp_atomic` can't be used on compound expressions.

## 6. New proofs written for this audit (all `sorry`-free; `#print axioms` shows only `propext, Classical.choice, Quot.sound`)

| File | LOC | check | What is proved | JS analogue |
|---|---|---|---|---|
| `AtomicCounter.lean` | 105 | 1.7 s | `faaIncr` and `casIncr` with **logically atomic** specs `<<{∀∀ n, l ↦ #n}>> incr #l @ ∅ <<{l ↦ #(n+1) \| RET #n}>>`, plus a derived sequential spec. | `Atomics.add`, a `compareExchange` loop |
| `TwoThreads.lean` | 166 | 2.4 s | **Closed theorem** `twoIncr_adequate : ∀ σ, adequate NotStuck (let l := ref 0; (faaIncr l ‖ faaIncr l); !l) σ (· = #2)`. The threads use only the atomic spec, opening a shared invariant `l ↦ n ∗ ●F n` at the linearisation point. Includes a custom ghost-state signature `AuditS`. | 2 workers × `Atomics.add` on a SAB |
| `ParMap.lean` | 126 | 2.2 s | Divide-and-conquer fork-join `pmap f a n`: `a ↦∗ zs` becomes `a ↦∗ map g zs`. **No invariant, no ghost state, no atomics**: the array is split into disjoint owned halves at each `par`. | Workers each own a slice of one SAB, using plain typed-array access |
| `Treiber.lean` | 219 | 2.4 s | Treiber stack push/pop (CAS on head), "bag" spec: each element carries an arbitrary resource `P x`, so it **transfers ownership** between threads. Uses persistent points-to for immutable nodes. | lock-free job pool / free list |
| `TreiberAtomic.lean` | 219 | 2.3 s | Same code, **linearizable** spec against an abstract list (`ghost_var` halves): `<<{∀∀ xs, content xs}>> push s x <<{content (x::xs) \| RET ()}>>` and `pop … <<{content xs.tail \| RET popRet xs}>>`. The linearisation point of an empty pop is the load. | |
| `SpscRing.lean` | 327 | 5.3 s | Bounded **single-producer/single-consumer ring buffer** (two counters, slot `i % n`, plain slot loads/stores, no CAS). `tryPush`/`tryPop` with an index-dependent resource `P i v`: the i-th push gives `P i v`, the i-th pop receives it. Also `rb_init` from fresh memory. | AudioWorklet / `ringbuf.js`-style SAB queue |
| `SpscClient.lean` | 184 | 1.5 s | **Closed theorem** `spscClient_adequate`: a producer thread pushes 10 and 20 (retrying), a consumer pops twice (retrying), and every interleaving is safe and returns exactly `(10, 20)`. That is FIFO, nothing lost, nothing duplicated. | |

Effort. Agent wall-clock per proof, read from file timestamps, iterations with the checker included and
approximate: AtomicCounter about 3 min after the build finished (drafted during the build), TwoThreads 4 min,
ParMap 3 min, Treiber 3 min, TreiberAtomic 2 min, SpscRing 7 min, SpscClient about 2 min. The
whole session took about 35 min: build, reading, 7 proofs, the JS check. Each proof needed 3–10 check
iterations. Don't read this as human effort. Someone fluent in Rocq Iris but new to iris-lean should plan for
**hours to a day per structure**. The check loop is fast (1.5–5 s per file), which helps a lot.

### What was hard (iris-lean friction, concrete)

1. **Telescope noise in atomic specs.** After every `imod AU` you get
   `Std.Tele.app (fun n => {down := …}) ⟨n, ()⟩`. The fix is `isimp only [Std.Tele.app, Std.Tele.lam,
   Std.Tele.bind, Std.Tele.app_bind]`, `ispecialize HΦ $$ %⟨⟩`, `isimp only [BIBase.wandM]`. Rocq hides
   all of this. There is no `awp_apply`, so specs are applied by `iunfold atomic_wp` and done by hand.
2. **`iinv` inside an atomic accessor breaks.** With a closing pattern, or `>` (timeless)
   patterns, on an `atomic_acc` goal, it fails with an internal typeclass error ("parameter #9 … is
   an out parameter that is not an mvar"). Workaround (`TwoThreads.lean:incr_thread`): `iunfold atomic_acc`,
   open the invariant on the plain fancy update, and build the accessor by hand with `fupd_mask_intro`.
   This is a real proof-mode gap: the Rocq instances exist.
3. **The accessor is a `∧`.** `⟨Hα, Habort, Hcommit⟩` can't destruct both conjuncts. Keep it whole
   and pick a side per branch.
4. **`iloeb` changes term shapes.** The terms stay definitionally equal but are no longer syntactically
   equal, so `iexact AU` fails. Workaround: run `iloeb` *before* `iintro AU`.
5. Small papercuts:
   - `ieval (rw …)` errors whenever `rw` closes its goal.
   - Full `simp` also rewrites the Iris context (use `isimp`).
   - `unfold f` unfolds hypotheses too (write equation lemmas).
   - `wp_cmpxchg with` emits the `compareSafe` side goal *first*.
   - HeapLang `=` evaluates to `BEq` and `if` on `decide`, both needing manual `rw`.
   - `wp_apply` can't use a raw `WP` hypothesis (go through `wp_wand`).
   - The notation `γ ↪VAR{q} a ∗ P` parses as `γ ↪VAR{q} (a ∗ P)` (needs parentheses).
   - `#(n + 1)` needs a type ascription.
   - `Loc + Nat` and `Loc + Int` need cast lemmas.
6. **Ghost-state signatures by hand.** There is no `subG`-style composition: to get adequacy with
   spawn tokens and a ghost var, you copy the 9 entries of `HeapLangS` and add yours (`AuditS`, `RingS`),
   then write `ElemG` instances as `⟨9, rfl⟩`. Fine but brittle.

### What could not be proved, or was not attempted

- **Any liveness:** Treiber lock-freedom, SPSC wait-freedom, ticket-lock fairness, termination of
  the closed programs. There is no HeapLang total adequacy and no twp tactics, and liveness logics
  (Transfinite Iris, Trillium, Fairis) don't exist in Lean.
- **The racy counter** (`l ← !l + 1` from two threads). It is unprovable by design: the invariant can't
  be re-established after a stale read. Iris has no "this is wrong" theorem. Disproving it needs an
  explicit operational trace, which I did not build. It loses updates empirically (§8).
- **Weak memory.** The SPSC ring with *plain* index stores, or with release/acquire instead of SC,
  can't even be *stated*: HeapLang is SC and iris-lean has no RC11/JS memory-model logic.
- **Memory reclamation / ABA.** The Treiber proofs depend on nodes never being freed: persistent
  `↦□` can't be freed. A SAB translation that recycles node indices has ABA and is outside the
  proof. Hazard pointers and epochs have Rocq proofs, none in Lean.
- Not attempted: Michael–Scott queue, elimination stack, Chase–Lev work-stealing deque, RDCSS (needs
  prophecies), MPMC queues, seqlocks (racy reads are SC-only here anyway).
- Connecting logically atomic specs to a formal *linearizability* theorem over histories. This is
  not in Lean, and only partially done in the Rocq literature.

## 7. Rocq Iris (and ecosystem) vs iris-lean

Inside Iris-Rocq (per the porting report): missing `atomic_heap.v` (18 defs, a logically atomic heap
abstraction), `increment.v` (9, the logatom increment that `AtomicCounter.lean` re-does), `logatom_lock.v`
(13, TaDA lock), heap_lang `total_adequacy.v`, all twp proof-mode tactics, later-credit
`wp_*_lc`/`steps_lb` laws (37 in `primitive_laws.v`), `inv_pointsto` (invariant locations), pure-
expression `Atomic` instances, and `iris_unstable/heap_lang/interpreter.v` (a verified HeapLang
interpreter: none in Lean).

Ecosystem built on Rocq Iris that has no Lean counterpart (as far as this audit found):
- **Weak memory:** iRC11, GPFSL, Compass (C11), Cosmo (OCaml 5).
- **Refinement and contextual equivalence:** ReLoC, Simuliris. These are what you would want for
  "lock-free version ≡ locked version".
- **Message passing:** Actris (session types for channels: the natural model of
  `postMessage`/`MessageChannel`).
- **Liveness:** Transfinite Iris, Trillium, Fairis, Lawyer.
- **Automation:** Diaframe.
- **Real languages:** RefinedC (C with atomics), RustBelt/RefinedRust, Perennial/Goose (Go), Aneris
  (distributed).
- **Example libraries:** iris-examples (MS-queue, elimination stack, RDCSS, barrier, HOCAP, logatom
  case studies).

## 8. Hand-translation check (JS, Node 22 `worker_threads`, SAB + Atomics)

`iris-audit/js/translate-check.mjs` transcribes the verified algorithms literally, plus broken
variants. Run it with `node translate-check.mjs`. Output from 3 runs is in `iris-audit/js/run2.txt`. The run uses a start
barrier so the threads really overlap.

| Scenario (4 threads × 2M incr, or 5M SPSC msgs, cap 1024) | Correct? | Time vs `Atomics.add` |
|---|---|---|
| FAA (`faaIncr`) | yes | 1.0 |
| CAS loop (`casIncr`) | yes | 1.45–1.81 |
| spin lock + plain increment (`SpinLock`) | yes | 3.3–3.8 |
| racy `i32[0] = i32[0] + 1` (unverifiable) | **no: 4.7–5.5 M of 8 M** | 0.07–0.11 |
| SPSC, `Atomics.load/store` on indices, plain slots (= proof) | yes, 0 out-of-order | 1.6–1.9 |
| SPSC, plain index accesses (outside the proof) | passed here (x86-TSO) | 0.4–0.5 |

Read the last row carefully. It runs about 4× faster than the proven translation and passed on this x86 VM. It is still a data
race under the JS memory model, with no happens-before from slot write to slot read. It may fail
on **ARM64, which includes the reference Mac**, or after a JIT change. The SC proof can't tell the two apart.
Re-run on the Mac. Also, in an earlier run without the start barrier the racy counter came out
"correct" (8 M), because the workers didn't overlap (`js/run1.txt`). Tests can't stand in for proofs here
either.

## 9. Mapping JS multithreading mechanisms to iris-lean today

| JS mechanism | HeapLang model | iris-lean status |
|---|---|---|
| `Worker` + `postMessage` (structured clone, copy) | no sharing; channels | Nothing to prove about memory. Protocol proofs need Actris (Rocq only). |
| `postMessage` with transfer (`ArrayBuffer` detaches) | ownership transfer | Exactly separation logic: `Spawn` handle, Treiber `P x`, SPSC `P i v` (done). |
| `SharedArrayBuffer` + `Atomics.add/sub/and/or/xor/exchange/compareExchange` | `faa`, `xchg`, `cmpXchg` (and/or/xor via CAS loop) | Good: `AtomicCounter`, `Counter`, Treiber, lock libs. SC atomics match JS `Atomics` (SC). |
| plain typed-array reads/writes on a SAB | plain `!`/`←` (but SC!) | Sound **only** when the proof shows exclusive ownership *and* the ownership hand-off goes through an `Atomics` op (`ParMap`: through `join`; SPSC: through index stores). The JS-memory-model step is an informal argument. |
| `Atomics.wait/notify`, `waitAsync` | none (spin) | Safety proofs of the spin version carry over if `wait` is treated as "may return at any time" (informal). No liveness. |
| Mutex/semaphore built on Atomics, `navigator.locks` | `Lock`/`RwLock` libs | Safety (mutual exclusion as ownership of `R`), no fairness or deadlock-freedom. |
| async/await, promises (one thread, interleaving at `await`) | `fork` over-approximates | Sound but coarse: preemptive interleavings include cooperative ones. |
| AudioWorklet ↔ main thread ring buffer | `SpscRing` | Done, FIFO, end-to-end client theorem. Counter wrap-around not covered (HeapLang `Int` is unbounded). |
| Worker pool / fork-join over slices | `par`, `ParMap` | Done, no sync needed beyond join. |
| wasm threads (shared memory, `memory.atomic.*`) | same as SAB | Same caveats. wasm atomics are SC-only too, so release/acquire buys nothing in wasm today. |

## 10. Honest shortcomings of "iris-lean → lock-free code" for LeanUI

1. **No code generation, no link to compiled code.** HeapLang programs are `Exp` ASTs inside
   Lean. The Lean compiler never sees them as code. LeanUI's Lean→C→wasm pipeline compiles
   ordinary Lean functions, and it is single-threaded on purpose (`docs/TOOLCHAIN.md`). Even QED64's
   pthread build gives Lean `Task`/`IO.Ref`, whose semantics are unrelated to HeapLang. To run a
   verified algorithm you need (a) a HeapLang→JS (SAB+Atomics) or HeapLang→C11 translator, or (b) a hand
   transcription like `translate-check.mjs`. Either one is **trusted**. Writing (a) is a modest project; proving
   it correct is a research project (a JS or wasm memory-model semantics in Lean plus a simulation proof).
2. **Semantic gaps the translator must close by hand:**
   - unbounded `Int` against Int32/Int53/i64 wrap. The SPSC counters overflow after 2³¹ pushes (about 12 h at
     48 kHz per sample). Use modular counters and re-prove, or 64-bit counters.
   - garbage collection against manual reuse (ABA in Treiber).
   - closures and boxed values against flat SAB layouts.
   - SC everything against "plain accesses are racy".
3. **No performance claims.** In the cases verified here, the proof doesn't make code faster. The
   fast variant (plain indices) is precisely the one the proof doesn't cover. What the proof buys is
   *confidence that the lock-free variant is correct*, plus a spec telling the test-writer which
   accesses must be atomic.
4. **Spec strength must be chosen.** "Bag" specs (Treiber `P x`) don't imply LIFO. Linearizable
   specs need ghost state and logically atomic triples, which are about 1.5× the work here.
5. **Partial correctness only.** A deadlocking or livelocking program satisfies every spec here.
6. **Tooling maturity.** The friction list in §6 is real, though everything was workable within the session.
   iris-lean moves fast (the upstream commit is from the audit day). Pin a commit.

## 11. How the side-by-side tests can use this

For each scenario, JS baseline (lock or racy) vs proof-backed transcription:

1. Shared counter: FAA / CAS / lock / racy. Proofs: `AtomicCounter`, `TwoThreads`.
2. Parallel map over SAB slices with no sync except join. Proof: `ParMap`.
3. Lock-free stack as a job pool, with an index pool *without reuse*. Proofs: `Treiber`,
   `TreiberAtomic`. Show ABA when indices are reused.
4. SPSC ring (Worker→main or AudioWorklet). Proofs: `SpscRing`, `SpscClient`. Run the plain-index
   variant on ARM.
5. Spawn/join result hand-off. Proof: `Lib/Spawn`.
6. Spin vs ticket vs RW locks. Proofs: upstream libs (safety only).

Each test should state the guarantee (the theorem name) and what is trusted (the transcription,
32-bit arithmetic, the memory model).

## Evidence index

- `<scratchpad>/iris/iris-audit/proofs/*.lean`: the 7 proofs
- `<scratchpad>/iris/iris-audit/build-iris.log`, `build-iristest.log`: builds with per-file times
- `<scratchpad>/iris/iris-audit/porting.csv`, `porting.log`: Rocq→Lean porting coverage
- `<scratchpad>/iris/iris-audit/js/translate-check.mjs`, `run1.txt`, `run2.txt`: JS transcription check
- Rocq comparison clone: `<scratchpad>/ext-rocq/iris-rocq` (commit `2fe2f450`)
