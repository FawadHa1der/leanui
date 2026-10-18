module
public import LeanUI
public import LeanUI.Host.Wasm
/-!
# A wasm probe for deeply nested views

Every engine pass (`mount`, `patch`, `release`, `Html.render`) recurses once per nesting level,
and the wasm build runs with a 1 MiB stack (`-sSTACK_SIZE` in `tools/build-app.sh`). This app
shows a chain of `depth` nested elements; `tests/browser/depth.mjs` raises the depth until the
app fails, to find the nesting a LeanUI page supports and how it fails beyond that.

    LEANUI_TOOLCHAIN=… tools/build-app.sh LeanUI.Testing.DepthProbe depth-probe

(Not part of any library: `lake build` does not build it; the app build does.)
-/
public section
open LeanUI

namespace DepthProbe

inductive Msg | depth (d : Nat) | label (s : String)

structure Model where
  depth : Nat := 1
  label : String := "leaf"

/-- `d` nested elements (alternating `div`/`span`) around one text. -/
def chain (d : Nat) (label : String) : Html Msg := Id.run do
  let mut v : Html Msg := text label
  for i in [0:d] do v := el (if i % 2 == 0 then "div" else "span") #[Attr.cls "c"] #[v]
  return v

def view (m : Model) : Html Msg :=
  el "main" #[] #[
    el "input" #[Attr.id "depth", Attr.onInput fun s => .depth (s.toNat?.getD 1)] #[],
    el "input" #[Attr.id "label", Attr.onInput .label] #[],
    el "output" #[Attr.id "shown"] #[text s!"{m.depth}:{m.label}"],
    -- display:none: browsers cannot lay out a DOM a few thousand levels deep (Chromium crashes
    -- at 2000 nested divs built by plain JavaScript), and this probe measures the engine only
    el "section" #[Attr.id "chain", .attr "style" "display:none"] #[chain m.depth m.label]]

def program : Program Model Msg where
  init _ := ({}, .none)
  update msg m := match msg with
    | .depth d => ({ m with depth := d }, .none)
    | .label s => ({ m with label := s }, .none)
  view := view

end DepthProbe

leanui_app DepthProbe.program
