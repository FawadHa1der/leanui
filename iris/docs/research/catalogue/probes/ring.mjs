// P3: move N numbers from a producer Worker to a consumer Worker, and check the sum and order.
//   ring      SPSC ring in a SharedArrayBuffer: head/tail with Atomics, data with plain accesses,
//             the consumer spins when empty (the shape of an AudioWorklet queue, and of QED64's stdin ring)
//   ringWait  the same, but both sides Atomics.wait instead of spinning when the ring is full/empty
//   ringBug   failure injection: the producer publishes the tail BEFORE writing the slot
//   ringCached the ring with cached indices: each side re-reads the other's index only when it must,
//             and publishes its own every 64 items (and at the end)
//   postEach  one postMessage per number
//   postBatch postMessage of 4096 numbers at a time, buffer transferred
// Usage: node ring.mjs [N=2000000]
import { Worker, isMainThread, workerData, parentPort, MessageChannel } from 'node:worker_threads';
const L = 16, HEAD = 0, TAIL = L, START = 2 * L, DATA = 4 * L, CAP = 1 << 12;
if (!isMainThread) {
  const { sab, role, mode, N, port, res } = workerData; const a = new Int32Array(sab), out = new Float64Array(res);
  while (Atomics.load(a, START) === 0) Atomics.wait(a, START, 0);
  const t0 = performance.now();
  if (mode === 'ringCached') {
    const B = 64;
    if (role === 'producer') {
      let tail = 0, head = 0, pub = 0;
      for (let x = 1; x <= N; x++) {
        if (tail - head === CAP) { if (pub !== tail) { Atomics.store(a, TAIL, tail); pub = tail; } while (tail - (head = Atomics.load(a, HEAD)) === CAP); }
        a[DATA + (tail & (CAP - 1))] = x; tail++;
        if (tail - pub >= B) { Atomics.store(a, TAIL, tail); pub = tail; }
      }
      Atomics.store(a, TAIL, tail);
    } else {
      let head = 0, tail = 0, pub = 0, sum = 0, bad = 0, prev = 0;
      for (let k = 0; k < N; k++) {
        if (head === tail) { if (pub !== head) { Atomics.store(a, HEAD, head); pub = head; } while ((tail = Atomics.load(a, TAIL)) === head); }
        const x = a[DATA + (head & (CAP - 1))]; head++;
        if (head - pub >= B) { Atomics.store(a, HEAD, head); pub = head; }
        if (x !== prev + 1) bad++; prev = x; sum += x;
      }
      out[0] = sum; out[1] = bad;
    }
  } else if (mode.startsWith('ring')) {
    if (role === 'producer') {
      let tail = 0;
      for (let x = 1; x <= N; x++) {
        while (tail - Atomics.load(a, HEAD) === CAP) { if (mode === 'ringWait') Atomics.wait(a, HEAD, tail - CAP); }
        if (mode === 'ringBug') { Atomics.store(a, TAIL, tail + 1); a[DATA + (tail & (CAP - 1))] = x; }
        else { a[DATA + (tail & (CAP - 1))] = x; Atomics.store(a, TAIL, tail + 1); }
        tail++; if (mode === 'ringWait') Atomics.notify(a, TAIL, 1);
      }
    } else {
      let head = 0, sum = 0, bad = 0, prev = 0;
      for (let k = 0; k < N; k++) {
        while (Atomics.load(a, TAIL) === head) { if (mode === 'ringWait') Atomics.wait(a, TAIL, head); }
        const x = a[DATA + (head & (CAP - 1))]; Atomics.store(a, HEAD, ++head); if (mode === 'ringWait') Atomics.notify(a, HEAD, 1);
        if (x !== prev + 1) bad++; prev = x; sum += x;
      }
      out[0] = sum; out[1] = bad;
    }
  } else if (role === 'producer') {
    if (mode === 'postEach') for (let x = 1; x <= N; x++) port.postMessage(x);
    else for (let x = 1; x <= N; x += 4096) { const b = new Int32Array(Math.min(4096, N - x + 1)); for (let i = 0; i < b.length; i++) b[i] = x + i; port.postMessage(b, [b.buffer]); }
  } else {
    let k = 0, sum = 0, bad = 0, prev = 0;
    await new Promise(r => port.on('message', m => {
      if (typeof m === 'number') { if (m !== prev + 1) bad++; prev = m; sum += m; k++; }
      else for (let i = 0; i < m.length; i++) { const x = m[i]; if (x !== prev + 1) bad++; prev = x; sum += x; k++; }
      if (k === N) r();
    }));
    out[0] = sum; out[1] = bad;
  }
  out[role === 'producer' ? 2 : 3] = performance.now() - t0;
  process.exit(0);
} else {
  const N0 = +(process.argv[2] || 2000000);
  for (const mode of ['ring', 'ringCached', 'ringWait', 'ringBug', 'postEach', 'postBatch']) {
    const N = mode === 'postEach' ? Math.min(N0, 200000) : N0;
    const sab = new SharedArrayBuffer(4 * (DATA + CAP)), res = new SharedArrayBuffer(8 * 4), a = new Int32Array(sab), out = new Float64Array(res);
    const { port1, port2 } = new MessageChannel();
    const ws = [['producer', port1], ['consumer', port2]].map(([role, port]) => new Worker(new URL(import.meta.url), { workerData: { sab, role, mode, N, port, res }, transferList: [port] }));
    await Promise.all(ws.map(x => new Promise(r => x.once('online', r)))); await new Promise(r => setTimeout(r, 50));
    Atomics.store(a, START, 1); Atomics.notify(a, START);
    await Promise.all(ws.map(x => new Promise(r => x.once('exit', r))));
    const expect = N * (N + 1) / 2;
    console.log(JSON.stringify({ mode, N, itemsPerUs: +(N / (out[3] * 1000)).toFixed(3), sumOk: out[0] === expect, outOfOrder: out[1] }));
  }
}
