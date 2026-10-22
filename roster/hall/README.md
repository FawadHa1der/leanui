# Roster: completeness, with Mathlib

`examples/Roster/Core.lean` proves the checkers sound: a roster `checkRoster` accepts is valid, and
a violator `checkViolator` accepts means no roster is. `RosterHall.lean` proves the other direction:

```lean
theorem Roster.Problem.complete (p : Problem) :
    (∃ r, p.Valid r) ∨ ∃ T, p.checkViolator T = true
theorem Roster.Problem.impossible_iff (p : Problem) :
    (¬ ∃ r, p.Valid r) ↔ ∃ T, p.checkViolator T = true
```

Every problem has an answer the checker accepts, so a correct solver is never stuck: a problem has
no valid roster exactly when some set of shifts needs more people than can do any of them. The
proof is Hall's marriage theorem, from Mathlib, applied to `needOf s` copies of each shift `s`
against the people (the module doc of `RosterHall.lean` has the argument). The statements use only
`Roster.Core`'s definitions; Mathlib is used in the proof alone, and Lean's kernel checks it all.
The build fails if either theorem ever depends on `sorry` or on an axiom beyond the standard three.

## Why it lives apart

Mathlib is large, and its releases each pin one Lean release. The main build, its CI and the wasm
builds stay free of it: nothing outside this directory reads it. It is on the same Lean as the main
build (4.34.0, with Mathlib's `v4.34.0`) and compiles the same `examples/Roster/Core.lean`, which
imports only `Init` for that reason.

## Building

    roster/hall/build.sh

It runs `lake exe cache get` for only the Mathlib modules `RosterHall.lean` imports, then
`lake build`. Nothing of Mathlib is compiled: the cache has about 740 prebuilt files for them (63 MB
to download, 1.3 GB unpacked; all of Mathlib would be several GB), and checking `RosterHall.lean`
takes a few seconds. The first run also clones Mathlib and its dependencies (Lake, from
`lake-manifest.json`): about a minute and a half in all, and 1.5 GB in `roster/hall/.lake`.

To move to a newer Lean, set `lean-toolchain` and `rev` in `lakefile.toml` to the matching Mathlib
release (Mathlib tags one per Lean release), then run `lake update` here.
