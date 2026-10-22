// Runs the verify page's checks under Node: worker.js's `check` (the code the page's worker runs)
// on dist/roster/verify/checker.wasm, judged by receipt.js against dist/roster/verify/reference.json
// (roster/verify/build.sh builds both). The first receipt must pass all four checks; its copy with
// one cell flipped (receipt.js's tamper, the page's button) must fail the kernel's, and its
// forgery with `List.count` redefined (forge.mjs) only the comparison with the published source.
// Every other receipt given must be rejected. Prints each outcome and how long the check took.
//   node roster/verify/test.mjs RECEIPT.ndjson [BAD.ndjson …]
import fs from "node:fs";
import { check } from "./worker.js";
import { DATA, PRINT, TITLES, judge, tamper } from "./receipt.js";
import { forgeCount } from "./forge.mjs";

const [good, ...bad] = process.argv.slice(2);
if (!good) { console.error("usage: node roster/verify/test.mjs RECEIPT.ndjson [BAD.ndjson …]"); process.exit(2); }
const dist = new URL("../../dist/roster/verify/", import.meta.url);
const reference = JSON.parse(fs.readFileSync(new URL("reference.json", dist), "utf8"));
const t0 = performance.now();
const module = await WebAssembly.compile(fs.readFileSync(new URL("checker.wasm", dist)));
console.log(`checker.wasm compiled in ${(performance.now() - t0).toFixed(0)} ms`);

let failed = 0;
/** Check and judge `ndjson`: the four checks' `ok`s must be `expect`, or without it, not all true. */
async function run(what, ndjson, expect) {
  const t = performance.now();
  const verdict = await check(module, ndjson, PRINT, DATA);
  verdict.ms = Math.round(performance.now() - t);
  const result = judge(verdict, reference);
  const pass = expect ? expect.every((ok, i) => ok === result.checks[i].ok) : !result.verified;
  if (!pass) failed++;
  console.log(`${pass ? "ok  " : "FAIL"} ${what}: ${result.verified ? "verified" : "rejected"} in ${verdict.ms} ms (${(ndjson.length / 1e6).toFixed(1)} MB)`);
  result.checks.forEach((c, i) => console.log(`     ${c.ok ? "✓" : c.ok === false ? "✗" : "–"} ${TITLES[i]}. ${c.text}`));
  return result;
}

const ndjson = fs.readFileSync(good, "utf8");
const { table } = await run(good, ndjson, [true, true, true, true]);
const flipped = table && tamper(ndjson, table);
if (!flipped) { failed++; console.log("FAIL no cell to flip"); }
else await run(`${good}, ${table.people[flipped.person]} can no longer do ${table.shifts[flipped.shift]}`, flipped.ndjson, [false, null, null, true]);
await run(`${good}, List.count redefined, nobody working`, forgeCount(ndjson), [true, true, false, true]);
for (const file of bad) await run(file, fs.readFileSync(file, "utf8"));
if (failed) { console.error(`${failed} wrong outcome(s)`); process.exit(1); }
