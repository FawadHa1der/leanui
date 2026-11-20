// One pool thread: links the translated program against the shared heap, then runs forked closures
// until it traps. The same loop in a Node worker (worker.mjs) and a module Web Worker
// (browser/worker.mjs); `post` sends a message to the launcher.
import * as RT from './runtime.mjs';

export async function poolThread(sab, progUrl, post) {
  const prog = await import(progUrl);
  const R = RT.attach(sab), H = R.H;
  while (Atomics.load(H, RT.C_READY) !== 1) Atomics.wait(H, RT.C_READY, 0, 10);   // statics published
  const FUNS = prog.link(R);
  post({ ready: true });
  for (;;) {
    const c = RT.nextTask();
    const live = Atomics.add(H, RT.C_LIVE, 1) + 1;
    let m;
    while (live > (m = Atomics.load(H, RT.C_MAXLIVE)) && Atomics.compareExchange(H, RT.C_MAXLIVE, m, live) !== m);
    let r;
    try {
      r = FUNS[H[c >> 3] >> 3](c, RT.UNIT);
    } catch (e) {
      // the launcher stops every thread: a trap ends the whole run, not just this thread
      Atomics.store(H, RT.C_TRAP, 1);
      post({ trap: String(e && e.message || e), stuck: e instanceof RT.Stuck });
      Atomics.store(H, RT.C_DONE, 1);
      Atomics.notify(H, RT.C_DONE);
      return;
    }
    Atomics.sub(H, RT.C_LIVE, 1);
    if (c === prog.MAIN) {                             // the HeapLang main thread returned
      Atomics.store(H, RT.C_RESULT, r);
      Atomics.store(H, RT.C_DONE, 1);
      Atomics.notify(H, RT.C_DONE);
    }
  }
}
