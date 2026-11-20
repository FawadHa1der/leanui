// The harness's host under Node: bench workers on worker_threads, process CPU time, and the
// whole-program lanes (gen/js on rt/launch.mjs, native and wasm as child processes).
import { Worker } from 'node:worker_threads';
import { execFile } from 'node:child_process';
import { pathToFileURL, fileURLToPath } from 'node:url';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Pool } from './core.mjs';
import { launch } from '../rt/launch.mjs';

const IRIS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// Whole programs run 3 times in one process and report the median: the first run also pays for
// threads that are still starting (Emscripten's pthreads load the module asynchronously).
const RUNS = 3;
const median = (xs) => (xs && xs.length ? [...xs].sort((a, b) => a - b)[xs.length >> 1] : null);

export function nodeHost(out = path.resolve(IRIS, '../dist/iris')) {
  const mfile = path.join(out, 'gen/manifest.json');
  if (!fs.existsSync(mfile)) throw new Error(`${mfile} is missing: run iris/build.sh first`);
  const manifest = JSON.parse(fs.readFileSync(mfile, 'utf8'));
  const url = (p) => pathToFileURL(p.startsWith('gen/') ? path.join(out, p) : path.join(IRIS, p)).href + (p.endsWith('/') ? '/' : '');
  const spawn = () => new Promise((resolve, reject) => {
    const w = new Worker(new URL('./worker.mjs', import.meta.url), { resourceLimits: { stackSizeMb: 64 } });
    const h = { post: (m, t) => w.postMessage(m, t), terminate: () => w.terminate(), onresult: null };
    w.on('message', (m) => { if (m.ready) resolve(h); else h.onresult?.(m); });
    w.on('error', (e) => { if (h.onresult) h.onresult({ error: String(e && e.stack || e) }); else reject(e); });
  });
  const poolWorker = new URL('../rt/worker.mjs', import.meta.url);
  const run = (cmd, argv) => new Promise((resolve) => {
    execFile(cmd, argv, { encoding: 'utf8', timeout: 120000 }, (err, stdout, stderr) => {
      const last = (s) => { try { return JSON.parse(String(s).trim().split('\n').pop()); } catch { return null; } };
      const j = last(stdout) || last(stderr);
      if (j) resolve(j); else resolve({ error: String((err && err.message) || stderr).slice(0, 300) });
    });
  });
  return {
    env: 'node', cores: os.availableParallelism?.() || os.cpus().length, manifest, url, out,
    pool: new Pool(spawn),
    cpuMs: () => { const u = process.cpuUsage(); return (u.user + u.system) / 1000; },
    async runProgram(name, backend, W) {
      if (backend === 'js') {
        const prog = await import(url(`gen/js/${name}.mjs`));
        const progUrl = url(`gen/js/${name}.mjs`);
        const r = await launch(prog, {
          pool: W, runs: RUNS, mb: 64, maxThreads: 64,
          newWorker(sab, onMessage) {
            const w = new Worker(poolWorker, { workerData: { sab, progUrl }, resourceLimits: { stackSizeMb: 64 } });
            w.on('message', onMessage);
            w.on('error', (e) => onMessage({ error: e.message }));
            return w;
          },
        });
        return { result: r.result, trap: r.trap, wall_ms: r.median_ms, cpu_ms: median(r.cpu_ms), threads: r.threads };
      }
      const file = backend === 'native' ? path.join(out, 'native', name) : path.join(out, 'wasm', name + '.js');
      if (!fs.existsSync(file)) return { skipped: `${backend} not built` };
      const argv = [String(W + 2), String(RUNS), '64'];
      const r = backend === 'native' ? await run(file, argv) : await run(process.execPath, [file, ...argv]);
      return { result: r.result, trap: r.trap, error: r.error, wall_ms: r.median_ms, cpu_ms: r.cpu_ms, threads: r.pool };
    },
  };
}
