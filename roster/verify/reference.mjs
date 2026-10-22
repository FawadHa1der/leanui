// Writes reference.json, what the verify page compares receipts with (receipt.js, check 3): the
// fingerprint (checker/src/fingerprint.rs) of every declaration in an export of the published
// specification, `Roster.Problem.Valid`, and of `Roster.Problem.checkRoster_iff`, by which
// receipts prove it, with all they rely on: everything a receipt holds outside `Roster.Receipt`.
// Also `Valid` as nanoda prints it, which the page shows: a receipt's own printing could differ,
// as fingerprints leave out binder names and kinds.
// build.sh makes the export with Lean 4.35's leanexport from roster/notary's build of the source,
// as the notary makes receipts, and runs this with dist/roster/verify/checker.wasm.
//   node roster/verify/reference.mjs EXPORT.ndjson SOURCE.lean > reference.json
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { check } from "./worker.js";

const [file, source] = process.argv.slice(2);
if (!source) { console.error("usage: node roster/verify/reference.mjs EXPORT.ndjson SOURCE.lean > reference.json"); process.exit(2); }
const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const ndjson = fs.readFileSync(file, "utf8");
const module = await WebAssembly.compile(fs.readFileSync(path.join(ROOT, "dist/roster/verify/checker.wasm")));
const v = await check(module, ndjson, ["Roster.Problem.Valid"]);
if (!v.ok) { console.error(`the reference does not check: ${v.during}: ${v.error}`); process.exit(1); }
const { meta } = JSON.parse(ndjson.slice(0, ndjson.indexOf("\n")));
console.log(JSON.stringify({
  source: path.relative(ROOT, path.resolve(source)),
  sha256: crypto.createHash("sha256").update(fs.readFileSync(source)).digest("hex"),
  lean: meta.lean.version,
  valid: v.printed["Roster.Problem.Valid"]?.text,
  fingerprints: v.fingerprints,
}));
