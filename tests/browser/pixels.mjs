// Browser test for the pixels lab (examples/Pixels.lean): PUT_IMAGE from wasm memory, pointer
// payloads with capture, the wheel, files from an input and from a drop (bytes and decoded
// pixels into Lean), DOWNLOAD, and Sub.keys.
// node tests/browser/pixels.mjs <url of dist/pixels/index.html> [chromium|firefox]
import { pw } from "./playwright.mjs";
import fs from "node:fs";

const url = process.argv[2] || "http://127.0.0.1:5331/pixels/index.html";
const engine = process.argv[3] || "chromium";
const browser = await pw[engine].launch({ headless: true });
const page = await browser.newPage({ acceptDownloads: true });
const errors = [], checks = [];
page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
page.on("console", (m) => { if (m.type() === "error" || (m.type() === "warning" && m.text().includes("LeanUI"))) errors.push("console: " + m.text()); });
const check = (name, ok, detail = "") => { checks.push({ name, ok: !!ok, detail: ok ? undefined : detail }); };
const text = (id) => page.$eval("#" + id, (e) => e.textContent);
const pixel = (sel, x, y) => page.$eval(sel, (c, [x, y]) => Array.from(c.getContext("2d").getImageData(x, y, 1, 1).data), [x, y]);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

await page.goto(url);
await page.waitForFunction(() => window.__leanui, null, { timeout: 30000 });

// the gradient, drawn from wasm memory by the init buffer
check("gradient top-left", same(await pixel("#px-canvas", 0, 0), [0, 0, 128, 255]), await pixel("#px-canvas", 0, 0));
check("gradient bottom-right", same(await pixel("#px-canvas", 255, 127), [255, 255, 128, 255]), await pixel("#px-canvas", 255, 127));
check("gradient middle", same(await pixel("#px-canvas", 128, 64), [128, 128, 128, 255]), await pixel("#px-canvas", 128, 64));

// pointer: the canvas is 256×128 pixels shown at 512×256 CSS pixels; the pointer aims at the
// middle of a canvas pixel (odd CSS offsets), since the canvas may sit at a fractional position
const box = await page.$eval("#px-canvas", (c) => { const r = c.getBoundingClientRect(); return { x: r.left, y: r.top }; });
await page.mouse.move(box.x + 101, box.y + 51);
check("hover", (await text("px-pointer")) === "50,25 buttons 0", await text("px-pointer"));
check("hover paints nothing", (await text("px-dabs")) === "0");
await page.mouse.down();
check("pointerdown paints", (await text("px-dabs")) === "1" && (await text("px-capturing")) === "true", await text("px-dabs"));
check("painted pixel", same(await pixel("#px-canvas", 50, 25), [0, 0, 0, 255]), await pixel("#px-canvas", 50, 25));
check("unpainted neighbour", same(await pixel("#px-canvas", 54, 25), [cv(54, 256), cv(25, 128), 128, 255]), await pixel("#px-canvas", 54, 25));
function cv(v, n) { return Math.floor(v * 255 / (n - 1)); }
await page.mouse.move(box.x + 141, box.y + 61, { steps: 4 });
const dabs = +(await text("px-dabs"));
check("moves paint", dabs >= 3, dabs);
check("dragged pixel", same(await pixel("#px-canvas", 70, 30), [0, 0, 0, 255]), await pixel("#px-canvas", 70, 30));
// captured: the canvas keeps getting moves far outside it while the button is down
await page.mouse.move(box.x + 101, box.y + 401, { steps: 2 });
check("captured move", (await text("px-pointer")).startsWith("50,200 buttons 1"), await text("px-pointer"));
await page.mouse.up();
check("released", (await text("px-capturing")) === "false");
// the wheel
await page.mouse.move(box.x + 10, box.y + 10);
await page.mouse.wheel(0, 120);
await page.waitForFunction(() => document.querySelector("#px-wheel").textContent !== "0", null, { timeout: 5000 }).catch(() => {});
check("wheel", +(await text("px-wheel")) > 0, await text("px-wheel"));
// the wheel listener is not passive: its preventDefault takes effect
check("wheel default prevented", !(await page.$eval("#px-canvas", (c) => c.dispatchEvent(new WheelEvent("wheel", { deltaY: 10, bubbles: true, cancelable: true })))));

// a file from the input: a 3×2 PNG made by the browser
const png = Buffer.from(await page.evaluate(async () => {
  const c = document.createElement("canvas"); c.width = 3; c.height = 2;
  const ctx = c.getContext("2d");
  const colors = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [0, 255, 255], [10, 20, 30]];
  colors.forEach(([r, g, b], i) => { ctx.fillStyle = `rgb(${r},${g},${b})`; ctx.fillRect(i % 3, Math.floor(i / 3), 1, 1); });
  const blob = await new Promise((ok) => c.toBlob(ok, "image/png"));
  return Array.from(new Uint8Array(await blob.arrayBuffer()));
}));
await page.setInputFiles("#px-file", { name: "dot.png", mimeType: "image/png", buffer: png });
// the bytes and the pixels are two effects that finish in either order: wait for both
await page.waitForFunction(() => document.querySelector("#px-decoded").textContent !== "" && document.querySelector("#px-bytes").textContent !== "", null, { timeout: 10000 }).catch(() => {});
check("files", (await text("px-files")) === `dot.png (${png.length} bytes, image/png)`, await text("px-files"));
check("bytes", (await text("px-bytes")) === `dot.png: ${png.length} bytes: 89 50 4e 47 0d 0a 1a 0a`, await text("px-bytes"));
check("decoded", (await text("px-decoded")) === "3×2", await text("px-decoded"));
const decoded = [];
for (let y = 0; y < 2; y++) for (let x = 0; x < 3; x++) decoded.push((await pixel("#px-image", x, y)).slice(0, 3));
check("decoded pixels", same(decoded, [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [0, 255, 255], [10, 20, 30]]), JSON.stringify(decoded));

// a dropped file that is not an image: bytes, and the decoder's error
const prevented = await page.evaluate(() => {
  const dt = new DataTransfer();
  dt.items.add(new File([new Uint8Array([1, 2, 3, 0, 255])], "junk.bin", { type: "application/octet-stream" }));
  const zone = document.querySelector("#px-drop");
  const over = new DragEvent("dragover", { dataTransfer: dt, bubbles: true, cancelable: true });
  zone.dispatchEvent(over);
  const drop = new DragEvent("drop", { dataTransfer: dt, bubbles: true, cancelable: true });
  zone.dispatchEvent(drop);
  return [over.defaultPrevented, drop.defaultPrevented];
});
check("drag over and drop prevented", same(prevented, [true, true]), prevented);
await page.waitForFunction(() => document.querySelector("#px-bytes").textContent.startsWith("junk"), null, { timeout: 10000 }).catch(() => {});
check("dropped bytes", (await text("px-bytes")) === "junk.bin: 5 bytes: 01 02 03 00 ff", await text("px-bytes"));
await page.waitForFunction(() => document.querySelector("#px-decoded").textContent !== "", null, { timeout: 10000 }).catch(() => {});
check("undecodable", (await text("px-decoded")).length > 0 && !(await text("px-decoded")).includes("×"), await text("px-decoded"));

// the download: the canvas's raw pixels, as painted
const [download] = await Promise.all([page.waitForEvent("download"), page.click("#px-download")]);
const raw = fs.readFileSync(await download.path());
check("download name", download.suggestedFilename() === "pixels.rgba", download.suggestedFilename());
check("download size", raw.length === 256 * 128 * 4, raw.length);
const at = (x, y) => Array.from(raw.subarray(4 * (y * 256 + x), 4 * (y * 256 + x) + 4));
check("download content", same(at(0, 0), [0, 0, 128, 255]) && same(at(50, 25), [0, 0, 0, 255]), JSON.stringify([at(0, 0), at(50, 25)]));

// keys: reported from the page, not from text fields
await page.click("h1");
await page.keyboard.press("Control+z");
await page.keyboard.press("Shift+KeyE");
await page.focus("#px-file");
await page.keyboard.press("w");
await page.evaluate(() => { const t = document.createElement("input"); t.id = "px-text"; document.body.appendChild(t); });
await page.focus("#px-text");
await page.keyboard.press("q");
await page.click("h1");
await page.keyboard.press("x");
check("keys", (await text("px-keys")) === "Ctrl+z Shift+E w x", await text("px-keys"));

const results = { engine: browser.version(), failed: checks.filter((c) => !c.ok), passed: checks.filter((c) => c.ok).length, errors };
await browser.close();
const ok = results.failed.length === 0 && errors.length === 0;
console.log(JSON.stringify(results, null, 1));
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
