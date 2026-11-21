// The side-by-side page (dist/iris/index.html). A section per scenario, each with its own Run
// button: a live visual where one is cheap and honest (live.mjs), a chart of the lanes whose rows
// open to their proof chips (chart.mjs), a verdict computed from the run (views.mjs) and, under
// Details, every row. The lanes of a section run one after another in module Web Workers
// (bench/core.mjs, runLane), each at the thread count asked for. Without cross-origin isolation
// there is no SharedArrayBuffer: the page then shows only what is proved, and why nothing runs.
//
//   ?auto=1&scenarios=s1,s2&w=1,2&fuzz=off,on&quick=1
// auto runs the scenarios named (all by default) at the thread counts w (4 by default, or the cores
// if fewer), with fuzz off and/or on; quick=1 uses the harness's short run sizes instead of the
// page's. window.__iris has every row, the verified-lane failures and each scenario's verdict.
import { KINDS, verdict as judge } from './bench/chips.mjs';
import { laneChart, tooltips, esc, num, speed, isBroken } from './chart.mjs';
import { VIEWS, wFor, violationText } from './views.mjs';
import { counterMeters, tileCards } from './live.mjs';

const base = new URL('./', import.meta.url);
const $ = (s, el = document) => el.querySelector(s);
const IDS = ['s1', 's2', 's4', 's5', 's11'];
const q = new URLSearchParams(location.search);
const quick = q.get('quick') === '1';
const state = (window.__iris = { isolated: !!globalThis.crossOriginIsolated, state: 'loading', rows: [], failures: [], scenarios: {} });

const manifest = await (await fetch(new URL('gen/manifest.json', base))).json();
renderLegend();
renderTheorems();

if (!globalThis.crossOriginIsolated) {
  const g = $('#gate');
  g.hidden = false;
  g.innerHTML = `<p><b>Nothing can run here: this page is not cross-origin isolated.</b> Shared memory
    (<code>SharedArrayBuffer</code>) exists only on pages served with
    <code>Cross-Origin-Opener-Policy: same-origin</code> and <code>Cross-Origin-Embedder-Policy: require-corp</code>,
    and every lane here, verified or not, shares memory between Workers. The same requirement is why
    LeanUI's own apps ship single-threaded. Serve the build with <code>leanui serve dist --coop</code> to run the
    scenarios. What is proved does not depend on running anything; it is below.</p>`;
  state.state = 'refused';
} else {
  await boot();
}

async function boot() {
  const { webHost } = await import('./bench/host-web.mjs');
  const { runLane } = await import('./bench/core.mjs');
  const host = await webHost(base);
  const cores = host.cores;
  const here = (l) => !l.only || l.only === host.env;
  const threadsOf = (l, W) => (l.threads ? l.threads(W) : W);

  // the thread counts: one, or 1, 2 and 4 (the bench programs exist for W = 1, 2, 4 and 8)
  const sel = $('#threads');
  for (const t of [1, 2, 4, 8]) sel.add(new Option(`${t}${t > cores ? ` (more than the ${cores} cores here)` : ''}`, String(t)));
  sel.add(new Option('1, 2 and 4, one after another', '1,2,4'));
  const w = q.get('w');
  if (w && ![...sel.options].some((o) => o.value === w)) sel.add(new Option(w.split(',').join(', '), w));
  sel.value = w || String(cores >= 4 ? 4 : cores >= 2 ? 2 : 1);
  $('#fuzz').checked = (q.get('fuzz') || 'off').split(',').includes('on');
  const asked = () => ({ Ts: sel.value.split(',').map(Number).filter((t) => t > 0), fuzz: $('#fuzz').checked ? [false, true] : [false] });

  const sections = [];
  for (const id of IDS) sections.push(section(await import(`./bench/scenarios/${id}.mjs`)));
  tooltips(document.body);
  $('#controls').hidden = false;
  $('#key').hidden = false;
  $('#status').textContent = `${cores} logical cores here. Press Run on a scenario, or Run all.`;

  // The chart's row of a lane: its run at the largest thread count asked for, fuzz off; the rounds
  // of a scenario that repeats its runs (S5) as one row: the median speed, violations added up.
  function chartRow(sv, id) {
    const lane = sv.sc.lanes.find((l) => l.id === id);
    if (!lane) return null;
    const W = lane.mode === 'kill' || lane.oneW ? lane.oneW || 2 : wFor(lane, Math.max(...sv.Ts));
    const rs = sv.rows.filter((r) => r.lane === id && !r.fuzz && (r.skipped || r.W === W));
    return merge(rs);
  }
  function merge(rs) {
    if (rs.length < 2) return rs[0] || null;
    const timed = rs.filter((r) => r.ops_per_us != null).sort((a, b) => a.ops_per_us - b.ops_per_us);
    const mid = timed.length ? timed[timed.length >> 1] : rs[rs.length - 1];
    const violations = {};
    for (const r of rs) for (const [k, n] of Object.entries(r.violations || {})) violations[k] = (violations[k] || 0) + n;
    const bad = rs.find((r) => r.error || r.trap || r.hung);
    return { ...mid, ...(bad && { error: bad.error, trap: bad.trap, hung: bad.hung }), violations, rounds: rs.length };
  }
  const total = (r) => Object.values(r?.violations || {}).some(Boolean);

  function section(sc) {
    const view = { ...VIEWS[sc.id], lanes: sc.lanes };
    const el = document.createElement('section');
    el.className = 'scenario';
    el.id = sc.id;
    el.innerHTML = `<div class="head"><h2>${esc(sc.title)}</h2><button type="button" class="run">Run ${sc.id.toUpperCase()}</button></div>
      <p class="ask">${esc(view.ask)}</p><p class="verdict" aria-live="polite"></p><div class="live"></div>
      <h3 class="chart-title"></h3><div class="chart-box"></div><div class="facts" hidden></div>
      <details class="more"><summary>Details: every run of every lane</summary><div class="table-wrap"></div></details>`;
    $('#results').append(el);
    const lanes = sc.lanes.filter((l) => here(l) && view.chart(l));
    const live = view.live === 'counter' ? counterMeters($('.live', el), lanes, view.read) : view.live === 'tiles' ? tileCards($('.live', el), lanes) : null;
    if (!live) $('.live', el).remove();
    const sv = { sc, view, el, lanes, live, rows: [], failures: [], Ts: asked().Ts, rounds: 1, running: null, ran: false,
      update: laneChart($('.chart-box', el), lanes, { manifest, scale: view.scale, unit: view.unit, max: view.max }) };
    $('.run', el).onclick = () => go([sv]);
    sel.addEventListener('change', () => { if (!sv.ran) { sv.Ts = asked().Ts; refresh(sv); } });
    refresh(sv);
    return sv;
  }

  // What a chart row shows (chart.mjs, laneChart): S4 shows a lane and its "-stress" twin in one
  // row: the speed of the stress run, the underruns of the paced one, the violations of both.
  function describe(sv, lane) {
    const { view } = sv;
    const ids = view.pairs ? [lane.id, `${lane.id}-stress`] : [lane.id];
    if (ids.includes(sv.running)) return { state: 'running' };
    const rs = ids.map((id) => chartRow(sv, id)).filter(Boolean);
    if (!rs.length) return { state: 'idle', idle: sv.active ? 'waiting' : sv.ran ? 'not run' : 'not run yet' };
    const r = rs[rs.length - 1];
    const done = { state: 'done', figures: figures(sv, rs) };
    if (r.skipped) return { ...done, text: `skipped: ${r.skipped}` };
    const err = rs.find((x) => x.error || x.trap || x.hung);
    if (err) return { ...done, error: err.trap ? `trap: ${err.trap}` : err.hung ? 'hung' : `error: ${String(err.error).split('\n')[0]}` };
    const all = merge(rs.map((x) => ({ ...x, ops_per_us: null })));
    if (isBroken(lane) && !view.countBroken) {
      if (!total(all)) return { ...done, text: threadsOf(lane, r.W) < 2 ? 'no failure: one thread has no one to race' : 'no failure this run (a race is not guaranteed to show)' };
      return { ...done, bad: (view.bad || violationText)({ ...r, violations: all.violations }), tip: violationText(all) };
    }
    const value = view.value ? view.value(r, lane) : r.ops_per_us;
    const text = view.text ? view.text(r, lane) : value != null ? speed(value) : '–';
    const n = threadsOf(lane, r.W);
    const tip = view.per && value != null ? `${speed(value)} ${view.per} · ${n} thread${n > 1 ? 's' : ''}${r.fairness != null ? ` · fairness ${r.fairness}` : ''}` : lane.note?.(r) || '';
    return { ...done, value, text, tip, meta: view.meta === false ? '' : lane.note?.(rs[0]) || '' };
  }
  function figures(sv, rs) {
    return rs.map((r, i) => {
      const l = sv.sc.lanes.find((x) => x.id === r.lane);
      const say = [`${threadsOf(l, r.W)} thread${threadsOf(l, r.W) > 1 ? 's' : ''} (W = ${r.W})`];
      if (r.ops != null && r.wall_ms != null) say.push(`${num(r.ops)} operations in ${r.wall_ms.toFixed(1)} ms`);
      if (r.fairness != null) say.push(`fairness ${r.fairness} (1: equal shares)`);
      if (r.rounds > 1) say.push(`median of ${r.rounds} rounds`);
      if (l.mode === 'program') say.push('a whole program on the HeapLang thread pool, median of 3 runs');
      if (l.note?.(r)) say.push(l.note(r));
      return `${sv.view.pairs ? (i ? 'Consumer flat out: ' : 'At audio pace: ') : 'This run: '}${say.join(' · ')}`;
    }).join('\n');
  }

  function refresh(sv) {
    const { view, el } = sv;
    const T = Math.max(...sv.Ts), W = wFor(sv.lanes[0], T);
    $('.chart-title', el).textContent = `${view.title}, at ${view.threads ? view.threads(T, W, threadsOf(sv.lanes[0], W)) : `${T} thread${T > 1 ? 's' : ''}`}`;
    sv.update(new Map(sv.lanes.map((l) => [l.id, describe(sv, l)])));
    if (view.facts) {
      const f = $('.facts', el), ls = sv.sc.lanes.filter((l) => here(l) && view.facts.lanes(l));
      f.hidden = false;
      f.innerHTML = `<h3>${esc(view.facts.title)}</h3><ul>${ls.map((l) => {
        const r = chartRow(sv, l.id), s = sv.running === l.id ? { st: '', text: 'running…' } : r ? view.facts.say(r, l) : { st: '', text: sv.active ? 'waiting' : 'not run yet' };
        return `<li><span class="st ${s.st}">${s.st === 'ok' ? '✓' : s.st === 'bad' ? '✗' : '·'}</span> <span class="name">${esc(l.label)}</span> <span class="kind" title="${esc(KINDS[l.kind])}">${l.kind}</span> ${esc(s.text)}</li>`;
      }).join('')}</ul>`;
    }
    details(sv);
  }

  // Every row of the last run, a line per lane, thread count and fuzz setting (rounds merged)
  function details(sv) {
    const groups = new Map();
    for (const r of sv.rows) { const k = `${r.lane} ${r.W} ${r.fuzz}`; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(r); }
    const body = [...groups.values()].map(merge).map((r) => {
      const l = sv.sc.lanes.find((x) => x.id === r.lane) || {};
      const v = r.skipped ? '' : total(r) ? `<span class="bad">${esc(violationText(r))}</span>` : '0';
      const note = r.skipped ? `skipped: ${r.skipped}` : r.error ? `error: ${String(r.error).split('\n')[0]}` : r.trap ? `trap: ${r.trap}` : l.note ? l.note(r) : r.extra?.after_kill || '';
      const sp = r.ops_per_us == null ? (l.noSpeed && !r.skipped ? '<span class="muted">not shown</span>' : '') : speed(r.ops_per_us);
      return `<tr><td class="l">${esc(l.label)}</td><td class="l"><span class="kind" title="${esc(KINDS[l.kind])}">${l.kind}</span></td><td>${l.threads ? `${threadsOf(l, r.W)} (W ${r.W})` : r.W}</td>
        <td>${r.fuzz ? 'on' : ''}</td><td>${sp}</td><td>${v}</td><td>${r.fairness ?? ''}</td><td>${r.rounds > 1 ? r.rounds : ''}</td><td class="l note">${esc(note)}</td></tr>`;
    }).join('');
    $('.table-wrap', sv.el).innerHTML = sv.rows.length ? `<table><thead><tr><th class="l">Lane</th><th class="l">Kind</th><th>Threads</th><th>Fuzz</th>
      <th>ops/µs</th><th>Violations</th><th>Fairness</th><th>Rounds</th><th class="l">Note</th></tr></thead><tbody>${body}</tbody></table>
      <p class="muted">ops/µs: operations per microsecond, all threads together, measured in this browser. Fairness: Jain's index over
      the threads' counts. Native and wasm32 lanes run under Node only (<code>node iris/bench/harness.mjs</code>), which also reports CPU time.</p>`
      : '<p class="muted">Not run yet.</p>';
  }

  const say = (sv, text, cls = '') => { const v = $('.verdict', sv.el); v.textContent = text; v.className = `verdict ${cls}`; };
  const estimate = (sv) => { const { Ts, fuzz } = asked(); return Math.round((sv.view.about * Ts.reduce((s, t) => s + Math.max(0.5, Math.min(1, t / 4)), 0) * fuzz.length) / (quick ? 5 : 1)); };
  const idle = (sv) => say(sv, `Not run yet: press Run (about ${estimate(sv)} s).`, 'idle');
  for (const sv of sections) idle(sv);
  sel.addEventListener('change', () => { for (const sv of sections) if (!sv.ran) idle(sv); });
  $('#fuzz').addEventListener('change', () => { for (const sv of sections) if (!sv.ran) idle(sv); });

  // the lane as the page runs it: what its setup returns and its workers report also go to the live visual
  const watch = (lane, probe) => (!probe ? lane : {
    ...lane,
    setup: async (ctx) => { const s = (await lane.setup?.(ctx)) || {}; probe.shared?.(s, ctx); return s; },
    check: lane.check && ((ctx, sh, outs) => { probe.outs?.(outs); return lane.check(ctx, sh, outs); }),
  });

  async function runSection(sv) {
    const { sc, view } = sv;
    const { Ts, fuzz } = asked();
    const sizes = quick ? sc.sizes.quick : { ...sc.sizes.full, ...view.sizes };
    const rounds = quick ? Math.min(2, view.rounds || 1) : view.rounds || 1;
    Object.assign(sv, { rows: [], failures: [], Ts, rounds, ran: true, active: true });
    sv.live?.reset();
    state.scenarios[sc.id] = { state: 'running', threads: Ts };
    // every lane at every thread count (as its W), fuzz off then on; a lane this host cannot run
    // gets one "skipped" row; a scenario with rounds runs every lane once per round
    const plan = [];
    for (let r = 0; r < rounds; r++) {
      for (const lane of sc.lanes) {
        if (!here(lane) && r) continue;
        const Ws = !here(lane) ? [Ts[0]] : lane.mode === 'kill' || lane.oneW ? [lane.oneW || 2] : [...new Set(Ts.map((t) => wFor(lane, t)))];
        for (const f of !here(lane) || lane.mode === 'program' || lane.mode === 'kill' ? [false] : fuzz) for (const W of Ws) plan.push({ lane, W, f, r });
      }
    }
    const t0 = performance.now();
    for (const [k, { lane, W, f, r }] of plan.entries()) {
      if (stopped) break;
      sv.running = lane.id;
      say(sv, `Running ${k + 1} of ${plan.length}: ${lane.label}, ${threadsOf(lane, W)} thread${threadsOf(lane, W) > 1 ? 's' : ''}${f ? ', fuzz' : ''}${rounds > 1 ? `, round ${r + 1} of ${rounds}` : ''}…`, 'busy');
      refresh(sv);
      const probe = here(lane) && !f ? sv.live?.probe(lane, W, sizes, r, rounds) : null;
      const row = await runLane(host, sc, watch(lane, probe), W, { fuzz: f, sizes, hangMs: lane.hangMs });
      if (rounds > 1) row.round = r;
      probe?.stop(row);
      sv.rows.push(row);
      const bad = judge(sc, row);
      if (bad) sv.failures.push(`${sc.id} ${row.lane} W=${row.W}${row.fuzz ? ' fuzz' : ''}: ${bad}`);
      sv.running = null;
      publish();
    }
    sv.active = false;
    // the counters end on the runs the chart shows (with several thread counts, the largest)
    if (view.live === 'counter') for (const l of sv.lanes) sv.live.result(l, chartRow(sv, l.id));
    refresh(sv);
    const ms = performance.now() - t0;
    const get = (id) => chartRow(sv, id);
    const fail = sv.failures.length ? `✗ ${sv.failures.length} verified-lane failure${sv.failures.length > 1 ? 's' : ''}: ${sv.failures.join('; ')}. ` : '';
    const text = stopped ? 'Stopped before the end: the rows so far are below.' : fail + view.verdict(get, { rounds }).filter(Boolean).join(' ');
    say(sv, text, sv.failures.length ? 'bad' : 'done');
    const where = `this browser on this machine, this run (${(ms / 1000).toFixed(1)} s)`;
    if (!stopped) $('.verdict', sv.el).insertAdjacentHTML('beforeend', ` <span class="muted">${view.scale === 'linear' ? `Measured in ${where}` : `Speeds: ${where}`}.</span>`);
    state.scenarios[sc.id] = { state: stopped ? 'stopped' : 'done', threads: Ts, ms: Math.round(ms), verdict: text, failures: sv.failures };
  }

  const publish = () => {
    state.rows = sections.flatMap((s) => s.rows);
    state.failures = sections.flatMap((s) => s.failures);
    $('#download').disabled = !state.rows.length;
  };
  let busy = false, stopped = false;
  const controls = (on) => {
    for (const e of [sel, $('#fuzz'), $('#runall'), ...document.querySelectorAll('.scenario .run')]) e.disabled = on;
    $('#stop').disabled = !on;
  };
  async function go(list) {
    if (busy) return;
    busy = true; stopped = false; controls(true);
    state.state = 'running'; state.error = undefined;
    try {
      for (const sv of list) {
        if (stopped) break;
        $('#status').textContent = `Running ${sv.sc.title}…`;
        await runSection(sv);
      }
      state.state = 'done';
      $('#status').textContent = stopped ? 'Stopped.' : state.failures.length ? `done: ${state.failures.length} verified-lane failures` : 'done: verified lanes, 0 violations';
    } catch (e) {
      state.state = 'error'; state.error = String((e && e.stack) || e);
      $('#status').textContent = 'error: ' + state.error.split('\n')[0];
    }
    busy = false; controls(false);
  }
  $('#runall').onclick = () => go(sections);
  $('#stop').onclick = () => { stopped = true; $('#status').textContent = 'Stopping after the lane that is running…'; };
  $('#download').onclick = () => {
    const blob = new Blob([JSON.stringify({ generated_by: 'iris/page', ua: navigator.userAgent, cores, threads: asked().Ts, quick, rows: state.rows }, null, 1)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob); a.download = 'iris-results.json'; a.click();
  };
  state.state = 'ready';
  if (q.get('auto') === '1') {
    const pick = (q.get('scenarios') || IDS.join(',')).split(',');
    go(sections.filter((s) => pick.includes(s.sc.id)));
  }
}

function renderLegend() {
  $('#legend').innerHTML = `<h2>Lane kinds</h2><div class="table-wrap"><table><tbody>${Object.entries(KINDS).map(([k, t]) =>
    `<tr><td class="l"><span class="kind">${k}</span></td><td class="l">${esc(t)}</td></tr>`).join('')}</tbody></table></div>
    <p class="muted">L0 lanes are broken on purpose: their failures are counted, never required, and their speed is not shown
    (V8 collapses a racy loop). L4n and L4w lanes (C11 to native code or wasm32) run under Node only.</p>`;
}

function renderTheorems() {
  const rows = manifest.kernels.map((k) => `<tr><td class="l"><b>${esc(k.name)}</b><br><span class="muted">${esc(k.source)}</span></td>
    <td class="l">${esc(k.says)}</td><td class="l">${k.theorems.map((t) => `<code>${esc(t.split('.').pop())}</code>`).join(', ')}</td></tr>`).join('');
  const closed = manifest.programs.filter((p) => p.closed).map((p) => `<li><code>${esc(p.closed)}</code>: in every interleaving <code>${esc(p.name)}</code> does not get stuck, and if it returns, it returns ${esc(p.expect)}</li>`).join('');
  $('#theorems').innerHTML = `<h2>What is proved</h2>
    <p>Every theorem below is checked by <code>lake build</code> in <code>iris/</code> and depends on the axioms
    propext, Classical.choice and Quot.sound only (a <code>#print axioms</code> guard fails the build otherwise).
    iris-lean ${esc(manifest.iris_lean.slice(0, 8))}, Lean ${esc(manifest.lean)}.</p>
    <div class="table-wrap"><table><thead><tr><th class="l">Kernel</th><th class="l">What the theorems say</th><th class="l">Theorems</th></tr></thead><tbody>${rows}</tbody></table></div>
    <h3>Whole programs</h3><ul>${closed}</ul>
    <p>Under sequentially consistent memory, with unbounded integers and a heap that never reuses a
    location. A whole program above: in every interleaving no thread gets stuck, and if the main thread
    returns, its value is the one stated. A kernel: each theorem holds at a call whose caller owns its
    precondition (one producer and one consumer for SpscRing, the cells touched only under the lock for
    Critical, disjoint parts for ParMap, ParMapG and Shards); in the drivers and the JavaScript glue,
    nothing checks this. Not proved: liveness (deadlock, starvation, lost wakeups), weak memory,
    performance, the translator and runtimes, the JavaScript around a kernel, and the data plane where
    a payload sits in ordinary typed arrays.</p>`;
}
