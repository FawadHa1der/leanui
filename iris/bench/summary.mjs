// node iris/bench/summary.mjs <harness.json> [--readme]
// Turns the harness's JSON into one Markdown table per scenario: throughput at each W (fuzz off),
// CPU time per operation at the largest W, every violation seen in any run (fuzz on or off), and
// the lane's note. With --readme it replaces the part of iris/README.md between the
// "results:begin" and "results:end" markers instead of printing.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { KINDS } from './chips.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const [file, ...flags] = process.argv.slice(2);
if (!file) { console.error('usage: node iris/bench/summary.mjs <harness.json> [--readme]'); process.exit(64); }
const run = JSON.parse(fs.readFileSync(file, 'utf8'));
const md = (s) => String(s).replace(/\|/g, '\\|');

const out = [];
out.push(`Measured ${run.started.slice(0, 10)} on ${run.machine.platform}, ${run.machine.cores} logical cores, Node ${run.machine.node}` +
  `${run.quick ? ', short runs' : ''}. ${run.note[0].toUpperCase()}${run.note.slice(1)}.`);
for (const s of run.scenarios) {
  const sc = await import(`./scenarios/${s.id}.mjs`);
  const Ws = [...new Set(s.rows.map((r) => r.W))].sort((a, b) => a - b);
  const maxW = Math.max(...run.Ws);
  out.push('', `**${sc.title}**`, '', `| lane | kind | ${Ws.map((w) => `W=${w}`).join(' | ')} | CPU ns/op (W=${maxW}) | fairness (W=${maxW}) | violations, all runs | note |`,
    `|---|---|${Ws.map(() => '--:').join('|')}|--:|--:|---|---|`);
  for (const lane of sc.lanes) {
    const rows = s.rows.filter((r) => r.lane === lane.id);
    if (!rows.length) continue;
    const off = rows.filter((r) => !r.fuzz);
    const cell = (w) => {
      const r = off.find((x) => x.W === w);
      if (!r) return '';
      if (r.skipped) return 'skipped';
      if (r.error) return 'error';
      if (r.trap) return 'trap';
      if (r.hung) return 'hung';
      if (r.ops_per_us == null) return lane.noSpeed ? '—' : '';
      return r.ops_per_us < 1 ? r.ops_per_us.toFixed(3) : r.ops_per_us.toFixed(1);
    };
    const big = off.filter((r) => !r.skipped).sort((a, b) => b.W - a.W)[0] || rows[0];
    const viol = {};
    for (const r of rows) for (const [k, n] of Object.entries(r.violations || {})) viol[k] = (viol[k] || 0) + n;
    const v = Object.entries(viol).filter(([, n]) => n).map(([k, n]) => `${k.replace(/_/g, ' ')} ${n}`).join(', ') || (rows.every((r) => r.skipped) ? '' : '0');
    const note = big.skipped ? big.skipped : big.trap ? `trap: ${big.trap}` : big.error ? `error: ${String(big.error).split('\n')[0]}`
      : lane.note ? lane.note(big) : (big.extra?.after_kill || '');
    const atMax = big.W === maxW; // a lane that never ran at the largest W leaves these two cells empty
    out.push(`| ${md(lane.label)} | ${lane.kind} | ${Ws.map((w) => cell(w)).join(' | ')} | ${atMax ? big.cpu_ns_per_op ?? '' : ''} | ${atMax ? big.fairness ?? '' : ''} | ${md(v)} | ${md(note)} |`);
  }
}
out.push('', `Kinds: ${Object.entries(KINDS).map(([k, t]) => `${k} ${t}`).join('; ')}. "—": not shown (a broken lane's speed means nothing). ` +
  'Throughput is operations per microsecond, all threads together, fuzz off; S4 counts samples, S5 pixels, S11 wakeups. ' +
  'Fairness is Jain\'s index over the threads\' counts (1: equal shares).');

const text = out.join('\n');
if (flags.includes('--readme')) {
  const readme = path.join(here, '../README.md');
  const r = fs.readFileSync(readme, 'utf8');
  const a = r.indexOf('<!-- results:begin -->'), b = r.indexOf('<!-- results:end -->');
  if (a < 0 || b < a) { console.error('README.md has no results markers'); process.exit(1); }
  fs.writeFileSync(readme, r.slice(0, a) + '<!-- results:begin -->\n' + text + '\n' + r.slice(b));
  console.log(`updated ${readme}`);
} else console.log(text);
