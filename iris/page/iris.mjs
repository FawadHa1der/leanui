// The side-by-side page (dist/iris/index.html): runs the harness's scenarios in module Web Workers
// and shows each lane with its proof chip. Without cross-origin isolation there is no
// SharedArrayBuffer, so the page shows only what is proved, and why nothing runs.
// ?auto=1&scenarios=s1,s2&w=1,2&fuzz=off,on&quick=1 runs at once; window.__iris has the rows.
import { KINDS, chip, verdict } from './bench/chips.mjs';

const base = new URL('./', import.meta.url);
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const SCENARIOS = [['s1', 'S1 counters'], ['s2', 'S2 lock zoo'], ['s4', 'S4 SPSC ring'], ['s5', 'S5 tiles'], ['s11', 'S11 lost wakeups']];
const q = new URLSearchParams(location.search);
const state = (window.__iris = { isolated: !!globalThis.crossOriginIsolated, state: 'loading', rows: [], failures: [] });

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
  const { webHost } = await import('./bench/host-web.mjs');
  const { runScenario } = await import('./bench/core.mjs');
  const host = await webHost(base);
  const want = (k, d) => (q.get(k) || d).split(',').filter(Boolean);
  const cores = host.cores;
  const Ws = [...new Set([1, 2, 4, cores])].sort((a, b) => a - b);
  const pickS = want('scenarios', SCENARIOS.map((s) => s[0]).join(','));
  const pickW = want('w', '1,2,4').map(Number);
  $('#scenarios').insertAdjacentHTML('beforeend', SCENARIOS.map(([id, t]) =>
    `<label><input type="checkbox" value="${id}" ${pickS.includes(id) ? 'checked' : ''}> ${esc(t)}</label>`).join(''));
  $('#ws').insertAdjacentHTML('beforeend', Ws.map((w) =>
    `<label><input type="checkbox" value="${w}" ${pickW.includes(w) ? 'checked' : ''}> ${w}${w === cores ? ' (cores)' : ''}</label>`).join(''));
  if (want('fuzz', 'off').includes('on')) $('#fuzz').checked = true;
  if (q.get('quick') === '0') $('#quick').checked = false;
  $('#controls').hidden = false;
  $('#status').textContent = `${cores} logical cores; ready.`;
  $('#download').onclick = () => {
    const blob = new Blob([JSON.stringify({ generated_by: 'iris/page', ua: navigator.userAgent, cores, rows: state.rows }, null, 1)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob); a.download = 'iris-results.json'; a.click();
  };
  const run = async () => {
    const ids = [...document.querySelectorAll('#scenarios input:checked')].map((i) => i.value);
    const ws = [...document.querySelectorAll('#ws input:checked')].map((i) => +i.value);
    const fuzz = $('#fuzz').checked ? [false, true] : [false];
    $('#run').disabled = true;
    state.state = 'running'; state.rows = []; state.failures = [];
    $('#results').innerHTML = '';
    try {
      for (const id of ids) {
        const sc = await import(`./bench/scenarios/${id}.mjs`);
        const view = scenarioView(sc);
        $('#status').textContent = `running ${sc.title}…`;
        await runScenario(host, sc, { Ws: ws, fuzz, quick: $('#quick').checked, onRow(r, lane) {
          state.rows.push(r);
          const v = verdict(sc, r);
          if (v) state.failures.push(`${sc.id} ${r.lane} W=${r.W}: ${v}`);
          view.add(r, lane);
        } });
      }
      state.state = 'done';
      $('#status').textContent = state.failures.length ? `done: ${state.failures.length} verified-lane failures` : 'done: verified lanes, 0 violations';
    } catch (e) {
      state.state = 'error'; state.error = String((e && e.stack) || e);
      $('#status').textContent = 'error: ' + state.error.split('\n')[0];
    }
    $('#run').disabled = false;
    $('#download').disabled = false;
  };
  $('#run').onclick = run;
  state.state = 'ready';
  if (q.get('auto') === '1') run();
}

function scenarioView(sc) {
  const sec = document.createElement('section');
  sec.innerHTML = `<h2>${esc(sc.title)}</h2><p class="question">${esc(sc.question)}</p>
    <div class="table-wrap"><table><thead><tr><th class="l">Lane</th><th class="l">Kind</th><th>W</th><th>fuzz</th>
    <th>ops/µs</th><th>violations</th><th>fairness</th><th class="l">note</th><th class="l">proof</th></tr></thead></table></div>`;
  $('#results').append(sec);
  const tbl = sec.querySelector('table'), bodies = new Map();
  return {
    add(r, lane) {
      let tb = bodies.get(lane.id);
      if (!tb) { tb = document.createElement('tbody'); tb.className = 'lane'; tbl.append(tb); bodies.set(lane.id, tb); }
      const first = !tb.rows.length;
      const viol = Object.entries(r.violations || {}).filter(([, n]) => n);
      const vtext = r.skipped ? '' : viol.length ? `<span class="bad">${esc(viol.map(([k, n]) => `${k.replace(/_/g, ' ')} ${n}`).join(', '))}</span>` : '<span class="ok">0</span>';
      const note = r.skipped ? `skipped: ${r.skipped}` : r.error ? `error: ${String(r.error).split('\n')[0]}` : r.trap ? `trap: ${r.trap}`
        : lane.note ? lane.note(r) : (r.extra?.after_kill || '');
      const speed = r.ops_per_us == null ? (lane.noSpeed && !r.skipped ? '<span class="muted">hidden</span>' : '') : r.ops_per_us.toFixed(r.ops_per_us < 1 ? 3 : 1);
      const tr = document.createElement('tr');
      tr.innerHTML = (first ? `<td class="l">${esc(lane.label)}</td><td class="l"><span class="kind ${lane.kind}" title="${esc(KINDS[lane.kind])}">${lane.kind}</span></td>` : '<td></td><td></td>') +
        `<td>${r.W}</td><td>${r.fuzz ? 'on' : ''}</td><td>${speed}</td><td>${vtext}</td><td>${r.fairness ?? ''}</td><td class="note">${esc(note)}</td>` +
        `<td class="l">${first ? chipHtml(lane, r.W) : ''}</td>`;
      tb.append(tr);
    },
  };
}

function chipHtml(lane, W) {
  const c = chip(manifest, lane, W);
  if (!c.verified) {
    const what = lane.kind === 'M' ? 'mutant: no proof' : lane.kind === 'L0' ? (lane.uses ? 'verified kernel, broken glue' : 'broken on purpose') : 'not verified';
    return `<details class="chip"><summary>${what}</summary><p>${esc(c.text)}</p></details>`;
  }
  const li = (xs) => `<ul>${xs.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>`;
  return `<details class="chip proved"><summary>proved: ${c.theorems.length} theorems · ${esc(KINDS[c.kind])}</summary>
    <p><b>Scope.</b> ${esc(c.scope)}</p>
    <p><b>Theorems</b> (axioms: ${c.axioms.join(', ')})</p><ul>${c.theorems.map((t) => `<li><code>${esc(t)}</code></li>`).join('')}</ul>
    <p><b>They say</b></p>${li(c.says)}
    <p><b>Trusted</b></p>${li(c.trusted)}
    <p><b>Not proved</b></p>${li(c.notProved)}</details>`;
}

function renderLegend() {
  $('#legend').innerHTML = `<h2>Lane kinds</h2><div class="table-wrap"><table><tbody>${Object.entries(KINDS).map(([k, t]) =>
    `<tr><td class="l"><span class="kind ${k}">${k}</span></td><td class="l">${esc(t)}</td></tr>`).join('')}</tbody></table></div>`;
}

function renderTheorems() {
  const rows = manifest.kernels.map((k) => `<tr><td class="l"><b>${esc(k.name)}</b><br><span class="muted">${esc(k.source)}</span></td>
    <td class="l">${esc(k.says)}</td><td class="l">${k.theorems.map((t) => `<code>${esc(t.split('.').pop())}</code>`).join(', ')}</td></tr>`).join('');
  const closed = manifest.programs.filter((p) => p.closed).map((p) => `<li><code>${esc(p.closed)}</code>: <code>${esc(p.name)}</code> returns ${esc(p.expect)} in every interleaving</li>`).join('');
  $('#theorems').innerHTML = `<h2>What is proved</h2>
    <p>Every theorem below is checked by <code>lake build</code> in <code>iris/</code> and depends on the axioms
    propext, Classical.choice and Quot.sound only (a <code>#print axioms</code> guard fails the build otherwise).
    iris-lean ${esc(manifest.iris_lean.slice(0, 8))}, Lean ${esc(manifest.lean)}.</p>
    <div class="table-wrap"><table><thead><tr><th class="l">Kernel</th><th class="l">What the theorems say</th><th class="l">Theorems</th></tr></thead><tbody>${rows}</tbody></table></div>
    <h3>Whole programs</h3><ul>${closed}</ul>
    <p>In every interleaving, under sequentially consistent memory, with unbounded integers and a heap that
    never reuses a location: no thread gets stuck, and a returned value satisfies the specification. Not
    proved: liveness (deadlock, starvation, lost wakeups), weak memory, performance, the translator
    and runtimes, the JavaScript around a kernel, and the data plane where a payload sits in ordinary
    typed arrays.</p>`;
}
