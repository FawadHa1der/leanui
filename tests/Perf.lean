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

def main (args : List String) : IO UInt32 := do
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
