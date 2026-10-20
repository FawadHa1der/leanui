// Browser test for the photo editor (examples/Editor.lean): open (file input and drop), a generated
// test image, adjustments with live preview, filters, painting, undo/redo (buttons, keys, the
// history panel), layers (add, paint, hide, rename, reorder, delete), geometry, crop, export
// (the PNG Lean encodes, decoded back by the browser).
// node tests/browser/editor.mjs <url of dist/editor/index.html> [chromium|firefox]
import { pw } from "./playwright.mjs";
import fs from "node:fs";

const url = process.argv[2] || "http://127.0.0.1:5331/editor/index.html";
const engine = process.argv[3] || "chromium";
const browser = await pw[engine].launch({ headless: true });
const page = await browser.newPage({ acceptDownloads: true, viewport: { width: 1400, height: 900 } });
const errors = [], checks = [];
page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
page.on("console", (m) => { if (m.type() === "error" || (m.type() === "warning" && m.text().includes("LeanUI"))) errors.push("console: " + m.text()); });
const check = (name, ok, detail = "") => { checks.push({ name, ok: !!ok, detail: ok ? undefined : detail }); if (!ok) console.log("FAIL", name, JSON.stringify(detail)); };
const text = (sel) => page.$eval(sel, (e) => e.textContent);
const count = (sel) => page.$$eval(sel, (es) => es.length);
const pixel = (x, y) => page.$eval("#canvas", (c, [x, y]) => Array.from(c.getContext("2d").getImageData(x, y, 1, 1).data), [x, y]);
const dims = () => page.$eval("#canvas", (c) => [c.width, c.height]);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const steps = () => page.$$eval("#history li", (es) => es.map((e) => e.textContent.replace(/^\d+/, "")));
const idle = () => page.waitForFunction(() => !document.querySelector("#busy"), null, { timeout: 60000 });
const setRange = (sel, v) => page.$eval(sel, (e, v) => { e.value = String(v); e.dispatchEvent(new Event("input", { bubbles: true })); }, v);
// canvas pixel (x, y) to page coordinates
async function at(x, y) {
  return page.$eval("#canvas", (c, [x, y]) => { const r = c.getBoundingClientRect(); return [r.left + (x + 0.5) * r.width / c.width, r.top + (y + 0.5) * r.height / c.height]; }, [x, y]);
}
async function drag(points) {
  const [x0, y0] = await at(...points[0]);
  await page.mouse.move(x0, y0); await page.mouse.down();
  for (const p of points.slice(1)) { const [x, y] = await at(...p); await page.mouse.move(x, y, { steps: 4 }); }
  await page.mouse.up();
}

await page.goto(url);
await page.waitForFunction(() => window.__leanui, null, { timeout: 30000 });
check("empty state", (await count("#canvas")) === 0 && (await count("#new-1")) === 1);

// ---- a generated 1 MP test image ----
await page.click("#new-1");
check("test image size", same(await dims(), [1152, 864]), await dims());
check("history: new", same(await steps(), ["New 1152×864"]), await steps());
const p0 = await pixel(100, 100);
check("opaque pixels", p0[3] === 255, p0);
check("histogram drawn", (await count("#histogram path")) === 4);

// ---- adjustments: live preview, apply, history ----
await setRange("#adj-brightness", 50);
const p1 = await pixel(100, 100);
check("brightness preview", p1[0] > p0[0] && p1[1] > p0[1], [p0, p1]);
check("preview is not a step", (await steps()).length === 1);
await page.click("#adj-apply");
await idle();
check("adjust applied", same(await steps(), ["New 1152×864", "Adjustments"]), await steps());
check("applied = previewed", same(await pixel(100, 100), p1), [p1, await pixel(100, 100)]);
check("sliders reset", (await page.$eval("#adj-brightness", (e) => e.value)) === "0");

// ---- a filter ----
await setRange("#blur-radius", 3);
await page.click("#blur-apply");
await idle();
check("blur step", (await steps()).at(-1) === "Blur 3px", await steps());
const flat = await page.$eval("#canvas", (c) => {
  // a blurred image has smaller neighbour differences than the noisy original
  const d = c.getContext("2d").getImageData(200, 200, 64, 1).data; let s = 0;
  for (let i = 4; i < d.length; i += 4) s += Math.abs(d[i] - d[i - 4]);
  return s / 63;
});
check("blur smooths", flat < 6, flat);

// ---- painting, undo, redo ----
await page.click("#tool-brush");
await page.$eval("#brush-color", (e) => { e.value = "#ff0000"; e.dispatchEvent(new Event("input", { bubbles: true })); });
await setRange("#brush-size", 30);
await setRange("#brush-hardness", 100);
const before = await pixel(500, 400);
await drag([[400, 400], [600, 400]]);
check("painted red", same(await pixel(500, 400), [255, 0, 0, 255]), await pixel(500, 400));
check("brush step", (await steps()).at(-1) === "Brush", await steps());
await page.click("#undo");
check("undo", same(await pixel(500, 400), before), [before, await pixel(500, 400)]);
await page.click("#redo");
check("redo", same(await pixel(500, 400), [255, 0, 0, 255]), await pixel(500, 400));
await page.click("h2, .brand");
await page.keyboard.press("Control+z");
check("Ctrl+Z", same(await pixel(500, 400), before), await pixel(500, 400));
await page.keyboard.press("Control+Shift+Z");
check("Ctrl+Shift+Z", same(await pixel(500, 400), [255, 0, 0, 255]), await pixel(500, 400));
// the history panel jumps
await page.click("#step-1");
check("history jump", same(await pixel(100, 100), p1) && (await page.$eval("#step-3", (e) => e.className)) === "future", await pixel(100, 100));
await page.click("#step-3");

// ---- layers ----
await page.click("#layer-add");
check("two layers", (await count(".layers li")) === 2);
await page.$eval("#brush-color", (e) => { e.value = "#0000ff"; e.dispatchEvent(new Event("input", { bubbles: true })); });
await drag([[300, 600], [300, 700]]);
check("painted on the new layer", same(await pixel(300, 650), [0, 0, 255, 255]), await pixel(300, 650));
const top = await page.$eval(".layers li", (e) => e.id);
await page.click(`#${top} input[type=checkbox]`);
check("hidden layer", !same(await pixel(300, 650), [0, 0, 255, 255]), await pixel(300, 650));
await page.click(`#${top} input[type=checkbox]`);
check("shown again", same(await pixel(300, 650), [0, 0, 255, 255]), await pixel(300, 650));
await page.dblclick(`#${top} .name`);
await page.fill("#rename", "Blue line");
await page.press("#rename", "Enter");
check("renamed", (await text(`#${top} .name`)) === "Blue line", await text(`#${top} .name`));
await page.click("#layer-down");
check("moved down", (await page.$$eval(".layers li", (es) => es.map((e) => e.id)))[1] === top);
await page.click("#layer-up");
await page.$eval("#layer-blend", (e) => { e.value = "multiply"; e.dispatchEvent(new Event("change", { bubbles: true })); });
check("blend mode", (await text(`#${top} .meta`)).includes("multiply"), await text(`#${top} .meta`));
await page.click("#layer-delete");
check("deleted", (await count(".layers li")) === 1);
check("layer steps", (await steps()).slice(-7).join("|") === "New layer|Brush|Visibility|Visibility|Rename layer|Layer down|Layer up|Blend mode|Delete layer".split("|").slice(-7).join("|"), await steps());

// ---- geometry and crop ----
await page.click("summary:has-text('Transform')");
await page.click("#rot-cw");
await idle();   // geometry runs as a job, over frames
check("rotated", same(await dims(), [864, 1152]), await dims());
await page.click("#undo");
check("rotation undone", same(await dims(), [1152, 864]), await dims());
await page.click("#tool-crop");
await drag([[100, 100], [400, 300]]);
check("crop box", (await count("#crop-box")) === 1);
await page.keyboard.press("Enter");
await page.waitForFunction(() => document.querySelector("#busy"), null, { timeout: 5000 }).catch(() => {});
await idle();
const cd = await dims();
check("cropped", Math.abs(cd[0] - 300) <= 2 && Math.abs(cd[1] - 200) <= 2, cd);

// ---- export: the PNG Lean encodes ----
const shown = await page.$eval("#canvas", (c) => Array.from(c.getContext("2d").getImageData(0, 0, c.width, c.height).data));
const [download] = await Promise.all([page.waitForEvent("download"), page.click("#export")]);
const png = fs.readFileSync(await download.path());
check("png signature", png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])));
check("png size", png.readUInt32BE(16) === cd[0] && png.readUInt32BE(20) === cd[1], [png.readUInt32BE(16), png.readUInt32BE(20)]);
const decoded = await page.evaluate(async (bytes) => {
  const bmp = await createImageBitmap(new Blob([new Uint8Array(bytes)], { type: "image/png" }), { premultiplyAlpha: "none", colorSpaceConversion: "none" });
  const c = new OffscreenCanvas(bmp.width, bmp.height), x = c.getContext("2d");
  x.drawImage(bmp, 0, 0);
  return Array.from(x.getImageData(0, 0, bmp.width, bmp.height).data);
}, Array.from(png));
let diff = 0; for (let i = 0; i < shown.length; i++) diff = Math.max(diff, Math.abs(shown[i] - decoded[i]));
check("png decodes to the canvas", decoded.length === shown.length && diff === 0, [decoded.length, shown.length, diff]);

// ---- open a file: input, then drop ----
const made = await page.evaluate(async () => {
  const c = document.createElement("canvas"); c.width = 300; c.height = 200;
  const x = c.getContext("2d"); x.fillStyle = "#123456"; x.fillRect(0, 0, 300, 200); x.fillStyle = "#fedcba"; x.fillRect(0, 0, 150, 100);
  const blob = await new Promise((ok) => c.toBlob(ok, "image/png"));
  return Array.from(new Uint8Array(await blob.arrayBuffer()));
});
await page.setInputFiles("#open", { name: "photo.png", mimeType: "image/png", buffer: Buffer.from(made) });
await page.waitForFunction(() => { const c = document.querySelector("#canvas"); return c && c.width === 300; }, null, { timeout: 10000 }).catch(() => {});
check("opened", same(await dims(), [300, 200]) && same(await steps(), ["Open"]), [await dims(), await steps()]);
check("opened pixels", same(await pixel(10, 10), [254, 220, 186, 255]) && same(await pixel(200, 150), [18, 52, 86, 255]), [await pixel(10, 10), await pixel(200, 150)]);
await page.evaluate((bytes) => {
  const dt = new DataTransfer();
  dt.items.add(new File([new Uint8Array(bytes)], "dropped.png", { type: "image/png" }));
  const vp = document.querySelector("#viewport");
  vp.dispatchEvent(new DragEvent("dragover", { dataTransfer: dt, bubbles: true, cancelable: true }));
  vp.dispatchEvent(new DragEvent("drop", { dataTransfer: dt, bubbles: true, cancelable: true }));
}, made);
await page.waitForFunction(() => document.querySelector("#status").textContent.startsWith("dropped"), null, { timeout: 10000 }).catch(() => {});
check("dropped", (await text("#status")).startsWith("dropped: 300×200"), await text("#status"));

// ---- keys pick tools ----
await page.click(".brand small");
await page.keyboard.press("e");
check("E picks the eraser", (await page.$eval("#tool-eraser", (e) => e.className)) === "on");
await page.keyboard.press("h");
check("H picks the hand", (await page.$eval("#tool-hand", (e) => e.className)) === "on");

const results = { engine: browser.version(), passed: checks.filter((c) => c.ok).length, failed: checks.filter((c) => !c.ok), errors,
  heapMB: await page.evaluate(() => Math.round(window.__leanui.stats.heapBytes / 1048576)) };
await browser.close();
const ok = results.failed.length === 0 && errors.length === 0;
console.log(JSON.stringify(results, null, 1));
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
