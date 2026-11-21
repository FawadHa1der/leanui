// The lane chart of a scenario (page/iris.mjs): one row per lane, in the scenario module's order.
// A row is a <details>: its summary shows the lane (a marker for its class, its name, its kind,
// what is proved) and its result: a dot on a log scale for a speed, a bar from zero for a count,
// or, for a lane broken on purpose, what went wrong instead of a speed. Opening it shows the
// lane's proof chip and the figures behind the mark. Rows are built once and updated in place, so
// a row stays open while results arrive.
import { KINDS, chip, isVerified } from './bench/chips.mjs';

export const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
export const isBroken = (lane) => lane.kind === 'L0' || lane.kind === 'M';
/** verified (L3, L3p, L4), js (L1, L2) or broken (L0, M): the class picks the marker. */
export const laneClass = (lane) => (isBroken(lane) ? 'broken' : isVerified(lane) ? 'verified' : 'js');
export const num = (x) => Math.round(x).toLocaleString('en-US');
export const speed = (x) => (x >= 100 ? num(x) : x >= 10 ? x.toFixed(1) : x >= 1 ? x.toFixed(2) : x.toPrecision(2));

/** The proof chip of a lane: a one-line summary for its row, and the body its row opens to. */
export function chipParts(manifest, lane) {
  const c = chip(manifest, lane, 1);   // a whole program's kernels are the same at every W
  if (!c.verified) {
    const what = lane.kind === 'M' ? 'mutant: no proof' : lane.kind === 'L0' ? (lane.uses ? 'verified kernel, broken glue' : 'broken on purpose') : 'not verified';
    return { summary: what, proved: false, body: `<p>${esc(c.text)}</p>` };
  }
  const li = (xs) => `<ul>${xs.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>`;
  return {
    summary: `proved: ${c.theorems.length} theorems`, proved: true,
    body: `<p><b>${esc(KINDS[c.kind])}.</b> ${esc(c.scope)}</p>
    <p><b>Theorems of the kernels it calls</b> (axioms: ${c.axioms.join(', ')})</p><ul class="thms">${c.theorems.map((t) => `<li><code>${esc(t)}</code></li>`).join('')}</ul>
    <p><b>They say</b></p>${li(c.says)}<p><b>Trusted</b></p>${li(c.trusted)}<p><b>Not proved</b></p>${li(c.notProved)}`,
  };
}

// Ticks: powers of ten on a log scale, about five round steps on a linear one.
const tickText = (v) => (v >= 10000 ? `${v / 1000}K` : v >= 1 ? v.toLocaleString('en-US') : String(+v.toPrecision(1)));
function domain(values, scale, max) {
  // a share (max: 100, in %): the axis ends at max, with room after it for the label of a full bar
  if (scale === 'linear' && max) return { x: (v) => (100 * Math.min(v, max)) / (max * 1.3), ticks: [0, 0.25, 0.5, 0.75, 1].map((f) => f * max), share: true };
  if (scale === 'linear') {
    const max = Math.max(1, ...values) * 1.35;   // room for the label at the end of the longest bar
    const step = [1, 2, 2.5, 5, 10].map((m) => m * 10 ** Math.floor(Math.log10(max / 4))).find((s) => max / s <= 5);
    const top = Math.ceil(max / step) * step, ticks = [];
    for (let v = 0; v <= top + step / 2; v += step) ticks.push(v);
    return { x: (v) => (100 * v) / top, ticks };
  }
  const lo = Math.floor(Math.log10(Math.min(...values))), hi = Math.max(lo + 2, Math.ceil(Math.log10(Math.max(...values))));
  const ticks = [];
  for (let e = lo; e <= hi; e++) ticks.push(10 ** e);
  return { x: (v) => (100 * (Math.log10(v) - lo)) / (hi - lo), ticks };
}

/**
 * Builds the chart in `el` for `lanes`. `opts`: { manifest, scale: 'log' | 'linear', unit, max }
 * (`max`: a linear axis from 0 to max, for a share).
 * Returns update(items), where items maps a lane id to what its row shows now:
 *   { state: 'idle' | 'running' | 'done', value, text, bad, error, meta, tip, figures }
 * `value` is the mark (a speed or a count) and `text` its label; `bad` replaces the mark with what
 * went wrong (a broken lane), `error` with an error; `meta` is the line under the name, `tip` the
 * mark's tooltip, `figures` the line the opened row starts with.
 */
export function laneChart(el, lanes, { manifest, scale = 'log', unit, max }) {
  el.classList.add('chart');
  el.innerHTML = `<div class="rows"></div><div class="axis" aria-hidden="true"><span class="axis-title">${esc(unit)}${scale === 'log' ? ' (log scale)' : ''}</span><span class="ticks"></span></div>`;
  const rows = new Map();
  for (const lane of lanes) {
    const c = chipParts(manifest, lane);
    const d = document.createElement('details');
    d.className = `lane-row ${laneClass(lane)}`;
    d.dataset.lane = lane.id;
    d.innerHTML = `<summary><span class="who"><i class="mark" aria-hidden="true"></i><span class="name">${esc(lane.label)}</span>
      <span class="kind" title="${esc(KINDS[lane.kind])}">${lane.kind}</span><span class="proof">${esc(c.summary)}</span><span class="meta"></span></span>
      <span class="plot"><span class="grid"></span><span class="res"></span></span></summary>
      <div class="chip${c.proved ? ' proved' : ''}"><p class="figures"></p>${c.body}</div>`;
    el.querySelector('.rows').append(d);
    rows.set(lane.id, { d, res: d.querySelector('.res'), meta: d.querySelector('.meta'), figures: d.querySelector('.figures') });
  }
  const axis = el.querySelector('.axis'), ticksEl = el.querySelector('.ticks');
  return function update(items) {
    const shown = [...items.values()].filter((i) => i.state === 'done' && i.value != null && !i.bad && !i.error);
    const values = shown.map((i) => i.value).filter((v) => v > 0);
    const dom = values.length || (max && shown.length) ? domain(values, scale, max) : null;
    axis.hidden = !dom;
    ticksEl.classList.toggle('share', !!dom?.share);
    const grid = dom ? dom.ticks.map((t) => `<i style="left:${dom.x(t).toFixed(2)}%"></i>`).join('') : '';
    if (dom) ticksEl.innerHTML = dom.ticks.map((t) => `<span style="left:${dom.x(t).toFixed(2)}%">${tickText(t)}${dom.share ? '%' : ''}</span>`).join('');
    for (const [id, r] of rows) {
      const it = items.get(id) || { state: 'idle' };
      r.d.querySelector('.grid').innerHTML = grid;
      r.meta.textContent = it.meta || '';
      r.figures.textContent = it.figures || '';
      let html;
      if (it.state === 'running') html = '<span class="busy">running…</span>';
      else if (it.state !== 'done') html = `<span class="idle">${esc(it.idle || 'not run yet')}</span>`;
      else if (it.error) html = `<span class="bad pill">✗ ${esc(it.error)}</span>`;
      else if (it.bad) html = `<span class="bad pill" data-tip="${esc(it.tip || '')}">✗ ${esc(it.bad)}</span>`;
      else if (it.value == null || !dom) html = `<span class="idle">${esc(it.text || '–')}</span>`;
      else {
        const x = it.value > 0 ? dom.x(it.value) : 0, left = scale === 'linear' || x < 68;
        const mark = scale === 'linear' ? `<i class="bar" style="width:${x.toFixed(2)}%"></i>` : `<i class="dot" style="left:${x.toFixed(2)}%"></i>`;
        const pos = left ? `left:calc(${x.toFixed(2)}% + ${scale === 'linear' ? 6 : 10}px)` : `right:calc(${(100 - x).toFixed(2)}% + 10px)`;
        html = `<span class="hit" data-tip="${esc(it.tip || '')}">${mark}<span class="val" style="${pos}">${esc(it.text)}</span></span>`;
      }
      r.res.innerHTML = html;
    }
  };
}

/** One tooltip for the page: an element with a non-empty data-tip shows it on hover, and an element
 * with a tipAt(event) method (a canvas) shows what that returns for the point under the pointer. */
export function tooltips(root) {
  const tip = document.createElement('div');
  tip.className = 'tip'; tip.hidden = true; tip.setAttribute('role', 'tooltip');
  document.body.append(tip);
  root.addEventListener('pointermove', (e) => {
    const t = e.target.closest?.('[data-tip]');
    const text = t?.dataset.tip || e.target.tipAt?.(e);
    if (!text) { tip.hidden = true; return; }
    tip.textContent = text; tip.hidden = false;
    const w = tip.offsetWidth, h = tip.offsetHeight;
    tip.style.left = `${Math.max(8, Math.min(innerWidth - w - 8, e.clientX + 12))}px`;
    tip.style.top = `${e.clientY - h - 12 < 8 ? e.clientY + 16 : e.clientY - h - 12}px`;
  });
  root.addEventListener('pointerleave', () => { tip.hidden = true; });
}
