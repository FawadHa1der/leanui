# A first LeanUI app

This walks through one small app from an empty module to a tested, server-rendered page. It
assumes the setup in the README (the Lean v4.34.0 toolchain, Docker, `toolchain/build-archives.sh`
run once). `lake` below means `~/.elan/toolchains/leanprover--lean4---v4.34.0/bin/lake`.

## 1. Scaffold

```bash
./.lake/build/bin/leanui new Notes        # examples/Notes.lean and examples/NotesApp.lean
```

Add both modules to the `Examples` library in `lakefile.toml` (`roots = [..., "Notes",
"NotesApp"]`). This repository already holds the finished result (`examples/Notes.lean`, with
the test of section 3 as `tests/Notes.lean`, run by `leanui-notes-tests`), so scaffold a
different name to follow along. `Notes.lean` holds the program; `NotesApp.lean` is one line, `leanui_app
Notes.program`, the entry point of the wasm build.

## 2. The program

A program is four pure functions. Replace the scaffold's body with a note list, written as a
template (`meta import LeanUI.Syntax` makes the syntax available in this module only, at no
run-time cost):

```lean
module
public import LeanUI
meta import LeanUI.Syntax
public section
open LeanUI

namespace Notes

structure Note where
  id : Nat
  text : String

structure Model where
  notes : Array Note := #[]
  draft : String := ""
  nextId : Nat := 1

inductive Msg | draft (s : String) | add | remove (id : Nat)

def update : Msg → Model → Model × Cmd Msg
  | .draft s, m => ({ m with draft := s }, .none)
  | .add, m =>
    if m.draft.isEmpty then (m, .none)
    else ({ m with notes := m.notes.push ⟨m.nextId, m.draft⟩, nextId := m.nextId + 1, draft := "" }, .none)
  | .remove i, m => ({ m with notes := m.notes.filter (·.id != i) }, .none)

def view (m : Model) : Html Msg :=
  <main class="notes">
    <form onSubmit={fun _ => .add}>
      <input value={m.draft} onInput={.draft} placeholder="A note" />
      <button>Add</button>
    </form>
    <ul>
      {...m.notes.map fun n =>
        keyed (toString n.id) <li>{n.text}{" "}<button onClick={.remove n.id}>×</button></li>}
    </ul>
  </main>

def program : Program Model Msg := { init := fun _ => ({}, .none), update, view }

end Notes
```

Things to notice:

- `onSubmit` prevents the browser's form navigation and hands Lean the form's fields; here only
  the message matters.
- `value={m.draft}` sets the input's *property*, so the field follows the model after the user
  types (an attribute would only set the initial value).
- Whitespace between tags (or between `{…}` and a tag) never makes a text node, so the space
  before the remove button is written `{" "}`.
- `keyed` gives each row a key, so removing a note removes exactly its `<li>` and moves nothing.
  For long lists, make rows lazy as well: `keyedLazy k n.text fun _ => row n` skips building and
  diffing a row while its key and dependencies are equal.

## 3. Test it natively

The DOM model in `LeanUI.Testing` applies the command buffers exactly as the browser runtime
does, so an app can be tested without a browser:

```lean
import LeanUI.Testing.Harness
import Notes
open LeanUI LeanUI.Testing

def main : IO UInt32 := do
  let r ← run Notes.program
  r.fire (← r.find "placeholder" "A note") "input" "buy milk"
  r.fire (← r.find "placeholder" "A note") "submit" "" -- from the input, it bubbles to the form
  r.check (Notes.view { notes := #[⟨1, "buy milk"⟩], nextId := 2 }) "after adding"
  return 0
```

`check` fails unless the DOM equals the view, the protocol was followed, and no node handle or
listener slot leaked. `tests/TodoMVC.lean` is a complete example, including effects.

## 4. Build and run it in the browser

```bash
./.lake/build/bin/leanui build NotesApp notes   # dist/notes/: index.html, leanui.js, app.js, app.wasm
./.lake/build/bin/leanui serve dist/notes       # http://127.0.0.1:8000/
```

The page needs no special headers. `window.__leanui.stats` counts flushes and commands.

## 5. Effects and subscriptions

`update` returns commands; their results come back as messages. To keep the notes across
reloads, store them as JSON:

```lean
meta import LeanUI.Json.Derive        -- with `public import LeanUI.Json`

structure Note where
  id : Nat
  text : String
  deriving ToJson, FromJson

inductive Msg | ... | loaded (json : Option String)

def save (m : Model) : Cmd Msg := .storageSet "notes" (Json.encode m.notes)
-- in update: return `save m'` from every message that changes the notes, and handle
--   | .loaded (some s), m => match Json.decode (Array Note) s with ...
def init (_ : String) : Model × Cmd Msg := ({}, .storageGet "notes" .loaded)
```

Subscriptions are what the app listens to *now*, recomputed after every update:
`subscriptions m := if m.autosave then .every 5000 .tick else .none`. In a module that opens
`LeanUI`, write the type as `LeanUI.Sub Msg`.

## 6. Serve it from Lean

The same program renders to HTML on a native Lean server, which then lets the wasm build adopt
the page (hydration) or, in a browser without Memory64, runs the program itself:

```lean
import LeanUI.Server
import Notes
open LeanUI LeanUI.Server

def main : IO Unit := do
  let sessions ← Sessions.new {}
  let stopReaper ← sessions.startReaper
  let site : Site := { title := "Notes", assets := some "/assets/notes/" }
  serve { port := 8080 } (Route.first [
      Static.file "/leanui.js" "dist/notes/leanui.js",
      Route.under "/assets/notes" (Static.route { root := "dist/notes" }),
      Route.under "/notes" (program "notes" Notes.program site sessions),
      sessions.route "/leanui"])
    (onShutdown := do stopReaper; sessions.closeAll)
```

`/notes` picks wasm or the server; `/notes/wasm`, `/notes/server` and `/notes/ssr` force one.
`docs/SERVER.md` covers sessions, limits and the server-rendering contract, and
`examples/SiteServer.lean` serves a routed multi-page app the same way.

## Where to go next

- `docs/SYNTAX.md`: every template feature (components, fragments, conditional children, SVG).
- `examples/TodoMVC.lean`: routing in the fragment, storage, editing with focus, and
  `examples/TodoMVCProofs.lean`, which proves an invariant of its `update` for every message.
- `examples/Site.lean`: components (`Html.map`, `Cmd.map`, `Sub.map`), path routing, fetch, SVG.
