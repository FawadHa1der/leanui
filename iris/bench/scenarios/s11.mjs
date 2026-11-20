// S11, the lost-wakeup hunt: the scenario where the proof does not help. Waiters sleep with
// Atomics.wait until an event count moves; three classic mistakes lose wakeups, and a watchdog
// timeout rescues the sleepers. iris-lean proves safety only, and the futex hints are proved
// no-ops, so a misplaced or missing notify changes no theorem: FutexNoWake (FutexMutex without its
// futexWake) is a lawful Lock with the very same spec as FutexMutex. Rescues are a liveness
// symptom: they are recorded, not counted as violations.
import * as E from '../../rt/embed.mjs';
import { LINE } from '../kernels.mjs';
import { now } from '../core.mjs';
import { heapSetup, heapOpen, heapFinal } from './s2.mjs';

export const id = 's11';
export const module = 'bench/scenarios/s11.mjs';
export const title = 'S11 · Lost-wakeup hunt: where the proof does not help';
export const question = 'Sleepers wait for an event count with Atomics.wait. Who misses a wakeup, and does any proof notice?';
export const sizes = { full: { cycles: 200, ms: 300 }, quick: { cycles: 40, ms: 80 } };

const WATCHDOG_MS = 5;
const STATE = 0, EPOCH = LINE, ACK = 2 * LINE;

// Worker 0 notifies; workers 1..W wait. One cycle: publish event c, every waiter acknowledges.
function epoch(id, kind, label, variant) {
  return {
    id, kind, label, mode: 'fixed', threads: (W) => W + 1, fairness: false,
    setup: () => ({ sab: new SharedArrayBuffer(4 * 3 * LINE) }),
    note: (r) => r.extra ? `${r.extra.rescues} lost wakeups rescued by the ${WATCHDOG_MS} ms watchdog (${r.extra.cycles} cycles)` : '',
    run(ctx) {
      const a = new Int32Array(ctx.shared.sab), C = ctx.sizes.cycles, W = ctx.W, F = ctx.F;
      const t0 = ctx.ready();
      if (ctx.i === 0) {
        for (let c = 1; c <= C; c++) {
          if (variant === 'notify-before-store') Atomics.notify(a, EPOCH);
          F();
          Atomics.store(a, STATE, c);
          F();
          Atomics.add(a, EPOCH, 1);
          if (variant === 'ok') Atomics.notify(a, EPOCH);
          if (variant === 'wrong-word') Atomics.notify(a, STATE);
          if (variant === 'notify-one') Atomics.notify(a, EPOCH, 1);
          let k;
          while ((k = Atomics.load(a, ACK)) < W * c) Atomics.wait(a, ACK, k, 50);
        }
        return { ops: 0, t0, t1: now() };
      }
      let next = 1, rescues = 0, timeouts = 0;
      while (next <= C) {
        const e = Atomics.load(a, EPOCH);
        if (Atomics.load(a, STATE) >= next) { next++; Atomics.add(a, ACK, 1); Atomics.notify(a, ACK); continue; }
        F();
        if (Atomics.wait(a, EPOCH, e, WATCHDOG_MS) === 'timed-out') {
          timeouts++;
          if (Atomics.load(a, STATE) >= next) rescues++;
        }
      }
      return { ops: C, rescues, timeouts, t0, t1: now() };
    },
    check: (ctx, sh, outs) => ({ violations: {}, extra: { rescues: outs.reduce((s, o) => s + (o.rescues || 0), 0), cycles: ctx.sizes.cycles } }),
  };
}

// The verified pair: the same critical section under FutexMutex and under FutexNoWake; the
// runtime counts the futex waits and those that only the 20 ms timeout ended.
function futex(which, label) {
  const fn = which === 'NoWake' ? 'FutexNoWake.criticalNoWake' : 'Critical.criticalFutex';
  return {
    id: which === 'NoWake' ? 'nowake-verified' : 'futex-verified', kind: 'L3', label, mode: 'timed',
    lib: 'lib_locks', uses: [fn],
    scope: 'proved: the lock and the critical section (critical_spec, through each Lock instance); nothing about wakeups',
    notProved: ['that a waiter is ever woken: FutexNoWake satisfies the same theorems'],
    note: (r) => r.extra ? `${r.extra.timeouts} of ${r.extra.waits} futex waits ended only by the 20 ms timeout` : '',
    setup: (ctx) => heapSetup(ctx, which),
    async run(ctx) {
      const { K } = await heapOpen(ctx), f = K[fn], { lk, a, b } = ctx.shared;
      const t0 = ctx.ready();
      let ops = 0, torn = 0;
      while (!ctx.stopped()) { for (let k = 0; k < 8; k++) if (f(lk, a, b) !== E.TRUE) torn++; ops += 8; }
      return { ops, torn, t0, t1: now() };
    },
    async check(ctx, sh, outs) {
      const ops = outs.reduce((s, o) => s + o.ops, 0), final = await heapFinal(ctx, sh);
      const lib = await ctx.lib('lib_locks'), H = E.open(sh.heap, lib).H;
      return { ops, violations: { torn_reads: outs.reduce((s, o) => s + o.torn, 0), lost_updates: ops - final },
        extra: { waits: H[E.C_WAITS], timeouts: H[E.C_TIMEOUTS] } };
    },
  };
}

export const lanes = [
  epoch('epoch-ok', 'L2', 'event count: store, bump epoch, notify all', 'ok'),
  epoch('notify-before-store', 'L0', 'mutant: notify before the store', 'notify-before-store'),
  epoch('wrong-word', 'L0', 'mutant: notify the state word, not the epoch', 'wrong-word'),
  epoch('notify-one', 'L0', 'mutant: notify one waiter of several', 'notify-one'),
  futex('Futex', 'FutexMutex critical section (verified)'),
  futex('NoWake', 'FutexNoWake: futexWake removed (verified too)'),
];
