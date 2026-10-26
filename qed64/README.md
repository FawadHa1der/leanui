# LeanUI on Lean's own interpreter, in QED64's wasm64 Lean

A fourth way to run a LeanUI program, kept for the race (`bench/race/`). The site and every app ship
the wasm64 build (Lean → C → wasm64, `tools/build-app.sh`), and `vir/` runs the same source in
lean-vir. This directory runs it in Lean itself: [QED64](https://github.com/FawadHa1der/qed64)'s
build of Lean 4.35 for the browser (`lean.wasm`, wasm64 with threads) runs `lean --run` on a
three-line file, and Lean's IR interpreter runs the program, LeanUI's diff and the buffer writers.
Only `Init` and `Std` run as compiled code, inside `lean.wasm`.

The library and the apps do not depend on this directory, and it changes nothing in them: it
compiles `../LeanUI` (through a shim, below) and the benchmarked programs (`examples/Bench.lean`,
`examples/Life.lean`) unchanged. Nothing large is committed: `qed64.lock.json` pins every download
by size and sha256, and downloads and builds go to `qed64/.cache` (ignored by git) and `dist/qed64`.

It has the Lean side, the build, a Node test and the browser side: a Worker and a page for each
app, in `dist/qed64/{bench,life}/`. The race runs it as an optional lane, `qed64` ("In the race",
below).

## How it runs

| | wasm64 (production) | QED64 (this directory) |
|---|---|---|
| Lean | 4.34.0 (`lean-toolchain`) | 4.35.0 (`qed64/lean-toolchain`): QED64's release `lean-v4.35.0-b081e7c`, a fork of Lean 4.35.0 built for wasm64 |
| What the browser runs | the app compiled to C, then to wasm64 | `lean.wasm` (106 MB, one for both apps) and a header snapshot of LeanUI and both apps (114 MB) |
| Entry | `examples/BenchApp.lean`: `leanui_app Bench.program` | `run/AppsRun.lean`, a plain file run with `lean --run`: `bench` or `life` |
| Host | `LeanUI/Host/Wasm.lean` + `runtime/leanui_wasm.c`: each update read in place from wasm memory | `LeanUIQed/Host.lean`: messages in on stdin, each update out on stdout as `[u32 opsBytes][ops][strs]` (the server's format) |
| Build | `tools/build-app.sh BenchApp bench` → `dist/bench/` | `qed64/build.sh` → `dist/qed64/` |
| Page | `LeanUI.start`: the module in the page, each update applied as Lean makes it | `lane/leanui-qed64.js`: Lean in a Worker (`lane/qed64.worker.js`), each reply applied when it comes |
| Browsers | needs Memory64 | needs Memory64 and a cross-origin isolated page (shared memory, pthreads) |

A session is one run of

    lean -j1 --incr-load=/snap/apps.snap --root=/workspace --run /workspace/AppsRun.lean <app> --out raw --selector #app

in `lean.wasm`'s in-memory file system. It reads no `.olean`: the snapshot holds the environment
after `AppsRun.lean`'s imports, IR included. The host that loads `lean.wasm` (in Node,
`tools/wasm-lean.mjs`) gives it a shared memory of its own, writes messages into Lean's stdin ring and
takes stdout byte by byte; `lane/core.js` is the part that the Node host and the browser Worker
share: the command line, the ring's producer and the parser of the host's replies.

The host's framing (`LeanUIQed/Host.lean`): `e <slot> <n>\n<payload>` is an event,
`c <cb> <0|1> <n>\n<payload>` an effect's result, `p\n` a ping, `q\n` the end. Each message gets one
reply: its updates (`u <n>\n` and the bytes), then `. <leanNs> <encodeNs>\n`, Lean's own time. The
first reply is the mount.

### In the browser

A page (`pages/bench.html`, `pages/life.html`) loads `runtime/leanui.js` and `lane/leanui-qed64.js`.
`LeanUIQed64.start()` reads `qed64.json`, starts the Worker (a classic one: the glue is a classic
script) and resolves once the app is mounted; until then the container says how far it has got. It
rejects, saying why, without Memory64 or cross-origin isolation (COOP and COEP, which
`leanui serve --coop` and the site's `/race` send).

The Worker is Emscripten's main runtime thread, and never blocks: Lean's pthreads proxy their system
calls through it. It does what `startLane()` does in Node. It downloads the snapshot itself and
unpacks it with `DecompressionStream` while `lean.wasm` compiles (from a same-origin URL, not a
Blob, so that it compiles as it downloads), writes the snapshot, its `.deps` and the run file into
MEMFS and starts `main`. Once the mount is out, it deletes MEMFS's copy of the snapshot (114 MB):
Lean holds its own. Every second it kicks the mailbox, as QED64 does (its HARDENING #52: a lost
wakeup).

The transport (`QedTransport`) is asynchronous, like `leanui.js`'s `RemoteTransport`: a message goes
to the Worker at once, into Lean's stdin ring; its reply comes back later, with the updates' buffers
transferred, Lean's own time and the Worker's (from the message reaching it, or the reply before it
leaving if that is later, to its reply leaving), and the page applies the updates with
`Runtime.apply`. `idle()` resolves once every message sent has been answered and applied. If Lean
stops (it exits, `lean.wasm` aborts, an update cannot be applied), `idle()` rejects, the container
gets a `leanui:error` event and the Worker is terminated.

For the race (`bench/race/lanes.mjs`), the page sets `window.__idle` and `window.__lane` before
`window.__ready`:

* `bytes`: what the Worker downloaded, which the page's resource timing does not list (42.0 MB);
* `phases`: the start, in ms: `download` (the snapshot unpacked and `lean.wasm`'s last byte),
  `runtime` (the rest of compiling, the pthreads, the files), `Lean` (loading the snapshot, the
  mount), `DOM` (the mount to the page), `pings`;
* `stats()`: since the mount, the replies and the totals of Lean's time, the Worker's and applying,
  the stalls (replies whose time in the Worker exceeds Lean's own by more than 500 ms: a lost wakeup
  that the kick caught), and `floorMs`, the median of 20 empty round trips taken before `__ready`.

### In the race

`bench/race/build.sh` copies the lane into `dist/race` when `dist/qed64` is built: `rt/` once, as
`qed64-rt/` (hard links, with the `.br` and `.gz` siblings), and the pages as `life/qed64/` and
`table/qed64/`, their `qed64.json` pointing at `../../qed64-rt/`. Without `dist/qed64` it prints a
notice and builds the race without the lane; `QED64=require` makes that an error.

The race page offers the lane with a box under its controls ("Add Lean's interpreter on QED64
(about 42 MB)"), or runs it with `?lanes=vanilla,wasm64,vir,qed64`. Its panel loads last, and the
referee waits 3 s once every panel is ready before the first click, so that the browser can finish
compiling `lean.wasm` in the background. Each click waits until the answer is on the page, and
nothing else is clicked meanwhile; the results split its times into Lean, transport and DOM
(docs/BENCHMARKS.md, "The QED64 lane"). Before loading the lane's page again (Run, another
scenario), the referee empties the panel and waits 2.5 s, because the pthreads of a page outlive
it by about 2 s and two starts' threads would overlap.

`tests/browser/run-all.sh` builds the lane with `--build` (`LEANUI_QED64=0` skips it), serves the
race cross-origin isolated, as the site does, and runs the race with the lane whenever
`dist/race` has it (`LEANUI_QED64=require` makes its absence a failure): in Chromium Life and the
table, in Firefox Life. `tests/browser/race.mjs` also checks that the lane had no stalls and that
its Worker downloaded more than 30 MB itself.

The race page's footer links the two licences `rt/` carries: `LICENSE-lean4.txt`, the Apache
License 2.0 of Lean, from which `lean.wasm` and `lean.js` are built, and `LICENSE-qed64.txt`,
QED64's MIT License.

### In CI and on the site

CI (`.github/workflows/ci.yml`, [docs/DEPLOY.md](../docs/DEPLOY.md)) builds the lane, runs
`test/node.mjs` with the Node `tools/node.sh` prints, and races it, on every push and pull request
(`LEANUI_QED64=require`); a pull request labelled `bench` also races it with `--perf`. It caches
`qed64/.cache` in two parts: per lock (`qed64.lock.json` and `lean-toolchain`), the downloads and
what is made from them alone (Std, `lean.wasm`'s `.br` and `.gz`), about 620 MB; per source, the
rest of the bake and `qed64/.lake`, about 70 MB.

The site serves the race's copy of `rt/`, `dist/race/qed64-rt/`, at `/race/qed64-rt/`, cross-origin
isolated like `/race/` and with year-long `immutable` caching (`examples/SiteServer.lean`).
`deploy/cloudflare/stage.sh`, which deletes the `.br` and `.gz` files it stages and writes new
siblings at brotli 11, leaves `lean.wasm`, its siblings and the snapshot (itself a `.gz`) as
`build.sh` made them. The lane adds 165 MB to the container.

### What breaks under the interpreter, and the shim

`tools/shim.py` writes `qed64/.shim/`, LeanUI's core as `lean.wasm` compiles it, with four edits. It
refuses unless each applies exactly once and no `@[extern` is left.

* LeanUI's two inline-C buffer helpers (`LeanUI.pushU32`, `LeanUI.appendUtf8` in
  `LeanUI/Patch.lean`) become plain `@[inline, expose]` definitions with their Lean bodies. The
  interpreter has no code for an inline-C `extern` ("Could not find native implementation"), and it
  cannot load a native library in wasm. The Lean bodies are LeanUI's own specification of the two,
  so the bytes are the same; `@[inline]` stays because without it the interpreted
  create-1,000-rows takes 11% longer.
* `public import Std.Data.HashMap` becomes `public import Std.Data.HashMap.Basic` in `Patch.lean`
  and `Keyed.lean`. That is all LeanUI uses of it, and its closure is 8 Std modules instead of 134.

The run file is a plain file, not a `module`: a module's imports bring no IR for the interpreter.

## Building

    qed64/build.sh

The steps, each skipped when its inputs have not changed:

1. `tools/shim.py`, then `lake build`: the reference, `bench-host` and `life-host`, the same host
   compiled natively by Lean 4.35.0 against LeanUI as it is (inline C and all). Lake runs on the
   toolchain `qed64/lean-toolchain` names (elan installs it, as for `vir/`); `qed64/.lake` holds the
   build.
2. `tools/node.sh` prints the Node that runs `lean.wasm` (Node 24, for Memory64 without a flag),
   downloading the pinned release first. The rest of the tools run on it.
3. `tools/fetch.mjs` downloads `lean.js`, `lean.wasm` (7 chunks), the licences and QED64's `Init`
   (the `lean-core` pack, 653 modules), checking every chunk and every file against the lock, and
   unpacks them into the cache. Sources: the release's GitHub assets, then QED64's own site.
4. `tools/bake.sh`, with `lean.wasm` under Node (`tools/wasm-lean.mjs make`, one process per module,
   in dependency order, in parallel):
   * the 8 Std modules, from the toolchain's sources. Each facet must equal QED64's own build of it
     (the digests in the lock), or the build stops. The exception is `.olean.private`, which
     `lean.wasm` writes a few hundred bytes apart from the native build QED64's packs come from;
     nothing the lane runs reads it (only `import all` does).
   * LeanUI's shimmed core, Bench, Life and `LeanUIQed.Host`;
   * the bake: `lean --incr-header-save` of `run/AppsRun.lean`, laid out as every session lays it
     out (the snapshot records its main module's name), against `Init`'s and `Std`'s `.olean` files
     alone. With their other facets too, the snapshot would also hold their server and private data:
     352 MB instead of 114 MB. Then `gzip -9`.
   * `lean.wasm.br` (brotli 9) and `lean.wasm.gz`, for servers that send precompressed files.
5. `dist/qed64/`: `rt/`, shared by both apps under content-hashed names (`lean.<h>.js`,
   `lean.<h>.wasm` with its `.br` and `.gz`, `apps.<h>.snap.gz` with its `.deps`,
   `AppsRun.<h>.lean`, `qed64.worker.<h>.js`, `core.<h>.js`, `LICENSE-lean4.txt`, `LICENSE-qed64.txt`);
   `bench/` and `life/`, each the app's page (`index.html`), `leanui.js`, `leanui-qed64.js` and
   `qed64.json`, what a session loads; and the pages' stylesheets one level up, where the race has
   them. The large files are hard links into the cache. A server must send `lean.wasm`'s `.br` or
   `.gz` (`leanui serve` and the site do): unpacked it is 106 MB, and Chrome then downloads it
   again on every load.

The cache is `qed64/.cache` (about 700 MB: `Init` unpacked, the runtime, Node, the build), or
`$LEANUI_QED64_CACHE`, which several checkouts can share. `LEAN_BIN` overrides the toolchain. Behind
an HTTPS proxy `build.sh` sets `NODE_USE_ENV_PROXY=1`, because Node's `fetch` ignores
`HTTPS_PROXY` otherwise.

| Build (CI machine, a 4-core cloud VM shared with other jobs; to be re-measured on the reference Mac) | Time |
|---|---|
| downloads, once per lock: 226.6 MB (plus 32 MB for Node) | 19 s |
| Std with `lean.wasm`, once per lock | 45 s |
| LeanUI, the apps and the host, the bake, `gzip -9` of the snapshot: after any change to them | 2 min |
| `lean.wasm`'s `.br` and `.gz`, once per lock | 29 s |
| nothing changed | 1.4 s |

## Tests

    "$(qed64/tools/node.sh)" qed64/test/node.mjs [--out file.json]

It boots sessions from `dist/qed64/` as the page does (`tools/wasm-lean.mjs lane`: the page's
config, the snapshot and the run file in memory where the browser puts them, the same command
line), and drives each one and the compiled reference through the same messages:

1. 8 scenarios: Life (reset, then 100 steps) and Bench's keyed operations that click only its
   buttons (`bench/ops.mjs`: create 1,000 rows, replace them, update every 10th, swap, create
   10,000, append 1,000, clear). Every update must be byte-identical to the reference's, and Life's
   board after 100 steps must be `bdbe4aa6`, as natively.
2. 20 pings, each answered with an empty reply; their median is the round trip's floor.
3. Create 10,000 rows with each pthread's stack cut to 0.49 MiB, about what a Chrome Worker has.

It takes about 30 s and prints Lean's time per operation next to the compiled reference's.

In a browser, by hand: `.lake/build/bin/leanui serve dist --coop`, then `/qed64/life/` and
`/qed64/bench/`. Their buttons work as in the other builds; `window.__lane.stats()` has the figures.

## Limits

* It is Lean's interpreter: about 150× slower than compiled code in Life, and 65-130× in the keyed
  operations on 1,000 rows (Numbers, below).
* A visitor downloads about 42 MB (`lean.wasm` 11.0 MB with brotli, the snapshot 30.9 MB gzipped),
  and a session holds `lean.wasm`'s 256 MiB memory and more. That is why it is an optional lane.
* The interpreter's recursion runs on the JavaScript engine's stack, with no guard on the way. In
  Node a session boots with more than 0.3 MiB of pthread stack and creates 10,000 rows with more
  than 0.4 MiB (it passes at 0.45); a Chrome Worker has about 0.5 MiB. In Playwright's Chromium 141
  and Firefox 142 it creates 10,000 rows.
* Effects that answer with bytes (`Cmd.readFile`, `Cmd.decodeImage`) are not carried, as in `vir/`;
  the benchmarked apps need none. Apps with inline C of their own (the photo editor, the video lab)
  would need the shim's treatment.

## Updating QED64

A snapshot and every `.olean` belong to one runtime build, so a new QED64 release means a new lock:

1. In `qed64.lock.json`, from the new release's `toolchain/lean4-wasm64-release.json` and the
   manifests it names: `release` and `qed64`; `runtime` (`public/runtime/runtime-manifest.json`,
   its chunks); `init` (`profiles/lean-core.manifest.json`: its own size and sha256, the pack's and
   the transport's, the parts); `std` (`profiles/lean-lib.manifest.json`, `content.modules`, every
   facet but `.olean.private`); the licences at the new commits.
2. `qed64/lean-toolchain`: the release's Lean version.
3. `qed64/build.sh` (the cache keys on the lock: everything is fetched and rebuilt), then
   `qed64/test/node.mjs`.

`tools/wasm-lean.mjs` relies on details of the runtime's JavaScript glue that the fork documents as
its embedding contract (`EMBED-RUNTIME.md` in its `wasm64-build/`): the stdin ring, the TTY's
`put_char`, the proxied exit functions, `waitAsyncPolyfilled`. A new release's notes say when they
change.

## Numbers

Node 24.22.1 on the CI machine (to be re-measured on the reference Mac), `qed64/test/node.mjs`:
Lean's own time per operation (the host's `leanNs`: update, view, diff and buffer), medians.

| | lane (interpreted, wasm64) | compiled (native) | ratio |
|---|---|---|---|
| Life, one step | 20.8 ms | 0.14 ms | 151× |
| create 1,000 rows | 190 ms | 1.5 ms | 130× |
| replace 1,000 rows | 333 ms | 2.9 ms | 116× |
| update every 10th row | 33 ms | 0.36 ms | 91× |
| swap 2 rows | 47 ms | 0.43 ms | 108× |
| create 10,000 rows | 1,926 ms | 151 ms | 13× |
| append 1,000 rows | 240 ms | 2.4 ms | 101× |
| clear 1,000 rows | 46 ms | 0.72 ms | 64× |

The compiled create-10,000 varies most between runs (65-172 ms here). A click's reply, timed by
the test through the pipe, comes 1-10 ms after Lean's own time for 1,000 rows and 60 ms after it for
10,000 (writing the update, `lean.wasm`'s stdout byte by byte, the pipe); an empty message's round
trip is 0.3-0.5 ms. A session is ready (mounted) about 2.2 s after its process starts: 0.43 s to
unpack the snapshot, 0.57 s more until the runtime is up, then 1.15 s for Lean to load the snapshot
and mount the app.

In a browser, on the same machine: Playwright's headless Chromium 141 and Firefox 142, `dist/qed64`
served by `leanui serve --coop` on localhost, one page load each. The times are from the click until
the page is updated, with Lean's own time in brackets; the operations are each one first click (the
race takes medians). Playwright's Firefox runs wasm about 8× slower than a release Firefox
(docs/BENCHMARKS.md, "Findings about measuring").

| | Chromium 141 | Firefox 142 |
|---|---|---|
| ready (Life) | 2.7 s | 6.7 s |
| of which download, runtime, Lean | 1.18, 0.03, 1.42 s | 1.69, 3.26, 1.40 s |
| Life, one step (median of 100) | 25.2 ms (23.4) | 152 ms (149) |
| create 1,000 rows | 301 ms (276) | 1,397 ms (1,372) |
| create 10,000 rows | 2,363 ms (2,230) | 12,936 ms (12,784) |
| an empty round trip | 0.37 ms | 0.48 ms |

In the race, next to the other lanes (docs/BENCHMARKS.md, "The QED64 lane"; Chromium 141, the same
machine), the lane is about as fast as lean-vir: it takes 1.11× lean-vir's time in Life and 1.00×
on the table (the geometric mean of the operations), and 12.3× wasm64's on the table. Lean's own
time is 80-97% of a click.
