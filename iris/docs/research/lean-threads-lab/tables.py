# python3 -I tables.py results/r2.jsonl results/r3.jsonl results/r4.jsonl  -> markdown tables (medians)
import json, sys, statistics

def load(path):
    sec, per = None, {}
    for line in open(path):
        line = line.strip()
        if not line.startswith("{"): continue
        try: d = json.loads(line)
        except Exception: continue
        if "run" in d: sec = d["run"]; continue
        if "bench" not in d: continue
        k = (sec, d["bench"], d.get("variant"), d.get("way"), d.get("W"), d.get("H"), d.get("tasks"))
        per[k] = d   # last (warm) occurrence wins
    return per

runs = [load(p) for p in sys.argv[1:]]
def med(sec, bench, field, variant=None, way=None, W=None, H=None, tasks=None):
    vals = []
    for per in runs:
        d = per.get((sec, bench, variant, way, W, H, tasks))
        if d is not None and isinstance(d.get(field), (int, float)): vals.append(d[field])
    return statistics.median(vals) if vals else None
def rng(sec, bench, field, **kw):
    vals = []
    for per in runs:
        d = per.get((sec, bench, kw.get("variant"), kw.get("way"), kw.get("W"), kw.get("H"), kw.get("tasks")))
        if d is not None and isinstance(d.get(field), (int, float)): vals.append(d[field])
    return vals
def f(x, nd=0):
    if x is None: return "–"
    return f"{x:,.{nd}f}"

SECS = [("native", "native (upstream 4.34, mimalloc)"), ("node-mt", "Node, wasm-mt (dlmalloc)"),
        ("node-mt-mimalloc", "Node, wasm-mt (mimalloc)"), ("node-st", "Node, wasm-st (LeanUI's)"),
        ("chromium-page-mt", "Chromium page, wasm-mt"), ("chromium-page-mt-mimalloc", "Chromium page, wasm-mt (mimalloc)"),
        ("chromium-worker-mt", "Chromium Worker, wasm-mt"), ("chromium-page-st", "Chromium page, wasm-st")]

print("### 4.1 Boot\n")
print("| build | where | load (ms) | Lean init (ms) | RSS (MB) |\n|---|---|--:|--:|--:|")
for sec, label in SECS:
    lm = med(sec, "boot", "loadMs"); li = med(sec, "boot", "leanInitMs"); rss = med(sec, "boot", "rssMB")
    if lm is None: continue
    print(f"| {label} | | {f(lm,1)} | {f(li,1)} | {f(rss,1)} |")

for title, bench, W, H, unit in [("Life 40 × 25, 1,000 generations (LeanUI's board)", "life", 40, 25, "ms"),
                                 ("Life 512 × 512, 50 generations", "life", 512, 512, "ms"),
                                 ("Box blur 640 × 360, r = 2, pure bands (`blurPar`)", "blur-pure", 640, 360, "ms"),
                                 ("Box blur 640 × 360, r = 2, disjoint writes to one C buffer (`blurShared`, ParMap pattern)", "blur-shared-buffer", 640, 360, "ms")]:
    print(f"\n#### {title}\n")
    print("| | 1 task | 2 tasks | 4 tasks | 4-task speed-up |\n|---|--:|--:|--:|--:|")
    for sec, label in SECS:
        a, b, c = (med(sec, bench, "ms", W=W, H=H, tasks=t) for t in (1, 2, 4))
        if a is None: continue
        print(f"| {label} | {f(a)} | {f(b)} | {f(c)} | {a / c:.2f}× |")

print("\n### Sharing costs\n")
print("| | rc: plain counts (ms) | rc: same objects after `markMultiThreaded` (ms) | 1 task over a shared array | 4 tasks, one shared array | 4 tasks, private arrays | first `set!` on a shared 4 MB array (µs) | `markMultiThreaded`, 100k objects (µs) |\n|---|--:|--:|--:|--:|--:|--:|--:|")
for sec, label in SECS:
    st = med(sec, "rc-single-thread", "stMs"); mt = med(sec, "rc-single-thread", "mtMs")
    if st is None: continue
    s1 = med(sec, "rc-k-tasks", "sharedMs", tasks=1); s4 = med(sec, "rc-k-tasks", "sharedMs", tasks=4); p4 = med(sec, "rc-k-tasks", "privateMs", tasks=4)
    cow = med(sec, "cow-after-share", "mtFirstSetUs"); mk = med(sec, "mark-mt", "firstUs")
    print(f"| {label} | {f(st,1)} | {f(mt,1)} | {f(s1,1)} | {f(s4,1)} | {f(p4,1)} | {f(cow)} | {f(mk)} |")

print("\n### Counters: 4 tasks × 1,000,000 increments of one shared counter\n")
ways = ["IO.Ref.modify (take/set)", "IO.Ref get;set (racy)", "Std.Mutex", "C11 fetch_add (faaIncr)", "C11 CAS loop (casIncr)", "per-task shards"]
cs = [s for s in SECS if med(s[0], "counter", "ms", way=ways[0], tasks=4) is not None]
print("| way | " + " | ".join(l for _, l in cs) + " |\n|---|" + "--:|" * len(cs))
for w in ways:
    cells = []
    for sec, _ in cs:
        ms = med(sec, "counter", "ms", way=w, tasks=4)
        got = rng(sec, "counter", "got", way=w, tasks=4)
        lost = "" if all(g == 4000000 for g in got) else " (kept " + "/".join(f"{g / 4e6:.0%}" for g in got) + ")"
        cells.append(f"{f(ms)} ms{lost}")
    print(f"| {w} | " + " | ".join(cells) + " |")

print("\n### Background blur 1280 × 720, r = 2, 4 tasks (Chromium page, main thread)\n")
print("| build | variant | call returned (ms) | result (ms) | frames drawn | longest frame gap (ms) |\n|---|---|--:|--:|--:|--:|")
for sec in ["chromium-bg-mt-mimalloc", "chromium-bg-mt", "chromium-bg-st"]:
    for v in ["naive do-block (pure prefix)", "IO.lazyPure inside IO.asTask"]:
        r = med(sec, "background-blur", "callReturnedMs", variant=v, W=1280, H=720, tasks=4)
        if r is None: continue
        print(f"| {sec.replace('chromium-bg-', 'wasm-')} | {v} | {f(r,1)} | {f(med(sec, 'background-blur', 'resultMs', variant=v, W=1280, H=720, tasks=4))} | {f(med(sec, 'background-blur', 'frames', variant=v, W=1280, H=720, tasks=4))} | {f(med(sec, 'background-blur', 'maxGapMs', variant=v, W=1280, H=720, tasks=4),1)} |")

print("\n### JavaScript and Lean on one SharedArrayBuffer (Node, wasm-mt)\n")
for per in runs:
    for k, d in per.items():
        if k[1] in ("mixed-faa", "spsc-js-to-lean", "spsc-js-producer", "spsc-lean-to-lean") and k[0] in ("node-mt",):
            print("-", json.dumps(d))
