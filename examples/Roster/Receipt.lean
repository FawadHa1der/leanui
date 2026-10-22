module
public import Roster.Core
/-!
# Roster: the Lean source of a receipt

The notary (`roster/notary`, Lean 4.35) proves that a roster is valid with Lean's kernel and
exports the proof, with everything it depends on, as a receipt. This is the file it compiles:

    import Roster.Core
    namespace Roster.Receipt
    def problem : Roster.Problem := { people := ["Ana", …], shifts := […], need := […], avail := [[true, …], …] }
    def roster : Roster.Roster := [some 2, none, …]
    theorem valid : problem.Valid roster := (Roster.Problem.checkRoster_iff problem roster).mp (by decide +kernel)
    end Roster.Receipt

`decide +kernel` has the kernel itself evaluate `checkRoster problem roster` to `true`, so the
receipt trusts no compiled code (no `native_decide`). Names become string literals through
`String.quote`, which escapes quotes, backslashes and control characters, so no name can end its
literal early; everything else is a number, a `Bool` or `none`. Each definition is one line: a
literal split over several lines failed to parse in the verify checker's tests.

It is built here, in the main build, so the tests check it natively (`tests/Kit.lean`); the
server (`examples/RosterServer.lean`) writes it out for the notary.
-/
public section
namespace Roster

def receiptSource (p : Problem) (r : Roster) : String :=
  let opt : Option Nat → String
    | some s => s!"some {s}"
    | none => "none"
  "import Roster.Core\n" ++
  "namespace Roster.Receipt\n" ++
  "def problem : Roster.Problem := { people := " ++ list String.quote p.people ++
    ", shifts := " ++ list String.quote p.shifts ++ ", need := " ++ list toString p.need ++
    ", avail := " ++ list (list toString) p.avail ++ " }\n" ++
  "def roster : Roster.Roster := " ++ list opt r ++ "\n" ++
  "theorem valid : problem.Valid roster := (Roster.Problem.checkRoster_iff problem roster).mp (by decide +kernel)\n" ++
  "end Roster.Receipt\n"
where
  /-- `[a, b, c]`, each element printed by `f`. -/
  list {α : Type} (f : α → String) (xs : List α) : String := "[" ++ ", ".intercalate (xs.map f) ++ "]"

end Roster
