// The runtime's fast paths against a literal reading of docs/PROTOCOL.md section 3.
//
// runtime/leanui.js does not apply every command with the DOM call the protocol table names:
// SET_ATTR "class" on an HTML element writes `className`, and a run of REMOVEs that empties a
// parent is one `replaceChildren()`. Here hand-built buffers go through the runtime and through a
// reference applier written in this file (one DOM call per command, exactly as the table reads),
// in Chromium and Firefox, and for every scenario we compare:
//   * the container's final DOM and whether the buffer threw (the error's class, not its text);
//   * what page code can observe while the buffer is applied: MutationObserver records (removed
//     nodes per record) and custom elements' disconnectedCallbacks (each logs how many children
//     its old parent still has).
// Every scenario must give the same observations, except where the runtime batches a list's
// removals. There they must differ exactly as docs/DESIGN.md and the REMOVE case say, and in
// nothing else: one record for the batched run instead of one per child, and the run's
// disconnectedCallbacks after its last removal (the old parent already empty) instead of after
// each one. Final DOMs against the Lean DOM model are fuzz.mjs's job; this file pins what the
// fuzzer cannot see.
//
//   node tests/browser/apply-semantics.mjs [chromium,firefox] [--runtime runtime/leanui.js]
//   (run under the host browser lock)
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire("/Users/fawadhaider/code/wasm64-lean-fable/qed64/package.json");
const pw = require("playwright");

const root = new URL("../..", import.meta.url).pathname;
const argv = process.argv.slice(2);
const ri = argv.indexOf("--runtime");
const runtimePath = ri >= 0 ? argv[ri + 1] : root + "runtime/leanui.js";
const engines = (argv.find((a, i) => !a.startsWith("--") && argv[i - 1] !== "--runtime") || "chromium,firefox").split(",");
const runtime = readFileSync(runtimePath, "utf8");

function check() {
  // ---- buffers: words and a string table, as Lean's Buf writes them ----
  const B = () => {
    const w = []; let text = "";
    const s = (str) => { const off = text.length; text += str; return [off, str.length]; };
    const b = {
      w, get text() { return text; },
      intern(id, str) { w.push(17, id, ...s(str)); return b; },
      el(h, ns, nm) { w.push(1, h, ns, nm); return b; },
      txt(h, str) { w.push(2, h, ...s(str)); return b; },
      attr(h, nm, str) { w.push(3, h, nm, ...s(str)); return b; },
      app(p, c) { w.push(10, p, c); return b; },
      ins(p, c, r) { w.push(11, p, c, r); return b; },
      rm(h) { w.push(12, h); return b; },
      free(h) { w.push(14, h); return b; },
      mount(h) { w.push(18, ...s("#app"), h); return b; },
      hydrate(first, count) { w.push(19, ...s("#app"), first, count); return b; },
    };
    return b;
  };
  const NS = [null, "http://www.w3.org/2000/svg", "http://www.w3.org/1998/Math/MathML"];
  // ---- the reference: one DOM call per command, as the protocol table reads ----
  class Ref {
    constructor() { this.nodes = [null]; this.names = [null]; }
    apply(b) {
      const w = b.w, text = b.text, N = this.nodes, names = this.names, S = (i) => text.substr(w[i], w[i + 1]);
      for (let i = 0; i < w.length; ) {
        switch (w[i]) {
          case 1: N[w[i + 1]] = w[i + 2] ? document.createElementNS(NS[w[i + 2]], names[w[i + 3]]) : document.createElement(names[w[i + 3]]); i += 4; break;
          case 2: N[w[i + 1]] = document.createTextNode(S(i + 2)); i += 4; break;
          case 3: N[w[i + 1]].setAttribute(names[w[i + 2]], S(i + 3)); i += 5; break;
          case 10: N[w[i + 1]].appendChild(N[w[i + 2]]); i += 3; break;
          case 11: N[w[i + 1]].insertBefore(N[w[i + 2]], N[w[i + 3]]); i += 4; break;
          case 12: N[w[i + 1]].remove(); i += 2; break;
          case 14: N[w[i + 1]] = undefined; i += 2; break;
          case 17: names[w[i + 1]] = S(i + 2); i += 4; break;
          case 18: document.querySelector(S(i + 1)).replaceChildren(N[w[i + 3]]); i += 4; break;
          case 19: {
            let h = w[i + 3];
            const walk = (p) => {
              for (let c = p.firstChild; c; ) {
                const next = c.nextSibling;
                if (c.nodeType === 8) { if (c.data === "t") { const t = document.createTextNode(""); c.replaceWith(t); N[h++] = t; } }
                else if (c.nodeType === 1 || c.nodeType === 3) { N[h++] = c; if (c.nodeType === 1) walk(c); }
                c = next;
              }
            };
            walk(document.querySelector(S(i + 1)));
            i += 5; break;
          }
          default: throw new Error("reference: opcode " + w[i]);
        }
      }
    }
  }
  class Lui {
    constructor() { this.rt = new LeanUI.Runtime({ event() {}, callback() {} }); }
    apply(b) {
      const ops = new Uint8Array(new Uint32Array(b.w).buffer), strs = new TextEncoder().encode(b.text);
      const u = new Uint8Array(ops.length + strs.length); u.set(ops); u.set(strs, ops.length);
      this.rt.apply(u, 0, ops.length, ops.length, strs.length);
    }
  }
  // a custom element that logs how many children its old parent has left when it is disconnected
  let disc = [];
  if (!customElements.get("x-probe"))
    customElements.define("x-probe", class extends HTMLElement {
      connectedCallback() { this.__p = this.parentNode; }
      disconnectedCallback() { disc.push(this.__p ? this.__p.childNodes.length : -1); }
    });

  const names = (b) => b.intern(1, "class").intern(2, "div").intern(3, "svg").intern(4, "circle").intern(5, "math")
    .intern(6, "mi").intern(7, "ul").intern(8, "x-probe").intern(9, "Class").intern(10, "p");
  // the document: root 80 holding list 90 (rows 100, 102, .. each a probe with a text child) and list 190 (rows 200, ..)
  const list = (b, ul, n, base) => { b.el(ul, 0, 7); for (let k = 0; k < n; k++) b.el(base + 2 * k, 0, 8).attr(base + 2 * k, 1, "r").txt(base + 2 * k + 1, "r" + k).app(base + 2 * k, base + 2 * k + 1).app(ul, base + 2 * k); return b; };
  const lists = (b) => { b.el(80, 0, 2); list(b, 90, 5, 100); list(b, 190, 3, 200); return b.app(80, 90).app(80, 190).mount(80); };
  const rmRow = (b, k) => b.rm(100 + 2 * k).free(101 + 2 * k).free(100 + 2 * k);
  // The runtime's observations where they differ from the reference's (null: they must not):
  // each record is one removal call (removed-node count), each disconnectedCallback logs the
  // children its old parent has left. The reference always removes one child per record.
  const batched = (records, disc) => ({ records, disc });
  const zeros = (n) => Array(n).fill(0);
  // name -> [initial html, setup buffer, the observed buffer, the runtime's expected difference]
  const scenarios = {
    // ---- SET_ATTR "class": className on HTML elements only ----
    classKinds: ["", (b) => b, (b) => names(b).el(20, 0, 2).el(21, 1, 3).el(22, 1, 4).el(23, 2, 5).el(24, 2, 6).app(20, 21).app(21, 22).app(20, 23).app(23, 24)
      .attr(20, 1, "h").attr(21, 1, "s").attr(22, 1, "c").attr(23, 1, "m").attr(24, 1, "i").attr(20, 9, "upper").attr(22, 1, "").mount(20), null],
    reuseAcrossNs: ["", (b) => names(b).el(30, 0, 2).mount(30), (b) => b.el(31, 0, 2).attr(31, 1, "a").app(30, 31).rm(31).free(31).el(31, 1, 3).attr(31, 1, "b").app(30, 31)
      .el(32, 1, 3).attr(32, 1, "c").app(30, 32).rm(32).free(32).el(32, 0, 2).attr(32, 1, "d").app(30, 32)
      .el(33, 1, 3).el(33, 0, 2).attr(33, 1, "e").app(30, 33).el(34, 0, 2).el(34, 1, 3).attr(34, 1, "f").app(30, 34), null],
    classOnText: ["", (b) => names(b).el(40, 0, 2).txt(41, "t").app(40, 41).mount(40), (b) => b.attr(41, 1, "x"), null],
    hydrated: ['<div class="a"><svg class="b"><circle class="c"></circle></svg><math><mi class="d">x</mi></math>text<!--t--></div>', (b) => names(b).hydrate(1, 8),
      (b) => b.attr(1, 1, "A").attr(2, 1, "B").attr(3, 1, "C").attr(4, 1, "D").attr(5, 1, "E"), null],
    // ---- REMOVE runs: list 90 holds rows 100..108, list 190 rows 200..204 ----
    clear: ["", (b) => lists(names(b)), (b) => { for (let k = 0; k < 5; k++) rmRow(b, k); return b; }, batched([5], zeros(5))],
    clearNoFree: ["", (b) => lists(names(b)), (b) => { for (let k = 0; k < 5; k++) b.rm(100 + 2 * k); return b; }, batched([5], zeros(5))],
    clearThenRebuild: ["", (b) => lists(names(b)), (b) => { for (let k = 0; k < 5; k++) rmRow(b, k); return b.el(100, 0, 8).attr(100, 1, "n").app(90, 100); }, batched([5], zeros(5))],
    clearParentFreed: ["", (b) => lists(names(b)), (b) => { b.rm(100).free(90); for (let k = 1; k < 5; k++) b.rm(100 + 2 * k); return b; }, batched([5], zeros(5))],
    clearEndsBuffer: ["", (b) => lists(names(b)), (b) => { for (let k = 0; k < 4; k++) rmRow(b, k); return b.rm(108); }, batched([5], zeros(5))],
    clearMoved: ["", (b) => lists(names(b)).ins(90, 108, 100), (b) => { for (const k of [4, 0, 1, 2, 3]) b.rm(100 + 2 * k); return b; }, batched([5], zeros(5))],
    clearBoth: ["", (b) => lists(names(b)), (b) => { for (let k = 0; k < 3; k++) b.rm(200 + 2 * k); for (let k = 0; k < 5; k++) b.rm(100 + 2 * k); return b; }, batched([3, 5], zeros(8))],
    // the rest of the list after the first removal empties it
    duplicate: ["", (b) => lists(names(b)), (b) => { b.rm(100).rm(100); for (let k = 1; k < 5; k++) b.rm(100 + 2 * k); return b; }, batched([1, 4], [4, ...zeros(4)])],
    outOfOrder: ["", (b) => lists(names(b)), (b) => { for (const k of [0, 2, 1, 3, 4]) rmRow(b, k); return b; }, batched([1, 1, 3], [4, 3, ...zeros(3)])],
    otherParent: ["", (b) => lists(names(b)), (b) => { b.rm(100).rm(200); for (let k = 1; k < 5; k++) b.rm(100 + 2 * k); return b; }, batched([1, 1, 4], [4, 2, ...zeros(4)])],
    reuseInRun: ["", (b) => lists(names(b)), (b) => { b.rm(100).free(101).free(100).el(100, 1, 3).attr(100, 1, "z").app(190, 100); for (let k = 1; k < 5; k++) b.rm(100 + 2 * k); return b; }, batched([1, 4], [4, ...zeros(4)])],
    // nothing batched (or a batch of one child, which no one can tell apart)
    partialHead: ["", (b) => lists(names(b)), (b) => { for (let k = 0; k < 3; k++) rmRow(b, k); return b; }, null],
    reversed: ["", (b) => lists(names(b)), (b) => { for (let k = 4; k >= 0; k--) rmRow(b, k); return b; }, null],
    notFirst: ["", (b) => lists(names(b)), (b) => { for (let k = 1; k < 5; k++) rmRow(b, k); return b; }, null],
    removeRoot: ["", (b) => lists(names(b)), (b) => b.rm(80).free(80), null],
    crashInRun: ["", (b) => lists(names(b)), (b) => { rmRow(b, 0); rmRow(b, 1); return b.rm(9999); }, null],
    markers: ["<p><!--|-->a<!--|-->b</p>", (b) => names(b).hydrate(1, 3), (b) => b.rm(2).free(2).rm(3).free(3), null],
  };

  const app = () => document.getElementById("app");
  const observe = (impl, html, setup, buf) => {
    document.body.innerHTML = '<div id="app">' + html + "</div>";
    const out = { error: null, records: [], disc: [] };
    try { impl.apply(setup(B())); } catch (e) { out.setupError = e.constructor.name; }
    disc = [];
    const mo = new MutationObserver(() => {});
    mo.observe(app(), { childList: true, subtree: true });
    try { impl.apply(buf(B())); } catch (e) { out.error = e.constructor.name; }
    out.records = mo.takeRecords().filter((r) => r.removedNodes.length).map((r) => r.removedNodes.length);
    mo.disconnect();
    out.disc = disc; disc = [];
    out.dom = app().innerHTML;
    return out;
  };
  const failures = [], seen = {};
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  for (const [name, [html, setup, buf, diff]] of Object.entries(scenarios)) {
    const ref = observe(new Ref(), html, setup, buf), got = observe(new Lui(), html, setup, buf);
    seen[name] = { dom: got.dom, records: got.records.join(","), disc: got.disc.join(","), error: got.error };
    const fail = (what) => failures.push(`${name}: ${what}\n     runtime   ${JSON.stringify(got)}\n     reference ${JSON.stringify(ref)}`);
    if (got.dom !== ref.dom || got.error !== ref.error || got.setupError !== ref.setupError) fail("the DOM or the error differs");
    else if (diff === null) { if (!same(got.records, ref.records) || !same(got.disc, ref.disc)) fail("an undocumented observable difference"); }
    else if (!ref.records.every((n) => n === 1) || ref.records.length !== got.disc.length) fail("the reference does not remove one child per record");
    else if (!same(got.records, diff.records) || !same(got.disc, diff.disc))
      fail(`expected records ${diff.records} and disconnectedCallbacks ${diff.disc} (one record per batched run, its callbacks after its last removal)`);
  }
  return { scenarios: Object.keys(scenarios).length, failures, seen };
}

let ok = true;
const results = {};
for (const engine of engines) {
  const browser = await pw[engine].launch({ headless: true });
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
  await page.setContent('<!doctype html><html><body><div id="app"></div></body></html>');
  await page.addScriptTag({ content: runtime });
  const r = await page.evaluate(check);
  await browser.close();
  results[engine] = { version: browser.version(), scenarios: r.scenarios, failures: r.failures.length, errors };
  if (argv.includes("--verbose")) results[engine].seen = r.seen;
  for (const f of r.failures) console.log(`  FAIL ${engine} ${f}`);
  ok &&= r.failures.length === 0 && errors.length === 0 && r.scenarios > 0;
}
console.log(JSON.stringify(results, null, 1));
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
