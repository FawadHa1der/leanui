// One bench worker, under Node's worker_threads or as a module Web Worker: runs jobs (one lane's
// share of one run) until it is terminated. core.mjs sends the jobs.
import { makeFuzz } from './kernels.mjs';
import { CTL_READY, CTL_GO, CTL_STOP, now } from './core.mjs';

let post, listen;
if (typeof process !== 'undefined' && process.versions?.node && !globalThis.WorkerGlobalScope) {
  const { parentPort } = await import('node:worker_threads');
  post = (m, t) => parentPort.postMessage(m, t);
  listen = (f) => parentPort.on('message', f);
} else {
  post = (m, t) => self.postMessage(m, t);
  listen = (f) => { self.onmessage = (e) => f(e.data); };
}

listen(async (msg) => {
  try {
    const sc = await import(msg.scenario);
    const lane = sc.lanes.find((l) => l.id === msg.lane);
    const ctl = new Int32Array(msg.ctl);
    const ctx = {
      ...msg, ctl, now, F: makeFuzz(msg.fuzz, msg.seed * 7919),
      lib: (name) => import(msg.genBase + name + '.mjs'),
      /** Waits at the start barrier; returns the start time. */
      ready() {
        Atomics.add(ctl, CTL_READY, 1);
        Atomics.notify(ctl, CTL_READY);
        while (Atomics.load(ctl, CTL_GO) === 0) Atomics.wait(ctl, CTL_GO, 0, 100);
        return now();
      },
      stopped: () => Atomics.load(ctl, CTL_STOP) !== 0,
    };
    const out = await lane.run(ctx);
    const transfer = out.__transfer || [];
    delete out.__transfer;
    post({ result: out }, transfer);
  } catch (e) {
    post({ error: String((e && e.stack) || e), trap: e && e.constructor && e.constructor.name === 'Stuck' ? e.message : undefined });
  }
});
post({ ready: true });
