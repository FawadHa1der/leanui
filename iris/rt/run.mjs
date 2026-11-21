// node iris/rt/run.mjs <program.mjs> [--pool N] [--runs R] [--mb M] [--max-threads T] [--json]
// Runs one translated program on worker_threads and prints its value, or the trap that stopped it.
// Exit status: 0 for a value, 2 for a trap (stuck, integer overflow, out of memory).
import { Worker } from 'node:worker_threads';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { launch } from './launch.mjs';

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? Number(args[i + 1]) : d; };
const progUrl = pathToFileURL(path.resolve(args[0])).href;
const prog = await import(progUrl);
const workerUrl = new URL('./worker.mjs', import.meta.url);
const out = await launch(prog, {
  pool: opt('--pool', 4), runs: opt('--runs', 1), mb: opt('--mb', 256), maxThreads: opt('--max-threads', 512),
  newWorker(sab, onMessage) {
    // HeapLang recursion other than self tail calls stays recursion: give threads deep stacks
    const w = new Worker(workerUrl, { workerData: { sab, progUrl }, resourceLimits: { stackSizeMb: 64 } });
    w.on('message', onMessage);
    w.on('error', (e) => onMessage({ error: e.message }));
    return w;
  },
});
if (args.includes('--json')) console.log(JSON.stringify(out));
else console.log(out);
process.exit(out.trap ? 2 : 0);
