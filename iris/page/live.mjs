// The live visuals of the page (page/iris.mjs): S1's counters and S5's images. Both sample shared
// memory from the main thread on requestAnimationFrame while a lane runs: they read what the lane
// writes anyway, and the page adds nothing to the lanes' loops but one Atomics.or per claimed tile
// in S5's two claiming lanes (bench/scenarios/s5.mjs: `own`, which records who drew it). Where a
// lane's state is not in shared memory until it ends, they show the final state instead (each case
// is noted where it is drawn).
//
// A visual hands the run loop a probe per lane run: probe(lane, W, sizes) returns null (the lane is
// not drawn) or { shared(s, ctx), outs(outs), stop(row) }: shared() sees what the lane's setup
// returned, outs() what its workers returned (before its check), stop() the result row.
import { esc, num, laneClass } from './chart.mjs';

function sampler(draw) {
  let on = true;
  const tick = () => { if (!on) return; draw(); requestAnimationFrame(tick); };
  requestAnimationFrame(tick);
  return () => { on = false; };
}
const ran = (r) => r && !r.skipped && !r.error && !r.trap && !r.hung;

/**
 * S1: one meter per lane. While the lane runs, its bar is the time elapsed and its figure the
 * shared counter as the page reads it (`read(lane, shared, ctx)` from views.mjs returns a function
 * that reads the counter, or null). When it ends, the bar splits into the increments the counter
 * kept and those it lost: the racy lane falls short, the others fill it.
 */
export function counterMeters(el, lanes, read) {
  el.innerHTML = `<h3>The shared counter, live</h3><p class="hint">Each lane runs on its own, one after another.
    While it runs, the figure is the counter as this page reads it from shared memory; then the bar shows
    how many of the increments the threads made the counter kept.</p><div class="meters"></div>`;
  const rows = new Map();
  for (const lane of lanes) {
    const m = document.createElement('div');
    m.className = `meter ${laneClass(lane)}`;
    m.innerHTML = `<span class="who"><i class="mark" aria-hidden="true"></i>${esc(lane.label)}</span><span class="say"></span>
      <span class="track"><i class="kept"></i><i class="lost"></i></span><span class="count">not run yet</span>`;
    el.querySelector('.meters').append(m);
    rows.set(lane.id, { m, count: m.querySelector('.count'), kept: m.querySelector('.kept'), lost: m.querySelector('.lost'), say: m.querySelector('.say') });
  }
  const show = (r, kept, lost, count, say, cls = '') => {
    r.kept.style.width = `${(100 * kept).toFixed(1)}%`; r.lost.style.width = `${(100 * lost).toFixed(1)}%`; r.lost.hidden = !lost;
    r.count.textContent = count; r.say.textContent = say; r.m.dataset.state = cls;
  };
  /** The final state of a lane from its result row (also used to show the chart's row at the end). */
  const result = (lane, row) => {
    const r = rows.get(lane.id);
    if (!r) return;
    if (!row) return show(r, 0, 0, 'not run', '', '');   // a run stopped before this lane
    if (row.skipped) return show(r, 0, 0, '–', 'skipped', '');
    if (!ran(row)) return show(r, 0, 0, '–', `✗ ${row.trap ? 'trap' : 'error'}`, 'bad');
    const made = row.ops;
    // a whole program's counter is its result: the page sees only that, not the count as it climbs
    const kept = lane.mode === 'program' ? Number(row.extra?.result) : made - (row.violations?.lost_updates || 0);
    const lost = Math.max(0, made - kept);
    show(r, kept / made, lost / made, `the counter kept ${num(kept)} of ${num(made)} increments`,
      lost ? `✗ ${(100 * lost / made).toFixed(1)}% lost` : 'none lost', lost ? 'bad' : 'done');
  };
  return {
    result,
    reset() { for (const r of rows.values()) show(r, 0, 0, 'waiting', '', ''); },
    probe(lane, W, sizes) {
      const r = rows.get(lane.id);
      if (!r) return null;
      const t0 = performance.now(), ms = sizes.ms || 1000;
      let get = null;
      show(r, 0, 0, 'the counter: 0', `running on ${W} thread${W > 1 ? 's' : ''}…`, 'running');
      const stop = sampler(() => {
        const v = get?.();
        // count locally: the count is in each worker's register until the end, and a whole program's
        // counter is in its own heap: the figure stays at 0 until the result
        r.count.textContent = `the counter: ${v == null ? 'not visible until the end' : num(v)}`;
        r.kept.style.width = `${Math.min(100, (100 * (performance.now() - t0)) / (ms + 150)).toFixed(1)}%`;
      });
      return {
        shared(s, ctx) { get = read(lane, s, ctx); },
        stop(row) { stop(); result(lane, row); },
      };
    },
  };
}

// S5's image: 256 × 256 iteration counts (1 to 200; 0 is a pixel not written yet), in tiles of 8 rows.
const SIDE = 256, N = SIDE * SIDE, TILE_ROWS = 8, GAP = 6;
const hex = (s) => { const h = s.trim().replace('#', ''); return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)); };
const rgba = ([r, g, b]) => (255 << 24) | (b << 16) | (g << 8) | r;   // little-endian ImageData word
const list = (xs) => (xs.length < 2 ? xs.join('') : `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`);

/**
 * S5: a card per lane with the image as the lane draws it and, beside it, one column per worker,
 * filled where that worker drew the rows (a row drawn by two workers is marked). A band lane's
 * owner of a row is fixed by its band; a claiming lane's comes from the claim marks it leaves in
 * shared memory (bench/scenarios/s5.mjs: `own`). The postMessage lane's image exists only once its
 * Workers return their bands, and the verified lane's stays in its whole program's HeapLang heap:
 * the first is drawn at the end, the second not at all (its checksum is checked instead).
 */
export function tileCards(el, lanes) {
  el.innerHTML = `<h3>The image, as each lane draws it</h3><p class="hint">Shade: iterations per pixel, from 1 (faintest) to 200 (strongest).
    The columns at the right are the threads, one each: a mark where that thread drew the rows; <span class="bad">red</span>: rows two threads both drew.
    Each round draws every lane's image afresh; hover over an image for its rows' owner.</p><div class="cards"></div>`;
  const cards = new Map();
  for (const lane of lanes) {
    const c = document.createElement('figure');
    c.className = `card ${laneClass(lane)}`;
    const drawn = lane.mode !== 'program';
    c.innerHTML = `<figcaption><i class="mark" aria-hidden="true"></i>${esc(lane.label)} <span class="kind">${lane.kind}</span></figcaption>
      ${drawn ? '<canvas width="256" height="256" role="img"></canvas>' : `<div class="noimg">A whole HeapLang program on the thread pool:
      its image stays in its own heap, so this page checks its checksum instead of drawing it.</div>`}<p class="cap">not run yet</p>`;
    el.querySelector('.cards').append(c);
    const canvas = c.querySelector('canvas');
    const card = { lane, c, canvas, cap: c.querySelector('.cap'), img: null, own: null, claims: null, W: 1, band: lane.mode === 'fixed' };
    if (canvas) canvas.tipAt = (e) => tipAt(card, e);
    cards.set(lane.id, card);
  }
  let lut = null, ink = '', red = '', grid = '';
  const colors = () => {
    const cs = getComputedStyle(el), v = (k) => hex(cs.getPropertyValue(k));
    const none = v('--img-none'), lo = v('--img-lo'), hi = v('--img-hi');
    lut = new Uint32Array(201);
    lut[0] = rgba(none);
    for (let i = 1; i <= 200; i++) {
      const t = Math.log(i) / Math.log(200);
      lut[i] = rgba(lo.map((a, k) => Math.round(a + (hi[k] - a) * t)));
    }
    [ink, red, grid] = ['--own', '--critical', '--grid'].map((k) => cs.getPropertyValue(k).trim());
  };
  // The owners of row y: a bit per worker (0: no one has drawn it yet). A lane with claim marks
  // (they arrive with its setup, before any pixel) has them; another one draws its band.
  const owners = (card, y) => {
    if (card.own) return card.own[Math.floor(y / TILE_ROWS)];
    if (!card.band) return 0;
    const written = card.img ? card.img[y * SIDE + SIDE - 1] !== 0 : card.done;
    return written ? 1 << Math.min(card.W - 1, Math.floor((y * SIDE * card.W) / N)) : 0;
  };
  const bits = (b) => { const ws = []; for (let i = 0; i < 31; i++) if (b & (1 << i)) ws.push(i + 1); return ws; };
  function draw(card) {
    if (!card.canvas) return;
    if (!lut) colors();
    const cw = Math.max(3, Math.min(12, Math.floor(48 / card.W)));
    const width = SIDE + GAP + cw * card.W;
    if (card.canvas.width !== width) card.canvas.width = width;
    const g = card.canvas.getContext('2d');
    const id = g.createImageData(SIDE, SIDE), px = new Uint32Array(id.data.buffer);
    if (card.img) for (let p = 0; p < N; p++) px[p] = lut[Math.min(200, card.img[p])];
    else px.fill(lut[0]);
    g.putImageData(id, 0, 0);
    g.clearRect(SIDE, 0, width - SIDE, SIDE);
    g.fillStyle = grid;
    for (let w = 0; w < card.W; w++) g.fillRect(SIDE + GAP + w * cw, 0, cw - 1, SIDE);
    for (let y = 0; y < SIDE; y++) {
      const ws = bits(owners(card, y));
      g.fillStyle = ws.length > 1 ? red : ink;
      for (const w of ws) if (w <= card.W) g.fillRect(SIDE + GAP + (w - 1) * cw, y, cw - 1, 1);
    }
  }
  function tipAt(card, e) {
    const b = card.canvas.getBoundingClientRect(), k = card.canvas.width / b.width;
    const x = Math.floor((e.clientX - b.left) * k), y = Math.floor((e.clientY - b.top) * k);
    if (y < 0 || y >= SIDE) return '';
    const ws = bits(owners(card, y)), t = Math.floor(y / TILE_ROWS);
    const who = !ws.length ? 'not drawn yet' : ws.length > 1 ? `drawn twice: by threads ${list(ws.map(String))}` : `drawn by thread ${ws[0]}`;
    const rows = card.own ? `rows ${t * TILE_ROWS}–${t * TILE_ROWS + TILE_ROWS - 1} (tile ${t})` : `row ${y}`;
    const it = x < SIDE && card.img?.[y * SIDE + x] ? ` · pixel (${x}, ${y}): ${card.img[y * SIDE + x]} iterations` : '';
    return `${rows}: ${who}${it}`;
  }
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { lut = null; for (const c of cards.values()) draw(c); });
  return {
    reset() { for (const c of cards.values()) { Object.assign(c, { img: null, own: null, claims: null, done: false }); draw(c); c.cap.textContent = 'not run yet'; } },
    probe(lane, W, sizes, round, rounds) {
      const card = cards.get(lane.id);
      if (!card) return null;
      Object.assign(card, { img: null, own: null, claims: null, W, done: false });
      card.cap.textContent = `round ${round + 1} of ${rounds}: drawing on ${W} thread${W > 1 ? 's' : ''}…`;
      // live in the first round only: later rounds keep the last picture up until theirs is done,
      // rather than flashing a blank image each time
      const stop = card.canvas && round === 0 ? sampler(() => draw(card)) : () => {};
      return {
        shared(s) {
          if (s.img) card.img = new Int32Array(s.img);
          if (s.own) card.own = new Int32Array(s.own);
        },
        // the postMessage lane: its bands arrive by transfer when its Workers end
        outs(outs) {
          if (card.img || !outs.every((o) => o.part)) return;
          card.img = new Int32Array(N);
          for (const o of outs) card.img.set(new Int32Array(o.part), o.lo);
        },
        stop(row) {
          stop(); card.done = true; draw(card);
          const v = row.violations || {}, say = [`round ${round + 1} of ${rounds}, ${W} thread${W > 1 ? 's' : ''}`];
          const bad = (t) => `<span class="bad">✗ ${esc(t)}</span>`;
          if (!ran(row)) say.push(bad(row.skipped ? 'skipped' : row.trap ? 'trap' : 'error'));
          else {
            const wrong = v.wrong_checksum || v.wrong_result;
            say.push(wrong ? bad('wrong checksum') : '✓ checksum = Σ Mandel.g');
            if (v.double_claims) say.push(bad(`${v.double_claims} tile${v.double_claims > 1 ? 's' : ''} drawn twice`));
            if (row.extra?.imbalance && W > 1) say.push(`slowest thread ${row.extra.imbalance}× the mean`);
          }
          card.cap.innerHTML = say.join(' · ');
        },
      };
    },
  };
}
