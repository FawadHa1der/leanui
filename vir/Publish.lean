import Lean.Data.Json.Basic
import Vir.Resources
import LeanUIVir.BenchResources
import LeanUIVir.LifeResources
/-! `lake exe publish <app> <dir>`: an app's lean-vir files for the browser. `<dir>/app.json` names
the runtime module and the two manifests (runtime and program) that `vir/leanui-vir.js` loads;
the files themselves go under `<dir>/lib/vir/` (lean-vir's `forSite` layout, content-addressed). -/

def apps : List (String × Vir.Resources.ResourceSet) :=
  [("bench", LeanUIVir.BenchResources.resources), ("life", LeanUIVir.LifeResources.resources)]

def main (args : List String) : IO UInt32 := do
  let [app, out] := args | IO.eprintln "usage: publish <bench|life> <directory>"; return 2
  let some res := apps.lookup app | IO.eprintln s!"unknown app {app}"; return 2
  let dir := System.FilePath.mk out
  let site ← IO.ofExcept <| (res.forSite "lib/vir").mapError reprStr
  for file in site.files do
    let path := dir / file.path
    IO.FS.createDirAll (path.parent.getD dir)
    IO.FS.writeBinFile path file.bytes
  IO.FS.writeFile (dir / "app.json") <| Lean.Json.compress <| Lean.Json.mkObj [
    ("runtimeModule", Lean.toJson site.runtimeModule),
    ("runtimeManifest", Lean.toJson site.runtimeManifest),
    ("programManifest", Lean.toJson site.programManifests[0]!)]
  return 0
