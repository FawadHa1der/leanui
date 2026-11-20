// Runtime for the ES modules iris/LeanUIIris/Translate.lean writes. Trusted, not verified.
// One SharedArrayBuffer holds the HeapLang heap, the scheduler's state and the static constants.
//
// Value encoding (one Int32 word per value; Translate/Encoding.lean is the reference):
//   w & 7 = 0 int (w >> 3) | 1 loc (w >> 3) | 2/3 injL(int/loc) = w - 2 | 4/5 injR(int/loc) = w - 4
//           6 block at w >> 3: [hdr, fields…]; hdr 1 pair, 2 injL, 3 injR, (k << 3) | 4 closure of code k
//           7 misc: (w >> 3) & 3 unit/false/true/poison; (w >> 5) & 3 plain/injL/injR
//
// Every HeapLang Load/Store/CmpXchg/Xchg/FAA is a SeqCst Atomics operation, so the program has
// only sequentially consistent executions. Plain accesses only initialise a fresh block before its
// pointer is published, and read immutable blocks (pairs, injections, closure environments) whose
// pointer came through an Atomics operation or the fork queue: happens-before through
// synchronizes-with, an argument, not a proof.
//
// Nothing is ever freed: HeapLang never reuses a location (`free` only makes a cell unusable), and
// neither does this heap. A run that allocates per operation stops with "out of memory" once the
// buffer is full; size runs accordingly.
export const UNIT = 7, FALSE = 15, TRUE = 23, POISON = 31;
export const HDR_PAIR = 1, HDR_INJL = 2, HDR_INJR = 3;
// control cells
export const C_BRK = 1, C_QHEAD = 2, C_QTAIL = 3, C_DONE = 4, C_RESULT = 5, C_GROW = 6, C_TRAP = 7,
  C_READY = 8, C_FORKS = 9, C_LIVE = 10, C_MAXLIVE = 11, C_FREED = 12, C_WAITS = 13, C_TIMEOUTS = 14;
export const QBASE = 64, QCAP = 4096;              // fork queue ring (power of two)
export const STATIC_BASE = QBASE + QCAP;           // 4160, must match Translate.lean
const CHUNK = 1 << 15;                             // thread-local allocation buffer, in cells
const INT_MIN_W = -(2 ** 31), INT_MAX_W = 2 ** 31 - 8;

export let H = null;
let tlab = 0, tlabEnd = 0;
export const R = {};                               // filled by attach(); passed to link()

export class Stuck extends Error {}
export function stuck(msg) { throw new Stuck('HeapLang program stuck / unsupported: ' + msg); }
function ovf() { throw new Stuck('integer overflow: result outside the 29-bit encoding (HeapLang ints are unbounded)'); }

export function allocBlock(n) {
  let p = tlab;
  if (p + n > tlabEnd) {
    const sz = n > CHUNK ? n : CHUNK;
    p = Atomics.add(H, C_BRK, sz);
    if (p + sz > H.length) throw new Stuck('out of memory: HeapLang never frees, heap exhausted');
    tlabEnd = p + sz;
  }
  tlab = p + n;
  return p;
}
export function allocN(nw, v) {
  if ((nw & 7) !== 0 || nw <= 0) stuck('allocN with non-positive size');
  const n = nw >> 3, p = allocBlock(n);
  for (let i = 0; i < n; i++) H[p + i] = v;       // plain init; published by an atomic op later
  return (p << 3) | 1;
}
export function free(l) { Atomics.add(H, C_FREED, 1); /* no reuse: matches HeapLang (cells become `none`) */ }
export function mkPair(a, b) {
  const p = allocBlock(3); H[p] = HDR_PAIR; H[p + 1] = a; H[p + 2] = b; return (p << 3) | 6;
}
export function mkInjL(w) {
  const t = w & 7;
  if (t < 2) return w + 2;
  if (t === 7 && (w & 0x60) === 0) return w + 32;
  const p = allocBlock(2); H[p] = HDR_INJL; H[p + 1] = w; return (p << 3) | 6;
}
export function mkInjR(w) {
  const t = w & 7;
  if (t < 2) return w + 4;
  if (t === 7 && (w & 0x60) === 0) return w + 64;
  const p = allocBlock(2); H[p] = HDR_INJR; H[p + 1] = w; return (p << 3) | 6;
}
export function isInjL(w) {
  const t = w & 7;
  if (t === 2 || t === 3) return true;
  if (t === 4 || t === 5) return false;
  if (t === 7) { const i = w & 0x60; if (i === 32) return true; if (i === 64) return false; }
  if (t === 6) { const h = H[w >> 3]; if (h === HDR_INJL) return true; if (h === HDR_INJR) return false; }
  return stuck('case on a non-sum value');
}
export function payload(w) {
  const t = w & 7;
  if (t === 2 || t === 3) return w - 2;
  if (t === 4 || t === 5) return w - 4;
  if (t === 7) return w & ~0x60;
  return H[(w >> 3) + 1];
}
// integer arithmetic on encoded words (tag 0): a + b of encodings is the encoding of the sum
export function add(a, b) { const r = a + b; if ((r | 0) !== r) ovf(); return r; }
export function sub(a, b) { const r = a - b; if ((r | 0) !== r) ovf(); return r; }
export function mul(a, b) { const r = (a >> 3) * b; if ((r | 0) !== r) ovf(); return r; }
// division by zero follows Lean's Int.tdiv/tmod (n / 0 = 0, n % 0 = n): HeapLang does not get stuck
export function quot(a, b) { if (b === 0) return 0; const r = Math.trunc((a >> 3) / (b >> 3)) * 8; if ((r | 0) !== r) ovf(); return r; }
export function rem(a, b) { if (b === 0) return a; return ((a >> 3) % (b >> 3)) * 8; }
function isBool(w) { return w === TRUE || w === FALSE; }
export function band(a, b) { if (isBool(a)) return (a === TRUE && b === TRUE) ? TRUE : FALSE; return a & b; }
export function bor(a, b) { if (isBool(a)) return (a === TRUE || b === TRUE) ? TRUE : FALSE; return a | b; }
export function bxor(a, b) { if (isBool(a)) return (a !== b) ? TRUE : FALSE; return a ^ b; }
export function shl(a, b) {
  const n = b >> 3, m = a >> 3;
  if (n >= 0) { const r = m * 2 ** n * 8; if (!Number.isSafeInteger(r) || (r | 0) !== r) ovf(); return r; }
  return (m >> Math.min(-n, 31)) * 8;
}
export function shr(a, b) { return shl(a, -b); }
export function off(l, i) { const r = l + i; if ((r | 0) !== r) ovf(); return r; }
export function neg(w) { if (isBool(w)) return w === TRUE ? FALSE : TRUE; return ~(w >> 3) * 8; }
export function minus(w) { const r = -w; if ((r | 0) !== r) ovf(); return r; }
// The four other heap operations; the generated code takes them from R, so that fuzz mode can
// swap in versions that first spin for a random while (more interleavings, same semantics).
const ald = (l) => Atomics.load(H, l >> 3), ast = (l, v) => Atomics.store(H, l >> 3, v);
const acas = (l, e, d) => Atomics.compareExchange(H, l >> 3, e, d), axchg = (l, v) => Atomics.exchange(H, l >> 3, v);
export function faa(l, d) {
  const old = Atomics.add(H, l >> 3, d);
  const r = old + d;
  if ((r | 0) !== r) ovf();                          // wrapped in the cell: fail-stop
  return old;
}

// Futex hints (no-ops in HeapLang, Kernels/Hints.lean). The wait is timed, so a lost wakeup
// delays a waiter by at most WAIT_MS per wait; it cannot strand it.
export const WAIT_MS = 20;
// C_WAITS and C_TIMEOUTS count the waits, and those that only the timeout ended (S11).
export function futexWait(l, v) {
  if ((l & 7) === 1) {
    const r = Atomics.wait(H, l >> 3, v, WAIT_MS);  // returns at once if the cell no longer holds v
    if (r !== 'not-equal') {
      Atomics.add(H, C_WAITS, 1);
      if (r === 'timed-out') Atomics.add(H, C_TIMEOUTS, 1);
    }
  }
  return UNIT;
}

// Fuzz mode: before roughly one heap operation in 2^FUZZ_BITS, spin up to 1023 iterations. A
// delay is one more interleaving, so it cannot change a HeapLang result; it can expose a bug in
// what is trusted (translator, runtime, glue). Per thread: each worker attaches with its own seed.
const FUZZ_BITS = 5;
let rng = 1, sink = 0;
export function fuzzDelay() {
  rng ^= rng << 13; rng ^= rng >>> 17; rng ^= rng << 5;
  if ((rng & ((1 << FUZZ_BITS) - 1)) === 0) { for (let n = (rng >>> 20) & 1023; n > 0; n--) sink += n; }
}
const fuzzed = {
  ald: (l) => { fuzzDelay(); return Atomics.load(H, l >> 3); },
  ast: (l, v) => { fuzzDelay(); return Atomics.store(H, l >> 3, v); },
  acas: (l, e, d) => { fuzzDelay(); return Atomics.compareExchange(H, l >> 3, e, d); },
  axchg: (l, v) => { fuzzDelay(); return Atomics.exchange(H, l >> 3, v); },
  faa: (l, d) => { fuzzDelay(); return faa(l, d); },
};
export function futexWake(l) { if ((l & 7) === 1) Atomics.notify(H, l >> 3, 1); return UNIT; }

// Threads: fork enqueues a closure word; idle pool threads take tickets (pool.mjs).
export function fork(clo) {
  const i = Atomics.add(H, C_QTAIL, 1);
  if (i - Atomics.load(H, C_QHEAD) >= QCAP) throw new Stuck('fork queue overflow');
  const slot = QBASE + (i & (QCAP - 1));
  while (Atomics.compareExchange(H, slot, 0, clo) !== 0) Atomics.wait(H, slot, Atomics.load(H, slot), 1);
  Atomics.notify(H, slot, 1);
  Atomics.add(H, C_FORKS, 1);
  // no thread holds ticket i yet: ask the launcher for one more (HeapLang threads are unbounded)
  if (i >= Atomics.load(H, C_QHEAD)) { Atomics.add(H, C_GROW, 1); Atomics.notify(H, C_GROW, 1); }
  return UNIT;
}
export function nextTask() {
  const j = Atomics.add(H, C_QHEAD, 1);
  const slot = QBASE + (j & (QCAP - 1));
  let c;
  while ((c = Atomics.load(H, slot)) === 0) Atomics.wait(H, slot, 0);
  Atomics.store(H, slot, 0);
  Atomics.notify(H, slot, 1);
  return c;
}

// Binds this thread (this module instance) to a heap. Any thread may attach, pool thread or not:
// the allocation buffer is per module instance, so a harness Worker gets its own.
export function attach(sab, { fuzz = false, seed = 1 } = {}) {
  H = new Int32Array(sab);
  tlab = tlabEnd = 0;
  rng = (seed | 0) || 1;
  Object.assign(R, { H, allocBlock, allocN, free, fork, mkPair, mkInjL, mkInjR, isInjL, payload,
    add, sub, mul, quot, rem, band, bor, bxor, shl, shr, off, neg, minus, faa, stuck, futexWait, futexWake,
    ald, ast, acas, axchg }, fuzz ? fuzzed : {});
  return R;
}

export function initHeap(sab, prog) {
  const h = new Int32Array(sab);
  h.set(prog.STATICS, STATIC_BASE);
  // round the dynamic heap start up
  Atomics.store(h, C_BRK, (STATIC_BASE + prog.STATICS.length + 1024) & ~1023);
  Atomics.store(h, C_READY, 1);                      // publishes the statics (synchronizes-with workers' load)
}

// Printing a result, as Interp.showV prints HeapLang values.
export function decode(h, w, depth = 0) {
  if (depth > 64) return '…';
  const t = w & 7;
  switch (t) {
    case 0: return String(w >> 3);
    case 1: return `#loc${w >> 3}`;
    case 2: case 3: return `injl(${decode(h, w - 2, depth + 1)})`;
    case 4: case 5: return `injr(${decode(h, w - 4, depth + 1)})`;
    case 7: {
      const lit = ['()', 'false', 'true', 'poison'][(w >> 3) & 3];
      const inj = (w >> 5) & 3;
      return inj === 1 ? `injl(${lit})` : inj === 2 ? `injr(${lit})` : lit;
    }
    case 6: {
      const p = w >> 3, hd = h[p];
      if (hd === HDR_PAIR) return `(${decode(h, h[p + 1], depth + 1)}, ${decode(h, h[p + 2], depth + 1)})`;
      if (hd === HDR_INJL) return `injl(${decode(h, h[p + 1], depth + 1)})`;
      if (hd === HDR_INJR) return `injr(${decode(h, h[p + 1], depth + 1)})`;
      return `<closure code ${hd >> 3}>`;
    }
  }
}
