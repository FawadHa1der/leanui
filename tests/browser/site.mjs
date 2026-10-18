// The LeanUI site (examples/Site.lean, served by examples/SiteServer.lean) in real browsers.
//   tools/build-app.sh SiteApp site && lake build leanui-site && node tests/browser/site.mjs [chromium,firefox]
// Run it under the host browser lock. It starts .lake/build/bin/leanui-site on port 5361 and
// stops it (by its PID) at the end.
import { spawn } from "node:child_process";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const require = createRequire(process.env.LEANUI_PLAYWRIGHT_FROM || "/Users/fawadhaider/code/wasm64-lean-fable/qed64/package.json");
const pw = require("playwright");
const PORT = 5361, BASE = `http://127.0.0.1:${PORT}`;

const server = spawn(path.join(ROOT, ".lake/build/bin/leanui-site"), ["--port", String(PORT), "--quiet"], { cwd: ROOT, stdio: ["ignore", "ignore", "inherit"] });
const stop = () => { try { server.kill("SIGTERM"); } catch (e) {} };
process.on("exit", stop);
// ready when it answers (its stdout is block-buffered in a pipe, so no banner to wait for)
for (let i = 0; ; i++) {
  try { if ((await fetch(BASE + "/site.css")).ok) break; } catch (e) {}
  if (i > 200) { stop(); throw new Error("leanui-site did not start"); }
  await new Promise((r) => setTimeout(r, 100));
}

const results = [];
let failures = 0;
const check = (engine, what, ok, detail = "") => { results.push(ok); if (!ok) { failures++; console.log(`  FAIL ${engine}: ${what} ${detail}`); } };

try {
  // server-side rendering, without any browser
  const html = await (await fetch(BASE + "/")).text();
  check("http", "home is complete HTML before any script", html.includes("Web UIs, written in Lean 4.") && html.includes('<output id="value" class="pos">0</output>'));
  const deep = await fetch(BASE + "/benchmarks");
  check("http", "a deep link renders its page (results still loading)", (await deep.text()).includes("Loading the results"));
  const missing = await fetch(BASE + "/no-such-page");
  check("http", "unknown paths answer 404 with the site's page", missing.status === 404 && (await missing.text()).includes("Not found"));

  for (const engine of (process.argv[2] || "chromium,firefox").split(",")) {
    const browser = await pw[engine].launch({ headless: true });
    for (const mode of ["wasm", "server"]) {
      const C = (what, ok, detail) => check(`${engine}/${mode}`, what, ok, detail);
      const page = await browser.newPage();
      const errors = [];
      page.on("pageerror", (e) => errors.push(e.message));
      page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
      // hold the app back until the server-rendered page has an expando on its heading
      let release;
      const held = new Promise((r) => (release = r));
      const gate = mode === "wasm" ? "**/assets/site/app.js" : "**/leanui/*";
      let first = true;
      await page.route(gate, async (route) => { if (first) { first = false; await held; } await route.continue(); });
      // the held script delays the load event, so wait only for the document
      await page.goto(`${BASE}/?mode=${mode}`, { waitUntil: "domcontentloaded" });
      await page.evaluate(() => { document.querySelector("h1").__ssr = true; window.__noReload = true; });
      release();
      await page.waitForFunction((m) => document.documentElement.dataset.leanui === m, mode, { timeout: 30000 });
      await page.waitForTimeout(100);
      C("hydration adopts the server-rendered nodes", await page.evaluate(() => document.querySelector("h1").__ssr === true));
      await page.click("#inc"); await page.click("#inc");
      await page.waitForFunction(() => document.querySelector("#value").textContent === "2", null, { timeout: 5000 }).catch(() => {});
      C("the counter counts", (await page.textContent("#value")) === "2");
      await page.click(".site-header nav a:has-text('Benchmarks')");
      await page.waitForFunction(() => document.querySelectorAll("svg.chart rect").length > 0, null, { timeout: 10000 }).catch(() => {});
      C("navigates without a reload", await page.evaluate(() => window.__noReload === true && location.pathname === "/benchmarks"));
      C("fetches and charts the results (SVG)", await page.evaluate(() => document.querySelectorAll("svg.chart rect").length === 18 && document.querySelector("svg.chart").namespaceURI === "http://www.w3.org/2000/svg"));
      C("sets the title", (await page.title()) === "Benchmarks · LeanUI");
      await page.goBack();
      await page.waitForFunction(() => location.pathname === "/" && document.querySelector("#value"), null, { timeout: 5000 }).catch(() => {});
      C("back returns home, state kept", await page.evaluate(() => location.pathname === "/" && document.querySelector("#value").textContent === "2" && window.__noReload === true));
      await page.click(".site-header nav a:has-text('Examples')");
      await page.waitForSelector(".todo-demo .new-todo");
      await page.fill(".new-todo", "check the site"); await page.press(".new-todo", "Enter");
      await page.fill(".new-todo", "ship it"); await page.press(".new-todo", "Enter");
      await page.click(".todo-list li:first-child .toggle");
      await page.click(".filters a[href='#/active']");
      await page.waitForFunction(() => location.hash === "#/active", null, { timeout: 5000 }).catch(() => {});
      const items = await page.$$eval(".todo-list li label", (ls) => ls.map((l) => l.textContent));
      C("embedded TodoMVC with its fragment filter", JSON.stringify(items.slice(-1)) === JSON.stringify(["ship it"]) && (await page.evaluate(() => location.pathname + location.hash)) === "/examples#/active" && (await page.textContent(".site-header nav a.active")) === "Examples", JSON.stringify(items));
      C("no console errors", errors.length === 0, errors.join(" | "));
      await page.evaluate(() => localStorage.clear());
      await page.close();
    }
    await browser.close();
  }
} finally {
  stop();
}
console.log(`LeanUI site: ${results.filter(Boolean).length}/${results.length} checks passed`);
process.exit(failures ? 1 : 0);
