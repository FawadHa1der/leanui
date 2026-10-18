module
public import Std.Data.HashMap
public import LeanUI.Html
/-!
# The LeanUI wire protocol: a command buffer

Every update produces one `Buf`: a stream of little-endian 32-bit words (`ops`) and a UTF-8
string area (`strs`). Strings in `ops` are `(offset, length)` pairs counted in UTF-16 code units,
so the browser decodes the whole string area with one `TextDecoder` call per flush and slices it.
Tag, attribute and event names are interned: the first use emits `INTERN id str`, later uses send
only the id. Node handles and listener slots are allocated by Lean, so no command needs an answer
from the browser: the same buffer can be applied on the page's main thread, posted from a Worker,
or sent by a server over HTTP. `docs/PROTOCOL.md` is the normative description.
-/
public section
namespace LeanUI.Op
-- DOM construction
def createElement : UInt32 := 1   -- node, ns, name
def createText    : UInt32 := 2   -- node, str
def setAttr       : UInt32 := 3   -- node, name, str
def removeAttr    : UInt32 := 4   -- node, name
def setPropStr    : UInt32 := 5   -- node, name, str
def setPropBool   : UInt32 := 6   -- node, name, 0|1
def setPropNum    : UInt32 := 7   -- node, name, str (decimal)
def removeProp    : UInt32 := 8   -- node, name            (sets the property to "" / false)
def setText       : UInt32 := 9   -- node, str
def appendChild   : UInt32 := 10  -- parent, child
def insertBefore  : UInt32 := 11  -- parent, child, ref
def remove        : UInt32 := 12  -- node                  (detach)
def replace       : UInt32 := 13  -- old, new              (old.replaceWith(new))
def free          : UInt32 := 14  -- node                  (forget the handle)
def setListener   : UInt32 := 15  -- node, event-name, slot, payload, flags
def removeListener: UInt32 := 16  -- node, event-name
def intern        : UInt32 := 17  -- id, str
def mount         : UInt32 := 18  -- selector-str, node    (container.replaceChildren(node))
def hydrate       : UInt32 := 19  -- selector-str, firstHandle, count
-- effects
def fetch         : UInt32 := 32  -- cb, method-str, url-str, body-str, headers-str ("k: v" lines)
def timeout       : UInt32 := 33  -- cb, ms
def intervalSet   : UInt32 := 34  -- sub, ms
def intervalClear : UInt32 := 35  -- sub                   (stops any subscription: interval or url)
def storageSet    : UInt32 := 36  -- key-str, value-str
def storageGet    : UInt32 := 37  -- cb, key-str
def storageRemove : UInt32 := 38  -- key-str
def urlPush       : UInt32 := 39  -- url-str
def urlReplace    : UInt32 := 40  -- url-str
def urlListen     : UInt32 := 41  -- sub                   (popstate and intercepted links -> callback)
def focus         : UInt32 := 42  -- selector-str
def log           : UInt32 := 43  -- str
def title         : UInt32 := 44  -- str
def frame         : UInt32 := 45  -- cb                    (requestAnimationFrame)
def blur          : UInt32 := 46  -- selector-str
def scrollIntoView: UInt32 := 47  -- selector-str
end LeanUI.Op

namespace LeanUI

/-- UTF-16 length of a string, the unit the browser slices the string area in. -/
@[inline] def utf16Len (s : String) : UInt32 :=
  s.foldl (fun n c => n + (if c.val < 0x10000 then 1 else 2)) 0

@[inline] def pushU32 (b : ByteArray) (x : UInt32) : ByteArray :=
  b |>.push x.toUInt8 |>.push (x >>> 8).toUInt8 |>.push (x >>> 16).toUInt8 |>.push (x >>> 24).toUInt8

/-- A command buffer under construction, plus the session's interned names. -/
structure Buf where
  ops : ByteArray := ByteArray.emptyWithCapacity 4096
  strs : ByteArray := ByteArray.emptyWithCapacity 4096
  /-- UTF-16 code units written to `strs` so far. -/
  units : UInt32 := 0
  names : Std.HashMap String UInt32 := {}
  nextName : UInt32 := 1

namespace Buf

@[inline] def w (b : Buf) (x : UInt32) : Buf := { b with ops := pushU32 b.ops x }

/-- Append a string to the string area and write its `(offset, length)`. -/
@[inline] def s (b : Buf) (str : String) : Buf :=
  let n := utf16Len str
  { b with ops := pushU32 (pushU32 b.ops b.units) n, strs := b.strs ++ str.toUTF8, units := b.units + n }

/-- The id of an interned name. On first use this emits `INTERN id str` *before* the caller
starts its own command, so commands are never interleaved. -/
@[inline] def intern (b : Buf) (nm : String) : UInt32 × Buf :=
  match b.names.get? nm with
  | some id => (id, b)
  | none =>
    let id := b.nextName
    (id, ({ b with names := b.names.insert nm id, nextName := id + 1 }.w Op.intern |>.w id |>.s nm))

/-! ### One writer per command (each interns first, then writes the opcode and operands) -/

def createElement (b : Buf) (node : UInt32) (ns : Ns) (tag : String) : Buf :=
  let (t, b) := b.intern tag; b.w Op.createElement |>.w node |>.w ns.code |>.w t
def createText (b : Buf) (node : UInt32) (txt : String) : Buf := b.w Op.createText |>.w node |>.s txt
def setAttr (b : Buf) (node : UInt32) (nm v : String) : Buf :=
  let (n, b) := b.intern nm; b.w Op.setAttr |>.w node |>.w n |>.s v
def removeAttr (b : Buf) (node : UInt32) (nm : String) : Buf :=
  let (n, b) := b.intern nm; b.w Op.removeAttr |>.w node |>.w n
def setProp (b : Buf) (node : UInt32) (nm : String) (v : PropValue) : Buf :=
  let (n, b) := b.intern nm
  match v with
  | .str x => b.w Op.setPropStr |>.w node |>.w n |>.s x
  | .bool x => b.w Op.setPropBool |>.w node |>.w n |>.w (if x then 1 else 0)
  | .num x => b.w Op.setPropNum |>.w node |>.w n |>.s (toString x)
def removeProp (b : Buf) (node : UInt32) (nm : String) : Buf :=
  let (n, b) := b.intern nm; b.w Op.removeProp |>.w node |>.w n
def setText (b : Buf) (node : UInt32) (txt : String) : Buf := b.w Op.setText |>.w node |>.s txt
def appendChild (b : Buf) (parent child : UInt32) : Buf := b.w Op.appendChild |>.w parent |>.w child
def insertBefore (b : Buf) (parent child ref : UInt32) : Buf := b.w Op.insertBefore |>.w parent |>.w child |>.w ref
def remove (b : Buf) (node : UInt32) : Buf := b.w Op.remove |>.w node
def replace (b : Buf) (old new : UInt32) : Buf := b.w Op.replace |>.w old |>.w new
def free (b : Buf) (node : UInt32) : Buf := b.w Op.free |>.w node
def setListener (b : Buf) (node : UInt32) (ev : String) (slot : UInt32) (payload : Payload) (flags : UInt32) : Buf :=
  let (e, b) := b.intern ev; b.w Op.setListener |>.w node |>.w e |>.w slot |>.w payload.code |>.w flags
def removeListener (b : Buf) (node : UInt32) (ev : String) : Buf :=
  let (e, b) := b.intern ev; b.w Op.removeListener |>.w node |>.w e
def mount (b : Buf) (selector : String) (node : UInt32) : Buf := b.w Op.mount |>.s selector |>.w node
def hydrate (b : Buf) (selector : String) (first count : UInt32) : Buf := b.w Op.hydrate |>.s selector |>.w first |>.w count

/-- True if nothing was written since the last `reset`. -/
@[inline] def isEmpty (b : Buf) : Bool := b.ops.size == 0

/-- Drop the written commands and strings, keeping the interned names (they live as long as
the session). -/
@[inline] def reset (b : Buf) : Buf := { b with ops := ByteArray.emptyWithCapacity 4096, strs := ByteArray.emptyWithCapacity 4096, units := 0 }

/-- The encoded update: `[u32 opsBytes][ops][strs]`, the format of a server-driven response. -/
def encode (b : Buf) : ByteArray := pushU32 ByteArray.empty b.ops.size.toUInt32 ++ b.ops ++ b.strs

end Buf
end LeanUI
