// Markdown tables for docs/BENCHMARKS.md from the harnesses' JSON:
//   node tools/bench-tables.mjs <bench.mjs json> [<selfbench firefox json> <selfbench chrome json> [<leanui-perf output>]]
// Columns for every implementation a run measured (leanui, vanilla, leanvir); the sections whose
// input is not given are left out.
import fs from "node:fs";
import { OPS } from "../bench/ops.mjs";
const readme = process.argv[2] === "--readme";
const [cj, fj, gj, nt] = process.argv.slice(readme ? 3 : 2);
const C = JSON.parse(fs.readFileSync(cj, "utf8")).engines.chromium;
const F = fj && JSON.parse(fs.readFileSync(fj, "utf8"));
const G = gj && JSON.parse(fs.readFileSync(gj, "utf8"));
const f2 = (x) => x.toFixed(2);
const ver = (ua, name) => (ua.match(new RegExp(name + "/(\\d+)")) || [])[1];
const gm = (xs) => Math.exp(xs.reduce((a, r) => a + Math.log(r), 0) / xs.length);
const NAME = { leanui: "LeanUI", vanilla: "vanilla", leanvir: "lean-vir" };
// the implementations a result measured, in this order
const implsOf = (cpu) => Object.keys(NAME).filter((i) => Object.values(cpu).some((c) => c[i]));
// each LeanUI build against vanilla, and the interpreter against the compiled build
const ratiosOf = (impls) => [["leanui", "vanilla"], ["leanvir", "vanilla"], ["leanvir", "leanui"]].filter((p) => p.every((i) => impls.includes(i)));
// geometric means: "**1.23×**" for one ratio, "**1.23×** (LeanUI ÷ vanilla), **45.60×** (lean-vir ÷ vanilla)" for several
const means = (ratios, perOp) => ratios.map(([a, b]) => `**${f2(gm(perOp(a, b)))}×**` + (ratios.length > 1 ? ` (${NAME[a]} ÷ ${NAME[b]})` : "")).join(", ");
// a table row; an empty cell stays "| |"
const tr = (cells) => "|" + cells.map((c) => (c === "" ? " |" : ` ${c} |`)).join("");
if (readme) {
  // the README's summary: LeanUI ÷ vanilla per operation in each browser
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
const impls = implsOf(C.cpu), ratios = ratiosOf(impls);
out.push(`### Chromium ${C.version.split(".")[0]}, traced: CPU time per click (median of ${JSON.parse(fs.readFileSync(cj, "utf8")).runs} fresh loads)`, "",
  tr(["operation", ...impls.flatMap((i) => [`${NAME[i]} total`, "script", "render"]), ...ratios.map(([a, b]) => `${NAME[a]} ÷ ${NAME[b]}`)]),
  "|---|" + "--:|".repeat(3 * impls.length + ratios.length));
for (const o of OPS) {
  const c = C.cpu[o.name];
  out.push(tr([o.desc, ...impls.flatMap((i) => [`${f2(c[i].total)} ms`, f2(c[i].script), f2(c[i].render)]),
    ...ratios.map(([a, b]) => `**${f2(c[a].total / c[b].total)}×**`)]));
}
out.push("", `Geometric mean of the ratios: ${means(ratios, (a, b) => OPS.map((o) => C.cpu[o.name][a].total / C.cpu[o.name][b].total))}.`, "");
for (const [R, name] of [[F, "Firefox"], [G, "Chrome"]]) {
  if (!R) continue;
  const v = ver(R.userAgent, name === "Firefox" ? "Firefox" : "Chrome");
  const ri = implsOf(R.cpu), rr = ratiosOf(ri), ops = OPS.filter((o) => R.cpu[o.name]);
  out.push(`### ${name} ${v} (release, no automation): script and layout per click (median of ${R.runs} fresh loads)`, "",
    tr(["operation", ...ri.flatMap((i) => [`${NAME[i]} layout`, "script"]), ...rr.map(([a, b]) => `${NAME[a]} ÷ ${NAME[b]}`)]),
    "|---|" + "--:|".repeat(2 * ri.length + rr.length));
  for (const o of ops) {
    const c = R.cpu[o.name];
    out.push(tr([o.desc, ...ri.flatMap((i) => [`${f2(c[i].layout)} ms`, f2(c[i].script)]), ...rr.map(([a, b]) => `**${f2(c[a].layout / c[b].layout)}×**`)]));
  }
  out.push("", `Geometric mean: ${means(rr, (a, b) => ops.map((o) => R.cpu[o.name][a].layout / R.cpu[o.name][b].layout))}. ` +
    `Ready after navigation: ${ri.map((i) => `${NAME[i]} ${R.startup[i]?.readyMs} ms`).join(", ")}.`, "");
}
// memory per implementation: its JS heap, and its wasm memory where the page can tell (lean-vir's
// runtime does not expose it, so its ArrayBuffer backing stores, the wasm memory included, stand in)
const MEM = { leanui: [["JS heap", "jsHeapMB"], ["wasm memory", "wasmMB"]], vanilla: [["JS heap", "jsHeapMB"]], leanvir: [["JS heap", "jsHeapMB"], ["array buffers", "buffersMB"]] };
out.push("### Memory (Chromium, after a full GC)", "", tr(["after", ...impls.flatMap((i) => MEM[i].map(([h]) => `${NAME[i]} ${h}`)), "DOM nodes"]),
  "|---|" + "--:|".repeat(impls.reduce((n, i) => n + MEM[i].length, 1)));
const names = { ready: "load", run1k: "creating 1,000 rows", update5: "5 updates of every 10th row", runClear5: "5 create/clear cycles", run10k: "creating 10,000 rows" };
for (const k of Object.keys(names)) out.push(tr([names[k], ...impls.flatMap((i) => MEM[i].map(([, f]) => `${C.memory[i][k][f]} MB`)), C.memory[impls[0]][k].domNodes]));
const S = C.startup;
out.push("", "### Startup and size (Chromium)", "", tr(["", ...impls.map((i) => NAME[i])]), "|---|" + "--:|".repeat(impls.length),
  tr(["ready after navigation", ...impls.map((i) => `${S[i].readyMs} ms`)]),
  tr(["of which wasm instantiation + Lean init + first render", ...impls.map((i) => (S[i].bootMs ? `${S[i].bootMs} ms` : ""))]),
  tr(["transferred (uncompressed)", ...impls.map((i) => `${S[i].transferKB} KB`)]),
  tr(["brotli", ...impls.map((i) => `${S[i].brotliKB} KB`)]), "");
// native
if (nt) {
  const text = fs.readFileSync(nt, "utf8").split("\n");
  const table = (label) => { const i = text.findIndex((l) => l.includes(label)); const m = new Map(); for (const l of text.slice(i + 1)) { const r = l.match(/^\s+(\w+)\s+([\d.]+) ms\s+\((\d+) words\)/); if (!r) break; m.set(r[1], [+r[2], +r[3]]); } return m; };
  const lazy = table("lazy rows"), eager = table("eager rows");
  out.push("### Native Lean (update, view, diff, encoding; no DOM)", "", "| operation | lazy rows | eager rows | command words |", "|---|--:|--:|--:|");
  for (const o of OPS) { const a = lazy.get(o.name), b = eager.get(o.name); if (a && b) out.push(`| ${o.desc} | ${f2(a[0])} ms | ${f2(b[0])} ms | ${a[1]} |`); }
}
console.log(out.join("\n"));
