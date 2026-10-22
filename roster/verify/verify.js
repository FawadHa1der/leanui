// The Roster verify page (index.html; roster/README.md). It checks a receipt with nanoda in a
// Worker (worker.js), judges the verdict by the four checks of receipt.js, and shows the table the
// receipt proves valid and what was proved. The receipt is `?receipt=<url>` (the app links here
// so) or a file chosen or dropped. "Tamper" flips one cell of the receipt's data and checks it
// again: it must be rejected. The latest outcome is left in `window.__verify` (with `n`, how many
// so far) for tests/browser/roster-verify.mjs.
import { DATA, PRINT, TITLES, judge, tamper } from "./receipt.js";

const $ = (id) => document.getElementById(id);
const reference = fetch("reference.json").then((r) => (r.ok ? r.json() : null), () => null);
const worker = new Worker("worker.js", { type: "module" });

// one check at a time: the controls are disabled meanwhile
let answer = () => {};
worker.onmessage = ({ data }) => answer(data);
worker.onerror = (e) => answer({ ok: false, error: "the checker did not start: " + (e.message || "worker error") });
const check = (ndjson) => new Promise((resolve) => {
  answer = resolve;
  worker.postMessage({ ndjson, names: PRINT, data: DATA });
});

// the receipt as loaded: {ndjson, label, table, verified}
let original = null;

const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
};
/** `e`, now showing `text`, in which `backquoted` parts are code. */
const rich = (e, text) => {
  e.replaceChildren(...text.split("`").map((part, i) => (i % 2 ? el("code", null, part) : part)));
  return e;
};
const status = (text) => { $("status").textContent = text; };
const megabytes = (s) => `${(s.length / 1e6).toFixed(1)} MB`;

function busy(on, tampered) {
  $("file").disabled = on;
  $("tamper").parentElement.hidden = !original?.verified;
  $("tamper").disabled = on || tampered || !original?.verified;
  $("original").hidden = !tampered;
  $("original").disabled = on;
}

/** Check `ndjson` and show the outcome; `flipped` is the cell tamper flipped, if it did. */
async function verify(ndjson, label, flipped = null) {
  busy(true, !!flipped);
  status(`Checking ${label} (${megabytes(ndjson)})…`);
  const verdict = await check(ndjson);
  const ref = await reference;
  const result = judge(verdict, ref);
  show(result, ref, flipped);
  status(`${label} (${megabytes(ndjson)})`);
  window.__verify = { n: (window.__verify?.n ?? 0) + 1, verified: result.verified, checks: result.checks.map((c) => c.ok), ms: verdict.ms, flipped: !!flipped };
  busy(false, !!flipped);
  return result;
}

function show({ checks, table, verified }, ref, flipped) {
  const v = $("verdict");
  v.hidden = false;
  v.className = "verdict " + (verified ? "verified" : "rejected");
  $("headline").textContent = verified ? "Verified: this roster is valid."
    : flipped ? "Rejected, as it must be: the receipt was changed."
    : "Rejected: this receipt does not prove the roster valid.";
  $("checks").replaceChildren(...checks.map((c, i) => {
    const li = el("li", c.ok ? "pass" : c.ok === false ? "fail" : "skip");
    li.append(el("span", "mark", c.ok ? "✓" : c.ok === false ? "✗" : "–"));
    const p = rich(el("p"), c.text);
    p.prepend(el("b", null, TITLES[i] + ". "));
    li.append(p);
    return li;
  }));
  // why, in plain words, where the checks' sentences are terse
  const why = $("why");
  why.replaceChildren();
  if (flipped && !checks[0].ok && table) {
    const who = table.people[flipped.person] ?? `person ${flipped.person}`, shift = table.shifts[flipped.shift] ?? `shift ${flipped.shift}`;
    rich(why, `Why: the roster puts ${who} on ${shift}, and the data now says they cannot do it. The proof ` +
      "was a computation (`decide`): the kernel runs `checkRoster` on the data, now gets `false` instead of " +
      "`true`, so the proof no longer checks. Nothing else in the receipt changed.");
  } else if (checks[2].ok === false) {
    rich(why, "Why it matters: a receipt brings its own copy of every definition it uses. With other " +
      "definitions, its `Roster.Problem.Valid` does not mean the published one, so its proof says nothing " +
      "about this roster, though the kernel accepts it.");
  }
  why.hidden = !why.childNodes.length;

  $("data").hidden = !table;
  if (table) {
    $("data-title").textContent = verified ? "The roster it proves valid"
      : flipped ? "The data, with the flipped cell outlined" : "What the receipt claims (not proved)";
    grid(table, flipped);
  }
  // the published definition, which check 3 found the receipt's to be
  $("proved").hidden = !(verified && ref?.valid);
  if (ref?.valid) $("valid").textContent = ref.valid;
}

/** The problem as a grid, people × shifts, with the roster on it. */
function grid({ people, shifts, need, avail, roster }, flipped) {
  const row = (head, cells) => { const tr = el("tr"); tr.append(head, ...cells); return tr; };
  const th = (text, scope) => { const e = el("th", null, text); if (scope) e.scope = scope; return e; };
  const gets = shifts.map((_, s) => roster.filter((x) => x === s).length);
  const thead = el("thead"), tbody = el("tbody");
  thead.append(
    row(el("th"), shifts.map((name) => th(name, "col"))),
    row(th("Needs", "row"), shifts.map((_, s) => el("td", "need", String(need[s] ?? 0)))),
    row(th("Gets", "row"), shifts.map((_, s) => el("td", "count" + (gets[s] < (need[s] ?? 0) ? " short" : ""), String(gets[s])))));
  people.forEach((name, i) => {
    tbody.append(row(th(name, "row"), shifts.map((_, s) => {
      const can = avail[i]?.[s] === true, works = roster[i] === s;
      const cell = el("div", "cell" + (can ? " can" : "") + (works ? " works" : "") + (works && !can ? " bad" : "") +
        (flipped?.person === i && flipped?.shift === s ? " flipped" : ""), works ? (can ? "✓" : "✗") : "");
      cell.title = `${name}, ${shifts[s]}: ${works ? "works it" : can ? "can do it" : "can't do it"}${works && !can ? ", but can't do it" : ""}`;
      const td = el("td");
      td.append(cell);
      return td;
    })));
  });
  $("grid").replaceChildren(thead, tbody);
}

async function load(get, label) {
  status(`Loading ${label}…`);
  let ndjson;
  try {
    ndjson = await get();
  } catch (e) {
    status(`Could not load ${label}: ${e.message}`);
    return;
  }
  original = { ndjson, label };
  const { table, verified } = await verify(ndjson, label);
  Object.assign(original, { table, verified });
  busy(false, false);
}

$("tamper").onclick = () => {
  const t = tamper(original.ndjson, original.table);
  if (!t) status("No cell of this receipt can be flipped without rewriting the receipt.");
  else verify(t.ndjson, "The receipt with one cell flipped", t);
};
$("original").onclick = () => verify(original.ndjson, original.label);
$("file").onchange = () => { const f = $("file").files[0]; if (f) load(() => f.text(), f.name); };
document.addEventListener("dragover", (e) => { e.preventDefault(); document.body.classList.add("dropping"); });
document.addEventListener("dragleave", () => document.body.classList.remove("dropping"));
document.addEventListener("drop", (e) => {
  e.preventDefault();
  document.body.classList.remove("dropping");
  const f = e.dataTransfer.files[0];
  if (f && !$("file").disabled) load(() => f.text(), f.name);
});

reference.then((r) => {
  if (r) rich($("reference"), `\`${r.source}\` (SHA-256 ${r.sha256.slice(0, 12)}…), exported with Lean ${r.lean}`);
});
const url = new URLSearchParams(location.search).get("receipt");
if (url) load(async () => {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
  return r.text();
}, url);
else status("No receipt yet.");
