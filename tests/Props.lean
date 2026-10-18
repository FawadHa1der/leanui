import LeanUI
import LeanUI.Testing.Harness
import LeanUI.Testing.Gen
import LeanUI.Testing.Spec
import LeanUI.Testing.Ssr
import LeanUI.Testing.Shrink
import LeanUI.Testing.Corpus
open LeanUI LeanUI.Testing

/-!
# leanui-props: randomized property tests and fuzzing for the LeanUI engine

    leanui-props [--quick | --long] [--seed N] [--only suite,suite] [--corpus DIR] [--verbose]

Suites (all deterministic from `--seed`):
  gen       generator coverage (depth, fan-out, keys, namespaces, lazies, listeners)
  diff      random views + random edit sequences through `DiffM`, every invariant after every step
  chaos     the same with duplicate attributes and listeners on one element
  app       end to end through `Testing.Harness`: `start`, events, `stepMsgs`, flush; routing by firing
  ssr       `Html.render` parsed back: node count, kinds, tags, texts, attributes; hazard lint
  hydrate   SSR → DOM model → `initState` with hydrate = true → invariants → random patches
  lazy      exact lazy-thunk counts in targeted scenarios
  mutation  drop single commands from real buffers: how many do the invariants catch?
  shrink    the shrinker against mutant engines (it must find tiny repros)
  scale     mount/patch timing for 1k..32k keyed rows, command counts, growth exponents
  corpus    (with --corpus DIR) write sessions for tests/browser/fuzz.mjs
-/

structure Opts where
  seed : UInt64 := 20261018
  /-- Case-count multiplier: 1 (--quick), 4 (default), 16 (--long). -/
  factor : Nat := 4
  only : List String := []
  corpus : Option String := none
  verbose : Bool := false

partial def parseArgs : List String → Opts → Opts
  | "--seed" :: s :: rest, o => parseArgs rest { o with seed := (s.toNat?.getD 0).toUInt64 }
  | "--quick" :: rest, o => parseArgs rest { o with factor := 1 }
  | "--long" :: rest, o => parseArgs rest { o with factor := 16 }
  | "--only" :: s :: rest, o => parseArgs rest { o with only := o.only ++ s.splitOn "," }
  | "--corpus" :: d :: rest, o => parseArgs rest { o with corpus := some d, only := o.only }
  | "--verbose" :: rest, o => parseArgs rest { o with verbose := true }
  | _ :: rest, o => parseArgs rest o
  | [], o => o

def nowMs : IO Float := do return (← IO.monoNanosNow).toFloat / 1000000

def fmt (x : Float) (digits : Nat := 2) : String :=
  let p := (10 : Float) ^ digits.toFloat
  let r := (x * p).round / p
  let s := toString r
  -- cut Lean's fixed six-digit format down to `digits`
  match s.splitOn "." with
  | [a, b] => if digits == 0 then a else a ++ "." ++ String.ofList (b.toList.take digits)
  | _ => s

/-- A failure message on one line, at most `n` characters. -/
def oneLine (s : String) (n : Nat := 110) : String :=
  let t := (s.splitOn "\n").map (·.trimAscii.toString) |> " ".intercalate
  if t.length > n then (t.take n).toString ++ "…" else t

def pad (s : String) (n : Nat) : String := s ++ String.ofList (List.replicate (n - s.length) ' ')
def lpad (s : String) (n : Nat) : String := String.ofList (List.replicate (n - s.length) ' ') ++ s

/-- One suite's result. -/
structure Outcome where
  name : String
  ok : Bool
  line : String

/-! ## Running a case: an initial view and an edit sequence -/

/-- Run a case through a session: mount (or hydrate) `t0`, then patch through every edit. -/
def runCase (c : Case) (hydrate := false) (mutant : Option (ByteArray → ByteArray → ByteArray) := none)
    (recording := false) : IO (Array String × Session) := do
  let cnt ← IO.mkRef 0
  let (s, f) ← if hydrate then do
      let (s, f, _) ← Session.hydrate cnt c.t0 recording
      pure ({ s with mutant }, f)
    else do
      let (s, f) ← Session.mount cnt c.t0 recording mutant
      pure (s, f ++ s.check "mount")
  if !f.isEmpty then return (f, s)
  let mut s := s
  let mut t := c.t0
  for h : k in [0:c.edits.size] do
    let e := c.edits[k]
    t := e.apply t
    let (s', f) ← s.step t s!"edit {k} ({e.name})"
    s := s'
    if !f.isEmpty then return (f, s)
  return (#[], s)

def genCase (cfg : Config) (seed : UInt64) (i : Nat) (nEdits : Nat) : Case :=
  let ((t0, edits), _) := (do let t ← genTree cfg; let es ← genEdits cfg t nEdits; pure (t, es)).run' (Rng.ofCase seed i)
  { t0, edits }

/-- Shrink a failing case and print the minimized repro. -/
def reportFailure (label : String) (c : Case) (fails : Array String) (hydrate := false) : IO Unit := do
  IO.println s!"  FAIL {label}: {fails[0]!}"
  let m ← minimize (fun c => do return !(← runCase c hydrate).1.isEmpty) c
  let (f, _) ← runCase m hydrate
  IO.println s!"  minimized from {c.edits.size} edits / {c.t0.size} nodes to {m.edits.size} edits / {m.t0.size} nodes:"
  IO.println s!"    {f[0]?.getD "(passes after shrinking?)"}"
  for l in (m.toLean.splitOn "\n") do IO.println s!"    {l}"

/-! ## gen: what the generators produce -/

def genSuite (o : Opts) : IO Outcome := do
  let n := 500 * o.factor
  let mut maxDepth := 0; let mut maxFan := 0; let mut nodes := 0; let mut maxNodes := 0
  let mut keyed := 0; let mut dupKeyed := 0; let mut lists := 0; let mut lazies := 0; let mut pinned := 0
  let mut svgs := 0; let mut maths := 0; let mut evs : Std.HashMap String Nat := {}; let mut props := 0
  let mut emptyTexts := 0; let mut edits : Std.HashMap String Nat := {}
  for i in [0:n] do
    let c := genCase {} o.seed i 20
    let t := c.t0
    maxDepth := max maxDepth t.depth; nodes := nodes + t.size; maxNodes := max maxNodes t.size
    lazies := lazies + t.lazies
    for e in c.edits do edits := edits.insert e.name (edits.getD e.name 0 + 1)
    for s in sites t do
      match s.node with
      | .elem ns _ attrs kids =>
        maxFan := max maxFan kids.size
        if ns == .svg then svgs := svgs + 1
        if ns == .mathml then maths := maths + 1
        if kids.size ≥ 2 then
          lists := lists + 1
          if kids.all (·.keyOld.isSome) then
            let ks := kids.map (·.keyOld.getD "")
            if uniqueKeysS (ks.map some) then keyed := keyed + 1 else dupKeyed := dupKeyed + 1
        for a in attrs do
          match a with
          | .on l => evs := evs.insert l.event (evs.getD l.event 0 + 1)
          | .prop .. => props := props + 1
          | _ => pure ()
      | .lazy (some _) _ => pinned := pinned + 1
      | .text "" => emptyTexts := emptyTexts + 1
      | _ => pure ()
  let evList := ", ".intercalate ((evs.toList.toArray.qsort (fun a b => a.1 < b.1)).toList.map fun (k, v) => s!"{k} {v}")
  let editList := ", ".intercalate ((edits.toList.toArray.qsort (fun a b => a.2 > b.2)).toList.map fun (k, v) => s!"{k} {v}")
  IO.println s!"  {n} trees: {nodes / n} nodes on average (max {maxNodes}), depth up to {maxDepth}, fan-out up to {maxFan}"
  IO.println s!"  child lists (≥2): {lists}, keyed {keyed}, keyed with a duplicate key {dupKeyed}; lazy nodes {lazies} ({pinned} pinned); SVG elements {svgs}, MathML {maths}; empty texts {emptyTexts}; properties {props}"
  IO.println s!"  listeners: {evList}"
  IO.println s!"  edits: {editList}"
  let ok := maxDepth ≥ 5 && maxFan ≥ 8 && keyed > 0 && dupKeyed > 0 && lazies > 0 && pinned > 0 && svgs > 0 && maths > 0 && evs.size ≥ 8 && edits.size ≥ 20
  return { name := "gen", ok, line := s!"{n} trees, coverage {if ok then "complete" else "INCOMPLETE"}" }

/-! ## diff / chaos: sessions under random edits -/

def diffSuite (o : Opts) (name : String) (cfg : Config) (cases edits : Nat) (hydrate := false) : IO Outcome := do
  let mut failed := 0; let mut steps := 0; let mut cmds := 0; let mut bytes := 0; let mut nodes := 0
  let mut firstFails : Array String := #[]
  for i in [0:cases] do
    let c := genCase cfg (o.seed + (if hydrate then 77 else 0)) i edits
    let (f, s) ← runCase c hydrate
    steps := steps + s.steps; cmds := cmds + s.commands; bytes := bytes + s.bytes; nodes := nodes + c.t0.size
    if !f.isEmpty then
      failed := failed + 1
      let key := (f[0]!.splitOn ": ").getLast!.take 40 |>.toString
      if failed ≤ 2 || (!firstFails.contains key && failed ≤ 6) then
        firstFails := firstFails.push key
        reportFailure s!"{name} case {i} (seed {o.seed})" c f hydrate
  let line := s!"{cases} cases, {steps} patches checked ({steps * 2} with idempotence), {cmds} commands / {bytes / 1024} KiB, {nodes / max cases 1} nodes per initial view; {failed} failing"
  return { name, ok := failed == 0, line }

/-! ## app: end to end through the harness -/

structure AppModel where
  idx : Nat := 0
  last : String := ""

def goHandler : Handler String := { payload := .value, decode := fun p => some ("goto:" ++ p) }

def appView (last : String) (tree : Html String) : Html String :=
  el "div" #[] #[el "button" #[.attr "id" "go", .on "click" goHandler] #[], el "pre" #[.attr "id" "last"] #[text last], tree]

def appProgram (c : IO.Ref Nat) (trees : Array T) : Program AppModel String where
  init _ := ({}, .none)
  update m s :=
    if m.startsWith "goto:" then ({ s with idx := ((m.drop 5).toString.toNat?).getD 0 }, .none)
    else ({ s with last := m }, .none)
  view s := appView s.last ((trees[s.idx]?.getD (.text "")).toHtml c)

/-- Every effective listener under `h`, with its DOM handle and slot. -/
partial def listenersOf (d : Dom) : T → UInt32 → Array (UInt32 × TListener × UInt32)
  | .lazy _ b, h => listenersOf d b h
  | .text _, _ => #[]
  | .elem _ _ attrs kids, h =>
    let dn := d.get h
    let here := (effListeners attrs).filterMap fun l =>
      (dn.listeners.find? (·.1 == l.event)).map fun (_, sl, _, _) => (h, l, sl)
    (kids.zip dn.kids).foldl (fun acc (k, dh) => acc ++ listenersOf d k dh) here

/-- Text nodes with the nearest enclosing click listener (where a click on the text lands). -/
partial def textTargets (d : Dom) (inh : Option TListener) : T → UInt32 → Array (UInt32 × Option TListener)
  | .lazy _ b, h => textTargets d inh b h
  | .text _, h => #[(h, inh)]
  | .elem _ _ attrs kids, h =>
    let inh := match (effListeners attrs).find? (·.event == "click") with | some l => some l | none => inh
    ((kids.zip (d.get h).kids).foldl (fun acc (k, dh) => acc ++ textTargets d inh k dh) #[])

def appCase (cfg : Config) (seed : UInt64) (i : Nat) (nEdits : Nat) : IO (Array String × Nat) := do
  let c := genCase cfg seed i nEdits
  let trees := c.views
  let cnt ← IO.mkRef 0
  let r ← Testing.run (appProgram cnt trees)
  let mut eff := ((mountS trees[0]!).run 0).1
  let mut last := ""
  let mut fired := 0
  let readLast : IO String := do
    let d ← r.dom.get
    let root ← r.root
    let pre := (d.get root).kids[1]!
    return (d.get ((d.get pre).kids[0]!)).text
  for h : step in [0:trees.size] do
    let t := trees[step]
    try
      if step > 0 then
        r.fire (← r.find "id" "go") "click" (toString step)
        eff := ((patchS eff t).run 0).1
      r.check (appView last eff.toHtml') s!"app step {step}"
      let d ← r.dom.get
      let treeRoot := (d.get (← r.root)).kids[2]!
      let got := strictDom d treeRoot
      if got != eff.canon then return (#[s!"app step {step}: strict DOM differs\n   got {got.take 300}\n  want {eff.canon.take 300}"], fired)
      -- every listener, through Instance.event, observed in the page itself
      for (hdl, l, sl) in listenersOf d eff treeRoot do
        for p in #["", "Enter", "v😀"] do
          r.inst.event sl p
          fired := fired + 1
          if let some m := l.decode p then last := m
          let shown ← readLast
          if shown != last then
            return (#[s!"app step {step}: slot {sl} ({l.event} on {hdl}) with {p.quote} shows {shown.quote}, expected {last.quote}"], fired)
          eff := ((patchS eff t).run 0).1
      -- clicks on texts bubble to the nearest click listener (Running.fire)
      let d ← r.dom.get
      for (hdl, target) in textTargets d none eff treeRoot do
        match target with
        | some l =>
          r.fire hdl "click"
          fired := fired + 1
          if let some m := l.decode "" then last := m
          let shown ← readLast
          if shown != last then return (#[s!"app step {step}: click on text {hdl} shows {shown.quote}, expected {last.quote}"], fired)
        | none =>
          let threw ← try r.fire hdl "click"; pure false catch _ => pure true
          if !threw then return (#[s!"app step {step}: click on text {hdl} found a listener, the view has none"], fired)
      r.check (appView last eff.toHtml') s!"app step {step} after events"
    catch e => return (#[e.toString], fired)
  return (#[], fired)

def appSuite (o : Opts) : IO Outcome := do
  let cases := 75 * o.factor
  let mut failed := 0; let mut fired := 0
  for i in [0:cases] do
    let (f, n) ← appCase {} (o.seed + 5) i 12
    fired := fired + n
    if !f.isEmpty then
      failed := failed + 1
      if failed ≤ 3 then IO.println s!"  FAIL app case {i}: {f[0]!}"
  return { name := "app", ok := failed == 0, line := s!"{cases} programs × 13 views, {fired} events fired and observed in the DOM; {failed} failing" }

/-! ## ssr: the render → parse round trip and the hazard lint -/

/-- A hazard message with tag names blanked out (`<p> inside <p>` → `<_> inside <_>`). -/
def hazardClass (h : String) : String := Id.run do
  let mut out := ""
  let mut inTag := false
  for c in h.toList do
    if c == '<' then inTag := true; out := out ++ "<_"
    else if c == '>' then inTag := false; out := out.push '>'
    else if !inTag then out := out.push c
  return (out.splitOn " (").head!

def ssrSuite (o : Opts) : IO Outcome := do
  let n := 750 * o.factor
  let mut clean := 0; let mut cleanFail := 0; let mut hazardous := 0; let mut diverged := 0
  let mut nodes := 0; let mut bytes := 0
  let mut classes : Std.HashMap String (Nat × Nat) := {}
  let mut examples : Std.HashMap String T := {}
  for i in [0:n] do
    let cfg : Config := if i % 4 == 2 then { hazards := true } else if i % 4 == 3 then Config.chaos else {}
    let ((t, _), _) := (do let t ← genTree cfg; pure (t, ())).run' (Rng.ofCase (o.seed + 11) i)
    let hs := Ssr.hazards t
    let rep := Ssr.roundTrip t
    nodes := nodes + t.size; bytes := bytes + rep.html.utf8ByteSize
    if hs.isEmpty then
      clean := clean + 1
      if !rep.failures.isEmpty then
        cleanFail := cleanFail + 1
        if cleanFail ≤ 3 then
          IO.println s!"  FAIL ssr tree {i}: {rep.failures[0]!}"
          let m ← shrinkTree (fun t => pure ((Ssr.hazards t).isEmpty && !(Ssr.roundTrip t).failures.isEmpty)) t (← IO.mkRef 3000)
          IO.println s!"    minimized: {m.toLean 4}\n    renders: {(Ssr.roundTrip m).html}\n    {(Ssr.roundTrip m).failures[0]?}"
    else
      hazardous := hazardous + 1
      let bad := !rep.failures.isEmpty
      if bad then diverged := diverged + 1
      let mut seen : Array String := #[]
      for h in hs do
        let cls := hazardClass h
        if seen.contains cls then continue
        seen := seen.push cls
        let (a, b) := classes.getD cls (0, 0)
        classes := classes.insert cls (a + 1, b + (if bad then 1 else 0))
        if bad && !examples.contains cls && hs.all (hazardClass · == cls) then examples := examples.insert cls t
  IO.println s!"  {clean} hazard-free trees round-trip exactly: {clean - cleanFail}/{clean} ({nodes / n} nodes, {bytes / n} bytes of HTML on average)"
  IO.println s!"  {hazardous} trees with hazards; the parser model rebuilds {hazardous - diverged} of them anyway, {diverged} diverge:"
  for (cls, (a, b)) in (classes.toList.toArray.qsort (fun x y => x.2.1 > y.2.1)).toList.take 14 do
    IO.println s!"    {pad cls 50} {lpad (toString a) 5} trees, {lpad (toString b) 5} diverge in the model"
  -- one minimized example per class that the model shows diverging
  if o.verbose then
    for (cls, t) in examples.toList do
      let only (t : T) : Bool := let hs := Ssr.hazards t; !hs.isEmpty && hs.all (hazardClass · == cls)
      let m ← shrinkTree (fun t => pure (only t && !(Ssr.roundTrip t).failures.isEmpty)) t (← IO.mkRef 2000)
      IO.println s!"    e.g. {cls}: {(Ssr.roundTrip m).html}  →  {(Ssr.roundTrip m).failures[0]?.getD ""}"
  return { name := "ssr", ok := cleanFail == 0,
           line := s!"{n} trees rendered and parsed back; {clean - cleanFail}/{clean} hazard-free exact, {diverged}/{hazardous} hazardous diverge (lint sound: {cleanFail == 0})" }

/-! ## lazy: exact thunk counts -/

def lazySuite (_ : Opts) : IO Outcome := do
  let mut fails : Array String := #[]
  let mut notes : Array String := #[]
  let cnt ← IO.mkRef 0
  let ids := (Array.range 200)
  -- 1. same view: nothing forced, nothing sent
  let (s, f) ← Session.mount cnt (lazyRows ids)
  fails := fails ++ f
  let before ← cnt.get
  let (s, f) ← s.step (lazyRows ids) "same view"
  fails := fails ++ f
  if (← cnt.get) != before then fails := fails.push "same view forced thunks"
  -- 2. one row changes: one thunk, one setText
  let b1 ← cnt.get; let c1 := s.commands
  let (s, f) ← s.step (lazyRows ids fun i => if i == 57 then "changed" else s!"row {i}") "one row"
  fails := fails ++ f
  let r := (← cnt.get) - b1
  if r != 1 then fails := fails.push s!"one changed lazy row forced {r} thunks"
  notes := notes.push s!"one changed row: {r} thunk, {s.commands - c1} command(s)"
  -- 3. keyed lazy rows, reversed: keys are invisible through `lazy`, so the diff is positional
  let b2 ← cnt.get; let c2 := s.commands
  let (s, f) ← s.step (lazyRows ids.reverse) "reverse lazy rows"
  fails := fails ++ f
  let lazyRev := ((← cnt.get) - b2, s.commands - c2)
  let cnt2 ← IO.mkRef 0
  let (p, _) ← Session.mount cnt2 (rows ids)
  let (p2, _) ← p.step (rows ids.reverse) "reverse rows"
  notes := notes.push s!"reverse 200 keyed rows: plain {p2.commands - p.commands} commands; lazy-wrapped {lazyRev.1} thunks and {lazyRev.2} commands (keyed reconciliation lost)"
  let _ := s
  -- 4. stale probe: pinned deps keep the old content and never run the thunk
  let cnt3 ← IO.mkRef 0
  let probe (label : String) : T := .elem .html "div" #[] #[.lazy (some 42) (.elem .html "p" #[] #[.text label])]
  let (q, _) ← Session.mount cnt3 (probe "old")
  let b3 ← cnt3.get
  let (q, f) ← q.step (probe "new") "stale probe"
  fails := fails ++ f
  if (← cnt3.get) != b3 then fails := fails.push "a pinned lazy node was forced"
  if !(strictDom q.dom q.root).contains "3:old" then fails := fails.push "a pinned lazy node changed the DOM"
  -- 5. hydration and server rendering force thunks how often?
  let cnt4 ← IO.mkRef 0
  let (_, f, extra) ← Session.hydrate cnt4 (lazyRows (Array.range 100))
  fails := fails ++ f
  notes := notes.push s!"hydrating 100 lazy rows forces {100 + extra} thunks ({extra} more than mounting)"
  let cnt5 ← IO.mkRef 0
  let _ ← IO.lazyPure fun _ => ((lazyRows (Array.range 100)).toHtml cnt5).render
  notes := notes.push s!"Html.render of 100 lazy rows forces {← cnt5.get} thunks"
  for nt in notes do IO.println s!"  {nt}"
  for fl in fails do IO.println s!"  FAIL {fl}"
  return { name := "lazy", ok := fails.isEmpty, line := s!"{notes.size} measurements, {fails.size} failing" }

/-! ## mutation: do the invariants notice a missing command? -/

def mutationSuite (o : Opts) : IO Outcome := do
  let cases := 20 * o.factor
  let mut total := 0; let mut killed := 0
  let mut survivors : Std.HashMap String Nat := {}
  let mut byKind : Std.HashMap String (Nat × Nat) := {}
  for i in [0:cases] do
    let c := genCase {} (o.seed + 23) i 8
    let cnt ← IO.mkRef 0
    let (s0, _) ← Session.mount cnt c.t0
    let mut s := s0
    let mut t := c.t0
    for e in c.edits do
      t := e.apply t
      let (node, diff) := (patch 0 s.node (t.toHtml' )).run s.diff
      let (eff, _) := (patchS s.eff t).run 0
      let b := diff.buf
      match Wire.decode b.ops b.strs with
      | .error _ => pure ()
      | .ok cmds =>
        for j in [0:cmds.size] do
          let k := cmds[j]!.op.name
          let mutated := Wire.reencode b.ops cmds (· != j)
          let m : Session := { s with node, eff, diff := { diff with buf := { b with ops := mutated } } }
          let m := m.flush "mutant"
          let caught := !(m.check "mutant").isEmpty
          total := total + 1
          if caught then killed := killed + 1 else survivors := survivors.insert k (survivors.getD k 0 + 1)
          let (a, z) := byKind.getD k (0, 0)
          byKind := byKind.insert k (a + 1, z + (if caught then 1 else 0))
      s := { s with node, eff, diff }.flush "step"
  let rows := (byKind.toList.toArray.qsort (fun a b => a.2.1 > b.2.1)).toList.map fun (k, (a, z)) => s!"{k} {z}/{a}"
  IO.println s!"  killed by command kind: {", ".intercalate rows}"
  let surv := survivors.toList.map fun (k, v) => s!"{k} ×{v}"
  if !surv.isEmpty then IO.println s!"  survivors (commands whose loss nothing observes): {", ".intercalate surv}"
  return { name := "mutation", ok := killed == total,
           line := s!"{total} single-command deletions from real buffers, {killed} caught ({fmt (100 * killed.toFloat / (max total 1).toFloat) 1}%)" }

/-! ## shrink: the shrinker against mutant engines -/

def dropCommands (p : Wire.WOp → Bool) (ops strs : ByteArray) : ByteArray :=
  match Wire.decode ops strs with
  | .ok cmds => Wire.reencode ops cmds fun i => !p cmds[i]!.op
  | .error _ => ops

/-- The last command matching `p`. -/
def dropLast (p : Wire.WOp → Bool) (ops strs : ByteArray) : ByteArray :=
  match Wire.decode ops strs with
  | .ok cmds =>
    match (List.range cmds.size).reverse.find? (fun i => p cmds[i]!.op) with
    | some j => Wire.reencode ops cmds (· != j)
    | none => ops
  | .error _ => ops

def shrinkSuite (o : Opts) : IO Outcome := do
  let mutants : Array (String × (ByteArray → ByteArray → ByteArray)) := #[
    ("drops removeListener", dropCommands fun | .removeListener .. => true | _ => false),
    ("drops the last move (insertBefore)", dropLast fun | .insertBefore .. => true | _ => false),
    ("drops removeAttr", dropCommands fun | .removeAttr .. => true | _ => false),
    ("drops setText", dropCommands fun | .setText .. => true | _ => false)]
  let mut ok := true
  let mut lines := #[]
  for (name, f) in mutants do
    let mut found : Option Case := none
    for i in [0:400] do
      let c := genCase {} (o.seed + 31) i 20
      let (fl, _) ← runCase c (mutant := some f)
      if !fl.isEmpty then found := some c; break
    match found with
    | none => ok := false; lines := lines.push s!"{name}: no failing case found"
    | some c =>
      let t0 ← nowMs
      let m ← minimize (fun c => do return !(← runCase c (mutant := some f)).1.isEmpty) c
      let t1 ← nowMs
      let (fl, _) ← runCase m (mutant := some f)
      lines := lines.push s!"{name}: {c.edits.size} edits/{c.t0.size} nodes → {m.edits.size} edit(s)/{m.t0.size} nodes in {fmt (t1 - t0) 0} ms\n      {oneLine (fl[0]?.getD "") 120}"
      if m.edits.size > 2 || m.t0.size > 10 then ok := false
      if o.verbose then IO.println m.toLean
  for l in lines do IO.println s!"  {l}"
  return { name := "shrink", ok, line := s!"{mutants.size} mutant engines caught and minimized" }

/-! ## scale: timing on keyed rows -/

def rowH (id : Nat) (label : String) (sel : Bool) : Html String :=
  el "li" #[.key s!"r{id}", Attr.cls (if sel then "danger" else "row"), .on "click" { decode := fun _ => some s!"select {id}" }]
    #[text label, el "b" #[] #[text (toString id)]]

def table (ids : Array Nat) (label : Nat → String := fun i => s!"row {i}") (sel : Option Nat := none) : Html String :=
  el "ul" #[Attr.id "rows"] (ids.map fun i => rowH i (label i) (sel == some i))

def median (xs : Array Float) : Float := let s := xs.qsort (· < ·); s[s.size / 2]!

structure Measure where
  engine : Float
  model : Float
  commands : Nat
  bytes : Nat
  moves : Nat
  creates : Nat
  frees : Nat

/-- Mount `before` (untimed), then time `patch` to `after` (median of `runs` fresh states).
`before = none` times the mount itself. -/
def measureRows (before : Option (Html String)) (after : Html String) (runs : Nat) (model := true) : IO Measure := do
  let mut ts := #[]; let mut ms := #[]
  let mut cmds := 0; let mut bytes := 0; let mut moves := 0; let mut creates := 0; let mut frees := 0
  for k in [0:runs] do
    let (n0, st0, dom0) := match before with
      | some v =>
        let (n, st) := (do let n ← mount v; emit (·.mount "#app" n.handle); pure n).run ({} : DiffState String)
        (some n, { st with buf := st.buf.reset }, ({} : Dom).apply st.buf.ops st.buf.strs)
      | none => (none, ({} : DiffState String), ({} : Dom))
    let t0 ← IO.monoNanosNow
    let st ← IO.lazyPure fun _ => match n0 with
      | some n => ((patch 0 n after).run st0).2
      | none => ((do let n ← mount after; emit (·.mount "#app" n.handle); pure n).run st0).2
    let t1 ← IO.monoNanosNow
    ts := ts.push ((t1 - t0).toFloat / 1000000)
    let b := st.buf
    if model then
      let t2 ← IO.monoNanosNow
      let d ← IO.lazyPure fun _ => dom0.apply b.ops b.strs
      let t3 ← IO.monoNanosNow
      if d.errors.size > 0 then IO.println s!"  model errors: {d.errors[0]!}"
      ms := ms.push ((t3 - t2).toFloat / 1000000)
    if k == 0 then
      bytes := b.ops.size + b.strs.size
      if let .ok cs := Wire.decode b.ops b.strs then
        cmds := cs.size
        for c in cs do
          match c.op with
          | .insertBefore .. => moves := moves + 1
          | .appendChild p _ => if p == 1 && creates == 0 then moves := moves + 1
          | .createElement .. | .createText .. => creates := creates + 1
          | .free _ => frees := frees + 1
          | _ => pure ()
  return { engine := median ts, model := if ms.isEmpty then 0 else median ms, commands := cmds, bytes, moves, creates, frees }

def lisLen (xs : Array Nat) : Nat := (Keyed.lis xs).size

def scaleSuite (o : Opts) : IO Outcome := do
  let mut fails : Array String := #[]
  let runsFor (n : Nat) := if n ≤ 2000 then 7 else if n ≤ 10000 then 5 else 3
  IO.println s!"  {pad "scenario" 26} {lpad "rows" 6} {lpad "engine ms" 10} {lpad "ns/row" 8} {lpad "model ms" 9} {lpad "commands" 9} {lpad "KiB" 7}"
  let mut results : Array (String × Nat × Measure) := #[]
  for n in #[1000, 10000] do
    let ids := Array.range n
    let base := table ids
    let ((sh, _)) := (shuffleArr ids).run' (Rng.ofCase o.seed n)
    let scenarios : Array (String × Option (Html String) × Html String) := #[
      ("create", none, base),
      ("re-render, no change", some base, table ids),
      ("update every 10th row", some base, table ids fun i => if i % 10 == 0 then s!"row {i} !!!" else s!"row {i}"),
      ("select a row", some base, table ids (sel := some (n / 2))),
      ("swap rows 1 and n-2", some base, table ((ids.set! 1 (n - 2)).set! (n - 2) 1)),
      ("remove one row", some base, table (ids.eraseIdxIfInBounds (n / 2))),
      ("append 1000 rows", some base, table (Array.range (n + 1000))),
      ("replace all rows", some base, table (ids.map (· + n))),
      ("reverse", some base, table ids.reverse),
      ("shuffle", some base, table sh),
      ("clear", some base, table #[])]
    for (name, b, a) in scenarios do
      let m ← measureRows b a (runsFor n)
      results := results.push (name, n, m)
      IO.println s!"  {pad name 26} {lpad (toString n) 6} {lpad (fmt m.engine 3) 10} {lpad (fmt (m.engine * 1000000 / n.toFloat) 0) 8} {lpad (fmt m.model 2) 9} {lpad (toString m.commands) 9} {lpad (toString (m.bytes / 1024)) 7}"
      -- exact command counts the diff must achieve
      let expect : Option Nat := match name with
        | "re-render, no change" => some 0
        | "update every 10th row" => some (n / 10)
        | "select a row" => some 1
        | "remove one row" => some 5
        | "append 1000 rows" => some 10000
        | _ => none
      if let some e := expect then
        if m.commands != e then fails := fails.push s!"{name} ({n} rows): {m.commands} commands, expected {e}"
      if name == "swap rows 1 and n-2" && (m.moves != 2 || m.creates != 0) then
        fails := fails.push s!"swap ({n} rows): {m.moves} moves, {m.creates} creates (expected 2, 0)"
      if name == "reverse" && (m.moves != n - 1 || m.creates != 0) then
        fails := fails.push s!"reverse ({n} rows): {m.moves} moves (expected {n - 1})"
      if name == "shuffle" && m.moves != n - lisLen sh then
        fails := fails.push s!"shuffle ({n} rows): {m.moves} moves, the minimum is {n - lisLen sh}"
  -- growth: time at 2k..32k rows; the exponent of the fit should stay near 1
  IO.println "  growth (engine ms at 2k / 4k / 8k / 16k / 32k rows → exponent):"
  let mut worst := 0.0
  for (name, mk) in (#[
      ("create", fun ids => (none, table ids)),
      ("re-render, no change", fun ids => (some (table ids), table ids)),
      ("reverse", fun ids => (some (table ids), table ids.reverse)),
      ("update every 10th row", fun ids => (some (table ids), table ids fun i => if i % 10 == 0 then "x" else s!"row {i}")),
      ("clear", fun ids => (some (table ids), table #[])),
      ("replace all rows", fun ids => (some (table ids), table (ids.map (· + 100000))))] :
      Array (String × (Array Nat → Option (Html String) × Html String))) do
    let mut pts : Array (Nat × Float) := #[]
    for n in #[2000, 4000, 8000, 16000, 32000] do
      let (b, a) := mk (Array.range n)
      let m ← measureRows b a (if n ≤ 8000 then 5 else 3) (model := false)
      pts := pts.push (n, m.engine)
    let (n0, t0) := pts[0]!; let (n1, t1) := pts.back!
    let slope := Float.log (t1 / t0) / Float.log (n1.toFloat / n0.toFloat)
    worst := max worst slope
    IO.println s!"    {pad name 24} {" / ".intercalate (pts.toList.map fun (_, t) => fmt t 2)}  → n^{fmt slope 2}{if slope > 1.3 then "  SUPER-LINEAR" else ""}"
    if slope > 1.3 then fails := fails.push s!"{name} grows like n^{fmt slope 2}"
  -- server rendering and hydration at 10k rows
  let big := rows (Array.range 10000)
  let bigH := big.toHtml'
  let t0 ← nowMs
  let html ← IO.lazyPure fun _ => bigH.render
  let t1 ← nowMs
  let parsed ← IO.lazyPure fun _ => Ssr.parse html
  let t2 ← nowMs
  let st ← IO.lazyPure fun _ => initState ({ init := fun _ => ((), .none), update := fun _ m => (m, .none), view := fun _ => bigH } : Program Unit String) "" "#app" true
  let t3 ← nowMs
  let nParsed := match parsed with | .ok ns => (Ssr.claims 0 "" none #[] ns).size | .error _ => 0
  IO.println s!"  10k rows SSR: render {fmt (t1 - t0) 1} ms ({html.utf8ByteSize / 1024} KiB), parse (test model) {fmt (t2 - t1) 1} ms ({nParsed} nodes), hydrate initState {fmt (t3 - t2) 1} ms ({st.diff.buf.ops.size / 4} words)"
  for f in fails do IO.println s!"  FAIL {f}"
  return { name := "scale", ok := fails.isEmpty, line := s!"{results.size} scenarios at 1k/10k rows + growth sweep to 32k (worst exponent {fmt worst 2}); {fails.size} failing" }

/-! ## corpus: sessions for the browser -/

def corpusSuite (o : Opts) (dir : String) : IO Outcome := do
  IO.FS.createDirAll dir
  let mut lines : Array String := #[]
  let mut steps := 0
  for i in [0:60 * o.factor] do
    let hyd := i % 4 == 3
    let cfg : Config := if i % 5 == 4 then Config.chaos else {}
    let c := genCase cfg (o.seed + 41) i 10
    let cnt ← IO.mkRef 0
    let start ← if hyd then do let (s, f, _) ← Session.hydrate cnt c.t0 true; pure (s, f)
      else Session.mount cnt c.t0 true
    let (s0, f0) := start
    if !f0.isEmpty then continue
    let mut s := s0
    let mut entries := #[Corpus.stepJson s.dom s.log.back!]
    let mut t := c.t0
    for e in c.edits do
      t := e.apply t
      let n := s.log.size
      let (s', _) ← s.step t "corpus"
      s := s'
      if s.log.size > n then entries := entries.push (Corpus.stepJson s.dom s.log.back!)
    steps := steps + entries.size
    let html := if hyd then Corpus.json (Ssr.roundTrip c.t0).html else "null"
    lines := lines.push s!"\{\"case\":{i},\"chaos\":{i % 5 == 4},\"html\":{html},\"steps\":{Corpus.jsonArr entries}}"
  -- parse checks: the browser's HTML parser against the parser model and the hazard lint
  let mut parses := 0
  for i in [0:400 * o.factor] do
    let cfg : Config := if i % 3 == 0 then { hazards := true } else if i % 3 == 1 then Config.chaos else {}
    let ((t, _), _) := (do let t ← genTree cfg; pure (t, ())).run' (Rng.ofCase (o.seed + 43) i)
    let html := t.toHtml'.render
    let model := match Ssr.modelCanon html with | some c => Corpus.json c | none => "null"
    let hz := Corpus.jsonArr ((Ssr.hazards t).map Corpus.json)
    lines := lines.push s!"\{\"case\":{i},\"parse\":{Corpus.json html},\"view\":{Corpus.json (Ssr.ssrCanon t)},\"model\":{model},\"hazards\":{hz}}"
    parses := parses + 1
  IO.FS.writeFile (dir ++ "/corpus.jsonl") ("\n".intercalate lines.toList ++ "\n")
  return { name := "corpus", ok := true, line := s!"{lines.size - parses} sessions, {steps} buffers, {parses} parse checks → {dir}/corpus.jsonl" }

/-! ## main -/

def main (args : List String) : IO UInt32 := do
  let o := parseArgs args {}
  let want (s : String) := o.only.isEmpty || o.only.contains s
  IO.println s!"leanui-props (seed {o.seed}, factor {o.factor})"
  let suites : Array (String × IO Outcome) := #[
    ("gen", genSuite o),
    ("diff", diffSuite o "diff" {} (250 * o.factor) 25),
    ("chaos", diffSuite o "chaos" Config.chaos (100 * o.factor) 25),
    ("app", appSuite o),
    ("ssr", ssrSuite o),
    ("hydrate", diffSuite o "hydrate" {} (100 * o.factor) 15 (hydrate := true)),
    ("lazy", lazySuite o),
    ("mutation", mutationSuite o),
    ("shrink", shrinkSuite o),
    ("scale", scaleSuite o)]
  let mut outcomes := #[]
  let total0 ← nowMs
  for (name, act) in suites do
    if !want name then continue
    IO.println s!"[{name}]"
    let t0 ← nowMs
    let r ← act
    let t1 ← nowMs
    IO.println s!"  {if r.ok then "ok" else "FAILED"}: {r.line} ({fmt ((t1 - t0) / 1000) 2} s)"
    outcomes := outcomes.push r
  if let some dir := o.corpus then
    IO.println "[corpus]"
    let r ← corpusSuite o dir
    IO.println s!"  {r.line}"
  let failed := outcomes.filter (!·.ok)
  IO.println s!"{outcomes.size - failed.size}/{outcomes.size} suites passed in {fmt (((← nowMs) - total0) / 1000) 1} s{if failed.isEmpty then "" else ": FAILED " ++ ", ".intercalate (failed.toList.map (·.name))}"
  return if failed.isEmpty then 0 else 1
