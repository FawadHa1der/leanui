// node iris/test/node.mjs [--runs N] [--backends js,native,wasm]
// Run after iris/build.sh. Checks, from dist/iris/gen/manifest.json:
//  1. provenance: every theorem the manifest names is in LeanUIIris/Axioms.lean's guard, and the
//     kernels a program is said to call were found in it (the generator compares terms);
//  2. translator statistics that no result would reveal (a dropped futex hint changes no value);
//  3. the reference interpreter, under every schedule, gives the hand-worked result, and its racy
//     controls show interleavings (a lost update, the ring mutant's stale reads);
//  4. the library modules' kernels, called from JavaScript through rt/embed.mjs, give their results;
//  5. each translated program, on real threads, gives the result HeapLang's semantics gives, or
//     traps where the encoding must (29-bit ints). Concurrent programs run several times. The
//     racy controls are recorded, never required: stress results are probabilistic.
// Backends: js always; native and wasm when build.sh built them ("not built" otherwise; a backend
// built only in part fails).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const IRIS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.resolve(IRIS, '../dist/iris');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const RUNS = Number(opt('--runs', 3));
const wanted = opt('--backends', 'js,native,wasm').split(',');

const mfile = path.join(OUT, 'gen/manifest.json');
if (!fs.existsSync(mfile)) { console.error(`${mfile} is missing: run iris/build.sh first`); process.exit(1); }
const manifest = JSON.parse(fs.readFileSync(mfile, 'utf8'));
const progs = manifest.programs;
let failures = 0;
const fail = (msg) => { failures++; console.log('FAIL  ' + msg); };

// 1. provenance
const axioms = fs.readFileSync(path.join(IRIS, 'LeanUIIris/Axioms.lean'), 'utf8');
const STD = 'depends on axioms: [propext, Classical.choice, Quot.sound]';
const guarded = (t) => axioms.includes(`/-- info: '${t}' ${STD} -/\n#guard_msgs in #print axioms ${t}\n`);
const libs = manifest.libs;
const named = new Set([...manifest.kernels.flatMap((k) => k.theorems), ...progs.flatMap((p) => p.theorems),
  ...libs.flatMap((l) => l.exports.flatMap((e) => [...e.theorems, ...e.calls_theorems]))]);
for (const t of named) if (!guarded(t)) fail(`provenance: ${t} is not in Axioms.lean's guard`);
const kernelNames = new Set(manifest.kernels.map((k) => k.name));
for (const p of progs) {
  for (const k of p.kernels) if (!kernelNames.has(k)) fail(`provenance: ${p.name} names unknown kernel ${k}`);
}
// the generator finds kernels by comparing terms; these must be found
const mustCall = {
  small_counter_faa: 'AtomicCounter', small_counter_casincr: 'AtomicCounter', small_counter_cas: 'Counter',
  small_counter_spin: 'SpinLock', small_counter_ticket: 'TicketLock', small_counter_futex: 'FutexMutex',
  small_rw: 'RwSpinLock', small_treiber: 'Treiber', small_spsc_stream: 'SpscRing', small_pmap: 'ParMap',
  small_pfib: 'Par', closed_two_incr: 'AtomicCounter', closed_spsc_client: 'SpscRing',
  closed_sort_and_check: 'Quicksort', small_spsc_early: 'SpscRing', bench_s1_shards_w2: 'Shards',
  bench_s2_futex_w2: 'Critical', bench_s2_spin_w2: 'SpinLock', bench_s5_mandel_w2: 'Mandel',
  bench_s5_mandel_w4: 'ParMapG',
};
for (const [name, k] of Object.entries(mustCall)) {
  const p = progs.find((q) => q.name === name);
  if (!p || !p.kernels.includes(k)) fail(`provenance: ${name} should call ${k}`);
}
// every library export is a proved kernel constant, except the negative controls
const unproved = new Set(['Critical.racy', 'Programs.tryPushEarly']);
for (const l of libs) {
  for (const e of l.exports) {
    if (!e.kernel && !unproved.has(e.name)) fail(`provenance: ${l.name} exports ${e.name}, which is no kernel's constant`);
    if (e.kernel && !e.theorems.length) fail(`provenance: ${l.name}'s ${e.name} has no theorem`);
  }
}
const exp = (lib, name) => libs.find((l) => l.name === lib).exports.find((e) => e.name === name);
if (!exp('lib_locks', 'Critical.criticalSpin').calls.includes('SpinLock')) fail('provenance: criticalSpin should call SpinLock');
if (!exp('lib_locks', 'FutexNoWake.criticalNoWake').calls.includes('FutexMutex')) fail('provenance: criticalNoWake should call FutexMutex');
console.log(`provenance: ${named.size} theorems named, all guarded to ${STD.slice(19)}; ${libs.length} libraries`);

// 2. translator statistics
const stat = (p, k) => (p.stats && p.stats[k]) || 0;
for (const p of progs) {
  if (p.kernels.includes('FutexMutex') || p.kernels.includes('Hints')) {
    if (stat(p, 'futex-wait') < 1 || stat(p, 'futex-wake') < 1) fail(`stats: ${p.name} lost its futex hints`);
  }
}
for (const l of libs) {
  const futex = l.exports.some((e) => e.kernel === 'FutexMutex' || e.calls.includes('FutexMutex'));
  if (futex && (stat(l, 'futex-wait') < 1 || stat(l, 'futex-wake') < 1)) fail(`stats: ${l.name} lost its futex hints`);
}
const loop = progs.find((p) => p.name === 'edge_loop-1e6');
if (stat(loop, 'self-tail-call->loop') < 1) fail('stats: edge_loop-1e6 has no self tail call turned into a loop');
console.log('stats: futex hints present wherever FutexMutex or Hints is called; self tail calls become loops');

// 3. reference interpreter
let interpRuns = 0, outOfFuel = 0;
for (const p of progs) {
  for (const { schedule, result } of p.interp) {
    interpRuns++;
    if (result === 'OUT OF FUEL') {
      outOfFuel++;
      if (p.name !== 'edge_loop-1e6') fail(`interp: ${p.name} ran out of fuel under ${schedule}`);
      continue;
    }
    if (p.expect === null || p.expect === 'TRAP') continue;
    if (result !== p.expect) fail(`interp: ${p.name} gave ${result} under ${schedule}, expected ${p.expect}`);
  }
}
console.log(`interpreter: ${interpRuns} runs agree with the expected results (${outOfFuel} out of fuel, checked on the backends only)`);
for (const p of progs.filter((p) => p.expect === 'TRAP'))
  console.log(`  ${p.name}: HeapLang gives ${p.interp[0].result}; the translation must trap instead`);
for (const p of progs.filter((p) => p.expect === null && p.interp.length))
  console.log(`  ${p.name} (racy control): ${p.interp.map((i) => `${i.result} [${i.schedule}]`).join(', ')}`);
// The schedules are seeded, so the racy controls give the same values every time: some schedule
// must lose an update and some must read the ring mutant's stale slots, or the interpreter has
// stopped interleaving.
const someInterp = (name, ok) => progs.find((p) => p.name === name)?.interp.some((i) => /^-?\d+$/.test(i.result) && ok(Number(i.result)));
if (!someInterp('small_counter_racy', (n) => n < 45)) fail('interp: no schedule of small_counter_racy loses an update');
if (!someInterp('small_spsc_early', (n) => n > 0)) fail('interp: no schedule of small_spsc_early reads a stale slot');

// 4. the embedding ABI (rt/embed.mjs): library kernels called from JavaScript, one thread
{
  const E = await import(path.join(IRIS, 'rt/embed.mjs'));
  const lib = async (n) => import(path.join(OUT, 'gen/js', n + '.mjs'));
  const counters = await lib('lib_counters');
  let K = E.open(E.newHeap(counters, 8), counters).K;
  const c = K['Counter.newcounter'](E.UNIT);
  for (let i = 0; i < 100; i++) { K['Counter.incr'](c); K['AtomicCounter.faaIncr'](c); K['AtomicCounter.casIncr'](c); }
  if (E.toInt(K['Counter.read'](c)) !== 300) fail('embed: counters');
  const locks = await lib('lib_locks');
  K = E.open(E.newHeap(locks, 8), locks).K;
  for (const [nl, crit] of [['SpinLock.newlock', 'Critical.criticalSpin'], ['TicketLock.newlock', 'Critical.criticalTicket'],
    ['FutexMutex.newlock', 'Critical.criticalFutex'], ['FutexMutex.newlock', 'FutexNoWake.criticalNoWake']]) {
    const lk = K[nl](E.UNIT), a = E.alloc(1, E.int(0)), b = E.alloc(1, E.int(0));
    for (let i = 0; i < 50; i++) if (K[crit](lk, a, b) !== E.TRUE) fail(`embed: ${crit} returned false`);
  }
  const ring = await lib('lib_ring');
  K = E.open(E.newHeap(ring, 8), ring).K;
  const buf = E.alloc(4, E.int(0)), hd = E.alloc(1, E.int(0)), tl = E.alloc(1, E.int(0)), n = E.int(4);
  const got = [];
  for (let i = 0; i < 6; i++) if (K['SpscRing.tryPush'](buf, hd, tl, n, E.int(i)) !== E.TRUE) got.push('full');
  for (let i = 0; i < 6; i++) { const v = E.option(K['SpscRing.tryPop'](buf, hd, tl, n)); got.push(v === undefined ? 'empty' : E.toInt(v)); }
  if (got.join() !== 'full,full,0,1,2,3,empty,empty') fail(`embed: ring gave ${got.join()}`);
  let trapped = false;
  try { E.int(2 ** 28); } catch { trapped = true; }
  if (!trapped) fail('embed: 2^28 should not encode');
  // m >>> n is m <<< (-n): a shift by -2^28, the one amount whose negation wraps, is 0 for 0 and
  // overflows otherwise (no edge program can test it: the interpreter would build 1 <<< 2^28)
  const RT = await import(path.join(IRIS, 'rt/runtime.mjs'));
  trapped = false;
  try { RT.shr(E.int(1), E.int(-(2 ** 28))); } catch { trapped = true; }
  if (!trapped || RT.shr(E.int(0), E.int(-(2 ** 28))) !== 0) fail('runtime: 1 >>> -2^28 should trap, 0 >>> -2^28 give 0');
  console.log('embed: counters, the four critical sections and the ring, called from JavaScript');
}

// 5. backends
function command(backend, name) {
  if (backend === 'native') return [path.join(OUT, 'native', name), ['64', '1', '64']];
  if (backend === 'wasm') return [process.execPath, [path.join(OUT, 'wasm', name + '.js'), '64', '1', '64']];
  return [process.execPath, [path.join(IRIS, 'rt/run.mjs'), path.join(OUT, 'gen/js', name + '.mjs'), '--json', '--mb', '64']];
}
function runOnce(backend, name) {
  const [cmd, argv] = command(backend, name);
  try {
    const out = execFileSync(cmd, argv, { encoding: 'utf8', timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
    return String(JSON.parse(out.trim().split('\n').pop()).result);
  } catch (e) {
    const last = (s) => { try { return JSON.parse(String(s).trim().split('\n').pop()); } catch { return null; } };
    const j = last(e.stdout) || last(e.stderr);
    if (j && j.trap) return 'TRAP';
    return 'ERROR ' + String(e.stderr || e.message).trim().split('\n').slice(-3).join(' | ').slice(0, 300);
  }
}
// A backend is "not built" when build.sh made no directory for it; a directory that lacks some
// programs is a failed build.
const binary = (backend, name) => backend === 'native' ? path.join(OUT, 'native', name) : path.join(OUT, 'wasm', name + '.wasm');
for (const backend of wanted) {
  if (backend !== 'js') {
    if (!fs.existsSync(path.join(OUT, backend))) { console.log(`\n[${backend}] not built`); continue; }
    const missing = progs.filter((p) => !fs.existsSync(binary(backend, p.name))).map((p) => p.name);
    if (missing.length) { fail(`[${backend}] ${missing.length} of ${progs.length} programs not built: ${missing.join(', ')}`); continue; }
  }
  console.log(`\n[${backend}]`);
  let pass = 0, failed = 0;
  const t0 = performance.now();
  for (const p of progs) {
    const n = p.kind === 'edge' || p.kind === 'bench' ? 1 : RUNS;
    const got = Array.from({ length: n }, () => runOnce(backend, p.name));
    if (p.expect === null) {
      console.log(`NOTE  ${p.name.padEnd(30)} racy control: ${got.join(', ')}`);
      continue;
    }
    if (got.every((g) => g === p.expect)) { pass++; console.log(`PASS  ${p.name.padEnd(30)} ${p.expect}${p.closed ? `   (${p.closed.split('.').pop()})` : ''}`); }
    else { failed++; fail(`${p.name.padEnd(30)} expected ${p.expect}, got ${got.join(', ')}`); }
  }
  console.log(`[${backend}] ${pass} passed, ${failed} failed (${((performance.now() - t0) / 1000).toFixed(1)} s)`);
}

console.log(failures ? `\n${failures} failures` : '\nall checks passed');
process.exit(failures ? 1 : 0);
