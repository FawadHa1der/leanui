// Runs the verify page's checker under Node: worker.js's `check` (the code the page's worker runs)
// on dist/roster/verify/checker.wasm (roster/verify/build.sh). The first receipt must be accepted,
// every other one rejected; prints each verdict and how long it took. "Accepted" means only that
// every declaration in the file checks, so a Roster receipt must also state what the page says it
// does (`STATEMENT`).
//   node roster/verify/test.mjs RECEIPT.ndjson [TAMPERED.ndjson …]
import fs from "node:fs";
import { check } from "./worker.js";

const [good, ...bad] = process.argv.slice(2);
if (!good) { console.error("usage: node roster/verify/test.mjs RECEIPT.ndjson [TAMPERED.ndjson …]"); process.exit(2); }
// what the page shows: the theorem's statement and the specification it is about
const NAMES = ["Roster.Receipt.valid", "Roster.Problem.Valid"];
const STATEMENT = "Roster.Problem.Valid Roster.Receipt.problem Roster.Receipt.roster";

const t0 = performance.now();
const module = await WebAssembly.compile(fs.readFileSync(new URL("../../dist/roster/verify/checker.wasm", import.meta.url)));
console.log(`checker.wasm compiled in ${(performance.now() - t0).toFixed(0)} ms`);
let failed = 0;
for (const [file, accept] of [[good, true], ...bad.map((f) => [f, false])]) {
  const ndjson = fs.readFileSync(file, "utf8");
  const t = performance.now();
  const v = await check(module, ndjson, NAMES);
  const ms = (performance.now() - t).toFixed(0);
  const stated = v.printed?.["Roster.Receipt.valid"];
  const pass = v.ok === accept && (!stated || stated.type === STATEMENT);
  if (!pass) failed++;
  console.log(`${pass ? "ok  " : "FAIL"} ${file}: ${v.ok ? "accepted" : "rejected"} in ${ms} ms (${(ndjson.length / 1e6).toFixed(1)} MB)`);
  if (v.ok) {
    console.log(`     ${v.declarations} declarations, axioms: ${v.axioms.join(", ") || "none"}`);
    for (const [n, p] of Object.entries(v.printed)) console.log(`     ${n}: ${p ? p.type : "not in the receipt"}`);
  } else console.log(`     ${v.during ? v.during + ": " : ""}${v.error}`);
}
if (failed) { console.error(`${failed} wrong verdict(s)`); process.exit(1); }
