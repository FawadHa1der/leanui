# Usage: closure.py <src root> <module>...   prints the import closure (modules under Init/Std/Lean)
import re, sys, os
root = sys.argv[1]
todo = list(sys.argv[2:]); seen = set()
imp = re.compile(r'^\s*(?:public\s+|private\s+)?(?:meta\s+)?import\s+(?:all\s+)?([A-Za-z0-9_.]+)', re.M)
while todo:
    m = todo.pop()
    if m in seen: continue
    seen.add(m)
    f = os.path.join(root, *m.split('.')) + '.lean'
    if not os.path.exists(f): print('missing', m, file=sys.stderr); continue
    src = open(f, encoding='utf-8').read()
    # stop at the end of the header: first line that is not import/module/prelude/comment/blank
    for x in imp.findall(src.split('\nnamespace')[0][:20000]):
        if x.split('.')[0] in ('Init', 'Std', 'Lean', 'Lake'):
            todo.append(x)
    if m != 'Init' and m.startswith('Init') is False and 'prelude' not in src[:3000]:
        todo.append('Init')
print('\n'.join(sorted(seen)))
