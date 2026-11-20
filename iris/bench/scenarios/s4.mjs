// S4, the glitch counter: a producer Worker feeds a consumer through a single-producer,
// single-consumer ring; the consumer stands in for an AudioWorklet and takes one 128-sample quantum
// every 2.67 ms ("tick"), or as fast as it can ("stress", where races show). W is the number of
// independent producer/consumer pairs, so 2W threads.
//
// Two verified lanes, as the critique asks:
//   ring-heap        L3   every sample goes through SpscRing.tryPush/tryPop in the HeapLang heap;
//                         fully covered (P i v := v = the i-th sample), every access an SC atomic
//   ring-dataplane   L3p  the ring carries block numbers; the samples are in a Float32Array that
//                         JavaScript fills and reads: the proof covers the protocol, not the bytes
// and the injected bug in three places: hand-written JS (ring-early-js), the verified protocol with
// glue that publishes before it writes (ring-dataplane-early: same proof, stale data), and the
// HeapLang mutant tryPushEarly (heap-mutant: no proof exists).
import * as E from '../../rt/embed.mjs';
import { LINE, QUANTUM as Q, TICK_MS, sample, sleep, sleepAsync } from '../kernels.mjs';
import { now } from '../core.mjs';

export const id = 's4';
export const module = 'bench/scenarios/s4.mjs';
export const title = 'S4 · SPSC ring: the glitch counter';
export const question = 'A producer feeds a 2.67 ms audio-style consumer through a ring. Underruns, stale or reordered samples, CPU per sample.';
export const sizes = { full: { ms: 400 }, quick: { ms: 120 } };

const CAPB = 8;              // ring capacity in blocks of Q samples
const B = CAPB + 2;          // payload blocks of the data-plane lanes (see `dataplane` below)
const HEAD = 0, TAIL = LINE;

// One loop for every consumer: `take()` returns 1 for a quantum delivered, 0 for an underrun.
async function consume(ctx, take, { tick, asyncSleep } = {}) {
  const t0 = ctx.ready();
  let ticks = 0, underruns = 0, next = now() + TICK_MS;
  while (!ctx.stopped()) {
    if (tick) {
      const d = next - now();
      if (d > 0) { if (asyncSleep) await sleepAsync(d); else sleep(d); }
      next += TICK_MS;
      ticks++;
      if (!take()) underruns++;
    } else if (asyncSleep) { await sleepAsync(1); } else take();
  }
  return { t0, t1: now(), ticks, underruns };
}
function produceLoop(ctx, step, tick) {
  const t0 = ctx.ready();
  while (!ctx.stopped()) if (!step()) { if (tick) sleep(0.2); else ctx.F(); }
  return { producer: true, t0, t1: now() };
}
const pairOf = (ctx) => ({ p: ctx.i >> 1, consumer: (ctx.i & 1) === 1 });
function result(outs) {
  const cs = outs.filter((o) => !o.producer);
  const sum = (k) => cs.reduce((s, o) => s + (o[k] || 0), 0);
  return { ops: sum('samples'), violations: { stale_or_reordered: sum('stale') },
    extra: { underruns: sum('underruns'), ticks: sum('ticks') } };
}
const note = (r) => r.extra?.ticks ? `${r.extra.underruns} underruns in ${r.extra.ticks} ticks` : '';

// Hand-written JS ring (ringbuf.js style): Atomics on the two block indices, plain Float32 slots
function jsRing(idBase, kind, label, early) {
  return [true, false].map((tick) => ({
    id: tick ? idBase : `${idBase}-stress`, kind, label: label + (tick ? '' : ', consumer flat out'),
    mode: 'timed', threads: (W) => 2 * W, fairness: false, noSpeed: kind === 'L0', note,
    setup: (ctx) => ({ idx: Array.from({ length: ctx.W }, () => new SharedArrayBuffer(4 * 2 * LINE)),
      data: Array.from({ length: ctx.W }, () => new SharedArrayBuffer(4 * CAPB * Q)) }),
    async run(ctx) {
      const { p, consumer } = pairOf(ctx), a = new Int32Array(ctx.shared.idx[p]), d = new Float32Array(ctx.shared.data[p]), F = ctx.F;
      if (!consumer) {
        let t = 0;
        return produceLoop(ctx, () => {
          if (t - Atomics.load(a, HEAD) >= CAPB) return false;
          const base = (t % CAPB) * Q;
          if (early) Atomics.store(a, TAIL, t + 1);
          for (let j = 0; j < Q; j++) { if (j === 64) F(); d[base + j] = sample(t * Q + j); }
          if (!early) Atomics.store(a, TAIL, t + 1);
          t++;
          return true;
        }, tick);
      }
      let h = 0, samples = 0, stale = 0;
      const r = await consume(ctx, () => {
        F();
        if (Atomics.load(a, TAIL) === h) return 0;
        const base = (h % CAPB) * Q;
        for (let j = 0; j < Q; j++) if (d[base + j] !== sample(h * Q + j)) { stale++; break; }
        Atomics.store(a, HEAD, ++h);
        samples += Q;
        return 1;
      }, { tick });
      return { ...r, samples, stale };
    },
    check: (ctx, sh, outs) => result(outs),
  }));
}

// Verified lanes: SpscRing from gen/js/lib_ring.mjs, one ring per pair in one heap
async function ringSetup(ctx, cap) {
  const lib = await ctx.lib('lib_ring');
  const heap = E.newHeap(lib, 16);
  E.open(heap, lib);
  const rings = Array.from({ length: ctx.W }, () => ({ buf: E.alloc(cap, E.int(-1)), hd: E.alloc(1, E.int(0)), tl: E.alloc(1, E.int(0)) }));
  return { heap, rings, data: Array.from({ length: ctx.W }, () => new SharedArrayBuffer(4 * B * Q)) };
}
async function ringOpen(ctx) {
  const lib = await ctx.lib('lib_ring');
  return E.open(ctx.shared.heap, lib, { fuzz: ctx.fuzz, seed: ctx.seed }).K;
}

// Payload in the heap: each sample is one ring item (capacity CAPB·Q samples)
function heapRing(idBase, kind, label, push, scope) {
  return [true, false].map((tick) => ({
    id: tick ? idBase : `${idBase}-stress`, kind, label: label + (tick ? '' : ', consumer flat out'),
    mode: 'timed', threads: (W) => 2 * W, fairness: false, noSpeed: kind === 'M', note,
    lib: 'lib_ring', uses: [push, 'SpscRing.tryPop'], scope,
    setup: (ctx) => ringSetup(ctx, CAPB * Q),
    async run(ctx) {
      const K = await ringOpen(ctx), { p, consumer } = pairOf(ctx), { buf, hd, tl } = ctx.shared.rings[p], n = E.int(CAPB * Q);
      const tryPush = K[push], tryPop = K['SpscRing.tryPop'];
      if (!consumer) {
        let k = 0;
        return produceLoop(ctx, () => {
          for (let j = 0; j < Q; j++, k++) if (tryPush(buf, hd, tl, n, E.int(sample(k))) !== E.TRUE) return j > 0;
          return true;
        }, tick);
      }
      let k = 0, samples = 0, stale = 0;
      const r = await consume(ctx, () => {
        for (let j = 0; j < Q; j++) {
          const v = E.option(tryPop(buf, hd, tl, n));
          if (v === undefined) return 0;
          if (v !== E.int(sample(k))) stale++;
          k++; samples++;
        }
        return 1;
      }, { tick });
      return { ...r, samples, stale };
    },
    check: (ctx, sh, outs) => result(outs),
  }));
}

// Verified protocol, trusted data plane: the ring carries block numbers (capacity CAPB); block t's
// samples are in payload block t % B of a Float32Array. The producer fills block t before pushing
// t, possibly while the ring is still full. That is safe only because B ≥ CAPB + 2: once push t−1
// succeeded the consumer has popped at least t−CAPB−1 blocks, so the one it may still be reading is
// ≥ t−CAPB−1, never ≡ t (mod B). This argument is the trusted glue; no theorem states it.
function dataplane(idBase, kind, label, early) {
  return [true, false].map((tick) => ({
    id: tick ? idBase : `${idBase}-stress`, kind, label: label + (tick ? '' : ', consumer flat out'),
    mode: 'timed', threads: (W) => 2 * W, fairness: false, noSpeed: kind === 'L0', note,
    lib: 'lib_ring', uses: ['SpscRing.tryPush', 'SpscRing.tryPop'],
    scope: 'protocol proved (the i-th pop returns the i-th push); the Float32Array payload and the JS that fills and reads it are trusted',
    trusted: ['payload block t % B is written only by the producer before it pushes t, and read only by the consumer after it pops t (B = capacity + 2)'],
    setup: (ctx) => ringSetup(ctx, CAPB),
    async run(ctx) {
      const K = await ringOpen(ctx), { p, consumer } = pairOf(ctx), { buf, hd, tl } = ctx.shared.rings[p], n = E.int(CAPB);
      const d = new Float32Array(ctx.shared.data[p]), F = ctx.F;
      const tryPush = K['SpscRing.tryPush'], tryPop = K['SpscRing.tryPop'];
      const fill = (t) => { const base = (t % B) * Q; for (let j = 0; j < Q; j++) { if (j === 64) F(); d[base + j] = sample(t * Q + j); } };
      if (!consumer) {
        let t = 0, filled = -1;
        return produceLoop(ctx, () => {
          if (!early && filled < t) { fill(t); filled = t; }
          if (tryPush(buf, hd, tl, n, E.int(t)) !== E.TRUE) return false;
          if (early) fill(t);
          t++;
          return true;
        }, tick);
      }
      let h = 0, samples = 0, stale = 0;
      const r = await consume(ctx, () => {
        const v = E.option(tryPop(buf, hd, tl, n));
        if (v === undefined) return 0;
        const t = E.toInt(v);
        if (t !== h) stale++;
        const base = (t % B) * Q;
        for (let j = 0; j < Q; j++) if (d[base + j] !== sample(t * Q + j)) { stale++; break; }
        h++; samples += Q;
        return 1;
      }, { tick });
      return { ...r, samples, stale };
    },
    check: (ctx, sh, outs) => result(outs),
  }));
}

// postMessage: CAPB block buffers circulate by transfer between the two Workers (backpressure
// for free: the producer fills only buffers the consumer has sent back)
const postmessage = [true, false].map((tick) => ({
  id: tick ? 'postmessage' : 'postmessage-stress', kind: 'L1',
  label: 'postMessage, block buffers transferred back and forth' + (tick ? '' : ', consumer flat out'),
  mode: 'timed', threads: (W) => 2 * W, fairness: false, note,
  perWorker(ctx) {
    const out = [];
    for (let p = 0; p < ctx.W; p++) {
      const ch = new MessageChannel();
      out.push({ data: { port: ch.port1 }, transfer: [ch.port1] }, { data: { port: ch.port2 }, transfer: [ch.port2] });
    }
    return out;
  },
  async run(ctx) {
    const port = ctx.data.port, { consumer } = pairOf(ctx);
    if (!consumer) {
      let t = 0;
      const send = (buf) => {
        if (ctx.stopped()) return;
        const f = new Float32Array(buf);
        for (let j = 0; j < Q; j++) f[j] = sample(t * Q + j);
        port.postMessage({ t, buf }, [buf]);
        t++;
      };
      port.onmessage = (e) => send(e.data);
      ctx.ready();
      for (let i = 0; i < CAPB; i++) send(new ArrayBuffer(4 * Q));
      while (!ctx.stopped()) await sleepAsync(5);
      port.onmessage = null; port.close();
      return { producer: true, t1: now() };
    }
    const queue = [];
    let h = 0, samples = 0, stale = 0;
    const take = () => {
      const m = queue.shift();
      if (!m) return 0;
      const f = new Float32Array(m.buf);
      if (m.t !== h) stale++;
      for (let j = 0; j < Q; j++) if (f[j] !== sample(m.t * Q + j)) { stale++; break; }
      h++; samples += Q;
      port.postMessage(m.buf, [m.buf]);
      return 1;
    };
    port.onmessage = (e) => { queue.push(e.data); if (!tick) take(); };
    const r = await consume(ctx, take, { tick, asyncSleep: true });
    port.onmessage = null; port.close();
    return { ...r, samples, stale };
  },
  check: (ctx, sh, outs) => result(outs),
}));

export const lanes = [
  ...jsRing('ring-early-js', 'L0', 'ring by hand, tail published before the slot is written', true),
  ...postmessage,
  ...jsRing('ring-js', 'L2', 'ring by hand (Atomics indices, plain Float32 slots)', false),
  ...heapRing('ring-heap', 'L3', 'SpscRing, one sample per item, payload in the heap', 'SpscRing.tryPush',
    'kernel proved (FIFO hand-off of each sample); the loops that call it are JS glue'),
  ...dataplane('ring-dataplane', 'L3p', 'SpscRing carries block numbers, samples in a Float32Array', false),
  ...dataplane('ring-dataplane-early', 'L0', 'the verified ring, but the glue fills the block after pushing it', true),
  ...heapRing('heap-mutant', 'M', 'tryPushEarly (HeapLang mutant: publishes, then writes)', 'Programs.tryPushEarly',
    'no proof: the mutant breaks the ring invariant'),
];
