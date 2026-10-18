import LeanUI
import LeanUI.Testing.Dom
import Bench
open LeanUI LeanUI.Testing

/-! Native cost of the Lean side of each benchmark operation: update + view + diff + command
encoding, with no DOM (the buffer is dropped). The upper bound on what wasm can do. -/

def timeIt (p : Program Bench.Model Bench.Msg) (label : String) (reps : Nat) (st : State Bench.Model Bench.Msg)
    (msgsOf : Bench.Model → Array Bench.Msg)
    (setup : Array Bench.Msg := #[]) : IO (State Bench.Model Bench.Msg) := do
  let mut st := st
  let mut ts : Array Nat := #[]
  let mut words := 0
  for _ in [0:reps] do
    if !setup.isEmpty then
      st := ((stepMsgs p setup).run st).2
      st := { st with diff := { st.diff with buf := st.diff.buf.reset } }
    let msgs := msgsOf st.model
    let cur := st
    let t0 ← IO.monoNanosNow
    -- lazyPure: evaluate the pure step here, between the two clock reads
    st ← IO.lazyPure fun _ => ((stepMsgs p msgs).run cur).2
    let t1 ← IO.monoNanosNow
    words := st.diff.buf.ops.size / 4
    st := { st with diff := { st.diff with buf := st.diff.buf.reset } }
    ts := ts.push (t1 - t0)
  let sorted := ts.qsort (· < ·)
  let med := sorted[sorted.size / 2]!
  IO.println s!"  {label.pushn ' ' (12 - label.length)} {Float.ofNat med / 1e6} ms  ({words} words)"
  return st

/-- `leanui-perf loop N`: N select updates on 1,000 rows, for a profiler. -/
def loopSelect (n : Nat) : IO Unit := do
  let mut st := initState Bench.program "" "#app" false
  st := ((stepMsgs Bench.program #[.run]).run st).2
  let mut t := ← IO.monoNanosNow
  for i in [0:n] do
    let cur := { st with diff := { st.diff with buf := st.diff.buf.reset } }
    let rid := (cur.model.rows[(2 + i % 2) % 1000]?.map (·.id)).getD 0
    st ← IO.lazyPure fun _ => ((stepMsgs Bench.program #[.select rid]).run cur).2
    if (i + 1) % 1000 == 0 then
      let t' ← IO.monoNanosNow
      IO.println s!"  {i + 1}: {Float.ofNat (t' - t) / 1e9} ms per select, slots {st.diff.slots.size}, free slots {st.diff.freeSlots.size}, nodes {st.diff.nextNode}, free nodes {st.diff.freeNodes.size}, names {st.diff.buf.names.size}"
      t := t'
  IO.println s!"looped {n}"

/-- Split one no-op update into its parts: building the view, and diffing it. -/
def split : IO Unit := do
  let st := ((stepMsgs Bench.program #[.run]).run (initState Bench.program "" "#app" false)).2
  let m := st.model
  let mut tv : Array Nat := #[]
  let mut td : Array Nat := #[]
  for _ in [0:21] do
    let t0 ← IO.monoNanosNow
    let v ← IO.lazyPure fun _ => Bench.view m
    let t1 ← IO.monoNanosNow
    let r ← IO.lazyPure fun _ => (patch 0 st.tree v).run { st.diff with buf := st.diff.buf.reset }
    let t2 ← IO.monoNanosNow
    if r.2.buf.ops.size > 1000000 then IO.println "?"
    tv := tv.push (t1 - t0); td := td.push (t2 - t1)
  let med (a : Array Nat) := Float.ofNat (a.qsort (· < ·))[a.size / 2]! / 1e6
  IO.println s!"  no-op update on 1,000 rows: view {med tv} ms, diff {med td} ms"

/-- Time the pieces of a no-op diff separately. -/
def parts : IO Unit := do
  let st := ((stepMsgs Bench.program #[.run]).run (initState Bench.program "" "#app" false)).2
  let m := st.model
  let v := Bench.view m
  let rowsOld : Array (Node Bench.Msg) := match st.tree with
    | .elem _ _ _ _ _ _ kids _ => match kids[1]! with
      | .elem _ _ _ _ _ _ k2 _ => match k2[0]! with
        | .elem _ _ _ _ _ _ k3 _ => k3 | _ => #[]
      | _ => #[]
    | _ => #[]
  let rowsNew : Array (Html Bench.Msg) := match v with
    | .elem _ _ _ kids => match kids[1]! with
      | .elem _ _ _ k2 => match k2[0]! with
        | .elem _ _ _ k3 => k3 | _ => #[]
      | _ => #[]
    | _ => #[]
  IO.println s!"  rows: {rowsOld.size} mounted, {rowsNew.size} in view"
  let ok := (List.range rowsOld.size).all fun i => sameF sameBudget rowsOld[i]! rowsNew[i]! != 0
  IO.println s!"  every row unchanged per sameF: {ok}"
  let med (a : Array Nat) := Float.ofNat (a.qsort (· < ·))[a.size / 2]! / 1e6
  let mut t1s : Array Nat := #[]
  let mut t2s : Array Nat := #[]
  let mut t3s : Array Nat := #[]
  let mut t4s : Array Nat := #[]
  for _ in [0:21] do
    let a ← IO.monoNanosNow
    let n ← IO.lazyPure fun _ => (List.range rowsOld.size).foldl (fun acc i => acc + sameF sameBudget rowsOld[i]! rowsNew[i]!) 0
    let b ← IO.monoNanosNow
    let sl ← IO.lazyPure fun _ => (List.range rowsOld.size).foldl (fun sl i => rebind sl rowsOld[i]! rowsNew[i]!) st.diff.slots
    let c ← IO.monoNanosNow
    let r ← IO.lazyPure fun _ => (patch 0 st.tree v).run { st.diff with buf := st.diff.buf.reset }
    let d ← IO.monoNanosNow
    let v2 ← IO.lazyPure fun _ => Bench.view m
    let e ← IO.monoNanosNow
    let k ← IO.lazyPure fun _ => (canonHtml v2).length
    if n + sl.size + r.2.slots.size + k == 0 then IO.println "?"
    t1s := t1s.push (b - a); t2s := t2s.push (c - b); t3s := t3s.push (d - c); t4s := t4s.push (e - d)
  IO.println s!"  sameF over rows {med t1s} ms, rebind over rows {med t2s} ms, whole patch {med t3s} ms, view {med t4s} ms"

/-- `leanui-perf loop-create N`: N create/clear cycles of 1,000 rows, for a profiler. -/
def loopCreate (n : Nat) : IO Unit := do
  let mut st := initState Bench.program "" "#app" false
  for _ in [0:n] do
    let cur := { st with diff := { st.diff with buf := st.diff.buf.reset } }
    st ← IO.lazyPure fun _ => ((stepMsgs Bench.program #[.run]).run cur).2
    let cur := { st with diff := { st.diff with buf := st.diff.buf.reset } }
    st ← IO.lazyPure fun _ => ((stepMsgs Bench.program #[.clear]).run cur).2
  IO.println s!"looped {n}"

/-! ## Allocation counts (`leanui-perf allocs`)

Lean's heartbeat counter (`IO.getNumHeartbeats`) is incremented by `lean_alloc_small_object`,
which every constructor object (structures, inductive values, pairs, `Option.some`, boxed
`UInt64`/`Float`) and every thunk goes through; arrays, strings, byte arrays and closures are
allocated by `lean_alloc_object` and are not counted, nor is a byte array growing. So the
difference of two readings is the exact number of *small objects* allocated in between, the
part of the allocator's work that scales with the view's node count. `tools/alloc-count.c`
counts every `malloc` and `free` of the wasm build (`tests/browser/allocs.mjs`). -/

/-- Small objects allocated while `f ()` is evaluated (see above). -/
@[noinline] def smallObjects (f : Unit → α) : IO (α × Nat) := do
  let h0 ← IO.getNumHeartbeats
  let a ← IO.lazyPure f
  let h1 ← IO.getNumHeartbeats
  return (a, h1 - h0)

/-- The view with every lazy thunk already run: diffing it renders nothing, so diffing it
instead of the view isolates what rendering lazy rows allocates. Built in `IO`, so each subtree
is computed before the closure that returns it (a pure `let` could float into the closure). -/
partial def prepare : Html Msg → IO (Html Msg)
  | .lazy k d r => do let h ← prepare (r ()); pure (.lazy k d fun _ => h)
  | .elem ns tag attrs kids => do pure (.elem ns tag attrs (← kids.mapM prepare))
  | h => pure h

/-- One decoded DOM command, with its strings already sliced out of the string area, so that
replaying a buffer through the `Buf` writers costs exactly what writing it did. -/
inductive Command where
  | createElement (n : UInt32) (ns : Ns) (tag : String)
  | createText (n : UInt32) (s : String)
  | setAttr (n : UInt32) (nm v : String)
  | removeAttr (n : UInt32) (nm : String)
  | setProp (n : UInt32) (nm : String) (v : PropValue)
  | removeProp (n : UInt32) (nm : String)
  | setText (n : UInt32) (s : String)
  | appendChild (p c : UInt32)
  | insertBefore (p c r : UInt32)
  | remove (n : UInt32)
  | replace (o n : UInt32)
  | free (n : UInt32)
  | setListener (n : UInt32) (ev : String) (slot : UInt32) (payload : Payload) (flags : UInt32)
  | removeListener (n : UInt32) (ev : String)
  | mount (sel : String) (n : UInt32)

/-- Decode the DOM commands of a buffer (`INTERN` is dropped: the writers intern again). -/
def decodeCommands (b : Buf) : Array Command := Id.run do
  let us := utf16Units b.strs
  let names : Std.HashMap UInt32 String := b.names.fold (fun m k v => m.insert v k) {}
  let ops := b.ops
  let word (i : Nat) : UInt32 :=
    ops[i]!.toUInt32 ||| (ops[i+1]!.toUInt32 <<< 8) ||| (ops[i+2]!.toUInt32 <<< 16) ||| (ops[i+3]!.toUInt32 <<< 24)
  let str (i : Nat) : String := fromUnits us (word i).toNat (word (i + 4)).toNat
  let name (i : Nat) : String := names.getD (word i) "?"
  let payload (c : UInt32) : Payload := match c with
    | 1 => .value | 2 => .checked | 3 => .key | 4 => .formData | _ => .none
  let mut out := #[]
  let mut pc := 0
  while pc < ops.size do
    let op := word pc
    let a := word (pc + 4)
    let (c, len) : Option Command × Nat :=
      if op == Op.createElement then
        (some (.createElement a (match word (pc + 8) with | 1 => .svg | 2 => .mathml | _ => .html) (name (pc + 12))), 16)
      else if op == Op.createText then (some (.createText a (str (pc + 8))), 16)
      else if op == Op.setAttr then (some (.setAttr a (name (pc + 8)) (str (pc + 12))), 20)
      else if op == Op.removeAttr then (some (.removeAttr a (name (pc + 8))), 12)
      else if op == Op.setPropStr then (some (.setProp a (name (pc + 8)) (.str (str (pc + 12)))), 20)
      else if op == Op.setPropBool then (some (.setProp a (name (pc + 8)) (.bool (word (pc + 12) == 1))), 16)
      else if op == Op.setPropNum then
        (some (.setProp a (name (pc + 8)) (.num ((str (pc + 12)).toNat?.getD 0).toFloat)), 20)
      else if op == Op.removeProp then (some (.removeProp a (name (pc + 8))), 12)
      else if op == Op.setText then (some (.setText a (str (pc + 8))), 16)
      else if op == Op.appendChild then (some (.appendChild a (word (pc + 8))), 12)
      else if op == Op.insertBefore then (some (.insertBefore a (word (pc + 8)) (word (pc + 12))), 16)
      else if op == Op.remove then (some (.remove a), 8)
      else if op == Op.replace then (some (.replace a (word (pc + 8))), 12)
      else if op == Op.free then (some (.free a), 8)
      else if op == Op.setListener then
        (some (.setListener a (name (pc + 8)) (word (pc + 12)) (payload (word (pc + 16))) (word (pc + 20))), 24)
      else if op == Op.removeListener then (some (.removeListener a (name (pc + 8))), 12)
      else if op == Op.intern then (none, 16)
      else if op == Op.mount then (some (.mount (str (pc + 4)) (word (pc + 12))), 16)
      else (none, ops.size)  -- not a DOM command: stop
    if let some c := c then out := out.push c
    pc := pc + len
  return out

/-- Write the commands again (what encoding them cost, interning included). -/
def replay (b : Buf) (cs : Array Command) : Buf :=
  cs.foldl (init := b) fun b c => match c with
    | .createElement n ns t => b.createElement n ns t
    | .createText n s => b.createText n s
    | .setAttr n nm v => b.setAttr n nm v
    | .removeAttr n nm => b.removeAttr n nm
    | .setProp n nm v => b.setProp n nm v
    | .removeProp n nm => b.removeProp n nm
    | .setText n s => b.setText n s
    | .appendChild p c => b.appendChild p c
    | .insertBefore p c r => b.insertBefore p c r
    | .remove n => b.remove n
    | .replace o n => b.replace o n
    | .free n => b.free n
    | .setListener n ev sl pl fl => b.setListener n ev sl pl fl
    | .removeListener n ev => b.removeListener n ev
    | .mount sel n => b.mount sel n

/-- Small objects of one update, by phase. `render` is what running the lazy rows' thunks
allocated, `mount` the rest of the diff (mounting, patching, releasing) without the encoding,
`encode` writing the command buffer (replayed), `subs` reconciling subscriptions, `step` the
whole `stepMsgs` (a cross-check: about the sum of the others). -/
structure Phases where
  update : Nat
  view : Nat
  render : Nat
  mount : Nat
  encode : Nat
  subs : Nat
  step : Nat

/-- The phases of one update from `st` (`calib`: what an empty measurement counts). -/
def phasesOf (calib : Nat) (p : Program Model Msg) (st : State Model Msg) (msgs : Array Msg) :
    IO (Phases × State Model Msg) := do
  let smallObjects {α} (f : Unit → α) : IO (α × Nat) := do
    let (a, n) ← smallObjects f; return (a, n - calib)
  let (model, update) ← smallObjects fun _ => msgs.foldl (fun m msg => (p.update msg m).1) st.model
  let (v, view) ← smallObjects fun _ => p.view model
  let (_, all) ← smallObjects fun _ => (patch 0 st.tree v).run st.diff
  let pv ← prepare v
  let ((_, d2), noRender) ← smallObjects fun _ => (patch 0 st.tree pv).run st.diff
  let cs := decodeCommands d2.buf
  let (b, encode) ← smallObjects fun _ => replay st.diff.buf cs
  if b.ops.size != d2.buf.ops.size then IO.println s!"  (replay wrote {b.ops.size} bytes, the diff {d2.buf.ops.size})"
  let (st', step) ← smallObjects fun _ => ((stepMsgs p msgs).run st).2
  -- `stepMsgs` reconciles subscriptions last; again, on the state it left
  let (_, subs) ← smallObjects fun _ => ((syncSubs (p.subscriptions st'.model)).run st').2
  let ph := { update, view, render := all - noRender, mount := noRender - encode, encode, subs, step }
  return (ph, { st' with diff := { st'.diff with buf := st'.diff.buf.reset } })

/-- `leanui-perf allocs`: small objects per benchmark operation, by phase, and per created row. -/
def allocs : IO Unit := do
  let (_, calib) ← smallObjects fun _ => ()
  IO.println "Small objects (constructors, thunks) per operation, Bench.program (lazy rows)"
  IO.println "| operation | update | view | render | mount | encode | subs | step | per new row |"
  IO.println "|---|--:|--:|--:|--:|--:|--:|--:|--:|"
  let p := Bench.program
  let mut st := initState p "" "#app" false
  st := { st with diff := { st.diff with buf := st.diff.buf.reset } }
  let run (st : State Bench.Model Bench.Msg) (msgs : Array Bench.Msg) :=
    let st := ((stepMsgs p msgs).run st).2
    { st with diff := { st.diff with buf := st.diff.buf.reset } }
  let rowId (m : Bench.Model) (i : Nat) : Nat := (m.rows[i]?.map (·.id)).getD 0
  -- (name, setup messages, the measured messages, rows it creates)
  let ops : List (String × List Bench.Msg × (Bench.Model → Array Bench.Msg) × Nat) := [
    ("create1k", [.run, .clear], fun _ => #[.run], 1000),
    ("replace1k", [.run], fun _ => #[.run], 1000),
    ("update10th", [.run], fun _ => #[.update], 0),
    ("select", [.run], fun m => #[.select (rowId m 4)], 0),
    ("swap", [.run], fun _ => #[.swapRows], 0),
    ("remove", [.run], fun m => #[.remove (rowId m 3)], 0),
    ("append1k", [.run], fun _ => #[.add], 1000),
    ("clear1k", [.run], fun _ => #[.clear], 0),
    ("create10k", [.clear], fun _ => #[.runLots], 10000)]
  for (name, setup, msgs, rows) in ops do
    for m in setup do st := run st #[m]
    let (ph, st') ← phasesOf calib p st (msgs st.model)
    st := st'
    let perRow := if rows == 0 then "" else
      let x := Float.ofNat ph.step / Float.ofNat rows
      s!"{(x * 100).round / 100}"
    IO.println s!"| {name} | {ph.update} | {ph.view} | {ph.render} | {ph.mount} | {ph.encode} | {ph.subs} | {ph.step} | {perRow} |"

def main (args : List String) : IO UInt32 := do
  if args == ["allocs"] then allocs; return 0
  if let ["loop-create", n] := args then loopCreate n.toNat!; return 0
  if args == ["parts"] then parts; return 0
  if args == ["split"] then split; return 0
  if let ["loop", n] := args then loopSelect n.toNat!; return 0
  for (name, p) in [("lazy rows", Bench.program), ("eager rows", Bench.programEager)] do
    IO.println s!"LeanUI native cost per operation, {name} (median, update+view+diff+encode, no DOM)"
    let mut st := initState p "" "#app" false
    st := { st with diff := { st.diff with buf := st.diff.buf.reset } }
    let rowId (m : Bench.Model) (i : Nat) : Nat := (m.rows[i]?.map (·.id)).getD 0
    st ← timeIt p "create1k" 9 st (fun _ => #[.run]) #[.clear]
    st ← timeIt p "replace1k" 9 st (fun _ => #[.run])
    st ← timeIt p "update10th" 9 st (fun _ => #[.update])
    st ← timeIt p "select" 9 st (fun m => #[.select (if m.selected == some (rowId m 4) then rowId m 5 else rowId m 4)])
    st ← timeIt p "swap" 9 st (fun _ => #[.swapRows])
    st ← timeIt p "remove" 9 st (fun m => #[.remove (rowId m 3)])
    st ← timeIt p "append1k" 5 st (fun _ => #[.add]) #[.run]
    st ← timeIt p "clear1k" 9 st (fun _ => #[.clear]) #[.run]
    let _ ← timeIt p "create10k" 3 st (fun _ => #[.runLots]) #[.clear]
  return 0
