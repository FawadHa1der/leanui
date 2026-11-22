// Cost of "every heap access is a SeqCst Atomics op" on a data-plane-sized loop:
// a 3-tap horizontal blur over 4M Int32 cells of a SharedArrayBuffer, disjoint quarters, W workers.
import { Worker, isMainThread, workerData, parentPort } from 'node:worker_threads';
const N = 1 << 22;
if (isMainThread) {
  const W = Number(process.argv[2] || 4);
  const src = new SharedArrayBuffer(N * 4), dst = new SharedArrayBuffer(N * 4);
  const s = new Int32Array(src); for (let i = 0; i < N; i++) s[i] = (i * 2654435761) >>> 8 & 0xffff;
  for (const mode of ['plain', 'atomics-load-plain-store', 'atomics-all', 'plain', 'atomics-all']) {
    const t0 = performance.now();
    await Promise.all(Array.from({ length: W }, (_, w) => new Promise(res => {
      const wk = new Worker(new URL(import.meta.url), { workerData: { src, dst, w, W, mode } });
      wk.on('message', res);
    })));
    const t1 = performance.now();
    const d = new Int32Array(dst); let h = 0; for (let i = 0; i < N; i++) h = (h * 31 + d[i]) | 0;
    console.log(`W=${W} ${mode.padEnd(26)} ${(t1 - t0).toFixed(1)} ms (incl. worker start) hash ${h}`);
  }
} else {
  const { src, dst, w, W, mode } = workerData; const s = new Int32Array(src), d = new Int32Array(dst);
  const lo = Math.max(1, (N / W) * w), hi = Math.min(N - 1, (N / W) * (w + 1));
  const reps = 10; const t0 = performance.now();
  for (let r = 0; r < reps; r++) {
    if (mode === 'plain') for (let i = lo; i < hi; i++) d[i] = (s[i - 1] + 2 * s[i] + s[i + 1]) >> 2;
    else if (mode === 'atomics-all') for (let i = lo; i < hi; i++) Atomics.store(d, i, (Atomics.load(s, i - 1) + 2 * Atomics.load(s, i) + Atomics.load(s, i + 1)) >> 2);
    else for (let i = lo; i < hi; i++) d[i] = (Atomics.load(s, i - 1) + 2 * Atomics.load(s, i) + Atomics.load(s, i + 1)) >> 2;
  }
  parentPort.postMessage(performance.now() - t0);
}
