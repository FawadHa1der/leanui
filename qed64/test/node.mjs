// The QED64 lane under Node 24 (qed64/README.md, Tests): sessions booted from dist/qed64/ as the
// page boots them (tools/wasm-lean.mjs lane), against the compiled reference
// (qed64/.lake/build/bin/{bench,life}-host), both driven through the host's framing:
//   1. 8 scenarios: Life (reset, then 100 steps) and Bench's keyed operations that only click its
//      buttons (bench/ops.mjs). Every update must be byte-identical to the reference's.
//   2. the ping: 20 empty round trips, each answered with an empty reply; their median is the floor.
//   3. create 10,000 rows with each pthread's stack cut to 0.49 MiB, about what a Chrome Worker has.
// Boot phases and Lean's time per operation are printed, and written with --out; they are not
// checked. Run after qed64/build.sh:
//   "$(qed64/tools/node.sh)" qed64/test/node.mjs [--out <file.json>]
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { OPS } from "../../bench/ops.mjs";

const Q = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const D = path.resolve(Q, "../dist/qed64");
vm.runInThisContext(fs.readFileSync(path.join(Q, "lane/core.js"), "utf8"), { filename: "core.js" });
const { QedCore } = globalThis;
const args = process.argv.slice(2);
const outFile = args.includes("--out") ? args[args.indexOf("--out") + 1] : null;
if (!fs.existsSync(path.join(D, "life/qed64.json"))) { console.error("no dist/qed64: run qed64/build.sh first"); process.exit(2); }

// ---- a host process and its replies ----
const tail = (s, n = 20) => s.trimEnd().split("\n").slice(-n).join("\n");
class Host {
  constructor(name, cmd, argv) {
    this.name = name; this.replies = []; this.wake = null; this.err = ""; this.code = undefined;
    this.p = spawn(cmd, argv, { stdio: ["pipe", "pipe", "pipe"] });
    const parse = new QedCore.Replies((r) => { r.t = performance.now(); this.replies.push(r); this.wake?.(); },
      (line) => { this.err += `stdout: ${line}\n`; });
    this.p.stdout.on("data", (b) => parse.push(b));
    this.p.stderr.on("data", (b) => { this.err += b; });
    this.p.stdin.on("error", () => {});                   // a host that died is reported by next()
    this.p.on("exit", (code, signal) => { this.code = code ?? signal; this.wake?.(); });
  }
  async next(ms = 300e3) {
    const t = setTimeout(() => { this.timedOut = true; this.wake?.(); }, ms);
    try {
      while (!this.replies.length) {
        if (this.code !== undefined || this.timedOut) throw new Error(`${this.name}: ${this.timedOut ? "no reply for " + ms / 1000 + " s" : "exited with " + this.code}\n${tail(this.err)}`);
        await new Promise((ok) => (this.wake = ok));
      }
    } finally { clearTimeout(t); this.wake = null; }
    const r = this.replies.shift();
    if (r.errors.length) throw new Error(`${this.name}: ${r.errors.join("; ")}`);
    return r;
  }
  send(text) { this.t = performance.now(); this.p.stdin.write(text); }
  async quit() {
    this.p.stdin.end("q\n");
    if (this.code === undefined) await new Promise((ok) => this.p.on("exit", ok));
    if (this.code !== 0) throw new Error(`${this.name}: exited with ${this.code}\n${tail(this.err)}`);
  }
}
const reference = (app) => new Host(`${app}-host`, path.join(Q, `.lake/build/bin/${app}-host`), ["--out", "raw"]);
const lane = (app, extra = []) => new Host(`lane ${app}${extra.length ? " " + extra.join(" ") : ""}`, process.execPath,
  ["--stack-size=8192", path.join(Q, "tools/wasm-lean.mjs"), "lane", path.join(D, app, "qed64.json"), ...extra]);

// ---- a session: what the updates say (element ids, their click slots), the scenarios ----
// the patch words (docs/PROTOCOL.md): each op's length, but 20 and 21 (3 + their count)
const SIZE = { 1: 4, 2: 4, 3: 5, 4: 3, 5: 5, 6: 4, 7: 5, 8: 3, 9: 4, 10: 3, 11: 4, 12: 2, 13: 3, 14: 2, 15: 6, 16: 3, 17: 4, 18: 4, 19: 5,
  32: 10, 33: 3, 34: 3, 35: 2, 36: 5, 37: 4, 38: 3, 39: 3, 40: 3, 41: 2, 42: 3, 43: 3, 44: 3, 45: 2, 46: 3, 47: 3, 48: 10, 49: 3, 50: 3, 51: 6, 52: 2, 53: 4, 54: 3 };
const utf8 = new TextDecoder();
class Session {
  constructor(host) { this.host = host; this.names = [""]; this.idOf = new Map(); this.clickOf = new Map(); }
  read(u) {
    const view = new DataView(u.buffer, u.byteOffset, u.length), opsLen = view.getUint32(0, true);
    const w = new Uint32Array(u.slice(4, 4 + opsLen).buffer), text = utf8.decode(u.subarray(4 + opsLen));
    const S = (i) => text.substr(w[i], w[i + 1]);
    for (let i = 0; i < w.length;) {
      const op = w[i];
      if (op === 17) this.names[w[i + 1]] = S(i + 2);
      else if ((op === 3 || op === 5) && this.names[w[i + 2]] === "id") this.idOf.set(S(i + 3), w[i + 1]);
      else if (op === 15 && this.names[w[i + 2]] === "click") this.clickOf.set(w[i + 1], w[i + 3]);
      else if (op === 14) this.clickOf.delete(w[i + 1]);
      if (op === 20 || op === 21) i += 3 + w[i + 2];
      else if (SIZE[op]) i += SIZE[op];
      else throw new Error(`unknown patch op ${op} at word ${i}`);
    }
  }
  take(r, hash) { for (const u of r.updates) { this.read(u); hash?.update(u); } return r; }
  async boot() { const r = await this.host.next(); this.take(r, this.hash = createHash("sha256")); return { leanMs: r.leanNs / 1e6, sha256: this.hash.digest("hex") }; }
  async click(id, hash) {
    const node = this.idOf.get(id), slot = node && this.clickOf.get(node);
    if (!slot) throw new Error(`${this.host.name}: no click listener on #${id}`);
    this.host.send(`e ${slot} 0\n`);
    const r = this.take(await this.host.next(), hash);
    return { leanMs: r.leanNs / 1e6, wallMs: r.t - this.host.t, updates: r.updates };
  }
  // one scenario: its clicks in order; the hash covers every update, the times the timed clicks
  async run({ name, clicks, timed }) {
    const hash = createHash("sha256"), leanMs = [], wallMs = [];
    let updates = 0, bytes = 0, last = null;
    for (let i = 0; i < clicks.length; i++) {
      last = await this.click(clicks[i], hash);
      updates += last.updates.length; bytes += last.updates.reduce((n, u) => n + u.length, 0);
      if (timed(i)) { leanMs.push(last.leanMs); wallMs.push(last.wallMs); }
    }
    return { name, updates, bytes, sha256: hash.digest("hex"), leanMs, wallMs, last };
  }
  async ping(n) {
    const ms = [];
    for (let i = 0; i < n; i++) {
      this.host.send("p\n");
      const r = await this.host.next();
      if (r.updates.length) throw new Error(`${this.host.name}: a ping got ${r.updates.length} updates`);
      ms.push(r.t - this.host.t);
    }
    return ms;
  }
}
const LIFE = { name: "100 steps", clicks: ["reset", ...Array(100).fill("step")], timed: (i) => i > 0 };
const keyed = (names) => OPS.filter((o) => names.includes(o.name)).map((o) => ({
  name: o.name, clicks: [...o.warm, o.click].map((s) => s.replace(/^#/, "")), timed: (i) => i === o.warm.length }));
// Bench's operations that click only its buttons (select and remove click rows)
const BENCH = keyed(["create1k", "replace1k", "update10th", "swap", "create10k", "append1k", "clear1k"]);

async function drive(host, scenarios, pings = 0) {
  const s = new Session(host), t0 = performance.now(), results = [];
  let boot, ping = null;
  try {
    boot = await s.boot();
    boot.wallMs = performance.now() - t0;
    for (const sc of scenarios) results.push(await s.run(sc));
    if (pings) ping = await s.ping(pings);
    await host.quit();
  } catch (e) { host.p.kill(); throw e; }
  const phases = host.err.match(/^qed64 phases (.*)$/m);
  return { boot: { ...boot, phases: phases ? JSON.parse(phases[1]) : undefined }, results, ping };
}

// ---- the runs ----
const median = (a) => { const s = a.slice().sort((x, y) => x - y); return s.length ? s[s.length >> 1] : NaN; };
const f1 = (x) => (Number.isFinite(x) ? x.toFixed(1) : "-");
const checks = [];
const check = (name, ok, detail = "") => { checks.push({ name, ok: !!ok, detail }); console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : ": " + detail}`); };
const report = { date: new Date().toISOString(), node: process.version, note: "times from the machine this ran on; CI machine numbers are to be re-measured on the reference Mac", sessions: {} };
const t0 = performance.now();
try {
  const sessions = [
    ["life", LIFE, [], 0],
    ["bench", BENCH, [], 20],
    ["bench", keyed(["create10k"]), ["--stack-mb", "0.49"], 0],
  ];
  for (const [app, scenarios, extra, pings] of sessions) {
    const sc = Array.isArray(scenarios) ? scenarios : [scenarios];
    const key = app + (extra.length ? " " + extra.join(" ") : "");
    const ref = await drive(reference(app), sc);
    let got;
    try { got = await drive(lane(app, extra), sc, pings); }
    catch (e) { check(`${key}: the lane ran`, false, e.message); continue; }
    check(`${key}: the mount is byte-identical`, got.boot.sha256 === ref.boot.sha256, `${got.boot.sha256} vs ${ref.boot.sha256}`);
    for (let i = 0; i < sc.length; i++) {
      const [a, b] = [got.results[i], ref.results[i]];
      check(`${key}: ${a.name}: ${a.updates} updates, ${a.bytes} bytes, byte-identical (sha256 ${a.sha256.slice(0, 12)})`,
        a.sha256 === b.sha256 && a.updates === b.updates, `the reference's ${b.updates} updates, ${b.bytes} bytes, ${b.sha256.slice(0, 12)}`);
    }
    if (app === "life") {
      const board = got.results[0].last.updates.some((u) => utf8.decode(u).includes("bdbe4aa6"));
      check("life: after 100 steps the board is bdbe4aa6, as natively (tests/browser/race.mjs)", board);
    }
    if (pings) check(`${key}: ${pings} pings, each an empty reply`, got.ping.length === pings);
    report.sessions[key] = {
      boot: { ...got.boot, sha256: undefined, referenceLeanMs: ref.boot.leanMs },
      floorMs: got.ping ? median(got.ping) : undefined,
      ops: Object.fromEntries(got.results.map((r, i) => [r.name, { updates: r.updates, bytes: r.bytes, sha256: r.sha256,
        leanMs: median(r.leanMs), wallMs: median(r.wallMs), referenceLeanMs: median(ref.results[i].leanMs) }])),
    };
    const s = report.sessions[key];
    console.log(`     boot ${f1(got.boot.wallMs)} ms (${Object.entries(got.boot.phases || {}).map(([k, v]) => `${k} ${f1(v)}`).join(", ")})` +
      (s.floorMs !== undefined ? `; ping floor ${f1(s.floorMs)} ms` : ""));
    for (const [name, o] of Object.entries(s.ops))
      console.log(`     ${name.padEnd(10)} Lean ${f1(o.leanMs).padStart(7)} ms (compiled ${f1(o.referenceLeanMs)}), click to reply ${f1(o.wallMs)} ms (median)`);
  }
} catch (e) { check("the run", false, e.stack); }
report.checks = checks;
report.seconds = +((performance.now() - t0) / 1000).toFixed(1);
if (outFile) fs.writeFileSync(outFile, JSON.stringify(report, null, 1) + "\n");
const ok = checks.length && checks.every((c) => c.ok);
console.log(`${ok ? "PASS" : "FAIL"} (${report.seconds} s)`);
process.exit(ok ? 0 : 1);
