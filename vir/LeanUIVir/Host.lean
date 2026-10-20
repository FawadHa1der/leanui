module
public import LeanUI.App
public import Vir.Js
public meta import Vir.ExternFallback
public meta import Vir.Attributes
/-!
# The lean-vir host

The counterpart of `LeanUI.Host.Wasm` for lean-vir, which runs an app's Lean code in its
interpreter (wasm32) instead of compiling it. Two differences follow:

* No C. Each finished update is kept as `[u32 opsBytes][ops][strs]` (the bytes the native server
  sends, docs/PROTOCOL.md) and handed to JavaScript as the result of the call that caused it;
  `vir/leanui-vir.js` applies them with the same DOM code as every other host.
* LeanUI's two inline-C buffer helpers run as their Lean definitions: lean-vir can call only the
  native functions in its own catalog.

An app's entry module (`LeanUIVir.BenchApp`, the counterpart of `examples/BenchApp.lean`) holds
`leanui_vir_app Bench.program` inside `namespace LeanUIVir.BenchApp`: it exports `start`, `event`,
`callback` and `take` in that namespace, which `vir/leanui-vir.js` calls by name.
-/
public section
open Lean.Vir

namespace LeanUIVir

/-- A running app and the updates it made since JavaScript last took them. -/
structure Session where
  inst : LeanUI.Instance
  out : IO.Ref (Array ByteArray)

/-- One update as the server encodes it. -/
def encode (ops strs : ByteArray) : ByteArray :=
  LeanUI.pushU32 (ByteArray.emptyWithCapacity (4 + ops.size + strs.size)) ops.size.toUInt32 ++ ops ++ strs

def start {Model Msg : Type} (p : LeanUI.Program Model Msg) (flags selector : String) : IO Session := do
  let out ← IO.mkRef #[]
  let inst ← LeanUI.start p { flush := fun ops strs => out.modify (·.push (encode ops strs)) } flags selector false
  return { inst, out }

def take (s : Session) : IO (Array ByteArray) := s.out.modifyGet fun a => (a, #[])

/-! JavaScript holds the session as an opaque handle (`JSL`); every call returns the updates it
made. -/

/-- lean-vir's `RuntimeM` is `IO` behind an irreducible definition, with no lift from `IO`. -/
def io (x : IO α) : RuntimeM α := by unfold RuntimeM; exact x

def startJs {Model Msg : Type} (p : LeanUI.Program Model Msg) (flags selector : String) : RuntimeM (JSL Session) := do
  LeanRef.toJSL (← io (start p flags selector))

def eventJs (h : JSL Session) (slot : UInt32) (payload : String) : RuntimeM (Array ByteArray) := do
  let s ← LeanRef.fromJSL h
  io do s.inst.event slot payload; take s

def callbackJs (h : JSL Session) (cb : UInt32) (ok : Bool) (payload : String) : RuntimeM (Array ByteArray) := do
  let s ← LeanRef.fromJSL h
  io do s.inst.callback cb ok payload; take s

def takeJs (h : JSL Session) : RuntimeM (Array ByteArray) := do
  io (take (← LeanRef.fromJSL h))

end LeanUIVir

/-- `leanui_vir_app p` makes `p` the program this module's lean-vir package runs: it exports
`start`, `event`, `callback` and `take` in the current namespace (the names are built with
`mkIdent` so macro hygiene cannot rename them: JavaScript calls exactly these), and has the package
run LeanUI's inline-C helpers as their Lean definitions (lean-vir reads that from the package's own
module, so it is said here rather than once in this file). -/
macro "leanui_vir_app " p:term : command => do
  let (start, event, callback, take) := (Lean.mkIdent `start, Lean.mkIdent `event, Lean.mkIdent `callback, Lean.mkIdent `take)
  `(vir_extern_fallback LeanUI.pushU32, LeanUI.appendUtf8
    @[vir_export] def $start (flags selector : String) : Lean.Vir.RuntimeM (Lean.Vir.JSL LeanUIVir.Session) :=
      LeanUIVir.startJs $p flags selector
    @[vir_export] def $event (h : Lean.Vir.JSL LeanUIVir.Session) (slot : UInt32) (payload : String) :
      Lean.Vir.RuntimeM (Array ByteArray) := LeanUIVir.eventJs h slot payload
    @[vir_export] def $callback (h : Lean.Vir.JSL LeanUIVir.Session) (cb : UInt32) (ok : Bool) (payload : String) :
      Lean.Vir.RuntimeM (Array ByteArray) := LeanUIVir.callbackJs h cb ok payload
    @[vir_export] def $take (h : Lean.Vir.JSL LeanUIVir.Session) : Lean.Vir.RuntimeM (Array ByteArray) :=
      LeanUIVir.takeJs h)
