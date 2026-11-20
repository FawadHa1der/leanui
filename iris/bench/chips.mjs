// What a lane may claim, and the rule the harness and the tests use to judge a run. A chip's
// kernels and theorems come from the generator's manifest; its scope and its trusted and
// not-proved lines are written per lane in scenarios/.
//
// Lane kinds:
//   L0   deliberately broken JavaScript (or broken glue around a verified kernel): its
//        violations are recorded, never required, and its speed is not shown
//   L1   idiomatic JavaScript;  L2  the same algorithm as the verified kernel, by hand
//   L3   verified, everything the kernel touches in the HeapLang heap (fully covered)
//   L3p  verified protocol, trusted data plane: the payload is in ordinary typed arrays, and the
//        JavaScript that touches it is outside the proof
//   L4n, L4w  the same HeapLang through C11 to native code or to wasm32 (Emscripten pthreads)
//   M    a HeapLang mutant with no proof: what the proof would have rejected

export const KINDS = {
  L0: 'broken (correctness counts only)',
  L1: 'idiomatic JavaScript',
  L2: 'same algorithm, by hand in JavaScript',
  L3: 'verified, payload in the heap',
  L3p: 'verified protocol, trusted data plane',
  L4n: 'verified, C11 → native',
  L4w: 'verified, C11 → wasm32',
  M: 'HeapLang mutant, no proof',
};
const VERIFIED = new Set(['L3', 'L3p', 'L4n', 'L4w']);
export const isVerified = (lane) => VERIFIED.has(lane.kind);

const notProved = (kind) => ['liveness: progress, fairness, deadlock, lost wakeups', 'performance',
  kind === 'L3p' ? "weak memory: the translated kernel's accesses are SeqCst atomics; the data plane's plain accesses are trusted"
    : 'weak memory: every shared access is emitted as a SeqCst atomic instead', 'a thread that dies (HeapLang threads never do)'];
const TRUSTED = {
  L3: ['the translator (Translate.lean), tested against the reference interpreter', 'the runtime (rt/runtime.mjs, rt/embed.mjs)',
    'integers: 29-bit words that trap where HeapLang has unbounded ints', 'the JS glue that calls the kernel', 'V8'],
  L3p: ['the translator and the runtime, as for L3', 'the data plane: the JS that reads and writes the payload, and that it touches only what the protocol handed it',
    'integers: 29-bit words that trap', 'V8'],
  L4n: ['the translator (C target)', 'the C runtime (rt/hl_rt.h, rt/hl_main.h)', 'integers: 29-bit words that trap', 'the C compiler'],
  L4w: ['the translator (C target)', 'the C runtime', 'integers: 29-bit words that trap', 'Emscripten and the wasm engine'],
};

function kernelInfo(manifest, names) {
  const ks = manifest.kernels.filter((k) => names.includes(k.name));
  return { theorems: [...new Set(ks.flatMap((k) => k.theorems))], says: ks.map((k) => `${k.name}: ${k.says}`) };
}

/** The proof chip of a lane: what is proved, what is trusted, what is not proved. Its theorems are
 * those of every kernel the lane calls, not only those about the constants it runs. */
export function chip(manifest, lane, W = 1) {
  if (!isVerified(lane)) {
    const text = lane.kind === 'M' ? 'No proof: the invariant cannot be re-established; the reference interpreter finds the bug.'
      : lane.uses ? `Broken on purpose in the glue: ${lane.uses.join(', ')} are the proved kernels, with the same theorems as the ` +
        'correct lane; the bug is in the JavaScript around them, which no proof covers.'
      : 'Not verified.';
    return { verified: false, kind: lane.kind, kindText: KINDS[lane.kind], text };
  }
  let kernels = [], theorems = [], scope = lane.scope;
  if (lane.mode === 'program') {
    const p = manifest.programs.find((q) => q.name === lane.program(W));
    if (!p) return { verified: false, kind: lane.kind, text: `program ${lane.program(W)} is missing from the manifest` };
    kernels = p.kernels; theorems = p.theorems; scope = scope || p.scope;
  } else {
    const lib = manifest.libs.find((l) => l.name === lane.lib);
    for (const u of lane.uses || []) {
      const e = lib?.exports.find((x) => x.name === u);
      if (!e) return { verified: false, kind: lane.kind, text: `${u} is missing from ${lane.lib}` };
      kernels.push(...(e.kernel ? [e.kernel] : []), ...e.calls);
      theorems.push(...e.theorems, ...e.calls_theorems);
    }
  }
  kernels = [...new Set(kernels)];
  const info = kernelInfo(manifest, kernels);
  return {
    verified: true, kind: lane.kind, kindText: KINDS[lane.kind], scope,
    kernels, theorems: [...new Set(theorems)], says: info.says,
    axioms: ['propext', 'Classical.choice', 'Quot.sound'],
    trusted: [...TRUSTED[lane.kind], ...(lane.trusted || [])],
    notProved: [...notProved(lane.kind), ...(lane.notProved || [])],
  };
}

/** A failure message when a run breaks what its lane promises; null otherwise. */
export function verdict(sc, row) {
  const lane = sc.lanes.find((l) => l.id === row.lane);
  if (!lane || row.skipped) return null;
  if (row.error) return `error: ${String(row.error).split('\n')[0]}`;
  if (lane.expectTrap) return row.trap ? null : 'expected a trap (the 29-bit encoding), got none';
  if (row.trap) return `trap: ${row.trap}`;
  if (row.hung && lane.mode !== 'kill') return 'hung';
  if (isVerified(lane)) {
    const v = Object.entries(row.violations || {}).filter(([, n]) => n);
    if (v.length) return `violations ${v.map(([k, n]) => `${k} ${n}`).join(', ')}`;
  }
  return null;
}
