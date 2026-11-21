# Threads in LeanUI's own wasm (Lean → C → wasm64), and where iris-lean fits

> Kept from the research that preceded `iris/`. Paths starting `<scratchpad>/iris/` or `iris/`
> name the research scratchpad, which no longer exists: the evidence they cite is in this
> directory (`README.md` maps it), and the code is now in `iris/` itself (`../../README.md`).

Written 2026-11-20 on a 4-vCPU cloud VM (Xeon 2.1 GHz, 4 cores, no SMT) that other agents were
loading heavily at the same time (load average 4–23 during the runs). **Every time below is a
CI-machine number, to be re-measured on the reference Mac; read them as ratios inside one run.**
Parallel speed-ups are understated: four busy cores were rarely four free cores. Medians of three
rounds (`lab/results/r{2,3,4}.jsonl`), each suite run twice per process with the second (warm)
pass kept.

All files are under
`<scratchpad>/iris/lean-threads/`
(`lab/` the experiment, `ext/` the fork clone and emsdk, `build/` the runtime builds and Init's C).
Nothing in `/home/user/leanui` was modified.

---

## 0. Short version

1. **It works.** I built the QED64 fork's Lean 4.34 runtime (commit `53cb11e`, the one
   `toolchain/fork.lock` pins) for wasm64 twice, threaded (`MULTI_THREAD=ON`, `-pthread`) and as
   LeanUI builds it (`MULTI_THREAD=OFF` plus LeanUI's `lean-wasm-threads.patch`), and linked one
   Lean program (`lab/ThreadLab.lean`) against each the way `tools/build-app.sh` links an app.
   The threaded build runs real Lean `Task`s on Emscripten pthreads in Node 24 and in Chromium 157,
   on the page's main thread (LeanUI's model) and in a Worker (QED64's), with the same hashes as the
   native and single-threaded builds.
2. **The one result that matters for a UI** (§4.6): with the threaded build, a 1280 × 720 blur
   ran on pthreads while the page kept drawing: the call returned in 0.3 ms, the page drew 78
   frames with a longest gap of 16.7 ms, and the result arrived 1.24 s later. The single-threaded
   build froze the page for 2.8 s (5 frames). Parallel speed-up is secondary; *not blocking the
   main thread* is the win.
3. **What it takes** (§3): threaded archives (the fork's own default; 63 s for the runtime here),
   `-pthread` on every object, a preloaded pthread pool, one call LeanUI's shim does not make
   (`lean_init_task_manager_using`), **mimalloc instead of dlmalloc** (with dlmalloc's global
   lock the blur got no speed-up at all: 1.0× on 4 threads, against 1.6–1.9× with mimalloc),
   COOP/COEP on every page plus a fallback build (without isolation the threaded module hangs), and **copies in leanui.js**: Chromium's
   `TextDecoder.decode`, `ImageData`, `Blob` and `TextEncoder.encodeInto` all throw on views of
   shared memory, so the zero-copy string and pixel paths break. About **1–2 weeks** for a robust
   opt-in "threaded" mode.
4. **What it costs** (§4.1–4.4): +5 % wasm with dlmalloc, +9 % with mimalloc (+13 / +37 KB
   brotli), +4 KB brotli of glue, a pool of Workers at boot (load 17 → 106–144 ms in Node,
   43 → 81–115 ms in Chromium; Node RSS 68 → 125–128 MB), atomic reference counts on everything
   shared with a task (1.9–2.9× slower counting in wasm), a full copy on the first write to any
   shared array (shared objects are never "exclusive" in Lean's runtime), and an
   O(object graph) walk whenever an object is first shared.
5. **Where it helps LeanUI's apps** (§7): not in the update/view/diff loop. LeanUI's own Life board
   (40 × 25) gets *slower* with tasks (native 31 → 63 → 145 ms per 1,000 generations on 1, 2, 4
   tasks). It helps the photo editor's full-resolution jobs and the video lab's heavy filters
   (720p blur 145 ms/frame today), and it lets long work leave the main thread.
6. **Where iris-lean fits** (§5, §6): for LeanUI-shaped parallelism (bands of an image, rows of a
   board) Lean's purity already makes the parallel code race-free with no locks: there is no
   shared mutable state for Iris to reason about. Iris is useful exactly where we *add* shared
   mutable memory through C: a ring between a JavaScript worker and Lean on one
   SharedArrayBuffer, disjoint writes into one output buffer, lock-free counters. I linked hand
   translations of the sibling iris-audit proofs (`SpscRing.tryPush/tryPop`, `faaIncr`,
   `casIncr`, `ParMap`'s disjoint writes) into the threaded wasm64 program; they run correctly
   against Lean tasks and JavaScript workers (§5). The proofs are about HeapLang under SC; the
   translations and the step to the C11/JS memory model are trusted (§8).
7. **Lean 4.34 gotchas found on the way** (§2):
   * `IO.Ref` has atomic `get/set/swap/take` but no CAS; `modify` is "take, then set", a spin
     lock in disguise; `get` then `set` silently loses updates (28–69 % lost with 4 tasks).
   * The task manager **serialises a burst of tasks onto one worker** when one worker is idle.
   * `IO.asTask (do let x := heavy; …)` computes `heavy` **on the calling thread**: the pure
     prefix of a `do` block is evaluated when the action value is built. `IO.lazyPure` fixes it.
   * Without a task manager (LeanUI today) `Task.spawn` runs eagerly *at spawn time*, and
     `IO.Promise.new`, `IO.CancelToken.new` and everything built on them (`Std.Channel`, …)
     abort the module.

---

## 1. What was built and run

| piece | how | result |
|---|---|---|
| fork runtime, threaded | `emcmake cmake <fork>/src -DSTAGE=1 … -DMULTI_THREAD=ON`, `make libuv leanrt` (the flags of `toolchain/build-archives.sh`) | `build/rt-mt`, 63 s; flags checked in `compile_commands.json`: `-pthread`, `-DLEAN_MULTI_THREAD` |
| fork runtime, LeanUI's | same, `-DMULTI_THREAD=OFF -DLEAN_WASM_THREADS=OFF`, after `git apply toolchain/lean-wasm-threads.patch` | `build/rt-st`, 54 s; no `-pthread` |
| C of Init + `Std.Sync.{Basic,Mutex}` | native `lean -c` of the 651-module closure (`tools/closure.py`); the fork's `src/Init`, `src/Std` equal upstream 4.34.0's (`diff -r` empty), `lean.h` differs in one wasm64 macro | `build/stdlib-c`, 241 s at load ≈ 15. `Init.Data.List.MinMaxIdx` needed `-Ddebug.proofAsSorry=true` (two `simp` proofs fail when re-elaborated against the shipped `.olean`s; its code is unaffected) |
| emsdk | `./emsdk install 6.0.5`, the version of the fork's image (`FROM emscripten/emsdk:6.0.5`); no Docker | `ext/emsdk`, ships Node 24.19 (Memory64 on by default) |
| the program | `lab/ThreadLab.lean` (466 lines), `lab/lab_ffi.c` (C11 atomics, ~110 lines), `lab/lab_shim.c` (boot) | `lab/build-native.sh`; `lab/build-wasm.sh mt\|st`, `MALLOC=mimalloc` for a third variant |
| runners | `lab/run-node.mjs` (plus plain JS `worker_threads` on the module's SharedArrayBuffer), `lab/web/browser.mjs` (Playwright 1.63, Chromium 157, COOP/COEP on/off; `page`, `worker`, `bg` modes), `lab/run-all.sh`, `lab/summarize.py` | `lab/results/` |

```bash
cd <scratchpad>/iris/lean-threads/lab
./build-native.sh
./build-wasm.sh mt; ./build-wasm.sh st; MALLOC=mimalloc ./build-wasm.sh mt
for i in 2 3 4; do ./run-all.sh r$i; done
python3 -I summarize.py results/r2.jsonl results/r3.jsonl results/r4.jsonl
```

---

## 2. Lean 4.34's concurrency, read from the runtime (fork `53cb11e` = upstream 4.34.0 + wasm patches)

### 2.1 What exists

`Task` (`Task.spawn`, `map`, `bind`, `get`), `IO.asTask/mapTask/bindTask` (on the pool, or on a
dedicated thread with `prio := .dedicated`), `IO.wait`, `IO.waitAny`, `IO.cancel`,
`IO.checkCanceled`, `IO.Promise`, `Thunk`, and `Std.Sync` (`src/Std/Sync/*.lean`): `Mutex`,
`Condvar`, `RecursiveMutex`, `SharedMutex`, `Barrier`, `Semaphore`, `Notify`, `Channel`,
`Broadcast`, `CancellationToken`/`Context`. `Std.Mutex` is a C++ `std::mutex` in an external
object (`src/runtime/mutex.cpp`): a pthread mutex, a futex in wasm.

There is **no user-level atomic** (no atomic integer, no CAS on an `IO.Ref`): anything lock-free
needs C.

### 2.2 Which `IO.Ref` operations are atomic (`src/runtime/io.cpp:1580–1690`)

A ref takes the atomic path when it is marked multi-threaded or is persistent (created in an
`initialize`): `ref_maybe_mt`.

| op | implementation | atomic? |
|---|---|---|
| `get` | `exchange(nullptr)`, `inc`, `exchange(val)` back; **spins while the cell is empty** | yes |
| `set` | `mark_mt(a)` (walks the new value), `exchange(a)`, `dec(old)` | yes |
| `swap` | `mark_mt(a)`, `exchange` (spins on empty) | yes |
| `take` (unsafe) | `exchange(nullptr)`, spins until non-empty | yes; leaves the cell empty |
| `modify f`, `modifyGet` | `@[implemented_by Ref.modifyUnsafe]` = **`take`, then `set (f v)`** (`src/Init/System/ST.lean:199–216`) | yes as a whole, because the cell is empty in between and every other `get/take/modify` busy-waits: a spin lock without back-off or fairness, with `f` run while holding it |
| `get` then `set` | two atomic operations | **no**: lost updates (§4.5) |

On a single-threaded ref all of these are plain loads and stores.

### 2.3 Reference counts once an object is shared (`lean.h:120–160, 580–730`; `object.cpp:468–488, 650–700`)

* `m_rc > 0`: single-threaded, plain `++`/`--`. `m_rc < 0`: multi-threaded (MT): an increment is
  an inline relaxed atomic `fetch_sub`; **every decrement is an out-of-line call**
  (`lean_dec_ref_cold`) doing an `acq_rel` atomic add. `m_rc == 0`: persistent, never counted.
* `lean_mark_mt` walks every object reachable from its argument and flips it to MT (stops at
  objects already MT). It runs on every `Task.spawn` closure (so on everything a task captures),
  every task result, every `Thunk` value, every value `set` into an MT ref, every promise
  resolution, and `Runtime.markMultiThreaded`.
* **An MT object is never exclusive**: `lean_is_exclusive` is `rc == 1` *single-threaded*. So
  Lean's in-place updates (`Array.set!`, `ByteArray.set!`, `push`) are gone for anything that has
  been shared with a task: the first update copies it (the copy is single-threaded again).
* `Runtime.markPersistent` (unsafe) is the escape hatch for read-only data shared for the life of
  the program: no counting, never freed.

### 2.4 What LeanUI's `MULTI_THREAD=OFF` runtime does with the same API

Checked in `wasm-st` and natively with no task manager (`threadlab 0 …`):

* `lean_mark_mt` returns at once (`object.cpp:665`): nothing is ever MT, no atomics, no lost
  exclusivity (`cow-after-share`: the "shared" 4 MB array is written in place).
* `Task.spawn`/`IO.asTask` **run the closure immediately, on the calling thread, at spawn time**
  (`lean_task_spawn_core`: `if (!g_task_manager) return lean_task_pure(apply_1(c, box(0)))`):
  `probe-asTask` spends 17.8 ms in the spawn and 1 µs in the wait. (docs/TOOLCHAIN.md says tasks
  "run when forced"; they run when *spawned*. Harmless, but the sentence is wrong.)
* `IO.Promise.new` panics and the module exits (`INTERNAL PANIC: IO.Promise.new called before the
  task manager is running`, reproduced in `wasm-st`). So does `IO.CancelToken.new`, and so does
  everything built on promises: `Std.Channel`, `Std.Sync.Notify`, `Broadcast`,
  `CancellationContext`. A LeanUI app cannot use them today, threads or not.
* `IO.waitAny` calls a member function of a null task manager; it returns correctly only because
  every task has already finished (undefined behaviour that happens to work).

So the same Lean source runs in both builds with the same results (every hash in §4 matches): a
threaded build is an opt-in speed-up, not a different program, as long as the app avoids promises.

### 2.5 Trap 1: a burst of tasks serialises onto one idle worker (measured)

`task_manager::enqueue_core` (`object.cpp:937–957`) starts a new pool thread only if **no**
worker is idle; otherwise it `notify_one`s, and a woken worker takes one task. A burst of k tasks
that finds exactly one idle worker therefore runs on that worker, one after the other:

| native, `lean_init_task_manager_using(4)`, 4 tasks of ~75 ms each | start times (ms) | wall |
|---|---|---|
| fresh process, the burst first | 0.3, 0.4, 1.4, 5.8 | 110 ms |
| after one single task had run (one idle worker) | 0.07, 74, 146, 225 | 300 ms |

(`benchOverlap`, suite 7.) Upstream code, not a fork patch. It silently made my first counter runs
sequential: no lost updates in deliberately racy code, and 4 × 1M increments taking exactly as long
as 1 × 4M. The lab works around it at boot (`lab_warm`: k tasks that wait for each other on a spin
barrier force k workers into existence). A LeanUI build needs the same, or `prio := .dedicated`
for its few long tasks.

### 2.6 Trap 2: the pure prefix of a `do` block runs where the action is built (measured)

```lean
discard <| IO.asTask (prio := .dedicated) do
  let out := blurPar (gradient W H) W H r k   -- runs HERE, on the calling thread
  notifyMain id (fnv out)
```

The generated C (`lab/ThreadLab.c`, `lab_bg_blur_naive`) calls `blurPar` and `fnv` *before*
`lean_io_as_task`, whose closure only posts the hash: `let`s that precede the first action are
part of building the `BaseIO` value, which Lean evaluates strictly at the call site. Measured in
Chromium (§4.6): the "background" call blocked the page for 1.5 s (mimalloc) to 2.8 s (dlmalloc). Writing
`let out ← IO.lazyPure fun _ => blurPar …` moves the work into the task (call returns in 0.3 ms).
Task-based code needs review for this; nothing warns.

---

## 3. What a threaded LeanUI build would take

| step | what | effort | risk |
|---|---|---|---|
| archives | `toolchain/build-archives.sh` with `-DMULTI_THREAD=ON -DLEAN_WASM_THREADS=ON` (the fork's default) into a second `.toolchain/wasm64-mt/` | hours | low: 63 s for leanrt+libuv here, Init/Std as today |
| objects | `-pthread` on every object (app, `libleanui.a`, Init, Std, `leanui_wasm.c`): a shared-memory module cannot mix objects without the atomics feature | hours | low |
| link | `-pthread -sPTHREAD_POOL_SIZE=<n> -sENVIRONMENT=web,worker -sDEFAULT_PTHREAD_STACK_SIZE=8MiB` (Lean asks for 8 MiB thread stacks on Emscripten, `thread.cpp:28`), **`-sMALLOC=mimalloc`** | hours | medium: mimalloc's memory overhead; LeanUI chose dlmalloc for half the linear memory (docs/BENCHMARKS.md) |
| boot | `leanui_boot` calls `lean_init_task_manager_using(n)` and warms the pool (§2.5) | a day | medium: pool size vs memory (each Worker is an isolate holding an instance) |
| page | two builds; `LeanUI.start` loads the threaded one only when `crossOriginIsolated`. Without isolation the threaded module **hangs** (Chromium: `SharedArrayBuffer transfer requires self.crossOriginIsolated`, and the factory promise never settles) | 1–2 days | medium |
| leanui.js | copy before handing wasm memory to the platform: `TextDecoder.decode` (the string table, `leanui.js:192`), `new ImageData` (pixels, `:393`, today zero-copy), `new Blob` (`:400`) and `TextEncoder.encodeInto` all throw on shared views in Chromium 157 (`lab/web/sab-apis.mjs`) | 1–2 days | medium: an extra copy per flush and per pixel blit (48 MB per 12 MP paint) |
| hosting in a Worker (optional) | pthreads start from the hosting script (`self.location.href`) unless `Module.mainScriptUrlOrBlob` is honoured, which emsdk 6 does only if it is listed in `-sINCOMING_MODULE_JS_API` (the fork lists it); my first Worker run hung for this reason until `web/worker.js` doubled as the pthread prelude | a day | low |
| serving | COOP `same-origin` + COEP `require-corp` (or `credentialless`) on every page and asset; `leanui serve --coop` and the site's `/race` already do it | a day per host | high for embedding: third-party images, iframes and pop-ups break or need CORP/CORS |
| API | a `Cmd` that runs work on a task and delivers a `Msg`: `IO.asTask` + `IO.lazyPure` (§2.6) + a C call to `MAIN_THREAD_ASYNC_EM_ASM` that wakes the page, which then calls `leanui_callback` (prototype: `lab_bg_blur`, `lab_notify_main`) | 2–3 days | medium |
| tests | the race and the browser suites in both builds, Firefox, reloads (the fork saw V8 OOMs from pthread Workers outliving a reload, `wasm64-build/EMBED-RUNTIME.md` §3.6) | 2–3 days | medium |

Total **1–2 weeks** for an opt-in mode. It needs no change to the fork (its default is threaded;
LeanUI's patch only adds the OFF switch) and none to LeanUI's diff or encoder.

The fork's own wasm notes (`wasm64-build/EMBED-RUNTIME.md`) list further hazards that LeanUI would
inherit: `pthread_create` from a pthread is a synchronous round trip through the main JS thread
(which must therefore keep servicing its mailbox; Emscripten's main-thread busy-wait does), "timed
sleeps on task pthreads do not wake in this build", a lost mailbox wake-up needed a periodic kick
(QED64 HARDENING #52), each pthread Worker gets ~500 KiB of V8 stack in Chrome, and parked Workers
outliving a reload exhausted V8's pointer-compression cage. `lean.wasm` runs `main` on a pthread
(`-sPROXY_TO_PTHREAD`); LeanUI would keep Lean on the page's main thread, where waiting means
busy-waiting (`ALLOW_BLOCKING_ON_MAIN_THREAD`, Emscripten's default), which my runs used without
trouble.

---

## 4. Measurements

Medians of rounds r2–r4 (load average 4.8–20, median 9). Hashes were identical in every
build and every task count (`life` 1315648144 / 3183741115, `blur` 1613900043, background blur
390660032), so the threaded and single-threaded builds compute the same thing.

### 4.1 Size and boot

| build | `threadlab.wasm` raw / brotli | glue `threadlab.js` raw / brotli |
|---|--:|--:|
| wasm-st (LeanUI's runtime) | 1,502,266 / 181,356 | 61,272 / 15,587 |
| wasm-mt, dlmalloc | 1,575,703 (+4.9 %) / 194,156 (+12.8 KB) | 79,291 / 19,658 (+4.1 KB) |
| wasm-mt, mimalloc | 1,642,042 (+9.3 %) / 218,588 (+37.2 KB) | 81,819 / 20,067 (+4.5 KB) |

(ThreadLab links all of Init, as every LeanUI app does; a real app adds LeanUI and Std the same in
both builds, so the absolute deltas carry over.)

`load` = from calling the factory to the module being ready (wasm compile + instantiate + the
pool of 4 pthread Workers each loading the glue and instantiating the module); `Lean init` = the
module initializers plus, in wasm-mt, the task manager and the pool warm-up (7–18 ms of it).

| build | load (ms) | Lean init (ms) | RSS (MB) |
|---|--:|--:|--:|
| Node, wasm-mt (dlmalloc) | 143.9 | 83.9 | 125.1 |
| Node, wasm-mt (mimalloc) | 106.3 | 74.9 | 128.1 |
| Node, wasm-st (LeanUI's) | 16.5 | 62.7 | 67.9 |
| Chromium page, wasm-mt | 81.1 | 85.2 | – |
| Chromium page, wasm-mt (mimalloc) | 114.7 | 75.4 | – |
| Chromium Worker, wasm-mt | 79.9 | 67.3 | – |
| Chromium page, wasm-st | 43.5 | 54.3 | – |

The threaded build's start is ~60–120 ms later (the pool) and Node's resident memory nearly
doubles (four more isolates with an instance each). The page cannot start before the pool is
loaded unless `-sPTHREAD_POOL_DELAY_LOAD` is used, and then the first task must wait for it.

### 4.2 The threaded build on one thread

The 1-task columns below compare the three builds on the same single-threaded work: Life 40 × 25
39 / 39 / 40 ms (wasm-mt dlmalloc / mimalloc / wasm-st, Node), Life 512² 542 / 580 / 522 ms, blur
724 / 708 / 732 ms; in Chromium 42 / 42 / 39, 525 / 560 / 584, 686 / 680 / 753. **No consistent
single-thread penalty** at this noise level (±10 %). The threaded runtime costs nothing until
objects are actually shared (§4.4) — consistent with docs/TOOLCHAIN.md's "the switch costs no
speed", seen from the other side.

### 4.3 Parallel speed-up (pure fork-join: `Task.spawn` per band, band 0 on the calling thread)

**Life 40 × 25, 1,000 generations (LeanUI's board)**

| | 1 task | 2 tasks | 4 tasks | 4-task speed-up |
|---|--:|--:|--:|--:|
| native (upstream 4.34, mimalloc) | 31 | 63 | 145 | 0.21× |
| Node, wasm-mt (dlmalloc) | 39 | 83 | 95 | 0.41× |
| Node, wasm-mt (mimalloc) | 39 | 77 | 108 | 0.36× |
| Node, wasm-st (LeanUI's) | 40 | 42 | 42 | 0.96× |
| Chromium page, wasm-mt | 42 | 61 | 89 | 0.48× |
| Chromium page, wasm-mt (mimalloc) | 42 | 72 | 66 | 0.65× |
| Chromium Worker, wasm-mt | 43 | 76 | 87 | 0.49× |
| Chromium page, wasm-st | 39 | 41 | 49 | 0.80× |

**Life 512 × 512, 50 generations**

| | 1 task | 2 tasks | 4 tasks | 4-task speed-up |
|---|--:|--:|--:|--:|
| native (upstream 4.34, mimalloc) | 409 | 311 | 248 | 1.65× |
| Node, wasm-mt (dlmalloc) | 542 | 527 | 379 | 1.43× |
| Node, wasm-mt (mimalloc) | 580 | 536 | 355 | 1.64× |
| Node, wasm-st (LeanUI's) | 522 | 504 | 520 | 1.00× |
| Chromium page, wasm-mt | 525 | 435 | 414 | 1.27× |
| Chromium page, wasm-mt (mimalloc) | 560 | 456 | 417 | 1.34× |
| Chromium Worker, wasm-mt | 610 | 553 | 391 | 1.56× |
| Chromium page, wasm-st | 584 | 618 | 611 | 0.96× |

**Box blur 640 × 360, r = 2, pure bands (`blurPar`)**

| | 1 task | 2 tasks | 4 tasks | 4-task speed-up |
|---|--:|--:|--:|--:|
| native (upstream 4.34, mimalloc) | 423 | 253 | 269 | 1.57× |
| Node, wasm-mt (dlmalloc) | 724 | 744 | 690 | 1.05× |
| Node, wasm-mt (mimalloc) | 708 | 467 | 373 | 1.90× |
| Node, wasm-st (LeanUI's) | 732 | 748 | 770 | 0.95× |
| Chromium page, wasm-mt | 686 | 765 | 692 | 0.99× |
| Chromium page, wasm-mt (mimalloc) | 680 | 385 | 422 | 1.61× |
| Chromium Worker, wasm-mt | 703 | 963 | 834 | 0.84× |
| Chromium page, wasm-st | 753 | 823 | 752 | 1.00× |

**Box blur 640 × 360, r = 2, disjoint writes to one C buffer (`blurShared`, ParMap pattern)**

| | 1 task | 2 tasks | 4 tasks | 4-task speed-up |
|---|--:|--:|--:|--:|
| native (upstream 4.34, mimalloc) | 404 | 278 | 249 | 1.62× |
| Node, wasm-mt (dlmalloc) | 807 | 799 | 702 | 1.15× |
| Node, wasm-mt (mimalloc) | 809 | 415 | 372 | 2.18× |
| Node, wasm-st (LeanUI's) | 743 | 686 | 665 | 1.12× |
| Chromium page, wasm-mt | 712 | 722 | 653 | 1.09× |
| Chromium page, wasm-mt (mimalloc) | 671 | 402 | 403 | 1.67× |
| Chromium Worker, wasm-mt | 710 | 831 | 762 | 0.93× |
| Chromium page, wasm-st | 678 | 774 | 676 | 1.00× |

* **LeanUI's actual Life board gets slower with every task** (0.2–0.65×): a generation is ~40 µs
  of work and a task round trip costs more. In wasm-st the "tasks" run inline, so nothing changes.
* **The allocator decides.** With dlmalloc (LeanUI's choice, one global lock in a `-pthread`
  build) the blur gains nothing (1.05× Node, 0.99× Chromium, 0.84× in a Worker); with mimalloc
  1.6–1.9× pure, 1.7–2.2× shared-buffer, on four cores that were never free. The blur's inner loops
  were not specialised by the compiler and allocate per tap (`ThreadLab.c`: `blurAt___lam__0`
  closures over `Id.instMonad`), which is what serialises on the lock; Life allocates less and
  scales a little even with dlmalloc (1.27–1.56×). Native Lean (mimalloc, thread-local heaps)
  1.6×.
* **The ParMap variant (one shared C buffer, disjoint plain stores) is not meaningfully faster**
  than pure bands plus a concatenation here: the copy it saves (0.9 MB at 640 × 360) is small next
  to the filter, and it pays an FFI call per byte instead. Its race-freedom rests on the ParMap ownership argument, which nothing in
  Lean checks.

### 4.4 What sharing costs

`rc`: 20 passes storing 100,000 strings into a fresh array and dropping it (one increment and
one decrement per string), on plain objects and on the same kind of objects after
`Runtime.markMultiThreaded`; then 1 or 4 tasks doing it over one array captured by all of them
(marked MT by `Task.spawn`) or over arrays each task builds itself (single-threaded objects).

| | rc: plain counts (ms) | rc: same objects after `markMultiThreaded` (ms) | 1 task over a shared array | 4 tasks, one shared array | 4 tasks, private arrays | first `set!` on a shared 4 MB array (µs) | `markMultiThreaded`, 100k objects (µs) |
|---|--:|--:|--:|--:|--:|--:|--:|
| native (upstream 4.34, mimalloc) | 24.2 | 40.4 | 44.1 | 68.5 | 49.0 | 622 | 1,685 |
| Node, wasm-mt (dlmalloc) | 18.6 | 35.8 | 49.8 | 94.8 | 116.2 | 535 | 707 |
| Node, wasm-mt (mimalloc) | 16.8 | 42.6 | 44.5 | 92.1 | 52.9 | 582 | 4,931 |
| Node, wasm-st (LeanUI's) | 15.9 | 14.8 | 15.3 | 54.2 | 86.3 | 8 | 4 |
| Chromium page, wasm-mt | 18.9 | 38.3 | 67.5 | 153.3 | 196.1 | 484 | 879 |
| Chromium page, wasm-mt (mimalloc) | 13.8 | 40.5 | 72.5 | 131.4 | 85.5 | 659 | 1,070 |
| Chromium Worker, wasm-mt | 19.1 | 41.4 | 49.5 | 95.6 | 188.8 | 480 | 830 |
| Chromium page, wasm-st | 16.4 | 14.7 | 15.4 | 56.1 | 94.7 | 0 | 0 |

* Atomic counts make the same loop **1.9–2.9× slower in wasm** (1.7× natively), with no
  contention at all (`plain` vs `after markMultiThreaded`, one thread). wasm-st shows no
  difference: nothing is ever MT there.
* The first `set!` on a shared 4 MB `ByteArray` costs ~0.5 ms in wasm (a copy) instead of
  ~5 µs: once per sharing, but per frame if every frame's image goes through a task.
* `markMultiThreaded` over 100,001 objects: 0.7–4.9 ms in wasm (1.7 ms native) — what
  `Task.spawn` pays the first time a big model is captured.
* "4 tasks, private arrays" includes building the strings inside each task: slower than sharing
  with dlmalloc (the lock), faster with mimalloc (52.9 vs 92.1 ms in Node).

### 4.5 A shared counter, six ways (4 tasks × 1,000,000 increments; "kept" = final count / 4M, per round)

| way | native (upstream 4.34, mimalloc) | Node, wasm-mt (dlmalloc) | Node, wasm-mt (mimalloc) | Chromium page, wasm-mt |
|---|--:|--:|--:|--:|
| IO.Ref.modify (take/set) | 354 ms | 577 ms | 533 ms | 180 ms |
| IO.Ref get;set (racy) | 236 ms (kept 51%/42%/59%) | 293 ms (kept 48%/61%/38%) | 363 ms (kept 31%/59%/49%) | 191 ms (kept 72%/50%/61%) |
| Std.Mutex | 362 ms | 750 ms | 630 ms | 748 ms |
| C11 fetch_add (faaIncr) | 72 ms | 125 ms | 112 ms | 37 ms |
| C11 CAS loop (casIncr) | 112 ms | 80 ms | 84 ms | 70 ms |
| per-task shards | 7 ms | 16 ms | 21 ms | 32 ms |

* **`get` then `set` loses 28–69 % of the increments**, in every build, every round: each call is
  atomic, the pair is not.
* `IO.Ref.modify` is correct but is a spin lock (§2.2): ~5× slower than one C11 `fetch_add`.
  `Std.Mutex` (a futex) was the slowest correct way in wasm (630–750 ms).
* One `fetch_add` (iris-audit `faaIncr`) or a CAS loop (`casIncr`): 37–125 ms; the CAS loop is
  sometimes faster than `fetch_add` here (fewer cache-line round trips under this contention
  pattern; not a stable ranking).
* **Per-task shards, summed at the join, beat every shared counter**: 1.2–10× faster than the best
  atomic one, 10–50× faster than the locks. The fastest "lock-free" counter is the one nobody shares.

### 4.6 Background work: does the page keep drawing? (Chromium, Lean on the page's main thread)

`lab_bg` / `lab_bg_naive` start a 1280 × 720 blur on a dedicated task (4 bands) and return;
the task posts its hash to the main thread with `MAIN_THREAD_ASYNC_EM_ASM`. The page counts
`requestAnimationFrame` callbacks meanwhile (`lab/web/bg.html`).

| build | variant | call returned (ms) | result (ms) | frames drawn | longest frame gap (ms) |
|---|---|--:|--:|--:|--:|
| wasm-mt-mimalloc | naive do-block (pure prefix) | 1,550.6 | 1,571 | 6 | 1,549.9 |
| wasm-mt-mimalloc | IO.lazyPure inside IO.asTask | 0.3 | 1,243 | 78 | 16.7 |
| wasm-mt | naive do-block (pure prefix) | 2,804.5 | 2,820 | 6 | 2,799.9 |
| wasm-mt | IO.lazyPure inside IO.asTask | 0.2 | 2,677 | 164 | 16.7 |
| wasm-st | naive do-block (pure prefix) | 2,849.1 | 2,849 | 5 | 2,849.9 |
| wasm-st | IO.lazyPure inside IO.asTask | 2,770.7 | 2,771 | 5 | 2,766.5 |

* With the threaded build and the work really inside the task (`IO.lazyPure`), the call returns
  in 0.2–0.3 ms and the page draws at full rate (longest gap 16.7 ms = one frame at 60 Hz) for the
  whole computation. With mimalloc the result also arrives 2.2× sooner (1.24 s vs 2.77 s); with
  dlmalloc it is no faster than single-threaded, but the page still never freezes.
* Written the natural way (`do let out := blur …`), the work runs before `IO.asTask` and the page
  freezes as long as in the single-threaded build (§2.6).
* In wasm-st both variants block (tasks run at spawn): 5 frames in 2.8 s.

### 4.7 Lean ↔ JavaScript on one SharedArrayBuffer

See §5 for the setup. All three rounds were exact: the mixed counter ended at 4,000,000 every
time (100–180 ms for 2 Lean tasks + 2 JS workers × 1M each), and the JS → Lean ring delivered
1,000,000 values in order (sum 500,000,500,000, 0 out of order) in 462–894 ms, about 0.5–0.9 µs
per value with one value per operation and SC atomics everywhere (the consumer mostly found the
ring empty: 2–8 million empty polls); Lean → Lean through the same ring 511–730 ms.

---

## 5. Lean and JavaScript workers on one SharedArrayBuffer (C11 atomics, ~110 lines of C)

In the threaded build the module's memory *is* a SharedArrayBuffer, so any plain JavaScript worker
given `Module.wasmMemory.buffer` can use `Atomics.*` on cells Lean also uses. `lab/lab_ffi.c` puts
a 64-byte-aligned static region in wasm memory and exposes GCC/C11 `__atomic_*` operations on it
(compiled to `i64.atomic.*`); Lean binds them as `@[extern]` `BaseIO` functions (4.34 erases the
IO world argument: `uint64_t lab_faa(size_t i, uint64_t d)`), JavaScript finds the region with
`_lab_region_js()`.

* **Mixed counter**: 2 Lean tasks (`__atomic_fetch_add`) and 2 JavaScript `worker_threads`
  (`Atomics.add` on a `BigUint64Array` over the same buffer) add 1M each to one cell at the same
  time: 4,000,000 in all three rounds (§4.7).
* **SPSC ring, JavaScript producer → Lean consumer**: `SpscRing.tryPush` written in JavaScript
  (indices with `Atomics.load/store`, the slot a plain typed-array store), `tryPop` in C (indices
  `__ATOMIC_SEQ_CST`, the slot a plain load), Lean popping in a loop: 1,000,000 values, all in order, sum exact,
  in all three rounds (§4.7).

That is the "no locks, no postMessage copies" channel a LeanUI app could use for a producer that
lives in JavaScript (a WebCodecs decoder worker feeding the video lab, a network worker). It needs
shared memory, not Lean threads: one Lean thread plus a JavaScript worker would do, but the fork's
CMake ties shared memory to `-pthread`; Emscripten alone can do it (`-sSHARED_MEMORY`, Wasm
Workers) — not tried here.

---

## 6. Iris-verified HeapLang inside a LeanUI wasm64 app

### 6.1 What can be linked today

* **Hand translations** (done here): the iris-audit programs are 2–10 lines of HeapLang each
  (`faaIncr`, `casIncr`, `SpscRing.tryPush/tryPop`, `ParMap.pmap`). Writing them in C11 and
  binding them with `@[extern]` took about an hour; they run in the threaded wasm64 build against
  Lean tasks and JavaScript workers (§4.5, §5). The translation is read, not checked.
* **A mechanical translator** exists in the sibling work
  (`…/scratchpad/iris/exec/src/Exec/Translate.lean` → `exec/out/c/*.c` + `exec/rt/hl_rt.h`): every
  HeapLang heap access becomes a `__ATOMIC_SEQ_CST` operation on an `int32_t H[]`, values are
  tagged 29-bit integers (overflow traps), closures and pairs are blocks in `H`, allocation is a
  bump pointer with no reclamation, `fork` is a queue served by pthreads; it builds with
  Emscripten `-pthread`. All-SC accesses make it faithful to HeapLang's SC semantics by
  construction, at the price of an atomic per access.

### 6.2 What it would take to put translator output into a LeanUI app

| task | effort | note |
|---|---|---|
| namespace the generated C (`hl_NAME`, `hl_MAIN`, `H`, the fork queue) so several programs and Lean coexist | 1 day | today: one program per binary |
| an entry ABI: Lean calls a translated function with marshalled ints/locations and gets a Lean value back | 2–3 days | data crosses by copy (`ByteArray` ↔ `H` words) |
| one thread pool: HeapLang `fork` on Lean `Task`s, or both schedulers sized against one Emscripten pool | 2 days | two schedulers on one pool deadlock easily on the web |
| reclaim `H` between calls | 1 day | per-call arenas |
| proof-to-code link: translate the very `Val` the theorem is about (`hl_val% …`), not a re-typed copy | 1 day | the translator takes `Exp` |
| tests: run the iris-audit specs as executable checks on the translated code | 2 days | |

So **about 2 weeks** to make "a verified HeapLang module" a LeanUI building block; after that each
new structure costs its proof (100–330 lines in iris-audit) and nothing on the code side. The risk
is value more than effort: the structures that need Iris are rare in LeanUI's apps (§7), and an
all-SC translation is slow.

### 6.3 What Iris does not give here

* Lock-freedom is a property of the algorithm; Iris shows the algorithm *correct* under SC.
* Nothing about the code that runs: HeapLang has unbounded `Int`s, a garbage-collected heap (no
  ABA), SC memory; the C has `uint64_t`/29-bit ints, manual memory, and the C11/JS model.
* No liveness: a spinning consumer is not proved to make progress, nor is `IO.Ref.modify`'s spin
  lock fair.
* Nothing about Lean's runtime (atomic RC, the task manager with its §2.5 behaviour, `IO.Ref`'s
  empty-cell protocol): all trusted C++.

---

## 7. Which parts of the idea fit LeanUI's apps

| workload | threads help? | race-free how | Iris needed? |
|---|---|---|---|
| update + view + diff (every app) | **no**: sequential by design, sub-millisecond; the model would become MT (atomic counts, copy-on-write) | n/a | no |
| Life as shipped (40 × 25) | **no**: slower with every task added (§4.3) | purity | no |
| Life at 512 × 512 | modestly: 1.3–1.7× on 4 threads (§4.3) | purity: bands of a read-only board | no |
| editor full-resolution jobs (12 MP blur 3.3 s, export 1.8 s today), video lab heavy filters (720p blur 145 ms, sharpen 106 ms per frame) | **yes**: off the main thread (§4.6), and 1.6–2.2× faster on 4 (busy) threads with mimalloc (§4.3) | purity (bands → arrays → concatenation), or disjoint writes into one C buffer | only for the shared-buffer variant (ParMap's ownership argument), which gained little over the pure one |
| big diffs | unlikely: both trees would be walked by `mark_mt` and every count on them made atomic; the patch stream is one sequential buffer | — | no |
| JavaScript producer → Lean consumer (decoder, network) | yes: no copies, no postMessage latency | the SPSC ring | **yes**: exactly what iris-audit proved |
| counters/statistics across tasks | marginal | `fetch_add`; better, per-task shards (§4.5) | `faaIncr` is trivial; shards need nothing |

---

## 8. Honest shortcomings

* **Measurements**: one shared, overloaded VM; parallel speed-ups vary between runs. The Mac (ARM,
  weaker hardware memory model, more cores) must re-run them. Only Chromium 157 and Node 24 were
  run; not Firefox, not Safari.
* **My kernels are not LeanUI's**: the blur is a naive 2-D window whose loops the compiler did not
  specialise (it allocates closures per tap, which is why the malloc lock dominated); Life is
  written like `examples/Life.lean`. The editor's separable filters must be measured themselves.
* **Translation gap**: HeapLang → C11/JS is trusted. The ring's plain slot accesses rest on an
  ownership argument plus a release/acquire step that lives in the C11/JS model, outside the SC
  proof; unbounded ints and GC hide overflow and ABA. iris-lean has no weak-memory logic.
* **Lean's runtime is trusted**, and the fork patches the task manager for wasm (0035, 0038).
* **No LeanUI app was built threaded.** ThreadLab is linked exactly like an app (Init archive,
  runtime, libuv, a C shim, `-m64 -fwasm-exceptions`), but LeanUI's library, Std and leanui.js were
  not rebuilt or changed; the leanui.js copies of §3 are inferred from the API test, not run.
* **I did not re-check the Iris proofs**; the C/JS translations follow the HeapLang programs in
  the sibling `iris-audit/proofs/*.lean`, which that audit reports as building.
* **Iris is not needed for most of this**: the speed-ups that matter came from not sharing (bands,
  shards, background tasks), which Lean's purity already makes safe.

---

## 9. Files

| path (under `…/scratchpad/iris/lean-threads/`) | what |
|---|---|
| `lab/ThreadLab.lean` | every benchmark, the FFI bindings, the probes, `lab_warm`, `lab_bg_blur(_naive)` |
| `lab/lab_ffi.c` | C11 atomics on a shared region; `SpscRing` push/pop; the ParMap output buffer; `MAIN_THREAD_ASYNC_EM_ASM` notification |
| `lab/lab_shim.c` | boot (`lean_init_task_manager_using`, warm-up) and the exported entry points |
| `lab/build-native.sh`, `lab/build-wasm.sh` | the three builds (`wasm-st/`, `wasm-mt/`, `wasm-mt-mimalloc/`) |
| `lab/run-node.mjs`, `lab/web/{page.html,worker.js,bg.html,browser.mjs}` | Node and Chromium runners (main thread, Worker, background) |
| `lab/web/sab-apis.mjs` | which web APIs reject shared-memory views |
| `lab/run-all.sh`, `lab/summarize.py`, `lab/tables.py`, `lab/results/` | the rounds and their medians (`results/tables.md`) |
| `build/rt-mt`, `build/rt-st`, `build/stdlib-c`, `build/obj-{mt,st}/libInit.a` | the fork runtime builds and Init for both variants |
| `ext/fork` (sparse clone of FawadHa1der/lean4 @ `53cb11e`, LeanUI's patch applied), `ext/emsdk` (6.0.5) | sources and toolchain |
