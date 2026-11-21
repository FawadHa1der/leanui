// The dedicated Worker that hosts the module, and (same URL) every pthread Worker of its pool:
// Emscripten starts pthreads from the hosting script (self.location.href) unless
// Module.mainScriptUrlOrBlob is honoured (emsdk 6 drops Module keys missing from
// INCOMING_MODULE_JS_API), so this script doubles as the pthreads' prelude.
const BUILD = new URL(self.location.href).searchParams.get("build");
if (self.name === "em-pthread") {
  importScripts(`../${BUILD}/threadlab.js`);
} else {
onmessage = async (e) => {
  const { build, workers, runs } = e.data;
  const out = [];
  const step = (x) => postMessage({ step: x });
  self.addEventListener("error", (ev) => step("error " + ev.message));
  self.addEventListener("unhandledrejection", (ev) => step("rejection " + ev.reason));
  try {
    importScripts(`../${build}/threadlab.js`);
    step("imported");
    const t0 = performance.now();
    const M = await ThreadLab({ print: (x) => out.push(x), printErr: (x) => { out.push("ERR " + x); step("ERR " + x); }, setStatus: (x) => step("status " + x),
      mainScriptUrlOrBlob: `../${build}/threadlab.js`, locateFile: (f) => `../${build}/${f}` });
    const t1 = performance.now();
    step("module ready");
    if (!M._lab_boot(workers)) throw new Error("boot failed");
    const t2 = performance.now();
    out.push(JSON.stringify({ bench: "boot", build, where: "dedicated worker", crossOriginIsolated: self.crossOriginIsolated,
      loadMs: +(t1 - t0).toFixed(1), leanInitMs: +(t2 - t1).toFixed(1) }));
    for (const [w, a, b, c] of runs) { const s = performance.now(); M._lab_run(w, a, b, c); out.push(JSON.stringify({ bench: "suite-wall", suite: w, ms: +(performance.now() - s).toFixed(1) })); }
  } catch (err) { out.push("FAILED " + build + ": " + err); }
  postMessage(out);
};

}
