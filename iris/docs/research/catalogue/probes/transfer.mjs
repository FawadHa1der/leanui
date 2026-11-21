// P5: hand a buffer to a Worker and get it back: structured clone (copy both ways), transfer (move
// both ways, the sender's buffer is detached), or SharedArrayBuffer (nothing moves: the Worker writes
// in place, and a flag says it is done). ms per round trip, median of 7.
import { Worker, isMainThread, parentPort } from 'node:worker_threads';
if (!isMainThread) {
  parentPort.on('message', ({ mode, buf, flag }) => {
    const u = new Uint8Array(buf); u[0]++; u[u.length - 1]++;
    if (mode === 'clone') parentPort.postMessage(buf); else if (mode === 'transfer') parentPort.postMessage(buf, [buf]);
    else { const f = new Int32Array(flag); Atomics.store(f, 0, 1); Atomics.notify(f, 0); }
  });
} else {
  const w = new Worker(new URL(import.meta.url)); await new Promise(r => w.once('online', r));
  for (const mb of [1, 16, 64]) {
    const row = { MiB: mb };
    for (const mode of ['clone', 'transfer', 'sab']) {
      const times = [];
      let buf = mode === 'sab' ? new SharedArrayBuffer(mb << 20) : new ArrayBuffer(mb << 20); new Uint8Array(buf).fill(1);
      for (let i = 0; i < 7; i++) {
        const t0 = performance.now();
        if (mode === 'sab') { const flag = new SharedArrayBuffer(4), f = new Int32Array(flag); w.postMessage({ mode, buf, flag }); Atomics.wait(f, 0, 0); }
        else { const back = new Promise(r => w.once('message', r)); w.postMessage({ mode, buf }, mode === 'transfer' ? [buf] : []); if (mode === 'transfer' && buf.byteLength !== 0) throw new Error('not detached'); buf = await back; }
        times.push(performance.now() - t0);
      }
      times.sort((x, y) => x - y); row[mode + 'Ms'] = +times[3].toFixed(3);
    }
    console.log(JSON.stringify(row));
  }
  await w.terminate();
}
