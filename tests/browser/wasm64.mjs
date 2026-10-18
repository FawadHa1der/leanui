// What does Memory64 cost? Runs bench/wasm64 (one C workload built for wasm32 and wasm64) in a
// browser binary launched directly, with no automation protocol attached, and prints both times.
//   bench/wasm64/build.sh && node tests/browser/wasm64.mjs <browser-binary> <firefox|chromium>
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
const DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../bench/wasm64");
const [bin, kind] = process.argv.slice(2);
const T = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm" };
let done;
const got = new Promise((r) => (done = r));
const server = http.createServer((q, r) => {
  const u = new URL(q.url, "http://x").pathname;
  if (u === "/result") { let b = ""; q.on("data", (c) => (b += c)); q.on("end", () => { r.end(); done(JSON.parse(b)); }); return; }
  const f = path.join(DIR, u.slice(1) || "index.html");
  if (!f.startsWith(DIR) || !fs.existsSync(f)) { r.writeHead(404); r.end(); return; }
  r.writeHead(200, { "content-type": T[path.extname(f)] }); r.end(fs.readFileSync(f));
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const url = `http://127.0.0.1:${server.address().port}/index.html`;
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "leanui-wasm64-"));
if (kind === "firefox") fs.writeFileSync(path.join(profile, "user.js"), 'user_pref("privacy.reduceTimerPrecision", false);\nuser_pref("browser.shell.checkDefaultBrowser", false);\n');
const args = kind === "firefox" ? ["--headless", "--no-remote", "--profile", profile, url] : ["--headless=new", `--user-data-dir=${profile}`, "--no-first-run", url];
const child = spawn(bin, args, { stdio: "ignore" });
const r = await Promise.race([got, new Promise((_, no) => setTimeout(() => no(new Error("timeout")), 120000))]);
const exited = new Promise((r) => child.once("exit", r));
try { process.kill(child.pid); } catch (e) {}
await Promise.race([exited, new Promise((r) => setTimeout(r, 5000))]);
server.close();
try { fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch (e) {}
console.log(`${r.userAgent}\n  wasm32 ${r.wasm32.toFixed(2)} ms   wasm64 ${r.wasm64.toFixed(2)} ms   wasm64/wasm32 ${(r.wasm64 / r.wasm32).toFixed(2)}x`);
