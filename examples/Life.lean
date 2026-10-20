module
public import LeanUI
public section
open LeanUI Attr

/-!
# Life: a thousand cells, one generation per click

Conway's Game of Life on a 40 × 25 board (1,000 cells) whose edges wrap around. Each click on
**Step** computes the next generation and redraws the board: every cell is an element, and a row
is rebuilt and diffed only when one of its cells changed (`lazy` on the row's bits).

The race page (`bench/race/`) runs this program twice, compiled to wasm64 and interpreted by
lean-vir, next to a hand-written JavaScript version (`bench/race/life-vanilla.html`), and clicks
Step a thousand times in each. All three start from the same board (drawn with the 64-bit LCG
of `examples/Bench.lean`) and print the generation, the live cells and an FNV-1a hash of the board,
so the race can check that they ended in the same place.
-/
namespace Life

def cols : Nat := 40
def rows : Nat := 25

structure Model where
  /-- One byte per cell, row by row: 1 alive, 0 dead. -/
  cells : ByteArray
  gen : Nat := 0

inductive Msg | step | reset

/-- The first board: each cell is alive when its draw of the LCG is divisible by 3. The LCG starts
at 1135, a start whose board is still busy at generation 1,000 (from 42, Bench's start, it settles
to 12 cells). -/
def seed : ByteArray := Id.run do
  let mut s : UInt64 := 1135
  let mut b := ByteArray.emptyWithCapacity (cols * rows)
  for _ in [0:cols * rows] do
    s := s * 6364136223846793005 + 1442695040888963407
    b := b.push (if (s >>> 33) % 3 == 0 then 1 else 0)
  return b

/-- The next generation: a cell with 3 live neighbours is born, one with 2 or 3 survives. -/
def next (b : ByteArray) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity (cols * rows)
  for y in [0:rows] do
    let up := (y + rows - 1) % rows * cols
    let mid := y * cols
    let down := (y + 1) % rows * cols
    for x in [0:cols] do
      let l := (x + cols - 1) % cols
      let r := (x + 1) % cols
      let n := b[up + l]! + b[up + x]! + b[up + r]! + b[mid + l]! + b[mid + r]! +
        b[down + l]! + b[down + x]! + b[down + r]!
      out := out.push (if n == 3 || (n == 2 && b[mid + x]! == 1) then 1 else 0)
  return out

def population (b : ByteArray) : Nat := Id.run do
  let mut n := 0
  for i in [0:b.size] do n := n + b[i]!.toNat
  return n

/-- FNV-1a (32-bit) over the cells. -/
def hash (b : ByteArray) : UInt32 := Id.run do
  let mut h : UInt32 := 2166136261
  for i in [0:b.size] do h := (h ^^^ b[i]!.toUInt32) * 16777619
  return h

/-- Eight hexadecimal digits. -/
def hex (h : UInt32) : String :=
  let ds := Nat.toDigits 16 h.toNat
  String.ofList (List.replicate (8 - ds.length) '0' ++ ds)

/-- Row `y` as bits, its first cell highest: what the row's subtree depends on. -/
def rowBits (b : ByteArray) (y : Nat) : UInt64 := Id.run do
  let mut v : UInt64 := 0
  for x in [0:cols] do v := (v <<< 1) ||| b[y * cols + x]!.toUInt64
  return v

def update : Msg → Model → Model × Cmd Msg
  | .step, m => ({ m with cells := next m.cells, gen := m.gen + 1 }, .none)
  | .reset, _ => ({ cells := seed }, .none)

def row (bits : UInt64) : Html Msg :=
  el "div" #[cls "r"] ((Array.range cols).map fun x =>
    if (bits >>> (cols - 1 - x).toUInt64) &&& 1 == 1 then el "i" #[cls "on"] #[] else el "i" #[] #[])

def view (m : Model) : Html Msg :=
  el "div" #[cls "life"] #[
    el "div" #[id "board", cls "board"] ((Array.range rows).map fun y =>
      let bits := rowBits m.cells y
      lazy bits fun _ => row bits),
    el "p" #[cls "stats"] #[
      text "generation ", el "output" #[id "gen"] #[text (toString m.gen)],
      text " · alive ", el "output" #[id "pop"] #[text (toString (population m.cells))],
      text " · board ", el "output" #[id "hash"] #[text (hex (hash m.cells))]],
    el "p" #[cls "buttons"] #[
      el "button" #[Attr.attr "type" "button", id "step", onClick .step] #[text "Step"],
      el "button" #[Attr.attr "type" "button", id "reset", onClick .reset] #[text "Reset"]]]

def program : Program Model Msg := { init := fun _ => ({ cells := seed }, .none), update, view }

end Life
