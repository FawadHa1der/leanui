// S1, lost-update roulette: W threads increment one shared counter, or count in shards. The
// headline pair is idiomatic JavaScript (`Atomics.add`) against the same algorithm verified
// (`AtomicCounter.faaIncr`, translated), both called from the same loop.
import * as E from '../../rt/embed.mjs';
import { LINE } from '../kernels.mjs';
import { now } from '../core.mjs';

export const id = 's1';
export const module = 'bench/scenarios/s1.mjs';
export const title = 'S1 · Counters: lost-update roulette';
export const question = 'W threads add 1 to a shared count. Which ways lose updates, and what does each cost per increment?';
export const sizes = { full: { ms: 300, wrap: 4000 }, quick: { ms: 60, wrap: 4000 } };

const CH = 256;                      // increments between two looks at the stop flag
function timed(ctx, op) {
  const t0 = ctx.ready();
  let ops = 0;
  while (!ctx.stopped()) { for (let k = 0; k < CH; k++) op(); ops += CH; }
  return { ops, t0, t1: now() };
}

// JS lanes: a counter cell, then one padded shard per worker
const jsSetup = (ctx) => ({ sab: new SharedArrayBuffer(4 * LINE * (ctx.n + 2)) });
const jsCount = (shared) => new Int32Array(shared.sab)[0];
const lost = (ctx, shared, outs, final) => {
  const ops = outs.reduce((s, o) => s + o.ops, 0);
  return { ops, violations: { lost_updates: ops - final }, extra: { lost_pct: +((100 * (ops - final)) / ops).toFixed(1) } };
};
const jsLane = (o) => ({ mode: 'timed', setup: jsSetup, check: (ctx, sh, outs) => lost(ctx, sh, outs, jsCount(sh)), ...o });

// Verified lanes: the kernel from gen/js/lib_counters.mjs on a heap the main thread sets up
async function heapSetup(ctx) {
  const lib = await ctx.lib('lib_counters');
  const heap = E.newHeap(lib, 16);
  const { K } = E.open(heap, lib);
  return { heap, c: K['Counter.newcounter'](E.UNIT) };
}
async function heapOpen(ctx) {
  const lib = await ctx.lib('lib_counters');
  return E.open(ctx.shared.heap, lib, { fuzz: ctx.fuzz, seed: ctx.seed }).K;
}
async function heapCount(ctx, shared) {
  const lib = await ctx.lib('lib_counters');
  const { H } = E.open(shared.heap, lib);
  return E.toInt(H[E.cell(shared.c)]);
}
const verified = (name, o) => ({
  mode: 'timed', lib: 'lib_counters', uses: [name], setup: heapSetup,
  async run(ctx) { const K = await heapOpen(ctx), f = K[name], c = ctx.shared.c; return timed(ctx, () => f(c)); },
  check: async (ctx, sh, outs) => lost(ctx, sh, outs, await heapCount(ctx, sh)),
  scope: 'kernel proved; the loop that calls it is the JS glue every lane shares',
  ...o,
});

const program = (backend, prog, label, K) => ({
  id: backend === 'js' ? `${prog}-verified` : `${prog}-${backend}`, mode: 'program', backend, program: (W) => `bench_s1_${prog}_w${W}`,
  ops: (W) => W * K, kind: backend === 'js' ? 'L3' : backend === 'native' ? 'L4n' : 'L4w', label,
  scope: 'whole program: kernel proved, HeapLang driver unproved glue', only: backend === 'js' ? undefined : 'node',
  onlyWhy: 'native and wasm lanes run under Node only',
});

export const lanes = [
  jsLane({
    id: 'racy-js', kind: 'L0', label: 'a[0] = a[0] + 1 (no synchronisation)', noSpeed: true,
    note: (r) => r.extra?.lost_pct ? `${r.extra.lost_pct}% of the increments lost; V8 collapses this loop, so no speed` : '',
    run: (ctx) => { const a = new Int32Array(ctx.shared.sab), F = ctx.F; return timed(ctx, () => { F(); a[0] = a[0] + 1; }); },
  }),
  jsLane({
    id: 'atomics-add-js', kind: 'L1', label: 'Atomics.add (idiomatic)',
    run: (ctx) => { const a = new Int32Array(ctx.shared.sab), F = ctx.F; return timed(ctx, () => { F(); Atomics.add(a, 0, 1); }); },
  }),
  verified('AtomicCounter.faaIncr', { id: 'faa-verified', kind: 'L3', label: 'faaIncr (verified FAA, translated)' }),
  jsLane({
    id: 'cas-js', kind: 'L2', label: 'compareExchange loop by hand',
    run: (ctx) => {
      const a = new Int32Array(ctx.shared.sab), F = ctx.F;
      return timed(ctx, () => { for (;;) { F(); const n = Atomics.load(a, 0); F(); if (Atomics.compareExchange(a, 0, n, n + 1) === n) return; } });
    },
  }),
  verified('AtomicCounter.casIncr', { id: 'casincr-verified', kind: 'L3', label: 'casIncr (verified CAS loop, translated)' }),
  verified('Counter.incr', { id: 'counter-verified', kind: 'L3', label: "iris-lean's Counter.incr (CAS loop)" }),
  jsLane({
    id: 'local-js', kind: 'L1', label: 'count locally, one Atomics.add at the end',
    note: () => 'V8 keeps the count in a register: no memory traffic per increment',
    run: (ctx) => {
      const a = new Int32Array(ctx.shared.sab), F = ctx.F;
      let local = 0;
      const r = timed(ctx, () => { F(); local++; });
      Atomics.add(a, 0, local);
      return r;
    },
  }),
  jsLane({
    id: 'shards-js', kind: 'L2', label: "own padded shard, Atomics load+store (Shards' algorithm)",
    run: (ctx) => {
      const a = new Int32Array(ctx.shared.sab), F = ctx.F, s = LINE * (ctx.i + 1);
      const r = timed(ctx, () => { F(); Atomics.store(a, s, Atomics.load(a, s) + 1); });
      Atomics.add(a, 0, Atomics.load(a, s));
      return r;
    },
  }),
  program('js', 'shards', 'Shards.shardCount (verified, whole program on the pool)', 1000000),
  program('native', 'shards', 'Shards.shardCount → C11 → native', 1000000),
  program('wasm', 'shards', 'Shards.shardCount → C11 → wasm32', 1000000),
  program('native', 'faa', 'faaIncr driver → C11 → native', 200000),
  program('wasm', 'faa', 'faaIncr driver → C11 → wasm32', 200000),
  // the wrap start: near the top of the integers, each of 2 workers adds `wrap` times
  {
    id: 'wrap-js', kind: 'L1', label: 'Atomics.add from 2^31 − wrap', mode: 'fixed', oneW: 2, noSpeed: true,
    setup: (ctx) => { const sab = new SharedArrayBuffer(64); new Int32Array(sab)[0] = 2 ** 31 - ctx.sizes.wrap; return { sab }; },
    run: (ctx) => { const a = new Int32Array(ctx.shared.sab), t0 = ctx.ready(); for (let k = 0; k < ctx.sizes.wrap; k++) Atomics.add(a, 0, 1); return { ops: ctx.sizes.wrap, t0, t1: now() }; },
    check: (ctx, sh) => { const v = new Int32Array(sh.sab)[0]; return { violations: { wrapped_silently: v < 0 ? 1 : 0 }, extra: { final: v } }; },
    note: (r) => `final value ${r.extra?.final} (Int32 wrapped, no error)`,
  },
  {
    id: 'wrap-verified', kind: 'L3', label: 'faaIncr from 2^28 − wrap', mode: 'fixed', oneW: 2, noSpeed: true, expectTrap: true,
    lib: 'lib_counters', uses: ['AtomicCounter.faaIncr'],
    async setup(ctx) { const s = await heapSetup(ctx); const lib = await ctx.lib('lib_counters'); E.open(s.heap, lib).H[E.cell(s.c)] = E.int(2 ** 28 - ctx.sizes.wrap); return s; },
    // the other worker stops at the harness's stop flag, set when one traps
    async run(ctx) { const K = await heapOpen(ctx), t0 = ctx.ready(); for (let k = 0; k < ctx.sizes.wrap && !ctx.stopped(); k++) K['AtomicCounter.faaIncr'](ctx.shared.c); return { ops: ctx.sizes.wrap, t0, t1: now() }; },
    note: (r) => r.trap ? 'trapped: HeapLang ints are unbounded, the encoding is 29-bit' : 'did not trap',
    scope: 'kernel proved for unbounded integers. In the 29-bit encoding, faa detects overflow only after the wrapped word is in ' +
      'the cell: the trapping thread stops and the run is reported as a trap, but the other thread may observe the wrapped value ' +
      'until the harness stops it',
  },
];
