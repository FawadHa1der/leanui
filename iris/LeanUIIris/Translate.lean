/-
HeapLang → JavaScript and C11. Trusted, not verified: tested against the reference interpreter
(`Interp.lean`, `test/node.mjs`).

The input is the very `Val`/`Exp` constant a theorem is about (`&SpinLock.acquire` in a program
*is* the `Val` that `acquire_spec` is stated for), so the kernel cannot drift from its proof; the
translation itself is the trusted step. Two targets:

* an ES module for `rt/runtime.mjs`: one SharedArrayBuffer, every HeapLang `Load`, `Store`,
  `CmpXchg`, `Xchg` and `FAA` one SeqCst `Atomics` operation;
* a C11 translation unit for `rt/hl_rt.h`: the same, with `__atomic` seq_cst operations; it builds
  natively with `-pthread` or to wasm32 with Emscripten pthreads.

Since every shared access is an SC atomic, the JS and C11 memory models give sequentially
consistent executions, the interleavings Iris reasons about. Plain accesses are emitted only to
initialise a fresh block before its pointer is published and to read immutable blocks.

Decisions that matter for faithfulness:
* HeapLang evaluates right to left (`ECtxItem`): every operand is hoisted into a `const` in that
  order, so `(faa(l,1), faa(l,10))` gives `(10, 0)`.
* `betaS` substitutes `f` before `x`: in `rec f f := f`, `f` is the closure.
* Closures are defunctionalised blocks in the shared heap (a code id and the captured words), so
  they can be stored, sent and forked; a closed `rec` is a static block. Known calls are direct
  and uncurried, and self tail calls become loops (every HeapLang spin is a self tail call, and JS
  has no tail calls).
* `Hints.futexWait`/`futexWake` become `Atomics.wait`/`notify`; prophecies are erased.
-/
import LeanUIIris.Translate.Encoding
import LeanUIIris.Kernels.Hints

namespace LeanUIIris.Translate
open Iris.HeapLang

def jsInt (n : Int) : String := if n < 0 then s!"({n})" else toString n

/-! ## Translator state -/

structure VarInfo where
  name : String
  /-- Statically known callee: (function id, arity of its uncurried entry). -/
  known : Option (Nat × Nat) := none
deriving Inhabited

abbrev Env := List (String × VarInfo)

structure FunMeta where
  id : Nat
  arity : Nat
  fvs : List String
deriving Inhabited

structure FunSrc where
  fm : FunMeta
  selfB : Binder
  params : List Binder
  /-- The expression under the first binder (still curried), used for the curried entry. -/
  inner : Exp
  /-- The body under all `arity` binders. -/
  body : Exp
  fvKnown : List (Option (Nat × Nat))

inductive Mode | value | tail
deriving BEq, Inhabited

structure Ctx where
  env : Env
  /-- (function id, JS names of the uncurried parameters): enables self-tail-call -> loop. -/
  loop : Option (Nat × List String) := none

inductive Target | js | c
deriving BEq, Inhabited

structure St where
  tmp : Nat := 0
  buf : Array String := #[]
  ind : Nat := 2
  nfun : Nat := 0
  recCache : List ((Binder × Binder × Exp × List (Option (Nat × Nat))) × FunMeta) := []
  work : Array FunSrc := #[]
  funCode : Array String := #[]
  funEntry : Array (Nat × String) := #[]
  statics : Array Int := #[]          -- flattened static cells (words); patched for closures
  staticCache : List (Val × Int) := []
  staticFun : List (Nat × Int) := []
  stats : List (String × Nat) := []
  protos : Array String := #[]
  target : Target := .js

abbrev M := StateT St (Except String)

def bump (key : String) : M Unit :=
  modify fun s =>
    let n := (s.stats.lookup key).getD 0
    { s with stats := (key, n + 1) :: s.stats.filter (·.1 != key) }

def isC : M Bool := do pure ((← get).target == .c)
def EQ : M String := do pure (if ← isC then "==" else "===")
def constKw : M String := do pure (if ← isC then "const int32_t" else "const")
def letKw : M String := do pure (if ← isC then "int32_t" else "let")

def fresh (hint : String := "t") : M String := do
  let s ← get
  set { s with tmp := s.tmp + 1 }
  pure s!"{hint}{s.tmp}"

def emit (line : String) : M Unit :=
  modify fun s => { s with buf := s.buf.push ("".pushn ' ' (2 * s.ind) ++ line) }

def indented (m : M α) : M α := do
  modify fun s => { s with ind := s.ind + 1 }
  let r ← m
  modify fun s => { s with ind := s.ind - 1 }
  pure r

def bindc (rhs : String) (hint := "t") : M String := do
  let t ← fresh hint
  emit s!"{← constKw} {t} = {rhs};"
  pure t

def finish (mode : Mode) (a : String) : M (Option String) := do
  match mode with
  | .value => pure (some a)
  | .tail => emit s!"return {a};"; pure none

def sanitize (s : String) : String :=
  String.ofList (s.toList.map fun c => if c.isAlphanum then c else '_')

def binderNames : Binder → List String
  | .named s => [s]
  | .anon => []

/-! ## Free variables (values `Val.rec_` are closed: substitution never enters them) -/

partial def fvAcc (bound : List String) (acc : Array String) : Exp → Array String
  | .var x => if bound.contains x || acc.contains x then acc else acc.push x
  | .val _ => acc
  | .rec_ f x b => fvAcc (binderNames x ++ binderNames f ++ bound) acc b
  | .app a b | .binop _ a b | .pair a b | .allocN a b | .store a b | .xchg a b | .faa a b =>
      fvAcc bound (fvAcc bound acc a) b
  | .unop _ a | .fst a | .snd a | .injL a | .injR a | .free a | .load a | .fork a => fvAcc bound acc a
  | .if a b c | .case a b c | .cmpXchg a b c | .resolve a b c =>
      fvAcc bound (fvAcc bound (fvAcc bound acc a) b) c
  | .newProph => acc

def freeVars (e : Exp) : List String := (fvAcc [] #[] e).toList

/-- `rec f x := rec _ y := ... body` has an uncurried entry of arity 1 + (number of nested
anonymous lambdas). -/
partial def uncurry : Exp → List Binder × Exp
  | .rec_ .anon x b => match uncurry b with | (xs, body) => (x :: xs, body)
  | e => ([], e)

def spine : Exp → Exp × List Exp
  | .app f a => match spine f with | (h, xs) => (h, xs ++ [a])
  | e => (e, [])

/-! ## Static constants (closed boxed values live in a static region of the shared heap) -/

def addStatic (cells : List Int) : M Int := do
  let s ← get
  let addr := STATIC_BASE + s.statics.size
  set { s with statics := s.statics ++ cells.toArray }
  pure ((addr : Int) * 8 + 6)

/-- Register a function (dedup by term + known-ness of captured variables). -/
def registerFun (f x : Binder) (inner : Exp) (fvs : List String)
    (fvKnown : List (Option (Nat × Nat))) : M FunMeta := do
  let key := (f, x, inner, fvKnown)
  match (← get).recCache.lookup key with
  | some m => pure m
  | none =>
    let (more, body) := uncurry inner
    let s ← get
    let m : FunMeta := { id := s.nfun, arity := 1 + more.length, fvs := fvs }
    set { s with nfun := s.nfun + 1, recCache := (key, m) :: s.recCache,
                 work := s.work.push { fm := m, selfB := f, params := x :: more, inner, body,
                                       fvKnown } }
    pure m

def staticClosure (m : FunMeta) : M Int := do
  match (← get).staticFun.lookup m.id with
  | some w => pure w
  | none =>
    let w ← addStatic [hdrClo m.id]
    modify fun s => { s with staticFun := (m.id, w) :: s.staticFun }
    pure w

partial def constWord (v : Val) : M Int := do
  match v with
  | .lit l => StateT.lift (encLit l)
  | .injL (.lit l) => pure (encInj true (← StateT.lift (encLit l)))
  | .injR (.lit l) => pure (encInj false (← StateT.lift (encLit l)))
  | _ =>
    match (← get).staticCache.lookup v with
    | some w => pure w
    | none =>
      let w ← match v with
        | .pair a b => do let wa ← constWord a; let wb ← constWord b; addStatic [HDR_PAIR, wa, wb]
        | .injL a => do let wa ← constWord a; addStatic [HDR_INJL, wa]
        | .injR a => do let wa ← constWord a; addStatic [HDR_INJR, wa]
        | .rec_ f x b => do
            let fv := freeVars (.rec_ f x b)
            unless fv.isEmpty do throw s!"closed value mentions free variables {fv}"
            let m ← registerFun f x b [] []
            staticClosure m
        | .lit _ => unreachable!
      modify fun s => { s with staticCache := (v, w) :: s.staticCache }
      pure w

/-- Closure word for `rec f x := inner` in `env`, plus its static call info. -/
def closure (env : Env) (f x : Binder) (inner : Exp) : M (String × Option (Nat × Nat)) := do
  let fvs := freeVars (.rec_ f x inner)
  let infos ← fvs.mapM fun y => match env.lookup y with
    | some vi => pure vi
    | none => throw s!"unbound variable `{y}`"
  let m ← registerFun f x inner fvs (infos.map (·.known))
  if fvs.isEmpty then
    pure (jsInt (← staticClosure m), some (m.id, m.arity))
  else
    bump "closure-alloc-sites"
    let p ← fresh "c"
    emit s!"{← constKw} {p} = allocBlock({fvs.length + 1});"
    emit s!"H[{p}] = {hdrClo m.id};"
    for (vi, j) in infos.zipIdx do
      emit s!"H[{p} + {j + 1}] = {vi.name};"
    let w ← bindc s!"({p} << 3) | 6" "k"
    pure (w, some (m.id, m.arity))

def binopJs (op : BinOp) (a b : String) (eq : String) : String :=
  match op with
  | .plus => s!"add({a}, {b})"
  | .minus => s!"sub({a}, {b})"
  | .mult => s!"mul({a}, {b})"
  | .tdiv => s!"quot({a}, {b})"
  | .tmod => s!"rem({a}, {b})"
  | .and => s!"band({a}, {b})"
  | .or => s!"bor({a}, {b})"
  | .xor => s!"bxor({a}, {b})"
  | .shiftl => s!"shl({a}, {b})"
  | .shiftr => s!"shr({a}, {b})"
  | .le => s!"({a} <= {b} ? 23 : 15)"
  | .lt => s!"({a} < {b} ? 23 : 15)"
  | .eq => s!"({a} {eq} {b} ? 23 : 15)"
  | .offset => s!"off({a}, {b})"

def unopJs (op : UnOp) (a : String) : String :=
  match op with
  | .neg => s!"neg({a})"
  | .minus => s!"minus({a})"

mutual

partial def atom (cx : Ctx) (e : Exp) : M String := do
  match ← compile cx e .value with
  | some a => pure a
  | none => throw "internal: expression in value position produced no value"

/-- Like `atom`, but keeps static call info for lambdas (used by `let` and call heads). -/
partial def atomK (cx : Ctx) (e : Exp) : M (String × Option (Nat × Nat)) := do
  match e with
  | .rec_ f x b => closure cx.env f x b
  | .val (.rec_ f x b) => do
      let w ← constWord (.rec_ f x b)
      let m ← registerFun f x b [] []
      pure (jsInt w, some (m.id, m.arity))
  | .var x => match cx.env.lookup x with
      | some vi => pure (vi.name, vi.known)
      | none => throw s!"unbound variable `{x}`"
  | _ => pure (← atom cx e, none)

partial def compile (cx : Ctx) (e : Exp) (mode : Mode) : M (Option String) := do
  match e with
  | .val v => finish mode (jsInt (← constWord v))
  | .var x =>
    match cx.env.lookup x with
    | some vi => finish mode vi.name
    | none => throw s!"unbound variable `{x}`"
  | .rec_ f x b => let (w, _) ← closure cx.env f x b; finish mode w
  | .app _ _ => compileApp cx e mode
  | .unop op a => do let va ← atom cx a; finish mode (← bindc (unopJs op va))
  | .binop op a b => do
      let vb ← atom cx b; let va ← atom cx a
      finish mode (← bindc (binopJs op va vb (← EQ)))
  | .if c a b => do
      let vc ← atom cx c
      match mode with
      | .tail =>
        emit s!"if ({vc} {← EQ} 23) \{"
        let _ ← indented (compile cx a .tail)
        emit "} else {"
        let _ ← indented (compile cx b .tail)
        emit "}"
        pure none
      | .value =>
        let t ← fresh
        emit s!"{← letKw} {t};"
        emit s!"if ({vc} {← EQ} 23) \{"
        indented do let r ← atom cx a; emit s!"{t} = {r};"
        emit "} else {"
        indented do let r ← atom cx b; emit s!"{t} = {r};"
        emit "}"
        pure (some t)
  | .pair a b => do
      let vb ← atom cx b; let va ← atom cx a
      finish mode (← bindc s!"mkPair({va}, {vb})")
  -- peepholes: `cas` is `snd(cmpXchg ..)`; avoid allocating the result pair
  | .snd (.cmpXchg l a b) => do
      bump "cas-peephole"
      let vb ← atom cx b; let va ← atom cx a; let vl ← atom cx l
      finish mode (← bindc s!"(acas({vl}, {va}, {vb}) {← EQ} {va} ? 23 : 15)")
  | .fst (.cmpXchg l a b) => do
      let vb ← atom cx b; let va ← atom cx a; let vl ← atom cx l
      finish mode (← bindc s!"acas({vl}, {va}, {vb})")
  | .fst a => do let va ← atom cx a; finish mode (← bindc s!"H[({va} >> 3) + 1]")
  | .snd a => do let va ← atom cx a; finish mode (← bindc s!"H[({va} >> 3) + 2]")
  | .injL a => do let va ← atom cx a; finish mode (← bindc s!"mkInjL({va})")
  | .injR a => do let va ← atom cx a; finish mode (← bindc s!"mkInjR({va})")
  | .case s l r => do
      let w ← atom cx s
      let t ← match mode with
        | .value => do let t ← fresh; emit s!"{← letKw} {t};"; pure (some t)
        | .tail => pure none
      emit s!"if (isInjL({w})) \{"
      indented (branch cx l w mode t)
      emit "} else {"
      indented (branch cx r w mode t)
      emit "}"
      pure t
  | .allocN n v => do
      let vv ← atom cx v; let vn ← atom cx n
      finish mode (← bindc s!"allocN({vn}, {vv})")
  | .free l => do let vl ← atom cx l; emit s!"hl_free({vl});"; finish mode "7"
  | .load l => do let vl ← atom cx l; finish mode (← bindc s!"ald({vl})")
  | .store l v => do
      let vv ← atom cx v; let vl ← atom cx l
      emit s!"ast({vl}, {vv});"
      finish mode "7"
  | .cmpXchg l a b => do
      let vb ← atom cx b; let va ← atom cx a; let vl ← atom cx l
      let o ← bindc s!"acas({vl}, {va}, {vb})"
      finish mode (← bindc s!"mkPair({o}, {o} {← EQ} {va} ? 23 : 15)")
  | .xchg l v => do
      let vv ← atom cx v; let vl ← atom cx l
      finish mode (← bindc s!"axchg({vl}, {vv})")
  | .faa l d => do
      let vd ← atom cx d; let vl ← atom cx l
      finish mode (← bindc s!"faa({vl}, {vd})")
  | .fork b => do
      bump "fork-sites"
      let (w, _) ← closure cx.env .anon .anon b
      emit s!"hl_fork({w});"
      finish mode "7"
  | .newProph => finish mode "31"
  | .resolve e0 e1 e2 => do
      -- prophecy erasure: evaluate e2, e1 (right to left), then e0 and keep its value
      let _ ← atom cx e2; let _ ← atom cx e1
      compile cx e0 mode

partial def branch (cx : Ctx) (eb : Exp) (w : String) (mode : Mode) (t : Option String) : M Unit := do
  let inline (env : Env) (x : Binder) (body : Exp) : M Unit := do
    let pay ← bindc s!"payload({w})" "y"
    let env' := match x with
      | .named n => (n, { name := pay : VarInfo }) :: env
      | .anon => env
    let r ← compile { cx with env := env' } body mode
    if let (some t, some r) := (t, r) then emit s!"{t} = {r};"
  match eb with
  | .rec_ .anon x body => inline cx.env x body
  | .val (.rec_ .anon x body) => inline [] x body
  | _ =>
    let f ← atom cx eb
    let r ← bindc s!"callv({f}, payload({w}))"
    match mode with
    | .tail => emit s!"return {r};"
    | .value => if let some t := t then emit s!"{t} = {r};"

partial def compileApp (cx : Ctx) (e : Exp) (mode : Mode) : M (Option String) := do
  let (h, args) := spine e
  -- futex hints: no-ops in HeapLang (Kernels/Hints.lean), Atomics.wait/notify here.
  -- Must precede the `let` rule: `futexWake l` is itself a one-argument beta-redex.
  if let .val hv := h then
    if hv = Hints.futexWait ∧ args.length = 2 then
      bump "futex-wait"
      let vx ← atom cx args[1]!
      let vl ← atom cx args[0]!
      emit s!"futexWait({vl}, {vx});"
      return ← finish mode "7"
    if hv = Hints.futexWake ∧ args.length = 1 then
      bump "futex-wake"
      let vl ← atom cx args[0]!
      emit s!"futexWake({vl});"
      return ← finish mode "7"
  -- `let x := a; body` is `(λ x, body) a`
  let letBind (env : Env) (x : Binder) (body : Exp) (a : Exp) : M (Option String) := do
    bump "let"
    let (va, kn) ← atomK cx a
    let env' := match x with
      | .named n => (n, { name := va, known := kn }) :: env
      | .anon => env
    compile { cx with env := env' } body mode
  match h, args with
  | .rec_ .anon x body, [a] => letBind cx.env x body a
  | .val (.rec_ .anon x body), [a] => letBind [] x body a
  | _, _ =>
    -- arguments right to left, then the head
    let mut vs : List String := []
    for a in args.reverse do
      vs := (← atom cx a) :: vs
    let (hw, kn) ← atomK cx h
    match kn with
    | some (k, n) =>
      if n ≤ vs.length then
        let now := vs.take n
        let rest := vs.drop n
        match mode, cx.loop with
        | .tail, some (k', ps) =>
          if k == k' && hw == "self" && rest.isEmpty then
            bump "self-tail-call->loop"
            let tmps ← now.mapM fun v => bindc v "n"
            for (p, t) in ps.zip tmps do emit s!"{p} = {t};"
            emit "continue;"
            return none
        | _, _ => pure ()
        bump "known-call"
        let mut r ← bindc s!"U{k}({hw}{String.join (now.map (", " ++ ·))})"
        for a in rest do
          r ← bindc s!"callv({r}, {a})"
        finish mode r
      else
        let mut r := hw
        for a in vs do r ← bindc s!"callv({r}, {a})"
        finish mode r
    | none =>
      bump "dynamic-call"
      let mut r := hw
      for a in vs do r ← bindc s!"callv({r}, {a})"
      finish mode r

end

/-! ## Functions -/

def genFun (src : FunSrc) : M Unit := do
  let k := src.fm.id
  let n := src.fm.arity
  let ps := (List.range n).map fun i => s!"p{i}"
  let fvEnv : Env := (src.fm.fvs.zip src.fvKnown).zipIdx.map fun ((y, kn), j) =>
    (y, { name := s!"e{j}", known := kn })
  let selfEnv : Env := match src.selfB with
    | .named f => [(f, { name := "self", known := some (k, n) })]
    | .anon => []
  let paramEnv (i : Nat) (b : Binder) : Env := match b with
    | .named x => [(x, { name := s!"p{i}" })]
    | .anon => []
  -- HeapLang substitutes `f` before `x` (betaS), so `f` shadows the first parameter; the inner
  -- (curried) parameters shadow both.
  let first := src.params.head!
  let envOuter : Env := selfEnv ++ paramEnv 0 first ++ fvEnv
  let envBody : Env :=
    (src.params.drop 1).zipIdx.reverse.foldl (fun acc (b, i) => acc ++ paramEnv (i + 1) b) [] ++ envOuter
  let loadEnv : M Unit := do
    for j in List.range src.fm.fvs.length do
      emit s!"{← constKw} e{j} = H[(self >> 3) + {j + 1}];"
  -- uncurried entry
  let c ← isC
  modify fun s => { s with buf := #[], ind := (if c then 0 else 1) }
  let sig (name : String) (params : List String) : String :=
    if c then s!"static int32_t {name}(int32_t self{String.join (params.map (", int32_t " ++ ·))})"
    else s!"function {name}(self{String.join (params.map (", " ++ ·))})"
  if c then
    modify fun s => { s with protos := s.protos.push (sig s!"U{k}" ps ++ ";") }
    if n > 1 then modify fun s => { s with protos := s.protos.push (sig s!"C{k}" ["p0"] ++ ";") }
  emit s!"{sig s!"U{k}" ps} \{"
  indented do
    loadEnv
    emit "for (;;) {"
    let _ ← indented (compile { env := envBody, loop := some (k, ps) } src.body .tail)
    emit "}"
  emit "}"
  -- curried entry (what `callv` dispatches to)
  if n > 1 then
    emit s!"{sig s!"C{k}" ["p0"]} \{"
    indented do
      loadEnv
      let _ ← compile { env := envOuter } src.inner .tail
    emit "}"
  let s ← get
  set { s with funCode := s.funCode.push (String.intercalate "\n" s.buf.toList),
               funEntry := s.funEntry.push (k, if n > 1 then s!"C{k}" else s!"U{k}") }

partial def drain : M Unit := do
  let s ← get
  if h : s.funCode.size < s.work.size then
    genFun s.work[s.funCode.size]
    drain

structure Output where
  code : String
  /-- How often each translation rule fired (`futex-wake`, `self-tail-call->loop`, …). A rule that
  silently stops firing changes no result, so tests check these counts. -/
  stats : List (String × Nat)
  nfun : Nat
  nstatic : Nat

/-- Translate a closed HeapLang program: an ES module for `rt/runtime.mjs`, or a C11 translation
unit for `rt/hl_rt.h`. -/
def translate (name : String) (main : Exp) (target : Target := .js) : Except String Output := do
  let act : M Int := do
    let fv := freeVars main
    unless fv.isEmpty do throw s!"program has free variables {fv}"
    let m ← registerFun .anon .anon main [] []
    let w ← staticClosure m
    drain
    pure w
  let (mainW, s) ← act.run { target }
  let entries := (s.funEntry.qsort (fun a b => a.1 < b.1)).toList.map (·.2)
  let staticsJs := String.intercalate ", " (s.statics.toList.map toString)
  if target == .c then
    let src := String.intercalate "\n" [
      s!"// Generated by iris/LeanUIIris/Translate.lean from iris-lean HeapLang. Program: {name}",
      "// Do not edit. Every heap access is a seq_cst __atomic op; iris/rt/hl_rt.h has the encoding.",
      "#include \"hl_rt.h\"",
      s!"const char *hl_NAME = {String.quote name};",
      s!"const int32_t hl_MAIN = {mainW};",
      s!"const int32_t hl_STATICS[] = \{{staticsJs}};",
      s!"const int32_t hl_NSTATICS = {s.statics.size};",
      String.intercalate "\n" s.protos.toList,
      "static int32_t callv(int32_t f, int32_t a);",
      String.intercalate "\n" s.funCode.toList,
      s!"hl_fn hl_FUNS[] = \{{String.intercalate ", " entries}};",
      "static int32_t callv(int32_t f, int32_t a) {",
      "  if ((f & 7) != 6) stuck(\"application of a non-closure\");",
      "  return hl_FUNS[H[f >> 3] >> 3](f, a);",
      "}",
      "#include \"hl_main.h\"",
      ""]
    return { code := src, stats := s.stats, nfun := s.nfun, nstatic := s.statics.size }
  let js := String.intercalate "\n" [
    s!"// Generated by iris/LeanUIIris/Translate.lean from iris-lean HeapLang. Program: {name}",
    "// Do not edit. Every heap access is a SeqCst Atomics op; iris/rt/runtime.mjs has the encoding.",
    s!"export const NAME = {String.quote name};",
    s!"export const MAIN = {mainW};",
    s!"export const STATIC_BASE = {STATIC_BASE};",
    s!"export const STATICS = new Int32Array([{staticsJs}]);",
    "export function link(R) {",
    "  const H = R.H, allocBlock = R.allocBlock, allocN = R.allocN, hl_free = R.free, hl_fork = R.fork;",
    "  const mkPair = R.mkPair, mkInjL = R.mkInjL, mkInjR = R.mkInjR, isInjL = R.isInjL, payload = R.payload;",
    "  const add = R.add, sub = R.sub, mul = R.mul, quot = R.quot, rem = R.rem, band = R.band, bor = R.bor;",
    "  const bxor = R.bxor, shl = R.shl, shr = R.shr, off = R.off, neg = R.neg, minus = R.minus, faa = R.faa;",
    "  const stuck = R.stuck, futexWait = R.futexWait, futexWake = R.futexWake;",
    "  const ald = (l) => Atomics.load(H, l >> 3), ast = (l, v) => Atomics.store(H, l >> 3, v);",
    "  const acas = (l, e, d) => Atomics.compareExchange(H, l >> 3, e, d), axchg = (l, v) => Atomics.exchange(H, l >> 3, v);",
    "  function callv(f, a) {",
    "    if ((f & 7) !== 6) stuck('application of a non-closure');",
    "    return FUNS[H[f >> 3] >> 3](f, a);",
    "  }",
    String.intercalate "\n" s.funCode.toList,
    s!"  const FUNS = [{String.intercalate ", " entries}];",
    "  return FUNS;",
    "}",
    ""]
  pure { code := js, stats := s.stats, nfun := s.nfun, nstatic := s.statics.size }

end LeanUIIris.Translate
