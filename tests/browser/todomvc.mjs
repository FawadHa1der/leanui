// TodoMVC in real browsers: real typing, clicks, double-clicks, focus, back/forward, reloads.
//   tools/build-app.sh TodoMVCApp todomvc && node tests/browser/todomvc.mjs [chromium,firefox]
// Run it under the host browser lock. It serves dist/todomvc itself.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { pw } from "./playwright.mjs";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const DIR = path.join(ROOT, "dist/todomvc");
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".wasm": "application/wasm" };
const server = http.createServer((req, res) => {
  const u = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const f = path.join(DIR, u.slice(1) || "index.html");
  if (!f.startsWith(DIR) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": TYPES[path.extname(f)] || "application/octet-stream" }); res.end(fs.readFileSync(f));
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const BASE = `http://127.0.0.1:${server.address().port}/index.html`;

const results = [];
let failures = 0;
const check = (engine, what, ok, detail = "") => { results.push([engine, what, ok]); if (!ok) { failures++; console.log(`  FAIL ${engine}: ${what} ${detail}`); } };

for (const engine of (process.argv[2] || "chromium,firefox").split(",")) {
  const browser = await pw[engine].launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
  const ready = async () => { await page.waitForFunction(() => window.__ready, null, { timeout: 30000 }); await page.waitForTimeout(50); };
  const items = () => page.$$eval(".todo-list li", (ls) => ls.map((l) => (l.classList.contains("completed") ? "x " : "o ") + l.querySelector("label").textContent));
  const count = () => page.textContent(".todo-count").catch(() => null);
  const C = (what, ok, detail) => check(engine, what, ok, detail);

  await page.goto(BASE);
  await ready();
  C("new-todo focused at start", await page.evaluate(() => document.activeElement?.classList.contains("new-todo")));
  C("no main/footer without todos", (await page.$(".main")) === null && (await page.$(".footer")) === null);
  for (const t of ["first", "second", "   ", "  third  "]) { await page.fill(".new-todo", t); await page.press(".new-todo", "Enter"); }
  C("added, trimmed, blank ignored", JSON.stringify(await items()) === JSON.stringify(["o first", "o second", "o third"]), JSON.stringify(await items()));
  C("input cleared", (await page.inputValue(".new-todo")) === "");
  C("stored in localStorage", (await page.evaluate(() => localStorage.getItem("todos-leanui"))) === JSON.stringify([{ title: "first", completed: false }, { title: "second", completed: false }, { title: "third", completed: false }]));
  await page.click(".todo-list li:nth-child(1) .toggle");
  C("toggle completes", (await items())[0] === "x first" && (await count()) === "2 items left", await count());
  // edit: Enter saves, Escape cancels, blur saves, empty deletes
  await page.dblclick(".todo-list li:nth-child(2) label");
  C("double-click edits", (await page.$(".todo-list li.editing")) !== null);
  C("editor focused with the title", await page.evaluate(() => document.activeElement?.classList.contains("edit") && document.activeElement.value === "second"));
  await page.fill(".todo-list li.editing .edit", "  second, edited ");
  await page.press(".todo-list li.editing .edit", "Enter");
  C("Enter saves trimmed", (await items())[1] === "o second, edited" && (await page.$(".editing")) === null, JSON.stringify(await items()));
  await page.dblclick(".todo-list li:nth-child(2) label");
  await page.fill(".todo-list li.editing .edit", "not this");
  await page.press(".todo-list li.editing .edit", "Escape");
  C("Escape cancels", (await items())[1] === "o second, edited" && (await page.$(".editing")) === null);
  await page.dblclick(".todo-list li:nth-child(3) label");
  await page.fill(".todo-list li.editing .edit", "third via blur");
  await page.click("h1");
  C("blur saves", (await items())[2] === "o third via blur" && (await page.$(".editing")) === null, JSON.stringify(await items()));
  await page.dblclick(".todo-list li:nth-child(3) label");
  await page.fill(".todo-list li.editing .edit", "   ");
  await page.press(".todo-list li.editing .edit", "Enter");
  C("empty title deletes", (await items()).length === 2);
  // filters: links, the URL fragment, back/forward
  await page.click(".filters a[href='#/active']");
  C("Active filter", JSON.stringify(await items()) === JSON.stringify(["o second, edited"]) && page.url().endsWith("#/active") && (await page.textContent(".filters a.selected")) === "Active");
  await page.click(".filters a[href='#/completed']");
  C("Completed filter", JSON.stringify(await items()) === JSON.stringify(["x first"]) && page.url().endsWith("#/completed"));
  await page.goBack(); await page.waitForTimeout(100);
  C("back returns to Active", JSON.stringify(await items()) === JSON.stringify(["o second, edited"]) && page.url().endsWith("#/active"), page.url());
  await page.goForward(); await page.waitForTimeout(100);
  C("forward returns to Completed", JSON.stringify(await items()) === JSON.stringify(["x first"]));
  await page.click(".filters a[href='#/']");
  // toggle all, clear completed
  await page.click(".toggle-all + label");
  C("toggle all completes all", (await items()).every((s) => s.startsWith("x ")) && (await count()) === "0 items left");
  await page.click(".toggle-all + label");
  C("toggle all again reopens all", (await items()).every((s) => s.startsWith("o ")) && (await page.$(".clear-completed")) === null);
  await page.click(".todo-list li:nth-child(2) .toggle");
  await page.click(".clear-completed");
  C("clear completed", JSON.stringify(await items()) === JSON.stringify(["o first"]));
  // destroy (the button only shows on hover)
  await page.fill(".new-todo", "doomed"); await page.press(".new-todo", "Enter");
  await page.hover(".todo-list li:nth-child(2)");
  await page.click(".todo-list li:nth-child(2) .destroy");
  C("destroy", JSON.stringify(await items()) === JSON.stringify(["o first"]));
  // persistence across reloads, and the filter from the URL on first render
  await page.click(".todo-list li:nth-child(1) .toggle");
  await page.fill(".new-todo", "keep me"); await page.press(".new-todo", "Enter");
  await page.goto(BASE + "#/completed"); await page.reload(); await ready();
  C("reload keeps the list and opens the URL's filter", JSON.stringify(await items()) === JSON.stringify(["x first"]) && (await page.textContent(".filters a.selected")) === "Completed", JSON.stringify(await items()));
  await page.click(".filters a[href='#/']");
  C("both todos after reload", JSON.stringify(await items()) === JSON.stringify(["x first", "o keep me"]));
  C("no console errors", errors.length === 0, errors.join("; "));
  await browser.close();
}
server.close();
const passed = results.filter((r) => r[2]).length;
console.log(`TodoMVC in the browser: ${passed}/${results.length} checks passed (${[...new Set(results.map((r) => r[0]))].join(", ")})`);
process.exit(failures ? 1 : 0);
