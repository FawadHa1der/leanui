module
public import LeanUI.Server.Static
public import LeanUI.Server.Run
/-!
# The `leanui` command

    leanui serve <dir> [--port N] [--host H] [--coop] [--cache MODE] [--spa] [--no-listing] [--quiet]
    leanui build <EntryModule> [name] [--debug]
    leanui new <Name> [--dir DIR]
    leanui help | version

`serve` is a static development server (the `LeanUI.Server.Static` route behind `Std.Http`);
`build` runs `tools/build-app.sh` from the enclosing LeanUI checkout (finding the wasm64 archives
of the main checkout when run from a git worktree); `new` scaffolds a program module and its wasm
entry module. The logic lives here, apart from `cli/Main.lean`, so the native tests can check
argument parsing and the scaffold.
-/
public section
namespace LeanUI.Server.Cli

def version : String := "0.1.0"

def usage : String :=
"leanui: build and serve LeanUI apps (Lean 4 UIs for the browser, in wasm64 or server-driven)

usage:
  leanui serve <dir> [options]       static development server for a built app (dist/<name>)
      --port N         port (default 8000; 0 picks a free one)
      --host H         address to bind (default 127.0.0.1; 0.0.0.0 for every interface)
      --coop           send COOP/COEP (cross-origin isolation; LeanUI's single-threaded wasm
                       does not need it)
      --cache MODE     no-store | revalidate (default: ETag, 304 when unchanged) | immutable | <seconds>
      --spa            serve index.html for unknown extension-less paths (client-side routes)
      --no-listing     no directory listings
      --quiet          do not log requests
  leanui build <EntryModule> [name] [--debug]
                       compile an app entry module (one `leanui_app`) to dist/<name>/ with
                       tools/build-app.sh (Docker image with emsdk; wasm64 archives in
                       $LEANUI_TOOLCHAIN, found automatically from a git worktree)
  leanui new <Name> [--dir DIR]
                       scaffold DIR/<Name>.lean (the program) and DIR/<Name>App.lean (its
                       wasm entry point); DIR defaults to examples/ when it exists
  leanui help          this text
  leanui version
"

/-! ## serve -/

structure ServeOpts where
  dir : System.FilePath := "."
  port : UInt16 := 8000
  host : String := "127.0.0.1"
  coop : Bool := false
  cache : Cache := .revalidate
  spa : Bool := false
  listing : Bool := true
  quiet : Bool := false
  deriving Inhabited

def parseCache (s : String) : Except String Cache :=
  match s with
  | "no-store" => .ok .noStore
  | "revalidate" | "no-cache" => .ok .revalidate
  | "immutable" => .ok .immutable
  | _ => match s.toNat? with
    | some n => .ok (.maxAge n)
    | none => .error s!"--cache: expected no-store, revalidate, immutable or seconds, got {s}"

def parsePort (s : String) : Except String UInt16 :=
  match s.toNat? with
  | some n => if n < 65536 then .ok n.toUInt16 else .error s!"port out of range: {s}"
  | none => .error s!"not a port: {s}"

partial def parseServe (args : List String) (o : ServeOpts := {}) (dirSet := false) : Except String ServeOpts :=
  match args with
  | [] => if dirSet then .ok o else .error "serve: which directory? (leanui serve dist/<name>)"
  | "--port" :: p :: rest => do parseServe rest { o with port := ← parsePort p } dirSet
  | "--host" :: h :: rest => parseServe rest { o with host := h } dirSet
  | "--coop" :: rest => parseServe rest { o with coop := true } dirSet
  | "--cache" :: m :: rest => do parseServe rest { o with cache := ← parseCache m } dirSet
  | "--spa" :: rest => parseServe rest { o with spa := true } dirSet
  | "--no-listing" :: rest => parseServe rest { o with listing := false } dirSet
  | "--quiet" :: rest => parseServe rest { o with quiet := true } dirSet
  | a :: rest =>
    if a.startsWith "--" then .error s!"serve: unknown option {a}"
    else if dirSet then .error s!"serve: one directory only (got {o.dir} and {a})"
    else parseServe rest { o with dir := a } true

def serveCmd (o : ServeOpts) : IO UInt32 := do
  unless ← o.dir.isDir do
    IO.eprintln s!"leanui serve: {o.dir} is not a directory"; return 1
  let st : Static := { root := o.dir, cache := o.cache, htmlCache := if o.cache == .noStore then .noStore else .revalidate,
                       isolate := o.coop, listing := o.listing, spa := o.spa }
  IO.println s!"[leanui] serving {o.dir}{if o.coop then " (cross-origin isolated)" else ""}"
  serve { host := o.host, port := o.port, log := !o.quiet } (st.route)
  return 0

/-! ## build -/

/-- The LeanUI checkout enclosing `dir`: the nearest ancestor with `tools/build-app.sh`. -/
partial def findRoot (dir : System.FilePath) : IO (Option System.FilePath) := do
  if ← (dir / "tools" / "build-app.sh").pathExists then return some dir
  match dir.parent with
  | some p => if p == dir then return none else findRoot p
  | none => return none

/-- In a git worktree, `.git` is a file `gitdir: <main>/.git/worktrees/<name>`; the main
checkout is where the wasm64 archives usually are. -/
def mainCheckout (root : System.FilePath) : IO (Option System.FilePath) := do
  let dotgit := root / ".git"
  if !(← dotgit.pathExists) || (← dotgit.isDir) then return none
  let txt ← IO.FS.readFile dotgit
  match (txt.trimAscii.toString.dropPrefix? "gitdir: ") with
  | none => return none
  | some p =>
    match p.toString.splitOn "/.git/worktrees/" with
    | main :: _ :: _ => return some main
    | _ => return none

/-- `$LEANUI_TOOLCHAIN`, else `<root>/.toolchain`, else the main checkout's `.toolchain`. -/
def findToolchain (root : System.FilePath) : IO (Option System.FilePath) := do
  if let some tc ← IO.getEnv "LEANUI_TOOLCHAIN" then return some tc
  let has (d : System.FilePath) := (d / "wasm64" / "lib" / "libInit.a").pathExists
  if ← has (root / ".toolchain") then return some (root / ".toolchain")
  if let some main ← mainCheckout root then
    if ← has (main / ".toolchain") then return some (main / ".toolchain")
  return none

/-- The output name `tools/build-app.sh` derives from a module name. -/
def defaultName (mod : String) : String := (mod.map fun c => if c == '.' then '-' else c).toLower

def buildCmd (mod : String) (name : Option String) (debug : Bool) : IO UInt32 := do
  let cwd ← IO.currentDir
  let some root ← findRoot cwd
    | IO.eprintln "leanui build: not inside a LeanUI checkout (no tools/build-app.sh above this directory)"; return 1
  let some tc ← findToolchain root
    | IO.eprintln s!"leanui build: no wasm64 archives; run toolchain/build-archives.sh, or set LEANUI_TOOLCHAIN"; return 1
  let docker ← IO.Process.output { cmd := "docker", args := #["info", "--format", "{{.ServerVersion}}"] } |>.toBaseIO
  match docker with
  | .ok o => if o.exitCode != 0 then IO.eprintln "leanui build: Docker is not running (the build compiles C to wasm64 in an emsdk image)"; return 1
  | .error _ => IO.eprintln "leanui build: docker not found"; return 1
  let name := name.getD (defaultName mod)
  IO.println s!"[leanui] building {mod} -> dist/{name}/ (toolchain {tc})"
  let t0 ← IO.monoMsNow
  let child ← IO.Process.spawn {
    cmd := "bash", args := #[(root / "tools" / "build-app.sh").toString, mod, name] ++ (if debug then #["--debug"] else #[]),
    cwd := root, env := #[("LEANUI_TOOLCHAIN", some tc.toString)] }
  let code ← child.wait
  let dt := (← IO.monoMsNow) - t0
  if code == 0 then
    IO.println s!"[leanui] built dist/{name}/ in {dt / 1000}.{(dt % 1000) / 100}s; try: leanui serve {root / "dist" / name}"
  else IO.eprintln s!"[leanui] build failed (exit {code})"
  return code

/-! ## new -/

/-- A Lean module name component: a capitalised identifier. -/
def validName (n : String) : Bool :=
  match n.toList with
  | c :: cs => c.isUpper && cs.all fun c => c.isAlphanum || c == '_'
  | [] => false

/-- The files `leanui new <Name>` writes: the program and its wasm entry module. -/
def scaffold (name : String) : List (String × String) := [
  (name ++ ".lean", s!"module
public import LeanUI
public section
open LeanUI Attr

/-!
# {name}

A LeanUI program: `init` (from the page's flags), `update` and `view` are pure. The same module
runs in the browser as wasm64 (`{name}App`) and natively on a LeanUI server (SSR, or a
server-driven session for browsers without Memory64).
-/
namespace {name}

structure Model where
  count : Int := 0
  draft : String := \"\"
  deriving Inhabited

inductive Msg where
  | inc | dec | edit (s : String) | reset

def init (flags : String) : Model × Cmd Msg := (\{ count := flags.toInt?.getD 0 }, .none)

def update : Msg → Model → Model × Cmd Msg
  | .inc, m => (\{ m with count := m.count + 1 }, .none)
  | .dec, m => (\{ m with count := m.count - 1 }, .none)
  | .edit s, m => (\{ m with draft := s }, .none)
  | .reset, _ => (\{}, .log \"reset\")

def view (m : Model) : Html Msg :=
  el \"main\" #[cls \"{name.toLower}\"] #[
    el \"h1\" #[] #[text \"{name}\"],
    el \"p\" #[] #[
      el \"button\" #[id \"dec\", onClick .dec] #[text \"-\"],
      el \"output\" #[id \"count\"] #[text (toString m.count)],
      el \"button\" #[id \"inc\", onClick .inc] #[text \"+\"]],
    el \"p\" #[] #[
      el \"input\" #[id \"draft\", value m.draft, onInput .edit] #[],
      el \"span\" #[] #[text s!\" \{m.draft.length} characters\"]],
    el \"button\" #[id \"reset\", onClick .reset] #[text \"reset\"]]

def program : Program Model Msg := \{ init, update, view }

end {name}
"),
  (name ++ "App.lean", s!"module
public import {name}
public import LeanUI.Host.Wasm
-- The wasm entry point: `leanui build {name}App {name.toLower}` compiles this to dist/{name.toLower}/.
leanui_app {name}.program
")]

def newCmd (name : String) (dir : Option System.FilePath) : IO UInt32 := do
  unless validName name do
    IO.eprintln s!"leanui new: {name} is not a module name (a capitalised identifier, e.g. Todo)"; return 1
  let dir ← match dir with
    | some d => pure d
    | none => do pure (if ← System.FilePath.isDir "examples" then "examples" else ".")
  IO.FS.createDirAll dir
  let files := scaffold name
  for (f, _) in files do
    if ← (dir / f).pathExists then
      IO.eprintln s!"leanui new: {dir / f} exists; not overwriting anything"; return 1
  for (f, body) in files do
    IO.FS.writeFile (dir / f) body
    IO.println s!"[leanui] wrote {dir / f}"
  IO.println s!"
next steps:
  1. add the modules to a library in lakefile.toml, e.g. the examples:
       roots = [..., \"{name}\", \"{name}App\"]
  2. build the wasm app:     leanui build {name}App {name.toLower}
  3. serve it:               leanui serve dist/{name.toLower}
  4. or serve it from Lean:  LeanUI.Server.program \"{name.toLower}\" {name}.program \{ ... } sessions
"
  return 0

/-! ## entry point -/

def main (args : List String) : IO UInt32 := do
  match args with
  | [] | ["help"] | ["--help"] | ["-h"] => IO.print usage; return 0
  | ["version"] | ["--version"] => IO.println s!"leanui {version}"; return 0
  | "serve" :: rest =>
    match parseServe rest with
    | .ok o => serveCmd o
    | .error e => IO.eprintln s!"leanui {e}"; return 2
  | "build" :: rest =>
    let debug := rest.contains "--debug"
    match rest.filter (· != "--debug") with
    | [m] => buildCmd m none debug
    | [m, n] => buildCmd m (some n) debug
    | _ => IO.eprintln "usage: leanui build <EntryModule> [name] [--debug]"; return 2
  | "new" :: rest =>
    match rest with
    | [n] => newCmd n none
    | [n, "--dir", d] | ["--dir", d, n] => newCmd n (some d)
    | _ => IO.eprintln "usage: leanui new <Name> [--dir DIR]"; return 2
  | cmd :: _ => IO.eprintln s!"leanui: unknown command {cmd}\n\n{usage}"; return 2

end LeanUI.Server.Cli
