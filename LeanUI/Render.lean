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

/-- Escape text or an attribute value. `\r` is written as a character reference: the HTML parser
turns every literal `\r` (and `\r\n`) into `\n` before anything else. -/
def escapeHtml (attr : Bool) (acc : String) (s : String) : String :=
  s.foldl (init := acc) fun acc c =>
    if c == '&' then acc ++ "&amp;" else if c == '<' then acc ++ "&lt;" else if c == '>' then acc ++ "&gt;"
    else if attr && c == '"' then acc ++ "&quot;" else if c == '\r' then acc ++ "&#13;" else acc.push c

/-- Attributes as the DOM ends up with them after `mount`: for a repeated name only the last one
(the HTML parser would keep the first), and a property's initial value only when no attribute
of that name exists. -/
private def renderAttrs (acc : String) (attrs : Array (Attr Msg)) : String := Id.run do
  let mut acc := acc
  for h : i in [0:attrs.size] do
    let later (p : Attr Msg → Bool) : Bool := Id.run do
      for j in [i + 1:attrs.size] do
        if p attrs[j]! then return true
      return false
    match attrs[i] with
    | .attr n v =>
      if !later (fun | .attr m _ => m == n | _ => false) then
        acc := escapeHtml true (acc ++ " " ++ n ++ "=\"") v ++ "\""
    -- initial property values become attributes, so the page is right before wasm runs
    | .prop n v =>
      if !later (fun | .prop m _ => m == n | _ => false) && !attrs.any (fun | .attr m _ => m == n | _ => false) then
        match v with
        | .str x => acc := escapeHtml true (acc ++ " " ++ n ++ "=\"") x ++ "\""
        | .bool true => acc := acc ++ " " ++ n
        | .bool false => pure ()
        | .num x => acc := acc ++ " " ++ n ++ "=\"" ++ toString x ++ "\""
    | _ => pure ()
  return acc

/-- Elements whose first line feed the HTML parser drops. -/
def lfDroppingElements : List String := ["pre", "textarea", "listing"]

partial def Html.renderInto {Msg : Type} (acc : String) : Html Msg → String
  | .text "" => acc ++ "<!--t-->"
  | .text s => escapeHtml false acc s
  | .lazy _ _ r => (r ()).renderInto acc
  | .elem _ tag attrs kids =>
    let acc := renderAttrs (acc ++ "<" ++ tag) attrs ++ ">"
    if voidElements.contains tag then acc
    else
      -- force each child once (a lazy child's thunk runs one time)
      let kids := kids.map Html.force
      let acc := match kids[0]? with
        | some (Html.text s) => if s.startsWith "\n" && lfDroppingElements.contains tag then acc ++ "\n" else acc
        | _ => acc
      let (acc, _) := kids.foldl (init := (acc, false)) fun (acc, prevText) k =>
        let isText := match k with | Html.text _ => true | _ => false
        let acc := if prevText && isText then acc ++ "<!--|-->" else acc
        (k.renderInto acc, isText)
      acc ++ "</" ++ tag ++ ">"

/-- The view as an HTML string (the container's inner HTML for hydration). -/
def Html.render {Msg : Type} (h : Html Msg) : String := h.renderInto ""

end LeanUI
