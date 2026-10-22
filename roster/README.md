# Roster: a proof-carrying staffing sheet

A LeanUI example in which proofs do work a JavaScript app cannot: an untrusted solver staffs one
day of an event, and what the app shows has been checked by code proved correct; a roster can be
notarized, which has Lean's kernel prove it valid, and the proof re-checked in any browser by a
second, independent kernel.

One day of an event: people (rows) tick the shifts (columns) they can do, each shift needs a
number of people, and each person works at most one shift. "Can we staff this?" asks the solver,
and the app shows one of:

* **a roster**, checked: every shift gets the people it needs, all of them available;
* **"can't be staffed"**, with a reason anyone can check by eye: "These 2 shifts, Bar 12–15 and
  Bar 15–18, need 6 people, but only 5 people can do any of them: Ana, Ben, Chen, Dee and Hana",
  the shifts and the people highlighted in the grid (a *Hall violator*: a set of shifts that need
  more people than can do any of them);
* **a rejected answer**, with why: the "Lying solver" switch makes the solver answer wrongly on
  purpose, a different lie each time (it puts someone on a shift they can't do, leaves a shift
  short, says it can't be done blaming a shift that can be staffed, or gives no reason), and the
  checker rejects every one.

A roster on screen can be **notarized**: the server has Lean's kernel prove it valid and keeps the
proof, a *receipt*. The **verify page** checks a receipt again in the browser, with nanoda (a Lean
kernel written in Rust, apart from Lean) compiled to WebAssembly, and shows the table it proves
valid; its "Tamper" button flips one cell and the kernel rejects the result.

## What is proved, and what each part trusts

The app's "What is proved" panel lists these, labelled by kind:

| Kind | Guarantee | Where | Trusts |
|---|---|---|---|
| **a**, a theorem about the code, for every input | The app never shows an unchecked answer: after any sequence of messages, a roster in the model's result is valid for the model's problem, and a reason there means no roster is | `steps_inv`, `examples/RosterProofs.lean` | Lean's kernel; Lean's compiler, which built the app; the view, which draws the result (tested, not proved) |
| **a** | The checkers are right: `checkRoster` accepts a roster exactly when it is valid, and a violator `checkViolator` accepts rules out every roster | `checkRoster_iff`, `checkViolator_sound`, `checkAnswer_sound`, `examples/Roster/Core.lean` | Lean's kernel |
| **a** | A reason always exists: every problem without a valid roster has a violator the checker accepts, so a correct solver is never stuck | `Roster.Problem.complete`, `roster/hall/` (Hall's marriage theorem, from Mathlib) | Lean's kernel |
| **b**, a check of this answer, now | The answer on screen passed `checkAnswer`, in the page | `judge`, `examples/Roster.lean` | the proofs above; Lean's compiler; the browser |
| **c**, a theorem about this data | Notarized: Lean's kernel proved `Valid problem roster` for this problem and roster | `roster/notary/`, `examples/RosterServer.lean` | Lean's kernel, on the server |
| **c′** | Verified: an independent kernel checked that theorem again, in the browser | `roster/verify/` | nanoda; the verify page's checks and the reference (below), built from the published source, as served |
| **d** | The solver only searches | `examples/Roster/Solver.lean` | nothing: nothing above depends on it |

`Valid` is the specification, small enough to read in full:

```lean
def Problem.Valid (p : Problem) (r : Roster) : Prop :=
  r.length = p.people.length ∧                                 -- one entry per person
  (∀ i s, r[i]? = some (some s) → p.canWork i s = true) ∧      -- everyone can do their shift
  (∀ s, s < p.shifts.length → p.needOf s ≤ r.count (some s))   -- every shift has enough people
```

A roster is a `List (Option Nat)`, each person's shift or `none`, so nobody can be on two shifts.
Every theorem's axioms are checked in the build (`#guard_msgs in #print axioms`): the standard
three, never `sorryAx`, and no `native_decide`.

## The parts

| Path | What | Lean |
|---|---|---|
| `examples/Roster/Core.lean` | the problem, `Valid`, the checkers and their soundness. Imports only `Init`, since three projects compile it | 4.34, 4.34 + Mathlib, 4.35 |
| `examples/Roster/Solver.lean` | the solver (augmenting paths; a violator from the shifts reachable from a place it could not fill), the lies, the sample problems | 4.34 |
| `examples/Roster.lean`, `RosterApp.lean`, `roster.html` | the app, a client-side wasm64 app like the others (its style is inline in the page: `tools/build-app.sh` copies only the page) | 4.34 |
| `examples/RosterProofs.lean` | `steps_inv` | 4.34 |
| `examples/Roster/Receipt.lean` | `receiptSource`: a problem and a roster as the Lean file the notary compiles | 4.34 |
| `examples/RosterServer.lean` | `leanui-roster`: serves the app and the verify page, and `POST /roster/notarize` | 4.34 |
| [`roster/notary/`](notary/README.md) | the notary: Lean 4.35 compiles a receipt, then `leanexport` exports it | 4.35 |
| [`roster/hall/`](hall/README.md) | the completeness proof, with Mathlib | 4.34 + Mathlib |
| `roster/verify/` | the verify page and its checker (`checker/`, Rust: nanoda for the browser) | 4.35 (the reference) |

The main build compiles the `examples/` files (`lake build`), the native tests check the checkers
and the solver on random problems (`tests/Kit.lean`), and nothing in the main build reads
`roster/`. The notary and the hall each pin their own toolchain, called by path
(docs/TOOLCHAIN.md).

## Running it

    lake build leanui-roster                 # with the main build's toolchain (docs/TOOLCHAIN.md)
    tools/build-app.sh RosterApp roster      # the app: dist/roster/
    roster/verify/build.sh                   # the verify page: dist/roster/verify/
    .lake/build/bin/leanui-roster            # http://127.0.0.1:5370/roster/

Run the server from the repository root: it runs `roster/notary/notarize.sh`, which needs Lean
4.35 (`elan toolchain install leanprover/lean4:v4.35.0`). `roster/verify/build.sh` also needs Node
and Rust with the `wasm32-wasip1` target. Options: `--port`, `--host`, `--dist`, `--receipts`
(where receipts go, `.lake/roster-receipts` by default), `--quiet`.

Served by `leanui serve dist` instead, the app works the same, but "Notarize" answers that there
is no notary.

## The notary

`POST /roster/notarize` takes a problem and a roster as JSON. The server trusts the request no
more than the app trusts its solver: it checks the roster with `checkRoster`, writes
`Roster.receiptSource` (a Lean file stating `theorem valid : problem.Valid roster`, proved with
`checkRoster_iff` and `decide +kernel`, so that the kernel evaluates the checker), and runs the
notary on it, one receipt at a time. The receipt is the theorem exported with everything it
depends on (NDJSON, Lean's export format), served at `/roster/receipts/<id>.ndjson` under a random
name (the latest 1,000 are kept); the app links it to the verify page. Problems are limited to 100 people and 30 shifts (about 3 s of kernel
time). [`notary/README.md`](notary/README.md) has the details: for the feasible sample a receipt
takes about 2.5 s and is 2.0 MB (320 kB gzipped), nearly all of it `Init`, carried along so that
the receipt checks on its own.

## The verify page

`/roster/verify/?receipt=<url>`, or a receipt file chosen or dropped on the page. The checker,
`checker.wasm` (821 KB, 257 KB gzipped), is nanoda as a WASI command, run in a Worker on a small
WASI shim (`worker.js`). It checks every declaration, prints the theorem, fingerprints every
declaration and decodes the data. A receipt brings its own declarations, `Init`'s included, so
"the kernel accepts it" alone would accept a receipt that redefines `Valid`, or `List.count`, to
make any roster pass. So the page passes a receipt only if all four checks pass (`receipt.js`):

1. **Checked by an independent kernel**: nanoda accepts every declaration, with no axiom beyond
   the standard three.
2. **The right statement**: `Roster.Receipt.valid` states exactly
   `Roster.Problem.Valid Roster.Receipt.problem Roster.Receipt.roster`.
3. **The published definitions**: every declaration outside `Roster.Receipt` has the fingerprint
   that `reference.json` gives it. A fingerprint is a SHA-256 of what the kernel checks, by
   structure, so it is the same in every export (`checker/src/fingerprint.rs`). `reference.json`
   is built from the published source, `examples/Roster/Core.lean`, exported the way the notary
   exports receipts, and names the source and its SHA-256.
4. **Plain data**: `problem` and `roster` are literals (`checker/src/data.rs`), with a need for each
   shift and a full row of availability for each person, which the page shows as the table. They
   are decoded by the checker from the terms the kernel checked, not by JavaScript reading the
   file again.

The page then shows the table, the statement, and the published definition of `Valid` (from
`reference.json`), which check 3 found the receipt's to be.
`roster/verify/forge.mjs` forges a receipt that the kernel accepts but check 3 rejects (it
redefines `List.count` so that an empty roster passes); the tests use it.

Checking the feasible sample's receipt takes about 0.25 s in Chromium and 0.8 to 1.2 s in Firefox
(CI machines, to be re-measured on the reference Mac).

The verify page is plain HTML and JavaScript with wasm32: it runs in any current browser, and on
its own, with no LeanUI. The app needs Memory64, which Safari does not have yet (Safari is out of
scope here, as for the other wasm64 apps).

## Tests

    .lake/build/bin/leanui-kit-tests                    # the checkers, the solver, the lies, receiptSource
    node tests/browser/roster.mjs URL [chromium|firefox]          # the app, notarizing too under leanui-roster
    node roster/verify/test.mjs RECEIPT.ndjson                    # the four checks under Node
    node tests/browser/roster-verify.mjs URL [chromium|firefox]   # the verify page: good, tampered, forged
    roster/hall/build.sh                                # the completeness proof

`tests/browser/run-all.sh` runs the browser ones against `leanui-roster`, on the receipt the app's
test notarized; CI runs them all, and checks the completeness proof in a job of its own.

## Not covered

* nanoda is a second implementation, not a verified one: c′ trusts it, as c trusts Lean's kernel.
  Lean 4.35's toolchain ships other checkers of export files too (`leanchecker --from-export`,
  `con-leche`, `con-ron`); `notary/README.md` runs `leanchecker` and `nanoda_bin` on a receipt.
* Whoever serves the verify page could serve one that says anything: c′ is independent of Lean's
  kernel and of the notary, not of the server, when one server serves both (leanui-roster does).
  The page is plain files: anyone can serve their own copy, or run `roster/verify/test.mjs`.
* Check 3 trusts `reference.json`, which the build makes with Lean 4.35's `leanexport` from the
  source in this repository; anyone can rebuild it and compare.
* The receipt names a roster for a problem; it says nothing about who wrote either.
* The site does not serve the demo yet: it needs `leanui-roster` and Lean 4.35 in the container.
