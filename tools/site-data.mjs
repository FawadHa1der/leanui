// Writes examples/site/benchmarks.json (what the site's benchmarks page shows) from benchmark runs:
//   node tools/site-data.mjs --chromium <bench.mjs --json output> [--release <name>=<selfbench --json output>]...
//        [--native <leanui-perf output text>] [--machine "Apple M4 Max"] [--out examples/site/benchmarks.json]
import fs from "node:fs";
import { OPS } from "../bench/ops.mjs";
const argv = process.argv.slice(2);
const all = (n) => argv.flatMap((a, i) => (a === "--" + n ? [argv[i + 1]] : []));
const one = (n, d) => all(n)[0] ?? d;
const chromium = JSON.parse(fs.readFileSync(one("chromium"), "utf8")).engines.chromium;
const ops = OPS.map((o) => ({ name: o.name, desc: o.desc, leanui: chromium.cpu[o.name].leanui.total, vanilla: chromium.cpu[o.name].vanilla.total }));
const release = all("release").map((spec) => {
  const [browser, file] = spec.split("=");
  const r = JSON.parse(fs.readFileSync(file, "utf8"));
  return { browser, ratios: OPS.map((o) => { const c = r.cpu[o.name]; return c ? +(c.leanui.layout / c.vanilla.layout).toFixed(3) : 0; }) };
});
let native = [];
const nat = one("native");
if (nat) {
  const text = fs.readFileSync(nat, "utf8").split("\n");
  // the first table (lazy rows): "  create1k     1.843208 ms  (122000 words)"
  const start = text.findIndex((l) => l.includes("lazy rows"));
  const rows = new Map();
  for (const l of text.slice(start + 1)) { const m = l.match(/^\s+(\w+)\s+([\d.]+) ms/); if (!m) break; rows.set(m[1], +(+m[2]).toFixed(3)); }
  native = OPS.map((o) => rows.get(o.name) ?? 0);
}
const out = { machine: one("machine", "an Apple-silicon Mac"), chromium: `Chromium ${chromium.version.split(".")[0]}`, ops, release, native };
fs.writeFileSync(one("out", "examples/site/benchmarks.json"), JSON.stringify(out, null, 1) + "\n");
console.log(`wrote ${one("out", "examples/site/benchmarks.json")}: ${ops.length} operations, ${release.length} release browsers, native ${native.length ? "yes" : "no"}`);
