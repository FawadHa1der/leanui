/-
A reference interpreter for HeapLang, used only to test the translator.

It reuses iris-lean's computable definitions wherever they exist: `Exp.subst`, `UnOp.eval`,
`BinOp.eval`, `Val.compareSafe`, `State` with its `ExtTreeMap` heap, `State.initHeap`,
`State.get?` and `Loc.fresh`. New, and so trusted for testing: the decomposition into evaluation
contexts (transcribed from `ECtxItem.fill`, right to left), the head-step cases (transcribed from
`BaseStep`), and the scheduler. It is not proved equal to `BaseStep`.
-/
import Iris.HeapLang.Semantics

namespace LeanUIIris.Interp
open Iris.HeapLang
def isV : Exp → Option Val
  | .val v => some v
  | _ => none

abbrev R := Except String (Option (Exp × State × List Exp))

def stuckE (what : String) : Except String α := throw s!"stuck: {what}"

def loadCell (σ : State) (l : Loc) : Except String Val :=
  match σ.get? l with
  | some (some v) => pure v
  | _ => stuckE s!"access to unallocated or freed location {l.n}"

/-- One step of one thread: `none` iff the thread is a value. -/
partial def step (e : Exp) (σ : State) : R := do
  let ctx (k : Exp → Exp) (e' : Exp) : R := do
    match ← step e' σ with
    | some (e'', σ', ts) => pure (some (k e'', σ', ts))
    | none => stuckE "internal: context hole is a value"
  let head (e' : Exp) (σ' : State := σ) (ts : List Exp := []) : R := pure (some (e', σ', ts))
  match e with
  | .val _ => pure none
  | .var x => stuckE s!"free variable {x}"
  | .rec_ f x b => head (.val (.rec_ f x b))
  | .app e1 e2 =>
    match isV e2 with
    | none => ctx (fun h => .app e1 h) e2
    | some v2 => match isV e1 with
      | none => ctx (fun h => .app h (.val v2)) e1
      | some (.rec_ f x b) => head ((b.subst f (.rec_ f x b)).subst x v2)
      | some _ => stuckE "application of a non-function"
  | .unop op a =>
    match isV a with
    | none => ctx (.unop op) a
    | some v => match op.eval v with
      | some v' => head (.val v')
      | none => stuckE "unop"
  | .binop op a b =>
    match isV b with
    | none => ctx (.binop op a) b
    | some vb => match isV a with
      | none => ctx (fun h => .binop op h (.val vb)) a
      | some va => match op.eval va vb with
        | some v' => head (.val v')
        | none => stuckE "binop"
  | .if c a b =>
    match isV c with
    | none => ctx (fun h => .if h a b) c
    | some (.lit (.bool true)) => head a
    | some (.lit (.bool false)) => head b
    | some _ => stuckE "if on non-bool"
  | .pair a b =>
    match isV b with
    | none => ctx (.pair a) b
    | some vb => match isV a with
      | none => ctx (fun h => .pair h (.val vb)) a
      | some va => head (.val (.pair va vb))
  | .fst a => match isV a with
    | none => ctx .fst a
    | some (.pair v _) => head (.val v)
    | some _ => stuckE "fst"
  | .snd a => match isV a with
    | none => ctx .snd a
    | some (.pair _ v) => head (.val v)
    | some _ => stuckE "snd"
  | .injL a => match isV a with
    | none => ctx .injL a
    | some v => head (.val (.injL v))
  | .injR a => match isV a with
    | none => ctx .injR a
    | some v => head (.val (.injR v))
  | .case s l r => match isV s with
    | none => ctx (fun h => .case h l r) s
    | some (.injL v) => head (.app l (.val v))
    | some (.injR v) => head (.app r (.val v))
    | some _ => stuckE "case"
  | .allocN n v =>
    match isV v with
    | none => ctx (.allocN n) v
    | some vv => match isV n with
      | none => ctx (fun h => .allocN h (.val vv)) n
      | some (.lit (.int k)) =>
        if 0 < k then
          let l := Loc.fresh σ.heap.keys
          head (.val (.lit (.loc l))) (σ.initHeap l k (some vv))
        else stuckE "allocN size"
      | some _ => stuckE "allocN"
  | .free a => match isV a with
    | none => ctx .free a
    | some (.lit (.loc l)) => do
      let _ ← loadCell σ l
      head (.val (.lit .unit)) (σ.initHeap l 1 none)
    | some _ => stuckE "free"
  | .load a => match isV a with
    | none => ctx .load a
    | some (.lit (.loc l)) => do head (.val (← loadCell σ l))
    | some _ => stuckE "load"
  | .store a b =>
    match isV b with
    | none => ctx (.store a) b
    | some vb => match isV a with
      | none => ctx (fun h => .store h (.val vb)) a
      | some (.lit (.loc l)) => do
        let _ ← loadCell σ l
        head (.val (.lit .unit)) (σ.initHeap l 1 (some vb))
      | some _ => stuckE "store"
  | .xchg a b =>
    match isV b with
    | none => ctx (.xchg a) b
    | some vb => match isV a with
      | none => ctx (fun h => .xchg h (.val vb)) a
      | some (.lit (.loc l)) => do
        let old ← loadCell σ l
        head (.val old) (σ.initHeap l 1 (some vb))
      | some _ => stuckE "xchg"
  | .cmpXchg a b c =>
    match isV c with
    | none => ctx (.cmpXchg a b) c
    | some vc => match isV b with
      | none => ctx (fun h => .cmpXchg a h (.val vc)) b
      | some vb => match isV a with
        | none => ctx (fun h => .cmpXchg h (.val vb) (.val vc)) a
        | some (.lit (.loc l)) => do
          let old ← loadCell σ l
          unless old.compareSafe vb do stuckE "cmpXchg on non-compare-safe values"
          let ok := decide (old = vb)
          head (.val (.pair old (.lit (.bool ok)))) (if ok then σ.initHeap l 1 (some vc) else σ)
        | some _ => stuckE "cmpXchg"
  | .faa a b =>
    match isV b with
    | none => ctx (.faa a) b
    | some vb => match isV a with
      | none => ctx (fun h => .faa h (.val vb)) a
      | some (.lit (.loc l)) => do
        match ← loadCell σ l, vb with
        | .lit (.int i1), .lit (.int i2) => head (.val (.lit (.int i1))) (σ.initHeap l 1 (some (.lit (.int (i1 + i2)))))
        | _, _ => stuckE "faa on non-int"
      | some _ => stuckE "faa"
  | .fork b => head (.val (.lit .unit)) σ [b]
  | .newProph => head (.val (.lit (.prophecy ⟨0⟩)))   -- prophecies are not observable here
  | .resolve e0 p w =>
    -- erased, as in the translator (justified by ProphErasure): evaluate w, p, then e0
    match isV w with
    | none => ctx (.resolve e0 p) w
    | some vw => match isV p with
      | none => ctx (fun h => .resolve e0 h (.val vw)) p
      | some _ => head e0

/-- Pretty-printer matching `decode` in rt/runtime.mjs (closures print as `<closure>`). -/
partial def showV : Val → String
  | .lit (.int n) => toString n
  | .lit (.bool b) => toString b
  | .lit .unit => "()"
  | .lit .poison => "poison"
  | .lit (.loc l) => s!"#loc{l.n}"
  | .lit (.prophecy _) => "poison"
  | .pair a b => s!"({showV a}, {showV b})"
  | .injL v => s!"injl({showV v})"
  | .injR v => s!"injr({showV v})"
  | .rec_ .. => "<closure>"


/-- A schedule: a seed for the pseudo-random choice of thread, and the longest run of steps one
thread takes before the next choice. Bursts of 1 interleave finely; longer bursts let a thread
finish a loop before another runs, as real threads often do. -/
structure Schedule where
  seed : Nat
  burst : Nat := 1
deriving Repr

def Schedule.label (s : Schedule) : String := s!"seed {s.seed}, burst {s.burst}"

/-- The schedules the tests use. -/
def schedules : List Schedule := [⟨1, 1⟩, ⟨2, 1⟩, ⟨3, 8⟩, ⟨4, 64⟩]

/-- Run the thread pool `[main]` until the main thread is a value; the value printed as the
runtimes print it, `STUCK …`, or `OUT OF FUEL`. -/
def run (e : Exp) (sched : Schedule) (fuel : Nat := 5_000_000) : String := Id.run do
  let mut tp : Array Exp := #[e]
  let mut σ : State := default
  let mut rng := sched.seed
  let mut cur := 0
  let mut left := 0
  for _ in [0:fuel] do
    if let some v := isV tp[0]! then return showV v
    if left == 0 || (isV tp[cur]!).isSome then
      rng := (rng * 1103515245 + 12345) % 2147483648
      let live := (List.range tp.size).filter fun i => (isV tp[i]!).isNone
      cur := live[(rng / 65536) % live.length]!
      left := 1 + (rng / 8) % sched.burst
    left := left - 1
    match step tp[cur]! σ with
    | .error msg => return s!"STUCK {msg}"
    | .ok none => pure ()
    | .ok (some (e', σ', ts)) =>
      tp := (tp.set! cur e') ++ ts.toArray
      σ := σ'
  return "OUT OF FUEL"

end LeanUIIris.Interp
