# LeanUI: design and contracts

LeanUI is a UI framework for Lean 4. An app is a pure Elm-architecture `Program` written in Lean;
it compiles to **single-threaded wasm64** (Memory64, no `-pthread`, dlmalloc) and drives the
browser DOM through a binary command protocol, or runs natively on a Lean server that renders
the same view to HTML and can drive the page remotely. This file is the contract the codebase is
built against. It was first written on 2026-10-18 from the research in
`../research/reports/Lean as a general web framework.md`, and updated as the system was built.

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
  lazy (key?, deps : Dep, thunk). Attributes: `.attr` (setAttribute), `.prop` (DOM property),
  `.on event handler`, `.key`; when a name or an event repeats, the last one wins everywhere
  (mount, patch, render, hydration). A `Handler` says which part of the event the browser
  extracts (`Payload`) and decodes that string to `Option Msg`. `Dep` is a closed, exactly
  compared value (`ToDep` builds one from naturals, strings, booleans, options, pairs, lists),
  never a hash; a lazy node carries its own key (`keyed k h`, or directly `keyedLazy k deps
  render`), so a keyed list of lazy rows reconciles without rendering them, and the key is
  compared like a dependency (rows may leave the key out of their deps; tests/Main.lean's
  `testKeyContract` and `keyedLazyNoId` lists pin this). Void elements (`input`, `br`, …) get no children
  (`effectiveKids`), whatever the view says, in the DOM, in rendered HTML and in hydration alike.
- **Templates** (`LeanUI.Syntax`, `docs/SYNTAX.md`): JSX-style syntax, compile-time only
  (`meta import`); it expands to the constructors above, so the generated C equals the
  hand-written view's.
- **Protocol** (`LeanUI.Patch`, normative spec `docs/PROTOCOL.md`): one `Buf` per update.
  Handles and listener slots are allocated by Lean; no command needs a reply. Names interned per
  session (`INTERN` is emitted before the command that first uses a name). Strings are sliced in
  UTF-16 units, so the browser decodes the string area once per flush.
- **Diff** (`LeanUI.Diff`): pure `StateM`. Children are keyed when every child on both sides has a
  key and the keys are unique on each side, positional otherwise. Keyed lists whose keys did not
  change order are patched pairwise without allocating; otherwise the common prefix and suffix
  are patched in place and the middle is planned by `LeanUI.Keyed.plan` (an LIS stable set,
  proved correct and optimal in `LeanUI.Proofs.Keyed`) and applied right to left. A `lazy` node
  is skipped (not rendered, not diffed, handlers kept) while its key and `deps` are equal.
  Repeated subtrees are created from templates: the second subtree of a shape (4 to 64 nodes:
  tags, attribute and property names, structure) is built as a prototype (no properties or
  listeners yet) that becomes the template, and every copy, the prototype included, is finished
  with the texts and attribute values that differ, the properties and listeners
  (`docs/PROTOCOL.md`, section 7); a clone yields exactly the mounted node and, in a browser, the
  DOM a plain mount would (the tests compare both, natively and in Chromium and Firefox).
  Before any monadic work, a pure check (`unchanged`: `sameF` on subtrees whose cached size is
  within `sameBudget`) recognises subtrees that need no command; they keep the *same* mounted node
  and only have their listener slots re-pointed (`rebind`), runs of such siblings in one state
  update. Because sizes are cached, re-checking stays linear at any depth. Hydration mode mounts
  without creating (claims pre-order nodes); the claim command is prepended after the mount, with
  the mounted size, so each lazy thunk runs once.
- **Runtime** (`LeanUI.App`): `start p host flags selector hydrate : IO Instance`. State lives in
  a ref created in `start` and is taken out (unique) for each step; never in an `initialize`d
  global (persistent refs mark contents multi-threaded; MT objects are never exclusive, so every
  `Array.push` would copy). Commands and subscriptions encode into the same `Buf`. Subscriptions
  are reconciled per update and grouped by identity: one browser subscription per identity
  (`url`, `every:<ms>`), whose callback delivers a message to every part of the app that asked.
- **SSR** (`LeanUI.Render`): `Html.render`, with `<!--|-->` between adjacent texts and `<!--t-->`
  for empty texts, so the browser's pre-order walk meets exactly the nodes `mount` allocates;
  only the last of repeated attributes, `\r` as `&#13;`, a doubled leading newline in `pre`,
  `textarea` and `listing` (the parser drops one).
- **Browser runtime** (`runtime/leanui.js`, about 6 KB brotli): applies buffers in one pass
  (a `class` attribute on an HTML element is written through `className`, which needs no name
  lookup; a run of `REMOVE`s that empties a parent in order is one `replaceChildren()`, the same
  DOM, but page code sees one `MutationObserver` record for it, and custom elements'
  `disconnectedCallback`s run after all the removals instead of after each one); one
  delegated listener per event type on the container, in the capture phase for events that do
  not bubble, which then reach their target's listener only; payloads extracted in the browser
  (`value`, `checked`, `key`, the `name=value` lines of the element's form); strings cross into
  wasm as UTF-8 bytes plus length (a payload may contain U+0000). An update that throws (in
  practice: a view nested about a thousand levels deep overflows the browser's native stack) is
  reported once, the instance is no longer called, and the container receives a `leanui:error`
  event.
- **Hosts**: `LeanUI.Host.Wasm` (browser; `leanui_app p` defines the export the C shim calls),
  `LeanUI.Server` (native Lean `Std.Http`: SSR, static files, server-driven sessions as actors;
  `docs/SERVER.md`). A server-driven page reloads once when its session has expired (HTTP 410).
- **Toolchain** (`docs/TOOLCHAIN.md`): `toolchain/build-archives.sh` builds the single-threaded
  wasm64 `libleanrt`, `libInit`, `libStd`, `libuv` from the fork pinned in `toolchain/fork.lock`
  plus `lean-wasm-threads.patch`; `tools/build-app.sh` links an app (`dist/<name>/`).

### Browser lifetime

The in-page Wasm callbacks use the single `LeanUI.active` slot; one active app per page is
supported. Starting another app does not dispose the previous one. Call `dispose()` before
replacing a running app. The Wasm host uses the synchronous `Runtime.start(boot)` boundary
once its module is loaded; `boot` must finish synchronously. It holds input until the initial
output is applied, then drains queued input. Failed startup disposes the new runtime and
restores the previous live owner. If an error handler has installed a newer runtime,
cleanup preserves that owner. This restores runtime ownership, not DOM changes already applied
to a mount; failed startup is not a DOM transaction.

`Runtime.dispose()` is an idempotent close request. It sets `disposed`, aborts cancellable
browser work and relinquishes the active slot immediately. New input, output and callbacks
cannot enter the runtime after closure.

A synchronous operation already running may finish its current DOM opcode or event handler;
that includes a coalesced removal batch. It starts no following opcode or ancestor handler.
The runtime keeps its handle tables and transport valid until the outermost synchronous entry
unwinds. Its `finally` boundary then cancels owned timers and frames, revokes object URLs,
clears the tables and releases the backend exactly once. With no entry in progress, `dispose()`
releases immediately. Callers inside a DOM callback therefore observe a closed runtime whose
resources are still valid until the callback and enclosing runtime call return.

All synchronous entries balance entry/exit in `try/finally`; internal opcode helpers run within
that boundary. This avoids checks between a DOM call and the state writes that complete its
opcode. Entries never span `await`. Async completions independently check closure before
resuming runtime work; temporary `ImageBitmap` and `VideoFrame` handles close in `finally`.
Disposal retains the last DOM, including completion of the in-flight opcode. The caller owns
removing the mount. No DOM rollback is promised.

A transport's `isTerminalError(error)` query classifies a thrown update error; an absent query
means recoverable. Wasm update errors are terminal; a recoverable transport error is logged
and allows later input. Terminal errors close the runtime, release it on unwind, then emit
one `leanui:error` on its former container. Transport cleanup exceptions are logged and do not
replace the application's primary error. An optional transport
`dispose()` releases backend resources after browser work has stopped. Wasm drops its module
reference (memory is reclaimed by JS garbage collection); a remote session expires on the
server's normal timeout. Intentional disposal is quiet. A synchronously cancelled startup rejects
with `AbortError`; a terminal failure preserves its original error. Initial script/module loading
has no general cancellation handle; callers must still account for a pending load when replacing
a page. Backend adapters must opt into the transport hooks to release their own resources.

`tests/browser/runtime-lifecycle.mjs` checks shared startup, disposal and async lifetime races
without compiled apps in Chromium and Firefox. `tests/browser/counter.mjs` and
`tests/browser/depth.mjs --lifecycle-only` check startup failure and terminal overflow through
compiled Wasm apps.

## 2. Frozen interfaces (change only with a note in this file)

- `LeanUI.Html` types and smart constructors; `LeanUI.Attr.*` helpers (additions allowed).
  `LeanUI.Input` (2026-10-19): `Pointer`, `FileInfo`, `Keys` and their parsers, `Attr.onPointer`,
  `onWheel`, `onFiles`, `onDrop`, `onDragOver`.
  2026-10-18: `Html.lazy` gained a key and its dependencies became an exact `Dep` (was `UInt64`).
  Added: `keyedLazy`, `keyedMemo` (a keyed lazy node in one constructor) and the constant
  dependencies `Dep.boolTrue`, `Dep.boolFalse`, `Dep.optNone`.
- `LeanUI.Patch` opcodes and operand layouts (additions allowed with new numbers; never renumber).
- `LeanUI.Keyed.Plan` fields `src`, `removed`, `move` and their meaning (the diff relies on them).
- `LeanUI.Program`, `Host`, `Instance`, `start`, `Cmd`, `Sub` constructors (additions allowed).
  2026-10-19: added `Host.blobs` (byte arrays a buffer's commands refer to), `Instance.callbackBytes`,
  `Cmd.putImage`, `Cmd.download`, `Cmd.readFile`, `Cmd.decodeImage`, `Sub.keys`, payloads
  `files` and `pointer`, and `Handler.capturePointer` (`docs/PROTOCOL.md`, sections 4 and 8).
  Then `Cmd.grabFrame` (a `<video>`'s current frame as RGBA, with its timestamp) and
  `Cmd.fileUrl` (an object URL for a file), ops 53 and 54.
- Browser globals: `LeanUI.start`, `LeanUI.connect`, `LeanUI.boot`, `LeanUI.__flush`.
- The wasm exports (`runtime/leanui_wasm.c`): `leanui_boot(flags, flagsLen, selector,
  selectorLen, hydrate)`, `leanui_event(slot, payload, len)`, `leanui_callback(cb, ok, payload,
  len)`; strings are malloc'd UTF-8 bytes that C frees. (2026-10-18: lengths added.)
  2026-10-19: `leanui_callback_bytes(cb, ok, payload, len, bytes)` with `bytes` a `ByteArray`
  from `leanui_bytes_alloc(len)` (filled through `leanui_bytes_data(bytes)`), which Lean then
  owns; and the import `LeanUI.__blob(index, address, length)` before a flush with blobs.
- Remote protocol (server-driven): `POST <endpoint>/<session>` with a text body
  `h` (hydrate) | `e\n<slot>\n<payload>` | `c\n<cb>\n<0|1>\n<payload>`; the response body is
  `Buf.encode` (`[u32 opsBytes][ops][strs]`), possibly empty; errors carry a status and a buffer
  that logs the reason.

## 3. Conventions

- Every Lean file is a `module` with `public section`; imports directly after `module`.
- Runtime code imports only `Init` and `Std` (never `Lean.*`: a runtime `Lean` import links the
  whole compiler, about 104 MB). Compile-time code (templates, JSON deriving) lives in modules the
  app reaches only through `meta import`, which keeps it out of the binary.
- No `initialize` globals on runtime paths. Hot loops keep arrays uniquely owned (`modifyGet`,
  not `get` then `modify`). `update` gets the model uniquely owned (`LeanUI.App.updateModel`;
  `tests/Kit.lean`, "update owns the model"), so an app whose model holds pixels updates them in
  place if it takes the model apart (`match m with | { img, .. } => …`) rather than reading
  `m.img` and then building `{ m with img := … }`, which keeps the old `m` alive meanwhile. It
  gets each message unshared too (`LeanUI.App.stepMsgs` pops them off the queue with
  `popLast`, a call the compiler cannot reorder; `tests/Kit.lean`, "update owns the message"), so
  bytes in a message, such as a video frame, are written in place. Code that runs once per created or removed node (mounting, cloning,
  releasing, placing a keyed list's middle) passes `DiffState` explicitly instead of running in
  `DiffM`, one `@[noinline]` function per state update (2026-10-18; `LeanUI.Diff`, "State
  passing"; `docs/BENCHMARKS.md`, "Allocations").
- `lake build` builds and checks everything (library, examples, tests, proofs) warning-free; the
  test executables are listed in the README.
- Browser runs go through the host lock:
  `"/Users/fawadhaider/code/lean questions/infoview-widget-research/widgets-v4.34/qed64-showcase/scripts/with-browser-lock.sh" <name> <cmd>`.
  `tests/browser/playwright.mjs` loads Playwright: from `LEANUI_PLAYWRIGHT_FROM` (a `package.json`
  whose `node_modules` has it; CI installs one), else from QED64's `node_modules`, read-only.
  `tests/browser/run-all.sh` runs every suite. Playwright's
  Firefox build runs wasm about 8x slower than release Firefox: use it for correctness, and
  `tests/browser/selfbench.mjs` (release browsers, no automation) for speed.
- Lean binaries by absolute path: `~/.elan/toolchains/leanprover--lean4---v4.34.0/bin/{lake,lean,leanc}`
  (a bare `lean`/`lake` outside a `lean-toolchain` folder makes elan download a toolchain).
- The command buffer's byte primitives (`pushU32`, `appendUtf8` in `LeanUI.Patch`) are
  `@[extern c inline]` (2026-10-18): code that writes a `Buf` (mount, diff, `LeanUI.Testing`)
  needs the compiled LeanUI library. Executables and wasm link it; `#eval` and `lean --run` need
  it loaded (`lake build LeanUI:shared`, then
  `lake env lean --load-dynlib=.lake/build/lib/libleanui_LeanUI.dylib …`, `.so` on Linux), and a
  downstream library with `precompileModules = true` loads it by itself, in `lake build` and in
  the editor. Views and `Html.render` stay interpretable without it.
- Archives: `LEANUI_TOOLCHAIN` (default `<repo>/.toolchain`).
- Commits end with the session's `Co-Authored-By` line. Never `git push`. Never `npm install`.
  Kill processes by PID only.

## 4. Module map

| Module / file | Role | Tests |
|---|---|---|
| `LeanUI/{Html,Patch,Keyed,Diff,Effect,Input,App,Render}.lean`, `runtime/*` | core | `leanui-tests`, `leanui-props`, `tests/browser/{counter,keyed-dom,fuzz,templates,depth,apply-semantics}.mjs` |
| `LeanUI/Syntax.lean` | JSX-style templates (compile time only) | `leanui-syntax-tests` |
| `LeanUI/Proofs/Keyed.lean` | machine-checked keyed reconciliation | `lake build` |
| `LeanUI/Testing/*` | DOM model, harness, generators, reference model, protocol checker, SSR parser | `leanui-props` |
| `LeanUI/Router.lean`, `LeanUI/Json.lean`, `LeanUI/Json/Derive.lean` | routing, JSON | `leanui-kit-tests`, `tests/browser/effects.mjs` |
| `LeanUI/Server.lean`, `LeanUI/Server/*.lean`, `cli/Main.lean` | native server, SSR pages, sessions, `leanui` CLI | `leanui-server-tests`, `tests/browser/server.mjs` |
| `examples/TodoMVC.lean`, `examples/TodoMVCProofs.lean` | TodoMVC and its proved invariants | `leanui-todomvc-tests`, `tests/browser/todomvc.mjs` |
| `examples/Site.lean`, `examples/SiteServer.lean` | the LeanUI site (`leanui-site`) | `tests/browser/site.mjs` |
| `examples/Pixels.lean` | the pixels lab: canvas, pointer, files, downloads, keys | `leanui-kit-tests`, `tests/browser/pixels.mjs` |
| `examples/Editor.lean`, `examples/Editor/*.lean` | LeanUI Photo: image operations, PNG, layers, jobs, the editor | `leanui-editor-tests`, `tests/browser/editor.mjs` |
| `examples/Video.lean` | the video lab: the editor's filters on every frame of a video | `leanui-editor-tests`, `tests/browser/video.mjs` |
| `examples/Bench.lean`, `bench/*` | the benchmark app, the vanilla reference, the runner | `leanui-perf`, `tests/browser/{bench,selfbench,bench-smoke}.mjs` |
| `examples/Life.lean`, `bench/race/*` | Game of Life on 1,000 cells; the race page (its lanes in `bench/race/lanes.mjs`: vanilla, wasm64, lean-vir side by side, and QED64 when asked for) | `leanui-kit-tests`, `tests/browser/race.mjs` |
| `vir/*` | the benchmarked apps on lean-vir (Lean 4.35, apart from the main build; `vir/README.md`) | `tests/browser/race.mjs` |
| `qed64/*` | the benchmarked apps on Lean's own interpreter in QED64's wasm64 Lean (Lean 4.35, apart from the main build; `qed64/README.md`) | `qed64/test/node.mjs`, `tests/browser/race.mjs` |
| `toolchain/*`, `tools/*` | wasm64 archives, app builds, site data | |

## 5. Limits

- **Browsers**: Memory64 is required for the wasm build (Chrome/Edge 133+, Firefox 134+); Safari
  gets the server-driven mode.
- **Nesting**: a view nests about 1,050 levels in Chromium and 1,700 in Firefox before an update
  overflows the browser's native stack (the diff recurses once per level); the app then stops
  with a `leanui:error` event.
- **Memory**: wasm memory never shrinks. The benchmark app uses 16 MB at load and about 28 MB
  after creating 10,000 rows (dlmalloc); see `docs/BENCHMARKS.md`.
- **Server**: Lean 4.34's `Std.Http` serves about 2,000–3,000 requests per second; a
  server-driven event costs about 1–2 ms round trip on localhost.
- **Markup the HTML parser rewrites** (a `tr` directly in a `table`, a `div` in a `p`, elements in
  a `textarea`) cannot be server-rendered faithfully; `docs/SERVER.md` lists the cases.
