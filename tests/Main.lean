import LeanUI
import LeanUI.Testing.Harness
import LeanUI.Testing.Wire
open LeanUI LeanUI.Testing Attr

/-! A deterministic PRNG for randomised tests. -/
structure Rng where
  s : UInt64
def Rng.next (r : Rng) : Rng × Nat := let s := r.s * 6364136223846793005 + 1442695040888963407; (⟨s⟩, (s >>> 33).toNat)
def Rng.below (r : Rng) (n : Nat) : Rng × Nat := let (r, x) := r.next; (r, if n == 0 then 0 else x % n)

def shuffle (r : Rng) (xs : Array Nat) : Rng × Array Nat := Id.run do
  let mut r := r; let mut a := xs
  for i in [0:a.size] do
    let (r', j) := r.below (a.size - i); r := r'
    a := a.swapIfInBounds i (i + j)
  return (r, a)

/-! ## A counter -/
inductive CMsg | inc | dec | set (n : Nat)
def counter : Program Nat CMsg where
  init _ := (0, .none)
  update m n := match m with | .inc => (n + 1, .none) | .dec => (n - 1, .none) | .set k => (k, .none)
  view n := el "div" #[cls "counter"] #[
    el "button" #[id "dec", onClick .dec] #[text "-"],
    el "span" #[id "value"] #[text (toString n)],
    el "button" #[id "inc", onClick .inc] #[text "+"],
    el "input" #[id "box", value (toString n), onInput fun s => .set (s.toNat?.getD 0)] #[]]

def testCounter : IO Unit := do
  let r ← run counter
  r.check (counter.view 0) "counter mount"
  for _ in [0:3] do r.click "id" "inc"
  r.check (counter.view 3) "counter after 3 inc"
  r.fire (← r.find "id" "box") "input" "41"
  r.check (counter.view 41) "counter after input"
  r.click "id" "dec"
  r.check (counter.view 40) "counter after dec"
  IO.println "  counter: ok"

/-! ## Keyed and positional lists under random edits -/
inductive LMsg | setRows (rows : Array Nat) | pick (k : Nat)
structure LModel where
  rows : Array Nat := #[]
  picked : Option Nat := none
/-- How the test list renders its rows. -/
inductive ListMode | positional | keyed | keyedLazy
  deriving BEq

def ListMode.name : ListMode → String
  | .positional => "positional" | .keyed => "keyed" | .keyedLazy => "keyed lazy"

def rowView (keyed : Bool) (picked : Bool) (k : Nat) : Html LMsg :=
  el "li" ((if keyed then #[Attr.key (toString k)] else #[]) ++
    #[cls (if picked then "picked" else "row"), onClick (.pick k)])
    #[text s!"row {k}", el "b" #[] #[text (toString (k * 7 % 13))]]

def listView (mode : ListMode) (m : LModel) : Html LMsg :=
  el "ul" #[id "list"] (m.rows.map fun k =>
    let picked := m.picked == some k
    match mode with
    | .positional => rowView false picked k
    | .keyed => rowView true picked k
    | .keyedLazy => keyed (toString k) (lazy (k, picked) fun _ => rowView false picked k))
def listProg (mode : ListMode) : Program LModel LMsg where
  init _ := ({}, .none)
  update m s := match m with | .setRows rs => ({ s with rows := rs }, .none) | .pick k => ({ s with picked := some k }, .none)
  view := listView mode

def decodeRows (s : String) : Option LMsg :=
  some (.setRows ((s.splitOn ",").filterMap String.toNat? |>.toArray))

/-- Drive a list through random edits. A hidden control button carries the next row list in its
event payload, so every edit goes through the same event path the browser uses. -/
def testLists (mode : ListMode) (iters : Nat) : IO Unit := do
  let mut rng : Rng := ⟨if mode == .keyed then 7 else if mode == .keyedLazy then 3 else 11⟩
  let p : Program LModel LMsg := { listProg mode with
    view := fun m => el "div" #[] #[
      el "button" #[id "go", Attr.on "click" { payload := .value, decode := decodeRows }] #[],
      listView mode m] }
  let r ← run p
  let mut model : LModel := {}
  let mut pool : Array Nat := #[]
  for it in [0:iters] do
    -- random edit: shuffle, insert, delete, replace, sometimes clear or reverse
    let (rng', op) := rng.below 7; rng := rng'
    let mut rows := model.rows
    if op == 0 then let (rng', s) := shuffle rng rows; rng := rng'; rows := s
    else if op == 1 then
      let (rng', n) := rng.below 6; rng := rng'
      for _ in [0:n + 1] do pool := pool.push (1000 + pool.size); rows := rows.insertIdxIfInBounds (pool.size % (rows.size + 1)) pool.back!
    else if op == 2 then
      let (rng', n) := rng.below 4; rng := rng'
      for _ in [0:n + 1] do if rows.size > 0 then rows := rows.eraseIdxIfInBounds (pool.size % rows.size)
    else if op == 3 then rows := rows.reverse
    else if op == 4 then
      let (rng', n) := rng.below 30; rng := rng'; rows := (Array.range n).map (· + 5000 + it * 100)
    else if op == 5 then
      if rows.size > 3 then let a := rows[1]!; rows := (rows.set! 1 rows[rows.size - 2]!).set! (rows.size - 2) a
    else rows := #[]
    model := { model with rows }
    r.fire (← r.find "id" "go") "click" (",".intercalate (rows.toList.map toString))
    r.check (p.view model) s!"{mode.name} iteration {it}"
    -- click a row to exercise slot routing after reorders
    if rows.size > 0 && it % 3 == 0 then
      let k := rows[it % rows.size]!
      let d ← r.dom.get
      let li := d.reachable (← r.root) |>.find? fun h => (d.get h).tag == "li" && (d.get (d.get h).kids[0]!).text == s!"row {k}"
      match li with
      | some h => r.fire h "click"; model := { model with picked := some k }; r.check (p.view model) s!"pick {k} at {it}"
      | none => throw (IO.userError s!"row {k} not found")
  IO.println s!"  {mode.name} lists, {iters} random edits: ok"

/-! ## The planner's list model -/
def testPlanner (iters : Nat) : IO Unit := do
  let mut rng : Rng := ⟨42⟩
  for it in [0:iters] do
    let (rng', n) := rng.below 12; rng := rng'
    let (rng', m) := rng.below 12; rng := rng'
    let (rng', a) := shuffle rng ((Array.range n).map (· * 2)); rng := rng'
    let (rng', b) := shuffle rng ((Array.range m).map (· + 3)); rng := rng'
    let old := a.map toString; let new := b.map toString
    let p := Keyed.plan old new
    let got := Keyed.applyList old new p
    unless got == new.toList do throw (IO.userError s!"plan wrong at {it}: {old} -> {new}: {got}")
    -- minimality sanity: stable nodes never exceed reused ones
    unless (p.move.filter (!·)).size ≤ (p.src.filter Option.isSome).size do throw (IO.userError "stable > reused")
  IO.println s!"  planner list model, {iters} random pairs: ok"

/-! ## Lazy subtrees are skipped -/
def testLazy : IO Unit := do
  let calls ← IO.mkRef 0
  let _ := calls
  let p : Program Nat Unit := {
    init := fun _ => (0, .none), update := fun _ n => (n + 1, .none)
    view := fun n => el "div" #[] #[
      el "button" #[id "b", onClick ()] #[text (toString n)],
      lazy 7 fun _ => el "p" #[] #[text "static"]] }
  let r ← run p
  r.click "id" "b"; r.click "id" "b"
  r.check (p.view 2) "lazy"
  IO.println "  lazy: ok"

def testRender : IO Unit := do
  let v : Html Unit := el "p" #[cls "a\"b"] #[text "x<y", text "", text "z", el "input" #[value "v"] #[]]
  let got := v.render
  let want := "<p class=\"a&quot;b\">x&lt;y<!--|--><!--t--><!--|-->z<input value=\"v\"></p>"
  unless got == want do throw (IO.userError s!"render: {got}")
  IO.println "  render: ok"

/-! ## Subscriptions shared by several parts of an app -/
inductive SMsg | urlA (u : String) | urlB (u : String) | tickA | tickB
def subsProg : Program (Array String) SMsg where
  init _ := (#[], .none)
  update m log := (log.push (match m with
    | .urlA u => s!"A {u}" | .urlB u => s!"B {u}" | .tickA => "tickA" | .tickB => "tickB"), .none)
  view log := el "ul" #[] (log.map fun s => el "li" #[] #[text s])
  -- two components that both follow the URL and both tick every second
  subscriptions _ := .batch #[(Sub.urlChanges SMsg.urlA), .every 1000 .tickA,
    (Sub.batch #[.urlChanges .urlB, .every 1000 .tickB])]

def testSharedSubs : IO Unit := do
  let r ← run subsProg
  let d ← r.dom.get
  let cbOf (pfx : String) : IO UInt32 := do
    let ws := d.effects.filter (·.startsWith pfx)
    unless ws.size == 1 do throw (IO.userError s!"expected one {pfx} subscription, got {ws}")
    return (((ws[0]!.drop pfx.length).takeWhile Char.isDigit).toString.toNat!).toUInt32
  let url ← cbOf s!"op{Op.urlListen} "
  let tick ← cbOf "interval "
  r.inst.callback url true "/x"
  r.inst.callback tick true ""
  r.check (subsProg.view #["A /x", "B /x", "tickA", "tickB"]) "shared subscriptions"
  IO.println "  shared subscriptions: ok"

def testVoid : IO Unit := do
  for t in voidElements ++ ["div", "td", "tr", "a", "p", "span", "section", "textarea", "inputs", "b", ""] do
    unless isVoid t == voidElements.contains t do throw (IO.userError s!"isVoid {t}")
  IO.println "  void elements: ok"

/-! ## Encoding primitives (`pushU32`, `appendUtf8` and interning; compiled as inline C) -/

/-- The specification of `pushU32`, compiled as ordinary Lean (byte pushes). -/
def refPushU32 (b : ByteArray) (x : UInt32) : ByteArray :=
  b |>.push x.toUInt8 |>.push (x >>> 8).toUInt8 |>.push (x >>> 16).toUInt8 |>.push (x >>> 24).toUInt8

def encStrs : Array String := #["", "a", "col-md-1", "é", "😀 x", "naïve \x00 nul",
  String.ofList (List.replicate 70000 'z'), "remove glyphicon glyphicon-remove"]

/-- One random append (`k = 0`: a word, else a string), by the primitives or by the specification. -/
def encStep (spec : Bool) (a : ByteArray) (k x : Nat) : ByteArray :=
  if k == 0 then
    let w := (x * 2654435761 % 4294967296).toUInt32
    if spec then refPushU32 a w else pushU32 a w
  else
    let s := encStrs[x % encStrs.size]!
    if spec then a ++ s.toUTF8 else appendUtf8 a s

def testEncoding : IO Unit := do
  let fail (what : String) : IO Unit := throw (IO.userError s!"encoding: {what}")
  -- random appends to arrays of every starting capacity; every 7th step appends to a shared array
  -- (the old one stays alive and must not change)
  let mut rng : Rng := ⟨7⟩
  for cap in [0, 1, 3, 4, 5, 8, 4096] do
    let mut a := ByteArray.emptyWithCapacity cap
    let mut ref := ByteArray.emptyWithCapacity cap
    for step in [0:400] do
      let (r1, k) := rng.below 3; let (r2, x) := r1.below 0x7fffffff; rng := r2
      if step % 7 == 0 then
        let keep := a
        let before := keep.toList
        a := encStep false a k x
        if keep.toList != before then fail s!"shared array changed (cap {cap}, step {step})"
      else
        a := encStep false a k x
      ref := encStep true ref k x
      if a != ref then fail s!"cap {cap}, step {step}: {a.size} bytes, want {ref.size}"
  -- interning: ids from 1 in order of first use, one INTERN each, `intern` agrees with the writers
  let b : Buf := {}
  let b := b.setAttr 1 "class" "x" |>.setAttr 2 "class" "y" |>.createElement 3 .html "td"
  let (cid, b) := b.intern "class"
  let (tid, b) := b.intern "td"
  let (nid, b) := b.intern "new"
  let (nid2, b) := b.intern "new"
  unless (cid, tid, nid, nid2, b.nextName, b.names.size) == (1, 2, 3, 3, 4, 3) do
    fail s!"intern ids {(cid, tid, nid, nid2, b.nextName, b.names.size)}"
  match Wire.decode b.ops b.strs with
  | .error e => fail s!"wire: {e}"
  | .ok cmds =>
    let interns := cmds.filterMap fun c => match c.op with | .intern i s => some (i, s) | _ => none
    unless interns == #[(1, "class"), (2, "td"), (3, "new")] do fail s!"INTERN commands {interns}"
  IO.println "  encoding primitives: ok"

def main : IO UInt32 := do
  IO.println "leanui tests"
  testEncoding
  testRender
  testPlanner 20000
  testCounter
  testLazy
  testLists .keyed 400
  testLists .positional 400
  testLists .keyedLazy 400
  testSharedSubs
  testVoid
  IO.println "all passed"
  return 0
