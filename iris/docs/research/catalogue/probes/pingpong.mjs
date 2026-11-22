// P4: round-trip latency between two Workers (us per round trip), four ways:
// postMessage on a MessageChannel, Atomics.wait/notify, Atomics.waitAsync/notify, spinning on Atomics.load.
// Usage: node pingpong.mjs
import { Worker, isMainThread, workerData, MessageChannel } from 'node:worker_threads';
const L = 16, PING = 0, PONG = L, START = 2 * L;
if (!isMainThread) {
  const { sab, role, mode, N, port, res } = workerData; const a = new Int32Array(sab), out = new Float64Array(res);
  while (Atomics.load(a, START) === 0) Atomics.wait(a, START, 0);
  const t0 = performance.now();
  if (mode === 'post') {
    if (role === 'a') { await new Promise(r => { let k = 0; port.on('message', () => { if (++k === N) r(); else port.postMessage(k); }); port.postMessage(0); }); }
    else { let k = 0; await new Promise(r => port.on('message', m => { port.postMessage(m); if (++k === N) r(); })); }
  } else if (mode === 'wait' || mode === 'spin') {
    const [mine, theirs] = role === 'a' ? [PONG, PING] : [PING, PONG];
    for (let k = 1; k <= N; k++) {
      if (role === 'a') { Atomics.store(a, theirs, k); if (mode === 'wait') Atomics.notify(a, theirs, 1); }
      while (Atomics.load(a, mine) !== k) { if (mode === 'wait') Atomics.wait(a, mine, k - 1); }
      if (role === 'b') { Atomics.store(a, theirs, k); if (mode === 'wait') Atomics.notify(a, theirs, 1); }
    }
  } else if (mode === 'waitAsync' || mode === 'waitAsyncKeepAlive') {
    // Node: a pending Atomics.waitAsync does not keep a Worker's event loop alive (the plain mode exits mid-run)
    const keep = mode === 'waitAsyncKeepAlive' ? setInterval(() => {}, 1 << 30) : null;
    const [mine, theirs] = role === 'a' ? [PONG, PING] : [PING, PONG];
    for (let k = 1; k <= N; k++) {
      if (role === 'a') { Atomics.store(a, theirs, k); Atomics.notify(a, theirs, 1); }
      while (Atomics.load(a, mine) !== k) { const r = Atomics.waitAsync(a, mine, k - 1); if (r.async) await r.value; }
      if (role === 'b') { Atomics.store(a, theirs, k); Atomics.notify(a, theirs, 1); }
    }
    if (keep) clearInterval(keep);
  }
  out[role === 'a' ? 0 : 1] = performance.now() - t0;
  process.exit(0);
} else {
  for (const [mode, N] of [['post', 20000], ['wait', 50000], ['waitAsync', 20000], ['waitAsyncKeepAlive', 20000], ['spin', 500000]]) {
    const sab = new SharedArrayBuffer(4 * 4 * L), res = new SharedArrayBuffer(16), a = new Int32Array(sab), out = new Float64Array(res);
    const { port1, port2 } = new MessageChannel();
    const ws = [['a', port1], ['b', port2]].map(([role, port]) => new Worker(new URL(import.meta.url), { workerData: { sab, role, mode, N, port, res }, transferList: [port] }));
    await Promise.all(ws.map(x => new Promise(r => x.once('online', r)))); await new Promise(r => setTimeout(r, 50));
    Atomics.store(a, START, 1); Atomics.notify(a, START);
    await Promise.all(ws.map(x => new Promise(r => x.once('exit', r))));
    console.log(JSON.stringify({ mode, N, usPerRoundTrip: +(out[0] * 1000 / N).toFixed(3), completed: out[0] > 0 && out[1] > 0 }));
  }
}
