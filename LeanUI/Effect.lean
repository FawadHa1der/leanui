module
public import LeanUI.Patch
/-!
# Effects: commands and subscriptions

`update` returns a `Cmd`: work for the runtime to do after the model changes (an HTTP request, a
timer, storage, navigation). Results come back as messages. `subscriptions` returns the event
sources the app wants *now* (intervals, URL changes); the runtime starts and stops them by
diffing the current set against the previous one, as it does for the DOM.

Effects are commands in the same buffer as DOM changes, so they work identically whether Lean
runs in the page or on a server driving the page. The pixel and file commands (`putImage`,
`download`, `readFile`, `decodeImage`, `grabFrame`) move bytes rather than strings, and work in
the in-page wasm host only (`docs/PROTOCOL.md`, section 8).
-/
public section
namespace LeanUI

structure Request where
  method : String := "GET"
  url : String
  headers : Array (String × String) := #[]
  body : String := ""

structure Response where
  /-- The request completed with a 2xx status. -/
  ok : Bool
  /-- HTTP status, or 0 if the request failed before a response (network error, CORS). -/
  status : Nat
  body : String

/-- RGBA pixels, 8 bits per channel, row-major, straight alpha: the layout of the DOM's
`ImageData`, so a canvas shows them without conversion. -/
structure Bitmap where
  width : Nat
  height : Nat
  /-- `4 * width * height` bytes. -/
  data : ByteArray
  deriving Inhabited

/-- A rectangle of pixels. -/
structure PixelRect where
  x : Nat := 0
  y : Nat := 0
  w : Nat := 0
  h : Nat := 0
  deriving Inhabited, BEq, Repr

inductive Cmd (Msg : Type) where
  | none
  | batch (cs : Array (Cmd Msg))
  /-- Process another message right after this one, before rendering. -/
  | send (m : Msg)
  | fetch (req : Request) (k : Response → Msg)
  | after (ms : Nat) (m : Msg)
  | storageSet (key value : String)
  | storageGet (key : String) (k : Option String → Msg)
  | storageRemove (key : String)
  | pushUrl (url : String)
  | replaceUrl (url : String)
  /-- Focus the first element matching a CSS selector (after this update's DOM changes). -/
  | focus (selector : String)
  | blur (selector : String)
  | scrollIntoView (selector : String)
  | log (s : String)
  | title (s : String)
  /-- Run once on the next animation frame; the timestamp is in milliseconds. -/
  | nextFrame (k : Float → Msg)
  /-- Copy `dirty` (clamped to the bitmap) of `img` to the same place in the first `<canvas>`
  matching `canvas`, once this update's DOM changes are applied, so the canvas may be created by
  this very update. The browser reads the pixels straight from wasm memory (`putImageData` on a
  view of them): no copy in Lean. The canvas's size is the view's business (its `width` and
  `height` attributes); `Cmd.drawBitmap` copies everything. -/
  | putImage (canvas : String) (img : Bitmap) (dirty : PixelRect)
  /-- Offer `data` as a download named `name`, of media type `type`. -/
  | download (name type : String) (data : ByteArray)
  /-- The bytes of a file the browser holds (`LeanUI.FileInfo.id`), or why they could not be read. -/
  | readFile (file : Nat) (k : Except String ByteArray → Msg)
  /-- A file decoded by the browser's image decoders (PNG, JPEG, WebP, GIF's first frame, …) to
  RGBA pixels, or why it could not be. -/
  | decodeImage (file : Nat) (k : Except String Bitmap → Msg)
  /-- The frame a `<video>` (the first match of `video`) shows now, as RGBA pixels, with the
  frame's timestamp in milliseconds (WebCodecs' `VideoFrame.timestamp`: the same for as long as
  the video shows the same frame), or why there is none (no video, no frame yet). -/
  | grabFrame (video : String) (k : Except String (Bitmap × Nat) → Msg)
  /-- A URL for a file the browser holds (an object URL), for a `<video>` or `<img>` to load it. -/
  | fileUrl (file : Nat) (k : String → Msg)

instance : Inhabited (Cmd Msg) := ⟨.none⟩
instance : Append (Cmd Msg) := ⟨fun a b => .batch #[a, b]⟩

def Cmd.map (f : α → β) : Cmd α → Cmd β
  | .none => .none
  | .batch cs => .batch (cs.attach.map fun ⟨c, _⟩ => c.map f)
  | .send m => .send (f m)
  | .fetch r k => .fetch r (f ∘ k)
  | .after ms m => .after ms (f m)
  | .storageSet k v => .storageSet k v
  | .storageGet k g => .storageGet k (f ∘ g)
  | .storageRemove k => .storageRemove k
  | .pushUrl u => .pushUrl u
  | .replaceUrl u => .replaceUrl u
  | .focus s => .focus s
  | .blur s => .blur s
  | .scrollIntoView s => .scrollIntoView s
  | .log s => .log s
  | .title s => .title s
  | .nextFrame k => .nextFrame (f ∘ k)
  | .putImage c i r => .putImage c i r
  | .download n t d => .download n t d
  | .readFile i k => .readFile i (f ∘ k)
  | .decodeImage i k => .decodeImage i (f ∘ k)
  | .grabFrame v k => .grabFrame v (f ∘ k)
  | .fileUrl i k => .fileUrl i (f ∘ k)

/-- Show all of `img` on the canvas (`putImage` with the whole bitmap as the dirty rectangle). -/
def Cmd.drawBitmap (canvas : String) (img : Bitmap) : Cmd Msg :=
  .putImage canvas img { w := img.width, h := img.height }

inductive Sub (Msg : Type) where
  | none
  | batch (ss : Array (Sub Msg))
  /-- A message every `ms` milliseconds. Identified by `ms`. -/
  | every (ms : Nat) (m : Msg)
  /-- The URL after `popstate` (back/forward) and after a click on a link with `data-link`. -/
  | urlChanges (k : String → Msg)
  /-- Key presses anywhere in the document (`keydown` on `document`), as `Ctrl+`, `Alt+`,
  `Shift+`, `Meta+` prefixes and `KeyboardEvent.key` (`LeanUI.Keys.parse`): keyboard shortcuts.
  Presses in text fields, selects and editable content are not reported. -/
  | keys (k : String → Option Msg)

instance : Inhabited (Sub Msg) := ⟨.none⟩

def Sub.map (f : α → β) : Sub α → Sub β
  | .none => .none
  | .batch ss => .batch (ss.attach.map fun ⟨s, _⟩ => s.map f)
  | .every ms m => .every ms (f m)
  | .urlChanges k => .urlChanges (f ∘ k)
  | .keys k => .keys fun s => (k s).map f

/-- Flatten to (identity, ms or 0, handler) triples; the identity is what subscription diffing
compares. -/
partial def Sub.flatten : Sub Msg → Array (String × Nat × (String → Option Msg))
  | .none => #[]
  | .batch ss => ss.foldl (fun acc s => acc ++ s.flatten) #[]
  | .every ms m => #[(s!"every:{ms}", ms, fun _ => some m)]
  | .urlChanges k => #[("url", 0, fun u => some (k u))]
  | .keys k => #[("keys", 0, k)]

namespace Buf
def fetchCmd (b : Buf) (cb : UInt32) (r : Request) : Buf :=
  let hs := "\n".intercalate (r.headers.toList.map fun (k, v) => k ++ ": " ++ v)
  b.w Op.fetch |>.w cb |>.s r.method |>.s r.url |>.s r.body |>.s hs
def timeoutCmd (b : Buf) (cb : UInt32) (ms : Nat) : Buf := b.w Op.timeout |>.w cb |>.w ms.toUInt32
def intervalSet (b : Buf) (sub : UInt32) (ms : Nat) : Buf := b.w Op.intervalSet |>.w sub |>.w ms.toUInt32
def subClear (b : Buf) (sub : UInt32) : Buf := b.w Op.intervalClear |>.w sub
def urlListen (b : Buf) (sub : UInt32) : Buf := b.w Op.urlListen |>.w sub
def storageSetCmd (b : Buf) (k v : String) : Buf := b.w Op.storageSet |>.s k |>.s v
def storageGetCmd (b : Buf) (cb : UInt32) (k : String) : Buf := b.w Op.storageGet |>.w cb |>.s k
def storageRemoveCmd (b : Buf) (k : String) : Buf := b.w Op.storageRemove |>.s k
def urlCmd (b : Buf) (push : Bool) (u : String) : Buf := b.w (if push then Op.urlPush else Op.urlReplace) |>.s u
def focusCmd (b : Buf) (sel : String) : Buf := b.w Op.focus |>.s sel
def blurCmd (b : Buf) (sel : String) : Buf := b.w Op.blur |>.s sel
def scrollCmd (b : Buf) (sel : String) : Buf := b.w Op.scrollIntoView |>.s sel
def logCmd (b : Buf) (s : String) : Buf := b.w Op.log |>.s s
def titleCmd (b : Buf) (s : String) : Buf := b.w Op.title |>.s s
def frameCmd (b : Buf) (cb : UInt32) : Buf := b.w Op.frame |>.w cb
def putImageCmd (b : Buf) (canvas : String) (img : Bitmap) (r : PixelRect) : Buf :=
  -- clamp the dirty rectangle to the bitmap
  let x := min r.x img.width; let y := min r.y img.height
  let w := min r.w (img.width - x); let h := min r.h (img.height - y)
  b.w Op.putImage |>.s canvas |>.blob img.data |>.w img.width.toUInt32 |>.w img.height.toUInt32
    |>.w x.toUInt32 |>.w y.toUInt32 |>.w w.toUInt32 |>.w h.toUInt32
def downloadCmd (b : Buf) (name type : String) (data : ByteArray) : Buf :=
  b.w Op.download |>.s name |>.s type |>.blob data
def fileReadCmd (b : Buf) (cb : UInt32) (file : Nat) : Buf := b.w Op.fileRead |>.w cb |>.w file.toUInt32
def imageDecodeCmd (b : Buf) (cb : UInt32) (file : Nat) : Buf := b.w Op.imageDecode |>.w cb |>.w file.toUInt32
def keysListen (b : Buf) (sub : UInt32) : Buf := b.w Op.keysListen |>.w sub
def frameGrabCmd (b : Buf) (cb : UInt32) (video : String) : Buf := b.w Op.frameGrab |>.w cb |>.s video
def fileUrlCmd (b : Buf) (cb : UInt32) (file : Nat) : Buf := b.w Op.fileUrl |>.w cb |>.w file.toUInt32
end Buf

end LeanUI
