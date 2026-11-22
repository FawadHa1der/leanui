/-
`lake exe iris-gen <dir>`: translates every program in `Manifest.programs` and every library in
`Manifest.libs`, and writes

  <dir>/js/<name>.mjs   ES modules for rt/runtime.mjs (libraries: for rt/embed.mjs)
  <dir>/c/<name>.c      C11 for rt/hl_rt.h (programs only)
  <dir>/manifest.json   per program: the expected result, the reference interpreter's results under
                        each schedule, the kernels it calls and their theorems, the closed theorem
                        if there is one, and the translator's statistics; per library export: its
                        kernel, the kernels it calls, and their theorems
-/
import Lean.Data.Json
import LeanUIIris.Translate
import LeanUIIris.Interp
import LeanUIIris.Manifest

open Lean LeanUIIris LeanUIIris.Manifest

def irisLeanRev : String := "100ed29e10b3b5e91d676d31ea708987882079e0"

def names (ns : List Name) : Json := toJson (ns.map toString)

def kernelJson (k : Kernel) : Json := Json.mkObj [
  ("name", k.name), ("source", k.source), ("consts", names (k.consts.map (·.1))),
  ("theorems", names k.theorems), ("says", k.says)]

def kindName : Kind → String
  | .edge => "edge" | .small => "small" | .large => "large" | .bench => "bench"

/-- An exported constant: the kernel it belongs to (by name), its theorems, and the kernels found
inside it by comparing terms (`Critical.criticalSpin` calls `SpinLock`'s constants). -/
def exportJson (n : Name) (v : Iris.HeapLang.Val) : Json :=
  let own := kernels.find? (·.consts.any (·.1 == n))
  let inside := (kernelsIn (.val v)).filter fun (k, _) => own.all (·.name != k.name)
  Json.mkObj [
    ("name", exportName n), ("const", toString n),
    ("kernel", toJson (own.map (·.name))),
    ("theorems", names (own.map (·.theorems) |>.getD [])),
    ("calls", toJson (inside.map (·.1.name))),
    ("calls_theorems", names (inside.flatMap (·.1.theorems)))]

def main (args : List String) : IO UInt32 := do
  let out := args.headD "gen"
  IO.FS.createDirAll s!"{out}/js"
  IO.FS.createDirAll s!"{out}/c"
  let mut entries := #[]
  let mut failed := false
  for k in kernels do
    if k.distinct.isEmpty then
      IO.eprintln s!"kernel {k.name}: every constant is also another kernel's, so no program can name it"
      failed := true
  for p in programs do
    match Translate.translate p.name p.exp, Translate.translate p.name p.exp .c with
    | .error e, _ | _, .error e =>
      IO.eprintln s!"{p.name}: translation failed: {e}"
      failed := true
    | .ok js, .ok c =>
      IO.FS.writeFile s!"{out}/js/{p.name}.mjs" js.code
      IO.FS.writeFile s!"{out}/c/{p.name}.c" c.code
      let interp := if p.kind == .large || p.kind == .bench then [] else
        Interp.schedules.map fun s => Json.mkObj [
          ("schedule", s.label), ("result", Interp.run p.exp s (if p.kind == .edge then 2_000_000 else 5_000_000))]
      let ks := kernelsIn p.exp
      entries := entries.push <| Json.mkObj [
        ("name", p.name), ("kind", kindName p.kind),
        ("expect", toJson p.expect),
        ("closed", toJson (p.closed.map toString)),
        ("scope", if p.closed.isSome then "whole program"
                  else if ks.isEmpty then "no kernel" else "kernels only; the driver is unproved glue"),
        ("kernels", toJson (ks.map (·.1.name))),
        ("consts", names (ks.flatMap (·.2))),
        ("theorems", names (ks.flatMap (·.1.theorems) ++ p.closed.toList)),
        ("interp", Json.arr interp.toArray),
        ("functions", js.nfun), ("static_cells", js.nstatic), ("bytes", js.code.utf8ByteSize),
        ("stats", Json.mkObj (js.stats.map fun (k, n) => (k, toJson n)))]
  let mut libEntries := #[]
  for l in libs do
    match Translate.translate l.name hl(#()) .js (l.exports.map fun (n, v) => (exportName n, v)) with
    | .error e =>
      IO.eprintln s!"{l.name}: translation failed: {e}"
      failed := true
    | .ok js =>
      IO.FS.writeFile s!"{out}/js/{l.name}.mjs" js.code
      libEntries := libEntries.push <| Json.mkObj [
        ("name", l.name), ("exports", Json.arr (l.exports.map fun (n, v) => exportJson n v).toArray),
        ("functions", js.nfun), ("bytes", js.code.utf8ByteSize),
        ("stats", Json.mkObj (js.stats.map fun (k, n) => (k, toJson n)))]
  let manifest := Json.mkObj [
    ("generated_by", "iris/Gen.lean"), ("iris_lean", irisLeanRev), ("lean", Lean.versionString),
    ("axioms_checked_in", "iris/LeanUIIris/Axioms.lean"),
    ("kernels", Json.arr (kernels.map kernelJson).toArray),
    ("programs", Json.arr entries), ("libs", Json.arr libEntries)]
  IO.FS.writeFile s!"{out}/manifest.json" (manifest.pretty 100 ++ "\n")
  IO.println s!"wrote {entries.size} programs and {libEntries.size} libraries to {out}"
  return if failed then 1 else 0
