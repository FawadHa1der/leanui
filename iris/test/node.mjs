// node iris/test/node.mjs [--runs N] [--backends js,native,wasm]
// Run after iris/build.sh. Checks, from dist/iris/gen/manifest.json:
//  1. provenance: every theorem the manifest names is in LeanUIIris/Axioms.lean's guard, and the
//     kernels a program is said to call were found in it (the generator compares terms);
//  2. translator statistics that no result would reveal (a dropped futex hint changes no value);
//  3. the reference interpreter, under every schedule, gives the hand-worked result;
//  4. each translated program, on real threads, gives the result HeapLang's semantics gives, or
//     traps where the encoding must (29-bit ints). Concurrent programs run several times. The
//     racy control's lost updates are recorded, never required: stress results are probabilistic.
// Backends: js always; native and wasm when build.sh built them ("not built" otherwise).
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
const named = new Set([...manifest.kernels.flatMap((k) => k.theorems), ...progs.flatMap((p) => p.theorems)]);
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
  closed_sort_and_check: 'Quicksort',
};
for (const [name, k] of Object.entries(mustCall)) {
  const p = progs.find((q) => q.name === name);
  if (!p || !p.kernels.includes(k)) fail(`provenance: ${name} should call ${k}`);
}
console.log(`provenance: ${named.size} theorems named, all guarded to ${STD.slice(19)}`);

// 2. translator statistics
const stat = (p, k) => (p.stats && p.stats[k]) || 0;
for (const p of progs) {
  if (p.kernels.includes('FutexMutex') || p.kernels.includes('Hints')) {
    if (stat(p, 'futex-wait') < 1 || stat(p, 'futex-wake') < 1) fail(`stats: ${p.name} lost its futex hints`);
  }
}
const loop = progs.find((p) => p.name === 'edge_loop-1e6');
if (stat(loop, 'self-tail-call->loop') < 1) fail('stats: edge_loop-1e6 has no self tail call turned into a loop');
console.log('stats: futex hints present wherever FutexMutex or Hints is called; self tail calls become loops');

// 3. reference interpreter
let interpRuns = 0, outOfFuel = 0;
for (const p of progs) {
  for (const { schedule, result } of p.interp) {
    interpRuns++;
    if (result === 'OUT OF FUEL') { outOfFuel++; continue; }
    if (p.expect === null || p.expect === 'TRAP') continue;
    if (result !== p.expect) fail(`interp: ${p.name} gave ${result} under ${schedule}, expected ${p.expect}`);
  }
}
console.log(`interpreter: ${interpRuns} runs agree with the expected results (${outOfFuel} out of fuel, checked on the backends only)`);
for (const p of progs.filter((p) => p.expect === 'TRAP'))
  console.log(`  ${p.name}: HeapLang gives ${p.interp[0].result}; the translation must trap instead`);
for (const p of progs.filter((p) => p.expect === null && p.interp.length))
  console.log(`  ${p.name} (racy control): ${p.interp.map((i) => `${i.result} [${i.schedule}]`).join(', ')}`);

// 4. backends
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
const built = (backend) => backend === 'js' ||
  progs.every((p) => fs.existsSync(backend === 'native' ? path.join(OUT, 'native', p.name) : path.join(OUT, 'wasm', p.name + '.wasm')));
for (const backend of wanted) {
  if (!built(backend)) { console.log(`\n[${backend}] not built`); continue; }
  console.log(`\n[${backend}]`);
  let pass = 0, failed = 0;
  const t0 = performance.now();
  for (const p of progs) {
    const n = p.kind === 'edge' ? 1 : RUNS;
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
