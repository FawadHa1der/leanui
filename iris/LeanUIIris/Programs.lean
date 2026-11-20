/-
The programs the generator translates. The kernels they call are the proved constants themselves,
imported from their proof modules or from iris-lean (never copies). The drivers around them
(`rep`, `spawnN`, `joinAll`, `onThreads`, the loops below) are unproved glue, except for the three
programs that have a closed theorem of their own (`closed` in `Manifest.lean`).
-/
import Iris.HeapLang.Lib.SpinLock
import Iris.HeapLang.Lib.TicketLock
import Iris.HeapLang.Lib.Counter
import Iris.HeapLang.Lib.Spawn
import Iris.HeapLang.Lib.Par
import Iris.HeapLang.Lib.RwSpinLock
import Iris.HeapLang.Lib.Quicksort
import LeanUIIris.Kernels.AtomicCounter
import LeanUIIris.Kernels.ParMap
import LeanUIIris.Kernels.Treiber
import LeanUIIris.Kernels.SpscRing
import LeanUIIris.Kernels.FutexMutex

namespace LeanUIIris.Programs
open Iris.HeapLang

/-! ## Drivers (unproved glue) -/

/-- `rep n f` runs `f #()` `n` times. -/
def rep : Val := hl_val%
  rec rep n f := if n ≤ #0 then #() else (f #(); rep (n - #1) f)

/-- Spawn `k` copies of the thunk `f`; a list (nested `some((h, rest))`) of join handles. -/
def spawnN : Val := hl_val%
  rec spawnN k f :=
    if k ≤ #0 then none()
    else (let h := &Spawn.spawn f; some((h, spawnN (k - #1) f)))

def joinAll : Val := hl_val%
  rec joinAll hs :=
    match hs with
    | none() => #()
    | some(p) => (&Spawn.join (fst(p)); joinAll (snd(p)))

/-- Run the thunk `work` on `t` threads: `t - 1` forked ones and the current one, then join. -/
def onThreads : Val := hl_val%
  λ t work, let hs := &spawnN (t - #1) work; work #(); &joinAll hs

/-! ## A shared counter, seven ways: `t` threads × `k` increments, then read -/

def counterFaa (t k : Nat) : Exp := hl%
  let c := ref(#0);
  &onThreads #t (λ _, &rep #k (λ _, &AtomicCounter.faaIncr c));
  !c

def counterCasIncr (t k : Nat) : Exp := hl%
  let c := ref(#0);
  &onThreads #t (λ _, &rep #k (λ _, &AtomicCounter.casIncr c));
  !c

/-- iris-lean's own CAS counter (`Counter.incr`, a different term from `casIncr`). -/
def counterCas (t k : Nat) : Exp := hl%
  let c := &Counter.newcounter #();
  &onThreads #t (λ _, &rep #k (λ _, &Counter.incr c));
  &Counter.read c

def counterSpin (t k : Nat) : Exp := hl%
  let c := ref(#0);
  let lk := &SpinLock.newlock #();
  &onThreads #t (λ _, &rep #k (λ _, &SpinLock.acquire lk; c ← !c + #1; &SpinLock.release lk));
  !c

def counterTicket (t k : Nat) : Exp := hl%
  let c := ref(#0);
  let lk := &TicketLock.newlock #();
  &onThreads #t (λ _, &rep #k (λ _, &TicketLock.acquire lk; c ← !c + #1; &TicketLock.release lk));
  !c

def counterFutex (t k : Nat) : Exp := hl%
  let c := ref(#0);
  let lk := &FutexMutex.newlock #();
  &onThreads #t (λ _, &rep #k (λ _, &FutexMutex.acquire lk; c ← !c + #1; &FutexMutex.release lk));
  !c

/-- The negative control: an unsynchronised read-modify-write. It has no proof (the invariant
cannot be re-established between the load and the store) and loses updates in the interpreter
too: the race belongs to the program, not to the translation. -/
def counterRacy (t k : Nat) : Exp := hl%
  let c := ref(#0);
  &onThreads #t (λ _, &rep #k (λ _, c ← !c + #1));
  !c

/-! ## Readers and writers (`RwSpinLock`) -/

/-- `t` threads, `k` operations each, one write in `w`: a writer bumps two cells inside the write
lock, a reader checks they are equal inside a read lock. The number of unequal reads (0) and the
final value. -/
def rwProg (t k w : Nat) : Exp := hl%
  let a := ref(#0);
  let b := ref(#0);
  let torn := ref(#0);
  let lk := &RwSpinLock.newlock #();
  let op := (λ i,
    if i % #w = #0 then
      (&RwSpinLock.acquireWriter lk; a ← !a + #1; b ← !b + #1; &RwSpinLock.releaseWriter lk)
    else
      (&RwSpinLock.acquireReader lk;
       (if !a = !b then #() else faa(torn, #1); #());
       &RwSpinLock.releaseReader lk));
  let loop := (rec loop i := if i ≤ #0 then #() else (op i; loop (i - #1)));
  &onThreads #t (λ _, loop #k);
  (!torn, !a)

/-! ## Treiber's stack -/

/-- Each of `t` threads pushes `1..k`, then pops `k` times; the sum of everything popped
(t·k(k+1)/2) and whether the stack ends empty. -/
def treiberProg (t k : Nat) : Exp := hl%
  let s := &Treiber.newStack #();
  let total := ref(#0);
  let pushes := (rec pushes i := if i ≤ #0 then #() else (&Treiber.push s i; pushes (i - #1)));
  let pops := (rec pops i acc :=
    if i ≤ #0 then acc
    else (match &Treiber.pop s with
      | none() => pops i acc
      | some(x) => pops (i - #1) (acc + x)));
  &onThreads #t (λ _, pushes #k; faa(total, pops #k #0); #());
  (!total, match &Treiber.pop s with | none() => #true | some(_) => #false)

/-! ## The SPSC ring -/

/-- A producer pushes `0..n-1` through a ring of capacity `cap`, retrying when full; the consumer
pops `n` items, retrying when empty, and counts those that are not the next number (0). -/
def spscStream (cap n : Nat) : Exp := hl%
  let buf := allocn(#cap, #0);
  let hd := ref(#0);
  let tl := ref(#0);
  let push := (rec push v := if &SpscRing.tryPush buf hd tl #cap v then #() else push v);
  let pop := (rec pop u := match &SpscRing.tryPop buf hd tl #cap with
    | none() => pop u
    | some(x) => x);
  let produce := (rec produce i := if #n ≤ i then #() else (push i; produce (i + #1)));
  let consume := (rec consume i bad :=
    if #n ≤ i then bad else consume (i + #1) (if pop #() = i then bad else bad + #1));
  let r := (produce #0) ‖ (consume #0 #0);
  snd(r)

/-! ## Fork-join -/

def affine : Val := hl_val% λ x, #3 * x + #1

/-- `ParMap.pmap` maps `x ↦ 3x + 1` over `0..n-1` in place, splitting in halves down to single
cells; the sum afterwards, 3n(n-1)/2 + n. -/
def pmapProg (n : Nat) : Exp := hl%
  let a := allocn(#n, #0);
  let init := (rec init i := if #n ≤ i then #() else ((a +ₗ i) ← i; init (i + #1)));
  init #0;
  &ParMap.pmap &affine a #n;
  let sum := (rec sum i acc := if #n ≤ i then acc else sum (i + #1) (acc + !(a +ₗ i)));
  sum #0 #0

def sumSq : Val := hl_val%
  rec sumSq i n acc := if n ≤ i then acc else sumSq (i + #1) n (acc + ((i % #1000) * (i % #1000)) % #7)

/-- The two halves of a range with `‖` (`Par.par`). -/
def parSum (n : Nat) : Exp := hl%
  let p := (&sumSq #0 #((n / 2 : Nat)) #0) ‖ (&sumSq #((n / 2 : Nat)) #n #0);
  fst(p) + snd(p)

/-- Recursive `‖` with a sequential cutoff: 2^d - 1 forks, each parent spin-joins. -/
def pfib : Val := hl_val%
  rec pfib d n :=
    if n < #2 then n
    else if d ≤ #0 then pfib d (n - #1) + pfib d (n - #2)
    else (let p := (pfib (d - #1) (n - #1)) ‖ (pfib (d - #1) (n - #2)); fst(p) + snd(p))

def pfibProg (d n : Nat) : Exp := hl% &pfib #d #n

/-- `n` forks, each one `faa`; the main thread spins until all are done. -/
def forkMany (n : Nat) : Exp := hl%
  let c := ref(#0);
  let go := (rec go i := if i ≤ #0 then #() else (fork(faa(c, #1)); go (i - #1)));
  go #n;
  let wait := (rec wait u := if !c = #n then !c else wait u);
  wait #()

/-! ## Semantic edge cases, with the result HeapLang's semantics gives (worked out by hand) -/

def edgeCases : List (String × Exp × String) := [
  ("eval-order-pair", hl% let l := ref(#0); (faa(l, #1), faa(l, #10)), "(10, 0)"),
  ("eval-order-xchg", hl% let l := ref(#1); (xchg(l, #2), !l), "(1, 1)"),
  ("eval-order-binop", hl% let l := ref(#1); (l ← #5; #0) + !l, "1"),
  ("rec-self-shadows-arg", hl% let g := (rec f f := f); let r := g #5; r = #5, "false"),
  ("tdiv-tmod-zero", hl% (#7 / #0, #7 % #0), "(0, 7)"),
  ("tdiv-tmod-neg", hl% (#(-7 : Int) / #2, #(-7 : Int) % #2), "(-3, -1)"),
  ("shifts", hl% (#(-7 : Int) >>> #1, (#3 <<< #4, #5 <<< #(-1 : Int))), "(-4, (48, 2))"),
  ("bitwise-int-bool", hl% ((#12 &&& #10, #12 ||| #3), (#true ^^^ #true, ~ #5)), "((8, 15), (false, -6))"),
  ("closure-capture", hl% let a := #1; let f := (λ x, x + a); let a := #100; f #2 + a, "103"),
  ("curried-partial", hl% let add3 := (λ x y z, x + y + z); let g := add3 #1; let h := g #2; h #3, "6"),
  ("case-boxed", hl% match injl((#1, #2)) with | injl(p) => fst(p) | injr(_) => #0, "1"),
  ("unboxed-eq", hl% (injl(#3) = injl(#3), (some(#()) = none(), none() = none())), "(true, (false, true))"),
  ("cas-none", hl% let l := ref(none()); (cas(l, none(), some(#3)), !l), "(true, injl(()))"),
  ("cmpxchg-pair", hl% let l := ref(#4); cmpXchg(l, #5, #6), "(4, false)"),
  ("loop-1e6", hl% (rec loop i := if i = #1000000 then i else loop (i + #1)) #0, "1000000"),
  ("array-offset", hl% let a := allocn(#3, #0); (a +ₗ #2) ← #7; !(a +ₗ #2) + !a, "7"),
  ("mutual-via-closure", hl%
      let ev := (rec ev n := if n = #0 then #true else (if n = #1 then #false else ev (n - #2)));
      (ev #10, ev #7), "(true, false)"),
  ("nested-pairs-heap", hl% let l := ref((#1, (injr(#2), #true))); let v := !l; fst(snd(v)), "injr(2)"),
  ("fork-handoff", hl%
      let l := ref(#0); fork(l ← #1);
      (rec wait u := if !l = #1 then #42 else wait u) #(), "42"),
  ("spawn-join", hl% let h := &Spawn.spawn (λ _, #20 + #22); &Spawn.join h, "42"),
  ("par-pair", hl% (#1 + #2) ‖ (#3 * #4), "(3, 12)"),
  ("proph-erased", hl% let l := ref(#0); let p := newProph(); resolve(faa(l, #5), p, #0); !l, "5"),
  ("free-no-reuse", hl% let a := ref(#1); free(a); let b := ref(#2); a = b, "false"),
  -- HeapLang's ints are unbounded; the translation stops instead of wrapping
  ("overflow-traps", hl% #268435455 + #1, "TRAP"),
  ("futex-hints-are-no-ops", hl%
      let l := ref(#5); &Hints.futexWait l #4; &Hints.futexWake l; !l, "5")
]

end LeanUIIris.Programs
