// P6: a Worker polls a stop flag with a plain read (a[0] === 0) or with Atomics.load; the main thread
// sets it (plain store or Atomics.store) 200 ms later. Does the Worker see it within 3 s? JS allows a
// compiler to read an unordered (plain) location once for the whole loop.
import { Worker, isMainThread, workerData, parentPort } from 'node:worker_threads';
if (!isMainThread) {
  const a = new Int32Array(workerData.sab); let n = 0;
  if (workerData.mode === 'plain') { while (a[0] === 0) n++; } else { while (Atomics.load(a, 0) === 0) n++; }
  parentPort.postMessage(n);
} else {
  for (const mode of ['plain', 'atomic']) {
    const sab = new SharedArrayBuffer(4), a = new Int32Array(sab);
    const w = new Worker(new URL(import.meta.url), { workerData: { sab, mode } });
    const seen = new Promise(r => { w.once('message', n => r('saw the flag after ' + n + ' polls')); setTimeout(() => r('did NOT see the flag within 3 s'), 3200); });
    setTimeout(() => { if (mode === 'plain') a[0] = 1; else Atomics.store(a, 0, 1); }, 200);
    console.log(mode, await seen); await w.terminate();
  }
}
