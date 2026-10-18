// Template cloning and batched insertion in real browsers: what the DOM model cannot see.
//
//   node tests/browser/templates.mjs [chromium|firefox|both]      (run under the host browser lock)
//
// Hand-encoded command buffers go through runtime/leanui.js (Runtime.apply, no wasm):
//   1. TEMPLATE keeps only the nodes Lean knows: children an innerHTML property created are not
//      in the template, so CLONE still gives every handle its node (pre-order);
//   2. a template's form controls are fresh: a clone's input has neither the template's value nor
//      its checkedness, and is not dirty (a later value/checked attribute shows), as after a mount;
//   3. INSERT_MANY inserts in order, before a reference or at the end, moving attached nodes;
//   4. a CLONE of a template with SVG and MathML elements, empty and adjacent texts.
// LeanUI/Testing/Dom.lean models the same commands for everything else (tests/browser/fuzz.mjs).
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire("/Users/fawadhaider/code/wasm64-lean-fable/qed64/package.json");
const pw = require("playwright");
const here = path.dirname(fileURLToPath(import.meta.url));
const runtime = fs.readFileSync(path.join(here, "../../runtime/leanui.js"), "utf8");
const which = process.argv[2] || "both";
const engines = which === "both" ? ["chromium", "firefox"] : [which];

function cases() {
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
  const names = ["div", "span", "innerHTML", "b", "input", "value", "checked", "type", "textarea", "svg", "g", "math", "mi", "p"];
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

  // 1. a property that adds children (innerHTML) inside a template
  {
    const { rt, apply } = fresh();
    apply([...intern,
      [1, 1, 0, N("div")], [1, 2, 0, N("span")], [5, 2, N("innerHTML"), S("<i>x</i><i>y</i>")], [10, 1, 2],
      [2, 3, S("t")], [10, 1, 3], [1, 4, 0, N("b")], [10, 1, 4], [2, 5, S("u")], [10, 4, 5],
      [20, 1, 5, 1, 2, 3, 4, 5],
      [21, 1, 5, 6, 7, 8, 9, 10], [5, 7, N("innerHTML"), S("<i>z</i>")], [9, 8, S("T")], [9, 10, S("U")],
      [1, 11, 0, N("p")], [22, 11, 0, 2, 1, 6], [18, S("#app"), 11]]);
    const n = rt.nodes;
    check("innerHTML: original intact", n[1].outerHTML === "<div><span><i>x</i><i>y</i></span>t<b>u</b></div>", n[1].outerHTML);
    check("innerHTML: clone built", n[6].outerHTML === "<div><span><i>z</i></span>T<b>U</b></div>", n[6].outerHTML);
    check("innerHTML: clone handles", n[7].localName === "span" && n[8].data === "T" && n[9].localName === "b" && n[10].data === "U" && n[10].parentNode === n[9]);
    check("innerHTML: insertMany appended both", document.getElementById("app").innerHTML === "<p>" + n[1].outerHTML + n[6].outerHTML + "</p>", document.getElementById("app").innerHTML);
  }

  // 2. form controls in a template are fresh
  {
    const { rt, apply } = fresh();
    apply([...intern,
      [1, 1, 0, N("div")],
      [1, 2, 0, N("input")], [5, 2, N("value"), S("typed")], [10, 1, 2],
      [1, 3, 0, N("input")], [3, 3, N("type"), S("checkbox")], [6, 3, N("checked"), 1], [10, 1, 3],
      [1, 4, 0, N("textarea")], [5, 4, N("value"), S("area")], [10, 1, 4],
      [20, 1, 4, 1, 2, 3, 4],
      [21, 1, 4, 5, 6, 7, 8], [18, S("#app"), 5]]);
    const n = rt.nodes;
    check("controls: template original keeps its state", n[2].value === "typed" && n[3].checked && n[4].value === "area");
    check("controls: clone input value is fresh", n[6].value === "", JSON.stringify(n[6].value));
    check("controls: clone checkbox is fresh", n[7].type === "checkbox" && !n[7].checked);
    check("controls: clone textarea is fresh", n[8].value === "", JSON.stringify(n[8].value));
    n[6].setAttribute("value", "attr"); n[7].setAttribute("checked", "");
    check("controls: clone input not dirty", n[6].value === "attr", JSON.stringify(n[6].value));
    check("controls: clone checkbox not dirty", n[7].checked === true);
    // what a mount would have done: the same properties on fresh controls
    apply([[5, 6, N("value"), S("v2")], [6, 7, N("checked"), 0]]);
    check("controls: properties after the clone", n[6].value === "v2" && n[7].checked === false);
  }

  // 3. INSERT_MANY
  {
    const { rt, apply } = fresh();
    const mk = [];
    for (let h = 2; h <= 7; h++) mk.push([1, h, 0, N("b")], [3, h, N("value"), S("n" + h)]);
    apply([...intern, [1, 1, 0, N("div")], ...mk, [1, 8, 0, N("div")],
      [22, 1, 0, 2, 2, 3],            // 2 3
      [22, 1, 3, 2, 4, 5],            // 2 4 5 3
      [10, 8, 6], [10, 8, 7],          // 6 and 7 in another parent
      [22, 1, 4, 3, 7, 3, 6],         // 2 7 3 6 4 5  (3 moves within the parent, 7 and 6 from 8)
      [22, 1, 0, 1, 2],               // 7 3 6 4 5 2
      [18, S("#app"), 1]]);
    const order = [...rt.nodes[1].children].map((e) => e.getAttribute("value")).join(" ");
    check("insertMany: order", order === "n7 n3 n6 n4 n5 n2", order);
    check("insertMany: moved out of the other parent", rt.nodes[8].childNodes.length === 0);
  }

  // 4. namespaces, empty and adjacent texts
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
  return results;
}

let allOk = true;
for (const engine of engines) {
  const browser = await pw[engine].launch({ headless: true });
  const page = await browser.newPage();
  await page.setContent('<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  await page.addScriptTag({ content: runtime });
  const results = await page.evaluate(cases);
  const failed = results.filter((r) => !r.ok);
  console.log(`${engine} ${browser.version()}: ${results.length - failed.length}/${results.length} checks passed`);
  for (const f of failed) console.log(`  FAIL ${f.name} ${f.detail}`);
  if (failed.length) allOk = false;
  await browser.close();
}
console.log(allOk ? "PASS" : "FAIL");
process.exit(allOk ? 0 : 1);
