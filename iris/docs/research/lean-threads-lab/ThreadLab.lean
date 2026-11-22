import Std.Sync.Mutex
/-!
# ThreadLab: what Lean 4.34's own concurrency costs and buys, natively and in wasm64

One file, three builds (native, wasm64 with the fork's threaded runtime, wasm64 with LeanUI's
single-threaded runtime). Every benchmark prints one JSON line. Workloads are LeanUI-shaped:
Life generations, an RGBA box blur (the photo editor / video lab), and the reference-count
traffic a view makes when it reads a model that has been shared with another thread.
-/
namespace ThreadLab

/-! ## FFI: wasm/C11 atomics on a static region that JavaScript workers can also see -/

@[extern "lab_region_addr"] opaque regionAddr : Unit → UInt64
@[extern "lab_store"] opaque cellStore (i : USize) (v : UInt64) : BaseIO Unit
@[extern "lab_load"] opaque cellLoad (i : USize) : BaseIO UInt64
@[extern "lab_faa"] opaque cellFaa (i : USize) (d : UInt64) : BaseIO UInt64
@[extern "lab_cas"] opaque cellCas (i : USize) (expected desired : UInt64) : BaseIO Bool
/-- `SpscRing.tryPop` translated to C11 atomics: 0 = empty, else value + 1. -/
@[extern "lab_ring_pop"] opaque ringPop : Unit → BaseIO UInt64
@[extern "lab_ring_push"] opaque ringPush (v : UInt64) : BaseIO Bool
@[extern "lab_ring_reset"] opaque ringReset : Unit → BaseIO Unit
/-- Plain (non-atomic) store of one byte into the shared output buffer (ParMap's pattern). -/
@[extern "lab_out_set"] opaque outSet (i : USize) (v : UInt8) : BaseIO Unit
@[extern "lab_out_reserve"] opaque outReserve (n : USize) : BaseIO Unit
@[extern "lab_out_hash"] opaque outHash (n : USize) : BaseIO UInt32
@[extern "lab_cpu_relax"] opaque cpuRelax : Unit → BaseIO Unit
/-- Posts `(id, value)` to the main JavaScript thread without blocking (Emscripten
`MAIN_THREAD_ASYNC_EM_ASM`); on the main thread itself, calls it at once. -/
@[extern "lab_notify_main"] opaque notifyMain (id value : UInt32) : BaseIO Unit
/-- Forces `a` to be computed before the next IO action (the compiler floats pure `let`s to
their first use, which would move the work out of the timed region). -/
@[extern "lab_keep"] opaque keep {α : Type} (a : @& α) : BaseIO Unit

def now : BaseIO Nat := IO.monoNanosNow

def emit (name : String) (fields : List (String × String)) : IO Unit := do
  let body := ", ".intercalate (fields.map fun (k, v) => s!"\"{k}\": {v}")
  IO.println s!"\{\"bench\": \"{name}\", {body}}"

def ms (ns : Nat) : String :=
  let us := ns / 1000
  s!"{us / 1000}.{toString (us % 1000 + 1000) |>.drop 1}"

/-! ## Life on a W × H torus (one byte per cell, as `examples/Life.lean`) -/

def seed (W H : Nat) : ByteArray := Id.run do
  let mut s : UInt64 := 1135
  let mut b := ByteArray.emptyWithCapacity (W * H)
  for _ in [0:W * H] do
    s := s * 6364136223846793005 + 1442695040888963407
    b := b.push (if (s >>> 33) % 3 == 0 then 1 else 0)
  return b

def lifeRows (b : ByteArray) (W H y0 y1 : Nat) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity ((y1 - y0) * W)
  for y in [y0:y1] do
    let up := (y + H - 1) % H * W
    let mid := y * W
    let down := (y + 1) % H * W
    for x in [0:W] do
      let l := (x + W - 1) % W
      let r := (x + 1) % W
      let n := b[up + l]! + b[up + x]! + b[up + r]! + b[mid + l]! + b[mid + r]! +
        b[down + l]! + b[down + x]! + b[down + r]!
      out := out.push (if n == 3 || (n == 2 && b[mid + x]! == 1) then 1 else 0)
  return out

def bands (H k : Nat) : Array (Nat × Nat) := (Array.range k).map fun i => (i * H / k, (i + 1) * H / k)

/-- One generation, rows split into `k` bands: bands 1..k-1 as `Task.spawn`, band 0 on this
thread, then concatenated. Pure: no shared mutable state, so no locks and nothing to prove. -/
def lifeStep (b : ByteArray) (W H k : Nat) : ByteArray :=
  if k ≤ 1 then lifeRows b W H 0 H else
  let bs := bands H k
  let tasks := (bs.extract 1 bs.size).map fun (y0, y1) => Task.spawn fun _ => lifeRows b W H y0 y1
  let first := lifeRows b W H bs[0]!.1 bs[0]!.2
  tasks.foldl (fun acc t => acc ++ t.get) first

def fnv (b : ByteArray) : UInt32 := Id.run do
  let mut h : UInt32 := 2166136261
  for i in [0:b.size] do h := (h ^^^ b[i]!.toUInt32) * 16777619
  return h

def benchLife (W H gens k : Nat) : IO Unit := do
  let mut b := seed W H
  let t0 ← now
  for _ in [0:gens] do b := lifeStep b W H k
  let t1 ← now
  emit "life" [("W", toString W), ("H", toString H), ("gens", toString gens), ("tasks", toString k),
    ("ms", ms (t1 - t0)), ("hash", toString (fnv b))]

/-! ## Box blur on RGBA (the editor's blur is separable; this one is the naive 2-D window,
so that the work per pixel is large enough to be worth a thread) -/

def gradient (W H : Nat) : ByteArray := Id.run do
  let mut d := ByteArray.emptyWithCapacity (4 * W * H)
  for y in [0:H] do
    for x in [0:W] do
      d := d.push (x * 255 / W).toUInt8 |>.push (y * 255 / H).toUInt8 |>.push ((x + y) % 256).toUInt8 |>.push 255
  return d

@[inline] def clampI (v lo hi : Int) : Nat := (if v < lo then lo else if v > hi then hi else v).toNat

/-- The blurred value of channel `c` of pixel (x, y). -/
@[inline] def blurAt (src : ByteArray) (W H r x y c : Nat) : UInt8 := Id.run do
  let mut s : UInt32 := 0
  for dy in [0:2 * r + 1] do
    let yy := clampI ((y : Int) + dy - r) 0 (H - 1)
    for dx in [0:2 * r + 1] do
      let xx := clampI ((x : Int) + dx - r) 0 (W - 1)
      s := s + src[(yy * W + xx) * 4 + c]!.toUInt32
  return (s / ((2 * r + 1) * (2 * r + 1)).toUInt32).toUInt8

def blurRows (src : ByteArray) (W H r y0 y1 : Nat) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity ((y1 - y0) * W * 4)
  for y in [y0:y1] do
    for x in [0:W] do
      for c in [0:4] do
        out := out.push (blurAt src W H r x y c)
  return out

/-- Pure fork-join: each band is a fresh ByteArray, concatenated at the end (one copy). -/
def blurPar (src : ByteArray) (W H r k : Nat) : ByteArray :=
  if k ≤ 1 then blurRows src W H r 0 H else
  let bs := bands H k
  let tasks := (bs.extract 1 bs.size).map fun (y0, y1) => Task.spawn fun _ => blurRows src W H r y0 y1
  let first := blurRows src W H r bs[0]!.1 bs[0]!.2
  tasks.foldl (fun acc t => acc ++ t.get) first

/-- ParMap's pattern: every task writes its own rows of ONE shared C buffer with plain stores,
no locks, no atomics. Race-free only because the bands are disjoint (the ownership argument of
iris-audit/proofs/ParMap.lean); nothing in Lean's types checks that. -/
def blurShared (src : ByteArray) (W H r k : Nat) : IO Unit := do
  let rows (y0 y1 : Nat) : BaseIO Unit := do
    for y in [y0:y1] do
      for x in [0:W] do
        for c in [0:4] do
          outSet ((y * W + x) * 4 + c).toUSize (blurAt src W H r x y c)
  if k ≤ 1 then rows 0 H else
  let bs := bands H k
  let ts ← (bs.extract 1 bs.size).mapM fun (y0, y1) => IO.asTask (rows y0 y1)
  rows bs[0]!.1 bs[0]!.2
  for t in ts do discard <| IO.wait t

def benchBlur (W H r k : Nat) : IO Unit := do
  let src := gradient W H
  keep src
  let t0 ← now
  let out := blurPar src W H r k
  keep out
  let t1 ← now
  emit "blur-pure" [("W", toString W), ("H", toString H), ("r", toString r), ("tasks", toString k),
    ("ms", ms (t1 - t0)), ("hash", toString (fnv out))]
  outReserve (W * H * 4).toUSize
  let t2 ← now
  blurShared src W H r k
  let t3 ← now
  emit "blur-shared-buffer" [("W", toString W), ("H", toString H), ("r", toString r), ("tasks", toString k),
    ("ms", ms (t3 - t2)), ("hash", toString (← outHash (W * H * 4).toUSize))]

/-! ## Reference counting once an object is shared with another thread -/

def strings (n : Nat) : Array String := (Array.range n).map fun i => s!"s{i}"
def strings2 (n : Nat) : Array String := (Array.range n).map fun i => s!"t{i}"

/-- Every element is stored into a new array (one increment each) and released with it (one
decrement each): the traffic a view makes when it puts model strings into a fresh tree. -/
@[noinline] def touch (xs : Array String) : Nat :=
  (xs.foldl (fun acc s => acc.push s) (Array.mkEmpty xs.size)).size

def touchReps (xs : Array String) (reps : Nat) : Nat := Id.run do
  let mut t := 0
  for _ in [0:reps] do t := t + touch xs
  return t

def benchRc (n reps : Nat) : IO Unit := do
  let st := strings n
  keep st
  let t0 ← now
  let a := touchReps st reps
  keep a
  let t1 ← now
  let mt ← Runtime.markMultiThreaded (strings2 n)
  let t2 ← now
  let b := touchReps mt reps
  keep b
  let t3 ← now
  emit "rc-single-thread" [("n", toString n), ("reps", toString reps), ("stMs", ms (t1 - t0)),
    ("mtMs", ms (t3 - t2)), ("check", toString (a == b))]

/-- `k` tasks over the SAME array (marked multi-threaded by `Task.spawn`: contended atomic
counts), versus `k` tasks that each build their own array inside the task (single-threaded
objects: plain counts). -/
def benchRcShared (n reps k : Nat) : IO Unit := do
  let shared := strings n
  keep shared
  let t0 ← now
  let ts := (List.range k).map fun _ => Task.spawn fun _ => touchReps shared reps
  let s1 := ts.foldl (fun acc t => acc + t.get) 0
  keep s1
  let t1 ← now
  let ts2 := (List.range k).map fun i => Task.spawn fun _ => touchReps (strings (n + i - i)) reps
  let s2 := ts2.foldl (fun acc t => acc + t.get) 0
  keep s2
  let t2 ← now
  emit "rc-k-tasks" [("n", toString n), ("reps", toString reps), ("tasks", toString k),
    ("sharedMs", ms (t1 - t0)), ("privateMs", ms (t2 - t1)), ("check", toString (s1 == s2))]

/-- Copy-on-write: a multi-threaded ByteArray is never exclusive, so the first `set!` after
sharing copies the whole buffer. -/
def benchCow (size : Nat) : IO Unit := do
  let mk : ByteArray := ByteArray.mk (Array.replicate size 0)
  keep mk
  let t0 ← now
  let a := mk.set! 1 7
  keep a
  let t1 ← now
  let shared ← Runtime.markMultiThreaded (ByteArray.mk (Array.replicate size 1))
  let t2 ← now
  let b := shared.set! 1 7
  keep b
  let t3 ← now
  let c := b.set! 2 9
  keep c
  let t4 ← now
  emit "cow-after-share" [("bytes", toString size), ("stSetUs", toString ((t1 - t0) / 1000)),
    ("mtFirstSetUs", toString ((t3 - t2) / 1000)), ("mtSecondSetUs", toString ((t4 - t3) / 1000)),
    ("check", toString (a[1]! + c[1]! + c[2]!))]

/-- Marking an object graph multi-threaded walks all of it (what `Task.spawn` does to its
closure and every task result). -/
def benchMarkMt (n : Nat) : IO Unit := do
  let xs := strings n
  keep xs
  let t0 ← now
  let ys ← Runtime.markMultiThreaded xs
  let t1 ← now
  let zs ← Runtime.markMultiThreaded ys
  let t2 ← now
  emit "mark-mt" [("objects", toString (n + 1)), ("firstUs", toString ((t1 - t0) / 1000)),
    ("againUs", toString ((t2 - t1) / 1000)), ("check", toString zs.size)]

/-! ## A shared counter, six ways -/

def joinAll (ts : List (Task (Except IO.Error Unit))) : IO Unit := do
  for t in ts do
    match ← IO.wait t with
    | .ok _ => pure ()
    | .error e => throw e

def counterRun (name : String) (k n : Nat) (expected : Nat) (body : IO Nat) : IO Unit := do
  let t0 ← now
  let got ← body
  let t1 ← now
  emit "counter" [("way", s!"\"{name}\""), ("tasks", toString k), ("perTask", toString n),
    ("ms", ms (t1 - t0)), ("got", toString got), ("expected", toString expected),
    ("nsPerInc", toString ((t1 - t0) / max 1 (k * n)))]

def benchCounters (k n : Nat) : IO Unit := do
  let e := k * n
  -- IO.Ref.modify: Lean implements it as take + set; a taken cell is null and every other
  -- get/take spins until it is put back. Correct, but a spin lock in disguise.
  counterRun "IO.Ref.modify (take/set)" k n e do
    let r ← IO.mkRef 0
    joinAll (← (List.range k).mapM fun _ => IO.asTask do for _ in [0:n] do r.modify (· + 1))
    r.get
  -- get then set: each call is atomic, the pair is not. Lost updates.
  counterRun "IO.Ref get;set (racy)" k n e do
    let r ← IO.mkRef 0
    joinAll (← (List.range k).mapM fun _ => IO.asTask do for _ in [0:n] do let v ← r.get; r.set (v + 1))
    r.get
  -- Std.Mutex: pthread mutex (a futex in wasm).
  counterRun "Std.Mutex" k n e do
    let m ← Std.Mutex.new 0
    joinAll (← (List.range k).mapM fun _ => IO.asTask do for _ in [0:n] do m.atomically (modify (· + 1)))
    m.atomically get
  -- one hardware fetch-and-add (iris-audit faaIncr, C11 __atomic_fetch_add / i64.atomic.rmw.add)
  counterRun "C11 fetch_add (faaIncr)" k n e do
    cellStore 0 0
    joinAll (← (List.range k).mapM fun _ => IO.asTask do for _ in [0:n] do discard <| cellFaa 0 1)
    return (← cellLoad 0).toNat
  -- load + compare-and-swap retry loop (iris-audit casIncr)
  counterRun "C11 CAS loop (casIncr)" k n e do
    cellStore 0 0
    let incr : BaseIO Unit := do
      let mut done := false
      while !done do
        let v ← cellLoad 0
        done ← cellCas 0 v (v + 1)
    joinAll (← (List.range k).mapM fun _ => IO.asTask do for _ in [0:n] do incr)
    return (← cellLoad 0).toNat
  -- no sharing: each task counts on its own, the results are added at the join
  counterRun "per-task shards" k n e do
    let ts ← (List.range k).mapM fun _ => IO.asTask (prio := .default) (do
      let mut c := 0
      for _ in [0:n] do c := c + 1
      return c)
    let mut s := 0
    for t in ts do
      match ← IO.wait t with
      | .ok c => s := s + c
      | .error err => throw err
    return s

/-! ## SPSC ring shared with a JavaScript worker (wasm only; natively a Lean task produces) -/

/-- Consume `count` values 1..count from the ring; check FIFO order and the sum. -/
def consume (count : Nat) : BaseIO (Nat × Nat × Nat) := do
  let mut got := 0
  let mut sum := 0
  let mut outOfOrder := 0
  let mut spins := 0
  while got < count do
    let v ← ringPop ()
    if v == 0 then
      spins := spins + 1
      cpuRelax ()
    else
      let x := (v - 1).toNat
      if x != got + 1 then outOfOrder := outOfOrder + 1
      got := got + 1
      sum := sum + x
  return (sum, outOfOrder, spins)

def benchRingLean (count : Nat) : IO Unit := do
  ringReset ()
  let t0 ← now
  let prod ← IO.asTask do
    let mut i := 1
    while i ≤ count do
      if ← ringPush i.toUInt64 then i := i + 1 else cpuRelax ()
  let (sum, ooo, spins) ← consume count
  joinAll [prod]
  let t1 ← now
  emit "spsc-lean-to-lean" [("count", toString count), ("ms", ms (t1 - t0)), ("sum", toString sum),
    ("expected", toString (count * (count + 1) / 2)), ("outOfOrder", toString ooo), ("emptySpins", toString spins)]

/-- The JavaScript side pushes; Lean pops. -/
@[export lab_consume_ring]
def consumeRing (count : UInt32) : IO Unit := do
  let t0 ← now
  let (sum, ooo, spins) ← consume count.toNat
  let t1 ← now
  emit "spsc-js-to-lean" [("count", toString count), ("ms", ms (t1 - t0)), ("sum", toString sum),
    ("expected", toString (count.toNat * (count.toNat + 1) / 2)), ("outOfOrder", toString ooo), ("emptySpins", toString spins)]

/-- Lean tasks add to cell 1 while JavaScript workers do `Atomics.add` on the same cell. -/
@[export lab_mixed_faa]
def mixedFaa (k n : UInt32) : IO Unit := do
  joinAll (← (List.range k.toNat).mapM fun _ => IO.asTask do for _ in [0:n.toNat] do discard <| cellFaa 1 1)
  emit "mixed-faa-lean-side-done" [("leanAdds", toString (k.toNat * n.toNat)), ("cellNow", toString (← cellLoad 1))]

/-- Lean 4.34's task manager starts a new pool thread only when NO worker is idle at the moment a
task is queued (object.cpp `enqueue_core`: `if (!m_idle_std_workers && ...) spawn_worker`). A burst
of k tasks that finds one idle worker therefore runs on that one worker, one after another. Boot
calls this once: k tasks that wait for each other (a spin barrier on cell 2, with a time-out)
force k workers into existence while none is idle. -/
@[export lab_warm]
def warm (k : UInt32) : IO Unit := do
  cellStore 2 0
  let t0 ← now
  let ts ← (List.range k.toNat).mapM fun _ => IO.asTask (do
    discard <| cellFaa 2 1
    let s ← now
    let mut waited := 0
    while (← cellLoad 2) < k.toUInt64 && waited < 1000000000 do
      cpuRelax ()
      waited := (← now) - s
    return waited)
  joinAll (ts.map fun t => t.map fun r => r.map fun _ => ())
  let t1 ← now
  emit "warm-pool" [("tasks", toString k), ("ms", ms (t1 - t0)), ("arrived", toString (← cellLoad 2))]

@[export lab_region]
def region (_ : Unit) : UInt64 := regionAddr ()

/-- When do `k` tasks from `IO.asTask` and from `Task.spawn` actually run? -/
def benchOverlap (k n : Nat) : IO Unit := do
  let t0 ← now
  let ts ← (List.range k).mapM fun i => IO.asTask (do
      let s ← now
      let mut c := 0
      for j in [0:n] do c := c + j % 7
      let e ← now
      return (i, s - t0, e - t0, c))
  for t in ts do
    match ← IO.wait t with
    | .ok (i, s, e, _) => emit "overlap-asTask" [("task", toString i), ("startUs", toString (s / 1000)), ("endUs", toString (e / 1000))]
    | .error err => throw err
  let t1 ← now
  let ts2 := (List.range k).map fun i => Task.spawn fun _ => Id.run do
      let mut c := 0
      for j in [0:n + i] do c := c + j % 7
      return c
  let s2 := ts2.foldl (fun acc t => acc + t.get) 0
  keep s2
  let t2 ← now
  emit "overlap-spawn" [("tasks", toString k), ("ms", ms (t2 - t1))]

/-- What the asynchronous parts of the API do without a task manager (LeanUI's runtime today). -/
def probeAsync (which : Nat) : IO Unit := do
  match which with
  | 0 =>
    let t0 ← now
    let t ← IO.asTask (do
      let mut c := 0
      for j in [0:3000000] do c := c + j % 7
      return c)
    let t1 ← now
    let r ← IO.wait t
    let t2 ← now
    emit "probe-asTask" [("spawnUs", toString ((t1 - t0) / 1000)), ("waitUs", toString ((t2 - t1) / 1000)),
      ("ok", toString (match r with | .ok _ => true | .error _ => false))]
  | 1 =>
    let a ← IO.asTask (pure 1)
    let b ← IO.asTask (pure 2)
    let r ← IO.waitAny [a, b]
    emit "probe-waitAny" [("ok", toString (match r with | .ok v => v | .error _ => 0))]
  | 2 =>
    let p ← IO.Promise.new (α := Nat)
    p.resolve 5
    emit "probe-promise" [("value", toString p.result!.get)]
  | _ =>
    let tok ← IO.CancelToken.new
    tok.set
    emit "probe-cancelToken" [("set", toString (← tok.isSet))]

/-- Background work, the way a LeanUI `Cmd` could run it: returns at once; a dedicated thread
runs the banded blur and posts the result's hash to the main thread when done. In the
single-threaded build `IO.asTask` runs the action before returning, so the call blocks instead. -/
@[export lab_bg_blur]
def bgBlur (id W H r k : UInt32) : IO Unit := do
  let (W, H, r, k) := (W.toNat, H.toNat, r.toNat, k.toNat)
  -- NOT `do let out := blurPar …; notifyMain id (fnv out)`: Lean evaluates the pure prefix of a
  -- `do` block where the action value is built, i.e. here, on the calling thread (measured: the
  -- call then blocks for the whole blur). `IO.lazyPure` defers it into the action.
  discard <| IO.asTask (prio := .dedicated) do
    let out ← IO.lazyPure fun _ => blurPar (gradient W H) W H r k
    notifyMain id (fnv out)

/-- The same, written the natural way: the blur runs on the calling thread before `IO.asTask`. -/
@[export lab_bg_blur_naive]
def bgBlurNaive (id W H r k : UInt32) : IO Unit := do
  let (W, H, r, k) := (W.toNat, H.toNat, r.toNat, k.toNat)
  discard <| IO.asTask (prio := .dedicated) do
    let src := gradient W H
    let out := blurPar src W H r k
    notifyMain id (fnv out)

@[export lab_suite]
def suite (which a b c : UInt32) : IO Unit := do
  let (a, b, c) := (a.toNat, b.toNat, c.toNat)
  match which with
  | 0 => benchLife a b c 1; benchLife a b c 2; benchLife a b c 4
  | 1 => benchBlur a b c 1; benchBlur a b c 2; benchBlur a b c 4
  | 2 => benchRc a b; benchRcShared a b 1; benchRcShared a b 4; benchCow (4 * 1024 * 1024); benchMarkMt a
  | 3 => benchCounters a b
  | 4 => benchRingLean a
  | 5 => benchLife a b c 1 -- one sequential run (single-threaded build comparison)
  | 6 => benchRc a b
  | 7 => benchOverlap a b
  | 8 => probeAsync a
  | _ => IO.println "unknown suite"

end ThreadLab
