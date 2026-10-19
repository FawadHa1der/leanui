// Allocations of the photo editor's work in wasm (tools/alloc-count.c counts every malloc, free,
// realloc and byte requested): each EditorBench operation on a 1 MP image, and in the editor one
// slider input and one brush move. Pixel loops must not allocate per pixel: a run should cost a
// few allocations (its output image, a lookup table, a temporary), whatever the image size.
//
//   LEANUI_COUNT_ALLOCS=1 tools/build-app.sh EditorBenchApp editor-bench-allocs
//   LEANUI_COUNT_ALLOCS=1 tools/build-app.sh EditorApp editor-allocs
//   .lake/build/bin/leanui serve dist --port 5331 &
//   node tests/browser/editor-allocs.mjs http://127.0.0.1:5331/ [--sizes 1,4]
import { pw } from "./playwright.mjs";

const args = process.argv.slice(2);
const base = (args.find((a) => a.startsWith("http")) || "http://127.0.0.1:5331/").replace(/\/?$/, "/");
const si = args.indexOf("--sizes");
const SIZES = (si >= 0 ? args[si + 1] : "1,4").split(",").map((s) => ({ 1: [1152, 864], 4: [2304, 1728], 12: [4000, 3000] }[s]));
const browser = await pw.chromium.launch({ headless: true });
const fmt = (n) => Math.round(n).toLocaleString("en-US");

async function open(url) {
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
  await page.goto(url);
  await page.waitForFunction(() => window.__leanui, null, { timeout: 30000 });
  const ok = await page.evaluate(() => {
    const mod = window.__leanui.transport.mod;
    if (!mod._leanui_alloc_counter) return false;
    window.__counts = () => [0, 1, 2, 3].map((i) => mod._leanui_alloc_counter(i));
    return true;
  });
  if (!ok) throw new Error(url + " is not a counting build (LEANUI_COUNT_ALLOCS=1)");
  return page;
}
// counters around `fn` (run in the page): allocations, frees, reallocs, bytes
const counted = (page, fn, arg) => page.evaluate(([src, arg]) => {
  const f = new Function("arg", src);
  const a = window.__counts(); f(arg); const b = window.__counts();
  return b.map((x, i) => x - a[i]);
}, [fn, arg]);

const rows = [];
{
  const page = await open(base + "editor-bench-allocs/index.html");
  const ops = ["adjust-lut", "adjust-color", "blur-2", "blur-8", "sharpen", "emboss", "edges", "rotate-90", "rotate-180",
    "flip-h", "flip-v", "resize-50", "downscale-8", "composite-normal", "composite-overlay", "histogram", "png-stored", "png-1", "crop-half"];
  const cmd = `const e = document.querySelector("#cmd"); e.value = arg; e.dispatchEvent(new Event("input", { bubbles: true }));`;
  for (const [w, h] of SIZES) {
    await counted(page, cmd, `make ${w} ${h}`);
    for (const op of ops) {
      await counted(page, cmd, `run ${op}`);            // warm-up: the previous result is replaced
      const c = await counted(page, cmd, `run ${op}`);
      rows.push({ what: op, size: `${w}×${h}`, allocs: c[0], frees: c[1], reallocs: c[2], bytes: c[3] });
    }
  }
  await page.close();
}
{
  const page = await open(base + "editor-allocs/index.html");
  await page.click("#new-1");
  const slide = `const e = document.querySelector(arg[0]); e.value = String(arg[1]); e.dispatchEvent(new Event("input", { bubbles: true }));`;
  for (const [name, sel, a, b] of [["slider input: brightness", "#adj-brightness", 20, 30], ["slider input: blur radius", "#blur-radius", 5, 6]]) {
    await page.evaluate(([sel, v]) => { const e = document.querySelector(sel); e.value = String(v); e.dispatchEvent(new Event("input", { bubbles: true })); }, [sel, a]);
    const c = await counted(page, slide, [sel, b]);
    rows.push({ what: name, size: "1152×864 (preview)", allocs: c[0], frees: c[1], reallocs: c[2], bytes: c[3] });
  }
  await page.evaluate(() => document.querySelector("#adj-reset").click());
  await page.evaluate(() => document.querySelector("#filter-cancel").click());
  await page.click("#tool-brush");
  const ptr = `const c = document.querySelector("#canvas"), r = c.getBoundingClientRect();
    c.dispatchEvent(new PointerEvent(arg[0], { bubbles: true, pointerId: 1, buttons: arg[0] === "pointerup" ? 0 : 1, clientX: r.left + r.width * arg[1], clientY: r.top + r.height * 0.5 }));`;
  await counted(page, ptr, ["pointerdown", 0.2]);
  await counted(page, ptr, ["pointermove", 0.25]);
  const c = await counted(page, ptr, ["pointermove", 0.3]);
  rows.push({ what: "brush move (24 px brush)", size: "1152×864", allocs: c[0], frees: c[1], reallocs: c[2], bytes: c[3] });
  await counted(page, ptr, ["pointerup", 0.3]);
  await page.close();
}
await browser.close();
console.log("| work | image | allocations | frees | reallocs | bytes requested |\n|---|---|--:|--:|--:|--:|");
for (const r of rows) console.log(`| ${r.what} | ${r.size} | ${fmt(r.allocs)} | ${fmt(r.frees)} | ${fmt(r.reallocs)} | ${fmt(r.bytes)} |`);
