// Differential test: translated JS (real threads) vs (a) hand-derived HeapLang result and
// (b) the Lean reference interpreter (Exec/Interp.lean, random schedules, 3 seeds).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'out/manifest.json'), 'utf8'));
const REPEAT = Number(process.argv[2] || 3);
const BACKEND = process.argv[3] || 'js';           // js | native | wasm
let pass = 0, fail = 0, notes = 0;
function runJs(name) {
  try {
    const [cmd, args] = BACKEND === 'native' ? [path.join(root, 'out/native', name), ['8', '1']]
      : BACKEND === 'wasm' ? ['node', [path.join(root, 'out/wasm', name + '.js'), '8', '1']]
      : ['node', [path.join(root, 'rt/run.mjs'), path.join(root, 'out', name + '.mjs'), '--pool', '4', '--json']];
    const out = execFileSync(cmd, args, { encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'pipe'] });
    return String(JSON.parse(out).result).replace(/<closure code \d+>/g, '<closure>');
  } catch (e) {
    const j = (() => { try { return JSON.parse(e.stdout); } catch { return null; } })();
    const k = (() => { try { return JSON.parse(String(e.stderr).trim().split('\n').pop()); } catch { return null; } })();
    return (j && j.trap) || (k && k.trap) ? 'TRAP' : 'ERROR ' + (e.stderr || e.message).slice(0, 200);
  }
}
for (const m of manifest.filter(m => /^(test|conc)_/.test(m.name))) {
  const interp = (m.interp || []).filter(r => r !== 'OUT OF FUEL');
  const interpAgree = interp.length && interp.every(r => r === interp[0]) ? interp[0] : null;
  const ref = m.expect ?? interpAgree;
  const got = [];
  for (let i = 0; i < (m.name.startsWith('conc_') ? REPEAT : 1); i++) got.push(runJs(m.name));
  let verdict;
  if (m.name === 'conc_counter_racy') { verdict = 'NOTE'; notes++; }
  else if (ref === 'TRAP') { verdict = got.every(g => g === 'TRAP') ? 'PASS' : 'FAIL'; }
  else verdict = got.every(g => g === ref) ? 'PASS' : 'FAIL';
  if (verdict === 'PASS') pass++; else if (verdict === 'FAIL') fail++;
  const gap = (m.expect && interpAgree && m.expect !== interpAgree) ? `  [HeapLang semantics says ${interpAgree}]` : '';
  console.log(`${verdict}  ${m.name.padEnd(28)} ref ${String(ref).padEnd(24)} interp ${JSON.stringify(m.interp)}  js ${JSON.stringify(got)}${gap}`);
}
console.log(`\n[${BACKEND}] ${pass} passed, ${fail} failed, ${notes} notes`);
process.exit(fail ? 1 : 0);
