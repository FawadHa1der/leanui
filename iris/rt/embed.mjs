// Calling verified kernels from JavaScript: the embedding ABI of the library modules that
// iris/Gen.lean writes (gen/js/lib_*.mjs). Trusted, not verified.
//
//   const sab = newHeap(lib);               // once, by the thread that sets up
//   const { K } = open(sab, lib);           // in every thread that calls a kernel
//   const lk = K['FutexMutex.newlock'](UNIT);
//   K['Critical.criticalFutex'](lk, a, b) === TRUE
//
// K maps a constant's name (without its namespace prefix) to its uncurried entry: arguments and
// results are encoded words (int n is n·8; runtime.mjs has the encoding). A thread that opens a
// heap gets its own allocation buffer, so any Worker may call, not only pool threads; a kernel
// that forks needs the pool (launch.mjs). What the caller does between calls (which cells it
// passes, what it reads or writes itself) is glue: outside every proof.
import * as RT from './runtime.mjs';

export const UNIT = RT.UNIT, FALSE = RT.FALSE, TRUE = RT.TRUE;
/** Control cells: futex waits, and those that only the timeout ended. */
export const C_WAITS = RT.C_WAITS, C_TIMEOUTS = RT.C_TIMEOUTS;
const MAX = 2 ** 28;

export function newHeap(lib, mb = 64) {
  const sab = new SharedArrayBuffer(mb * 1024 * 1024);
  RT.initHeap(sab, lib);
  return sab;
}

export function open(sab, lib, { fuzz = false, seed = 1 } = {}) {
  const R = RT.attach(sab, { fuzz, seed });
  const FUNS = lib.link(R);
  return { H: R.H, K: FUNS.exports, R };
}

export function int(n) {
  if (!Number.isInteger(n) || n < -MAX || n >= MAX) throw new RangeError(`${n} is outside the 29-bit integers of the encoding`);
  return n * 8;
}
export function toInt(w) {
  if ((w & 7) !== 0) throw new TypeError(`word ${w} is not an int`);
  return w >> 3;
}
export function bool(w) {
  if (w === TRUE) return true;
  if (w === FALSE) return false;
  throw new TypeError(`word ${w} is not a bool`);
}
/** The cell index of a location word, for glue that reads the heap itself. */
export function cell(w) {
  if ((w & 7) !== 1) throw new TypeError(`word ${w} is not a location`);
  return w >> 3;
}
/** `none()` is `undefined`, `some(v)` is v's word. */
export function option(w) { return RT.isInjL(w) ? undefined : RT.payload(w); }
/** A fresh block of n cells, each holding `init` (a word): its location word. */
export function alloc(n, init = 0) { return RT.allocN(int(n), init); }

export const Stuck = RT.Stuck;
export { decode } from './runtime.mjs';
