// How deep can a LeanUI view nest in the browser (wasm64)? Drives dist/depth-probe
// (LeanUI/Testing/DepthProbe.lean), which renders a chain of nested elements inside a
// display:none section (browsers cannot lay out a DOM a few thousand levels deep; this measures
// the engine). For each depth a fresh page jumps from depth 1 to d in one update (one recursive
// mount d levels deep) and changes the innermost text (one patch d levels deep); a binary search
// finds the largest depth that works. Then it checks what an overflow does to the app.
//   node tests/browser/depth.mjs [baseUrl] [chromium|firefox|both] [--lifecycle-only]
// --lifecycle-only checks a shallow view and disposal after overflow, without the depth search.
// Run under the host browser lock.
import { pw } from "./playwright.mjs";
const argv = process.argv.slice(2), positional = argv.filter((arg) => !arg.startsWith("--"));
const base = positional[0] || "http://127.0.0.1:5391/plain/depth-probe/index.html";
const lifecycleOnly = argv.includes("--lifecycle-only");
const engine = positional[1] || "both";
const engines = engine === "both" ? ["chromium", "firefox"] : [engine];

async function attempt(browser, d) {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", async (m) => {
    if (m.type() !== "error") return;
    const parts = await Promise.all(m.args().map((a) => a.evaluate((x) => (x && x.message) ? `${x.name}: ${x.message}` : String(x)).catch(() => "?")));
    errors.push(parts.join(" "));
  });
  await page.goto(base);
  await page.waitForFunction(() => window.__leanui, null, { timeout: 30000 });
  const r = await page.evaluate((d) => {
    const set = (id, v) => { const el = document.getElementById(id); el.value = v; el.dispatchEvent(new Event("input", { bubbles: true })); };
    const t0 = performance.now(); set("depth", String(d));
    const t1 = performance.now(); set("label", "x" + d);
    const t2 = performance.now();
    let n = 0, el = document.getElementById("chain").firstChild;
    while (el && el.nodeType === 1) { n++; el = el.firstChild; }
    const ok = n === d && el && el.nodeValue === "x" + d;
    // after a failure: does the app still answer?
    set("depth", "3");
    const after = document.getElementById("shown").textContent;
    return { ok, grow: t1 - t0, relabel: t2 - t1, n, after };
  }, d).catch((e) => ({ ok: false, err: e.message }));
  await new Promise((res) => setTimeout(res, 50));
  await page.close();
  return { ...r, ok: r.ok && errors.length === 0, errors };
}

// A deep view in the compiled probe must fail. Verify the terminal-error contract through
// the actual app, including listener and module release.
async function stoppedByOverflow(browser) {
  const page = await browser.newPage();
  try {
    await page.goto(base);
    await page.waitForFunction(() => window.__leanui, null, { timeout: 30000 });
    return await page.evaluate(() => {
      const rt = window.__leanui, transport = rt.transport;
      let notifications = 0, detail;
      rt.container.addEventListener("leanui:error", (e) => { notifications++; detail = e.detail; });
      const setDepth = (n) => {
        const input = document.querySelector("#depth");
        input.value = String(n); input.dispatchEvent(new Event("input", { bubbles: true }));
      };
      setDepth(10000);
      const stopped = document.querySelector("#shown").textContent;
      setDepth(3); rt.callback(1, true, "late");
      const result = { crashed: !!rt.crashed, disposed: !!rt.disposed, notifications, sameError: detail === rt.crashed,
        aborted: rt.effects.signal.aborted, released: transport.mod === null, inactive: LeanUI.active === null,
        unchanged: document.querySelector("#shown").textContent === stopped, pending: rt.queue.length,
        error: String(rt.crashed) };
      rt.dispose(); return result;
    });
  } finally { await page.close(); }
}

let allOk = true;
for (const engine of engines) {
  const browser = await pw[engine].launch({ headless: true });
  let lo = 100, hi = 200000, failure = null;
  const okAt = await attempt(browser, lo);
  if (!okAt.ok) { console.log(`${engine}: fails at ${lo}`, okAt); allOk = false; await browser.close(); continue; }
  const stopped = await stoppedByOverflow(browser);
  const stoppedOk = stopped.crashed && stopped.disposed && stopped.notifications === 1 && stopped.sameError &&
    stopped.aborted && stopped.released && stopped.inactive && stopped.unchanged && stopped.pending === 0;
  console.log(`${engine}: ${stoppedOk ? "PASS" : "FAIL"} overflow lifecycle ${JSON.stringify(stopped)}`);
  if (!stoppedOk) allOk = false;
  if (lifecycleOnly) { await browser.close(); continue; }
  let timing = okAt;
  // grow geometrically, then bisect
  while (lo * 2 < hi) {
    const r = await attempt(browser, lo * 2);
    if (r.ok) { lo = lo * 2; timing = r; } else { hi = lo * 2; failure = r; break; }
  }
  while (hi - lo > Math.max(50, lo / 50)) {
    const mid = Math.floor((lo + hi) / 2);
    const r = await attempt(browser, mid);
    if (r.ok) { lo = mid; timing = r; } else { hi = mid; failure = r; }
  }
  console.log(`${engine} ${browser.version()}: a view nests up to ${lo} levels (fails at ${hi}); at ${lo}: mount ${timing.grow.toFixed(1)} ms, patch ${timing.relabel.toFixed(1)} ms`);
  if (failure) {
    console.log(`  failure: ${failure.err || failure.errors[0] || "wrong DOM"}`);
    console.log(`  afterwards the app ${failure.after === "3:x" + hi ? "still works" : `no longer updates (setting depth 3 shows ${JSON.stringify(failure.after)})`}`);
  }
  await browser.close();
  if (lo < 1000) allOk = false;
}
console.log(allOk ? "PASS" : "FAIL");
process.exit(allOk ? 0 : 1);
