module
public import Roster.Core
/-!
# Roster: the untrusted solver, its lies, and sample problems

`solve` answers "can we staff this?" by bipartite matching of the places on each shift (shift `s`
has `needOf s` of them) to people, with Kuhn's augmenting paths. If a place cannot be filled, the
shifts reachable from it by alternating paths form a Hall violator, which is then shrunk so the
explanation stays short.

Nothing here is proved. The app shows an answer only when `Problem.checkAnswer` accepts it, and
`lie` turns the solver's answer into wrong ones to show that the checker rejects them; `diagnose`
says why, in words, but the verdict is always the checker's.
-/
public section
namespace Roster

/-! ## The solver -/

/-- Who works what while the solver searches: one entry per person. -/
abbrev Works := Array (Option Nat)

/-- Find someone for one more place on shift `s`, moving people to other shifts they can do if
need be (an augmenting path). Each search tries a person at most once (`seen`) and recurses only
through a newly tried person, so `fuel` = the number of people `n` is enough. -/
def augment (p : Problem) (n : Nat) : (fuel s : Nat) → StateM (Array Bool × Works) Bool
  | 0, _ => pure false
  | fuel + 1, s => do
    for i in [0:n] do
      if p.canWork i s && !(← get).1[i]! then
        modify fun (seen, w) => (seen.set! i true, w)
        let found ← match (← get).2[i]! with
          | none => pure true
          | some t => augment p n fuel t
        if found then
          modify fun (seen, w) => (seen, w.set! i (some s))
          return true
    return false

/-- Fill the shifts place by place: who works what, and the first shift with a place nobody can be
found for (`none`: every place is filled). -/
def assign (p : Problem) : Works × Option Nat := Id.run do
  let n := p.people.length
  let mut w : Works := Array.replicate n none
  for s in [0:p.shifts.length] do
    for _ in [0:p.needOf s] do
      let (found, _, w') := (augment p n n s).run (Array.replicate n false, w)
      if !found then return (w, some s)
      w := w'
  return (w, none)

/-- The shifts reachable from `s` by alternating paths: `s`, then the shifts of everyone able to do
one of them, until nothing changes (each round adds a shift or changes nothing). When no place on
`s` can be filled, everyone able to do one of these shifts already works one, and `s` is short:
a Hall violator. -/
def reachable (p : Problem) (w : Works) (s : Nat) : List Nat :=
  let grow T := (List.range p.shifts.length).filter fun t =>
    t == s || (p.able T).any (w[·]? == some (some t))
  Nat.repeat grow p.shifts.length [s]

/-- Leave out the shifts the violator does not need, so the explanation names few shifts. -/
def shrink (p : Problem) (T : List Nat) : List Nat :=
  T.foldl (fun T s => if p.checkViolator (T.erase s) then T.erase s else T) T

def solve (p : Problem) : Answer :=
  match assign p with
  | (w, none) => .staffed w.toList
  | (w, some s) => .impossible (shrink p (reachable p w s))

/-! ## The lying solver -/

inductive Lie | unavailable | shortShift | fakeImpossible | noExcuse
  deriving Repr, BEq, Inhabited

/-- The lies, in the order the app tells them. -/
def Lie.all : Array Lie := #[.unavailable, .shortShift, .fakeImpossible, .noExcuse]

def Lie.describe : Lie → String
  | .unavailable => "puts someone on a shift they can't do"
  | .shortShift => "leaves a shift short"
  | .fakeImpossible => "says it can't be done, blaming a shift that can be staffed"
  | .noExcuse => "says it can't be done, without a reason"

/-- `r` with at most `k` people on shift `s`: the others are sent home. -/
def capShift (s : Nat) : (k : Nat) → Roster → Roster
  | _, [] => []
  | k, o :: r =>
    if o != some s then o :: capShift s k r
    else match k with
      | 0 => none :: capShift s 0 r
      | k + 1 => o :: capShift s k r

/-- A wrong answer instead of the solver's answer `a`, or `a` itself when this lie cannot be told
(nobody is unavailable for anything, or no shift needs anyone). -/
def lie : Lie → Problem → Answer → Answer
  | .unavailable, p, a =>
    -- the roster, or as far as the solver got; someone idle if possible, so nobody else goes missing
    let r := match a with | .staffed r => r | .impossible _ => (assign p).1.toList
    let order := (List.range r.length).filter (r[·]? == some none) ++
      (List.range r.length).filter (r[·]? != some none)
    let cells := order.flatMap fun i => (List.range p.shifts.length).map (i, ·)
    match cells.find? fun (i, s) => !p.canWork i s with
    | some (i, s) => .staffed (r.set i (some s))
    | none => a
  | .shortShift, p, a =>
    let r := match a with | .staffed r => r | .impossible _ => (assign p).1.toList
    match (List.range p.shifts.length).find? (0 < p.needOf ·) with
    | some s => .staffed (capShift s (p.needOf s - 1) r)
    | none => a
  | .fakeImpossible, p, a =>
    -- a shift with enough people able to do it can be staffed on its own
    let staffable s := 0 < p.needOf s && p.needOf s ≤ (p.able [s]).length
    match (List.range p.shifts.length).find? staffable with
    | some s => .impossible [s]
    | none => a
  | .noExcuse, _, _ => .impossible []

/-! ## Explaining a verdict -/

def Problem.personName (p : Problem) (i : Nat) : String := p.people.getD i s!"person {i + 1}"
def Problem.shiftName (p : Problem) (s : Nat) : String := p.shifts.getD s s!"shift {s + 1}"

/-- `a`, `a and b`, `a, b and c`. -/
def andList : List String → String
  | [] => ""
  | [a] => a
  | a :: rest => a ++ (if rest.length == 1 then " and " else ", ") ++ andList rest

def peopleCount (n : Nat) : String := if n == 1 then "1 person" else s!"{n} people"

/-- Why `checkAnswer` accepts or rejects `a`, in words. For display only: the verdict is the
checker's, and this is not proved to agree with it. -/
def diagnose (p : Problem) : Answer → String
  | .staffed r =>
    let unable := (List.range r.length).filterMap fun i => match r[i]? with
      | some (some s) => if p.canWork i s then none else some (i, s)
      | _ => none
    let short := (List.range p.shifts.length).filter fun s => r.count (some s) < p.needOf s
    if r.length != p.people.length then
      s!"The roster has {r.length} entries for {peopleCount p.people.length}."
    else if let (i, s) :: _ := unable then
      s!"{p.personName i} is put on {p.shiftName s}, which they can't do."
    else if let s :: _ := short then
      s!"{p.shiftName s} needs {peopleCount (p.needOf s)} but gets {r.count (some s)}."
    else "Every shift gets the people it needs, and everyone works a shift they can do."
  | .impossible T =>
    let needed := (T.map p.needOf).sum
    let able := p.able T
    let need := s!"{andList (T.map p.shiftName)} {if T.length == 1 then "needs" else "need"} \
      {peopleCount needed}"
    let them := if T.length == 1 then "it" else "any of them"
    let canDo := if able.isEmpty then s!"nobody can do {them}"
      else s!"{able.length} can do {them}: {andList (able.map p.personName)}"
    if T.isEmpty then "No reason given: it names no shifts."
    else if let some s := T.find? (T.count · > 1) then s!"{p.shiftName s} is counted twice."
    else if let some s := T.find? (· ≥ p.shifts.length) then s!"There is no shift {s + 1}."
    else if able.length < needed then s!"{need}, but {if able.isEmpty then "" else "only "}{canDo}."
    else s!"{need}, and {canDo}."

/-! ## Sample problems -/

def personNames : Array String := #["Ana", "Ben", "Chen", "Dee", "Eli", "Fay", "Gus", "Hana", "Ivo",
  "Jun", "Kai", "Lea", "Max", "Noor", "Olu", "Pia", "Quinn", "Ravi", "Sol", "Tess", "Uma", "Vik",
  "Wen", "Xia", "Yara", "Zoe", "Abe", "Bea", "Cy", "Dov"]
def shiftNames : Array String := #["Gate 9–12", "Gate 12–15", "Info 9–13", "Bar 12–15", "Bar 15–18",
  "Cleanup 18–20", "Gate 15–18", "Info 13–17", "Bar 18–21", "Parking 9–13"]

/-- A summer fair: twelve people and six shifts, availability as one string of 0s and 1s per
person. -/
def fair (need : List Nat) : Problem :=
  { people := (personNames.extract 0 12).toList, shifts := (shiftNames.extract 0 6).toList, need,
    avail := ["100110", "000111", "000110", "001010", "110000", "011000",
              "100001", "010100", "000001", "111000", "010001", "001001"].map
      fun row => row.toList.map (· == '1') }

/-- A random problem: each shift needs up to twice its share of the people, each person can do
about a third of the shifts (at 30 × 10, a bit under half can be staffed). The 64-bit LCG of
`examples/Bench.lean`. -/
def random (seed : UInt64) (people shifts : Nat) : Problem := Id.run do
  let mut s := seed
  let mut need := #[]
  for _ in [0:shifts] do
    s := s * 6364136223846793005 + 1442695040888963407
    need := need.push ((s >>> 33).toNat % (2 * people / shifts + 1))
  let mut avail := #[]
  for _ in [0:people] do
    let mut row := #[]
    for _ in [0:shifts] do
      s := s * 6364136223846793005 + 1442695040888963407
      row := row.push ((s >>> 33) % 3 == 0)
    avail := avail.push row.toList
  return {
    people := (List.range people).map fun i => personNames.getD i s!"Person {i + 1}",
    shifts := (List.range shifts).map fun j => shiftNames.getD j s!"Shift {j + 1}",
    need := need.toList, avail := avail.toList }

/-- The presets. In "impossible", the two bar shifts need 6 people and only Ana, Ben, Chen, Dee and
Hana can do either. -/
def samples : Array (String × Problem) := #[
  ("feasible", fair [2, 2, 1, 2, 2, 2]),
  ("impossible", fair [2, 2, 1, 2, 4, 2])]

end Roster
