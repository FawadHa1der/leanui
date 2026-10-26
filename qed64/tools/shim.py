#!/usr/bin/env python3
"""Write qed64/.shim/: LeanUI's core (LeanUI.lean and the LeanUI modules it imports) as lean.wasm
compiles it for the lane, with four edits:

  * LeanUI.pushU32 and LeanUI.appendUtf8 (LeanUI/Patch.lean) lose `@[extern c inline ...]` and
    become plain `@[inline, expose]` definitions. Lean's interpreter has no code for an inline-C
    extern and cannot load a native library in wasm; their Lean bodies are LeanUI's own
    specification of the two, so the bytes they write are the same. `@[inline]` stays: without it
    the interpreted create-1,000-rows takes 11% longer.
  * `public import Std.Data.HashMap` becomes `public import Std.Data.HashMap.Basic` (Patch.lean,
    Keyed.lean), all that LeanUI uses of it: its closure is 8 Std modules instead of 134, and
    lean.wasm compiles those 8 itself (tools/bake.sh).

Each edit must apply exactly once, and no `@[extern` may be left anywhere: if the sources change,
the shim refuses and must be looked at again.
  python3 -I qed64/tools/shim.py <repository root> <out dir>
"""
import os, re, shutil, sys

root, out = sys.argv[1], sys.argv[2]
EXTERN = r'@\[extern c inline "(?:[^"\\]|\\.)*", expose\]\ndef {} '
EDITS = [  # (file, pattern, replacement)
    ("LeanUI/Patch.lean", EXTERN.format("pushU32"), "@[inline, expose]\ndef pushU32 "),
    ("LeanUI/Patch.lean", EXTERN.format("appendUtf8"), "@[inline, expose]\ndef appendUtf8 "),
    ("LeanUI/Patch.lean", r"^public import Std\.Data\.HashMap$", "public import Std.Data.HashMap.Basic"),
    ("LeanUI/Keyed.lean", r"^public import Std\.Data\.HashMap$", "public import Std.Data.HashMap.Basic"),
]

def module_file(m):
    return os.path.join(*m.split(".")) + ".lean"

# LeanUI.lean and the LeanUI modules it imports, transitively
files, todo = {}, ["LeanUI"]
while todo:
    f = module_file(todo.pop())
    if f in files: continue
    files[f] = open(os.path.join(root, f), encoding="utf-8").read()
    todo += re.findall(r"^(?:public )?(?:meta )?import (?:all )?(LeanUI(?:\.\w+)*)\s*$", files[f], re.M)

for f, pat, new in EDITS:
    if f not in files: sys.exit(f"shim.py: {f} is no longer part of LeanUI's core")
    files[f], n = re.subn(pat, lambda m: new, files[f], flags=re.M | re.S)
    if n != 1: sys.exit(f"shim.py: expected {pat!r} once in {f}, found it {n} times")
for f, s in files.items():
    if "@[extern" in s: sys.exit(f"shim.py: {f} still has an @[extern")

tmp = out + ".tmp"
shutil.rmtree(tmp, ignore_errors=True)
for f, s in files.items():
    os.makedirs(os.path.dirname(os.path.join(tmp, f)), exist_ok=True)
    open(os.path.join(tmp, f), "w", encoding="utf-8").write(s)
shutil.rmtree(out, ignore_errors=True)
os.rename(tmp, out)
print(f"{out}: LeanUI's core, {len(files)} modules, with {len(EDITS)} edits")
