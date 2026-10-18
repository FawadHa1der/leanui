# LeanUI: design and contracts

LeanUI is a UI framework for Lean 4. An app is a pure Elm-architecture `Program` written in Lean;
it compiles to **single-threaded wasm64** (Memory64, no `-pthread`, mimalloc) and drives the
browser DOM through a binary command protocol, or runs natively on a Lean server that renders
the same view to HTML and can drive the page remotely. This file is the contract every part of
the codebase is built against. It was written on 2026-10-18 from the research in
`../research/reports/Lean as a general web framework.md`.

## 1. Architecture

```
          Lean (pure)                                         Browser (runtime/leanui.js)
 Program.update/view ──> Html Msg ──> Diff (DiffM, pure) ──> Buf (u32 words + UTF-8 strings)
        ^                                                        │  flush (wasm: zero-copy view;
        │ Msg (decoded from payload)                              │   server: HTTP response body)
 Instance.event/callback <── slot/callback id + payload string <──┘  applier, delegated events,
                                                                      effects, hydration
```

- **View** (`LeanUI.Html`): `Html Msg` = text | elem (ns, tag, attrs, kids) |
  lazy (key?, deps : Dep, thunk). `Dep` is a closed, exactly compared value (`ToDep` builds one
  from naturals, strings, booleans, options, pairs, lists), never a hash; a lazy node carries its
  own key so keyed lists of lazy rows reconcile without rendering them (`keyed k h`).
  Attributes: `.attr` (setAttribute), `.prop` (DOM property), `.on event handler`, `.key`.
  A `Handler` says which part of the event the browser extracts (`Payload`) and decodes that
  string to `Option Msg`.
- **Protocol** (`LeanUI.Patch`, normative spec `docs/PROTOCOL.md`): one `Buf` per update.
  Handles and listener slots are allocated by Lean; no command needs a reply. Names interned per
  session (`INTERN` is emitted before the command that first uses a name).
- **Diff** (`LeanUI.Diff`): pure `StateM`. Positional children unless every child on both sides
  has a unique key; keyed children trim prefix/suffix and use `LeanUI.Keyed.plan` (LIS stable
  set), applied right to left. `lazy` skipped (not rendered, not diffed, handlers kept) while
  key and `deps` are equal. Before any monadic work, a pure fuel-bounded check (`sameF`, at most
  `sameBudget` nodes per call) recognises subtrees that need no command; they keep the *same*
  mounted node and only have their listener slots re-pointed (`rebind`), runs of such siblings in
  one state update. The bound keeps total re-checking linear. Hydration mode mounts without
  creating (claims pre-order nodes).
- **Runtime** (`LeanUI.App`): `start p host flags selector hydrate : IO Instance`. State lives in
  a ref created in `start` and is taken out (unique) for each step; never in an `initialize`d
  global (persistent refs mark contents multi-threaded; MT objects are never exclusive, so every
  `Array.push` would copy). Commands and subscriptions encode into the same `Buf`.
- **SSR** (`LeanUI.Render`): `Html.render`, with `<!--|-->` between adjacent texts and `<!--t-->`
  for empty texts, so the browser's pre-order walk meets exactly the nodes `mount` allocates.
- **Hosts**: `LeanUI.Host.Wasm` (browser; `leanui_app p` defines the export the C shim calls),
  `LeanUI.Server` (native Lean `Std.Http`: SSR, static files, server-driven sessions).
- **Toolchain**: `toolchain/build-archives.sh` builds the single-threaded wasm64 `libleanrt`,
  `libInit`, `libStd`, `libuv` from the fork pinned in `toolchain/fork.lock` plus
  `lean-wasm-threads.patch`; `tools/build-app.sh` links an app (`dist/<name>/`).

## 2. Frozen interfaces (change only with a note in this file)

- `LeanUI.Html` types and smart constructors; `LeanUI.Attr.*` helpers (additions allowed).
- `LeanUI.Patch` opcodes and operand layouts (additions allowed with new numbers; never renumber).
- `LeanUI.Keyed.Plan` fields `src`, `removed`, `move` and their meaning (the diff relies on them).
- `LeanUI.Program`, `Host`, `Instance`, `start`, `Cmd`, `Sub` constructors (additions allowed).
- Browser globals: `LeanUI.start`, `LeanUI.connect`, `LeanUI.boot`, `LeanUI.__flush`.
- Remote protocol (server-driven): `POST <endpoint>/<session>` with a text body
  `h` (hydrate) | `e\n<slot>\n<payload>` | `c\n<cb>\n<0|1>\n<payload>`; the response body is
  `Buf.encode` (`[u32 opsBytes][ops][strs]`), possibly empty.

## 3. Conventions

- Every Lean file is a `module` with `public section`; imports directly after `module`.
- Runtime code imports only `Init` and `Std` (never `Lean.*`: a runtime `Lean` import links the
  whole compiler, about 104 MB). Compile-time code (macros) lives in modules the app reaches only
  through `meta import`, which keeps it out of the binary (measured: 0 `initialize_Lean`
  references, 1.1 MB native binary).
- No `initialize` globals on runtime paths. Hot loops keep arrays uniquely owned (`modifyGet`,
  not `get` then `modify`).
- Tests: `lake build` must stay warning-free in new code; `.lake/build/bin/leanui-tests` must pass.
- Browser runs go through the host lock:
  `"/Users/fawadhaider/code/lean questions/infoview-widget-research/widgets-v4.34/qed64-showcase/scripts/with-browser-lock.sh" <lane> <cmd>`.
  Playwright is imported read-only from QED64's `node_modules`
  (`createRequire("/Users/fawadhaider/code/wasm64-lean-fable/qed64/package.json")`).
- Lean binaries by absolute path: `~/.elan/toolchains/leanprover--lean4---v4.34.0/bin/{lake,lean,leanc}`
  (a bare `lean`/`lake` outside a `lean-toolchain` folder makes elan download a toolchain).
- Archives: `LEANUI_TOOLCHAIN` (default `<repo>/.toolchain`); from a worktree set it to
  `/Users/fawadhaider/code/wasm64-lean-fable/leanui/.toolchain`.
- Commits end with the session's `Co-Authored-By` line. Never `git push`. Never `npm install`.
  Kill processes by PID only.

## 4. Module map and ownership

| Module / file | Role | Owner |
|---|---|---|
| `LeanUI/{Html,Patch,Keyed,Diff,Effect,App,Render}.lean`, `runtime/*`, `tools/build-app.sh` | core | coordinator |
| `LeanUI/Syntax.lean`, `tests/Syntax.lean` | JSX-style templates (meta only) | syntax lane |
| `LeanUI/Proofs/Keyed.lean` | machine-checked reconciliation | proofs lane |
| `LeanUI/Testing/Gen.lean`, `tests/Props.lean` | property tests and fuzzing | testing lane |
| `LeanUI/Router.lean`, `LeanUI/Json.lean`, `tests/browser/effects.mjs`, `examples/Effects.lean` | routing, JSON, effects | effects lane |
| `LeanUI/Server.lean`, `LeanUI/Server/*.lean`, `cli/Main.lean`, `tests/browser/server.mjs` | native server: SSR, static, server-driven sessions; `leanui` CLI | server lane |
| `examples/TodoMVC.lean`, `examples/Bench.lean` | flagship examples | examples lane |
| `bench/*` | js-framework-benchmark-style harness (script + paint) | bench lane |
| `docs/*`, `README.md` | documentation | docs lane |
