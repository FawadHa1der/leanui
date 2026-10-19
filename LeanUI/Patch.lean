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

/-- UTF-16 length of a string, the unit the browser slices the string area in. An ASCII string
(byte size = character count, both stored in the string object) needs no walk. -/
@[inline] def utf16Len (s : String) : UInt32 :=
  if s.utf8ByteSize == s.length then s.length.toUInt32
  else s.foldl (fun n c => n + (if c.val < 0x10000 then 1 else 2)) 0

/-! ### Writing bytes

A buffer for 1,000 benchmark rows holds 122,000 words and 10,000 strings, so the two primitives
below are the hot path of every update. Their Lean bodies are the specification (what the kernel
and proofs see); compiled code uses the C expression in `extern c inline` instead, which the Lean
compiler pastes at each call site, natively and in wasm alike (no C file, no build step). When the
array is exclusive and has room (almost always: capacity doubles as it grows), the C stores the
bytes and bumps the size, with no call at all; otherwise it runs what the Lean body compiles to
(`lean_byte_array_push`; `lean_string_to_utf8` and `lean_byte_array_copy_slice`), which copies or
grows the array. Byte stores keep the layout little-endian on any host (the C compiler merges them
into one store). The snippets are GNU statement expressions (`({ … })`), which clang (`leanc`,
`emcc`) and GCC accept.

The interpreter has no code of its own for an inline C extern, so code that writes a `Buf`
(mounting, diffing, `LeanUI.Testing`) needs the compiled LeanUI library. Executables and wasm
link it. Under `#eval` or `lean --run` it fails ("Could not find native implementation of
external declaration 'LeanUI.pushU32'") unless the library is loaded:

    lake build LeanUI:shared
    lake env lean --load-dynlib=.lake/build/lib/libleanui_LeanUI.dylib File.lean   # .so on Linux

(`tests/browser/keyed-dom.mjs` runs `tests/KeyedDom.lean` this way). A downstream library with
`precompileModules = true` gets it loaded automatically, in `lake build` and in the editor.
Views and `Html.render` do not touch a `Buf` and stay interpretable without it. -/

/-- Append a little-endian `u32`. -/
@[extern c inline "({ lean_object *a_ = #1; uint32_t x_ = #2; size_t n_ = lean_sarray_size(a_); \
  if (LEAN_LIKELY(lean_is_exclusive(a_) && lean_sarray_capacity(a_) - n_ >= 4)) { \
    uint8_t *p_ = lean_sarray_cptr(a_) + n_; \
    p_[0] = (uint8_t)x_; p_[1] = (uint8_t)(x_ >> 8); p_[2] = (uint8_t)(x_ >> 16); p_[3] = (uint8_t)(x_ >> 24); \
    lean_to_sarray(a_)->m_size = n_ + 4; \
  } else { \
    a_ = lean_byte_array_push(a_, (uint8_t)x_); a_ = lean_byte_array_push(a_, (uint8_t)(x_ >> 8)); \
    a_ = lean_byte_array_push(a_, (uint8_t)(x_ >> 16)); a_ = lean_byte_array_push(a_, (uint8_t)(x_ >> 24)); \
  } a_; })"]
def pushU32 (b : ByteArray) (x : UInt32) : ByteArray :=
  b |>.push x.toUInt8 |>.push (x >>> 8).toUInt8 |>.push (x >>> 16).toUInt8 |>.push (x >>> 24).toUInt8

/-- Append a string's UTF-8 bytes: `b ++ s.toUTF8`, but copied straight from the string object
(one `memcpy`, no intermediate `ByteArray`). -/
@[extern c inline "({ lean_object *a_ = #1; lean_object *s_ = #2; size_t n_ = lean_sarray_size(a_); \
  size_t k_ = lean_string_size(s_) - 1; \
  if (LEAN_LIKELY(lean_is_exclusive(a_) && lean_sarray_capacity(a_) - n_ >= k_)) { \
    __builtin_memcpy(lean_sarray_cptr(a_) + n_, lean_string_cstr(s_), k_); lean_to_sarray(a_)->m_size = n_ + k_; \
  } else { \
    extern lean_object *lean_string_to_utf8(lean_object *); \
    extern lean_object *lean_byte_array_copy_slice(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *, uint8_t); \
    lean_object *t_ = lean_string_to_utf8(s_); \
    a_ = lean_byte_array_copy_slice(t_, lean_box(0), a_, lean_box(n_), lean_box(k_), 0); lean_dec_ref(t_); \
  } a_; })"]
def appendUtf8 (b : ByteArray) (s : @& String) : ByteArray := b ++ s.toUTF8

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
  { b with ops := pushU32 (pushU32 b.ops b.units) n, strs := appendUtf8 b.strs str, units := b.units + n }

/-- Define `nm` if it is new: give it the next id and emit `INTERN id nm`. Out of line: it runs
on a lookup miss, once per name and session, while `named` is inlined into every command writer.

A miss means `getD … 0` returned 0, and ids start at 1, so the name is almost always new. It can
be known with id 0 only in a `Buf` built with `nextName := 0`, or after 2³² names when the
counter wraps; then this leaves the buffer as it is, and the caller reads the id again. -/
@[noinline] private def define (b : Buf) (nm : String) : Buf :=
  if b.names.contains nm then b
  else
    let id := b.nextName
    { b with names := b.names.insert nm id, nextName := id + 1 }.w Op.intern |>.w id |>.s nm

/-- The id of an interned name. On first use this emits `INTERN id str` *before* the caller
starts its own command, so commands are never interleaved.

The lookup is `getD … 0`, which allocates no `Option`. On a miss, `define` adds the name unless
it is already there with id 0, and the id is looked up again: two more lookups per new name and
session, and exact for every starting `nextName`. (Checking `contains` here instead keeps the
name map alive across the hot lookup, which measured 2–5% slower natively on the benchmark's
creates.) -/
@[inline] def intern (b : Buf) (nm : String) : UInt32 × Buf :=
  let id := b.names.getD nm 0
  if id != 0 then (id, b)
  else
    let b := b.define nm
    (b.names.getD nm 0, b)

/-- `k` applied to the buffer and the id of `nm`, interned first if new (`intern` in continuation
form, with the same lookup; the command writers use it). Each `k` below is a call to an
out-of-line writer that takes the id, so the buffer stays one object that every write updates in
place. (When `k` writes the words itself, or through `intern`'s pair, the compiler takes the
buffer apart where the branches meet and allocates a new one for every command: 18 per benchmark
row.) -/
@[inline] def named (b : Buf) (nm : String) (k : Buf → UInt32 → Buf) : Buf :=
  let id := b.names.getD nm 0
  if id != 0 then k b id
  else
    let b := b.define nm
    k b (b.names.getD nm 0)

/-! ### One writer per command (each interns first, then writes the opcode and operands) -/

@[noinline] private def createElementId (b : Buf) (node : UInt32) (ns : Ns) (t : UInt32) : Buf :=
  b.w Op.createElement |>.w node |>.w ns.code |>.w t
@[noinline] private def setAttrId (b : Buf) (node n : UInt32) (v : String) : Buf :=
  b.w Op.setAttr |>.w node |>.w n |>.s v
@[noinline] private def removeAttrId (b : Buf) (node n : UInt32) : Buf :=
  b.w Op.removeAttr |>.w node |>.w n
@[noinline] private def setPropId (b : Buf) (node n : UInt32) (v : PropValue) : Buf :=
  match v with
  | .str x => b.w Op.setPropStr |>.w node |>.w n |>.s x
  | .bool x => b.w Op.setPropBool |>.w node |>.w n |>.w (if x then 1 else 0)
  | .num x => b.w Op.setPropNum |>.w node |>.w n |>.s (toString x)
@[noinline] private def removePropId (b : Buf) (node n : UInt32) : Buf :=
  b.w Op.removeProp |>.w node |>.w n
@[noinline] private def setListenerId (b : Buf) (node e slot : UInt32) (payload : Payload) (flags : UInt32) : Buf :=
  b.w Op.setListener |>.w node |>.w e |>.w slot |>.w payload.code |>.w flags
@[noinline] private def removeListenerId (b : Buf) (node e : UInt32) : Buf :=
  b.w Op.removeListener |>.w node |>.w e

def createElement (b : Buf) (node : UInt32) (ns : Ns) (tag : String) : Buf :=
  b.named tag fun b t => createElementId b node ns t
def createText (b : Buf) (node : UInt32) (txt : String) : Buf := b.w Op.createText |>.w node |>.s txt
def setAttr (b : Buf) (node : UInt32) (nm v : String) : Buf :=
  b.named nm fun b n => setAttrId b node n v
def removeAttr (b : Buf) (node : UInt32) (nm : String) : Buf :=
  b.named nm fun b n => removeAttrId b node n
def setProp (b : Buf) (node : UInt32) (nm : String) (v : PropValue) : Buf :=
  b.named nm fun b n => setPropId b node n v
def removeProp (b : Buf) (node : UInt32) (nm : String) : Buf :=
  b.named nm fun b n => removePropId b node n
def setText (b : Buf) (node : UInt32) (txt : String) : Buf := b.w Op.setText |>.w node |>.s txt
def appendChild (b : Buf) (parent child : UInt32) : Buf := b.w Op.appendChild |>.w parent |>.w child
def insertBefore (b : Buf) (parent child ref : UInt32) : Buf := b.w Op.insertBefore |>.w parent |>.w child |>.w ref
def remove (b : Buf) (node : UInt32) : Buf := b.w Op.remove |>.w node
def replace (b : Buf) (old new : UInt32) : Buf := b.w Op.replace |>.w old |>.w new
def free (b : Buf) (node : UInt32) : Buf := b.w Op.free |>.w node
def setListener (b : Buf) (node : UInt32) (ev : String) (slot : UInt32) (payload : Payload) (flags : UInt32) : Buf :=
  b.named ev fun b e => setListenerId b node e slot payload flags
def removeListener (b : Buf) (node : UInt32) (ev : String) : Buf :=
  b.named ev fun b e => removeListenerId b node e
def mount (b : Buf) (selector : String) (node : UInt32) : Buf := b.w Op.mount |>.s selector |>.w node
def hydrate (b : Buf) (selector : String) (first count : UInt32) : Buf := b.w Op.hydrate |>.s selector |>.w first |>.w count

/-- `hydrate` placed before everything already written: hydration mounts first and only then
knows how many nodes it claimed. Its selector goes at the end of the string area (offsets are
absolute, so nothing else moves). -/
def prependHydrate (b : Buf) (selector : String) (first count : UInt32) : Buf :=
  let n := utf16Len selector
  let head := pushU32 (pushU32 (pushU32 (pushU32 (pushU32 (ByteArray.emptyWithCapacity 20) Op.hydrate) b.units) n) first) count
  { b with ops := head ++ b.ops, strs := appendUtf8 b.strs selector, units := b.units + n }

/-- True if nothing was written since the last `reset`. -/
@[inline] def isEmpty (b : Buf) : Bool := b.ops.size == 0

/-- Drop the written commands and strings, keeping the interned names (they live as long as
the session). -/
@[inline] def reset (b : Buf) : Buf := { b with ops := ByteArray.emptyWithCapacity 4096, strs := ByteArray.emptyWithCapacity 4096, units := 0 }

/-- The encoded update: `[u32 opsBytes][ops][strs]`, the format of a server-driven response. -/
def encode (b : Buf) : ByteArray := pushU32 ByteArray.empty b.ops.size.toUInt32 ++ b.ops ++ b.strs

end Buf
end LeanUI

/-! ## Template cloning (opcodes 20, 21)

Commands with a variable number of operands: a count, then that many node handles. Opcode 22
(INSERT_MANY, a DocumentFragment insertion of many children) was measured and left out: it made
creating rows slower in Chromium and no faster in Firefox (`docs/PROTOCOL.md`). -/

namespace LeanUI.Op
def template      : UInt32 := 20  -- tid, count, h1..hcount  (snapshot the subtree h1 roots; hs = its nodes in pre-order)
def clone         : UInt32 := 21  -- tid, count, h1..hcount  (a copy of template tid; its nodes become hs in pre-order)
end LeanUI.Op

namespace LeanUI.Buf

/-- Write `count` then the handles `hs[lo:hi]` (only through `w`, whatever `ops` is). A recursive
loop: `for i in [lo:hi]` allocates its range object on every call, one per clone. -/
def handles (b : Buf) (hs : Array UInt32) (lo hi : Nat) : Buf :=
  go (b.w (hi - lo).toUInt32) lo
where
  go (b : Buf) (i : Nat) : Buf := if i < hi then go (b.w hs[i]!) (i + 1) else b
  termination_by hi - i

/-- `TEMPLATE tid count hs`: remember a copy of the subtree rooted at `hs[0]`, whose nodes are
`hs` in pre-order. -/
def template (b : Buf) (tid : UInt32) (hs : Array UInt32) : Buf :=
  (b.w Op.template |>.w tid).handles hs 0 hs.size

/-- `CLONE tid count hs`: copy template `tid`; its nodes, in pre-order, become `hs`. -/
def clone (b : Buf) (tid : UInt32) (hs : Array UInt32) : Buf :=
  (b.w Op.clone |>.w tid).handles hs 0 hs.size

end LeanUI.Buf
