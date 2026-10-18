module
public import LeanUI.Html
/-!
# Server-side rendering

`Html.render` prints a view as HTML, so a native Lean server can send a page that is complete
before any wasm loads. The output is also a *hydration contract*: the browser can adopt the
server-rendered nodes instead of recreating them. Hydration walks the DOM in pre-order and must
meet exactly the nodes `mount` allocates, so two things the HTML parser would otherwise lose are
marked with comments: a boundary between adjacent text nodes (`<!--|-->`, or the parser would
merge them) and an empty text node (`<!--t-->`, or it would not exist).
-/
public section
namespace LeanUI

/-- Elements that have no closing tag and no children. -/
def voidElements : List String :=
  ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

def escapeHtml (attr : Bool) (acc : String) (s : String) : String :=
  s.foldl (init := acc) fun acc c =>
    if c == '&' then acc ++ "&amp;" else if c == '<' then acc ++ "&lt;" else if c == '>' then acc ++ "&gt;"
    else if attr && c == '"' then acc ++ "&quot;" else acc.push c

private def renderAttrs (acc : String) (attrs : Array (Attr Msg)) : String :=
  attrs.foldl (init := acc) fun acc a =>
    match a with
    | .attr n v => escapeHtml true (acc ++ " " ++ n ++ "=\"") v ++ "\""
    -- initial property values become attributes, so the page is right before wasm runs
    | .prop n (.str v) => escapeHtml true (acc ++ " " ++ n ++ "=\"") v ++ "\""
    | .prop n (.bool true) => acc ++ " " ++ n
    | .prop n (.num x) => acc ++ " " ++ n ++ "=\"" ++ toString x ++ "\""
    | _ => acc

partial def Html.renderInto {Msg : Type} (acc : String) : Html Msg → String
  | .text "" => acc ++ "<!--t-->"
  | .text s => escapeHtml false acc s
  | .lazy _ _ r => (r ()).renderInto acc
  | .elem _ tag attrs kids =>
    let acc := renderAttrs (acc ++ "<" ++ tag) attrs ++ ">"
    if voidElements.contains tag then acc
    else
      let (acc, _) := kids.foldl (init := (acc, false)) fun (acc, prevText) k =>
        let isText := match k.force with | .text _ => true | _ => false
        let acc := if prevText && isText then acc ++ "<!--|-->" else acc
        (k.renderInto acc, isText)
      acc ++ "</" ++ tag ++ ">"

/-- The view as an HTML string (the container's inner HTML for hydration). -/
def Html.render {Msg : Type} (h : Html Msg) : String := h.renderInto ""

end LeanUI
