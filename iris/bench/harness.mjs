// node iris/bench/harness.mjs [--scenarios s1,s2,s4,s5,s11] [--w 1,2,4,8] [--fuzz off,on]
//                             [--quick] [--lanes a,b] [--json FILE]
// Runs the side-by-side scenarios (iris/README.md, "The scenarios") after iris/build.sh: every
// lane at every thread count W, with fuzz-mode delays off and on, then prints one table per
// scenario and writes the rows as JSON. Exit status 1 if a verified lane (L3, L4) shows a
// violation, an error or a hang it should not; the broken lanes' violations are recorded only.
import fs from 'node:fs';
import { nodeHost } from './host-node.mjs';
import { runScenario, table } from './core.mjs';
import { verdict } from './chips.mjs';

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const list = (k, d) => opt(k, d).split(',').filter(Boolean);
const quick = args.includes('--quick');
const ids = list('--scenarios', 's1,s2,s4,s5,s11');
const Ws = list('--w', quick ? '1,4' : '1,2,4,8').map(Number);
const fuzz = list('--fuzz', 'off,on').map((f) => f === 'on');
const lanes = opt('--lanes') ? list('--lanes') : undefined;

const host = nodeHost();
const out = { generated_by: 'iris/bench/harness.mjs', machine: { env: 'node', node: process.version, cores: host.cores, platform: `${process.platform} ${process.arch}` },
  note: 'CI machine numbers: read them as ratios within one run; re-measure on the reference Mac',
  started: new Date().toISOString(), quick, Ws, scenarios: [] };
let bad = 0;
for (const id of ids) {
  const sc = await import(`./scenarios/${id}.mjs`);
  console.log(`\n${sc.title}\n${sc.question}`);
  const rows = await runScenario(host, sc, { Ws, fuzz, quick, lanes, onRow: (r) => process.stderr.write('.') });
  process.stderr.write('\n');
  console.log(table(sc, rows));
  for (const r of rows) {
    const v = verdict(sc, r);
    if (v) { bad++; console.log(`FAIL  ${sc.id} ${r.lane} W=${r.W}${r.fuzz ? ' fuzz' : ''}: ${v}`); }
  }
  out.scenarios.push({ id: sc.id, title: sc.title, rows });
}
host.pool.close();
out.finished = new Date().toISOString();
const file = opt('--json');
if (file) { fs.writeFileSync(file, JSON.stringify(out, null, 1) + '\n'); console.log(`\nwrote ${file}`); }
console.log(bad ? `\n${bad} verified-lane failures` : '\nverified lanes: 0 violations');
process.exit(bad ? 1 : 0);
