// Differential fuzzing of runtime/leanui.js against the Lean DOM model (LeanUI.Testing.Dom).
//
//   .lake/build/bin/leanui-props --only corpus --corpus <dir>      (writes <dir>/corpus.jsonl)
//   node tests/browser/fuzz.mjs <dir>/corpus.jsonl [chromium|firefox|both] [--strict]
//   (run under the host browser lock)
//
// Every session in the corpus was run natively by the engine; the corpus holds each buffer it
// flushed and what the model held afterwards. Here the same buffers go through the real browser
// runtime (no wasm: the runtime's `Runtime.apply` is called directly), and after every buffer we
// compare: the DOM (namespaces, tags, attributes, texts, listener slots/payload kinds/flags, in
// the same canonical form as `LeanUI.Testing.strictDom`), every DOM property the model set, and
// for every listener a dispatched event: which slots it reaches (bubbling, stopPropagation), the
// payload the runtime extracts, and whether the default is prevented. Hydration sessions start
// from the server-rendered HTML parsed by the browser's own HTML parser.
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire("/Users/fawadhaider/code/wasm64-lean-fable/qed64/package.json");
const pw = require("playwright");
const here = path.dirname(fileURLToPath(import.meta.url));
const runtime = fs.readFileSync(path.join(here, "../../runtime/leanui.js"), "utf8");

const args = process.argv.slice(2);
const strict = args.includes("--strict");
const pos = args.filter((a) => !a.startsWith("--"));
const corpusPath = pos[0];
if (!corpusPath) { console.error("usage: fuzz.mjs <corpus.jsonl> [chromium|firefox|both] [--strict]"); process.exit(2); }
const engines = (pos[1] || "both") === "both" ? ["chromium", "firefox"] : [pos[1]];
const corpus = fs.readFileSync(corpusPath, "utf8").trim().split("\n").map((l) => JSON.parse(l));

// Runs in the page: replay a batch of sessions, return per-session results.
function replay(sessions) {
  const SVG = "http://www.w3.org/2000/svg", MATH = "http://www.w3.org/1998/Math/MathML";
  const lp = (s) => [...s].length + ":" + s;
  const byName = (a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0);
  const canon = (n) => {
    if (n.nodeType === 3) return "#" + lp(n.data);
    const ns = n.namespaceURI === SVG ? 1 : n.namespaceURI === MATH ? 2 : 0;
    const attrs = [...n.attributes].map((a) => [a.name, a.value]).sort(byName);
    const ls = Object.entries(n.__lui || {}).map(([e, [sl, pl, fl]]) => [e, `${pl}/${fl}@${sl}`]).sort(byName);
    const kids = [...n.childNodes].filter((c) => c.nodeType !== 8).map(canon).join("");
    return `<${ns}:${n.localName}${attrs.map(([k, v]) => ` @${k}=${lp(v)}`).join("")}${ls.map(([e, x]) => ` !${e}/${x}`).join("")}>${kids}</>`;
  };
  const preorder = (n, out) => { out.push(n); for (const c of n.childNodes) if (c.nodeType !== 8) preorder(c, out); return out; };
  const b64 = (s) => { const bin = atob(s); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u; };
  const firstDiff = (a, b) => { let i = 0; while (i < a.length && a[i] === b[i]) i++; return i; };
  const clip = (s, i) => s.slice(Math.max(0, i - 60), i + 140);
  let pageErrors = 0;
  addEventListener("error", (e) => { pageErrors++; e.preventDefault(); });
  // a parsed page as the hydration walk sees it: <!--t--> is an empty text, other comments are skipped
  const canonParsed = (n) => {
    if (n.nodeType === 8) return n.data === "t" ? "#0:" : "";
    if (n.nodeType === 3) return "#" + lp(n.data);
    const ns = n.namespaceURI === SVG ? 1 : n.namespaceURI === MATH ? 2 : 0;
    const attrs = [...n.attributes].map((a) => [a.name, a.value]).sort(byName);
    return `<${ns}:${n.localName}${attrs.map(([k, v]) => ` @${k}=${lp(v)}`).join("")}>${[...n.childNodes].map(canonParsed).join("")}</>`;
  };
  const results = [];
  for (const c of sessions) {
    if (c.parse !== undefined) {
      const app = document.createElement("div");
      app.innerHTML = c.parse;
      const got = [...app.childNodes].map(canonParsed).join("");
      results.push({ case: c.case, parse: true, hazards: c.hazards, exact: got === c.view, modelOk: c.model === null ? null : got === c.model,
                     got: got.slice(0, 300), view: c.view.slice(0, 300), model: (c.model || "").slice(0, 300), html: c.parse.slice(0, 300) });
      continue;
    }
    const r = { case: c.case, chaos: c.chaos, hydrate: c.html !== null, steps: 0, canon: 0, props: 0, events: 0, throws: 0, bubbledEnter: 0, fail: null };
    results.push(r);
    try {
      document.body.innerHTML = '<div id="app">' + (c.html ?? "") + "</div>";
      const sent = [];
      const rt = new LeanUI.Runtime({ event: (slot, payload) => sent.push([slot, payload]), callback() {} });
      for (let k = 0; k < c.steps.length && !r.fail; k++) {
        const st = c.steps[k];
        const bytes = b64(st.buf);
        const opsLen = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
        rt.apply(bytes, 4, opsLen, 4 + opsLen, bytes.length - 4 - opsLen);
        r.steps++;
        if (st.canon === null) continue;
        const app = document.getElementById("app");
        const tops = [...app.childNodes].filter((n) => n.nodeType !== 8);
        if (tops.length !== 1) { r.fail = { step: k, what: `container holds ${tops.length} nodes` }; break; }
        const got = canon(tops[0]);
        r.canon++;
        if (got !== st.canon) { const i = firstDiff(got, st.canon); r.fail = { step: k, what: "DOM differs", got: clip(got, i), want: clip(st.canon, i) }; break; }
        const order = preorder(tops[0], []);
        for (const [i, name, v] of st.props) {
          const val = order[i][name];
          r.props++;
          const ok = String(val) === v || (typeof val === "number" && val === Number(v));
          if (!ok) { r.fail = { step: k, what: `property ${name} of node ${i} is ${JSON.stringify(val)}, the model says ${JSON.stringify(v)}` }; break; }
        }
        if (r.fail) break;
        for (const [i, ev, chain] of st.fires) {
          sent.length = 0;
          const errs = pageErrors;
          const e = ev === "keydown" ? new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })
            : new Event(ev, { bubbles: ev !== "mouseenter", cancelable: true });
          order[i].dispatchEvent(e);
          r.events++;
          if (ev === "mouseenter" && sent.length > 1) r.bubbledEnter++;
          // the model's chain; a null payload means the runtime's extraction throws there
          const cut = chain.findIndex(([, p]) => p === null);
          const reached = cut < 0 ? chain : chain.slice(0, cut);
          const want = reached.map(([sl, p]) => [sl, p]);
          const prevented = (cut < 0 ? chain : chain.slice(0, cut + 1)).some(([, , fl]) => fl & 1);
          if (cut >= 0) { r.throws++; if (pageErrors === errs) { r.fail = { step: k, what: `${ev} on node ${i}: expected the formData extraction to throw` }; break; } }
          if (JSON.stringify(sent) !== JSON.stringify(want)) { r.fail = { step: k, what: `${ev} on node ${i} reached ${JSON.stringify(sent)}, the model says ${JSON.stringify(want)}` }; break; }
          if (e.defaultPrevented !== prevented) { r.fail = { step: k, what: `${ev} on node ${i}: defaultPrevented ${e.defaultPrevented}, the model says ${prevented}` }; break; }
        }
      }
    } catch (e) {
      r.fail = { step: r.steps, what: "exception: " + (e && e.message) };
    }
  }
  return results;
}

let allOk = true;
for (const engine of engines) {
  const t0 = Date.now();
  const browser = await pw[engine].launch({ headless: true });
  const page = await browser.newPage();
  await page.setContent('<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  await page.addScriptTag({ content: runtime });
  const results = [];
  for (let i = 0; i < corpus.length; i += 20) results.push(...(await page.evaluate(replay, corpus.slice(i, i + 20))));
  const version = browser.version();
  await browser.close();
  const parses = results.filter((r) => r.parse);
  const sessions = results.filter((r) => !r.parse);
  const sum = (k) => sessions.reduce((n, r) => n + r[k], 0);
  const failed = sessions.filter((r) => r.fail);
  const throws = sum("throws");
  console.log(`${engine} ${version}: ${sessions.length} sessions (${sessions.filter((r) => r.hydrate).length} hydrated, ${sessions.filter((r) => r.chaos).length} chaos), ` +
    `${sum("steps")} buffers applied, ${sum("canon")} DOM comparisons, ${sum("props")} property checks, ${sum("events")} events dispatched; ` +
    `${failed.length} failing (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
  // the parser model and the hazard lint against this browser's HTML parser
  const flagged = parses.filter((r) => r.hazards.length), clean = parses.filter((r) => !r.hazards.length);
  const unsound = clean.filter((r) => !r.exact);
  const modelWrong = parses.filter((r) => r.modelOk === false);
  const modelWrongClean = modelWrong.filter((r) => !r.hazards.length);
  const diverge = flagged.filter((r) => !r.exact).length;
  console.log(`  ${parses.length} server renderings parsed: ${clean.length} hazard-free, ${clean.length - unsound.length} exact; ` +
    `${flagged.length} flagged by the lint, ${diverge} really diverge (${flagged.length - diverge} harmless: the lint over-approximates); ` +
    `parser model agrees with the browser on ${parses.length - modelWrong.length}/${parses.length} (${modelWrongClean.length} disagreements on hazard-free trees)`);
  for (const u of unsound.slice(0, 4)) console.log(`  LINT MISSED case ${u.case}: ${u.html}\n     got  ${u.got}\n     view ${u.view}`);
  for (const u of modelWrongClean.slice(0, 4)) console.log(`  MODEL WRONG case ${u.case}: ${u.html}\n     got   ${u.got}\n     model ${u.model}`);
  if (unsound.length || modelWrongClean.length) allOk = false;
  // attribute a model/browser disagreement to a hazard class only when the tree has one class
  const unmodeled = {};
  for (const r of modelWrong) {
    const cls = [...new Set(r.hazards.map((h) => h.replace(/<[^>]*>/g, "<_>").replace(/ \(.*$/, "")))];
    const k = cls.length === 1 ? cls[0] : "several hazards";
    unmodeled[k] = (unmodeled[k] || 0) + 1;
  }
  if (modelWrong.length) console.log(`  where the parser model differs from this browser (all flagged by the lint): ${Object.entries(unmodeled).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ×${v}`).join(", ")}`);
  const entered = sum("bubbledEnter");
  if (entered) console.log(`  semantics note: ${entered} mouseenter events also reached an ancestor's mouseenter listener (delegation walks up for non-bubbling events)`);
  if (throws) console.log(`  runtime issue: ${throws} events reached a payload: formData listener on an element that is not a <form>; extract() throws (new FormData(el)) and the rest of the chain is lost`);
  for (const f of failed.slice(0, 8)) console.log(`  FAIL case ${f.case}${f.hydrate ? " (hydrated)" : ""} step ${f.fail.step}: ${f.fail.what}${f.fail.got !== undefined ? `\n     got ${f.fail.got}\n    want ${f.fail.want}` : ""}`);
  if (failed.length || (strict && throws)) allOk = false;
}
console.log(allOk ? "PASS" : "FAIL");
process.exit(allOk ? 0 : 1);
