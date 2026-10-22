# Roster: the notary

`notarize.sh` turns a roster into a *receipt*: Lean's kernel proves the roster valid, and the
theorem is exported with every definition it depends on as NDJSON (Lean's export format), for
anyone to check again with a kernel of their own (the verify page does it with nanoda).

    roster/notary/notarize.sh Receipt.lean out.ndjson

`Receipt.lean` is what `Roster.receiptSource` writes (`examples/Roster/Receipt.lean`):

```lean
import Roster.Core
namespace Roster.Receipt
def problem : Roster.Problem := { people := ["Ana", "Ben", …], shifts := […], need := […], avail := […] }
def roster : Roster.Roster := [some 4, some 5, none, …]
theorem valid : problem.Valid roster := (Roster.Problem.checkRoster_iff problem roster).mp (by decide +kernel)
end Roster.Receipt
```

The script builds this project if need be (it compiles `Roster.Core` from `../../examples`),
compiles the receipt with Lean 4.35, whose kernel evaluates `checkRoster problem roster` to `true`
(`decide +kernel`: no compiled code is trusted, unlike `native_decide`), then runs
`leanexport Roster.Receipt -- Roster.Receipt.valid`. It exits with 3 if the toolchain is missing,
1 on any other failure. `leanui-roster` (`examples/RosterServer.lean`) runs it for
`POST /roster/notarize`, after checking the roster itself.

For the feasible preset it takes about 2.5 s (Lake 0.2 s, Lean 0.5 s, leanexport 1.8 s) and the
receipt is 2.0 MB, 320 kB gzipped: 956 declarations, nearly all from `Init`, carried along so that
the receipt checks on its own. At the server's limit, 100 people and 30 shifts, Lean takes 2.6 s
and the receipt is 2.2 MB.

The toolchain's own checkers take a receipt too: Lean's kernel again, and nanoda, which also
prints the theorem's statement and the axioms it uses:

    L=~/.elan/toolchains/leanprover--lean4---v4.35.0/bin
    PATH=$L:$PATH leanchecker --from-export out.ndjson
    $L/nanoda_bin <(echo '{"use_stdin": true, "permitted_axioms": ["propext", "Classical.choice",
      "Quot.sound"], "nat_extension": true, "string_extension": true, "pp_declars":
      ["Roster.Receipt.valid"], "pp_to_stdout": true, "print_success_message": true}') < out.ndjson

## Why it lives apart

`leanexport` and `nanoda_bin` ship with Lean 4.35's toolchain, and the main build is on 4.34. So
the notary is a project of its own, on 4.35, with its build in `roster/notary/.lake`; the tools are
called by path (elan installs the toolchain: `elan toolchain install leanprover/lean4:v4.35.0`).
`Roster.Core` imports only `Init`, so both versions compile the same source.
