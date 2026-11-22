// The hand-written JavaScript side: the locks, the ring and the Mandelbrot pixel that the JS lanes
// use, written the way a JS developer would. Every `F()` is a labelled fuzz point: a no-op, or in
// fuzz mode a random spin (the same distribution as rt/runtime.mjs uses before each translated
// heap operation).

export const LINE = 16;                 // Int32 cells per 64-byte cache line

export function makeFuzz(on, seed) {
  if (!on) return () => {};
  let r = (seed | 0) || 1, sink = 0;
  return () => {
    r ^= r << 13; r ^= r >>> 17; r ^= r << 5;
    if ((r & 31) === 0) { for (let n = (r >>> 20) & 1023; n > 0; n--) sink += n; }
    return sink;
  };
}

// Locks on one Int32 cell `w` of `a` (the critical section's data lives elsewhere).
export const locks = {
  // CAS spin lock: the algorithm of iris-lean's SpinLock
  spin: {
    acquire(a, w, F) { for (;;) { F(); if (Atomics.compareExchange(a, w, 0, 1) === 0) return; } },
    release(a, w, F) { F(); Atomics.store(a, w, 0); },
  },
  // ticket lock: next ticket at w, now serving at w + 1, side by side as iris-lean's TicketLock
  // allocates its two counters
  ticket: {
    acquire(a, w, F) { F(); const t = Atomics.add(a, w, 1); for (;;) { F(); if (Atomics.load(a, w + 1) === t) return; } },
    release(a, w, F) { F(); Atomics.add(a, w + 1, 1); },
  },
  // Drepper's three-state futex mutex (0 free, 1 locked, 2 locked with waiters): FutexMutex by hand
  futex: {
    acquire(a, w, F) {
      F();
      let c = Atomics.compareExchange(a, w, 0, 1);
      if (c === 0) return;
      F();
      if (c !== 2) c = Atomics.exchange(a, w, 2);
      while (c !== 0) { Atomics.wait(a, w, 2); F(); c = Atomics.exchange(a, w, 2); }
    },
    release(a, w, F) {
      F();
      if (Atomics.sub(a, w, 1) !== 1) { F(); Atomics.store(a, w, 0); Atomics.notify(a, w, 1); }
    },
  },
};

// The iteration count of pixel p of the 256-wide image: the same fixed-point arithmetic as
// LeanUIIris/Kernels/Mandel.lean (`>>` is the arithmetic shift HeapLang's `>>>` is), so the
// image is the same pixel for pixel.
export function mandel(p) {
  const cx = (p % 256) * 10 - 2048, cy = ((p / 256) | 0) * 10 - 1280;
  let x = 0, y = 0, i = 0;
  while (i < 200) {
    const xx = (x * x) >> 10, yy = (y * y) >> 10;
    if (4096 < xx + yy) break;
    const nx = xx - yy + cx;
    y = ((x * y) >> 9) + cy;
    x = nx;
    i++;
  }
  return i;
}

// S4: one audio quantum is 128 samples; sample k of the stream has a value the consumer can check.
export const QUANTUM = 128, TICK_MS = 128 / 48;  // 2.67 ms at 48 kHz
export const sample = (k) => k % 65521;

/** Blocks the calling Worker for `ms` (Atomics.wait on a private cell: no busy waiting). */
const nap = new Int32Array(new SharedArrayBuffer(4));
export function sleep(ms) { if (ms > 0) Atomics.wait(nap, 0, 0, ms); }
/** The same without blocking the event loop (for a consumer that also receives messages). */
export function sleepAsync(ms) {
  if (ms <= 0) return Promise.resolve();
  const r = Atomics.waitAsync(nap, 0, 0, ms);
  return r.async ? r.value : Promise.resolve();
}
