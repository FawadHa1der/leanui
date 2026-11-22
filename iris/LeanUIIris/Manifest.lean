/-
What is proved about each kernel, which programs the generator translates, and which kernels it
exports as libraries for the harness (`libs`). `Gen.lean` turns
this into `manifest.json`: for every program, the kernels found in it (by comparing its values with
the proved constants), their theorems, and the closed theorem when the whole program has one.

Theorem names are written ``` ``name ```, so the build fails if one does not exist; `vals%` pairs
each constant's name with its value, so the two cannot disagree. Every theorem named here is also
in `Axioms.lean`, which checks its axioms (`test/node.mjs` checks that the two lists agree).
-/
import Lean.Elab.Term
import LeanUIIris.Programs
import LeanUIIris.Kernels.TwoThreads
import LeanUIIris.Kernels.TreiberAtomic
import LeanUIIris.Kernels.SpscClient

namespace LeanUIIris.Manifest
open Lean Elab Term Iris.HeapLang

/-- `vals% [a, b]` is `[(``a, a), (``b, b)]`, for constants of type `Val`. -/
elab "vals%" "[" cs:ident,* "]" : term <= expected => do
  let items ← cs.getElems.mapM fun c => do
    let n ← realizeGlobalConstNoOverloadWithInfo c
    `(((($(quote n) : Lean.Name)), ($(mkCIdent n) : Iris.HeapLang.Val)))
  elabTerm (← `([$items,*])) expected

structure Kernel where
  name : String
  /-- Where the code and the proof are. -/
  source : String
  consts : List (Name × Val)
  theorems : List Name
  /-- What the theorems say, in one line. -/
  says : String

def irisLib (f : String) : String := s!"iris-lean Iris/HeapLang/Lib/{f}.lean"
def ours (f : String) : String := s!"iris/LeanUIIris/Kernels/{f}.lean"

open Iris.HeapLang in
def kernels : List Kernel := [
  { name := "SpinLock", source := irisLib "SpinLock"
    consts := vals% [SpinLock.newlock, SpinLock.tryAcquire, SpinLock.acquire, SpinLock.release]
    theorems := [``SpinLock.newlock_spec, ``SpinLock.try_acquire_spec, ``SpinLock.acquire_spec,
      ``SpinLock.release_spec]
    says := "a lock (iris-lean's Lock interface): acquire returns the lock's resource R and an \
      exclusive token, so mutual exclusion is ownership of R; no fairness, no progress" },
  { name := "TicketLock", source := irisLib "TicketLock"
    consts := vals% [TicketLock.waitLoop, TicketLock.newlock, TicketLock.acquire, TicketLock.release]
    theorems := [``TicketLock.newlock_spec, ``TicketLock.waitLoop_spec, ``TicketLock.acquire_spec,
      ``TicketLock.release_spec]
    says := "the same Lock spec as SpinLock; the FIFO order of tickets is not part of it" },
  { name := "RwSpinLock", source := irisLib "RwSpinLock"
    consts := vals% [RwSpinLock.newlock, RwSpinLock.tryAcquireReader, RwSpinLock.acquireReader,
      RwSpinLock.releaseReader, RwSpinLock.tryAcquireWriter, RwSpinLock.acquireWriter,
      RwSpinLock.releaseWriter]
    theorems := [``RwSpinLock.newlock_spec, ``RwSpinLock.tryAcquireReader_spec,
      ``RwSpinLock.acquireReader_spec, ``RwSpinLock.releaseReader_spec,
      ``RwSpinLock.tryAcquireWriter_spec, ``RwSpinLock.acquireWriter_spec,
      ``RwSpinLock.releaseWriter_spec]
    says := "a readers-writer lock: readers get a fraction of the resource, the writer all of it" },
  { name := "Counter", source := irisLib "Counter"
    consts := vals% [Counter.newcounter, Counter.incr, Counter.read]
    theorems := [``Counter.newcounter_mono_spec, ``Counter.incr_mono_spec, ``Counter.read_mono_spec,
      ``Counter.newcounter_contrib_spec, ``Counter.incr_contrib_spec, ``Counter.read_contrib_spec,
      ``Counter.read_contrib_spec_1]
    says := "a CAS-loop counter: a read is at least any lower bound its caller holds (mono), \
      and fractional contributions add up to the value (contrib); not logically atomic" },
  { name := "Spawn", source := irisLib "Spawn"
    consts := vals% [Spawn.spawn, Spawn.join]
    theorems := [``Spawn.spawn_spec, ``Spawn.join_spec]
    says := "join returns a value satisfying the spawned thread's postcondition (it spin-waits)" },
  { name := "Par", source := irisLib "Par"
    consts := vals% [Par.par]
    theorems := [``Par.par_spec]
    says := "e1 ‖ e2 returns both results, each satisfying its own postcondition" },
  { name := "Quicksort", source := irisLib "Quicksort"
    consts := vals% [Quicksort.nil, Quicksort.cons, Quicksort.append, Quicksort.partition,
      Quicksort.quicksort, Quicksort.checkSorted]
    theorems := [``Quicksort.nil_spec, ``Quicksort.cons_spec, ``Quicksort.append_spec,
      ``Quicksort.partition_spec, ``Quicksort.quicksort_spec, ``Quicksort.wp_checkSorted]
    says := "sequential: the result is sorted and a permutation of the input" },
  { name := "AtomicCounter", source := ours "AtomicCounter"
    consts := vals% [LeanUIIris.AtomicCounter.faaIncr, LeanUIIris.AtomicCounter.casIncr]
    theorems := [``LeanUIIris.AtomicCounter.faaIncr_spec, ``LeanUIIris.AtomicCounter.casIncr_spec,
      ``LeanUIIris.AtomicCounter.casIncr_seq]
    says := "logically atomic increments: <<l ↦ n>> incr l <<l ↦ n+1 | RET n>>" },
  { name := "ParMap", source := ours "ParMap"
    consts := vals% [LeanUIIris.ParMap.pmap]
    theorems := [``LeanUIIris.ParMap.pmap_spec]
    says := "maps a pure function over an owned array, each thread owning a disjoint half; \
      no invariant, no read-modify-write atomics" },
  { name := "Treiber", source := ours "Treiber, TreiberAtomic"
    consts := vals% [LeanUIIris.Treiber.newStack, LeanUIIris.Treiber.push, LeanUIIris.Treiber.pop]
    theorems := [``LeanUIIris.Treiber.newStack_spec, ``LeanUIIris.Treiber.push_spec,
      ``LeanUIIris.Treiber.pop_spec, ``LeanUIIris.TreiberAtomic.newStackA_spec,
      ``LeanUIIris.TreiberAtomic.pushA_spec, ``LeanUIIris.TreiberAtomic.popA_spec]
    says := "a pop returns a pushed element with the resource its pusher gave up; push and pop \
      are logically atomic against an abstract list; nodes are never freed" },
  { name := "SpscRing", source := ours "SpscRing"
    consts := vals% [LeanUIIris.SpscRing.tryPush, LeanUIIris.SpscRing.tryPop]
    theorems := [``LeanUIIris.SpscRing.rb_init, ``LeanUIIris.SpscRing.tryPush_spec,
      ``LeanUIIris.SpscRing.tryPop_spec]
    says := "the i-th push hands P i v to the i-th pop: FIFO, nothing lost or duplicated; \
      one producer and one consumer" },
  { name := "SpscClient loops", source := ours "SpscClient"
    consts := vals% [LeanUIIris.SpscClient.pushLoop, LeanUIIris.SpscClient.popLoop]
    theorems := [``LeanUIIris.SpscClient.pushLoop_spec, ``LeanUIIris.SpscClient.popLoop_spec]
    says := "the retry loops of the closed two-thread client (capacity 2, its two messages)" },
  { name := "Hints", source := ours "Hints"
    consts := vals% [LeanUIIris.Hints.futexWait, LeanUIIris.Hints.futexWake]
    theorems := [``LeanUIIris.Hints.futexWait_spec, ``LeanUIIris.Hints.futexWake_spec]
    says := "no-ops in HeapLang, Atomics.wait and Atomics.notify once translated" },
  { name := "FutexMutex", source := ours "FutexMutex"
    consts := vals% [LeanUIIris.FutexMutex.newlock, LeanUIIris.FutexMutex.slow,
      LeanUIIris.FutexMutex.acquire, LeanUIIris.FutexMutex.release]
    theorems := [``LeanUIIris.FutexMutex.newlock_spec, ``LeanUIIris.FutexMutex.slow_spec,
      ``LeanUIIris.FutexMutex.acquire_spec, ``LeanUIIris.FutexMutex.release_spec]
    says := "the same Lock spec as SpinLock (an instance of the interface); the lock word \
      stays in {0, 1, 2}" },
  { name := "Critical", source := ours "Critical"
    consts := vals% [LeanUIIris.Critical.criticalSpin, LeanUIIris.Critical.criticalTicket,
      LeanUIIris.Critical.criticalFutex]
    theorems := [``LeanUIIris.Critical.critical_spec, ``LeanUIIris.Critical.criticalSpin_spec,
      ``LeanUIIris.Critical.criticalTicket_spec, ``LeanUIIris.Critical.criticalFutex_spec]
    says := "one critical section proved once for every Lock instance: under the lock the two \
      cells are always equal, so the section, if it returns, returns true" },
  { name := "FutexNoWake", source := ours "FutexNoWake"
    consts := vals% [LeanUIIris.FutexNoWake.releaseNoWake, LeanUIIris.FutexNoWake.criticalNoWake]
    theorems := [``LeanUIIris.FutexNoWake.releaseNoWake_spec, ``LeanUIIris.FutexNoWake.instLock,
      ``LeanUIIris.FutexNoWake.criticalNoWake_spec, ``LeanUIIris.Critical.critical_spec]
    says := "FutexMutex with its futexWake removed (a lost-wakeup bug) satisfies the very same \
      Lock spec: the proof cannot see a liveness bug" },
  { name := "Shards", source := ours "Shards"
    consts := vals% [LeanUIIris.Shards.bump, LeanUIIris.Shards.shardCount]
    theorems := [``LeanUIIris.Shards.bump_spec, ``LeanUIIris.Shards.shardCount_spec]
    says := "n threads each count k in memory they own and add it to their own shard: every \
      shard ends k higher; ParMap-style ownership, no invariant, no read-modify-write atomics" },
  { name := "ParMapG", source := ours "ParMapG"
    consts := vals% [LeanUIIris.ParMapG.seqMap, LeanUIIris.ParMapG.pmapG]
    theorems := [``LeanUIIris.ParMapG.seqMap_spec, ``LeanUIIris.ParMapG.pmapG_spec]
    says := "ParMap with a grain size: disjoint parts mapped in parallel, each sequentially; \
      the array ends as map g; no invariant, no read-modify-write atomics" },
  { name := "Mandel", source := ours "Mandel"
    consts := vals% [LeanUIIris.Mandel.iter, LeanUIIris.Mandel.mandel]
    theorems := [``LeanUIIris.Mandel.iter_spec, ``LeanUIIris.Mandel.mandel_spec]
    says := "mandel computes the Lean function Mandel.g (the iteration count of a pixel): the \
      fSpec that pmapG_spec needs" }
]

/-! ## Libraries: kernels the harness calls from JavaScript (`rt/embed.mjs`) -/

structure Lib where
  name : String
  /-- What the harness calls, by the Lean name of the constant. -/
  exports : List (Name × Val)

open LeanUIIris in
def libs : List Lib := [
  { name := "lib_counters"
    exports := vals% [AtomicCounter.faaIncr, AtomicCounter.casIncr, Counter.newcounter,
      Counter.incr, Counter.read] },
  { name := "lib_locks"
    exports := vals% [Critical.criticalSpin, Critical.criticalTicket, Critical.criticalFutex,
      FutexNoWake.criticalNoWake, Critical.racy,
      SpinLock.newlock, SpinLock.acquire, SpinLock.release,
      TicketLock.newlock, TicketLock.acquire, TicketLock.release,
      FutexMutex.newlock, FutexMutex.acquire, FutexMutex.release] },
  { name := "lib_ring"
    exports := vals% [SpscRing.tryPush, SpscRing.tryPop, Programs.tryPushEarly] } ]

/-- The name the JavaScript side uses: the constant's name without the namespace prefix. -/
def exportName (n : Name) : String :=
  let s := n.toString
  let strip (p : String) (s : String) := if s.startsWith p then (s.drop p.length).toString else s
  strip "Iris.HeapLang." (strip "LeanUIIris." s)

/-! ## Programs -/

inductive Kind
  /-- A semantic edge case, with the result worked out by hand. -/
  | edge
  /-- A concurrent instance small enough for the reference interpreter. -/
  | small
  /-- Thousands of operations under real contention: too big for the interpreter. -/
  | large
  /-- A whole program the harness (`iris/bench/`) runs at each thread count. -/
  | bench
deriving BEq, Repr

structure Program where
  name : String
  exp : Exp
  kind : Kind
  /-- The result HeapLang's semantics gives (`TRAP` where the translation must stop instead),
  or `none` for the racy control, which has no single result. -/
  expect : Option String
  /-- A theorem about this exact program, not only its kernels. -/
  closed : Option Name := none

open Programs

/-- The sizes of one set of drivers. -/
structure Sizes where
  threads : Nat
  /-- Increments per thread, for each counter. -/
  incrs : Nat
  /-- The ticket lock's: it convoys once threads outnumber cores, so fewer. -/
  ticketIncrs : Nat
  rwOps : Nat
  rwWriteEvery : Nat
  treiberPushes : Nat
  ringCap : Nat
  ringItems : Nat
  pmapLen : Nat

/-- Every driver at the given sizes, with the result each must give. -/
def drivers (pre : String) (kind : Kind) (z : Sizes) : List Program :=
  let t := z.threads
  let counter (n : String) (e : Exp) (k : Nat) : Program :=
    { name := s!"{pre}_{n}", exp := e, kind, expect := toString (t * k) }
  [ counter "counter_faa" (counterFaa t z.incrs) z.incrs,
    counter "counter_casincr" (counterCasIncr t z.incrs) z.incrs,
    counter "counter_cas" (counterCas t z.incrs) z.incrs,
    counter "counter_spin" (counterSpin t z.incrs) z.incrs,
    counter "counter_futex" (counterFutex t z.incrs) z.incrs,
    counter "counter_ticket" (counterTicket t z.ticketIncrs) z.ticketIncrs,
    { name := s!"{pre}_counter_racy", exp := counterRacy t z.incrs, kind, expect := none },
    -- each thread writes once every `rwWriteEvery` operations
    { name := s!"{pre}_rw", exp := rwProg t z.rwOps z.rwWriteEvery, kind,
      expect := s!"(0, {t * (z.rwOps / z.rwWriteEvery)})" },
    -- each thread pushes 1..k and pops k: the pops sum to t·k(k+1)/2
    { name := s!"{pre}_treiber", exp := treiberProg t z.treiberPushes, kind,
      expect := s!"({t * (z.treiberPushes * (z.treiberPushes + 1) / 2)}, true)" },
    { name := s!"{pre}_spsc_stream", exp := spscStream z.ringCap z.ringItems, kind, expect := "0" },
    -- Σ_{i<n} 3i + 1
    { name := s!"{pre}_pmap", exp := pmapProg z.pmapLen, kind,
      expect := toString (3 * (z.pmapLen * (z.pmapLen - 1) / 2) + z.pmapLen) } ]

/-- Small enough for the reference interpreter. -/
def small : Sizes := ⟨3, 15, 10, 12, 3, 8, 2, 12, 12⟩
/-- Real contention, thousands of operations; a few MB of the never-freed heap. -/
def large : Sizes := ⟨4, 20000, 2000, 20000, 10, 2000, 64, 50000, 32⟩

/-- Σ_{i<n} (i mod 1000)² mod 7, `sumSq`'s result. -/
def sumSqRef (n : Nat) : Nat := ((List.range n).map fun i => (i % 1000) ^ 2 % 7).sum

def fib : Nat → Nat
  | 0 => 0 | 1 => 1 | n + 2 => fib n + fib (n + 1)

/-- Forty pseudo-random ints for the quicksort program. -/
def sortInput : List Int := (List.range 40).map fun i => ((i * 7919 + 13) % 101 : Nat) - 50

/-- The harness's thread counts and sizes. -/
def benchThreads : List Nat := [1, 2, 4, 8]
def shardIncrs : Nat := 1000000
def faaIncrs : Nat := 200000
def critIncrs : Nat := 50000
def mandelRows : Nat := 256

/-- Σ over the image of the iteration counts: what `mandelProg` must return. -/
def mandelSum (rows : Nat) : Int :=
  ((List.range (256 * rows)).map fun (p : Nat) => Mandel.g (p : Int)).sum

def bench : List Program := benchThreads.flatMap fun t => [
  { name := s!"bench_s1_faa_w{t}", exp := counterFaa t faaIncrs, kind := .bench,
    expect := toString (t * faaIncrs) },
  { name := s!"bench_s1_shards_w{t}", exp := shardsProg t shardIncrs, kind := .bench,
    expect := toString (t * shardIncrs) },
  { name := s!"bench_s2_futex_w{t}", kind := .bench,
    exp := criticalProg FutexMutex.newlock Critical.criticalFutex t critIncrs,
    expect := s!"(0, {t * critIncrs})" },
  { name := s!"bench_s2_spin_w{t}", kind := .bench,
    exp := criticalProg SpinLock.newlock Critical.criticalSpin t critIncrs,
    expect := s!"(0, {t * critIncrs})" },
  { name := s!"bench_s5_mandel_w{t}", kind := .bench,
    exp := mandelProg mandelRows (256 * mandelRows / t),
    expect := toString (mandelSum mandelRows) } ]


def programs : List Program :=
  edgeCases.map (fun (n, e, r) => { name := s!"edge_{n}", exp := e, kind := .edge, expect := r }) ++
  drivers "small" .small small ++
  [ { name := "small_par_sum", exp := parSum 60, kind := .small, expect := toString (sumSqRef 60) },
    { name := "small_pfib", exp := pfibProg 2 9, kind := .small, expect := toString (fib 9) },
    { name := "small_fork_many", exp := forkMany 12, kind := .small, expect := "12" },
    { name := "closed_two_incr", exp := TwoThreads.twoIncr, kind := .small, expect := "2",
      closed := ``TwoThreads.twoIncr_adequate },
    { name := "closed_spsc_client", exp := SpscClient.spscClient, kind := .small,
      expect := "(10, 20)", closed := ``SpscClient.spscClient_adequate },
    { name := "closed_sort_and_check", exp := Quicksort.sortAndCheck sortInput, kind := .small,
      expect := "true", closed := ``Quicksort.sortAndCheckAdequate } ] ++
  drivers "large" .large large ++
  [ { name := "small_spsc_early", exp := spscStreamEarly 1 20, kind := .small, expect := none } ] ++
  bench

mutual
/-- The closures in a value, its own included: the candidates for a kernel constant. -/
partial def closuresOfVal (v : Val) (acc : Array Val) : Array Val :=
  match v with
  | .rec_ _ _ b => closuresOfExp b (acc.push v)
  | .pair a b => closuresOfVal b (closuresOfVal a acc)
  | .injL a | .injR a => closuresOfVal a acc
  | .lit _ => acc

partial def closuresOfExp (e : Exp) (acc : Array Val) : Array Val :=
  match e with
  | .val v => closuresOfVal v acc
  | .var _ | .newProph => acc
  | .rec_ _ _ b | .unop _ b | .fst b | .snd b | .injL b | .injR b | .free b | .load b | .fork b =>
    closuresOfExp b acc
  | .app a b | .binop _ a b | .pair a b | .allocN a b | .store a b | .xchg a b | .faa a b =>
    closuresOfExp b (closuresOfExp a acc)
  | .if a b c | .case a b c | .cmpXchg a b c | .resolve a b c =>
    closuresOfExp c (closuresOfExp b (closuresOfExp a acc))
end

/-- A kernel's constants that no other kernel has as an identical term. Small terms recur:
`λ _, ref(#0)` is `Counter.newcounter`, `FutexMutex.newlock` and more, so it names no kernel. -/
def Kernel.distinct (k : Kernel) : List (Name × Val) :=
  k.consts.filter fun (_, v) => kernels.all fun k' => k'.name == k.name || !k'.consts.any (·.2 == v)

/-- The kernels a program calls, each with the distinct constants found among its closures. -/
def kernelsIn (e : Exp) : List (Kernel × List Name) :=
  let vs := closuresOfExp e #[]
  kernels.filterMap fun k =>
    match k.distinct.filter (vs.contains ·.2) with
    | [] => none
    | found => some (k, found.map (·.1))

end LeanUIIris.Manifest
