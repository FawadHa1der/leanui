// S2, the lock zoo: W threads run the same critical section (read two cells, check they are equal,
// bump both) under different locks. One theorem (`Critical.critical_spec`, for every instance of
// iris-lean's `Lock`) covers the three verified locks; it says nothing about their speed, their
// fairness under oversubscription, or a holder that dies (the kill test).
import * as E from '../../rt/embed.mjs';
import { LINE, locks } from '../kernels.mjs';
import { now, CTL_HELD } from '../core.mjs';

export const id = 's2';
export const module = 'bench/scenarios/s2.mjs';
export const title = 'S2 · Lock zoo: one theorem, very different locks';
export const question = 'W threads take a lock, check that two cells are equal and bump both. Same safety proof for three locks; how do they behave, and what if the holder dies?';
export const sizes = { full: { ms: 300 }, quick: { ms: 60 } };

const CH = 32;
const LOCK = 0, A = 2 * LINE, B = 3 * LINE;

function timed(ctx, op) {
  const t0 = ctx.ready();
  let ops = 0, torn = 0;
  while (!ctx.stopped()) { for (let k = 0; k < CH; k++) torn += op(); ops += CH; }
  return { ops, torn, t0, t1: now() };
}
const result = (outs, final) => {
  const ops = outs.reduce((s, o) => s + o.ops, 0);
  return { ops, violations: { torn_reads: outs.reduce((s, o) => s + o.torn, 0), lost_updates: ops - final } };
};

// JS lanes: the lock word, then the two cells, each on its own cache line; a plain body
const jsSetup = () => ({ sab: new SharedArrayBuffer(4 * LINE * 4) });
const jsCheck = (ctx, sh, outs) => result(outs, new Int32Array(sh.sab)[A]);
function jsLock(id, kind, label, lock) {
  return {
    id, kind, label, mode: 'timed', setup: jsSetup, check: jsCheck,
    run(ctx) {
      const a = new Int32Array(ctx.shared.sab), F = ctx.F, L = locks[lock];
      return timed(ctx, () => {
        L.acquire(a, LOCK, F);
        const x = a[A], y = a[B];
        a[A] = x + 1; a[B] = y + 1;
        L.release(a, LOCK, F);
        return x === y ? 0 : 1;
      });
    },
  };
}

// Verified lanes: Critical.critical<Lock> from gen/js/lib_locks.mjs; the whole section is HeapLang
const NEW = { Spin: 'SpinLock.newlock', Ticket: 'TicketLock.newlock', Futex: 'FutexMutex.newlock', NoWake: 'FutexMutex.newlock' };
export async function heapSetup(ctx, which) {
  const lib = await ctx.lib('lib_locks');
  const heap = E.newHeap(lib, 16);
  const { K } = E.open(heap, lib);
  return { heap, lk: K[NEW[which]](E.UNIT), a: E.alloc(1, E.int(0)), b: E.alloc(1, E.int(0)) };
}
export async function heapOpen(ctx) {
  const lib = await ctx.lib('lib_locks');
  return E.open(ctx.shared.heap, lib, { fuzz: ctx.fuzz, seed: ctx.seed });
}
export async function heapFinal(ctx, sh) {
  const lib = await ctx.lib('lib_locks');
  const { H } = E.open(sh.heap, lib);
  return E.toInt(H[E.cell(sh.a)]);
}
function verified(which, kind, label) {
  const fn = which === 'NoWake' ? 'FutexNoWake.criticalNoWake' : `Critical.critical${which}`;
  return {
    id: `${which.toLowerCase()}-verified`, kind, label, mode: 'timed', lib: 'lib_locks', uses: [fn],
    scope: 'the lock and the whole critical section proved (critical_spec); the loop around it is JS glue',
    setup: (ctx) => heapSetup(ctx, which),
    async run(ctx) {
      const { K } = await heapOpen(ctx), f = K[fn], { lk, a, b } = ctx.shared;
      return timed(ctx, () => (f(lk, a, b) === E.TRUE ? 0 : 1));
    },
    check: async (ctx, sh, outs) => result(outs, await heapFinal(ctx, sh)),
  };
}

const program = (backend, lock) => ({
  id: `${lock}-${backend}`, kind: backend === 'native' ? 'L4n' : 'L4w', mode: 'program', backend,
  label: `critical${lock === 'futex' ? 'Futex' : 'Spin'} driver → C11 → ${backend === 'native' ? 'native' : 'wasm32'} (50,000 sections per thread)`,
  program: (W) => `bench_s2_${lock}_w${W}`, ops: (W) => W * 50000, only: 'node', onlyWhy: 'native and wasm lanes run under Node only',
  scope: 'whole program: lock and section proved, HeapLang driver unproved glue',
});

// The kill test: one worker takes the lock and is terminated while holding it
function killJs(id, kind, label, lock) {
  return {
    id, kind, label, mode: 'kill', setup: jsSetup,
    run(ctx) {
      const a = new Int32Array(ctx.shared.sab), F = () => {};
      locks[lock].acquire(a, LOCK, F);
      if (ctx.data.role === 'holder') { Atomics.store(ctx.ctl, CTL_HELD, 1); Atomics.wait(ctx.ctl, 15, 0); }
      locks[lock].release(a, LOCK, F);
      return { ops: 1 };
    },
  };
}
function killVerified(which, label) {
  const ns = { Spin: 'SpinLock', Ticket: 'TicketLock', Futex: 'FutexMutex' }[which];
  return {
    id: `kill-${which.toLowerCase()}-verified`, kind: 'L3', label, mode: 'kill', lib: 'lib_locks',
    uses: [`${ns}.acquire`, `${ns}.release`], scope: 'the lock proved; nothing in HeapLang can die',
    setup: (ctx) => heapSetup(ctx, which),
    async run(ctx) {
      const { K } = await heapOpen(ctx), lk = ctx.shared.lk;
      K[`${ns}.acquire`](lk);
      if (ctx.data.role === 'holder') { Atomics.store(ctx.ctl, CTL_HELD, 1); Atomics.wait(ctx.ctl, 15, 0); }
      K[`${ns}.release`](lk);
      return { ops: 1 };
    },
  };
}

let runs = 0;
export const lanes = [
  {
    id: 'no-lock', kind: 'L0', label: 'no lock', mode: 'timed', noSpeed: true, setup: jsSetup, check: jsCheck,
    run(ctx) {
      const a = new Int32Array(ctx.shared.sab), F = ctx.F;
      return timed(ctx, () => { F(); const x = a[A]; F(); const y = a[B]; a[A] = x + 1; F(); a[B] = y + 1; return x === y ? 0 : 1; });
    },
  },
  jsLock('futex-js', 'L1', 'futex mutex by hand (Drepper), plain body', 'futex'),
  verified('Futex', 'L3', 'FutexMutex + critical section (verified)'),
  jsLock('spin-js', 'L2', 'CAS spin lock by hand, plain body', 'spin'),
  verified('Spin', 'L3', 'SpinLock + critical section (verified)'),
  jsLock('ticket-js', 'L2', 'ticket lock by hand, plain body', 'ticket'),
  verified('Ticket', 'L3', 'TicketLock + critical section (verified)'),
  {
    id: 'weblocks', kind: 'L1', label: 'Web Locks (navigator.locks), one request per section', mode: 'timed',
    only: 'browser', onlyWhy: 'Node 22 has no navigator.locks',
    setup: () => ({ ...jsSetup(), name: `iris-s2-${Date.now()}-${runs++}` }), check: jsCheck,
    async run(ctx) {
      const a = new Int32Array(ctx.shared.sab), name = ctx.shared.name;
      const t0 = ctx.ready();
      let ops = 0, torn = 0;
      while (!ctx.stopped()) {
        await navigator.locks.request(name, () => { const x = a[A], y = a[B]; a[A] = x + 1; a[B] = y + 1; if (x !== y) torn++; });
        ops++;
      }
      return { ops, torn, t0, t1: now() };
    },
  },
  program('native', 'futex'), program('wasm', 'futex'), program('native', 'spin'), program('wasm', 'spin'),
  killJs('kill-spin-js', 'L2', 'kill test: spin lock by hand', 'spin'),
  killJs('kill-futex-js', 'L1', 'kill test: futex mutex by hand', 'futex'),
  killVerified('Spin', 'kill test: SpinLock (verified)'),
  killVerified('Ticket', 'kill test: TicketLock (verified)'),
  killVerified('Futex', 'kill test: FutexMutex (verified)'),
  {
    id: 'kill-weblocks', kind: 'L1', label: 'kill test: Web Locks', mode: 'kill', only: 'browser', onlyWhy: 'Node 22 has no navigator.locks',
    setup: () => ({ name: `iris-kill-${Date.now()}-${runs++}` }),
    async run(ctx) {
      if (ctx.data.role === 'holder') {
        await navigator.locks.request(ctx.shared.name, () => { Atomics.store(ctx.ctl, CTL_HELD, 1); return new Promise(() => {}); });
      }
      await navigator.locks.request(ctx.shared.name, () => {});
      return { ops: 1 };
    },
  },
];
