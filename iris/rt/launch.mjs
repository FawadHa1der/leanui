// Runs a translated program: starts a pool of threads over one SharedArrayBuffer, forks the
// HeapLang main thread, and waits for its value without blocking (Atomics.waitAsync), so the same
// code serves Node (run.mjs) and a page's main thread (browser/index.html).
//
// HeapLang has unboundedly many threads: when a fork finds no idle thread, the launcher starts one
// more (up to maxThreads). A thread still starting is only a delay, which adequacy covers.
import * as RT from './runtime.mjs';

// newWorker(sab, onMessage) starts one pool thread running pool.mjs and returns it (it has terminate()).
export async function launch(prog, { newWorker, pool = 4, runs = 1, mb = 256, maxThreads = 512 }) {
  const sab = new SharedArrayBuffer(mb * 1024 * 1024);
  const H = new Int32Array(sab);
  RT.initHeap(sab, prog);
  const workers = [];
  let ready = 0, starting = 0, trap = null;
  const spawn = () => {
    starting++;
    workers.push(newWorker(sab, (m) => {
      if (m.ready) { ready++; starting--; }
      if (m.trap) trap = m.trap;
      if (m.error) { trap = 'worker error: ' + m.error; Atomics.store(H, RT.C_DONE, 1); Atomics.notify(H, RT.C_DONE); }
    }));
  };
  for (let i = 0; i < pool; i++) spawn();
  while (ready < pool && !trap) await new Promise((r) => setTimeout(r, 2));

  let stopped = false;
  (async () => {
    let seen = 0;
    while (!stopped) {
      const w = Atomics.waitAsync(H, RT.C_GROW, seen, 1000);
      if (w.async) await w.value;
      seen = Atomics.load(H, RT.C_GROW);
      // forks still queued with no idle or starting thread
      const pending = Atomics.load(H, RT.C_QTAIL) - Atomics.load(H, RT.C_QHEAD) - starting;
      for (let i = 0; i < pending && workers.length < maxThreads && !stopped; i++) spawn();
    }
  })();

  RT.attach(sab);
  // CPU time of the whole process, every thread (Node only; a page cannot see it)
  const cpu = globalThis.process?.cpuUsage ? () => { const u = process.cpuUsage(); return (u.user + u.system) / 1000; } : null;
  const times = [], cpus = [];
  let result = null;
  for (let run = 0; run < runs && !trap; run++) {
    Atomics.store(H, RT.C_DONE, 0);
    const t0 = performance.now(), c0 = cpu && cpu();
    RT.fork(prog.MAIN);
    const w = Atomics.waitAsync(H, RT.C_DONE, 0);
    if (w.async) await w.value;
    const t1 = performance.now();
    if (cpu) cpus.push(cpu() - c0);
    if (Atomics.load(H, RT.C_TRAP)) {
      for (let i = 0; i < 100 && !trap; i++) await new Promise((r) => setTimeout(r, 5));
      trap = trap || 'trap';
      break;
    }
    times.push(t1 - t0);
    result = RT.decode(H, Atomics.load(H, RT.C_RESULT));
  }
  stopped = true;
  for (const w of workers) w.terminate();               // other threads may still spin after a trap
  const sorted = [...times].sort((a, b) => a - b);
  return {
    program: prog.NAME, result, trap,
    times_ms: times.map((t) => +t.toFixed(3)),
    median_ms: sorted.length ? +sorted[sorted.length >> 1].toFixed(3) : null,
    cpu_ms: cpus.length ? cpus.map((c) => +c.toFixed(3)) : null,
    threads: workers.length, forks: Atomics.load(H, RT.C_FORKS), max_live: Atomics.load(H, RT.C_MAXLIVE),
    heap_cells_used: Atomics.load(H, RT.C_BRK), heap_cells: H.length,
  };
}
