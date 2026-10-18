// Keyed reconciliation against the real DOM (the one link docs/PROOFS.md cannot prove).
//
// tests/KeyedDom.lean (the leanui-keyed-dom executable, built by `lake build`) runs the real LeanUI
// runtime natively over random edits of a keyed list and prints every command buffer. Here runtime/leanui.js applies those buffers in Chromium and
// Firefox, and after every update we check, independently of Lean:
//   * order: the <li>s are exactly the rows the model shows;
//   * identity: every row that survives an update is the same DOM node (moved, never recreated);
//   * minimality: the number of insertBefore/appendChild calls on the list equals
//     |new| - LIS(old positions of the kept rows), the fewest any reordering can make.
//
//   node tests/browser/keyed-dom.mjs [steps] [seed] [engines]     (run under the host browser lock)
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire("/Users/fawadhaider/code/wasm64-lean-fable/qed64/package.json");
const pw = require("playwright");

const root = new URL("../..", import.meta.url).pathname;
const steps = process.argv[2] || "1500";
const seed = process.argv[3] || "1";
const engines = (process.argv[4] || "chromium,firefox").split(",");

const t0 = Date.now();
// compiled, not `lean --run`: the command buffer's primitives are inline C (LeanUI/Patch.lean),
// which the interpreter cannot run
const data = JSON.parse(execFileSync(root + ".lake/build/bin/leanui-keyed-dom", [steps, seed],
  { cwd: root, maxBuffer: 1 << 30 }).toString());
const genMs = Date.now() - t0;
const runtime = readFileSync(root + "runtime/leanui.js", "utf8");

function check(steps) {
  const hexBytes = (h) => { const b = new Uint8Array(h.length >>> 1); for (let i = 0; i < b.length; i++) b[i] = parseInt(h.substr(2 * i, 2), 16); return b; };
  // longest strictly increasing subsequence length (patience sorting), written independently of Lean
  const lis = (xs) => { const t = []; for (const x of xs) { let lo = 0, hi = t.length; while (lo < hi) { const m = (lo + hi) >> 1; if (t[m] < x) lo = m + 1; else hi = m; } t[lo] = x; } return t.length; };
  let inserts = 0;
  const ib = Node.prototype.insertBefore, ac = Node.prototype.appendChild;
  Node.prototype.insertBefore = function (n, r) { if (this.id === "list") inserts++; return ib.call(this, n, r); };
  Node.prototype.appendChild = function (n) { if (this.id === "list") inserts++; return ac.call(this, n); };
  const rt = new LeanUI.Runtime({ event() {}, callback() {} });
  LeanUI.active = rt;
  const r = { updates: 0, emptyUpdates: 0, inserts: 0, minInserts: 0, kept: 0, created: 0, maxRows: 0, failures: [] };
  let prevRows = [], prevEls = new Map(), ul0 = null;
  for (let s = 0; s < steps.length && r.failures.length < 5; s++) {
    const st = steps[s];
    const ops = hexBytes(st.ops), strs = hexBytes(st.strs);
    inserts = 0;
    if (ops.length) {
      const bytes = new Uint8Array(ops.length + strs.length); bytes.set(ops); bytes.set(strs, ops.length);
      rt.apply(bytes, 0, ops.length, ops.length, strs.length);
      r.updates++;
    } else r.emptyUpdates++;
    const ul = document.getElementById("list");
    if (!ul) { r.failures.push(`step ${s}: no list`); break; }
    if (ul0 && ul !== ul0) r.failures.push(`step ${s}: the list element was replaced`);
    ul0 = ul;
    const lis_ = [...ul.children];
    const got = lis_.map((li) => li.firstChild.data);
    const want = st.rows.map((k) => "row " + k);
    if (got.join("|") !== want.join("|")) { r.failures.push(`step ${s}: order ${got.join(",")} != ${want.join(",")}`); continue; }
    lis_.forEach((li, i) => {
      const k = st.rows[i];
      if (li.getAttribute("class") !== (k % 3 === 0 ? "a" : "b") || li.children[0].textContent !== String(k * 7 % 13))
        r.failures.push(`step ${s}: row ${k} content`);
    });
    // identity and minimality against the previous update
    const oldPos = new Map(prevRows.map((k, i) => [k, i]));
    const keptOld = [];
    st.rows.forEach((k, i) => {
      if (prevEls.has(k)) {
        r.kept++;
        if (prevEls.get(k) !== lis_[i]) r.failures.push(`step ${s}: row ${k} was recreated`);
        keptOld.push(oldPos.get(k));
      } else r.created++;
    });
    const minIns = st.rows.length - lis(keptOld);
    r.inserts += inserts; r.minInserts += minIns;
    if (inserts !== minIns) r.failures.push(`step ${s}: ${inserts} insertions, minimum is ${minIns} (${prevRows.length} -> ${st.rows.length} rows)`);
    r.maxRows = Math.max(r.maxRows, st.rows.length);
    prevRows = st.rows; prevEls = new Map(st.rows.map((k, i) => [k, lis_[i]]));
  }
  Node.prototype.insertBefore = ib; Node.prototype.appendChild = ac;
  return r;
}

let ok = true;
const results = { steps: data.steps.length, generateMs: genMs };
for (const engine of engines) {
  const browser = await pw[engine].launch({ headless: true });
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
  await page.setContent('<!doctype html><html><body><div id="app"></div></body></html>');
  await page.addScriptTag({ content: runtime });
  const t = Date.now();
  const r = await page.evaluate(check, data.steps);
  r.ms = Date.now() - t;
  r.version = browser.version();
  r.errors = errors;
  await browser.close();
  results[engine] = r;
  ok &&= r.failures.length === 0 && errors.length === 0 && r.updates > 0;
}
console.log(JSON.stringify(results, null, 1));
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
