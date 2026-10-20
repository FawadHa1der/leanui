// The photo editor's operations in MPix/s (input megapixels per second, from the median time) as
// markdown tables, from the JSON that tests/browser/editor-bench.mjs writes: one table per file, a
// row per operation, a column per size, each cell "Lean · JS · canvas built-in" ("–" where there
// is no built-in, or the median is under the timer's resolution), and the geometric mean of
// Lean ÷ JS time per size.
//   node bench/editor/mpix-table.mjs bench/editor/results-chromium.json [more.json ...]
import fs from "node:fs";

const LABELS = {
  "adjust-lut": "brightness, contrast, gamma (lookup table)", "adjust-color": "saturation and hue (colour matrix)",
  "blur-2": "Gaussian blur, radius 2", "blur-8": "Gaussian blur, radius 8", sharpen: "unsharp mask",
  emboss: "emboss (3×3)", edges: "edges (Sobel)", "rotate-90": "rotate 90°", "rotate-180": "rotate 180°",
  "flip-h": "flip horizontally", "flip-v": "flip vertically", "resize-50": "resize to 50% (bilinear)",
  "downscale-8": "downscale to 1/8 (box)", "composite-normal": "composite, normal at 60%",
  "composite-overlay": "composite, overlay at 60%", histogram: "histogram", "png-stored": "PNG, stored",
  "png-1": "PNG, level 1 (filters, LZ77, fixed Huffman)", "crop-half": "crop", blit: "show on a canvas (`putImageData`)",
};
const median = (xs) => { const s = [...xs].sort((a, b) => a - b), n = s.length; return n === 0 ? NaN : n % 2 ? s[n >> 1] : (s[n / 2 - 1] + s[n / 2]) / 2; };
const mps = (px, t) => { if (!(t > 0)) return "–"; const v = px / 1e6 / (t / 1000); return v >= 100 ? v.toFixed(0) : v.toFixed(1); };

for (const file of process.argv.slice(2)) {
  const r = JSON.parse(fs.readFileSync(file, "utf8"));
  const rows = new Map();
  const geo = [];
  for (const s of r.sizes) {
    let logSum = 0, n = 0;
    for (const o of [...s.ops, { op: "blit", ...s.blit }]) {
      const l = median(o.lean), j = median(o.js), c = o.canvas ? median(o.canvas) : null;
      if (!rows.has(o.op)) rows.set(o.op, []);
      rows.get(o.op).push(`${mps(s.pixels, l)} · ${mps(s.pixels, j)} · ${c == null ? "–" : mps(s.pixels, c)}`);
      if (o.op !== "blit" && l > 0 && j > 0) { logSum += Math.log(l / j); n++; }
    }
    geo.push(`${Math.exp(logSum / n).toFixed(2)}× (${n} operations)`);
  }
  console.log(`**${r.engine} ${r.browserVersion}**${r.commit ? `, commit ${r.commit}` : ""}, median of ${r.runs} runs (fewer for slow operations; \`${file}\`):\n`);
  console.log(`| MPix/s: Lean · JS · canvas | ${r.sizes.map((s) => `${s.label} (${s.w}×${s.h})`).join(" | ")} |`);
  console.log(`|---|${r.sizes.map(() => "--:").join("|")}|`);
  for (const [op, cells] of rows) console.log(`| ${LABELS[op] || op} | ${cells.join(" | ")} |`);
  console.log(`| *Lean ÷ JS time, geometric mean* | ${geo.join(" | ")} |\n`);
}
