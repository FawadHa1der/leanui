# python3 -I summarize.py results/r*.jsonl
# Per run file: sections start at {"run": ...}; within a section the LAST line for a key wins (the
# warmed-up pass). Across files: median of every numeric field, plus min/max of "ms".
import json, sys, statistics
from collections import defaultdict

KEYS = ("bench", "variant", "way", "W", "H", "r", "gens", "tasks", "n", "reps", "count", "leanTasks", "jsWorkers", "perThread", "perTask", "build", "where", "suite", "bytes", "objects")
runs = []
for path in sys.argv[1:]:
    sec, cur = None, {}
    per = {}
    for line in open(path):
        line = line.strip()
        if not line.startswith("{"): continue
        try: d = json.loads(line)
        except Exception: continue
        if "run" in d:
            sec = d["run"]; per.setdefault(("load", sec), d.get("load")); continue
        if "bench" not in d: continue
        key = (sec,) + tuple((k, d[k]) for k in KEYS if k in d)
        per[key] = d
    runs.append(per)

allkeys = []
for per in runs:
    for k in per:
        if k not in allkeys: allkeys.append(k)
for k in allkeys:
    if k[0] == "load":
        print("# load", k[1], [per.get(k) for per in runs]); continue
    ds = [per[k] for per in runs if k in per]
    fields = {}
    for f in ds[0]:
        vals = [d.get(f) for d in ds]
        if all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in vals):
            m = statistics.median(vals)
            fields[f] = round(m, 2) if isinstance(m, float) else m
            if f in ("ms", "sharedMs", "privateMs", "stMs", "mtMs", "resultMs", "maxGapMs") and len(vals) > 1:
                fields[f + "_range"] = [min(vals), max(vals)]
        elif f not in KEYS:
            fields[f] = vals[0] if len(set(map(str, vals))) == 1 else vals
    label = " ".join(f"{a}={b}" for a, b in k[1:])
    print(f"[{k[0]}] {label} :: n={len(ds)} " + json.dumps(fields))
