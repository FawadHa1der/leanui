// How the page shows each scenario (page/iris.mjs runs them): the question in plain words, the run
// sizes a visitor gets, the chart (which lanes, which figure), the live visual, the facts listed
// under the chart, and the verdict, computed from the run. The scenario modules
// (bench/scenarios/) stay the only definition of the lanes; this file says only how to show them.
//
// A view: {
//   ask        the question, one sentence
//   sizes      the run sizes (over the module's `full` sizes); ?quick=1 uses its `quick` sizes
//   rounds     runs of each lane (a scenario whose run is one short job, S5); the chart shows the median
//   about      seconds a run takes at 4 threads, fuzz off (measured on the 4-vCPU CI machine)
//   unit       what the chart's figure counts; `per` the same in a tooltip
//   scale      'log' (a speed: dots) or 'linear' (a count: bars from zero); `max` fixes a linear axis's top (S11: 100%)
//   chart(l)   whether lane l has a chart row; `pairs`: lane X and X-stress share one (S4)
//   value(r, l), text(r, l)   the figure of a row and its label (default: ops/µs)
//   bad(r)     what a broken lane's row shows instead of a speed (default: its violations)
//   threads(T, W, n)  the chart's thread count in words where W is not the thread count: T asked
//              for, W and n = the W and the threads of the first lane
//   live       'counter' (S1) or 'tiles' (S5): see live.mjs; read() for the counter
//   facts      { title, lanes(l), say(r, l) → { st: 'ok' | 'bad' | '', text } }: a list under the chart
//   verdict(get, info)   sentences from the run; get(id) is a lane's row as the chart shows it
// }
import { num, isBroken } from './chart.mjs';

// Int32 cells per cache line, as in bench/kernels.mjs (not imported: it makes a SharedArrayBuffer
// when it loads, and this module also loads on a page that is not cross-origin isolated)
const LINE = 16;

const ran = (r) => r && !r.skipped && !r.error && !r.trap && !r.hung;
const v = (r, k) => r?.violations?.[k] || 0;
const total = (r) => Object.values(r?.violations || {}).reduce((s, n) => s + n, 0);
const times = (a, b) => { const x = a.ops_per_us / b.ops_per_us; return `${x >= 10 ? x.toFixed(0) : x >= 0.95 ? x.toFixed(1) : x.toFixed(2)}×`; };
const fast = (...rs) => rs.every((r) => ran(r) && r.ops_per_us > 0);
const list = (xs) => (xs.length < 2 ? xs.join('') : `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`);
const plural = (n, one, many = `${one}s`) => `${num(n)} ${n === 1 ? one : many}`;
export const violationText = (r) => Object.entries(r.violations || {}).filter(([, n]) => n).map(([k, n]) => `${num(n)} ${k.replace(/_/g, ' ')}`).join(', ');

export const VIEWS = {
  s1: {
    ask: 'When several threads add 1 to the same number at once, which ways of doing it lose updates, and what does a safe increment cost?',
    // 600 ms: the racy lane's 32-bit cell must not lose 2^32 updates (some 3·10^9 a second at 4
    // threads on the CI machine), and the verified counters' 29-bit words must not reach 2^28
    sizes: { ms: 600 }, about: 6,
    unit: 'increments per µs, all threads together', per: 'increments/µs', title: 'What an increment costs',
    chart: (l) => !l.oneW,
    bad: (r) => `${r.extra?.lost_pct ?? 0}% of the updates lost`,
    live: 'counter',
    // The counter as the page can read it while the lane runs: the shared cell (racy, Atomics.add,
    // the CAS loop), the verified counter's heap cell (its word is n·8), or the sum of the shards.
    // Counting locally keeps the count in registers until the end; a whole program's is in its heap.
    read(lane, s, ctx) {
      if (s.heap && s.c != null) { const H = new Int32Array(s.heap), c = s.c >> 3; return () => Atomics.load(H, c) >> 3; }
      if (!s.sab) return null;
      const a = new Int32Array(s.sab);
      if (lane.id === 'shards-js') return () => { let t = 0; for (let i = 0; i < ctx.n; i++) t += Atomics.load(a, LINE * (i + 1)); return t; };
      return () => Atomics.load(a, 0) >>> 0;   // the Int32 cell, read as the count it wraps modulo 2^32
    },
    facts: {
      title: 'Near the top of the integers: two threads each add 4,000 to a counter that is 4,000 short of the limit',
      lanes: (l) => !!l.oneW,
      say: (r, l) => (l.expectTrap ? (r.trap ? { st: 'ok', text: 'stopped with a trap: its integers are 29-bit words that trap where HeapLang\'s unbounded ones would go on' } : { st: 'bad', text: 'did not trap' })
        : v(r, 'wrapped_silently') ? { st: 'bad', text: `wrapped to ${num(r.extra.final)} without an error` } : { st: 'ok', text: `ended at ${num(r.extra?.final)}` }),
    },
    verdict(get) {
      const racy = get('racy-js'), add = get('atomics-add-js'), faa = get('faa-verified'), out = [];
      if (ran(racy)) out.push(v(racy, 'lost_updates') ? `The racy counter lost ${racy.extra.lost_pct}% of its ${num(racy.ops)} updates`
        : `The racy counter lost no updates this run${racy.W < 2 ? ' (one thread has no one to race)' : ' (a race is not guaranteed to show)'}`);
      const safe = this.lanes.filter((l) => !isBroken(l) && !l.oneW).map((l) => get(l.id)).filter(ran);
      const leaky = safe.filter((r) => total(r));
      if (safe.length) out.push(leaky.length ? `✗ ${list(leaky.map((r) => r.lane))} lost updates too` : 'every other lane kept every increment');
      if (fast(faa, add)) out.push(`the verified faaIncr ran at ${times(faa, add)} the speed of Atomics.add`);
      const wj = get('wrap-js'), wv = get('wrap-verified');
      const tail = wj && wv && !wj.error && (wv.trap || !wv.error) ? ` Near the top of the integers, Atomics.add ${v(wj, 'wrapped_silently') ? 'wrapped around without an error' : 'did not wrap'}; the verified counter ${wv.trap ? 'stopped with a trap instead' : 'did not trap'}.` : '';
      return [out.join('; ') + '.' + tail];
    },
  },

  s2: {
    ask: 'Three locks share one safety proof: how fast is each when threads compete for it, and what happens when a thread dies holding it?',
    sizes: { ms: 700 }, about: 11,
    unit: 'critical sections per µs, all threads together', per: 'sections/µs', title: 'How fast each lock lets threads through',
    chart: (l) => l.mode === 'timed',
    facts: {
      title: 'Kill test: a thread takes the lock and is terminated; can another thread take it?',
      lanes: (l) => l.mode === 'kill',
      say: (r) => (r.skipped ? { st: '', text: `skipped: ${r.skipped}` } : r.error ? { st: 'bad', text: `error: ${String(r.error).split('\n')[0]}` }
        : /acquired/.test(r.extra?.after_kill || '') ? { st: 'ok', text: `released: ${r.extra.after_kill}` } : { st: 'bad', text: `stays taken: ${r.extra?.after_kill || 'hung'}` }),
    },
    verdict(get) {
      const none = get('no-lock'), out = [];
      if (ran(none)) out.push(total(none) ? `Without a lock, ${plural(v(none, 'torn_reads'), 'section')} saw the two cells differ and ${plural(v(none, 'lost_updates'), 'update')} were lost`
        : `Without a lock nothing went wrong this run${none.W < 2 ? ' (one thread)' : ' (a race is not guaranteed to show)'}`);
      const pairs = [['futex', 'futex mutex'], ['spin', 'spin lock'], ['ticket', 'ticket lock']].map(([k, name]) => ({ name, mine: get(`${k}-verified`), js: get(`${k}-js`) }));
      const proved = pairs.filter((p) => ran(p.mine));
      if (proved.length) {
        const bad = proved.filter((p) => total(p.mine));
        const rs = pairs.filter((p) => fast(p.mine, p.js));
        const pace = rs.length ? ` and ran at ${list(rs.map((p) => times(p.mine, p.js)))} the speed of the same ${list(rs.map((p) => p.name.split(' ')[0]))} locks by hand` : '';
        out.push(bad.length ? `✗ the verified ${list(bad.map((p) => p.name))} broke the section` : `the ${proved.length === 3 ? 'three ' : ''}verified locks (one theorem, critical_spec) broke no section${pace}`);
      }
      const kills = this.lanes.filter((l) => l.mode === 'kill' && l.id !== 'kill-weblocks').map((l) => get(l.id)).filter((r) => r && !r.skipped && !r.error);
      const web = get('kill-weblocks');
      let tail = '';
      if (kills.length) {
        const stuck = kills.filter((r) => r.hung).length;
        tail = ` When the thread holding the lock was terminated, ${stuck} of ${kills.length} lock words in shared memory stayed taken, verified or not`;
        if (web && /acquired/.test(web.extra?.after_kill || '')) tail += `; Web Locks gave the lock to the next request (${web.extra.after_kill})`;
        tail += '.';
      }
      return [out.join('; ') + '.' + tail];
    },
  },

  s4: {
    ask: 'A producer thread hands audio samples to a consumer that takes a block every 2.67 ms: who glitches, who delivers stale samples, and what does each way cost?',
    sizes: { ms: 700 }, about: 11,
    unit: 'samples per µs with the consumer flat out, all pairs together', per: 'samples/µs', title: 'How fast each ring delivers, consumer flat out',
    chart: (l) => !l.id.endsWith('-stress'), pairs: true,
    bad: (r) => `${plural(v(r, 'stale_or_reordered'), 'stale or reordered delivery', 'stale or reordered deliveries')}`,
    threads: (T, W, n) => `${n} threads (${W} producer–consumer pair${W > 1 ? 's' : ''})`,
    verdict(get) {
      const stale = (id) => v(get(id), 'stale_or_reordered') + v(get(`${id}-stress`), 'stale_or_reordered');
      const has = (id) => ran(get(`${id}-stress`));
      const out = [];
      const bugs = [['ring-early-js', 'by hand'], ['ring-dataplane-early', 'through the verified ring with the same bug in its glue (its proof covers the hand-off, not the bytes)'],
        ['heap-mutant', 'through the HeapLang mutant (which has no proof)']].filter(([id]) => has(id));
      if (bugs.length) out.push(`Publishing a block before writing it delivered stale or reordered data ${list(bugs.map(([id, how]) => `${plural(stale(id), 'time')} ${how}`))}`);
      const good = this.lanes.filter((l) => !isBroken(l) && !l.id.endsWith('-stress'));
      const bad = good.filter((l) => stale(l.id));
      if (good.length) out.push(bad.length ? `✗ ${list(bad.map((l) => l.id))} delivered stale data too` : 'the correct lanes delivered none');
      const ticks = good.map((l) => get(l.id)).filter(ran);
      const u = ticks.reduce((s, r) => s + (r.extra?.underruns || 0), 0), t = ticks.reduce((s, r) => s + (r.extra?.ticks || 0), 0);
      const tail = [];
      if (t) tail.push(`At audio pace the correct lanes missed ${num(u)} of ${num(t)} ticks`);
      const [dp, js, heap] = ['ring-dataplane-stress', 'ring-js-stress', 'ring-heap-stress'].map(get);
      if (fast(dp, js)) tail.push(`flat out, the verified ring carrying block numbers ran at ${times(dp, js)} the speed of the ring by hand${fast(heap, js) ? `, and with every sample in its heap at ${times(heap, js)}` : ''}`);
      return [out.join('; ') + '.', tail.length ? tail.join('; ') + '.' : ''];
    },
  },

  s5: {
    ask: 'Threads draw disjoint parts of one image: does every pixel come out right, and who ends up waiting for whom?',
    sizes: {}, rounds: 24, about: 10,
    unit: 'pixels per µs, all threads together (median of the rounds)', per: 'pixels/µs', title: 'How fast each lane draws the image',
    chart: () => true,
    bad: (r) => `${plural(v(r, 'double_claims'), 'tile')} drawn twice${r.rounds > 1 ? ` in ${r.rounds} rounds` : ''}`,
    live: 'tiles',
    verdict(get, { rounds }) {
      const rows = this.lanes.filter((l) => l.only !== 'node').map((l) => get(l.id)).filter(ran);
      const wrong = rows.filter((r) => v(r, 'wrong_checksum') || v(r, 'wrong_result'));
      const out = [wrong.length ? `✗ ${list(wrong.map((r) => r.lane))} drew a different image` : `Every lane drew the same image (its checksum equals Σ Mandel.g, computed in Lean)`];
      const racy = get('racy-claimer-js'), each = rounds > 1 ? ` in ${rounds} rounds` : '';
      if (ran(racy)) out.push(v(racy, 'double_claims') ? `the racy claimer had ${plural(v(racy, 'double_claims'), 'tile')} drawn twice${each}`
        : `the racy claimer drew no tile twice${each}${racy.W < 2 ? ' (one thread)' : ' (its race is real but rare here)'}`);
      const pm = get('pmapg-verified'), band = get('sab-static-js'), faa = get('faa-claimer-js');
      if (fast(pm, band)) out.push(`the verified pmapG ran at ${times(pm, band)} the speed of the bands by hand (its time also covers setting up and summing the image in its heap)`);
      const tail = ran(band) && ran(faa) && band.W > 1 && band.extra?.imbalance ? ` With equal bands the slowest thread took ${band.extra.imbalance}× the mean time; with tiles claimed by Atomics.add, ${faa.extra.imbalance}×.` : '';
      return [out.join('; ') + '.' + tail];
    },
  },

  s11: {
    ask: 'Sleeping threads wait for a signal: who misses a wakeup, and does any proof notice?',
    sizes: { cycles: 500, ms: 2000 }, about: 10,
    // each lane's own share: the event count's sleepers wait once per cycle each, the futex lanes as often as they must
    unit: 'missed wakeups: % of the waits that only a timeout ended', title: 'Wakeups each way missed', scale: 'linear', max: 100,
    threads: (T, W, n) => `${T} thread${T > 1 ? 's' : ''} (the event count: 1 notifier and ${W} sleeper${W > 1 ? 's' : ''}${n > T ? `, ${n} threads` : ''})`,
    chart: () => true,
    value: (r, l) => 100 * (l.mode === 'fixed' ? r.extra.rescues / Math.max(1, r.extra.cycles * r.W) : r.extra.timeouts / Math.max(1, r.extra.waits)),
    text: (r, l) => (l.mode === 'fixed' ? `${num(r.extra.rescues)} of ${num(r.extra.cycles * r.W)}` : `${num(r.extra.timeouts)} of ${num(r.extra.waits)}`),
    countBroken: true,
    verdict(get) {
      const ok = get('epoch-ok'), out = [];
      const muts = [['notify-before-store', 'notify before the store'], ['wrong-word', 'notify the wrong word'], ['notify-one', 'wake one of several']].map(([id, name]) => ({ name, r: get(id) })).filter((m) => ran(m.r));
      if (ran(ok)) out.push(`The correct event count missed ${plural(ok.extra.rescues, 'wakeup')}`);
      if (muts.length) out.push(`the ${muts.length === 3 ? 'three ' : ''}classic mistakes missed ${list(muts.map((m) => `${num(m.r.extra.rescues)} (${m.name})`))}, and a 5 ms watchdog rescued every sleeper that missed one`);
      const fx = get('futex-verified'), nw = get('nowake-verified'), tail = [];
      if (ran(nw)) tail.push(`FutexNoWake, proved exactly as FutexMutex is, had ${num(nw.extra.timeouts)} of ${num(nw.extra.waits)} futex waits end only by the 20 ms timeout${ran(fx) ? ` (FutexMutex: ${num(fx.extra.timeouts)} of ${num(fx.extra.waits)})` : ''}: the proof does not notice, because it is about safety, not wakeups`);
      return [out.length ? out.join('; ') + '.' : '', tail.length ? tail.join('; ') + '.' : ''];
    },
  },
};

/** The thread count the page asks for, as W for a lane: W itself, or the largest W whose threads fit. */
export function wFor(lane, T) {
  if (!lane.threads) return T;
  let w = 1;
  while (lane.threads(w + 1) <= T) w++;
  return w;
}
