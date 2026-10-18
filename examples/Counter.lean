module
public import LeanUI
public import LeanUI.Host.Wasm
public section
open LeanUI Attr

namespace Examples.Counter

inductive Msg | inc | dec | set (n : Int) | reset

def update : Msg → Int → Int × Cmd Msg
  | .inc, n => (n + 1, .none)
  | .dec, n => (n - 1, .none)
  | .set k, _ => (k, .none)
  | .reset, _ => (0, .log "reset")

def view (n : Int) : Html Msg :=
  el "main" #[cls "counter"] #[
    el "h1" #[] #[text "LeanUI counter"],
    el "p" #[] #[
      el "button" #[id "dec", onClick .dec] #[text "−"],
      el "output" #[id "value", cls (if n < 0 then "neg" else "pos")] #[text (toString n)],
      el "button" #[id "inc", onClick .inc] #[text "+"]],
    el "p" #[] #[
      el "input" #[id "box", Attr.attr "type" "number", value (toString n),
        onInput fun s => .set (s.toInt?.getD n)] #[],
      el "button" #[id "reset", onClick .reset] #[text "reset"]]]

def program : Program Int Msg := { init := fun _ => (0, .none), update, view }

end Examples.Counter

leanui_app Examples.Counter.program
