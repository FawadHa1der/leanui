// The race: one app, three ways, side by side. Each panel is a page of its own (an iframe):
// hand-written JavaScript, LeanUI compiled to wasm64 (the production path), and the same Lean
// program interpreted by lean-vir (wasm32). This page is the referee, in plain JavaScript: it clicks
// each app's own buttons, times the clicks, and checks that all three end in the same state.
//
//   index.html?scenario=life|table&steps=1000&runs=3&auto=1[&post=1]
//
// Life: Step is clicked `steps` times in every panel. The panels share the time: in each animation
// frame, a panel clicks while the time it has spent is under SLICE_MS more than the least any
// unfinished panel has spent, so all get the same time and the faster ones get further: what you
// see moving is each one's speed. Table: the js-framework-benchmark keyed operations
// (bench/ops.mjs), one panel at a time: the warm-up clicks, then the timed click, `runs` times
// (the median counts). Times are the clicks' script time: the app's update and its DOM calls,
// measured here around the clicks. Style, layout and paint come later, in the frame, and are not
// counted (the three build the same DOM). Served cross-origin isolated (as the site serves it),
// `performance.now()` is precise to microseconds; otherwise Chrome rounds it to 0.1 ms and Firefox
// coarser, which only the table's smallest clicks feel. `auto=1` runs at once; the result is left
// in `window.__race`, and with `post=1` also POSTed to /result (tests/browser/selfbench.mjs
// --race, for release browsers).
import { OPS } from "./ops.mjs";

const SLICE_MS = 8;
// ms of busy-waiting before each timed table click, as bench/runner.html does: an idle renderer is
// often moved to an efficiency core, which makes single-click timings bimodal
const SPIN_MS = 30;
const IMPLS = [
  { key: "vanilla", name: "Vanilla JavaScript", note: "hand-written DOM code" },
  { key: "wasm64", name: "LeanUI · wasm64", note: "Lean → C → wasm64 (Emscripten), the production build" },
  { key: "vir", name: "LeanUI · lean-vir", note: "the same Lean program, interpreted by lean-vir (wasm32)" },
];
const q = new URLSearchParams(location.search);
const $ = (s) => document.querySelector(s);
const frame = () => new Promise((r) => requestAnimationFrame(r));
const settle = (w) => new Promise((r) => w.requestAnimationFrame(() => w.requestAnimationFrame(() => setTimeout(r, 20))));
const median = (a) => { const s = a.slice().sort((x, y) => x - y); return s.length ? s[s.length >> 1] : NaN; };
const fmt = (ms) => (ms >= 100 ? ms.toFixed(0) : ms >= 10 ? ms.toFixed(1) : ms.toFixed(2)) + " ms";
const ratio = (a, b) => (a > 0 && b > 0 ? (a / b).toFixed(a / b >= 10 ? 0 : 1) + "×" : "–");
const fnv = (s) => { let h = 2166136261; for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619) >>> 0; return h.toString(16).padStart(8, "0"); };
// LeanUI's wasm64 build needs WebAssembly Memory64 (not in Safari yet; lean-vir and vanilla run anyway)
const memory64 = (() => { try { return WebAssembly.validate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 5, 3, 1, 4, 0])); } catch (e) { return false; } })();
const expected = IMPLS.filter((i) => i.key !== "wasm64" || memory64).map((i) => i.key);

const panels = IMPLS.map((impl) => {
  const el = document.createElement("section");
  el.className = "panel";
  el.innerHTML = `<h2>${impl.name}</h2><p class="note">${impl.note}</p><iframe title="${impl.name}"></iframe>
    <div class="bar"><div></div></div>
    <dl><div><dt>Progress</dt><dd class="done">–</dd></div><div><dt>Script time</dt><dd class="ms">–</dd></div>
    <div><dt>Per click</dt><dd class="per">–</dd></div><div><dt>Started in</dt><dd class="boot">–</dd></div></dl>`;
  $("#panels").appendChild(el);
  return { ...impl, el, frame: el.querySelector("iframe"), win: null, ok: false };
});
const status = (s) => { $("#status").textContent = s; };
const set = (p, cls, text) => { p.el.querySelector("." + cls).textContent = text; };
const click = (p, sel) => { const e = p.win.document.querySelector(sel); if (!e) throw new Error(p.name + ": no element " + sel); e.click(); };

// Load the scenario's page in each panel, one after another (so that each start is timed alone),
// and wait until each says it is ready. A newer load (the scenario changed) makes an older one stop.
let loads = 0;
async function load(scenario) {
  const n = ++loads;
  for (const p of panels) { p.ok = false; p.win = null; set(p, "done", "–"); set(p, "ms", "–"); set(p, "per", "–"); set(p, "boot", "–"); bar(p, 0); }
  for (const p of panels) {
    if (n !== loads) return;
    if (!expected.includes(p.key)) { p.frame.removeAttribute("src"); set(p, "boot", "needs WebAssembly Memory64"); continue; }
    await new Promise((ok) => {
      p.frame.onload = () => {
        const w = p.frame.contentWindow, t0 = performance.now();
        const wait = () => {
          if (n !== loads) return ok();
          if (w.__ready) {
            p.win = w; p.ok = true;
            // bytes of everything the page loaded, each URL once (lean-vir's loader fetches its
            // runtime.js again to check it); compressed where the server compresses, as the site does
            const sizes = new Map(w.performance.getEntriesByType("navigation").concat(w.performance.getEntriesByType("resource"))
              .map((e) => [e.name, e.encodedBodySize || 0]));
            const kb = [...sizes.values()].reduce((a, b) => a + b, 0) / 1024;
            set(p, "boot", `${fmt(w.__ready)} · ${kb.toFixed(0)} KB`);
            return ok();
          }
          if (performance.now() - t0 > 60000) { set(p, "boot", "did not start (see the console)"); return ok(); }
          setTimeout(wait, 10);
        };
        wait();
      };
      p.frame.src = `${scenario}/${p.key}/?n=${Math.random()}`;
    });
  }
}
// The panels the run needs that did not start: their absence must not count as agreement.
const missing = () => expected.filter((k) => !panels.find((p) => p.key === k).ok);
const bar = (p, f) => { p.el.querySelector(".bar > div").style.width = (100 * f).toFixed(1) + "%"; };

let stopped = false;

// Life: `steps` clicks on Step in every panel, sharing the time (the header above).
async function runLife(steps) {
  const live = panels.filter((p) => p.ok);
  for (const p of live) { click(p, "#reset"); p.done = 0; p.ms = 0; }
  await frame();
  while (!stopped && live.some((p) => p.done < steps)) {
    const until = Math.min(...live.filter((p) => p.done < steps).map((p) => p.ms)) + SLICE_MS;
    for (const p of live) {
      if (p.done >= steps || p.ms >= until) continue;
      const step = p.win.document.getElementById("step");
      const t0 = performance.now();
      let k = 0;
      do { step.click(); k++; } while (p.done + k < steps && p.ms + performance.now() - t0 < until);
      p.ms += performance.now() - t0; p.done += k;
      set(p, "done", `${p.done.toLocaleString()} / ${steps.toLocaleString()}`);
      set(p, "ms", fmt(p.ms)); set(p, "per", fmt(p.ms / p.done)); bar(p, p.done / steps);
    }
    await frame();
  }
  // What each app says (generation, live cells, the hash of its board), and the board it shows:
  // the referee hashes the cells on the page the way the apps hash theirs, so a cell the DOM got
  // wrong (or left out) cannot pass.
  const out = (p, id) => p.win.document.getElementById(id).textContent;
  const shown = (p) => {
    const cells = p.win.document.querySelectorAll("#board i");
    let h = 2166136261;
    for (const c of cells) h = Math.imul(h ^ (c.className === "on" ? 1 : 0), 16777619) >>> 0;
    return cells.length === 1000 ? h.toString(16).padStart(8, "0") : `${cells.length} cells`;
  };
  const rows = live.map((p) => ({ key: p.key, name: p.name, clicks: p.done, ms: p.ms, gen: +out(p, "gen"), pop: +out(p, "pop"), board: out(p, "hash"), shown: shown(p) }));
  const same = !missing().length && rows.every((r) => r.gen === steps && r.shown === r.board && r.board === rows[0].board && r.pop === rows[0].pop);
  const base = (k) => rows.find((r) => r.key === k)?.ms;
  $("#results").innerHTML = `<table><thead><tr><th></th><th>Script time</th><th>Per click</th><th>÷ vanilla</th><th>÷ wasm64</th><th>Generation</th><th>Alive</th><th>Board</th></tr></thead><tbody>${
    rows.map((r) => `<tr><th>${r.name}</th><td>${fmt(r.ms)}</td><td>${fmt(r.ms / r.clicks)}</td><td>${ratio(r.ms, base("vanilla"))}</td><td>${ratio(r.ms, base("wasm64"))}</td><td>${r.gen.toLocaleString()}</td><td>${r.pop}</td><td><code>${r.board}</code></td></tr>`).join("")
  }</tbody></table><p class="${same ? "ok" : "bad"}">${same ? `✓ All ${rows.length} reached generation ${steps.toLocaleString()} and show the same board.` : verdict("✗ The boards differ (or an app stopped early, or shows a board other than its own): see the console.")}</p>`;
  return { scenario: "life", steps, same, rows };
}

// Table: the keyed operations, one panel at a time; each panel's table must match the others'.
async function runTable(runs) {
  const live = panels.filter((p) => p.ok);
  const rows = [];
  const tbl = document.createElement("table");
  tbl.innerHTML = `<thead><tr><th>Operation</th>${live.map((p) => `<th>${p.name}</th>`).join("")}<th>wasm64 ÷ vanilla</th><th>lean-vir ÷ wasm64</th><th>Same rows</th></tr></thead><tbody></tbody>`;
  $("#results").replaceChildren(tbl);
  for (const [i, op] of OPS.entries()) {
    if (stopped) break;
    const row = { op: op.name, desc: op.desc, ms: {}, sig: {} };
    for (const p of live) {
      set(p, "done", `${i + 1} / ${OPS.length}: ${op.desc}`); bar(p, i / OPS.length);
      const times = [];
      for (let r = 0; r < runs && !stopped; r++) {
        for (const sel of op.warm) { click(p, sel); await settle(p.win); }
        const e = p.win.document.querySelector(op.click);
        for (const end = performance.now() + SPIN_MS; performance.now() < end; );
        const t0 = performance.now(); e.click(); times.push(performance.now() - t0);
        await settle(p.win);
      }
      row.ms[p.key] = median(times);
      // the rows the app shows: ids, labels and which one is selected
      row.sig[p.key] = fnv([...p.win.document.querySelectorAll("#tbody tr")].map((tr) => tr.className + ":" + tr.textContent).join("|"));
      set(p, "ms", fmt(row.ms[p.key])); set(p, "per", op.desc);
    }
    row.same = !missing().length && live.every((p) => row.sig[p.key] === row.sig[live[0].key]);
    rows.push(row);
    tbl.tBodies[0].insertAdjacentHTML("beforeend", `<tr><th>${op.desc}</th>${live.map((p) => `<td>${fmt(row.ms[p.key])}</td>`).join("")}<td>${ratio(row.ms.wasm64, row.ms.vanilla)}</td><td>${ratio(row.ms.vir, row.ms.wasm64)}</td><td>${row.same ? "✓" : "✗"}</td></tr>`);
  }
  for (const p of live) bar(p, 1);
  const same = rows.length === OPS.length && rows.every((r) => r.same);
  $("#results").insertAdjacentHTML("beforeend", `<p class="${same ? "ok" : "bad"}">${same ? `✓ After every operation, all ${live.length} showed the same rows.` : verdict("✗ The tables differ: see the console.")}</p>`);
  return { scenario: "table", runs, same, rows };
}

const verdict = (differ) => (stopped ? "Stopped." : missing().length ? `✗ Did not start: ${missing().join(", ")}.` : differ);

// the controls that would change what is running are off while it runs
const busy = (on) => { for (const id of ["run", "scenario", "steps", "runs"]) $("#" + id).disabled = on; $("#stop").disabled = !on; };

async function run() {
  const scenario = $("#scenario").value;
  stopped = false;
  busy(true); $("#results").textContent = "";
  try {
    status("Loading the three pages…");
    await load(scenario);
    status("Running…");
    const result = scenario === "life" ? await runLife(+$("#steps").value) : await runTable(+$("#runs").value);
    window.__race = { ...result, missing: missing(), userAgent: navigator.userAgent, memory64, crossOriginIsolated };
    status(stopped ? "Stopped." : crossOriginIsolated ? "Done." : "Done. This page is not cross-origin isolated, so its timer is coarse (0.1 ms in Chrome).");
  } catch (e) {
    console.error(e); status("Error: " + e.message); window.__race = { error: String(e) };
  } finally { busy(false); }
  if (q.get("post") === "1") fetch("/result", { method: "POST", body: JSON.stringify(window.__race) });
}

// a count the menus lack (?steps=250) gets an option of its own: a select set to a value it does
// not list is empty, and an empty count would run nothing and report all three equal
for (const k of ["steps", "runs"]) if (+q.get(k) > 0 && ![...$("#" + k).options].some((o) => o.value === q.get(k))) $("#" + k).add(new Option(q.get(k)));
for (const k of ["scenario", "steps", "runs"]) if (q.has(k)) $("#" + k).value = q.get(k);
const showOptions = () => { for (const e of document.querySelectorAll("[data-for]")) e.hidden = e.dataset.for !== $("#scenario").value; };
$("#scenario").addEventListener("change", () => { showOptions(); load($("#scenario").value); });
$("#run").addEventListener("click", run);
$("#stop").addEventListener("click", () => { stopped = true; });
showOptions();
if (q.get("auto") === "1") run(); else load($("#scenario").value).then(() => status("Ready."));
