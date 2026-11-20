# Adversarial review of the design

Written after `design.md`, against it and the research evidence. Its corrections are binding; the
list at the top of `design.md` sums them up. Paths name the research scratchpad, which no longer
exists: `sc-cost.mjs` and `sc-cost.out` are in `research/critic/`, the probes in
`research/catalogue/`.

Verdict: the design is honest at the top level ("Iris does not remove locks; the algorithm does", liveness and weak memory left out, S11 included). Its central gap is the **data plane**. Almost every flagship scenario (S3, S4 with audio blocks, S5, S9, S14) gets its speed from payload that sits outside HeapLang. There the proof covers an abstract resource `P`, never the JS that touches the bytes. So "proved no torn frame / zero-copy hand-off / justifies deleting the mutex" is not true of the code that runs. Several stage-1 "no new proof" claims also fail on inspection.

New evidence produced for this review: <scratchpad>/iris/critic/sc-cost.mjs and sc-cost.out. The test is a 3-tap blur over 4M Int32 cells in a SharedArrayBuffer, Node 22.23.5, run on the CI VM (re-measure on the Mac):
- W=1: plain 181–186 ms, all `Atomics` 1367 ms (7.5×), Atomics loads with plain stores 1018 ms.
- W=4: plain 91–98 ms, all `Atomics` 375–511 ms (4–5×).
- Hashes are identical across modes.

## A. Overclaims (claimed as proved, lock-free or the same constant when it is not)

1. **The data plane is outside the proof, and so are the bugs the design shows off.**
   - §1.3 and S3/S4/S5/S9 put the payload in ordinary typed arrays. Calling `tryPush` before or after writing the block is client JS.
   - So the S4 L0 bug "publish-before-write" and the S3 "torn frame" are not ruled out by `tryPush_spec` or `TripleBuffer` for the data-plane lanes. They are ruled out only when the payload is in the HeapLang heap. There every access becomes an SC atomic, which costs 4–7.5× on a pixel loop (sc-cost.out) and 3–10× in the catalogue's seqlock row (0.86/0.10 against 2.79/1.01, js-catalogue.md §1.3).
   - A5(a) says "detach happens at proof time, zero checks at run time". It is worse than `postMessage` with transfer: the browser enforces detach at run time, while nothing enforces the SAB discipline in unverified JS.
   - Fix: give every flagship scenario two verified lanes. "L3-in-heap" has the payload in HeapLang, is fully covered and slow. "L3-data-plane" is fast and its glue is trusted. The chip must say which one it is.
2. **§1.3 says plain accesses "are race-free by the SC-DRF theorem". This is backwards.** SC-DRF only says that race-free programs behave as SC. Race freedom is the trusted discipline, and nothing proves it.
3. **"The kernel can never drift from the proof: the SAME constant" (§1.1) is already false in the evidence.**
   - `exec/src/Exec/Programs.lean:49` has `faaIncr := λ l, faa(l,#1); #()`.
   - The proved one, `iris-audit/proofs/AtomicCounter.lean:22`, is `λ l, faa(l,#1)`. They are different terms.
   - Treiber in `Programs.lean:126-127` is a text copy, not an import.
   - SpscRing, ParMap, TreiberAtomic and AtomicCounter were never translated. They are not among the 37 tests (`Programs.lean` smallConc covers counter_*, rw, treiber, par_sum, pfib, qsort, fork_many).
   - §0.4's "translated programs pass 37/37" reads as if it covered them. Rephrase it, and make stage 0 import the proof modules' constants.
4. **S1 attributes the shard proof to the wrong spec.** "Sharded `ccounter` (`incr_contrib_spec`)" and "the proof of the shards is the contribution spec" are wrong.
   - In upstream `Lib/Counter.lean` lines 214–279, `ccounter` is ghost fractions over one shared CAS cell, which is the opposite of physical shards.
   - Physical shards need only ParMap-style ownership plus a join, a trivial proof that does not exist yet.
5. **The "≈250× shards" figure is a V8 artefact and will not carry over to L3.**
   - js-catalogue.md §1.2 footnote: "about 1.4 cycles per increment, so V8 is optimising the plain loop (store sinking)". The probe is `a[SHARD+I*w]++` (catalogue/probes/counter.mjs:23).
   - Translated shards perform an SC `Atomics.store`/`load` per increment.
   - The honest JS reference is "count locally, one Atomics.add": 2,280–2,370/µs.
   - The L3 number is unmeasured. Do not quote 250× until L3 is measured. The same applies to "batched ring 16×" and "triple buffer fastest": those were measured with plain payload.
6. **Range invariants do not "close G3 per kernel" (§6.4, §7.3).**
   - `⌜|n|<2^28⌝` can be an invariant only for bounded-state words: FutexMutex {0,1,2}, the triple buffer's `mid` ∈ [0,8).
   - Monotone counters, ring indices, the barrier `gen`, the seqlock `seq` and the claimer `next` grow without bound. A bound needs a client precondition on the total number of operations.
   - Only modular re-proofs fix rings. Counters, `gen` and `seq` stay fail-stop.
7. **The "No lock" column mislabels blocking primitives.**
   - S7 (barrier), S9 (once: waiters spin or futex while state=1), S10 (semaphore), S11 (event count) and S13 (a reader must wait on a slot "being published") are blocking by construction. A stalled initialiser or holder blocks everyone, which is S9's own kill test.
   - Label them "blocking primitive built without a mutex word" and reserve "lock-free/wait-free" for S3, S4's try ops, S5 and Treiber.
8. **"TreiberAtomic: linearizable" (§0.4, §6.5) overstates it.** It is a logically atomic spec. iris-audit.md §6 says the link to history linearizability "is not in Lean".
9. **The wait-freedom certificate (§6.3) is an unverified meta-argument.**
   - "No `rec`" must allow anonymous `rec`, because `λ` and `let` are `rec <>`.
   - It bounds the operation's *own HeapLang steps*, not time: GC, JIT deopt and cache-line contention all remain. The chip on the AudioWorklet must not read as "real-time safe".
   - The translator's overflow or OOM trap inside `process()` kills the processor (`onprocessorerror`, silence).
10. **"Fuzzing cannot change a verified lane's results" (§5.4) is circular.** The translator, runtime, drivers (G11) and data plane are unverified, which is exactly what fuzzing tests. Present 0 violations as evidence about the trusted base, not as a property of the proof.
11. **"Fail-stop" on trap holds per thread, not per system.** `exec/rt/worker.mjs` sets C_TRAP/C_DONE and breaks. A trap inside a critical section leaves the other threads spinning, the same as the kill test. In-page or embedded use needs a global teardown.
12. **L4 is labelled "our Lean → wasm code" (§1.2). It is not.** L4 is HeapLang → C → wasm32 with its own word heap and pool. It is not LeanUI's Lean → C → wasm64 or Lean's runtime. Real Lean code first appears in L5, at stage 3, behind an undecided threaded mode. Say so plainly, because this is what the user asked for.

## B. Unfair or misleading comparisons

- **L1 is a strawman for counters.** Idiomatic JS for S1 is `Atomics.add`, which is L2. Make L2 vs L3 (same algorithm) the default headline; L1 is context only. The design admits this in §7.5, but §1.2 still calls L1 vs L3 "the pair the user asked for".
- **S3 leaves out the idiomatic JS answer:** render in the Worker with OffscreenCanvas (`transferControlToOffscreen`, Worker rAF) or `transferToImageBitmap` per frame. Neither shares a frame. The catalogue already lists it (js-catalogue.md B13(c), line 786), but S3's L1 lanes do not.
- **Spinning SAB lanes against event-driven message lanes, with no CPU-time metric.**
  - Throughput hides burned cores and battery, which matters on the Mac.
  - Add CPU time per operation (Node `process.cpuUsage`, `eventLoopUtilization`).
  - Add an `Atomics.waitAsync` consumer lane, because the main thread cannot `wait`.
- **L2 vs L3 mostly measures the translator.** It reflects the uniform encoding, `callv` and SC atomics on thread-local refs (the triple buffer's `wref`/`rref` are heap cells). Report it as translator overhead, not as a "proof tax".
- **The L0 racy lanes' speed is meaningless** (V8 collapses the loop). Show their correctness counts only.
- **The W=2×cores and oversubscription rows** come from a VM with load average 19–21 (exec.md §5). Mark them noise-dominated until they are run on a quiet machine.

## C. JS techniques the design leaves out

- OffscreenCanvas and Worker-side rAF; ImageBitmap and VideoFrame transfer (WebCodecs decoders in Workers, relevant to S10).
- `Atomics.waitAsync` as a real lane for main-thread consumers (S4, S16).
- `scheduler.postTask`/`scheduler.yield` time-slicing, the main-thread "concurrency" UI frameworks use (A15).
- Emscripten PROXY_TO_PTHREAD and wasm-bindgen-rayon as the idiomatic wasm parallel route. For Lean, its analogue is `Task`.
- Partytown/synckit-style synchronous RPC (`Atomics.wait` plus `receiveMessageOnPort`) is mentioned only in passing.

## D. Infeasible or under-estimated stages

- **Stage 1 "no new proof" fails for S5.** `pmap_spec` (ParMap.lean:51) is pointwise, `Int → Int` per element. A blur is a stencil and needs the new fractional-input spec. Use a pointwise kernel (Mandelbrot per pixel, colour map) in stage 1 or mark the blur N.
- **No embedding ABI exists.** Generated modules export only `MAIN` and `link(R)` (out/treiber_t4.mjs). Allocation needs a pool-thread TLAB (runtime.mjs:33–41). Calling `tryPop` from a worklet, `fetch` from rAF, or a claimer from data-plane workers needs named entry points, argument encoding, foreign-thread TLAB registration and trap handling. That is stage-1 work the plan does not list.
- **The heap runs out in seconds.** With 256 MB by default (run.mjs:11), 64M cells and 4 cells per Treiber node, S6 traps "out of memory" after about 16M pushes. That is about 3 s at the measured 5–6 pushes/µs. The 29-bit loc words cap the heap at 1 GiB, about 12 s. So S20's "10 s fuzzed stress" over all kernels and the "verified job pool" framing do not survive. Any kernel that allocates per operation leaks in a long-running UI.
- **The refutation theorems (§5.3) carry a risk.** `State.heap` is `Std.ExtTreeMap` (Semantics.lean:90), a quotient. Replaying traces by `decide` may need `native_decide`, and the design's own axiom guard rejects that. "1–3 days" is optimistic.
- **Schedule.** Stage 1 needs 4 scenarios × 5 lanes, the ABI, fuzz mode, kill and wrap faults, an isolated page, chips, and porting 7 proofs plus exec into one Lake project. That is more like 2–3 weeks than 1–1.5. Stage 2 has 7 proofs plus Explore, the certificate, the tournament, the worklet, Web Locks and CI. Given the audit's "hours to a day per structure" for simple ones, plus the `iinv`/`atomic_acc` friction (iris-audit.md §6), plan 4–6 weeks.
- **CI cost.** The `.lake` is 580–818 MB (`du`) plus a fourth toolchain in the shared cache budget.

## E. Simpler alternatives that should be in the design

- **For the [W] cases, use bounded model checking on the real memory model** instead of "run it on the Mac and hope":
  - GenMC (RC11/IMM, which covers ARMv8) on the C kernels with explicit orders;
  - or the Watt et al. Alloy JS model on litmus-size versions of the plain-index ring and plain-data seqlock.

  These are exactly the 4× and 10× fast variants Iris cannot state.
- **Move L5(a) to stage 1–2:** one single-threaded LeanUI wasm64 instance per Worker, plus the verified JS claimer or ring. It needs no threaded runtime and is the cheapest way to put real Lean code in the comparison.
- **Cut the 20 scenarios to about 6** that each show something different: S1, S2, S3, S4 (with the ARM plain-index test), S5 and S11, plus the S20 table. S8, S12–S19 are research padding at this stage.
- **For a quick demo, hand-transcribe** proved kernels as in iris-audit/js/translate-check.mjs. The translator's no-drift benefit is limited while the glue and data plane are unverified anyway.

## Files referenced

- <scratchpad>/iris/critic/sc-cost.mjs and sc-cost.out (new measurement)
- <scratchpad>/iris/exec/src/Exec/Programs.lean (line 49, lines 126–127, smallConc)
- <scratchpad>/iris/iris-audit/proofs/AtomicCounter.lean (line 22), ParMap.lean (line 51), SpscRing.lean (lines 31–49)
- <scratchpad>/ext/iris-lean-upstream/Iris/Iris/HeapLang/Lib/Counter.lean (lines 214–279), Semantics.lean (line 90)
- <scratchpad>/iris/exec/rt/runtime.mjs (lines 33–41), run.mjs (line 11), worker.mjs, out/treiber_t4.mjs
- <scratchpad>/iris/js-catalogue.md (§1.2 footnote, §1.3, B13(c)); catalogue/probes/counter.mjs (line 23), snapshot.mjs
- /home/user/leanui/qed64/lane/core.js (lines 24–53: the payload is a plain `ring.set`, i.e. data plane too)
