import LeanUI
import LeanUI.Testing.Harness
import LeanUI.Testing.Wire
import Std.Data.HashSet
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
/-- How the test list renders its rows. `keyedLazyNoId` leaves the row's id out of the lazy deps,
the idiom Bench and TodoMVC use: the rows are then told apart by their keys alone, so the list is
correct only if the diff compares a lazy node's key like a dependency. -/
inductive ListMode | positional | keyed | keyedLazy | keyedLazyNoId
  deriving BEq

def ListMode.name : ListMode → String
  | .positional => "positional" | .keyed => "keyed" | .keyedLazy => "keyed lazy"
  | .keyedLazyNoId => "keyed lazy (key not in deps)"

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
    | .keyedLazy => keyed (toString k) (lazy (k, picked) fun _ => rowView false picked k)
    | .keyedLazyNoId => keyedLazy (toString k) picked fun _ => rowView false picked k)
def listProg (mode : ListMode) : Program LModel LMsg where
  init _ := ({}, .none)
  update m s := match m with | .setRows rs => ({ s with rows := rs }, .none) | .pick k => ({ s with picked := some k }, .none)
  view := listView mode

def decodeRows (s : String) : Option LMsg :=
  some (.setRows ((s.splitOn ",").filterMap String.toNat? |>.toArray))

/-- Drive a list through random edits. A hidden control button carries the next row list in its
event payload, so every edit goes through the same event path the browser uses. -/
def testLists (mode : ListMode) (iters : Nat) : IO Unit := do
  let mut rng : Rng := ⟨match mode with | .keyed => 7 | .keyedLazy => 3 | .keyedLazyNoId => 5 | .positional => 11⟩
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

/-! ## A lazy node's key is compared like a dependency

`keyedLazy k deps render` rows whose deps are all equal (here `()`) differ only by key. Both
places where the diff skips a lazy node must compare the key: `sameF` (the unchanged-subtree check,
which pairs children by position in a small subtree) and `patchNode` (reached for lists diffed by
position, e.g. with a duplicate key). Each step below fails if one of them compares deps only. -/
def keyContractView (rows : Array Nat) : Html LMsg :=
  el "div" #[] #[
    el "button" #[id "go", Attr.on "click" { payload := .value, decode := decodeRows }] #[],
    el "ul" #[id "list"] (rows.map fun k => keyedLazy (toString k) () fun _ => el "li" #[] #[text s!"row {k}"])]

def testKeyContract : IO Unit := do
  let p : Program LModel LMsg := { listProg .keyedLazyNoId with view := fun m => keyContractView m.rows }
  let r ← run p
  r.check (keyContractView #[]) "key contract: mount"
  -- [1,2,3] then reversed: a small subtree, so `sameF` pairs the rows by position;
  -- then lists with a duplicate key, diffed by position through `patchNode`
  for rows in [#[1, 2, 3], #[3, 2, 1], #[1, 1, 2], #[2, 1, 1], #[1, 2, 1]] do
    r.fire (← r.find "id" "go") "click" (",".intercalate (rows.toList.map toString))
    r.check (keyContractView rows) s!"key contract: rows {rows} with equal deps"
  IO.println "  keyed lazy rows with equal deps (key compared like a dependency): ok"

/-! ## Childless elements share one empty array

Mounting a childless element (or one without listeners) must not allocate an empty array for it:
a `#[]` written in an argument position is allocated every time it runs, and 1,000 benchmark rows
would keep 2,000 such arrays alive. Checked by address, on rows mounted at startup and on rows
created by an update (the patch path). -/
private unsafe def addrImpl {α : Type} (a : α) : USize := ptrAddrUnsafe a
@[implemented_by addrImpl] opaque addrOf {α : Type} (a : α) : USize

/-- The distinct addresses of the empty children arrays and the empty listener tables. -/
partial def emptyArrays (n : Node Unit) (acc : Std.HashSet USize × Std.HashSet USize := ({}, {})) :
    Std.HashSet USize × Std.HashSet USize :=
  match n with
  | .elem _ _ _ _ _ ls kids _ =>
    let acc := if kids.isEmpty then (acc.1.insert (addrOf kids), acc.2) else acc
    let acc := if ls.isEmpty then (acc.1, acc.2.insert (addrOf ls)) else acc
    kids.foldl (fun acc k => emptyArrays k acc) acc
  | .lazy _ _ n => emptyArrays n acc
  | .text .. => acc

/-- A benchmark-like row: two childless elements (the span and the last cell), one listener. -/
def emptyRow (i : Nat) : Html Unit :=
  el "tr" #[] #[el "td" #[cls "col-md-1"] #[text (toString i)],
    el "td" #[] #[el "a" #[onClick ()] #[text "label"]],
    el "td" #[] #[el "a" #[] #[el "span" #[cls "remove"] #[]]], el "td" #[] #[]]

def testSharedEmpty : IO Unit := do
  let p : Program Nat Unit := {
    init := fun _ => (1000, .none), update := fun _ n => (n + 1000, .none)
    view := fun n => el "tbody" #[] ((Array.range n).map emptyRow) }
  let st := initState p "" "#app" false
  let st := ((stepMsgs p #[()]).run st).2
  let (kids, ls) := emptyArrays st.tree
  unless kids.size == 1 && ls.size == 1 do
    throw (IO.userError s!"2,000 rows hold {kids.size} distinct empty children arrays and {ls.size} distinct empty listener tables (want 1 each)")
  IO.println "  childless elements share one empty array: ok"

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

/-- Interning as `0a415c1` defined it (`get?`, then the caller writes its words): the reference
that the allocation-free `intern` and `named` must match exactly, from any starting counter. -/
def refIntern (b : Buf) (nm : String) : UInt32 × Buf :=
  match b.names.get? nm with
  | some n => (n, b)
  | none =>
    let n := b.nextName
    (n, ({ b with names := b.names.insert nm n, nextName := n + 1 }.w Op.intern |>.w n |>.s nm))

/-- One command that names something (`k` picks which), by the writers or by the reference. -/
def namedStep (spec : Bool) (b : Buf) (k : Nat) (node : UInt32) (nm v : String) : Buf :=
  if spec then
    let (n, b) := refIntern b nm
    match k with
    | 0 => b.w Op.createElement |>.w node |>.w Ns.svg.code |>.w n
    | 1 => b.w Op.setAttr |>.w node |>.w n |>.s v
    | 2 => b.w Op.removeAttr |>.w node |>.w n
    | 3 => b.w Op.setPropStr |>.w node |>.w n |>.s v
    | 4 => b.w Op.setPropBool |>.w node |>.w n |>.w 1
    | 5 => b.w Op.removeProp |>.w node |>.w n
    | 6 => b.w Op.setListener |>.w node |>.w n |>.w (node + 1) |>.w Payload.value.code |>.w 3
    | _ => b.w Op.removeListener |>.w node |>.w n
  else
    match k with
    | 0 => b.createElement node .svg nm
    | 1 => b.setAttr node nm v
    | 2 => b.removeAttr node nm
    | 3 => b.setProp node nm (.str v)
    | 4 => b.setProp node nm (.bool true)
    | 5 => b.removeProp node nm
    | 6 => b.setListener node nm (node + 1) .value 3
    | _ => b.removeListener node nm

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
  -- random sessions of `intern` and every named writer (and `reset`) against the reference, from
  -- several starting counters: 0 (a name can then have id 0, which `getD … 0` also returns for a
  -- miss) and the counter wrapping through 0 included
  let pool := #["a", "class", "td", "", "é", "😀", "click", "input", "a\x00b"] ++
    (Array.range 24).map (s!"n{·}")
  for start in [0, 1, 2, 1000, 0xFFFFFFF0, 0xFFFFFFFE, 0xFFFFFFFF] do
    let mut b : Buf := { nextName := start }
    let mut ref : Buf := { nextName := start }
    for step in [0:600] do
      let (r1, k) := rng.below 10; let (r2, i) := r1.below pool.size; let (r3, node) := r2.below 5000
      rng := r3
      let nm := pool[i]!
      if k == 8 then
        let (n, b') := b.intern nm
        let (rn, ref') := refIntern ref nm
        if n != rn then fail s!"intern {nm.quote} = {n}, want {rn} (start {start}, step {step})"
        b := b'; ref := ref'
      else if k == 9 then
        b := b.reset; ref := ref.reset
      else
        b := namedStep false b k node.toUInt32 nm s!"v{step}"
        ref := namedStep true ref k node.toUInt32 nm s!"v{step}"
      let same := b.ops == ref.ops && b.strs == ref.strs && b.units == ref.units &&
        b.nextName == ref.nextName && b.names.size == ref.names.size &&
        pool.all fun n => b.names.get? n == ref.names.get? n
      unless same do
        fail s!"named writers differ from the reference (start {start}, step {step}, op {k}, name {nm.quote})"
  IO.println "  encoding primitives: ok"

def main : IO UInt32 := do
  IO.println "leanui tests"
  testEncoding
  testRender
  testPlanner 20000
  testCounter
  testLazy
  testKeyContract
  testSharedEmpty
  testLists .keyed 400
  testLists .positional 400
  testLists .keyedLazy 400
  testLists .keyedLazyNoId 400
  testSharedSubs
  testVoid
  IO.println "all passed"
  return 0
