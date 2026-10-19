import LeanUI
/-!
# Keyed lists, end to end: the frames a real browser must apply

Drives a keyed list through random edits with the real runtime (`LeanUI.start`, `LeanUI.Diff`)
and prints, as JSON, every command buffer the page would receive together with the rows it must
show afterwards. `tests/browser/keyed-dom.mjs` applies the buffers with `runtime/leanui.js` in
Chromium and Firefox and checks the real DOM: order, node identity, and that the number of
insertions is the minimum (`docs/PROOFS.md`, "what is tested").

    lake build LeanUI:shared
    lake env lean --load-dynlib=.lake/build/lib/libleanui_LeanUI.dylib --run tests/KeyedDom.lean [steps] [seed]

(`.so` instead of `.dylib` on Linux. The library must be loaded because the command buffer's byte
primitives are inline C, which the interpreter can only call compiled; see `LeanUI.Patch`.)
-/
open LeanUI Attr

structure Rng where
  s : UInt64
def Rng.next (r : Rng) : Rng × Nat :=
  let s := r.s * 6364136223846793005 + 1442695040888963407; (⟨s⟩, (s >>> 33).toNat)
def Rng.below (r : Rng) (n : Nat) : Rng × Nat := let (r, x) := r.next; (r, if n == 0 then 0 else x % n)

def shuffle (r : Rng) (xs : Array Nat) : Rng × Array Nat := Id.run do
  let mut r := r; let mut a := xs
  for i in [0:a.size] do
    let (r', j) := r.below (a.size - i); r := r'
    a := a.swapIfInBounds i (i + j)
  return (r, a)

inductive Msg | setRows (rows : Array Nat)

def decodeRows (s : String) : Option Msg :=
  some (.setRows ((s.splitOn ",").filterMap String.toNat? |>.toArray))

def view (rows : Array Nat) : Html Msg :=
  el "div" #[] #[
    el "button" #[id "go", Attr.on "click" { payload := .value, decode := decodeRows }] #[],
    el "ul" #[id "list"] (rows.map fun k =>
      el "li" #[Attr.key (toString k), cls (if k % 3 == 0 then "a" else "b")]
        #[text s!"row {k}", el "b" #[] #[text (toString (k * 7 % 13))]])]

def prog : Program (Array Nat) Msg where
  init _ := (#[], .none)
  update | .setRows rs, _ => (rs, .none)
  view := view

/-- One random edit of a list of distinct keys (fresh keys come from `next`). -/
def edit (rng : Rng) (rows : Array Nat) (next : Nat) : Rng × Array Nat × Nat := Id.run do
  let (rng, op) := rng.below 10
  let mut rng := rng
  let mut rows := rows
  let mut next := next
  match op with
  | 0 | 1 => let (r, s) := shuffle rng rows; rng := r; rows := s
  | 2 =>  -- insert a few fresh keys at random places
    let (r, n) := rng.below 5; rng := r
    for _ in [0:n + 1] do
      let (r, at_) := rng.below (rows.size + 1); rng := r
      rows := rows.insertIdxIfInBounds at_ next; next := next + 1
  | 3 =>  -- delete a few
    let (r, n) := rng.below 4; rng := r
    for _ in [0:n + 1] do
      if rows.size > 0 then
        let (r, at_) := rng.below rows.size; rng := r
        rows := rows.eraseIdxIfInBounds at_
  | 4 => rows := rows.reverse
  | 5 =>  -- move one row
    if rows.size > 1 then
      let (r, a) := rng.below rows.size; rng := r
      let (r, b) := rng.below rows.size; rng := r
      let x := rows[a]!
      rows := (rows.eraseIdxIfInBounds a).insertIdxIfInBounds b x
  | 6 =>  -- swap two rows
    if rows.size > 1 then
      let (r, a) := rng.below rows.size; rng := r
      let (r, b) := rng.below rows.size; rng := r
      rows := rows.swapIfInBounds a b
  | 7 =>  -- replace everything
    let (r, n) := rng.below 25; rng := r
    rows := (Array.range n).map (· + next); next := next + n
  | 8 =>  -- mixed: shuffle, drop some, add some
    let (r, s) := shuffle rng rows; rng := r
    let (r, d) := rng.below (s.size + 1); rng := r
    rows := s.extract 0 (s.size - d / 2)
    let (r, n) := rng.below 4; rng := r
    for i in [0:n] do rows := rows.push (next + i)
    next := next + n
  | _ => if rows.size > 30 then rows := #[]   -- keep lists small, sometimes empty
  return (rng, rows, next)

def hexDigit (n : Nat) : Char := if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)
def hex (b : ByteArray) : String := Id.run do
  let mut s := ""
  for x in b do s := (s.push (hexDigit (x.toNat / 16))).push (hexDigit (x.toNat % 16))
  return s

def main (args : List String) : IO Unit := do
  let steps := (args.head? >>= String.toNat?).getD 400
  let seed := (args[1]? >>= String.toNat?).getD 1
  let frames ← IO.mkRef (#[] : Array (ByteArray × ByteArray))
  let host : Host := { flush := fun ops strs => frames.modify (·.push (ops, strs)) }
  let inst ← start prog host "" "#app" false
  let mut out : Array String := #[]
  let take : IO String := do
    let fs ← frames.modifyGet fun fs => (fs, #[])
    let ops := fs.foldl (fun b f => b ++ f.1) ByteArray.empty
    -- one update produces at most one buffer; join defensively (no string offsets cross frames
    -- when there is only one)
    if fs.size > 1 then throw (IO.userError "more than one buffer for one update")
    let strs := fs.foldl (fun b f => b ++ f.2) ByteArray.empty
    return s!"\"ops\":\"{hex ops}\",\"strs\":\"{hex strs}\""
  out := out.push s!"\{{← take},\"rows\":[]}"
  let mut rng : Rng := ⟨seed.toUInt64⟩
  let mut rows : Array Nat := #[]
  let mut next := 0
  for _ in [0:steps] do
    let (r, rs, n) := edit rng rows next
    rng := r; rows := rs; next := n
    -- the hidden button's listener is slot 1; its payload carries the new rows
    inst.event 1 (",".intercalate (rows.toList.map toString))
    out := out.push s!"\{{← take},\"rows\":[{",".intercalate (rows.toList.map toString)}]}"
  IO.println s!"\{\"steps\":[{",\n".intercalate out.toList}]}"
