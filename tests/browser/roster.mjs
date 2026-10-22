// Browser test for the Roster app (examples/Roster.lean): presets, the solver's answers drawn on the
// grid and checked here again from the DOM, the explanation of an impossible problem, the lying
// solver (every lie rejected, with a reason), edits clearing the result, and notarizing (a receipt
// link when the page is served by leanui-roster; on the site, which has no notary, a link to its
// sample receipt; a plain error otherwise).
// node tests/browser/roster.mjs <url of dist/roster/index.html> [chromium|firefox]
import { pw } from "./playwright.mjs";

const url = process.argv[2] || "http://127.0.0.1:5331/roster/index.html";
const engine = process.argv[3] || "chromium";
const browser = await pw[engine].launch({ headless: true });
const page = await browser.newPage();
const errors = [], checks = [];
page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
page.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); });
const check = (name, ok, detail = "") => { checks.push({ name, ok: !!ok, detail: ok ? undefined : detail }); };
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// The grid as the page shows it: names, needs, highlights, and per cell whether the person can
// do the shift, works it, and is highlighted.
const grid = () => page.evaluate(() => {
  const texts = (sel) => [...document.querySelectorAll(sel)].map((e) => e.textContent);
  const rows = [...document.querySelectorAll(".grid tbody tr")];
  return {
    shifts: texts(".grid th.shift"),
    short: [...document.querySelectorAll(".grid th.shift")].map((e) => e.classList.contains("short")),
    need: texts(".grid .need output").map(Number),
    gets: document.querySelector(".grid tr.gets") ? texts(".grid tr.gets td").map(Number) : null,
    people: rows.map((r) => r.querySelector("th").textContent),
    able: rows.map((r) => r.querySelector("th").classList.contains("able")),
    cells: rows.map((r) => [...r.querySelectorAll(".cell")].map((c) =>
      ({ can: c.classList.contains("can"), works: c.classList.contains("works"), hl: c.classList.contains("hl") }))),
  };
});
const result = () => page.$eval("#result", (e) => e.className.replace("result", "").trim() || "none");
const text = (sel) => page.$eval(sel, (e) => e.textContent).catch(() => null);
const click = async (sel) => { await page.click(sel); await page.waitForTimeout(30); };
const ask = () => click("#ask");

// A roster on screen: everyone works at most one shift and only one they can do, every shift
// gets at least what it needs, and the "Gets" row says how many it gets.
function checkStaffed(what, g) {
  const unable = [], counts = g.shifts.map(() => 0);
  g.cells.forEach((row, i) => row.forEach((c, s) => { if (c.works) { counts[s]++; if (!c.can) unable.push(`${g.people[i]}/${g.shifts[s]}`); } }));
  check(`${what}: nobody works two shifts`, g.cells.every((row) => row.filter((c) => c.works).length <= 1));
  check(`${what}: every assignment is to an available cell`, unable.length === 0, unable.join(", "));
  check(`${what}: every shift has enough people`, counts.every((n, s) => n >= g.need[s]), JSON.stringify({ counts, need: g.need }));
  check(`${what}: the counts shown are the assignments`, same(g.gets, counts), JSON.stringify({ gets: g.gets, counts }));
  check(`${what}: nothing highlighted`, !g.short.some((x) => x) && !g.able.some((x) => x));
}

// A violator on screen: the highlighted shifts need more people than the highlighted people,
// who are exactly those able to do one of them; the highlighted cells are where they can; the
// sentence names them all.
async function checkImpossible(what, g) {
  const T = g.shifts.map((_, s) => s).filter((s) => g.short[s]);
  const able = g.people.map((_, i) => i).filter((i) => T.some((s) => g.cells[i][s].can));
  const need = T.reduce((n, s) => n + g.need[s], 0);
  check(`${what}: some shifts highlighted`, T.length > 0);
  check(`${what}: the highlighted people are those able to do them`, same(able, g.people.map((_, i) => i).filter((i) => g.able[i])));
  check(`${what}: they need more people than can do them`, need > able.length, JSON.stringify({ need, able: able.length }));
  check(`${what}: the highlighted cells are where they can`,
    g.cells.every((row, i) => row.every((c, s) => c.hl === (able.includes(i) && T.includes(s) && c.can))));
  check(`${what}: no assignments shown`, g.cells.every((row) => row.every((c) => !c.works)) && g.gets === null);
  const why = await text("#why");
  check(`${what}: the sentence names the shifts, the people and how many`,
    T.every((s) => why.includes(g.shifts[s])) && able.every((i) => why.includes(g.people[i])) &&
    why.includes(`${need === 1 ? "1 person" : need + " people"}, but`), why);
}

await page.goto(url);
await page.waitForFunction(() => window.__ready, null, { timeout: 30000 });
check("no result at first", (await result()) === "none");

// the feasible preset
await click("button.preset:has-text('Feasible')");
await ask();
check("feasible: staffed", (await result()) === "staffed", await result());
checkStaffed("feasible", await grid());

// editing clears the result: a cell, then a need
const before = await grid();
await click(".grid tbody tr:nth-child(1) .cell >> nth=0");
let g = await grid();
check("a click toggles the cell", g.cells[0][0].can === !before.cells[0][0].can);
check("a click clears the result", (await result()) === "none" && g.cells.every((r) => r.every((c) => !c.works)) && g.gets === null);
await click(".grid tbody tr:nth-child(1) .cell >> nth=0");
await ask();
check("staffed again", (await result()) === "staffed");
await click(".grid .need .more >> nth=2");
g = await grid();
check("+ raises the need and clears the result", g.need[2] === before.need[2] + 1 && (await result()) === "none");
await click(".grid .need .fewer >> nth=2");
check("− lowers it again", (await grid()).need[2] === before.need[2]);

// the impossible preset: the explanation in words and in the grid
await click("button.preset:has-text('Impossible')");
await ask();
check("impossible: not staffable", (await result()) === "impossible", await result());
check("impossible: the sentence", (await text("#why")) ===
  "These 2 shifts, Bar 12–15 and Bar 15–18, need 6 people, but only 5 people can do any of them: Ana, Ben, Chen, Dee and Hana.",
  await text("#why"));
await checkImpossible("impossible", await grid());

// the lying solver: four lies, each rejected with a reason, nothing drawn on the grid
await click("button.preset:has-text('Feasible')");
await click("#liar");
const lies = [];
for (let k = 0; k < 4; k++) {
  await ask();
  const lie = await text("#lie"), why = await text("#why");
  lies.push(lie);
  g = await grid();
  check(`lie ${k + 1}: rejected`, (await result()) === "rejected", await result());
  check(`lie ${k + 1}: says which lie`, lie && lie.startsWith("The lying solver "), lie);
  check(`lie ${k + 1}: says why`, why && why.startsWith("The solver's answer was rejected: ") && why.length > 40, why);
  check(`lie ${k + 1}: nothing on the grid`, g.cells.every((r) => r.every((c) => !c.works && !c.hl)) && g.gets === null);
}
check("four different lies", new Set(lies).size === 4, JSON.stringify(lies));
await click("#liar");
await ask();
check("liar off: accepted", (await result()) === "staffed", await result());
checkStaffed("liar off", await grid());

// random problems: whatever the answer, it is drawn right
const seen = new Set();
for (let k = 0; k < 6; k++) {
  await click("button.preset:has-text('Random')");
  await ask();
  g = await grid();
  const r = await result();
  seen.add(r);
  check(`random ${k + 1}: 30 people, 10 shifts`, g.people.length === 30 && g.shifts.length === 10);
  if (r === "staffed") checkStaffed(`random ${k + 1}`, g);
  else if (r === "impossible") await checkImpossible(`random ${k + 1}`, g);
  else check(`random ${k + 1}: staffed or impossible`, false, r);
}

// notarize: a receipt and a link to the verify page from leanui-roster; a plain error elsewhere
await click("button.preset:has-text('Feasible')");
await ask();
const quiet = errors.length;
await click("#notarize");
await page.waitForSelector("#verify, #notary-error", { timeout: 180000 });
const href = await page.$eval("#verify", (a) => a.getAttribute("href")).catch(() => null);
let notary;
if (href) {
  const receipt = new URL(href, url).searchParams.get("receipt");
  const res = await page.evaluate(async (u) => { const r = await fetch(u); return { status: r.status, text: await r.text() }; }, receipt);
  check("notarized: links to the verify page", href.startsWith("/roster/verify/?receipt="), href);
  const ndjson = res.text.split("\n").filter((l) => l);
  check("notarized: the receipt is there, as NDJSON", res.status === 200 && ndjson.length > 0 &&
    ndjson.every((l) => { try { JSON.parse(l); return true; } catch { return false; } }), res.status);
  check("notarized: the link text", (await text("#verify")) === "Verify this roster in your browser →");
  notary = "receipt " + receipt;
} else {
  notary = await text("#notary-error");
  // the browser logs the failed POST itself (Chromium does): expected without a notary
  errors.splice(quiet, errors.length - quiet, ...errors.slice(quiet).filter((e) => !/Failed to load resource.*(40[45]|503)/.test(e)));
  // the failures allowed: no notary at all (leanui serve), or the site's, which links to its
  // sample receipt; leanui-roster must notarize
  const sample = await page.$eval("#sample", (a) => a.getAttribute("href")).catch(() => null);
  check("not notarized: only because there is no notary",
    notary.startsWith("Not notarized: This page is not served by leanui-roster") ||
    (notary.startsWith("Not notarized: This site has no notary") && sample?.startsWith("/roster/verify/?receipt=")), notary);
  if (sample) notary += " (sample " + sample + ")";
}
await click(".grid tbody tr:nth-child(2) .cell >> nth=0");
check("an edit clears the notary too", (await page.$("#notarize, #verify, #notary-error, #sample")) === null);

const results = { engine: browser.version(), random: [...seen], notary, failed: checks.filter((c) => !c.ok), passed: checks.filter((c) => c.ok).length, errors };
await browser.close();
const ok = results.failed.length === 0 && errors.length === 0;
console.log(JSON.stringify(results, null, 1));
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
