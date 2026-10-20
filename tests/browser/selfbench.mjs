// The keyed suite in *release* browsers, with no automation protocol attached: serves the pages
// and bench/runner.html, launches a browser binary headless on a throwaway profile, and waits for
// the runner to post its results. Use this for Firefox: Playwright's Firefox build runs wasm about
// 8x slower than release Firefox (docs/BENCHMARKS.md), so it cannot measure LeanUI.
//
//   node tests/browser/selfbench.mjs <browser-binary> <firefox|chromium> [--runs 7] [--only a,b]
//        [--impls leanui,vanilla,leanvir] [--leanui-dir dist/bench] [--leanvir-dir dist/vir/bench] [--json out.json]
//   e.g. node tests/browser/selfbench.mjs /Applications/Firefox.app/Contents/MacOS/firefox firefox
//
// --race life|table [--steps 1000] runs the race page instead (dist/race, bench/race/build.sh; --runs
// for the table): the release-browser counterpart of tests/browser/race.mjs, served cross-origin
// isolated as the site serves it, so its timer is precise. It prints what the page measured and
// exits 1 unless all three implementations agree.
//
// Run it under the host browser lock.
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { OPS } from "../../bench/ops.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const [bin, kind] = process.argv.slice(2);
if (!bin || !["firefox", "chromium"].includes(kind)) { console.error("usage: selfbench.mjs <browser-binary> <firefox|chromium> [options]"); process.exit(2); }
const argv = process.argv.slice(4);
const opt = (n, d) => { const i = argv.indexOf("--" + n); return i >= 0 ? argv[i + 1] : d; };
const RUNS = opt("runs", "7"), ONLY = opt("only", ""), IMPLS = opt("impls", "leanui,vanilla"), JSON_OUT = opt("json", null);
const SPIN = opt("spin", "30");   // ms of busy-waiting before each measured click (efficiency cores)
const LEANUI_DIR = opt("leanui-dir", "dist/bench").replace(/\/?$/, "/");
const LEANVIR_DIR = opt("leanvir-dir", "dist/vir/bench").replace(/\/?$/, "/");   // vir/build.sh bench
const RACE = opt("race", null);
const MOUNTS = [["/race/", "dist/race/"], ["/leanui/", LEANUI_DIR], ["/vanilla/", "bench/vanilla/"], ["/leanvir/", LEANVIR_DIR], ["/", "bench/"]];
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm", ".css": "text/css", ".json": "application/json" };

let finish;
const posted = new Promise((r) => (finish = r));
const server = http.createServer((req, res) => {
  const url = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (url === "/result" && req.method === "POST") {
    let body = ""; req.on("data", (c) => (body += c)); req.on("end", () => { res.end("ok"); finish(JSON.parse(body)); }); return;
  }
  for (const [prefix, dir] of MOUNTS) {
    if (!url.startsWith(prefix)) continue;
    const base = path.join(ROOT, dir);
    let file = path.join(base, url.slice(prefix.length) || "index.html");
    if (!file.startsWith(base) || !fs.existsSync(file)) break;
    if (fs.statSync(file).isDirectory()) file = path.join(file, "index.html");
    const isolate = prefix === "/race/" ? { "cross-origin-opener-policy": "same-origin", "cross-origin-embedder-policy": "require-corp" } : {};
    res.writeHead(200, { "content-type": TYPES[path.extname(file)] || "application/octet-stream", "cache-control": "no-store", ...isolate });
    res.end(fs.readFileSync(file)); return;
  }
  res.writeHead(404); res.end();
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const origin = `http://127.0.0.1:${server.address().port}`;
const page = RACE ? `${origin}/race/?scenario=${RACE}&auto=1&post=1&${RACE === "life" ? "steps=" + opt("steps", "1000") : "runs=" + RUNS}`
  : `${origin}/runner.html?runs=${RUNS}&impls=${IMPLS}&spin=${SPIN}${ONLY ? "&only=" + ONLY : ""}`;
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "leanui-selfbench-"));
let args;
if (kind === "firefox") {
  fs.writeFileSync(path.join(profile, "user.js"), [
    'user_pref("privacy.reduceTimerPrecision", false);', 'user_pref("browser.shell.checkDefaultBrowser", false);',
    'user_pref("datareporting.policy.dataSubmissionEnabled", false);', 'user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);',
    'user_pref("browser.aboutwelcome.enabled", false);', 'user_pref("app.update.disabledForTesting", true);',
  ].join("\n") + "\n");
  args = ["--headless", "--no-remote", "--profile", profile, "--window-size=1400,1000", page];
} else args = ["--headless=new", `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--window-size=1400,1000", page];
const child = spawn(bin, args, { stdio: "ignore" });
// an hour: lean-vir's runs alone take minutes
const timeout = setTimeout(() => { console.error("timed out"); try { process.kill(child.pid); } catch (e) {} process.exit(1); }, 60 * 60 * 1000);
const R = await posted;
clearTimeout(timeout);
// stop the browser and wait for it to exit before removing its profile
const exited = new Promise((r) => child.once("exit", r));
try { process.kill(child.pid); } catch (e) {}
await Promise.race([exited, new Promise((r) => setTimeout(r, 5000))]);
server.close();
try { fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch (e) {}

if (RACE) {
  // the race page's own result (bench/race/race.js): per implementation, or per operation
  const fmt = (ms) => (ms == null ? "–" : ms.toFixed(ms >= 100 ? 0 : 2) + " ms");
  console.log(`## race (${RACE}), ${kind}: ${R.userAgent}\n\n${R.error ? "ERROR " + R.error : R.same ? "all three agree" : "THEY DIFFER"}\n`);
  if (RACE === "life") for (const r of R.rows || []) console.log(`${r.name.padEnd(20)} ${fmt(r.ms).padStart(10)}  ${fmt(r.ms / r.clicks).padStart(9)}/click  generation ${r.gen}, ${r.pop} alive, board ${r.board}`);
  else for (const r of R.rows || []) console.log(`${r.desc.padEnd(32)} ${["vanilla", "wasm64", "vir"].map((k) => fmt(r.ms[k]).padStart(10)).join(" ")}  ${r.same ? "same" : "DIFFER"}`);
  if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(R, null, 1));
  server.closeAllConnections?.();
  process.exit(R.same ? 0 : 1);
}
const impls = IMPLS.split(",");
// each LeanUI build against vanilla, and the interpreter against the compiled build
const ratios = [["leanui", "vanilla"], ["leanvir", "vanilla"], ["leanvir", "leanui"]].filter((p) => p.every((i) => impls.includes(i)));
const lines = [`## ${kind}: ${R.userAgent}`, "", `Memory64: ${R.memory64}; median of ${R.runs} fresh page loads${R.error ? "; ERROR " + R.error : ""}`, ""];
const head = ["operation", ...impls.flatMap((i) => [`${i} layout`, `${i} script`]), ...ratios.map(([a, b]) => `${a}/${b} (layout)`)];
lines.push("| " + head.join(" | ") + " |", "|" + head.map(() => "---").join("|") + "|");
for (const op of OPS) {
  const c = R.cpu[op.name]; if (!c) continue;
  const cells = [op.desc, ...impls.flatMap((i) => c[i] ? [`${c[i].layout.toFixed(2)} ms`, `${c[i].script.toFixed(2)} ms`] : ["–", "–"]),
    ...ratios.map(([a, b]) => c[a] && c[b] ? `${(c[a].layout / c[b].layout).toFixed(2)}×` : "–")];
  lines.push("| " + cells.join(" | ") + " |");
}
lines.push("", "| startup | " + impls.join(" | ") + " |", "|---|" + impls.map(() => "---").join("|") + "|",
  "| ready (ms after navigation) | " + impls.map((i) => R.startup[i]?.readyMs ?? "–").join(" | ") + " |");
console.log(lines.join("\n"));
if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(R, null, 1));
server.closeAllConnections?.();   // keep-alive sockets would keep the process alive
process.exit(0);
