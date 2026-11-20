// The harness's host in a page (page/iris.mjs): bench workers are module Web Workers, the
// whole-program lanes run on rt/launch.mjs with the browser pool threads. A page cannot see CPU
// time, and the native and wasm lanes are Node's.
import { Pool } from './core.mjs';
import { launch } from '../rt/launch.mjs';

export async function webHost(base) {
  const url = (p) => new URL(p, base).href;
  const manifest = await (await fetch(url('gen/manifest.json'))).json();
  const spawn = () => new Promise((resolve, reject) => {
    const w = new Worker(new URL('./worker.mjs', import.meta.url), { type: 'module' });
    const h = { post: (m, t) => w.postMessage(m, t), terminate: () => w.terminate(), onresult: null };
    w.onmessage = (e) => { if (e.data && e.data.ready) resolve(h); else h.onresult?.(e.data); };
    w.onerror = (e) => {
      const m = { error: e.message || 'worker error' };
      if (h.onresult) h.onresult(m); else reject(new Error(m.error));
    };
  });
  return {
    env: 'browser', cores: navigator.hardwareConcurrency || 4, manifest, url, pool: new Pool(spawn),
    cpuMs: () => null,
    async runProgram(name, backend, W) {
      if (backend !== 'js') return { skipped: `${backend}: Node only` };
      const progUrl = url(`gen/js/${name}.mjs`);
      const prog = await import(progUrl);
      const r = await launch(prog, {
        pool: W, runs: 3, mb: 64, maxThreads: 64, timeoutMs: 120000,
        newWorker(sab, onMessage) {
          const w = new Worker(url('rt/browser/worker.mjs'), { type: 'module' });
          w.onmessage = (e) => onMessage(e.data);
          w.onerror = (e) => onMessage({ error: e.message });
          w.postMessage({ sab, progUrl });
          return w;
        },
      });
      return { result: r.result, trap: r.trap, wall_ms: r.median_ms, cpu_ms: null, threads: r.threads };
    },
  };
}
