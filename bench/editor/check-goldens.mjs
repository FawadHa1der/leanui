// Checks bench/editor/ops.js against the golden checksums of tests/Editor.lean (computed by the
// Lean core natively, and all but the compressed PNG files also by tests/editor-ref/reference.py):
// the same operations on the same generated images must give the same bytes. Also checks that
// ops.js implements exactly the operations of examples/EditorBench.lean.
//   node bench/editor/check-goldens.mjs
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../..");
const E = createRequire(import.meta.url)("./ops.js");

// ---- the generated images of tests/Editor.lean ----
const lcg = (s) => (Math.imul(s, 1103515245) + 12345) >>> 0;
function noise(w, h, seed, alpha = true) {
  const d = new Uint8ClampedArray(4 * w * h);
  let s = seed >>> 0;
  for (let i = 0; i < w * h; i++) {
    const s1 = lcg(s), s2 = lcg(s1), s3 = lcg(s2), s4 = lcg(s3);
    const a0 = s4 >>> 24;
    d[4 * i] = s1 >>> 24; d[4 * i + 1] = s2 >>> 24; d[4 * i + 2] = s3 >>> 24;
    d[4 * i + 3] = !alpha ? 255 : a0 < 64 ? 0 : a0 > 160 ? 255 : a0;
    s = s4;
  }
  return E.image(w, h, d);
}
function generate(w, h, f) {
  const img = E.image(w, h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) img.data.set(f(x, y), 4 * (y * w + x));
  return img;
}
const gradient = (w, h) => generate(w, h, (x, y) =>
  [Math.floor(x * 255 / Math.max(1, w - 1)), Math.floor(y * 255 / Math.max(1, h - 1)), ((x + y) * 4) % 256, 255]);
const checker = (w, h, k) => generate(w, h, (x, y) =>
  (Math.floor(x / k) + Math.floor(y / k)) % 2 === 0 ? [240, 240, 240, 255] : [20, 40, 60, 255]);

const base = noise(37, 23, 7), top = noise(37, 23, 11), opaqueBase = noise(37, 23, 5, false);
const A = E.adjust;
const adjustments = [
  ["brightness +30", A({ brightness: 30 })], ["brightness -45", A({ brightness: -45 })],
  ["contrast +40", A({ contrast: 40 })], ["contrast -60", A({ contrast: -60 })],
  ["exposure +1", A({ exposure: 1 })], ["exposure -1.5", A({ exposure: -1.5 })],
  ["saturation +50", A({ saturation: 50 })], ["saturation -100", A({ saturation: -100 })],
  ["hue +90", A({ hue: 90 })], ["hue -150", A({ hue: -150 })],
  ["levels 20 230 1.5", A({ inBlack: 20, inWhite: 230, gamma: 1.5 })], ["curve", A({ curve: [[64, 40], [192, 220]] })],
  ["invert", A({ invert: true })], ["grayscale", A({ grayscale: true })],
  ["everything", A({ brightness: 10, contrast: 20, exposure: 0.5, saturation: 30, hue: 45, inBlack: 5, inWhite: 250,
    gamma: 0.8, curve: [[128, 150]], invert: true })]];

const got = new Map();
const g = (name, v) => got.set(name, v);
g("base", E.checksum(base)); g("top", E.checksum(top)); g("opaque base", E.checksum(opaqueBase));
for (const [n, a] of adjustments) g(`adjust ${n}`, E.checksum(E.adjustApply(a, base)));
const hist = E.histogram(base), hb = new Uint8Array(2 * hist.length);
hist.forEach((n, i) => { hb[2 * i] = n & 255; hb[2 * i + 1] = (n >>> 8) & 255; });
g("histogram", E.fnvBytes(hb));
g("blur 2", E.checksum(E.blur(base, 2)));
g("blur 5.5", E.checksum(E.blur(base, 5.5)));
g("blur 1 opaque", E.checksum(E.blur(opaqueBase, 1)));
g("sharpen 1.5 2 4", E.checksum(E.sharpen(base, 1.5, 2, 4)));
g("emboss", E.checksum(E.emboss(base)));
g("edges", E.checksum(E.edgeDetect(base)));
g("convolve sharpen", E.checksum(E.convolve(E.KERNELS.sharpen, base)));
g("convolve box", E.checksum(E.convolve(E.KERNELS.boxBlur, base)));
g("crop", E.checksum(E.crop(base, 5, 3, 20, 11)));
g("rotate90cw", E.checksum(E.rotate90cw(base)));
g("rotate90ccw", E.checksum(E.rotate90ccw(base)));
g("rotate180", E.checksum(E.rotate180(base)));
g("flipH", E.checksum(E.flipH(base)));
g("flipV", E.checksum(E.flipV(base)));
g("resize 50x31", E.checksum(E.resize(base, 50, 31)));
g("resize 19x12", E.checksum(E.resize(base, 19, 12)));
g("resize opaque 61x9", E.checksum(E.resize(opaqueBase, 61, 9)));
g("downscaleBox 9x6", E.checksum(E.downscaleBox(base, 9, 6)));
g("downscaleBox opaque 10x7", E.checksum(E.downscaleBox(opaqueBase, 10, 7)));
for (const m of E.BLENDS) g(`composite ${m} 70`, E.checksum(E.composite(base, top, 70, m)));
g("composite normal 100 opaque", E.checksum(E.composite(base, opaqueBase, 100, "normal")));
g("png level 0", E.fnvBytes(E.pngEncode(base, 0)));
g("png level 1 base", E.fnvBytes(E.pngEncode(base, 1)));
g("png level 1 gradient", E.fnvBytes(E.pngEncode(gradient(61, 37), 1)));
g("png level 9 gradient", E.fnvBytes(E.pngEncode(gradient(61, 37), 9)));
g("png level 4 checker", E.fnvBytes(E.pngEncode(checker(64, 48, 8), 4)));

// ---- compare with the pinned goldens ----
const src = fs.readFileSync(path.join(repo, "tests/Editor.lean"), "utf8");
const start = src.indexOf("def goldens"), block = src.slice(start, src.indexOf(")]", start) + 2);
const pinned = new Map([...block.matchAll(/\("([^"]+)", (\d+)\)/g)].map((m) => [m[1], m[2]]));
let ok = 0, bad = 0, skipped = [];
for (const [name, want] of pinned) {
  if (!got.has(name)) { skipped.push(name); continue; }
  if (got.get(name) === want) ok++;
  else { bad++; console.log(`DIFF ${name}: js ${got.get(name)}, lean ${want}`); }
}
for (const name of got.keys()) if (!pinned.has(name)) { bad++; console.log(`no golden for ${name}`); }

// ---- the PNG files decode (zlib) to the pixels, at a size where the stored blocks split ----
let pngOk = 0;
for (const [img, level] of [[noise(301, 203, 3), 0], [noise(301, 203, 3), 1], [E.testImage(333, 250), 1], [E.testImage(333, 250), 6]]) {
  const png = E.pngEncode(img, level);
  const idatLen = (png[33] << 24) | (png[34] << 16) | (png[35] << 8) | png[36];
  const raw = zlib.inflateSync(png.subarray(41, 41 + idatLen));
  // undo the filters
  const rb = 4 * img.width, px = new Uint8Array(img.data.length);
  for (let y = 0; y < img.height; y++) {
    const ft = raw[y * (rb + 1)];
    for (let i = 0; i < rb; i++) {
      const x = raw[y * (rb + 1) + 1 + i], a = i >= 4 ? px[y * rb + i - 4] : 0, b = y > 0 ? px[(y - 1) * rb + i] : 0;
      const c = y > 0 && i >= 4 ? px[(y - 1) * rb + i - 4] : 0;
      const pa = Math.abs(b - c), pb = Math.abs(a - c), pc = Math.abs(a + b - 2 * c);
      const pred = ft === 0 ? 0 : ft === 1 ? a : ft === 2 ? b : ft === 4 ? (pa <= pb && pa <= pc ? a : pb <= pc ? b : c) : NaN;
      px[y * rb + i] = (x + pred) & 255;
    }
  }
  if (Buffer.compare(Buffer.from(px), Buffer.from(img.data)) === 0) pngOk++;
  else { bad++; console.log(`DIFF png round trip ${img.width}x${img.height} level ${level}`); }
}

// ---- the operation list matches examples/EditorBench.lean ----
const benchSrc = fs.readFileSync(path.join(repo, "examples/EditorBench.lean"), "utf8");
const leanOps = [...benchSrc.match(/def ops : List String :=\s*\[([^\]]*)\]/)[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
if (JSON.stringify(leanOps) !== JSON.stringify(E.OPS)) { bad++; console.log("ops differ:", leanOps, E.OPS); }

console.log(`${ok} of ${pinned.size} goldens match` + (skipped.length ? ` (not ported: ${skipped.join(", ")})` : "") +
  `; ${pngOk} PNG round trips through zlib; ${E.OPS.length} operations as in EditorBench.ops`);
process.exit(bad ? 1 : 0);
