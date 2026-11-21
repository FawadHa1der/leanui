// The harness's core, shared by Node (harness.mjs) and the page (page/iris.mjs): runs one lane of
// one scenario at one thread count W, and turns what the workers report into a result row.
//
// A scenario module (scenarios/s*.mjs) exports `id`, `title`, `lanes` and `sizes`. A lane is one of:
//   timed    W workers run `run(ctx)` until the stop flag (throughput, fairness);
//   fixed    W workers each do a fixed amount of work (makespan);
//   program  a whole translated HeapLang program (gen/js, native, wasm), run by the host;
//   kill     one worker takes a lock and is terminated; can another still take it?
// `setup(ctx)` runs on the main thread and returns what the workers share (SharedArrayBuffers and
// numbers); `run(ctx)` runs in each worker; `check(ctx, shared, outs)` counts the violations.
//
// The host provides: `pool` (workers that run bench/worker.mjs), `cpuMs()` (process CPU time, or
// null in a page), `runProgram(name, backend, W)`, `url(path)` for generated modules, and `env`.

export const now = () => performance.timeOrigin + performance.now();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Jain's fairness index over per-worker counts: 1 when equal, 1/n when one did everything. */
export function jain(xs) {
  if (!xs.length) return null;
  const s = xs.reduce((a, b) => a + b, 0), q = xs.reduce((a, b) => a + b * b, 0);
  return q ? +((s * s) / (xs.length * q)).toFixed(3) : null;
}

/** A pool of bench workers, reused across runs; a worker that hangs or is killed is replaced. */
export class Pool {
  constructor(spawn) { this.spawn = spawn; this.idle = []; }
  async take(n) {
    const ws = this.idle.splice(0, n);
    while (ws.length < n) ws.push(await this.spawn());
    return ws;
  }
  give(ws) { this.idle.push(...ws); }
  kill(w) { w.terminate(); }
  close() { for (const w of this.idle) w.terminate(); this.idle = []; }
}

// Control cells shared by the main thread and the workers of one run.
export const CTL_READY = 0, CTL_GO = 1, CTL_STOP = 2, CTL_HELD = 3, CTL_CELLS = 16;

function job(w, msg, transfer = []) {
  return new Promise((resolve) => {
    w.onresult = resolve;
    w.post(msg, transfer);
  });
}

function withTimeout(p, ms) {
  let t;
  return Promise.race([p, new Promise((r) => { t = setTimeout(() => r({ timeout: true }), ms); })])
    .finally(() => clearTimeout(t));
}

/**
 * Runs one lane at W threads. `opts`: { fuzz, sizes, hangMs }. Returns a row:
 * { scenario, lane, W, fuzz, ops, wall_ms, ops_per_us, cpu_ns_per_op, violations, fairness, extra,
 *   hung, trap, error, skipped }.
 */
export async function runLane(host, sc, lane, W, opts) {
  const row = { scenario: sc.id, lane: lane.id, W, fuzz: !!opts.fuzz };
  const sizes = opts.sizes;
  const base = { W, sizes, fuzz: !!opts.fuzz, env: host.env };
  try {
    if (lane.only && lane.only !== host.env) return { ...row, skipped: lane.onlyWhy };
    if (lane.avail && !lane.avail(host)) return { ...row, skipped: lane.availWhy };
    if (lane.mode === 'program') return { ...row, ...(await runProgramLane(host, lane, W, sizes)) };
    if (lane.mode === 'kill') return { ...row, ...(await runKill(host, sc, lane, opts)) };
    const n = lane.threads ? lane.threads(W) : W;
    const ctlSab = new SharedArrayBuffer(4 * CTL_CELLS);
    const ctl = new Int32Array(ctlSab);
    const ctx = { ...base, n, manifest: host.manifest, lib: (name) => import(host.url(`gen/js/${name}.mjs`)) };
    const shared = (await lane.setup?.(ctx)) || {};
    const ws = await host.pool.take(n);
    const extraMsg = lane.perWorker ? lane.perWorker(ctx, shared) : [];
    const outs = ws.map((w, i) => {
      const per = extraMsg[i] || { data: undefined, transfer: [] };
      return job(w, { scenario: host.url(sc.module), lane: lane.id, i, W, n, sizes, fuzz: !!opts.fuzz, seed: 1 + i,
        ctl: ctlSab, shared, data: per.data, genBase: host.url('gen/js/') }, per.transfer)
        // a trap or an error ends the run for every worker (a stuck lock would otherwise hang it)
        .then((g) => { if (g.error) { Atomics.store(ctl, CTL_STOP, 1); Atomics.notify(ctl, CTL_STOP); } return g; });
    });
    // start barrier: every worker has linked its modules and opened its heap
    while (Atomics.load(ctl, CTL_READY) < n) {
      const r = await withTimeout(Promise.race(outs), 50);
      if (!r.timeout) break;                         // a worker finished (with an error) before the barrier
    }
    const cpu0 = host.cpuMs(), t0 = now();
    Atomics.store(ctl, CTL_GO, 1);
    Atomics.notify(ctl, CTL_GO);
    if (lane.mode === 'timed') { await sleep(sizes.ms); Atomics.store(ctl, CTL_STOP, 1); Atomics.notify(ctl, CTL_STOP); }
    const got = await withTimeout(Promise.all(outs), (opts.hangMs ?? 20000));
    const t1 = now(), cpu1 = host.cpuMs();
    if (got.timeout) {
      for (const w of ws) host.pool.kill(w);
      return { ...row, hung: true, error: `no result ${opts.hangMs ?? 20000} ms after the run should have ended` };
    }
    host.pool.give(ws);
    const err = got.find((g) => g.error);
    if (err) return err.trap ? { ...row, trap: err.trap, violations: {} } : { ...row, error: err.error };
    const res = got.map((g) => g.result);
    const ends = res.map((r) => r.t1).filter(Boolean);
    const wall = (ends.length === res.length ? Math.max(...ends) : t1) - t0;
    const chk = (await lane.check?.(ctx, shared, res)) || {};
    const ops = chk.ops ?? res.reduce((s, r) => s + (r.ops || 0), 0);
    const per = res.map((r) => r.ops || 0);
    return {
      ...row, ops, wall_ms: +wall.toFixed(2),
      ops_per_us: lane.noSpeed ? null : +(ops / (wall * 1000)).toFixed(4),
      cpu_ns_per_op: lane.noSpeed || cpu0 == null || !ops ? null : +(((cpu1 - cpu0) * 1e6) / ops).toFixed(1),
      fairness: lane.fairness === false || res.length < 2 ? null : jain(per),
      violations: chk.violations || {}, extra: chk.extra,
    };
  } catch (e) {
    return { ...row, error: String((e && e.stack) || e) };
  }
}

async function runProgramLane(host, lane, W, sizes) {
  const name = lane.program(W);
  const r = await host.runProgram(name, lane.backend, W);
  if (r.skipped) return { skipped: r.skipped };
  const expect = host.manifest.programs.find((p) => p.name === name)?.expect;
  const ops = lane.ops(W, sizes);
  const ok = !r.trap && r.result === expect;
  // a row that trapped or hung has no speed, even if some runs finished before it
  const timed = !r.trap && !r.error;
  return {
    ops, wall_ms: r.wall_ms, ops_per_us: timed && r.wall_ms ? +(ops / (r.wall_ms * 1000)).toFixed(4) : null,
    cpu_ns_per_op: timed && r.cpu_ms != null && r.cpu_ms >= 0 ? +((r.cpu_ms * 1e6) / ops).toFixed(1) : null,
    fairness: null, trap: r.trap || undefined, error: r.error,
    violations: { wrong_result: ok ? 0 : 1 }, extra: { result: r.result, expect, threads: r.threads },
  };
}

// The kill test: a holder takes the lock and signals; the main thread terminates it; a second
// worker then tries to take the lock. Web Locks are released when their context dies; a lock word
// in a SharedArrayBuffer stays taken, verified or not (HeapLang threads never die).
async function runKill(host, sc, lane, opts) {
  const ctlSab = new SharedArrayBuffer(4 * CTL_CELLS), ctl = new Int32Array(ctlSab);
  const ctx = { W: 2, n: 2, sizes: opts.sizes, env: host.env, lib: (name) => import(host.url(`gen/js/${name}.mjs`)) };
  const shared = (await lane.setup?.(ctx)) || {};
  const [holder] = await host.pool.take(1);
  const msg = (role, i) => ({ scenario: host.url(sc.module), lane: lane.id, i, W: 2, n: 2, sizes: opts.sizes,
    fuzz: false, seed: 1 + i, ctl: ctlSab, shared, data: { role }, genBase: host.url('gen/js/') });
  const held = job(holder, msg('holder', 0));
  Atomics.store(ctl, CTL_GO, 1);
  for (let k = 0; k < 400 && Atomics.load(ctl, CTL_HELD) === 0; k++) {
    const r = await withTimeout(held, 5);
    if (!r.timeout) return { error: r.error || 'the holder returned without holding the lock' };
  }
  if (Atomics.load(ctl, CTL_HELD) === 0) { host.pool.kill(holder); return { error: 'the holder never took the lock' }; }
  host.pool.kill(holder);                             // terminated while holding the lock
  await sleep(20);
  const [waiter] = await host.pool.take(1);
  const t0 = now();
  const r = await withTimeout(job(waiter, msg('waiter', 1)), lane.hangMs ?? 1000);
  if (r.timeout) {
    host.pool.kill(waiter);
    return { violations: {}, extra: { after_kill: `hung (no acquire within ${lane.hangMs ?? 1000} ms)` }, hung: true };
  }
  host.pool.give([waiter]);
  if (r.error) return { error: r.error };
  return { violations: {}, extra: { after_kill: `acquired after ${(now() - t0).toFixed(1)} ms` } };
}

/** Runs the lanes of a scenario over the thread counts; `onRow` sees each row as it comes. */
export async function runScenario(host, sc, { Ws = [1, 2, 4, 8], fuzz = [false], quick = false, lanes, onRow } = {}) {
  const sizes = quick ? sc.sizes.quick : sc.sizes.full;
  const rows = [];
  for (const lane of sc.lanes) {
    if (lanes && !lanes.includes(lane.id)) continue;
    // a lane this host cannot run gets one "skipped" row, not one per W
    const away = lane.only && lane.only !== host.env;
    const lws = away ? [Ws[0]] : lane.mode === 'kill' || lane.oneW ? [lane.oneW || 2] : Ws;
    for (const f of away || lane.mode === 'program' || lane.mode === 'kill' ? [false] : fuzz) {
      for (const W of lws) {
        const r = await runLane(host, sc, lane, W, { fuzz: f, sizes, hangMs: lane.hangMs });
        rows.push(r);
        onRow?.(r, lane);
      }
    }
  }
  return rows;
}

/** A row's violations as one string: "0" when clean. */
export function violationText(r) {
  const v = Object.entries(r.violations || {}).filter(([, n]) => n);
  return v.length ? v.map(([k, n]) => `${k} ${n}`).join(', ') : '0';
}

/** A plain-text table of rows, one per (lane, W, fuzz). */
export function table(sc, rows) {
  const lanes = new Map(sc.lanes.map((l) => [l.id, l]));
  const head = ['lane', 'kind', 'W', 'fuzz', 'ops/µs', 'CPU ns/op', 'fair', 'violations', 'note'];
  const body = rows.map((r) => {
    const l = lanes.get(r.lane) || {};
    const note = r.skipped ? `skipped: ${r.skipped}` : r.hung ? (r.extra?.after_kill || 'hung')
      : r.error ? `ERROR ${String(r.error).split('\n')[0].slice(0, 80)}` : r.trap ? `trap: ${r.trap}`
      : l.note ? l.note(r) : r.extra?.after_kill || '';
    return [r.lane, l.kind || '', String(r.W), r.fuzz ? 'on' : '', r.ops_per_us == null ? (l.noSpeed && !r.skipped ? '(hidden)' : '') : String(r.ops_per_us),
      r.cpu_ns_per_op == null ? '' : String(r.cpu_ns_per_op), r.fairness == null ? '' : String(r.fairness),
      r.skipped ? '' : violationText(r), note];
  });
  const wd = head.map((h, i) => Math.max(h.length, ...body.map((b) => b[i].length)));
  const line = (cells) => cells.map((c, i) => c.padEnd(wd[i])).join('  ').trimEnd();
  return [line(head), line(wd.map((n) => '-'.repeat(n))), ...body.map(line)].join('\n');
}
