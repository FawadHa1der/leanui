# Research record

The investigations that preceded `iris/`, kept because the design (`../design.md`), its review
(`../critique.md`) and the catalogue (`../js-catalogue.md`) cite their numbers. Every number was
measured on a shared, busy 4-vCPU x86 cloud VM: read them as ratios within one run, to be
re-measured on the reference Mac (ARM, a weaker memory model).

The scripts are a record, not part of the build: they expect the scratchpad layout they were
written in (`../../exec/out`, `../rt`, a copy of iris-lean next to them), so they do not run from
here as they are. The code that replaced them is in `iris/` (`../../README.md`).

| Here | What it is | Was |
|---|---|---|
| `iris-audit.md` | iris-lean as a tool for verified lock-free code: the build, what adequacy guarantees, the seven proofs (now in `../../LeanUIIris/Kernels/`) and the proof-mode friction | `iris-audit.md` |
| `audit-js/` | hand transcriptions of the audit's kernels into JavaScript, with broken variants; `run1.txt` (no start barrier: the racy counter looked correct) and `run2.txt` | `iris-audit/js/` |
| `exec.md` | the execution path: the translator (now `../../LeanUIIris/Translate.lean`), the runtimes (now `../../rt/`), 37 differential tests on three backends, the measurements and the trusted base (G1–G12) | `exec.md` |
| `exec-bench/` | the hand-written JavaScript baselines, the side-by-side harness and its results (`results.md`, `results.json`), the browser run | `exec/bench/` |
| `lean-threads.md` | threads in LeanUI's own Lean → C → wasm64 build: what a threaded runtime takes and costs | `lean-threads.md` |
| `lean-threads-lab/` | the lab program, its FFI, build scripts and the summary tables (the builds themselves are not kept) | `lean-threads/lab/` |
| `catalogue/` | the JavaScript probes behind the catalogue's numbers: `probes/` for Node, `browser/` for Chromium, each with its output | `catalogue/` |
| `critic/` | the review's own measurement: a 3-tap blur with plain accesses against all-`Atomics` accesses | `critic/` |
