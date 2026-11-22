// P1: a shared counter, incremented by W workers for a fixed time, eight ways. Reports throughput
// (increments per microsecond, all workers together), lost updates (sum of what the workers did minus
// what the counter says), and fairness (the fewest increments of a worker / the most).
// Usage: node counter.mjs [ms=300]
import { Worker, isMainThread, workerData } from 'node:worker_threads';
const I = 16; // Int32 slots per 64-byte cache line
const C = 0, LOCK = I, NEXT = 2 * I, SERVING = 3 * I, START = 4 * I, STOP = 5 * I, SHARD = 8 * I;
if (!isMainThread) {
  const { sab, mode, w, res } = workerData; const a = new Int32Array(sab), out = new Float64Array(res);
  while (Atomics.load(a, START) === 0) Atomics.wait(a, START, 0);
  let done = 0, local = 0;
  const ops = {
    plain: () => { a[C] = a[C] + 1; },                       // non-atomic read-modify-write
    add: () => { Atomics.add(a, C, 1); },                     // one fetch-and-add
    cas: () => { for (;;) { const n = Atomics.load(a, C); if (Atomics.compareExchange(a, C, n, n + 1) === n) return; } }, // = iris-lean Counter.incr
    spin: () => { while (Atomics.compareExchange(a, LOCK, 0, 1) !== 0); a[C]++; Atomics.store(a, LOCK, 0); }, // = iris-lean SpinLock
    ticket: () => { const t = Atomics.add(a, NEXT, 1); while (Atomics.load(a, SERVING) !== t); a[C]++; Atomics.store(a, SERVING, t + 1); }, // = iris-lean TicketLock
    futex: () => { // Drepper's three-state mutex on Atomics.wait/notify (0 free, 1 locked, 2 locked with waiters)
      let c = Atomics.compareExchange(a, LOCK, 0, 1);
      if (c !== 0) { if (c !== 2) c = Atomics.exchange(a, LOCK, 2); while (c !== 0) { Atomics.wait(a, LOCK, 2); c = Atomics.exchange(a, LOCK, 2); } }
      a[C]++;
      if (Atomics.sub(a, LOCK, 1) !== 1) { Atomics.store(a, LOCK, 0); Atomics.notify(a, LOCK, 1); } },
    shardPadded: () => { a[SHARD + I * w]++; },              // each worker owns its own cache line
    shardFalse: () => { a[SHARD + w]++; },                   // each worker owns a slot, all in one cache line
    localThenPublish: () => { local++; },                    // count privately, one Atomics.add at the end
  };
  const op = ops[mode];
  for (;;) { for (let k = 0; k < 1024; k++) op(); done += 1024; if (Atomics.load(a, STOP)) break; }
  if (mode === 'localThenPublish') Atomics.add(a, C, local);
  out[w] = done;
  process.exit(0);
} else {
  const ms = +(process.argv[2] || 300);
  const run = async (mode, W) => {
    const sab = new SharedArrayBuffer(4 * (SHARD + I * 16)), res = new SharedArrayBuffer(8 * W);
    const a = new Int32Array(sab), out = new Float64Array(res);
    const ws = Array.from({ length: W }, (_, w) => new Worker(new URL(import.meta.url), { workerData: { sab, mode, w, res } }));
    await Promise.all(ws.map(x => new Promise(r => x.once('online', r))));
    await new Promise(r => setTimeout(r, 50));
    const t0 = performance.now(); Atomics.store(a, START, 1); Atomics.notify(a, START);
    await new Promise(r => setTimeout(r, ms)); Atomics.store(a, STOP, 1);
    await Promise.all(ws.map(x => new Promise(r => x.once('exit', r))));
    const t = performance.now() - t0, per = [...out], did = per.reduce((s, x) => s + x, 0);
    let got = a[C]; if (mode.startsWith('shard')) { got = 0; for (let w = 0; w < W; w++) got += a[SHARD + (mode === 'shardPadded' ? I * w : w)]; }
    return { mode, W, opsPerUs: +(did / t / 1000).toFixed(2), lost: did - got, lostPct: +((did - got) / did * 100).toFixed(2), fairness: +(Math.min(...per) / Math.max(...per)).toFixed(3) };
  };
  const rows = [];
  for (const mode of ['plain', 'add', 'cas', 'spin', 'ticket', 'futex', 'shardPadded', 'shardFalse', 'localThenPublish'])
    for (const W of [1, 2, 4, ...(['spin', 'ticket', 'futex'].includes(mode) ? [6] : [])]) { const r = await run(mode, W); rows.push(r); console.log(JSON.stringify(r)); }
}
