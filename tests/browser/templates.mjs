// Template cloning in real browsers: a clone must be indistinguishable from a mount.
//
//   ./.lake/build/bin/leanui-props --only corpus --corpus work/corpus    (writes templates.jsonl)
//   node tests/browser/templates.mjs work/corpus/templates.jsonl [chromium|firefox|both]
//   (run under the host browser lock)
//
// 1. The engine's buffers for each scenario of LeanUI.Testing.Pool.Scenario, once with templates
//    and once without, go through runtime/leanui.js (Runtime.apply, no wasm). After every buffer,
//    and after a probe at the end, the two DOMs must be the same: every node, its attributes in
//    order, value/checked/selected/selectedIndex, listener slots (__lui), how many scripts ran.
//    The probe sets each control's content attribute (value, checked; a textarea gets a text) and
//    reads the property back, which shows whether the value or checkedness is dirty.
//    This is what the DOM model cannot see: properties reflecting onto attributes, a property
//    assignment the runtime skips because the value is already there, controls' dirty flags.
// 2. Hand-encoded: a template with SVG and MathML, empty and adjacent texts; and a TEMPLATE whose
//    handles are not its subtree is rejected.
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire("/Users/fawadhaider/code/wasm64-lean-fable/qed64/package.json");
const pw = require("playwright");
const here = path.dirname(fileURLToPath(import.meta.url));
const runtime = fs.readFileSync(path.join(here, "../../runtime/leanui.js"), "utf8");
const [casesFile, which = "both"] = process.argv.slice(2);
if (!casesFile) { console.error("usage: node tests/browser/templates.mjs <templates.jsonl> [chromium|firefox|both]"); process.exit(2); }
const scenarios = fs.readFileSync(casesFile, "utf8").trim().split("\n").map((l) => JSON.parse(l));
const engines = which === "both" ? ["chromium", "firefox"] : [which];

// in the page: apply both buffer sequences, return the differences
function compare(c) {
  const unb64 = (s) => Uint8Array.from(atob(s), (ch) => ch.charCodeAt(0));
  const snap = () => {
    const out = [];
    const walk = (n, d) => {
      const pad = " ".repeat(d);
      if (n.nodeType === 3) { out.push(`${pad}#text ${JSON.stringify(n.data)}`); return; }
      if (n.nodeType !== 1) { out.push(`${pad}#${n.nodeType}`); return; }
      const attrs = [...n.attributes].map((a) => `${a.name}=${JSON.stringify(a.value)}`).join(" ");
      const st = [];
      if (n.localName === "input" || n.localName === "textarea" || n.localName === "select" || n.localName === "option") st.push(`value=${JSON.stringify(n.value)}`);
      if ("checked" in n) st.push(`checked=${n.checked}`);
      if ("selected" in n) st.push(`selected=${n.selected}`);
      if ("selectedIndex" in n) st.push(`selectedIndex=${n.selectedIndex}`);
      if (n.__lui) st.push(`lui=${JSON.stringify(n.__lui)}`);
      const ns = n.namespaceURI === "http://www.w3.org/1999/xhtml" ? "" : n.namespaceURI + ":";
      out.push(`${pad}<${ns}${n.localName} ${attrs}> {${st.join(" ")}}`);
      for (let k = n.firstChild; k; k = k.nextSibling) walk(k, d + 1);
    };
    walk(document.getElementById("app"), 0);
    return out;
  };
  const probe = () => {
    const out = [];
    for (const el of document.querySelectorAll("#app input, #app textarea")) {
      if (el.localName === "textarea") { el.appendChild(document.createTextNode("+P")); out.push(`textarea value=${JSON.stringify(el.value)}`); continue; }
      const t = el.type;
      if (t === "checkbox" || t === "radio") { el.toggleAttribute("checked"); out.push(`${t} checked=${el.checked}`); }
      else { el.setAttribute("value", "7"); out.push(`${t} value=${JSON.stringify(el.value)}`); }
    }
    return out;
  };
  const run = (bufs) => {
    document.body.innerHTML = '<div id="app"></div>';
    window.__runs = 0;
    const rt = new LeanUI.Runtime({ event() {}, callback() {} });
    const states = [];
    for (const s of bufs) {
      const b = unb64(s);
      const n = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
      rt.apply(b, 4, n, 4 + n, b.length - 4 - n);
      states.push([...snap(), "scripts run: " + window.__runs]);
    }
    states.push(probe());
    return states;
  };
  let on, off;
  try { on = run(c.on); } catch (e) { on = [["threw " + e]]; }
  try { off = run(c.off); } catch (e) { off = [["threw " + e]]; }
  const diffs = [];
  for (let s = 0; s < Math.max(on.length, off.length); s++) {
    const a = on[s] || [], b = off[s] || [];
    const when = s === off.length - 1 ? "probe" : "after buffer " + s;
    for (let i = 0; i < Math.max(a.length, b.length); i++)
      if (a[i] !== b[i]) diffs.push(`${when}: clone ${a[i]}\n      mount ${b[i]}`);
  }
  return diffs;
}

// in the page: hand-encoded buffers
function handChecks() {
  // [u32 opsBytes][ops][strs]; a command is a list of numbers and {s: string} operands
  const encode = (cmds) => {
    const words = []; let text = "";
    for (const c of cmds) for (const x of c) {
      if (typeof x === "number") words.push(x);
      else { words.push(text.length, x.s.length); text += x.s; }
    }
    const strs = new TextEncoder().encode(text);
    const out = new Uint8Array(4 + 4 * words.length + strs.length);
    const dv = new DataView(out.buffer);
    dv.setUint32(0, 4 * words.length, true);
    words.forEach((w, i) => dv.setUint32(4 + 4 * i, w, true));
    out.set(strs, 4 + 4 * words.length);
    return out;
  };
  const S = (s) => ({ s });
  const names = ["div", "span", "innerHTML", "b", "type", "svg", "g", "math", "mi"];
  const N = (n) => names.indexOf(n) + 1;
  const intern = names.map((n, i) => [17, i + 1, S(n)]);
  const results = [];
  const check = (name, ok, detail = "") => results.push({ name, ok: !!ok, detail });
  const fresh = () => {
    document.body.innerHTML = '<div id="app"></div>';
    const rt = new LeanUI.Runtime({ event() {}, callback() {} });
    const apply = (cmds) => { const b = encode(cmds); const n = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24); rt.apply(b, 4, n, 4 + n, b.length - 4 - n); };
    return { rt, apply };
  };

  // namespaces, empty and adjacent texts
  {
    const { rt, apply } = fresh();
    apply([...intern,
      [1, 1, 0, N("div")], [1, 2, 1, N("svg")], [10, 1, 2], [1, 3, 1, N("g")], [3, 3, N("type"), S("x")], [10, 2, 3],
      [1, 4, 2, N("math")], [10, 1, 4], [1, 5, 2, N("mi")], [10, 4, 5], [2, 6, S("")], [10, 5, 6],
      [2, 7, S("a")], [10, 1, 7], [2, 8, S("")], [10, 1, 8], [2, 9, S("b")], [10, 1, 9],
      [20, 1, 9, 1, 2, 3, 4, 5, 6, 7, 8, 9],
      [21, 1, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18], [9, 15, S("m")], [9, 16, S("")], [9, 17, S("e")],
      [18, S("#app"), 10]]);
    const n = rt.nodes;
    const SVG = "http://www.w3.org/2000/svg", MATH = "http://www.w3.org/1998/Math/MathML";
    check("namespaces: svg", n[11].namespaceURI === SVG && n[12].namespaceURI === SVG && n[12].getAttribute("type") === "x");
    check("namespaces: math", n[13].namespaceURI === MATH && n[14].namespaceURI === MATH && n[15].parentNode === n[14]);
    check("texts: empty and adjacent", n[10].childNodes.length === 5 && n[15].data === "m" && n[16].data === "" && n[17].data === "e" && n[18].data === "b" &&
      n[16].nodeType === 3 && n[16].previousSibling === n[13]);
  }
  // a TEMPLATE must name exactly its subtree: here a property added children Lean does not know
  {
    const { apply } = fresh();
    let err = "";
    try {
      apply([...intern,
        [1, 1, 0, N("div")], [1, 2, 0, N("span")], [5, 2, N("innerHTML"), S("<i>x</i>")], [10, 1, 2],
        [2, 3, S("t")], [10, 1, 3], [1, 4, 0, N("b")], [10, 1, 4], [20, 1, 4, 1, 2, 3, 4]]);
    } catch (e) { err = String(e); }
    check("a TEMPLATE that does not name its subtree is rejected", /TEMPLATE 1 names 4 nodes, its subtree has 6/.test(err), err);
  }
  return results;
}

let allOk = true;
for (const engine of engines) {
  const browser = await pw[engine].launch({ headless: true });
  const page = await browser.newPage();
  await page.setContent('<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  await page.addScriptTag({ content: runtime });
  let same = 0, templates = 0;
  for (const c of scenarios) {
    const diffs = await page.evaluate(compare, c);
    templates += c.templates;
    if (diffs.length === 0) { same++; continue; }
    allOk = false;
    console.log(`  FAIL ${engine}: ${c.name} (${c.templates} templates)`);
    for (const d of diffs.slice(0, 6)) console.log("    " + d);
  }
  const results = await page.evaluate(handChecks);
  const failed = results.filter((r) => !r.ok);
  for (const f of failed) console.log(`  FAIL ${engine}: ${f.name} ${f.detail}`);
  if (failed.length) allOk = false;
  console.log(`${engine} ${browser.version()}: ${same}/${scenarios.length} scenarios build the same DOM with templates (${templates} templates); ${results.length - failed.length}/${results.length} hand-encoded checks`);
  await browser.close();
}
console.log(allOk ? "PASS" : "FAIL");
process.exit(allOk ? 0 : 1);
