module
public import LeanUI.Patch
/-!
# Effects: commands and subscriptions

`update` returns a `Cmd`: work for the runtime to do after the model changes (an HTTP request, a
timer, storage, navigation). Results come back as messages. `subscriptions` returns the event
sources the app wants *now* (intervals, URL changes); the runtime starts and stops them by
diffing the current set against the previous one, as it does for the DOM.

Effects are commands in the same buffer as DOM changes, so they work identically whether Lean
runs in the page or on a server driving the page.
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

inductive Sub (Msg : Type) where
  | none
  | batch (ss : Array (Sub Msg))
  /-- A message every `ms` milliseconds. Identified by `ms`. -/
  | every (ms : Nat) (m : Msg)
  /-- The URL after `popstate` (back/forward) and after a click on a link with `data-link`. -/
  | urlChanges (k : String → Msg)

instance : Inhabited (Sub Msg) := ⟨.none⟩

def Sub.map (f : α → β) : Sub α → Sub β
  | .none => .none
  | .batch ss => .batch (ss.attach.map fun ⟨s, _⟩ => s.map f)
  | .every ms m => .every ms (f m)
  | .urlChanges k => .urlChanges (f ∘ k)

/-- Flatten to (identity, ms or 0, handler) triples; the identity is what subscription diffing
compares. -/
partial def Sub.flatten : Sub Msg → Array (String × Nat × (String → Option Msg))
  | .none => #[]
  | .batch ss => ss.foldl (fun acc s => acc ++ s.flatten) #[]
  | .every ms m => #[(s!"every:{ms}", ms, fun _ => some m)]
  | .urlChanges k => #[("url", 0, fun u => some (k u))]

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
end Buf

end LeanUI
