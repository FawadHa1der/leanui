module
public import LeanUI
meta import LeanUI.Syntax
public section
open LeanUI

namespace Counter

inductive Msg | inc | dec | set (n : Int) | reset

def update : Msg → Int → Int × Cmd Msg
  | .inc, n => (n + 1, .none)
  | .dec, n => (n - 1, .none)
  | .set k, _ => (k, .none)
  | .reset, _ => (0, .log "reset")

def view (n : Int) : Html Msg :=
  <main class="counter">
    <h1>LeanUI counter</h1>
    <p>
      <button id="dec" onClick={.dec}>−</button>
      <output id="value" class={if n < 0 then "neg" else "pos"}>{n}</output>
      <button id="inc" onClick={.inc}>+</button>
    </p>
    <p>
      <input id="box" type="number" value={toString n} onInput={fun s => .set (s.toInt?.getD n)} />
      <button id="reset" onClick={.reset}>reset</button>
    </p>
  </main>

def program : Program Int Msg := { init := fun _ => (0, .none), update, view }

end Counter
