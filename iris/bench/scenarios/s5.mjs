// S5, disjoint tiles: render a 256×256 Mandelbrot (iteration counts, at most 200 per pixel) on W
// threads. The verified lane is ParMapG.pmapG over the image in the HeapLang heap with the proved
// pointwise kernel Mandel.mandel: no lock, no read-modify-write atomics, no invariant; ownership of
// disjoint halves (translated, every heap access is an SC Atomics load or store).
// The per-pixel cost is uneven (1 to 200 iterations), so equal bands are uneven work.
import { mandel } from '../kernels.mjs';
import { now } from '../core.mjs';

export const id = 's5';
export const module = 'bench/scenarios/s5.mjs';
export const title = 'S5 · Disjoint tiles: a parallel Mandelbrot without locks';
export const question = 'W threads render disjoint parts of one image. Same pixels everywhere? Who waits for whom?';
export const sizes = { full: {}, quick: {} };

const WIDTH = 256, ROWS = 256, N = WIDTH * ROWS, TILE = 8 * WIDTH;   // dynamic lanes claim 8 rows

const imageSetup = () => ({ img: new SharedArrayBuffer(4 * N), claims: new SharedArrayBuffer(4 * (N / TILE + 16)) });
const band = (ctx) => [Math.floor((ctx.i * N) / ctx.W), Math.floor(((ctx.i + 1) * N) / ctx.W)];
function check(ctx, sh, outs, img) {
  const expect = Number(ctx.manifest.programs.find((q) => q.name === 'bench_s5_mandel_w1').expect);
  let sum = 0;
  for (let p = 0; p < N; p++) sum += img[p];
  const busy = outs.map((o) => o.t1 - o.t0), mean = busy.reduce((s, b) => s + b, 0) / busy.length;
  const v = { wrong_checksum: sum === expect ? 0 : 1 };
  if (sh.claims) {
    const c = new Int32Array(sh.claims);
    let dbl = 0, missed = 0;
    for (let t = 0; t < N / TILE; t++) { if (c[t] > 1) dbl += c[t] - 1; if (c[t] === 0) missed++; }
    if (dbl || missed || ctx.dynamic) Object.assign(v, { double_claims: dbl, missed_tiles: missed });
  }
  return { ops: N, violations: v, extra: { imbalance: +(Math.max(...busy) / mean).toFixed(2), checksum: sum } };
}
const note = (r) => r.extra?.imbalance ? `slowest thread ${r.extra.imbalance}× the mean` : '';
function computeTile(img, t) { for (let p = t * TILE; p < (t + 1) * TILE; p++) img[p] = mandel(p); }
// One image takes tens of milliseconds, so a cold Worker would spend much of it in the JIT: each
// JS lane renders a sample of pixels before the start barrier.
let sink = 0;
function warm() { for (let p = 0; p < N; p += 7) sink += mandel(p); return sink; }

const program = (backend, kind, label) => ({
  id: `pmapg-${backend === 'js' ? 'verified' : backend}`, kind, label, mode: 'program', backend,
  program: (W) => `bench_s5_mandel_w${W}`, ops: () => N,
  scope: 'pmapG_spec and mandel_spec: every pixel becomes g of its index, each part owned by one thread; the init and sum loops around it are unproved glue',
  note: () => `the time includes allocating, initialising and summing the image (on the 4-vCPU VM, ${backend === 'js' ? 'about 2 ms at W = 1 and 5 to 7 ms above' : 'about 0.7 ms'})`,
  only: backend === 'js' ? undefined : 'node', onlyWhy: 'native and wasm lanes run under Node only',
});

export const lanes = [
  {
    id: 'racy-claimer-js', kind: 'L0', label: 'tiles claimed with next = next + 1 (no atomics)', mode: 'fixed', fairness: false, noSpeed: true,
    setup: () => ({ ...imageSetup(), next: new SharedArrayBuffer(64) }),
    run(ctx) {
      const img = new Int32Array(ctx.shared.img), c = new Int32Array(ctx.shared.claims), nx = new Int32Array(ctx.shared.next), F = ctx.F;
      warm();
      const t0 = ctx.ready();
      let ops = 0;
      for (;;) {
        const t = nx[0]; F(); nx[0] = t + 1;
        if (t >= N / TILE) break;
        Atomics.add(c, t, 1);
        computeTile(img, t);
        ops += TILE;
      }
      return { ops, t0, t1: now() };
    },
    check: (ctx, sh, outs) => check({ ...ctx, dynamic: true }, sh, outs, new Int32Array(sh.img)),
  },
  {
    id: 'postmessage', kind: 'L1', label: 'each Worker returns its band as a transferred buffer', mode: 'fixed', fairness: false,
    run(ctx) {
      const [lo, hi] = band(ctx);
      warm();
      const t0 = ctx.ready(), part = new Int32Array(hi - lo);
      for (let p = lo; p < hi; p++) part[p - lo] = mandel(p);
      return { ops: hi - lo, lo, part: part.buffer, t0, t1: now(), __transfer: [part.buffer] };
    },
    check(ctx, sh, outs) {
      const img = new Int32Array(N);
      for (const o of outs) img.set(new Int32Array(o.part), o.lo);
      return check(ctx, sh, outs, img);
    },
    note,
  },
  {
    id: 'sab-static-js', kind: 'L2', label: 'one SharedArrayBuffer, a band per Worker (ParMapG by hand)', mode: 'fixed', fairness: false,
    setup: imageSetup,
    run(ctx) {
      const [lo, hi] = band(ctx), img = new Int32Array(ctx.shared.img);
      warm();
      const t0 = ctx.ready();
      for (let p = lo; p < hi; p++) img[p] = mandel(p);
      return { ops: hi - lo, t0, t1: now() };
    },
    check: (ctx, sh, outs) => check(ctx, { img: sh.img }, outs, new Int32Array(sh.img)),
    note,
  },
  {
    id: 'faa-claimer-js', kind: 'L2', label: 'tiles of 8 rows claimed with Atomics.add (not verified yet)', mode: 'fixed', fairness: false,
    setup: () => ({ ...imageSetup(), next: new SharedArrayBuffer(64) }),
    run(ctx) {
      const img = new Int32Array(ctx.shared.img), c = new Int32Array(ctx.shared.claims), nx = new Int32Array(ctx.shared.next), F = ctx.F;
      warm();
      const t0 = ctx.ready();
      let ops = 0;
      for (;;) {
        F();
        const t = Atomics.add(nx, 0, 1);
        if (t >= N / TILE) break;
        Atomics.add(c, t, 1);
        computeTile(img, t);
        ops += TILE;
      }
      return { ops, t0, t1: now() };
    },
    check: (ctx, sh, outs) => check({ ...ctx, dynamic: true }, sh, outs, new Int32Array(sh.img)),
    note,
  },
  program('js', 'L3', 'ParMapG.pmapG with Mandel.mandel (verified, whole program on the pool)'),
  program('native', 'L4n', 'the same → C11 → native'),
  program('wasm', 'L4w', 'the same → C11 → wasm32'),
];
