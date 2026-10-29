// Browser smoke test for dist/counter: boots the wasm app, clicks and types, checks the DOM.
// node tests/browser/counter.mjs [baseUrl] [chromium|firefox]   (run under the host browser lock)
import { pw } from "./playwright.mjs";
const engine = process.argv[3] || "chromium";
const browser = await pw[engine].launch({ headless: true });
const page = await browser.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
page.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); });
await page.goto(process.argv[2] || "http://127.0.0.1:5330/plain/counter/index.html");
await page.waitForFunction(() => window.__leanui, null, { timeout: 30000 });
const read = () => page.$eval("#value", (e) => e.textContent);
const results = { engine: browser.version(), boot: await page.evaluate(() => window.__leanui.bootMs), coi: await page.evaluate(() => crossOriginIsolated) };
results.initial = await read();
for (let i = 0; i < 3; i++) await page.click("#inc");
results.after3inc = await read();
await page.click("#dec");
results.afterDec = await read();
await page.fill("#box", "-7");
results.afterInput = await read();
results.negClass = await page.$eval("#value", (e) => e.className);
await page.click("#reset");
results.afterReset = await read();
// Exercise startup failure through the compiled app's initial flush.
results.startupFailure = await page.evaluate(async () => {
  const previous = window.__leanui, start = LeanUI.Runtime.prototype.start;
  let failed, rejected = false;
  LeanUI.Runtime.prototype.start = function (boot) { failed = this; return start.call(this, boot); };
  try { await LeanUI.start({ glue: "app.js", selector: "[" }); } catch { rejected = true; }
  finally { LeanUI.Runtime.prototype.start = start; }
  return { rejected, disposed: !!failed?.disposed, aborted: !!failed?.effects.signal.aborted,
    released: failed?.transport === null, restored: LeanUI.active === previous };
});
await page.click("#inc");
results.afterFailedStartup = await read();
results.disposal = await page.evaluate(() => {
  const rt = window.__leanui, transport = rt.transport;
  rt.dispose(); rt.dispose();
  document.querySelector("#inc").click();
  rt.callback(1, true, "late");
  return { disposed: rt.disposed, aborted: rt.effects.signal.aborted, inactive: LeanUI.active === null,
    released: transport.mod === null, value: document.querySelector("#value").textContent };
});
results.stats = await page.evaluate(() => window.__leanui.stats);
results.errors = errors;
await browser.close();
const ok = results.initial === "0" && results.after3inc === "3" && results.afterDec === "2" && results.afterInput === "-7" && results.negClass === "neg" && results.afterReset === "0" &&
  Object.values(results.startupFailure).every((x) => x === true) && results.afterFailedStartup === "1" &&
  results.disposal.disposed && results.disposal.aborted && results.disposal.inactive && results.disposal.released &&
  results.disposal.value === "1" && errors.length === 0;
console.log(JSON.stringify(results, null, 1));
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
