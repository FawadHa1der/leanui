// Side-by-side: hand-written JS (bench/baselines.mjs) vs translated iris-lean HeapLang (out/*.mjs via rt/run.mjs).
// node bench/side-by-side.mjs [--runs 5] [--reps 2]   -> bench/results.json + bench/results.md
// Each cell: median of RUNS timed runs inside one process; REPS processes, median of their medians.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const argv = process.argv.slice(2);
const opt = (k, d) => { const i = argv.indexOf(k); return i >= 0 ? Number(argv[i + 1]) : d; };
const RUNS = opt('--runs', 5), REPS = opt('--reps', 2);
const LOAD0 = os.loadavg();

function median(xs) { const s = [...xs].sort((a, b) => a - b); return s[s.length >> 1]; }
function js(scenario, variant, T, K) {
  const ms = [], res = [];
  for (let r = 0; r < REPS; r++) {
    const o = JSON.parse(execFileSync('node', [path.join(root, 'bench/baselines.mjs'), scenario, variant, String(T), String(K), '--runs', String(RUNS)], { encoding: 'utf8', timeout: 300000 }));
    ms.push(o.median_ms); res.push(o.result);
  }
  return { ms: median(ms), result: [...new Set(res)].join(' | ') };
}
function tr(prog, pool) { return { prog, ...tr0(prog, pool) }; }
function tr0(prog, pool) {
  const ms = [], res = [];
  let extra = {};
  for (let r = 0; r < REPS; r++) {
    let o;
    try {
      o = JSON.parse(execFileSync('node', [path.join(root, 'rt/run.mjs'), path.join(root, 'out', prog + '.mjs'), '--pool', String(pool), '--runs', String(RUNS), '--json'], { encoding: 'utf8', timeout: 300000 }));
    } catch (e) { o = JSON.parse(e.stdout); }
    ms.push(o.median_ms); res.push(o.trap ? 'TRAP: ' + o.trap.slice(0, 40) : o.result);
    extra = { threads: o.threads_started, max_live: o.max_live, heap_mb: +(o.heap_cells_used * 4 / 1e6).toFixed(1) };
  }
  return { ms: median(ms), result: [...new Set(res)].join(' | '), ...extra };
}

function cbin(kind, prog, pool) {
  const ms = [], res = [];
  for (let r = 0; r < REPS; r++) {
    const [cmd, args] = kind === 'native' ? [path.join(root, 'out/native', prog), [String(pool), String(RUNS)]]
      : ['node', [path.join(root, 'out/wasm', prog + '.js'), String(pool), String(RUNS)]];
    let o;
    try { o = JSON.parse(execFileSync(cmd, args, { encoding: 'utf8', timeout: 300000, stdio: ['ignore', 'pipe', 'pipe'] })); }
    catch (e) { const t = (() => { try { return JSON.parse(String(e.stderr).trim().split('\n').pop()); } catch { return null; } })(); o = { median_ms: null, result: t ? 'TRAP: ' + t.trap.slice(0, 40) : 'ERROR' }; }
    ms.push(o.median_ms); res.push(o.result);
  }
  return { ms: median(ms), result: [...new Set(res)].join(' | ') };
}
const rows = [];
const C_POOL = { pfib_d6: 66, pfib_hint_d6: 66 };
const ONLY = (() => { const i = argv.indexOf('--only'); return i >= 0 ? new RegExp(argv[i + 1]) : null; })();
const OUT = (() => { const i = argv.indexOf('--out'); return i >= 0 ? argv[i + 1] : 'results'; })();
function row(group, label, T, ops, baseF, transF, note = '') {
  if (ONLY && !ONLY.test(`${group} ${label} T=${T}`)) return;
  const base = typeof baseF === 'function' ? baseF() : baseF, trans = typeof transF === 'function' ? transF() : transF;
  if (trans && !argv.includes('--js-only')) {
    trans.prog = trans.r.prog;
    const prog = trans.prog, pool = C_POOL[prog] || Math.max(T, 1);
    trans.native = cbin('native', prog, pool);
    trans.wasm = cbin('wasm', prog, pool);
  }
  rows.push({ group, label, T, ops, base, trans, note });
  const b = base ? `${base.name} ${base.r.ms}ms [${base.r.result}]` : '-';
  const t = trans ? `${trans.name} ${trans.r.ms}ms [${trans.r.result}]` + (trans.native ? ` native ${trans.native.ms}ms wasm ${trans.wasm.ms}ms [${trans.wasm.result}]` : '') : '-';
  console.error(`${group.padEnd(10)} ${label.padEnd(34)} T=${T}  JS: ${b}   HL: ${t}`);
}

const K = 200000;
for (const T of [1, 2, 4]) {
  const ops = T * K;
  row('counter', 'fetch-and-add', T, ops, () => ({ name: 'Atomics.add', r: js('counter', 'faa', T, K) }), () => ({ name: 'faa (wp_faa)', r: tr(`counter_faa_t${T}`, T) }));
  row('counter', 'CAS loop', T, ops, () => ({ name: 'CAS loop', r: js('counter', 'cas', T, K) }), () => ({ name: 'Counter.incr (verified)', r: tr(`counter_cas_t${T}`, T) }));
  row('counter', 'spin lock', T, ops, () => ({ name: 'CAS spinlock, plain ++', r: js('counter', 'spin', T, K) }), () => ({ name: 'SpinLock (verified)', r: tr(`counter_spin_t${T}`, T) }));
  row('counter', 'spin lock, all-SC body', T, ops, () => ({ name: 'CAS spinlock, SC ++', r: js('counter', 'spin-sc', T, K) }), null);
  row('counter', 'ticket lock', T, ops, () => ({ name: 'ticket lock', r: js('counter', 'ticket', T, K) }), () => ({ name: 'TicketLock (verified)', r: tr(`counter_ticket_t${T}`, T) }));
  row('counter', 'futex mutex', T, ops, () => ({ name: 'Drepper mutex, wait/notify', r: js('counter', 'mutex', T, K) }), () => ({ name: 'FutexMutex + hints (hints verified no-op)', r: tr(`counter_futex_t${T}`, T) }));
  row('counter', 'spin lock + hints', T, ops, null, { name: 'SpinLock + hints', r: tr(`counter_spinhint_t${T}`, T) });
  row('counter', 'NO lock (racy)', T, ops, () => ({ name: 'plain I[c]++', r: js('counter', 'racy', T, K) }), () => ({ name: 'c <- !c + 1 (no proof possible)', r: tr(`counter_racy_t${T}`, T) }), 'lost updates expected for T>1');
}
{
  const T = 8, K8 = 50000;
  row('counter', 'spin lock (8 thr / 4 vCPU)', T, T * K8, () => ({ name: 'CAS spinlock, plain ++', r: js('counter', 'spin', T, K8) }), () => ({ name: 'SpinLock (verified)', r: tr('counter_spin_t8', T) }));
  row('counter', 'CAS loop (8 thr / 4 vCPU)', T, T * K8, () => ({ name: 'CAS loop', r: js('counter', 'cas', T, K8) }), () => ({ name: 'Counter.incr (verified)', r: tr('counter_cas_t8', T) }));
  row('counter', 'futex mutex (8 thr / 4 vCPU)', T, T * K8, () => ({ name: 'Drepper mutex', r: js('counter', 'mutex', T, K8) }), () => ({ name: 'FutexMutex + hints', r: tr('counter_futex_t8', T) }));
  row('counter', 'spin + hints (8 thr / 4 vCPU)', T, T * K8, null, { name: 'SpinLock + hints', r: tr('counter_spinhint_t8', T) });
  row('counter', 'ticket lock (8 thr / 4 vCPU)', T, T * 2000, () => ({ name: 'ticket lock', r: js('counter', 'ticket', T, 2000) }), () => ({ name: 'TicketLock (verified)', r: tr('counter_ticket_t8', T) }));
}
row('rwlock', 'readers/writer, 1 write in 10', 4, 400000, () => ({ name: 'RW spinlock', r: js('rw', 'spin', 4, 100000) }), () => ({ name: 'RwSpinLock (verified)', r: tr('rw_t4', 4) }));
row('lockfree', 'Treiber stack push/pop', 4, 80000, () => ({ name: 'Treiber over SAB', r: js('treiber', 'sab', 4, 10000) }), () => ({ name: 'Treiber (iris-audit proof)', r: tr('treiber_t4', 4) }));
row('forkjoin', 'sum 4M, sequential', 1, 4000000, () => ({ name: 'loop', r: js('par', 'seq', 1, 4000000) }), () => ({ name: 'sumSq', r: tr('seq_sum', 1) }));
row('forkjoin', 'sum 4M, two halves', 2, 4000000, () => ({ name: '2 workers', r: js('par', 'two', 2, 4000000) }), () => ({ name: 'Par.par (verified)', r: tr('par_sum', 2) }));
row('forkjoin', 'sum 4M with i*i (overflows 2^28)', 1, 4000000, null, { name: 'sumSqOvf', r: tr('seq_sum_overflow', 1) }, 'HeapLang value is fine; translation traps');
row('forkjoin', 'fib(32) sequential', 1, 1, () => ({ name: 'fib', r: js('fib', 'seq', 1, 32) }), () => ({ name: 'pfib d=0', r: tr('pfib_d0', 1) }));
row('forkjoin', 'fib(32), 4 leaves', 4, 1, () => ({ name: '4 workers', r: js('fib', 'four', 4, 32) }), () => ({ name: 'pfib d=2 (Par)', r: tr('pfib_d2', 4) }));
row('forkjoin', 'fib(32), 64 leaves, spin-join', 4, 1, null, { name: 'pfib d=6 (Par)', r: tr('pfib_d6', 4) });
row('forkjoin', 'fib(32), 64 leaves, hinted join', 4, 1, null, { name: 'pfib d=6 (Par + hints)', r: tr('pfib_hint_d6', 4) });
row('seq', 'quicksort 20k linked list', 1, 20000, () => ({ name: 'same algorithm, JS objects', r: js('qsort', 'list', 1, 20000) }), () => ({ name: 'Quicksort.quicksort (verified)', r: tr('qsort_20k', 1) }));
row('seq', 'quicksort 20k (context)', 1, 20000, () => ({ name: 'Array.prototype.sort', r: js('qsort', 'array', 1, 20000) }), null);
row('threads', '1000 tiny tasks', 4, 1000, () => ({ name: 'postMessage pool', r: js('forks', 'pool', 4, 1000) }), () => ({ name: '1000 x fork', r: tr('fork_many_1000', 4) }));
row('threads', '50 tasks, new Worker each', 50, 50, () => ({ name: 'new Worker per task', r: js('forks', 'fresh', 4, 50) }), null);

const meta = { loadavg_start: LOAD0, loadavg_end: os.loadavg(), date: new Date().toISOString(), node: process.version, cpus: os.cpus().length, cpu: os.cpus()[0].model, runs: RUNS, reps: REPS,
  note: 'CI machine (4 vCPU cloud VM); use ratios, re-measure on the reference Mac' };
fs.writeFileSync(path.join(root, `bench/${OUT}.json`), JSON.stringify({ meta, rows }, null, 1));
const fmt = x => x == null ? '' : String(x);
let md = `| group | scenario | thr | JS hand-written | ms | result | HeapLang program (iris-lean) | HL->JS ms | HL->C native ms | HL->C->wasm ms | result | HL->JS / JS |\n|---|---|---|---|---|---|---|---|---|---|---|---|\n`;
for (const r of rows) {
  const ratio = r.base && r.trans && r.base.r.ms && r.trans.r.ms ? (r.trans.r.ms / r.base.r.ms).toFixed(2) : '';
  const tres = r.trans ? [...new Set([r.trans.r.result, r.trans.native && r.trans.native.result, r.trans.wasm && r.trans.wasm.result].filter(Boolean))].join(' / ') : '';
  md += `| ${r.group} | ${r.label} | ${r.T} | ${r.base ? r.base.name : ''} | ${r.base ? fmt(r.base.r.ms) : ''} | ${r.base ? r.base.r.result : ''} | ${r.trans ? r.trans.name : ''} | ${r.trans ? fmt(r.trans.r.ms) : ''} | ${r.trans && r.trans.native ? fmt(r.trans.native.ms) : ''} | ${r.trans && r.trans.wasm ? fmt(r.trans.wasm.ms) : ''} | ${tres} | ${ratio} |\n`;
}
md += `\n${JSON.stringify(meta)}\n`;
fs.writeFileSync(path.join(root, `bench/${OUT}.md`), md);
console.log(md);
