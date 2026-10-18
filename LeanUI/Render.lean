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

/-- Escape text (or, with `attr`, a double-quoted attribute value). A carriage return is written
as `&#13;`: the parser would turn a literal one (and `\r\n`) into `\n`. -/
def escapeHtml (attr : Bool) (acc : String) (s : String) : String :=
  s.foldl (init := acc) fun acc c =>
    if c == '&' then acc ++ "&amp;" else if c == '<' then acc ++ "&lt;" else if c == '>' then acc ++ "&gt;"
    else if attr && c == '"' then acc ++ "&quot;" else if c == '\r' then acc ++ "&#13;" else acc.push c

/-- The name an attribute renders under, if it renders. -/
private def renderedName : Attr Msg → Option String
  | .attr n _ | .prop n (.str _) | .prop n (.num _) => some n
  | .prop n (.bool true) => some n
  | _ => none

/-- Of attributes rendering under the same name only the last is written: the HTML parser keeps
the *first* of duplicates, while mounting (`setAttribute` in order) leaves the last, and
hydration does not resend attributes. -/
private def renderAttrs (acc : String) (attrs : Array (Attr Msg)) : String :=
  let laterSame (i : Nat) : Bool := match renderedName attrs[i]! with
    | some n => (List.range' (i + 1) (attrs.size - i - 1)).any fun j => renderedName attrs[j]! == some n
    | none => false
  -- attribute lists are short; the common case (no duplicates) allocates nothing extra
  let dups := attrs.size > 1 && (List.range attrs.size).any laterSame
  let attrs := if !dups then attrs else
    ((List.range attrs.size).filterMap fun i => if laterSame i then none else some attrs[i]!).toArray
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
  | .lazy _ r => (r ()).renderInto acc
  | .elem _ tag attrs kids =>
    let acc := renderAttrs (acc ++ "<" ++ tag) attrs ++ ">"
    if voidElements.contains tag then acc
    else
      -- the parser drops a newline right after these start tags, so a leading one is doubled
      let lead := match kids[0]?.map Html.force with
        | some (.text t) => t.startsWith "\n" && (tag == "pre" || tag == "textarea" || tag == "listing")
        | _ => false
      let acc := if lead then acc ++ "\n" else acc
      let (acc, _) := kids.foldl (init := (acc, false)) fun (acc, prevText) k =>
        let isText := match k.force with | .text _ => true | _ => false
        let acc := if prevText && isText then acc ++ "<!--|-->" else acc
        (k.renderInto acc, isText)
      acc ++ "</" ++ tag ++ ">"

/-- The view as an HTML string (the container's inner HTML for hydration). -/
def Html.render {Msg : Type} (h : Html Msg) : String := h.renderInto ""

end LeanUI
