// Forged receipts, for the verify page's tests: a good receipt with something it relies on
// redefined, consistently enough that the kernel still accepts it. Only the comparison with the
// published source (check 3, receipt.js) can catch them.
//   forgeCount(ndjson): `List.count` counts every element (it becomes `List.length`), and nobody
//   works: every shift seems to get as many people as the roster has entries, so this empty
//   roster passes `Valid` (if no shift needs more people than there are).
// It edits the receipt's expressions as a graph and writes it out again, numbered afresh: names
// and levels first, then before each declaration the expressions it needs that are not out yet
// (as Lean's exporter does), each once.

const EXPR = { app: ["fn", "arg"], forallE: ["type", "body"], lam: ["type", "body"], letE: ["type", "value", "body"], proj: ["struct"] };
const kind = (r) => Object.keys(r).find((k) => k !== "ie");

/** The receipt as {head: [meta, name and level lines], declars: [lines]}, the declarations'
    expressions as nodes: {kind: content}, with their subexpressions as nodes. */
function read(ndjson) {
  const head = [], exprs = [], declars = [];
  for (const line of ndjson.split("\n")) {
    if (!line) continue;
    const r = JSON.parse(line);
    if ("ie" in r) {
      const k = kind(r), node = { [k]: EXPR[k] ? { ...r[k] } : r[k] }; // `{"bvar":0}`, `{"sort":1}`, …: no subexpressions
      for (const f of EXPR[k] ?? []) node[k][f] = exprs[r[k][f]];
      exprs[r.ie] = node;
    } else if ("in" in r || "il" in r || "meta" in r) head.push(r);
    else declars.push(mapDeclar(r, (e) => exprs[e]));
  }
  return { head, declars };
}

// a declaration line with its expressions mapped by `f`
function mapDeclar(r, f) {
  const k = kind(r);
  const each = (x) => ({ ...x, type: f(x.type), ...("value" in x && { value: f(x.value) }),
    ...(x.rules && { rules: x.rules.map((rule) => ({ ...rule, rhs: f(rule.rhs) })) }) });
  const { ctors, recs, types } = r[k];
  return { [k]: k === "inductive" ? { ctors: ctors.map(each), recs: recs.map(each), types: types.map(each) } : each(r[k]) };
}

function write({ head, declars }) {
  const out = head.map((r) => JSON.stringify(r)), index = new Map(), byContent = new Map();
  const emit = (node) => {
    if (index.has(node)) return index.get(node);
    const k = kind(node);
    let content = node[k];
    if (EXPR[k]) {
      // keys in order, as Lean's exporter writes them: equal nodes must give equal lines
      content = {};
      for (const f of Object.keys(node[k]).sort()) content[f] = EXPR[k].includes(f) ? emit(node[k][f]) : node[k][f];
    }
    const key = JSON.stringify([k, content]);
    let i = byContent.get(key);
    if (i === undefined) {
      i = byContent.size;
      byContent.set(key, i);
      out.push(JSON.stringify({ [k]: content, ie: i }));
    }
    index.set(node, i);
    return i;
  };
  for (const d of declars) {
    const line = mapDeclar(d, emit); // the expressions first, then the declaration
    out.push(JSON.stringify(line));
  }
  return out.join("\n") + "\n";
}

export function forgeCount(ndjson) {
  const receipt = read(ndjson);
  const names = [""];
  for (const r of receipt.head) if ("in" in r) names[r.in] = r.str ? (r.str.pre ? names[r.str.pre] + "." : "") + r.str.str : names[r.num.pre] + "." + r.num.i;
  const nameId = (n) => names.indexOf(n);
  const count = receipt.declars.find((d) => d.def && names[d.def.name] === "List.count").def;
  // count : {α : Type u} → [BEq α] → α → List α → Nat; it becomes fun α inst a l => @List.length α l,
  // with the binders of its type
  const binders = [];
  for (let t = count.type; t.forallE; t = t.forallE.body) binders.push(t.forallE);
  const u = count.levelParams.map((p) => receipt.head.find((r) => r.param === p).il);
  let value = { app: { fn: { app: { fn: { const: { name: nameId("List.length"), us: u } }, arg: { bvar: 3 } } }, arg: { bvar: 0 } } };
  for (const b of binders.reverse()) value = { lam: { binderInfo: b.binderInfo, body: value, name: b.name, type: b.type } };
  count.value = value;
  // every `@Option.some Nat s` in the roster becomes `@Option.none Nat`, whatever the list's
  // shape (Lean writes a long list literal with `let`s)
  const done = new Map();
  const empty = (node) => {
    if (!node.app && !node.letE) return node;
    if (!done.has(node)) {
      const some = node.app?.fn.app, isSome = some?.fn.const && names[some.fn.const.name] === "Option.some";
      done.set(node, isSome ? { app: { fn: { const: { ...some.fn.const, name: nameId("Option.none") } }, arg: some.arg } }
        : node.app ? { app: { fn: empty(node.app.fn), arg: empty(node.app.arg) } }
        : { letE: { ...node.letE, value: empty(node.letE.value), body: empty(node.letE.body) } });
    }
    return done.get(node);
  };
  const roster = receipt.declars.find((d) => d.def && names[d.def.name] === "Roster.Receipt.roster").def;
  roster.value = empty(roster.value);
  return write(receipt);
}
