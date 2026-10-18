// Markdown tables for docs/BENCHMARKS.md from the harnesses' JSON:
//   node tools/bench-tables.mjs <bench.mjs json> <selfbench firefox json> <selfbench chrome json> <leanui-perf output>
import fs from "node:fs";
import { OPS } from "../bench/ops.mjs";
const readme = process.argv[2] === "--readme";
const [cj, fj, gj, nt] = process.argv.slice(readme ? 3 : 2);
const C = JSON.parse(fs.readFileSync(cj, "utf8")).engines.chromium;
const F = JSON.parse(fs.readFileSync(fj, "utf8"));
const G = JSON.parse(fs.readFileSync(gj, "utf8"));
const f2 = (x) => x.toFixed(2);
const ver = (ua, name) => (ua.match(new RegExp(name + "/(\\d+)")) || [])[1];
if (readme) {
  // the README's summary: LeanUI ÷ vanilla per operation in each browser
  const gm = (xs) => Math.exp(xs.reduce((a, r) => a + Math.log(r), 0) / xs.length);
  const cols = [[`Chromium ${C.version.split(".")[0]} (script + render)`, (o) => C.cpu[o].leanui.total / C.cpu[o].vanilla.total],
    [`Chrome ${ver(G.userAgent, "Chrome")} (script + layout)`, (o) => G.cpu[o].leanui.layout / G.cpu[o].vanilla.layout],
    [`Firefox ${ver(F.userAgent, "Firefox")} (script + layout)`, (o) => F.cpu[o].leanui.layout / F.cpu[o].vanilla.layout]];
  const lines = ["| operation | " + cols.map((c) => c[0]).join(" | ") + " |", "|---|" + cols.map(() => "--:").join("|") + "|"];
  for (const o of OPS) lines.push(`| ${o.desc} | ` + cols.map((c) => f2(c[1](o.name)) + "×").join(" | ") + " |");
  lines.push("| **geometric mean** | " + cols.map((c) => "**" + f2(gm(OPS.map((o) => c[1](o.name)))) + "×**").join(" | ") + " |");
  console.log(lines.join("\n"));
  process.exit(0);
}
const out = [];
out.push(`### Chromium ${C.version.split(".")[0]}, traced: CPU time per click (median of ${JSON.parse(fs.readFileSync(cj, "utf8")).runs} fresh loads)`, "",
  "| operation | LeanUI total | script | render | vanilla total | script | render | LeanUI ÷ vanilla |", "|---|--:|--:|--:|--:|--:|--:|--:|");
const ratios = [];
for (const o of OPS) {
  const l = C.cpu[o.name].leanui, v = C.cpu[o.name].vanilla;
  ratios.push(l.total / v.total);
  out.push(`| ${o.desc} | ${f2(l.total)} ms | ${f2(l.script)} | ${f2(l.render)} | ${f2(v.total)} ms | ${f2(v.script)} | ${f2(v.render)} | **${f2(l.total / v.total)}×** |`);
}
const geo = Math.exp(ratios.reduce((a, r) => a + Math.log(r), 0) / ratios.length);
out.push("", `Geometric mean of the ratios: **${f2(geo)}×**.`, "");
for (const [R, name] of [[F, "Firefox"], [G, "Chrome"]]) {
  const v = ver(R.userAgent, name === "Firefox" ? "Firefox" : "Chrome");
  out.push(`### ${name} ${v} (release, no automation): script and layout per click (median of ${R.runs} fresh loads)`, "",
    "| operation | LeanUI layout | script | vanilla layout | script | LeanUI ÷ vanilla |", "|---|--:|--:|--:|--:|--:|");
  const rs = [];
  for (const o of OPS) {
    const c = R.cpu[o.name]; if (!c) continue;
    rs.push(c.leanui.layout / c.vanilla.layout);
    out.push(`| ${o.desc} | ${f2(c.leanui.layout)} ms | ${f2(c.leanui.script)} | ${f2(c.vanilla.layout)} ms | ${f2(c.vanilla.script)} | **${f2(c.leanui.layout / c.vanilla.layout)}×** |`);
  }
  const g = Math.exp(rs.reduce((a, r) => a + Math.log(r), 0) / rs.length);
  out.push("", `Geometric mean: **${f2(g)}×**. Ready after navigation: LeanUI ${R.startup.leanui?.readyMs} ms, vanilla ${R.startup.vanilla?.readyMs} ms.`, "");
}
out.push("### Memory (Chromium, after a full GC)", "", "| after | LeanUI JS heap | LeanUI wasm memory | vanilla JS heap | DOM nodes |", "|---|--:|--:|--:|--:|");
const names = { ready: "load", run1k: "creating 1,000 rows", update5: "5 updates of every 10th row", runClear5: "5 create/clear cycles", run10k: "creating 10,000 rows" };
for (const k of Object.keys(names)) {
  const l = C.memory.leanui[k], v = C.memory.vanilla[k];
  out.push(`| ${names[k]} | ${l.jsHeapMB} MB | ${l.wasmMB} MB | ${v.jsHeapMB} MB | ${l.domNodes} |`);
}
out.push("", "### Startup and size (Chromium)", "", "| | LeanUI | vanilla |", "|---|--:|--:|",
  `| ready after navigation | ${C.startup.leanui.readyMs} ms | ${C.startup.vanilla.readyMs} ms |`,
  `| of which wasm instantiation + Lean init + first render | ${C.startup.leanui.bootMs} ms | |`,
  `| transferred (uncompressed) | ${C.startup.leanui.transferKB} KB | ${C.startup.vanilla.transferKB} KB |`,
  `| brotli | ${C.startup.leanui.brotliKB} KB | ${C.startup.vanilla.brotliKB} KB |`, "");
// native
const text = fs.readFileSync(nt, "utf8").split("\n");
const table = (label) => { const i = text.findIndex((l) => l.includes(label)); const m = new Map(); for (const l of text.slice(i + 1)) { const r = l.match(/^\s+(\w+)\s+([\d.]+) ms\s+\((\d+) words\)/); if (!r) break; m.set(r[1], [+r[2], +r[3]]); } return m; };
const lazy = table("lazy rows"), eager = table("eager rows");
out.push("### Native Lean (update, view, diff, encoding; no DOM)", "", "| operation | lazy rows | eager rows | command words |", "|---|--:|--:|--:|");
for (const o of OPS) { const a = lazy.get(o.name), b = eager.get(o.name); if (a && b) out.push(`| ${o.desc} | ${f2(a[0])} ms | ${f2(b[0])} ms | ${a[1]} |`); }
console.log(out.join("\n"));
