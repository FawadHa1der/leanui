module
public import LeanUI
public import LeanUI.Router
public import LeanUI.Json
public import Roster.Solver
meta import LeanUI.Json.Derive
meta import LeanUI.Syntax
/-!
# Roster: can we staff this?

The app of the Roster demo (`roster/README.md`). A grid of people × shifts: a click on a cell says
whether that person can do that shift, −/+ changes how many people a shift needs, and the presets
load a sample problem or a random one. "Can we staff this?" asks the solver (`Roster.Solver`),
which is not trusted: with the "Lying solver" switch on it answers wrongly on purpose, with the
next lie in turn each time.

What the app shows is decided by the checker, not by the solver: `judge` keeps an answer only if
`Problem.checkAnswer` accepts it, and every edit of the problem clears the result. So a roster in
the result is valid for the problem, and a set of shifts there proves that no roster exists
(`steps_inv` in `examples/RosterProofs.lean`); the view draws them as they are. The "What is
proved" panel says which kind of guarantee each part of this is, and what it trusts.

A roster on screen can be notarized: `POST /roster/notarize` asks `leanui-roster`
(`examples/RosterServer.lean`) to prove it valid with Lean's kernel. The receipt it exports opens
in the verify page (`roster/verify/`), which checks it again with an independent kernel.
-/
@[expose] public section
open LeanUI Attr
namespace Roster

/-! ## Model -/

/-- What the results panel shows. -/
inductive Result where
  | none
  /-- An accepted roster. -/
  | staffed (r : Roster)
  /-- An accepted Hall violator: no roster exists. -/
  | impossible (T : List Nat)
  /-- An answer the checker rejected: the lie told (empty if none), and why it was rejected. -/
  | rejected (lie : String) (why : String)

inductive Notary where
  | idle
  | working
  /-- The receipt's URL, and how long the server took. -/
  | done (url : String) (ms : Nat)
  | failed (why : String)

structure Model where
  problem : Problem
  result : Result := .none
  /-- The lying solver is on; it has told `lies` lies, so the next is `Lie.all[lies % 4]`. -/
  liar : Bool := false
  lies : Nat := 0
  notary : Notary := .idle
  /-- Notarizations asked for: an answer counts only if it is for the latest. -/
  requests : Nat := 0
  /-- Random problems drawn: the seed of the next. -/
  draws : Nat := 0

inductive Msg where
  | toggle (i s : Nat)
  | more (s : Nat)
  | fewer (s : Nat)
  | preset (p : Problem)
  | random
  | liar (b : Bool)
  | ask
  | notarize
  | notarized (request : Nat) (res : Response)

/-! ## Editing the problem -/

/-- Flip whether person `i` can do shift `s`. -/
def Problem.toggle (p : Problem) (i s : Nat) : Problem :=
  { p with avail := p.avail.modify i (·.modify s (!·)) }

def Problem.setNeed (p : Problem) (s n : Nat) : Problem := { p with need := p.need.set s n }

/-- A different problem: the result, and any receipt, were about the old one. -/
def Model.edit (m : Model) (problem : Problem) : Model :=
  { m with problem, result := .none, notary := .idle }

/-! ## Asking the solver -/

/-- What the app shows for the answer `a` to `p`: the answer only if the checker accepts it; else
that it was rejected, after which `lie`, and why. -/
def judge (p : Problem) (a : Answer) (lie : String) : Result :=
  if p.checkAnswer a then
    match a with
    | .staffed r => .staffed r
    | .impossible T => .impossible T
  else .rejected lie (diagnose p a)

/-- Run the solver; with the liar on, tell the next lie instead of its answer. -/
def ask (m : Model) : Model :=
  let a := solve m.problem
  if m.liar then
    let l := Lie.all[m.lies % Lie.all.size]!
    { m with result := judge m.problem (lie l m.problem a) l.describe, lies := m.lies + 1, notary := .idle }
  else { m with result := judge m.problem a "", notary := .idle }

/-! ## Notarizing -/

/-- The body of `POST /roster/notarize`. -/
def notarizeBody (p : Problem) (r : Roster) : String :=
  Json.compress <| Json.mkObj [("people", toJson p.people), ("shifts", toJson p.shifts),
    ("need", toJson p.need), ("avail", toJson p.avail), ("roster", toJson r)]

/-- The notary's answers: a receipt, or why not. -/
structure Notarized where
  url : String
  ms : Nat
  deriving FromJson

structure Refused where
  error : String
  deriving FromJson

/-- What the notary answered. Without one (a page not served by `leanui-roster`), the POST gets a
static server's error page, not JSON. -/
def Notary.ofResponse (res : Response) : Notary :=
  if res.ok then
    match Json.decode Notarized res.body with
    | .ok n => .done n.url n.ms
    | .error e => .failed s!"The notary's answer could not be read: {e}"
  else match Json.decode Refused res.body with
    | .ok e => .failed e.error
    | .error _ =>
      if res.status == 0 then .failed "The server could not be reached."
      else .failed s!"This page is not served by leanui-roster, so there is no notary here (HTTP {res.status})."

/-- The verify page, for the receipt at `url`. -/
def verifyHref (url : String) : String := "/roster/verify/?receipt=" ++ Url.percentEncode url Url.querySafe

/-! ## Update -/

def update : Msg → Model → Model × Cmd Msg
  | .toggle i s, m => (m.edit (m.problem.toggle i s), .none)
  | .more s, m => (m.edit (m.problem.setNeed s (m.problem.needOf s + 1)), .none)
  | .fewer s, m => (m.edit (m.problem.setNeed s (m.problem.needOf s - 1)), .none)
  | .preset p, m => (m.edit p, .none)
  -- the largest problem the demo is for: 30 people, 10 shifts
  | .random, m => ({ m.edit (random (m.draws + 1).toUInt64 30 10) with draws := m.draws + 1 }, .none)
  | .liar b, m => ({ m with liar := b, lies := 0 }, .none)
  | .ask, m => (ask m, .none)
  | .notarize, m => match m.result, m.notary with
    | .staffed r, .idle | .staffed r, .failed _ =>
      let n := m.requests + 1
      ({ m with notary := .working, requests := n },
        .fetch { method := "POST", url := "/roster/notarize", headers := #[("content-type", "application/json")],
                 body := notarizeBody m.problem r } (.notarized n))
    | _, _ => (m, .none)
  | .notarized n res, m =>
    -- an answer about an older roster (edited or asked again since) is dropped
    if n == m.requests && m.notary matches .working then ({ m with notary := .ofResponse res }, .none)
    else (m, .none)

/-- The first preset. -/
def init : Model := { problem := samples[0]!.2 }

/-! ## View -/

/-- An accepted violator in words, for anyone to check by eye in the grid. -/
def explain (p : Problem) (T : List Nat) : String :=
  let able := p.able T
  let shifts := andList (T.map p.shiftName)
  let need := peopleCount (T.map p.needOf).sum
  let who := if able.isEmpty then "nobody" else s!"only {peopleCount able.length}"
  let names := if able.isEmpty then "" else ": " ++ andList (able.map p.personName)
  if T.length == 1 then s!"This shift, {shifts}, needs {need}, but {who} can do it{names}."
  else s!"These {T.length} shifts, {shifts}, need {need}, but {who} can do any of them{names}."

/-- Person `i`, shift `s`: a click flips whether they can do it. -/
def cell (p : Problem) (i s : Nat) (works hl : Bool) : Html Msg :=
  let can := p.canWork i s;
  <td>
    <button class="cell" class:can={can} class:works={works} class:hl={hl} aria-pressed={can}
      aria-label={s!"{p.personName i}, {p.shiftName s}"} onClick={.toggle i s}>{if works then "✓" else ""}</button>
  </td>

/-- The grid, with the result drawn on it: who works where, or the violator's shifts and the
people able to do them. -/
def grid (p : Problem) (res : Result) : Html Msg :=
  let roster := match res with | .staffed r => some r | _ => none
  let T := match res with | .impossible T => T | _ => []
  let able := p.able T
  let shifts := Array.range p.shifts.length;
  <div class="grid-wrap">
    <table class="grid" class:explaining={!T.isEmpty}>
      <thead>
        <tr>
          <th class="corner" />
          {...shifts.map fun s => <th class="shift" class:short={T.contains s} scope="col">{p.shiftName s}</th>}
        </tr>
        <tr class="needs">
          <th scope="row">Needs</th>
          {...shifts.map fun s =>
            <td class="need">
              <button class="fewer" disabled={p.needOf s == 0} aria-label={s!"Fewer for {p.shiftName s}"}
                onClick={.fewer s}>−</button>
              <output>{p.needOf s}</output>
              <button class="more" aria-label={s!"More for {p.shiftName s}"} onClick={.more s}>+</button>
            </td>}
        </tr>
        <tr class="gets" if={roster.isSome}>
          <th scope="row">Gets</th>
          {...shifts.map fun s => <td class="count">{(roster.getD []).count (some s)}</td>}
        </tr>
      </thead>
      <tbody>
        {...(Array.range p.people.length).map fun i =>
          let works := roster.bind (·[i]?) |>.join
          let isAble := able.contains i;
          <tr>
            <th class="person" class:able={isAble} scope="row">{p.personName i}</th>
            {...shifts.map fun s => cell p i s (works == some s) (isAble && T.contains s && p.canWork i s)}
          </tr>}
      </tbody>
    </table>
  </div>

def notaryView : Notary → Html Msg
  | .idle =>
    <p class="notary">
      <button id="notarize" onClick={.notarize}>Notarize</button>
      {" "}Have Lean's kernel prove this roster valid on the server, as a receipt anyone can check.
    </p>
  | .working =>
    <p class="notary"><button id="notarize" disabled>Notarizing…</button>{" "}Lean's kernel is checking this roster.</p>
  | .done url ms =>
    <p class="notary done">
      Notarized in {ms} ms: Lean's kernel proved this roster valid.{" "}
      <a id="verify" href={verifyHref url}>Verify this roster in your browser →</a>
    </p>
  | .failed why =>
    <p class="notary failed">
      <button id="notarize" onClick={.notarize}>Notarize</button>
      {" "}<span id="notary-error">Not notarized: {why}</span>
    </p>

def resultView (m : Model) : Html Msg :=
  match m.result with
  | .none =>
    <section id="result" class="result">
      <p>Tick who can do which shift, set how many people each shift needs, then ask: <b>Can we staff this?</b></p>
    </section>
  | .staffed _ =>
    <section id="result" class="result staffed">
      <h2>Yes: this can be staffed.</h2>
      <p>
        Everyone works at most one shift, and only one they can do, and every shift gets the
        people it needs. The grid shows who works where (✓).
      </p>
      <p class="checked">The checker accepted this answer just now.</p>
      {notaryView m.notary}
    </section>
  | .impossible T =>
    <section id="result" class="result impossible">
      <h2>No: this can't be staffed.</h2>
      <p id="why">{explain m.problem T}</p>
      <p>
        Whatever the roster, {if T.length == 1 then "it stays short" else "at least one of them stays short: nobody works two shifts"}.
        The shifts, and the people able to do them, are highlighted in the grid.
      </p>
      <p class="checked">The checker accepted this explanation just now.</p>
    </section>
  | .rejected lie why =>
    <section id="result" class="result rejected">
      <h2>Answer rejected.</h2>
      <p if={!lie.isEmpty} id="lie">The lying solver {lie}.</p>
      <p id="why">The solver's answer was rejected: {why}</p>
      <p>So the app shows nothing in the grid: it shows only answers the checker accepts.</p>
    </section>

/-- A guarantee in the "What is proved" panel: its kind, what it says, and what it trusts. -/
def Guarantee (kind trusts : String) (children : Array (Html Msg) := #[]) : Html Msg :=
  <li><span class="kind">{kind}</span><div><p>{...children}</p><p class="trusts">{trusts}</p></div></li>

def proved : Html Msg :=
  <section class="proved">
    <h2>What is proved</h2>
    <p class="kinds">
      <b>a</b> proved once, for every problem · <b>b</b> checked now, for
      this answer · <b>c</b> proved for this roster on the server, <b>c′</b> and again in your
      browser · <b>d</b> not trusted
    </p>
    <ul>
      <Guarantee kind="a" trusts="Trusts Lean's kernel, which checked the proof, and Lean's compiler, which built this page. The view that draws the result is tested, not proved.">
        <b>The app never shows an unchecked answer.</b> A roster on screen is valid, and “can't be
        staffed” is shown only when no roster can be. <code>steps_inv</code>
      </Guarantee>
      <Guarantee kind="a" trusts="Trusts Lean's kernel.">
        <b>The checks are right.</b> A roster passes exactly when it is valid, and a reason passes
        only if it really rules out every roster. <code>checkRoster_iff</code>,{" "}
        <code>checkViolator_sound</code>
      </Guarantee>
      <Guarantee kind="a" trusts="Trusts Lean's kernel.">
        <b>A reason always exists.</b> When no valid roster exists, some shifts need more people
        than can do any of them. <code>Roster.Problem.complete</code>, proved with Mathlib's
        Hall's marriage theorem in <code>roster/hall</code>
      </Guarantee>
      <Guarantee kind="b" trusts="Trusts the proofs above, Lean's compiler and your browser.">
        <b>This answer was checked just now</b>, by the compiled checker, in this page.
      </Guarantee>
      <Guarantee kind="c" trusts="Trusts Lean's kernel, on the server.">
        <b>Notarize:</b> Lean's kernel proves that this roster is valid, and the server keeps the
        proof as a receipt.
      </Guarantee>
      <Guarantee kind="c′" trusts="Trusts nanoda, a second kernel written in Rust, and the verify page with its reference of the published definitions, as served: not Lean's kernel, not this app.">
        <b>Verify:</b> an independent kernel checks the receipt again, in your browser.
      </Guarantee>
      <Guarantee kind="d" trusts="Not trusted: nothing above depends on it.">
        <b>The solver</b> only searches. It can be wrong, or lie (try the switch).
      </Guarantee>
    </ul>
  </section>

def view (m : Model) : Html Msg :=
  <main class="roster">
    <header>
      <h1>Can we staff this?</h1>
      <p class="lead">
        One day of an event. Each person ticks the shifts they can do and works at most one; each
        shift needs a number of people. A solver looks for a roster, and a checker proved
        correct decides what you see.
      </p>
    </header>
    <section class="controls">
      <span class="presets">
        Start from{" "}
        {...samples.map fun (name, p) => <button class="preset" onClick={.preset p}>{name.capitalize}</button>}
        <button class="preset" onClick={.random}>Random</button>
      </span>
      <label class="switch" title="Each answer is wrong, in a different way each time">
        <input id="liar" type="checkbox" checked={m.liar} onCheck={.liar} />
        {" "}Lying solver
      </label>
      <button id="ask" class="primary" onClick={.ask}>Can we staff this?</button>
    </section>
    {resultView m}
    {grid m.problem m.result}
    <p class="legend">
      <span class="swatch" /> can't do it <span class="swatch can" /> can do it
      <span class="swatch works">✓</span> works this shift · click a cell to change it
    </p>
    {proved}
  </main>

def program : Program Model Msg := { init := fun _ => (init, .none), update, view }

end Roster
