// Browser test for the Roster verify page (roster/verify/): a good receipt passes all four checks
// and its table and the definition of Valid are shown; the tamper button flips a cell and the
// kernel rejects it, with why; a forged receipt (roster/verify/forge.mjs: List.count redefined,
// nobody working), chosen as a file, is accepted by the kernel but fails the comparison with the
// published source (check 3); so does every other forged receipt given. Prints the timings.
//   node tests/browser/roster-verify.mjs <url of the verify page with ?receipt=…> [chromium|firefox] [FORGED.ndjson …]
//   node tests/browser/roster-verify.mjs --serve RECEIPT.ndjson [chromium|firefox] [FORGED.ndjson …]
// The first form takes the page as served (by leanui-roster, examples/RosterServer.lean); the
// second serves dist/roster/verify (roster/verify/build.sh) and the receipt itself. Run it under
// the host browser lock.
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pw } from "./playwright.mjs";
import { forgeCount } from "../../roster/verify/forge.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const args = process.argv.slice(2);
let url, server;
if (args[0] === "--serve") {
  args.shift();
  const receipt = path.resolve(args.shift()), dist = path.join(ROOT, "dist/roster/verify"), under = "/roster/verify/";
  const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json", ".wasm": "application/wasm" };
  server = http.createServer((req, res) => {
    const p = decodeURIComponent(new URL(req.url, "http://x").pathname);
    const file = p === "/receipt.ndjson" ? receipt : p.startsWith(under) ? path.join(dist, p.slice(under.length) || "index.html") : "";
    if (!(file === receipt || file.startsWith(dist + path.sep)) || !fs.existsSync(file)) return res.writeHead(404).end();
    res.writeHead(200, { "content-type": types[path.extname(file)] ?? "application/x-ndjson" }).end(fs.readFileSync(file));
  });
  await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
  url = `http://127.0.0.1:${server.address().port}/roster/verify/?receipt=/receipt.ndjson`;
} else url = args.shift();
const engine = ["chromium", "firefox"].includes(args[0]) ? args.shift() : "chromium";
const forged = args;
if (!url) { console.error("usage: see the top of tests/browser/roster-verify.mjs"); process.exit(2); }

const browser = await pw[engine].launch({ headless: true });
const page = await browser.newPage();
const errors = [], checks = [], times = { engine: `${engine} ${browser.version()}` };
page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
page.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); });
const check = (name, ok, detail = "") => { checks.push({ name, ok: !!ok, detail: ok ? undefined : detail }); };
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const state = () => page.evaluate(() => window.__verify);
const text = (sel) => page.$eval(sel, (e) => e.textContent).catch(() => "");
/** Wait for the page's verdict number `n`, and time it from now. */
async function verdict(n) {
  const t = Date.now();
  await page.waitForFunction((n) => window.__verify?.n >= n, n, { timeout: 60000 });
  return { ...(await state()), wall: Date.now() - t };
}

try {
  // the good receipt
  const t0 = Date.now();
  await page.goto(url);
  const good = await verdict(1);
  times.load = Date.now() - t0;
  times.check = good.ms;
  check("the receipt is verified", good.verified && same(good.checks, [true, true, true, true]), JSON.stringify(good) + " " + (await text("#checks")));
  check("it says so", (await text("#headline")).startsWith("Verified"), await text("#headline"));
  const grid = await page.evaluate(() => ({
    people: document.querySelectorAll("#grid tbody tr").length,
    works: document.querySelectorAll("#grid .cell.works").length,
    bad: document.querySelectorAll("#grid .cell.bad").length,
  }));
  check("the table shows the people and who works", grid.people > 0 && grid.works > 0 && grid.bad === 0, JSON.stringify(grid));
  check("what was proved: the definition of Valid", (await text("#valid")).startsWith("def Roster.Problem.Valid") && !(await page.isHidden("#proved")), await text("#valid"));
  check("the reference is named", (await text("#reference")).includes("examples/Roster/Core.lean"), await text("#reference"));

  // tamper: one cell flipped, the kernel must reject it, and the page say why
  await page.click("#tamper");
  const tampered = await verdict(2);
  times.tamper = tampered.wall;
  check("the tampered receipt is rejected by the kernel", tampered.flipped && !tampered.verified && tampered.checks[0] === false, JSON.stringify(tampered));
  check("the page says why", (await text("#why")).includes("no longer checks"), await text("#why"));
  check("the flipped cell is shown, worked but not available",
    await page.evaluate(() => { const c = document.querySelector("#grid .cell.flipped"); return !!c && c.matches(".works.bad"); }));
  await page.click("#original");
  const again = await verdict(3);
  check("the original passes again", again.verified, JSON.stringify(again));

  // forgeries, chosen as files: the kernel accepts them, the reference does not
  const receipt = await page.evaluate(async (u) => (await fetch(new URL(u, location.href).searchParams.get("receipt"))).text(), url);
  const files = [["List.count redefined", forgeCount(receipt)], ...forged.map((f) => [path.basename(f), fs.readFileSync(f, "utf8")])];
  let n = 3;
  for (const [what, ndjson] of files) {
    await page.setInputFiles("#file", { name: "forged.ndjson", mimeType: "application/x-ndjson", buffer: Buffer.from(ndjson) });
    const v = await verdict(++n);
    times[what] = v.ms;
    check(`forged (${what}): only the published definitions fail`, same(v.checks, [true, true, false, true]), JSON.stringify(v) + " " + (await text("#checks")));
    check(`forged (${what}): it says why`, (await text("#why")).includes("does not mean the published one"), await text("#why"));
    check(`forged (${what}): nothing shown as proved`, await page.isHidden("#proved"));
  }
} catch (e) {
  check("no exception", false, e.stack);
}
await browser.close();
server?.close();
check("no page errors", errors.length === 0, errors.join("\n"));
const failed = checks.filter((c) => !c.ok);
for (const c of checks) console.log(`${c.ok ? "ok  " : "FAIL"} ${c.name}${c.ok ? "" : ": " + c.detail}`);
console.log("times (ms):", JSON.stringify(times));
console.log(failed.length ? `FAIL: ${failed.length} of ${checks.length}` : `PASS: ${checks.length} checks`);
process.exit(failed.length ? 1 : 0);
