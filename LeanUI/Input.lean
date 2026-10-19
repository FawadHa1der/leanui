module
public import LeanUI.Html
/-!
# Pointers, files and keys

The payloads `runtime/leanui.js` extracts for pointer-heavy and file-handling apps (an editor, a
drawing surface), decoded into Lean values, and the handlers that use them:

* `Payload.pointer`: a pointer, mouse or wheel event as `Pointer`, in CSS pixels relative to the
  element that listens (its border box, after CSS transforms), with that element's size, so a
  scaled canvas maps a pointer to its own pixels with `Pointer.scaledTo`.
* `Payload.files`: the files of a `change` on a file input or of a `drop`, as `FileInfo`s. The
  bytes stay in the browser until `Cmd.readFile` or `Cmd.decodeImage` asks for them by id.
* `Sub.keys` (`LeanUI.Effect`) reports document-wide key presses as `"Ctrl+Shift+z"`-style
  strings; `Keys.parse` splits one.

The payload formats are part of the protocol (`docs/PROTOCOL.md`, section 4).
-/
public section
namespace LeanUI

/-- A decimal number as the runtime writes it (`-12.5`, `3`, `0.25`; at most a few fraction
digits, never an exponent). Anything else reads as 0. -/
def parseDecimal (s : String) : Float :=
  let (neg, s) := if s.startsWith "-" then (true, (s.drop 1).toString) else (false, s)
  let (whole, frac) := match s.splitOn "." with
    | [w] => (w, "")
    | [w, f] => (w, f)
    | _ => ("", "")
  if !(whole.all Char.isDigit && frac.all Char.isDigit) || (whole.isEmpty && frac.isEmpty) then 0
  else
    let w := Float.ofNat (whole.toNat?.getD 0)
    let f := if frac.isEmpty then 0 else Float.ofNat (frac.toNat?.getD 0) / Float.ofNat (10 ^ frac.length)
    if neg then -(w + f) else w + f

/-- A pointer, mouse or wheel event (`Payload.pointer`). -/
structure Pointer where
  /-- Position relative to the listening element's top-left corner, in CSS pixels. -/
  x : Float := 0
  y : Float := 0
  /-- The listening element's displayed size, in CSS pixels. -/
  width : Float := 0
  height : Float := 0
  /-- `MouseEvent.buttons`: 1 primary, 2 secondary, 4 middle (a sum while several are down). -/
  buttons : Nat := 0
  shift : Bool := false
  ctrl : Bool := false
  alt : Bool := false
  metaKey : Bool := false
  /-- `PointerEvent.pointerId` (0 for mouse and wheel events). -/
  id : Nat := 0
  /-- `PointerEvent.pressure`, 0 to 1 (0.5 for a mouse with a button down). -/
  pressure : Float := 0
  /-- Wheel deltas in CSS pixels (lines and pages converted); 0 for other events. -/
  deltaX : Float := 0
  deltaY : Float := 0
  /-- Position in the viewport (`clientX`, `clientY`), for drags that move the element itself. -/
  clientX : Float := 0
  clientY : Float := 0
  deriving Inhabited, Repr

/-- Read `x y width height buttons modifiers pointerId pressure deltaX deltaY clientX clientY`
(modifiers: 1 shift, 2 ctrl, 4 alt, 8 meta). -/
def Pointer.parse (s : String) : Option Pointer :=
  match s.splitOn " " with
  | [x, y, w, h, b, m, i, p, dx, dy, cx, cy] =>
    let mods := m.toNat?.getD 0
    some { x := parseDecimal x, y := parseDecimal y, width := parseDecimal w, height := parseDecimal h,
           buttons := b.toNat?.getD 0, shift := mods &&& 1 != 0, ctrl := mods &&& 2 != 0,
           alt := mods &&& 4 != 0, metaKey := mods &&& 8 != 0, id := i.toNat?.getD 0,
           pressure := parseDecimal p, deltaX := parseDecimal dx, deltaY := parseDecimal dy,
           clientX := parseDecimal cx, clientY := parseDecimal cy }
  | _ => none

/-- The position in the coordinates of something `w × h` drawn over the whole element (a canvas
whose backing store is `w × h` pixels, displayed at any size). -/
def Pointer.scaledTo (p : Pointer) (w h : Nat) : Float × Float :=
  (if p.width > 0 then p.x * Float.ofNat w / p.width else p.x,
   if p.height > 0 then p.y * Float.ofNat h / p.height else p.y)

/-- A file the browser holds for the app (`Payload.files`). -/
structure FileInfo where
  /-- Names the file in `Cmd.readFile` and `Cmd.decodeImage`. The runtime keeps the 64 most
  recent files. -/
  id : Nat
  size : Nat
  /-- The media type the browser guessed (`image/png`), possibly empty. -/
  type : String
  name : String
  deriving Inhabited, Repr, BEq

/-- Read the `id\tsize\ttype\tname` lines of a `Payload.files` payload. -/
def FileInfo.parse (s : String) : Array FileInfo :=
  (s.splitOn "\n").toArray.filterMap fun line =>
    match line.splitOn "\t" with
    | i :: sz :: ty :: rest => do
      let id ← i.toNat?
      some { id, size := sz.toNat?.getD 0, type := ty, name := "\t".intercalate rest }
    | _ => none

/-- A key press as `Sub.keys` reports it: `Ctrl+`, `Alt+`, `Shift+` and `Meta+` prefixes (in that
order), then `KeyboardEvent.key`. -/
structure Keys where
  key : String
  ctrl : Bool := false
  alt : Bool := false
  shift : Bool := false
  metaKey : Bool := false
  deriving Inhabited, Repr, BEq

def Keys.parse (s : String) : Keys := Id.run do
  let mut k : Keys := { key := "" }
  let mut rest := s
  for _ in [0:4] do
    if rest.startsWith "Ctrl+" && rest.length > 5 then rest := (rest.drop 5).toString; k := { k with ctrl := true }
    else if rest.startsWith "Alt+" && rest.length > 4 then rest := (rest.drop 4).toString; k := { k with alt := true }
    else if rest.startsWith "Shift+" && rest.length > 6 then rest := (rest.drop 6).toString; k := { k with shift := true }
    else if rest.startsWith "Meta+" && rest.length > 5 then rest := (rest.drop 5).toString; k := { k with metaKey := true }
  return { k with key := rest }

/-- Ctrl, or Meta (⌘ on a Mac): the usual shortcut modifier. -/
def Keys.cmd (k : Keys) : Bool := k.ctrl || k.metaKey

namespace Attr
/-- A pointer event (`pointerdown`, `pointermove`, `pointerup`, `pointerleave`, `click`, …) as a
`Pointer`. `capture` captures the pointer on `pointerdown`, so the element keeps getting its moves
and its `pointerup` while the button is held. -/
@[inline] def onPointer (event : String) (f : Pointer → Option Msg) (capture := false) (preventDefault := false) : Attr Msg :=
  .on event { payload := .pointer, decode := fun s => (Pointer.parse s).bind f, capturePointer := capture, preventDefault }
/-- `wheel`, with the page's own scrolling or zooming prevented. -/
@[inline] def onWheel (f : Pointer → Option Msg) : Attr Msg :=
  .on "wheel" { payload := .pointer, decode := fun s => (Pointer.parse s).bind f, preventDefault := true }
/-- The files chosen in a file input (`change`). -/
@[inline] def onFiles (f : Array FileInfo → Msg) : Attr Msg :=
  .on "change" { payload := .files, decode := fun s => some (f (FileInfo.parse s)) }
/-- Files dropped on the element (`drop`, default prevented so the browser does not open them).
The element needs `onDragOver` too: a drop happens only where `dragover` was prevented. -/
@[inline] def onDrop (f : Array FileInfo → Msg) : Attr Msg :=
  .on "drop" { payload := .files, decode := fun s => some (f (FileInfo.parse s)), preventDefault := true }
/-- `dragover` with its default prevented (which allows a drop); `m` is sent, if given. -/
@[inline] def onDragOver (m : Option Msg := none) : Attr Msg :=
  .on "dragover" { decode := fun _ => m, preventDefault := true }
end Attr

end LeanUI
