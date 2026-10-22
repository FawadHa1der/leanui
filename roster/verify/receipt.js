// What makes a Roster receipt good (roster/README.md), for the verify page (verify.js) and its
// tests (test.mjs, tests/browser/roster-verify.mjs). The checker (worker.js) says only that every
// declaration in the file checks, and a receipt brings its own declarations: everything its
// theorem relies on, Init's included, so that it checks on its own. So a receipt is good only if
//  1. the checker accepts it,
//  2. its theorem `Roster.Receipt.valid` states exactly `Valid problem roster`,
//  3. every declaration outside `Roster.Receipt` is the published one: it has the fingerprint
//     (checker/src/fingerprint.rs) the reference gives it (reference.json: Valid and
//     checkRoster_iff exported from examples/Roster/Core.lean; build.sh), so the receipt cannot
//     redefine `Valid` or anything it uses;
//  4. `problem` and `roster` are plain data (checker/src/data.rs): the table the page shows.
// Sentences put code in `backquotes`.

export const STATEMENT = "Roster.Problem.Valid Roster.Receipt.problem Roster.Receipt.roster";
// what the page asks the checker for: the declarations to print, the definitions to decode
export const PRINT = ["Roster.Receipt.valid", "Roster.Problem.Valid"];
export const DATA = ["Roster.Receipt.problem", "Roster.Receipt.roster"];
const OWN = "Roster.Receipt.";

const list = (names, n = 4) =>
  names.slice(0, n).map((x) => "`" + x + "`").join(", ") + (names.length > n ? ` and ${names.length - n} more` : "");
const plural = (n, one, many = one + "s") => `${n.toLocaleString("en")} ${n === 1 ? one : many}`;

/** The problem and roster of a verdict's data, or why they are not plain data. */
export function decode(data) {
  const field = (name) => {
    const d = data?.[name];
    if (!d) throw `\`${name}\` was not decoded`;
    if ("error" in d) throw `\`${name}\` is not plain data: ${d.error}`;
    return d.value;
  };
  try {
    const mk = field("Roster.Receipt.problem")?.["Roster.Problem.mk"], roster = field("Roster.Receipt.roster");
    const all = (xs, ok) => Array.isArray(xs) && xs.every(ok);
    const [people, shifts, need, avail] = mk ?? [];
    const nat = (n) => Number.isSafeInteger(n) && n >= 0;
    if (!(mk?.length === 4 && all(people, (x) => typeof x === "string") && all(shifts, (x) => typeof x === "string") &&
          all(need, nat) && all(avail, (row) => all(row, (b) => typeof b === "boolean"))))
      throw "`Roster.Receipt.problem` is not a `Roster.Problem.mk` of names, needs and availability";
    if (!all(roster, (s) => s === null || nat(s))) throw "`Roster.Receipt.roster` is not a list of shifts or `none`";
    return { table: { people, shifts, need, avail, roster } };
  } catch (why) {
    return { why: String(why) };
  }
}

export const TITLES = ["Checked by an independent kernel", "The right statement", "The published definitions", "Plain data"];

/** The four checks of `verdict` (the checker's, with `ms` if timed) against `reference`
    (reference.json, or null if it could not be loaded): each with `ok` (true, false, or null
    when it could not be made) and a sentence (titles: TITLES); `table`, the problem and roster
    if they decode; `verified`, whether all four passed. */
export function judge(verdict, reference) {
  const checks = [];
  const ms = verdict.ms != null ? ` in ${plural(verdict.ms, "ms", "ms")}` : "";
  if (verdict.ok) checks.push({ ok: true, text: `nanoda accepted all ${plural(verdict.declarations, "declaration")}${ms}.` });
  else if (verdict.during) checks.push({ ok: false, text: `nanoda rejected it while ${verdict.during.replace(/^checking (.*)/, "checking `$1`")}: ${verdict.error}` });
  else checks.push({ ok: false, text: `No verdict: ${verdict.error}.` }); // the checker could not run, or crashed (worker.js)
  const skipped = { ok: null, text: "Not checked: the kernel did not accept the receipt." };

  const stated = verdict.printed?.["Roster.Receipt.valid"];
  if (!verdict.ok) checks.push(skipped);
  else if (!stated) checks.push({ ok: false, text: "There is no theorem `Roster.Receipt.valid`." });
  else if (stated.type !== STATEMENT) checks.push({ ok: false, text: `\`Roster.Receipt.valid\` states \`${stated.type}\`, not \`${STATEMENT}\`.` });
  else checks.push({ ok: true, text: `\`Roster.Receipt.valid\` states exactly \`${STATEMENT}\`.` });

  if (!verdict.ok) checks.push(skipped);
  else if (!reference) checks.push({ ok: false, text: "Not checked: the reference fingerprints (`reference.json`) did not load." });
  else {
    const others = Object.keys(verdict.fingerprints).filter((n) => !n.startsWith(OWN));
    const known = (n) => Object.hasOwn(reference.fingerprints, n);
    const unknown = others.filter((n) => !known(n));
    const changed = others.filter((n) => known(n) && reference.fingerprints[n] !== verdict.fingerprints[n]);
    const from = `\`${reference.source}\` (Lean ${reference.lean})`;
    if (!unknown.length && !changed.length)
      checks.push({ ok: true, text: `The other ${plural(others.length, "declaration")} (\`Roster.Problem.Valid\` and all it relies on) are exactly those of ${from}: each has the reference's fingerprint.` });
    else checks.push({ ok: false, text: [
      changed.length && `${plural(changed.length, "declaration")} differ${changed.length === 1 ? "s" : ""} from ${from}: ${list(changed)}.`,
      unknown.length && `${plural(unknown.length, "declaration")} ${unknown.length === 1 ? "is" : "are"} not in it: ${list(unknown)}.`,
    ].filter(Boolean).join(" ") });
  }

  const { table, why } = verdict.data ? decode(verdict.data) : { why: "Not checked: the checker could not read the receipt." };
  if (table) {
    const working = table.roster.filter((s) => s !== null).length;
    checks.push({ ok: true, text: `\`problem\` and \`roster\` are plain data: ${plural(table.people.length, "person", "people")}, ${plural(table.shifts.length, "shift")}, ${working} working, as the table below shows.` });
  } else checks.push({ ok: verdict.data ? false : null, text: why });

  return { checks, table, verified: checks.every((c) => c.ok) };
}

/** A copy of `ndjson` in which one cell of the problem's availability that the roster uses is
    flipped to false, so that the roster is no longer valid, and which person and shift that is;
    null if no cell can be. `table` is the receipt's (judge). An export file shares equal subterms,
    numbers its nodes in order, and nanoda refuses a node that duplicates another, so the cell's
    node `List.cons Bool true rest` is pointed at an existing `List.cons Bool false` (written
    earlier), in a cell where no node `List.cons Bool false rest` exists yet and no other row
    shares the cell's node, which would flip it too. */
export function tamper(ndjson, table) {
  const lines = ndjson.split("\n");
  const names = [""], exprs = [], at = [], apps = new Map();
  let problem;
  lines.forEach((l, k) => {
    if (!l) return;
    const r = JSON.parse(l);
    if ("in" in r) names[r.in] = r.str ? (r.str.pre ? names[r.str.pre] + "." : "") + r.str.str : names[r.num.pre] + "." + r.num.i;
    else if ("ie" in r) { exprs[r.ie] = r; at[r.ie] = k; if (r.app) apps.set(`${r.app.fn} ${r.app.arg}`, r.ie); }
    else if (r.def && names[r.def.name] === "Roster.Receipt.problem") problem = r.def.value;
  });
  const spine = (e) => { const args = []; for (; exprs[e]?.app; e = exprs[e].app.fn) args.unshift(exprs[e].app.arg); return [e, args]; };
  const isConst = (e, name) => exprs[e]?.const && names[exprs[e].const.name] === name;
  // a list's cons nodes and elements, each with the `let`s around it (Lean writes a long list
  // literal with them, checker/src/data.rs): `env` holds what the bound variables stand for
  const items = (e, env = []) => {
    const xs = [];
    for (;;) {
      const x = exprs[e];
      if (x?.letE) { env = [{ e: x.letE.value, env }, ...env]; e = x.letE.body; continue; }
      if (x && "bvar" in x) return env[x.bvar] ? xs.concat(items(env[x.bvar].e, env[x.bvar].env)) : xs;
      const [, args] = spine(e);
      if (args.length !== 3) return xs;
      xs.push({ cons: e, item: args[1], env });
      e = args[2];
    }
  };
  const [, fields] = spine(problem);
  if (fields.length !== 4) return null;
  const rows = items(fields[3]).map((row) => items(row.item, row.env).map((x) => x.cons));
  const uses = new Map();
  for (const row of rows) for (const c of row) uses.set(c, (uses.get(c) ?? 0) + 1);
  const yes = exprs.findIndex((x) => isConst(x?.ie, "Bool.true")), no = exprs.findIndex((x) => isConst(x?.ie, "Bool.false"));
  for (const [i, s] of table.roster.entries()) {
    const cell = rows[i]?.[s];
    if (s === null || cell === undefined || uses.get(cell) !== 1) continue;
    const { fn, arg: rest } = exprs[cell].app, consBool = exprs[fn].app.fn;
    const consNo = apps.get(`${consBool} ${no}`);
    if (exprs[fn].app.arg !== yes || !(consNo < cell) || apps.has(`${consNo} ${rest}`)) continue;
    lines[at[cell]] = JSON.stringify({ app: { arg: rest, fn: consNo }, ie: cell });
    return { ndjson: lines.join("\n"), person: i, shift: s };
  }
  return null;
}
