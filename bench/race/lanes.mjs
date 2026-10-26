// The race's lanes (bench/race/race.js): the ways the race runs its app, in the order of their panels.
// A lane is a page per scenario at <scenario>/<key>/ (bench/race/build.sh puts it there) that has
// the app's own buttons and sets window.__ready (its performance.now() once the app is ready). This
// file is data only: a lane's code stays in its own pages, and the referee loads none of it unless
// the lane runs.
//
//   key            its directory, and its name in ?lanes= and in window.__race
//   name, note     the panel's title and the line under it
//   short          its name in a ratio column ("lean-vir ÷ wasm64")
//   ratio          the lane its times are divided by in the results (the key of another lane)
//   needs()        true if this browser can run it, or why not (the panel shows it)
//   optional       runs only when ?lanes= names it (or its box is ticked: the page offers a box
//                  for each optional lane built for the scenario, dist/race/lanes.json)
//   offer          the label of that box ("Add <name>" if not given), e.g. with what it downloads
//   async          its app answers after the click returns (from a Worker): see below
//   bootTimeoutMs  how long its page may take to be ready (60 s if not given)
//   quietMs        how long the referee waits, once every page is ready, before the first click
//                  (the browser may still be compiling the lane's code in the background)
//
// An asynchronous lane's page also sets window.__idle(): a promise that resolves once everything the
// clicks so far caused is on the page, and rejects if the app has stopped. The referee awaits it after
// each click on the lane and clicks nothing else meanwhile, so the lane's time runs from the click to
// the page updated: what a synchronous lane's click covers. Any lane may also set window.__lane, for
// what the referee cannot see itself, before __ready:
//   bytes          what it downloaded that the page's resource timing does not list (a Worker's
//                  fetches), added to the panel's size
//   phases         its start, { name: ms, … } in order, shown in the panel
//   stats()        totals since the page loaded, each optional: leanMs (the app's own time, its
//                  clock), workerMs (from a message reaching the Worker to its reply leaving),
//                  applyMs (applying the replies to the DOM), stalls (replies the lane knows were
//                  held up), floorMs (an empty message's round trip, measured once). The referee
//                  splits each timed click's time with them (the rest is the transport) and puts
//                  them in window.__race.lanes.<key>.

// LeanUI's wasm64 build needs WebAssembly Memory64 (not in Safari yet; lean-vir and vanilla run anyway)
export const memory64 = (() => { try { return WebAssembly.validate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 5, 3, 1, 4, 0])); } catch (e) { return false; } })();

export const LANES = [
  { key: "vanilla", name: "Vanilla JavaScript", short: "vanilla", note: "hand-written DOM code" },
  { key: "wasm64", name: "LeanUI · wasm64", short: "wasm64", note: "Lean → C → wasm64 (Emscripten), the production build",
    needs: () => memory64 || "needs WebAssembly Memory64", ratio: "vanilla" },
  { key: "vir", name: "LeanUI · lean-vir", short: "lean-vir", note: "the same Lean program, interpreted by lean-vir (wasm32)",
    ratio: "wasm64" },
];
