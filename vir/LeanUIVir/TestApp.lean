module
public import LeanUIVir.Host
public section

namespace LeanUIVir.TestApp
open LeanUI

structure Model where
  stored : String := "pending"
  delayed : Nat := 0
  ticks : Nat := 0
  running : Bool := false
  order : String := ""
  fetched : String := "pending"

inductive Msg where
  | stored (value : Option String)
  | delayed | tick | toggle | focus | focused | key | url | fetch | delay | frame
  | fetched (result : Response)

def update : Msg → Model → Model × Cmd Msg
  | .stored value, m => ({ m with stored := value.getD "absent" }, .none)
  | .delayed, m => ({ m with delayed := m.delayed + 1 }, .none)
  | .tick, m => ({ m with ticks := m.ticks + 1 }, .none)
  | .toggle, m => ({ m with running := !m.running }, .none)
  | .focus, m => ({ m with order := m.order ++ "event;" }, .focus "#probe-input")
  | .focused, m => ({ m with order := m.order ++ "focus;" }, .none)
  | .key, m => ({ m with order := m.order ++ "key;" }, .none)
  | .url, m => ({ m with order := m.order ++ "url;" }, .none)
  | .fetch, m => (m, .fetch { url := "/slow" } .fetched)
  | .delay, m => (m, .after 60000 .delayed)
  | .frame, m => (m, .nextFrame (fun _ => .delayed))
  | .fetched r, m => ({ m with fetched := r.body }, .none)

def output (name value : String) : Html Msg := el "output" #[Attr.id name] #[text value]
def button (name : String) (msg : Msg) : Html Msg := el "button" #[Attr.id name, Attr.onClick msg] #[text name]

def view (m : Model) : Html Msg :=
  el "div" #[] #[
    output "stored" m.stored, output "delayed" (toString m.delayed),
    output "ticks" (toString m.ticks), output "order" m.order, output "fetched" m.fetched,
    button "toggle" .toggle, button "focus" .focus, button "fetch" .fetch,
    button "delay" .delay, button "frame" .frame,
    el "input" #[Attr.id "probe-input", Attr.on "focus" { decode := fun _ => some .focused }] #[]]

def program : Program Model Msg := {
  init := fun flags => ({}, if flags == "fail" then
    .batch #[.after 60000 .delayed, .fetch { url := "/slow" } .fetched,
      .nextFrame (fun _ => .delayed), .pushUrl "http://["]
    else .batch #[.storageGet "leanui.vir.probe" .stored, .after 5 .delayed])
  update, view
  subscriptions := fun m => .batch #[
    (if m.running then .every 10 .tick else .none),
    .keys (fun k => if k == "p" then some .key else none), .urlChanges (fun _ => .url)]
}

leanui_vir_app program

/-- Exercise a recoverable IO error without changing the app's state. -/
@[vir_export] def reject : IO Unit := throw (IO.userError "injected call failure")
end LeanUIVir.TestApp
