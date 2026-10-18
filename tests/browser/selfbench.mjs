// The keyed suite in *release* browsers, with no automation protocol attached: serves the pages
// and bench/runner.html, launches a browser binary headless on a throwaway profile, and waits for
// the runner to post its results. Use this for Firefox: Playwright's Firefox build runs wasm about
// 8x slower than release Firefox (docs/BENCHMARKS.md), so it cannot measure LeanUI.
//
//   node tests/browser/selfbench.mjs <browser-binary> <firefox|chromium> [--runs 7] [--only a,b]
//        [--impls leanui,vanilla] [--leanui-dir dist/bench] [--json out.json]
//   e.g. node tests/browser/selfbench.mjs /Applications/Firefox.app/Contents/MacOS/firefox firefox
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
const LEANUI_DIR = opt("leanui-dir", "dist/bench").replace(/\/?$/, "/");
const MOUNTS = [["/leanui/", LEANUI_DIR], ["/vanilla/", "bench/vanilla/"], ["/", "bench/"]];
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm", ".css": "text/css" };

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
    res.writeHead(200, { "content-type": TYPES[path.extname(file)] || "application/octet-stream", "cache-control": "no-store" });
    res.end(fs.readFileSync(file)); return;
  }
  res.writeHead(404); res.end();
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const page = `http://127.0.0.1:${server.address().port}/runner.html?runs=${RUNS}&impls=${IMPLS}${ONLY ? "&only=" + ONLY : ""}`;
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
const timeout = setTimeout(() => { console.error("timed out"); try { process.kill(child.pid); } catch (e) {} process.exit(1); }, 30 * 60 * 1000);
const R = await posted;
clearTimeout(timeout);
// stop the browser and wait for it to exit before removing its profile
const exited = new Promise((r) => child.once("exit", r));
try { process.kill(child.pid); } catch (e) {}
await Promise.race([exited, new Promise((r) => setTimeout(r, 5000))]);
server.close();
try { fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch (e) {}

const impls = IMPLS.split(",");
const lines = [`## ${kind}: ${R.userAgent}`, "", `Memory64: ${R.memory64}; median of ${R.runs} fresh page loads${R.error ? "; ERROR " + R.error : ""}`, ""];
const head = ["operation", ...impls.flatMap((i) => [`${i} layout`, `${i} script`])];
if (impls.length === 2) head.push(`${impls[0]}/${impls[1]} (layout)`);
lines.push("| " + head.join(" | ") + " |", "|" + head.map(() => "---").join("|") + "|");
for (const op of OPS) {
  const c = R.cpu[op.name]; if (!c) continue;
  const cells = [op.desc, ...impls.flatMap((i) => c[i] ? [`${c[i].layout.toFixed(2)} ms`, `${c[i].script.toFixed(2)} ms`] : ["–", "–"])];
  if (impls.length === 2 && c[impls[0]] && c[impls[1]]) cells.push(`${(c[impls[0]].layout / c[impls[1]].layout).toFixed(2)}×`);
  lines.push("| " + cells.join(" | ") + " |");
}
lines.push("", "| startup | " + impls.join(" | ") + " |", "|---|" + impls.map(() => "---").join("|") + "|",
  "| ready (ms after navigation) | " + impls.map((i) => R.startup[i]?.readyMs ?? "–").join(" | ") + " |");
console.log(lines.join("\n"));
if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(R, null, 1));
