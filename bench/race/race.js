// The race: one app, several ways, side by side. Each panel is a page of its own (an iframe), one
// for each lane of lanes.mjs: by default hand-written JavaScript, LeanUI compiled to wasm64 (the
// production path), and the same Lean program interpreted by lean-vir (wasm32). This page is the
// referee, in plain JavaScript: it clicks each app's own buttons, times the clicks, and checks that
// all of them end in the same state.
//
//   index.html?scenario=life|table&steps=1000&runs=3&auto=1[&post=1][&lanes=vanilla,wasm64,vir]
//
// `lanes` picks the lanes (in lanes.mjs's order); without it, every lane that is not optional runs.
// Life: Step is clicked `steps` times in every panel. The panels share the time: in each animation
// frame, a panel clicks while the time it has spent is under SLICE_MS more than the least any
// unfinished panel has spent, so all get the same time and the faster ones get further: what you
// see moving is each one's speed. Table: the js-framework-benchmark keyed operations
// (bench/ops.mjs), one panel at a time: the warm-up clicks, then the timed click, `runs` times
// (the median counts). Times are the clicks' script time: the app's update and its DOM calls,
// measured here around the clicks. Style, layout and paint come later, in the frame, and are not
// counted (the lanes build the same DOM). An asynchronous lane's app answers after the click
// returns (lanes.mjs): its click is timed until the app has applied what the click caused, and the
// referee clicks nothing else meanwhile. Served cross-origin isolated (as the site serves it),
// `performance.now()` is precise to microseconds; otherwise Chrome rounds it to 0.1 ms and Firefox
// coarser, which only the table's smallest clicks feel. `auto=1` runs at once; the result is left
// in `window.__race`, and with `post=1` also POSTed to /result (tests/browser/selfbench.mjs
// --race, for release browsers).
import { OPS } from "./ops.mjs";
import { LANES, memory64 } from "./lanes.mjs";

const SLICE_MS = 8;
// ms of busy-waiting before each timed table click, as bench/runner.html does: an idle renderer is
// often moved to an efficiency core, which makes single-click timings bimodal
const SPIN_MS = 30;
const q = new URLSearchParams(location.search);
const $ = (s) => document.querySelector(s);
const frame = () => new Promise((r) => requestAnimationFrame(r));
const settle = (w) => new Promise((r) => w.requestAnimationFrame(() => w.requestAnimationFrame(() => setTimeout(r, 20))));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const median = (a) => { const s = a.slice().sort((x, y) => x - y); return s.length ? s[s.length >> 1] : NaN; };
const num = (ms) => (!isFinite(ms) ? "–" : ms >= 100 ? ms.toFixed(0) : ms >= 10 ? ms.toFixed(1) : ms.toFixed(2));
const fmt = (ms) => (isFinite(ms) ? num(ms) + " ms" : "–");
const ratio = (a, b) => (a > 0 && b > 0 ? (a / b).toFixed(a / b >= 10 ? 0 : 1) + "×" : "–");
const fnv = (s) => { let h = 2166136261; for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619) >>> 0; return h.toString(16).padStart(8, "0"); };
const words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];

// The lanes this page races: the ones ?lanes= names, or else every lane that is not optional.
const asked = (q.get("lanes") || "").split(",").filter(Boolean);
const unknown = asked.filter((k) => !LANES.some((l) => l.key === k));
const IMPLS = LANES.filter((l) => (asked.length ? asked.includes(l.key) : !l.optional));
// An optional lane exists only where bench/race/build.sh found its page: lanes.json lists the
// lanes built for each scenario (fetched only if there is an optional lane to look up).
const BUILT = LANES.some((l) => l.optional) ? await fetch("lanes.json").then((r) => r.json()).catch(() => ({})) : {};
const built = (l, scenario) => !l.optional || (BUILT[scenario] || []).includes(l.key);
const needs = (l) => (l.needs ? l.needs() : true);
const runnable = (scenario) => IMPLS.filter((l) => built(l, scenario) && needs(l) === true);
// the lanes a run on the current scenario needs (load() sets it): their absence must not count as agreement
let expected = [];

const panels = IMPLS.map((impl) => {
  const el = document.createElement("section");
  el.className = "panel";
  el.innerHTML = `<h2>${impl.name}</h2><p class="note">${impl.note}</p><iframe title="${impl.name}"></iframe>
    <div class="bar"><div></div></div>
    <dl><div><dt>Progress</dt><dd class="done">–</dd></div><div><dt>Script time</dt><dd class="ms">–</dd></div>
    <div><dt>Per click</dt><dd class="per">–</dd></div><div><dt>Started in</dt><dd class="boot">–</dd></div></dl>
    <p class="lane" hidden></p>`;
  $("#panels").appendChild(el);
  return { ...impl, el, frame: el.querySelector("iframe"), win: null, ok: false, lane: null, dead: null };
});
const status = (s) => { $("#status").textContent = s; };
const set = (p, cls, text) => { p.el.querySelector("." + cls).textContent = text; };
const click = (p, sel) => { const e = p.win.document.querySelector(sel); if (!e) throw new Error(p.name + ": no element " + sel); e.click(); };

// An asynchronous lane (lanes.mjs): wait until its app has applied what the clicks so far caused.
// If its app stopped, the lane is out of the race, and it does not count as agreeing.
async function idle(p) {
  try { await p.win.__idle(); return true; } catch (e) {
    console.error(p.name + " stopped:", e); p.dead = String(e && e.message || e); set(p, "done", "stopped (see the console)");
    return false;
  }
}
const press = async (p, sel) => { click(p, sel); if (p.async) await idle(p); };

// A lane's own figures (window.__lane, lanes.mjs), for the clicks the referee timed: the difference
// of its totals around them, so they add up to the time shown (Life: per click over the run; the
// table: the run that is the median). The transport is the rest: the Worker's I/O and the messages.
const stats = (p) => p.lane.stats?.() || {};
const tally = () => ({ ms: 0, leanMs: 0, workerMs: 0, applyMs: 0 });
const add = (acc, ms, s0, s1) => { acc.ms += ms; for (const k of ["leanMs", "workerMs", "applyMs"]) acc[k] += (s1[k] || 0) - (s0[k] || 0); };
const per = (acc, n) => ({ totalMs: acc.ms / n, leanMs: acc.leanMs / n, workerMs: acc.workerMs / n, applyMs: acc.applyMs / n,
  hopsMs: (acc.ms - acc.workerMs - acc.applyMs) / n });
const parts = (s) => [s.leanMs, s.totalMs - s.leanMs - s.applyMs, s.applyMs];
const split = (s) => { const [lean, transport, dom] = parts(s).map(fmt); return `of which Lean ${lean} · transport ${transport} · DOM ${dom}`; };
// the same under a time in the results (the note under them says what the three are)
const brief = (s) => `<br><small>${parts(s).map(num).join(" + ")}</small>`;
const stalls = (p) => { const n = p.lane ? stats(p).stalls || 0 : 0; return n ? ` ⚠ ${n} stall${n > 1 ? "s" : ""} (times include them)` : ""; };
// the line under a panel: how the lane started, then its split of the last figures shown
const laneLine = (p, ...lines) => { const e = p.el.querySelector(".lane"); e.textContent = lines.filter(Boolean).join("\n"); e.hidden = !e.textContent; };
const phases = (p) => (p.lane?.phases ? "started: " + Object.entries(p.lane.phases).map(([k, v]) => `${k} ${fmt(v)}`).join(" · ") : "");

// Load the scenario's page in each panel, one after another (so that each start is timed alone),
// and wait until each says it is ready. A newer load (the scenario changed) makes an older one stop.
let loads = 0;
async function load(scenario) {
  const n = ++loads;
  expected = runnable(scenario).map((l) => l.key);
  offer(scenario);
  for (const p of panels) {
    p.ok = false; p.win = null; p.lane = null; p.dead = null; p.acc = p.perOp = null; p.el.hidden = !built(p, scenario);
    set(p, "done", "–"); set(p, "ms", "–"); set(p, "per", "–"); set(p, "boot", "–"); bar(p, 0); laneLine(p);
  }
  for (const p of panels) {
    if (n !== loads) return;
    if (!built(p, scenario)) { p.frame.removeAttribute("src"); continue; }
    if (needs(p) !== true) { p.frame.removeAttribute("src"); set(p, "boot", needs(p)); continue; }
    await new Promise((ok) => {
      p.frame.onload = () => {
        const w = p.frame.contentWindow, t0 = performance.now();
        const wait = () => {
          if (n !== loads) return ok();
          if (w.__ready) {
            p.win = w; p.ok = true; p.lane = w.__lane || null;
            // bytes of everything the page loaded, each URL once (lean-vir's loader fetches its
            // runtime.js again to check it); compressed where the server compresses, as the site does;
            // and what the lane says it fetched where the page cannot see (its Worker's downloads)
            const sizes = new Map(w.performance.getEntriesByType("navigation").concat(w.performance.getEntriesByType("resource"))
              .map((e) => [e.name, e.encodedBodySize || 0]));
            const kb = ([...sizes.values()].reduce((a, b) => a + b, 0) + (p.lane?.bytes || 0)) / 1024;
            set(p, "boot", `${fmt(w.__ready)} · ${kb.toFixed(0)} KB`); laneLine(p, phases(p));
            return ok();
          }
          if (performance.now() - t0 > (p.bootTimeoutMs ?? 60000)) { set(p, "boot", "did not start (see the console)"); return ok(); }
          setTimeout(wait, 10);
        };
        wait();
      };
      p.frame.src = `${scenario}/${p.key}/?n=${Math.random()}`;
    });
  }
  // a lane may ask for a quiet spell before the first click (lanes.mjs: quietMs)
  const quiet = Math.max(0, ...panels.filter((p) => p.ok).map((p) => p.quietMs || 0));
  if (quiet && n === loads) { status(`Waiting ${(quiet / 1000).toFixed(1)} s for the pages to settle…`); await sleep(quiet); }
}
// The panels the run needs that did not start: their absence must not count as agreement. The
// lanes that stopped during the run (asynchronous ones: idle() above) do not agree either.
const missing = () => expected.filter((k) => !panels.find((p) => p.key === k).ok);
const dropped = () => panels.filter((p) => p.dead).map((p) => p.key);
const bar = (p, f) => { p.el.querySelector(".bar > div").style.width = (100 * f).toFixed(1) + "%"; };

let stopped = false;

// Life: `steps` clicks on Step in every panel, sharing the time (the header above).
async function runLife(steps) {
  const live = panels.filter((p) => p.ok);
  for (const p of live) { await press(p, "#reset"); p.done = 0; p.ms = 0; p.acc = p.lane ? tally() : null; }
  await frame();
  while (!stopped && live.some((p) => !p.dead && p.done < steps)) {
    const until = Math.min(...live.filter((p) => !p.dead && p.done < steps).map((p) => p.ms)) + SLICE_MS;
    for (const p of live) {
      if (p.dead || p.done >= steps || p.ms >= until) continue;
      // An asynchronous lane waits for its app's answers, and the browser would meanwhile draw the
      // frame (the clicks before it): it starts once that is done, so that it is not in its time.
      // Then each click until its app has answered (usually longer than a slice: one per turn), and
      // nothing else meanwhile.
      if (p.async) await sleep(0);
      const step = p.win.document.getElementById("step");
      const s0 = p.acc && stats(p);
      const t0 = performance.now();
      let k = 0;
      if (p.async) do { step.click(); if (!(await idle(p))) break; k++; } while (p.done + k < steps && p.ms + performance.now() - t0 < until);
      else do { step.click(); k++; } while (p.done + k < steps && p.ms + performance.now() - t0 < until);
      const t = performance.now() - t0;
      p.ms += t; p.done += k;
      if (p.acc) { add(p.acc, t, s0, stats(p)); laneLine(p, phases(p), split(per(p.acc, p.done)) + " per click" + stalls(p)); }
      if (p.dead) continue;
      set(p, "done", `${p.done.toLocaleString()} / ${steps.toLocaleString()}`);
      set(p, "ms", fmt(p.ms)); set(p, "per", fmt(p.ms / p.done)); bar(p, p.done / steps);
    }
    await frame();
  }
  for (const p of live) {
    if (p.async && !p.dead) await idle(p);
    if (p.acc) p.perOp = { step: per(p.acc, p.done) };
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
  const same = !missing().length && !dropped().length && rows.every((r) => r.gen === steps && r.shown === r.board && r.board === rows[0].board && r.pop === rows[0].pop);
  const base = (k) => rows.find((r) => r.key === k)?.ms;
  // a ratio column for each lane that the times of another lane are divided by (lanes.mjs: ratio)
  const bases = [...new Set(IMPLS.map((l) => l.ratio).filter((k) => k && live.some((p) => p.key === k)))];
  const lane = (k) => panels.find((p) => p.key === k);
  $("#results").innerHTML = `<table><thead><tr><th></th><th>Script time</th><th>Per click</th>${bases.map((k) => `<th>÷ ${lane(k).short}</th>`).join("")}<th>Generation</th><th>Alive</th><th>Board</th></tr></thead><tbody>${
    rows.map((r) => `<tr><th>${r.name}${stalls(lane(r.key))}</th><td>${fmt(r.ms)}</td><td>${fmt(r.ms / r.clicks)}${lane(r.key).perOp ? brief(lane(r.key).perOp.step) : ""}</td>${bases.map((k) => `<td>${ratio(r.ms, base(k))}</td>`).join("")}<td>${r.gen.toLocaleString()}</td><td>${r.pop}</td><td><code>${r.board}</code></td></tr>`).join("")
  }</tbody></table><p class="${same ? "ok" : "bad"}">${same ? `✓ All ${rows.length} reached generation ${steps.toLocaleString()} and show the same board.` : verdict("✗ The boards differ (or an app stopped early, or shows a board other than its own): see the console.")}</p>${notes(live)}`;
  return { scenario: "life", steps, same, rows };
}

// Table: the keyed operations, one panel at a time; each panel's table must match the others'.
async function runTable(runs) {
  const live = panels.filter((p) => p.ok);
  const rows = [];
  const tbl = document.createElement("table");
  // a ratio column for each lane whose times are divided by another live lane's (lanes.mjs: ratio)
  const ratios = live.filter((p) => p.ratio && live.some((b) => b.key === p.ratio));
  const short = (k) => live.find((p) => p.key === k).short;
  tbl.innerHTML = `<thead><tr><th>Operation</th>${live.map((p) => `<th>${p.name}</th>`).join("")}${ratios.map((p) => `<th>${p.short} ÷ ${short(p.ratio)}</th>`).join("")}<th>Same rows</th></tr></thead><tbody></tbody>`;
  $("#results").replaceChildren(tbl);
  for (const p of live) p.perOp = p.lane ? {} : null;
  for (const [i, op] of OPS.entries()) {
    if (stopped) break;
    const row = { op: op.name, desc: op.desc, ms: {}, sig: {} };
    for (const p of live) {
      if (p.dead) continue;
      set(p, "done", `${i + 1} / ${OPS.length}: ${op.desc}`); bar(p, i / OPS.length);
      const times = [], accs = [];
      for (let r = 0; r < runs && !stopped && !p.dead; r++) {
        for (const sel of op.warm) { await press(p, sel); if (p.dead) break; await settle(p.win); }
        if (p.dead) break;
        const e = p.win.document.querySelector(op.click);
        const s0 = p.perOp && stats(p);
        for (const end = performance.now() + SPIN_MS; performance.now() < end; );
        const t0 = performance.now(); e.click(); if (p.async && !(await idle(p))) break; times.push(performance.now() - t0);
        if (p.perOp) { const acc = tally(); add(acc, times[times.length - 1], s0, stats(p)); accs.push(acc); }
        await settle(p.win);
      }
      if (p.dead || (p.async && !(await idle(p)))) continue;
      row.ms[p.key] = median(times);
      // the rows the app shows: ids, labels and which one is selected
      row.sig[p.key] = fnv([...p.win.document.querySelectorAll("#tbody tr")].map((tr) => tr.className + ":" + tr.textContent).join("|"));
      set(p, "ms", fmt(row.ms[p.key])); set(p, "per", op.desc);
      // the lane's split of the run that is the median
      if (p.perOp && accs.length) { p.perOp[op.name] = per(accs[times.indexOf(row.ms[p.key])], 1); laneLine(p, phases(p), `${op.desc}: ${split(p.perOp[op.name])}${stalls(p)}`); }
    }
    row.same = !missing().length && !dropped().length && live.every((p) => row.sig[p.key] === row.sig[live[0].key]);
    rows.push(row);
    tbl.tBodies[0].insertAdjacentHTML("beforeend", `<tr><th>${op.desc}</th>${live.map((p) => `<td>${fmt(row.ms[p.key])}${p.perOp?.[op.name] ? brief(p.perOp[op.name]) : ""}</td>`).join("")}${ratios.map((p) => `<td>${ratio(row.ms[p.key], row.ms[p.ratio])}</td>`).join("")}<td>${row.same ? "✓" : "✗"}</td></tr>`);
  }
  for (const p of live) bar(p, 1);
  for (const [j, p] of live.entries()) if (stalls(p)) tbl.tHead.rows[0].cells[j + 1].textContent += stalls(p);
  const same = rows.length === OPS.length && rows.every((r) => r.same);
  $("#results").insertAdjacentHTML("beforeend", `<p class="${same ? "ok" : "bad"}">${same ? `✓ After every operation, all ${live.length} showed the same rows.` : verdict("✗ The tables differ: see the console.")}</p>${notes(live)}`);
  return { scenario: "table", runs, same, rows };
}

const verdict = (differ) => (stopped ? "Stopped." : missing().length ? `✗ Did not start: ${missing().join(", ")}.`
  : dropped().length ? `✗ Stopped during the run: ${dropped().join(", ")}.` : differ);
// under the results of a run: how an asynchronous lane is timed, and what the figures under a lane's
// times are (its own, window.__lane)
const notes = (live) => live.filter((p) => p.async || p.perOp).map((p) => {
  const f = p.lane && stats(p).floorMs;
  return `<p class="note">${p.async ? `${p.name} answers from a Worker: each of its clicks is timed until its app has
    applied the answer, so it also pays for the messages between the page and the Worker${f ? ` (an empty round trip takes ${fmt(f)})` : ""};
    the other lanes run on the page's own thread.` : p.name + ":"}${p.perOp ? ` Under its times, in ms: Lean + transport + DOM, that is
    its app's own time, then the Worker's input and output and the messages, then applying the answers to the page.` : ""}</p>`;
}).join("");

// The boxes that add an optional lane (lanes.mjs), for each one built for the scenario: ticking one
// loads this page again with the lanes asked for (?lanes=), and unticking it, without it.
function offer(scenario) {
  const box = $("#extra");
  box.replaceChildren(...LANES.filter((l) => l.optional && built(l, scenario)).map((l) => {
    const label = document.createElement("label"), input = document.createElement("input");
    input.type = "checkbox"; input.checked = IMPLS.includes(l);
    input.addEventListener("change", () => {
      const keys = LANES.filter((m) => (m === l ? input.checked : IMPLS.includes(m))).map((m) => m.key);
      for (const k of ["scenario", "steps", "runs"]) q.set(k, $("#" + k).value);
      q.set("lanes", keys.join(",")); q.delete("auto");
      location.search = q;
    });
    label.title = l.note; label.append(input, " " + (l.offer || "Add " + l.name));
    return label;
  }));
  box.hidden = !box.children.length;
}

// the controls that would change what is running are off while it runs
const busy = (on) => {
  for (const e of [$("#run"), $("#scenario"), $("#steps"), $("#runs"), ...$("#extra").querySelectorAll("input")]) e.disabled = on;
  $("#stop").disabled = !on;
};

async function run() {
  const scenario = $("#scenario").value;
  stopped = false;
  busy(true); $("#results").textContent = "";
  try {
    const n = runnable(scenario).length;
    if (!n) throw new Error("none of the lanes asked for can run here");
    status(n === 1 ? "Loading the page…" : `Loading the ${words[n] || n} pages…`);
    await load(scenario);
    status("Running…");
    const result = scenario === "life" ? await runLife(+$("#steps").value) : await runTable(+$("#runs").value);
    window.__race = { ...result, missing: missing(), userAgent: navigator.userAgent, memory64, crossOriginIsolated };
    if (dropped().length) window.__race.stopped = dropped();
    // what the lanes said of themselves (window.__lane, lanes.mjs)
    const own = panels.filter((p) => p.lane);
    if (own.length) window.__race.lanes = Object.fromEntries(own.map((p) => [p.key, { boot: p.win.__ready, phases: p.lane.phases,
      bytes: p.lane.bytes, stalls: stats(p).stalls || 0, floorMs: stats(p).floorMs, perOp: p.perOp }]));
    status(stopped ? "Stopped." : crossOriginIsolated ? "Done." : "Done. This page is not cross-origin isolated, so its timer is coarse (0.1 ms in Chrome).");
  } catch (e) {
    console.error(e); status("Error: " + e.message); window.__race = { error: String(e) };
  } finally { busy(false); }
  if (q.get("post") === "1") fetch("/result", { method: "POST", body: JSON.stringify(window.__race) });
}

// a count the menus lack (?steps=250) gets an option of its own: a select set to a value it does
// not list is empty, and an empty count would run nothing and report all of them equal
for (const k of ["steps", "runs"]) if (+q.get(k) > 0 && ![...$("#" + k).options].some((o) => o.value === q.get(k))) $("#" + k).add(new Option(q.get(k)));
for (const k of ["scenario", "steps", "runs"]) if (q.has(k)) $("#" + k).value = q.get(k);
const showOptions = () => { for (const e of document.querySelectorAll("[data-for]")) e.hidden = e.dataset.for !== $("#scenario").value; };
$("#scenario").addEventListener("change", () => { showOptions(); load($("#scenario").value); });
$("#run").addEventListener("click", run);
$("#stop").addEventListener("click", () => { stopped = true; });
showOptions();
if (unknown.length) {
  // a lane ?lanes= names that lanes.mjs does not have: nothing runs (an auto run says why)
  const why = `No lane ${unknown.join(", ")}: the lanes are ${LANES.map((l) => l.key).join(", ")}.`;
  status(why); $("#run").disabled = true;
  if (q.get("auto") === "1") { window.__race = { error: why }; if (q.get("post") === "1") fetch("/result", { method: "POST", body: JSON.stringify(window.__race) }); }
} else if (q.get("auto") === "1") run(); else load($("#scenario").value).then(() => status("Ready."));
