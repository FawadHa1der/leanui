module
public import LeanUI.App
/-!
# The browser host (wasm64)

The C shim (`runtime/leanui_wasm.c`) owns the running `Instance` and calls the exported functions
below; `flush` hands each finished command buffer to the JavaScript runtime without copying it
(the browser reads it straight out of wasm memory). An app becomes a wasm program with
`leanui_app myProgram`, which defines the one exported entry point `leanui_app_start`.
-/
public section
namespace LeanUI.Wasm

/-- Hand a finished update (command words, string area) to the page. -/
@[extern "leanui_host_flush"] opaque hostFlush (ops : @& ByteArray) (strs : @& ByteArray) : IO Unit

def host : Host := { flush := hostFlush }

@[export leanui_instance_event]
def instanceEvent (i : Instance) (slot : UInt32) (payload : String) : IO Unit := i.event slot payload

@[export leanui_instance_callback]
def instanceCallback (i : Instance) (cb : UInt32) (ok : UInt8) (payload : String) : IO Unit :=
  i.callback cb (ok != 0) payload

end LeanUI.Wasm

/-- `leanui_app p` makes `p` the program this wasm module runs. The exported symbol is built
with `mkIdent` so macro hygiene cannot rename it: the C shim links against exactly
`leanui_app_start`. -/
macro "leanui_app " p:term : command => do
  let exp := Lean.mkIdent `leanui_app_start
  `(@[export $exp] def leanuiAppStart (flags selector : String) (hydrate : UInt8) : IO LeanUI.Instance :=
      LeanUI.start $p LeanUI.Wasm.host flags selector (hydrate != 0))
