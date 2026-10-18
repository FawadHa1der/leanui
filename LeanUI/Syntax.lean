module
public meta import Lean
public import LeanUI.Html
/-!
# JSX-style templates

```
<ul class="todo-list">
  {...m.todos.map fun t =>
    <li key={t.id} class:completed={t.done}>
      <input class="toggle" type="checkbox" checked={t.done} onCheck={fun _ => .toggle t.id} />
      <label onDblClick={.edit t.id}>{t.title}</label>
    </li>}
</ul>
```

is a term of type `Html Msg`. The reference is `docs/SYNTAX.md`; this module is the
implementation.

**Zero runtime cost.** Everything here is compile-time code (`meta`). An app reaches it only
through `meta import LeanUI.Syntax`, so neither this module nor the Lean compiler it imports is
linked into the app. A template expands to exactly the constructors one would write by hand:
`Html.elem`, `Html.text`, `Attr.attr`, `Attr.prop`, `Attr.key`, the `Attr.on*` helpers, array
literals and `toString`. Conversions that depend on the type of an interpolated value (a `String`
child becomes a text node, a `Nat` attribute becomes its decimal string, a `Bool` property becomes
`PropValue.bool`, ...) are decided by small elaborators while the template is compiled, not by
type classes at run time.

**Parsing.** Names (`data-id`, `on:click`, `.value`, `class:done`, `svg:a`, `Ui.Card`) and text
runs are custom tokens, so attribute names may contain dashes and colons and text may contain
any character except `{`, `<`, `>` and `}`. Lean's tokenizer attaches the whitespace after a token
to that token, so a text run recovers the whitespace before it from the input (otherwise
`<b>x</b> y` would lose the space before `y`). A closing tag is checked against its opening tag
while parsing, so a mismatch is reported where it happens instead of as a confusing error at the
end of the template. A template is a leading term (`jsxTerm`); as a function argument (`jsxArg`,
where `<` is also less-than) it is recognised only when a complete opening tag follows, which keeps
`a <b then c` a comparison; `jsxCont` reports the one place where Lean would read a template as
`… < …`, a template on the line after `let x := v`.

**Elaboration.** `transform` turns the element tree into constructor syntax (`buildArray` makes
array literals, with pushes for splices and conditional parts) and the `leanui_jsx_*%` elaborators
fill in the type-directed conversions (`withValue`: elaborate the value once, decide from its type,
postpone only the decision while the type is unknown).
-/
public section
namespace LeanUI.Syntax
open Lean Parser Elab Term Meta

/-! ## Tables -/

/-- HTML elements (WHATWG), for the unknown-element warning. -/
meta def htmlTags : List String := [
  "a", "abbr", "address", "area", "article", "aside", "audio", "b", "base", "bdi", "bdo",
  "blockquote", "body", "br", "button", "canvas", "caption", "cite", "code", "col", "colgroup",
  "data", "datalist", "dd", "del", "details", "dfn", "dialog", "div", "dl", "dt", "em", "embed",
  "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head",
  "header", "hgroup", "hr", "html", "i", "iframe", "img", "input", "ins", "kbd", "label", "legend",
  "li", "link", "main", "map", "mark", "menu", "meta", "meter", "nav", "noscript", "object", "ol",
  "optgroup", "option", "output", "p", "picture", "pre", "progress", "q", "rp", "rt", "ruby", "s",
  "samp", "script", "search", "section", "select", "selectedcontent", "slot", "small", "source",
  "span", "strong", "style", "sub", "summary", "sup", "table", "tbody", "td", "template",
  "textarea", "tfoot", "th", "thead", "time", "title", "tr", "track", "u", "ul", "var", "video",
  "wbr"]

/-- SVG elements. -/
meta def svgTags : List String := [
  "a", "animate", "animateMotion", "animateTransform", "circle", "clipPath", "defs", "desc",
  "ellipse", "feBlend", "feColorMatrix", "feComponentTransfer", "feComposite", "feConvolveMatrix",
  "feDiffuseLighting", "feDisplacementMap", "feDistantLight", "feDropShadow", "feFlood", "feFuncA",
  "feFuncB", "feFuncG", "feFuncR", "feGaussianBlur", "feImage", "feMerge", "feMergeNode",
  "feMorphology", "feOffset", "fePointLight", "feSpecularLighting", "feSpotLight", "feTile",
  "feTurbulence", "filter", "foreignObject", "g", "image", "line", "linearGradient", "marker",
  "mask", "metadata", "mpath", "path", "pattern", "polygon", "polyline", "radialGradient", "rect",
  "script", "set", "stop", "style", "svg", "switch", "symbol", "text", "textPath", "title", "tspan",
  "use", "view"]

/-- MathML Core elements (plus the common legacy ones). -/
meta def mathmlTags : List String := [
  "math", "maction", "annotation", "annotation-xml", "menclose", "merror", "mfenced", "mfrac", "mi",
  "mmultiscripts", "mn", "mo", "mover", "mpadded", "mphantom", "mprescripts", "mroot", "mrow", "ms",
  "mspace", "msqrt", "mstyle", "msub", "msubsup", "msup", "mtable", "mtd", "mtext", "mtr", "munder",
  "munderover", "semantics"]

/-- Elements with no content and no end tag. -/
meta def voidTags : List String :=
  ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

/-- HTML boolean attributes: present or absent. Given `{b : Bool}` they are added only when `b`. -/
meta def booleanAttrs : List String := [
  "allowfullscreen", "async", "autofocus", "autoplay", "controls", "default", "defer", "disabled",
  "formnovalidate", "hidden", "inert", "ismap", "itemscope", "loop", "multiple", "nomodule",
  "novalidate", "open", "playsinline", "readonly", "required", "reversed"]

/-- Live form state: given `{e}` these set the DOM property, not the attribute (an attribute only
sets the initial value, so a controlled input would stop following the model once edited). -/
meta def liveProps : List String := ["value", "checked", "selected", "indeterminate", "muted"]

/-- DOM event names, to recognise inline JavaScript handlers (`onclick="…"`). -/
meta def domEvents : List String := [
  "abort", "animationend", "animationiteration", "animationstart", "auxclick", "beforeinput",
  "beforeunload", "blur", "cancel", "canplay", "canplaythrough", "change", "click", "close",
  "contextmenu", "copy", "cut", "dblclick", "drag", "dragend", "dragenter", "dragleave", "dragover",
  "dragstart", "drop", "durationchange", "ended", "error", "focus", "focusin", "focusout",
  "formdata", "hashchange", "input", "invalid", "keydown", "keypress", "keyup", "load",
  "loadeddata", "loadedmetadata", "loadstart", "message", "mousedown", "mouseenter", "mouseleave",
  "mousemove", "mouseout", "mouseover", "mouseup", "paste", "pause", "play", "playing",
  "pointercancel", "pointerdown", "pointerenter", "pointerleave", "pointermove", "pointerout",
  "pointerover", "pointerup", "popstate", "progress", "ratechange", "reset", "resize", "scroll",
  "scrollend", "seeked", "seeking", "select", "selectionchange", "submit", "timeupdate", "toggle",
  "touchcancel", "touchend", "touchmove", "touchstart", "transitionend", "unload",
  "volumechange", "waiting", "wheel"]

/-- `on<Event>` shorthands: the `Attr` helper and the DOM event it listens to. -/
meta def shorthands : List (String × Name × String × String) := [
  ("onClick", ``LeanUI.Attr.onClick, "click", "a message `Msg`"),
  ("onDblClick", ``LeanUI.Attr.onDblClick, "dblclick", "a message `Msg`"),
  ("onInput", ``LeanUI.Attr.onInput, "input", "a function `String → Msg` (the input's value)"),
  ("onChange", ``LeanUI.Attr.onChange, "change", "a function `String → Msg` (the value)"),
  ("onCheck", ``LeanUI.Attr.onCheck, "change", "a function `Bool → Msg` (`checked`)"),
  ("onKeyDown", ``LeanUI.Attr.onKeyDown, "keydown", "a function `String → Option Msg` (`KeyboardEvent.key`)"),
  ("onSubmit", ``LeanUI.Attr.onSubmit, "submit", "a function `String → Msg` (the form's fields)"),
  ("onBlur", ``LeanUI.Attr.onBlur, "focusout", "a message `Msg`")]

/-- Named character references accepted in text (`&amp;`, `&nbsp;`, ...). Numeric references
(`&#169;`, `&#x1F600;`) are always accepted. -/
meta def entities : List (String × Nat) := [
  ("amp", 38), ("lt", 60), ("gt", 62), ("quot", 34), ("apos", 39), ("nbsp", 160),
  ("lbrace", 123), ("rbrace", 125), ("lcub", 123), ("rcub", 125), ("ensp", 8194), ("emsp", 8195),
  ("thinsp", 8201), ("zwnj", 8204), ("zwj", 8205), ("lrm", 8206), ("rlm", 8207), ("shy", 173),
  ("copy", 169), ("reg", 174), ("trade", 8482), ("deg", 176), ("plusmn", 177), ("times", 215),
  ("divide", 247), ("micro", 181), ("middot", 183), ("para", 182), ("sect", 167), ("laquo", 171),
  ("raquo", 187), ("lsquo", 8216), ("rsquo", 8217), ("sbquo", 8218), ("ldquo", 8220),
  ("rdquo", 8221), ("bdquo", 8222), ("ndash", 8211), ("mdash", 8212), ("hellip", 8230),
  ("bull", 8226), ("prime", 8242), ("Prime", 8243), ("lsaquo", 8249), ("rsaquo", 8250),
  ("euro", 8364), ("cent", 162), ("pound", 163), ("yen", 165), ("curren", 164), ("iexcl", 161),
  ("iquest", 191), ("brvbar", 166), ("uml", 168), ("ordf", 170), ("ordm", 186), ("not", 172),
  ("macr", 175), ("acute", 180), ("cedil", 184), ("sup1", 185), ("sup2", 178), ("sup3", 179),
  ("frac14", 188), ("frac12", 189), ("frac34", 190), ("dagger", 8224), ("Dagger", 8225),
  ("permil", 8240), ("larr", 8592), ("uarr", 8593), ("rarr", 8594), ("darr", 8595),
  ("harr", 8596), ("crarr", 8629), ("lArr", 8656), ("uArr", 8657), ("rArr", 8658),
  ("dArr", 8659), ("hArr", 8660), ("forall", 8704), ("part", 8706), ("exist", 8707),
  ("empty", 8709), ("nabla", 8711), ("isin", 8712), ("notin", 8713), ("ni", 8715),
  ("prod", 8719), ("sum", 8721), ("minus", 8722), ("lowast", 8727), ("radic", 8730),
  ("prop", 8733), ("infin", 8734), ("ang", 8736), ("and", 8743), ("or", 8744), ("cap", 8745),
  ("cup", 8746), ("int", 8747), ("there4", 8756), ("sim", 8764), ("cong", 8773),
  ("asymp", 8776), ("ne", 8800), ("equiv", 8801), ("le", 8804), ("ge", 8805), ("sub", 8834),
  ("sup", 8835), ("nsub", 8836), ("sube", 8838), ("supe", 8839), ("oplus", 8853),
  ("otimes", 8855), ("perp", 8869), ("sdot", 8901), ("lceil", 8968), ("rceil", 8969),
  ("lfloor", 8970), ("rfloor", 8971), ("lang", 10216), ("rang", 10217), ("loz", 9674),
  ("spades", 9824), ("clubs", 9827), ("hearts", 9829), ("diams", 9830), ("check", 10003),
  ("cross", 10007), ("star", 9734), ("starf", 9733),
  ("Alpha", 913), ("Beta", 914), ("Gamma", 915), ("Delta", 916), ("Epsilon", 917), ("Zeta", 918),
  ("Eta", 919), ("Theta", 920), ("Iota", 921), ("Kappa", 922), ("Lambda", 923), ("Mu", 924),
  ("Nu", 925), ("Xi", 926), ("Omicron", 927), ("Pi", 928), ("Rho", 929), ("Sigma", 931),
  ("Tau", 932), ("Upsilon", 933), ("Phi", 934), ("Chi", 935), ("Psi", 936), ("Omega", 937),
  ("alpha", 945), ("beta", 946), ("gamma", 947), ("delta", 948), ("epsilon", 949), ("zeta", 950),
  ("eta", 951), ("theta", 952), ("iota", 953), ("kappa", 954), ("lambda", 955), ("mu", 956),
  ("nu", 957), ("xi", 958), ("omicron", 959), ("pi", 960), ("rho", 961), ("sigmaf", 962),
  ("sigma", 963), ("tau", 964), ("upsilon", 965), ("phi", 966), ("chi", 967), ("psi", 968),
  ("omega", 969)]

/-! ## Tokens -/

/-- Can a JSX name start with `c`? Letters, `_`, and `.` (a DOM property, `.value`). -/
meta def isNameStart (c : Char) : Bool := c.isAlpha || c == '_' || c == '.'

/-- Characters inside a JSX name: `data-id`, `on:click`, `class:done`, `Ui.Card`, `onClick|prevent`,
`title?`. What each name may actually contain is checked when the template is elaborated. -/
meta def isNameChar (c : Char) : Bool :=
  c.isAlphanum || c == '-' || c == '_' || c == ':' || c == '.' || c == '|' || c == '?'

/-- Characters that end a text run. -/
meta def isTextStop (c : Char) : Bool := c == '{' || c == '<' || c == '>' || c == '}'

meta def jsxNameKind : SyntaxNodeKind := `LeanUI.Syntax.jsxName
meta def jsxTextKind : SyntaxNodeKind := `LeanUI.Syntax.jsxText

meta def jsxNameFn : ParserFn := fun c s =>
  let startPos := s.pos
  if h : c.atEnd startPos then s.mkEOIError ["name"]
  else if isNameStart (c.get' startPos h) then
    let s := takeWhileFn isNameChar c (s.next' c startPos h)
    mkNodeToken jsxNameKind startPos true c s
  else s.mkErrorsAt ["name"] startPos

/-- A tag or attribute name. -/
meta def jsxName : Parser :=
  withAntiquot (mkAntiquot "jsxName" jsxNameKind) { fn := jsxNameFn }

/-- The name in a closing tag. It must repeat the opening tag's name; the check happens here,
in the parser, so that `<ul><li>a</div></ul>` fails at `</div>` with
`expected </li>, found </div>`. The opening name sits at a fixed depth of the syntax stack
(`"<" name attrs ">" children "</"` are below it). -/
meta def jsxCloseNameFn : ParserFn := fun c s =>
  let startPos := s.pos
  -- the opening name, below `"<" name attrs ">" children "</"`
  let sz := s.stackSize
  let opened := if sz < 6 then Syntax.missing else s.stxStack.get! (sz - 5)
  let o? := if opened.isOfKind jsxNameKind then some (opened.getArg 0).getAtomVal else none
  let voidHint (o : String) := if voidTags.contains o.toLower then s!"; <{o}> is a void element: write <{o} … />" else ""
  if !c.atEnd startPos && c.get startPos == '>' && o?.isSome then
    s.mkUnexpectedErrorAt s!"expected </{o?.get!}>, found </>" startPos
  else
    let s := jsxNameFn c s
    if s.hasError then s
    else match o? with
      | some o =>
        let k := (s.stxStack.back.getArg 0).getAtomVal
        if o == k then s else s.mkUnexpectedErrorAt s!"expected </{o}>, found </{k}>{voidHint o}" startPos
      | none => s

meta def jsxCloseName : Parser :=
  withAntiquot (mkAntiquot "jsxCloseName" jsxNameKind) { fn := jsxCloseNameFn }

/-- Where the whitespace in front of `p` starts. The previous token (`>`, `}` or `/>`) consumed it
as trailing whitespace, but in a text run it is content. -/
meta partial def wsStart (c : ParserContext) (p : String.Pos.Raw) : String.Pos.Raw :=
  if p.byteIdx == 0 then p
  else
    let q := c.prev p
    let ch := c.get q
    if ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' then wsStart c q else p

/-- The first character of a text line that starts in column 0, if any. Lean commands start in
column 0, so such a line is nearly always code swallowed by an element that was never closed;
reporting it here beats an "unexpected end of input" at the end of the file. -/
meta partial def findCol0 (c : ParserContext) (i stop : String.Pos.Raw) : Option String.Pos.Raw :=
  if i >= stop then none
  else
    let ch := c.get i
    let j := c.next i
    if ch == '\n' && j < stop then
      let d := c.get j
      if d != ' ' && d != '\n' && d != '\r' && d != '\t' then some j else findCol0 c j stop
    else findCol0 c j stop

meta def badTextChar (ch : Char) (s : ParserState) : ParserState :=
  let ent := if ch == '>' then "&gt;" else "&rbrace;"
  s.mkUnexpectedError s!"'{ch}' cannot appear in JSX text; write {ent} or \{\"{ch}\"}"

/-- A run of text between tags: everything up to the next `{` or `<`. A stray `>` or `}` is an
error (reported just after it, so the enclosing loop does not mistake it for the end of the
children). The atom's value includes the whitespace before the run. -/
meta def jsxTextFn : ParserFn := fun c s =>
  let startPos := s.pos
  if h : c.atEnd startPos then s.mkEOIError
  else
    let ch := c.get' startPos h
    if ch == '>' || ch == '}' then badTextChar ch (s.next' c startPos h)
    else if isTextStop ch then s.mkErrorsAt ["text"] startPos
    else
      let s := takeUntilFn isTextStop c (s.next' c startPos h)
      let stop := s.pos
      if let some p := findCol0 c (wsStart c startPos) stop then
        -- report past the run's start, so the children loop does not take it for their end
        let p := if p == startPos then c.next startPos else p
        s.mkUnexpectedErrorAt "template text starts in column 0 here; indent it (or, if this is Lean code, an element above is missing its closing tag)" p
      else
      if h : c.atEnd stop then s
      else
        let ch := c.get' stop h
        if ch == '>' || ch == '}' then badTextChar ch (s.next' c stop h)
        else
          let val := c.extract (wsStart c startPos) stop
          let info := SourceInfo.original (c.mkEmptySubstringAt startPos) startPos (c.mkEmptySubstringAt stop) stop
          s.pushSyntax (Syntax.mkLit jsxTextKind val info)

/-- Text between tags. -/
meta def jsxText : Parser :=
  withAntiquot (mkAntiquot "jsxText" jsxTextKind) { fn := jsxTextFn }

@[combinator_formatter jsxName] meta def jsxName.formatter : PrettyPrinter.Formatter :=
  PrettyPrinter.Formatter.visitAtom jsxNameKind
@[combinator_parenthesizer jsxName] meta def jsxName.parenthesizer : PrettyPrinter.Parenthesizer :=
  PrettyPrinter.Parenthesizer.visitToken
@[combinator_formatter jsxCloseName] meta def jsxCloseName.formatter : PrettyPrinter.Formatter :=
  PrettyPrinter.Formatter.visitAtom jsxNameKind
@[combinator_parenthesizer jsxCloseName] meta def jsxCloseName.parenthesizer : PrettyPrinter.Parenthesizer :=
  PrettyPrinter.Parenthesizer.visitToken
@[combinator_formatter jsxText] meta def jsxText.formatter : PrettyPrinter.Formatter :=
  PrettyPrinter.Formatter.visitAtom jsxTextKind
@[combinator_parenthesizer jsxText] meta def jsxText.parenthesizer : PrettyPrinter.Parenthesizer :=
  PrettyPrinter.Parenthesizer.visitToken

/-! ## Grammar -/

/-- An attribute of a JSX element. -/
declare_syntax_cat leanuiAttr
/-- A child of a JSX element: an element, text, `{term}` or `{...term}`. -/
declare_syntax_cat leanuiChild
/-- A JSX element or fragment. -/
declare_syntax_cat leanuiElement

/-- `name="string"` -/
syntax (name := attrStr) jsxName "=" str : leanuiAttr
/-- `name={term}` -/
syntax (name := attrTerm) jsxName "=" "{" term "}" : leanuiAttr
/-- A boolean attribute without a value: `disabled`. -/
syntax (name := attrBare) jsxName : leanuiAttr
/-- `{...attrs}` splices an `Array (Attr Msg)` (or a `List` or `Option`). -/
syntax (name := attrSpread) "{..." term "}" : leanuiAttr

/-- `{...term}` splices an `Array (Html Msg)` (or a `List`, an `Option`, or an `Array String`). -/
syntax (name := childSpread) "{..." term "}" : leanuiChild
/-- `{term}`: one child, an `Html Msg`, a `String`, or anything with `ToString`. -/
syntax (name := childTerm) "{" term "}" : leanuiChild
/-- `{}` (or `{/- a comment -/}`) adds nothing. -/
syntax (name := childEmpty) "{" "}" : leanuiChild
syntax (name := childElem) leanuiElement : leanuiChild
syntax (name := childText) jsxText : leanuiChild

/-- One child. Dispatches on the next character instead of the next token: a text run is not
Lean, and tokenizing it can fail (`'tis` is a broken character literal), so text never goes through
the category parser. -/
meta def jsxChildFn : ParserFn := fun c s =>
  if h : c.atEnd s.pos then s.mkEOIError ["</"]
  else
    let ch := c.get' s.pos h
    if ch == '<' || ch == '{' then (categoryParser `leanuiChild 0).fn c s
    else (node ``childText jsxText).fn c s

/-- A child of an element. -/
meta def jsxChild : Parser := { fn := jsxChildFn }

@[combinator_formatter jsxChild] meta def jsxChild.formatter : PrettyPrinter.Formatter :=
  PrettyPrinter.Formatter.categoryParser.formatter `leanuiChild
@[combinator_parenthesizer jsxChild] meta def jsxChild.parenthesizer : PrettyPrinter.Parenthesizer :=
  PrettyPrinter.Parenthesizer.categoryParser.parenthesizer `leanuiChild 0

/-- The `>` that ends a tag, read as a single character: the tokenizer would read `<mo>=</mo>` as
`<mo` `>=` … and `<b>>></b>` as `>>`. -/
meta def jsxGt : Parser := rawCh '>' (trailingWs := true)

@[combinator_formatter jsxGt] meta def jsxGt.formatter : PrettyPrinter.Formatter :=
  PrettyPrinter.Formatter.rawCh.formatter '>' true
@[combinator_parenthesizer jsxGt] meta def jsxGt.parenthesizer : PrettyPrinter.Parenthesizer :=
  PrettyPrinter.Parenthesizer.rawCh.parenthesizer '>'

/-- `<tag attrs />` -/
syntax (name := elemSelf) "<" noWs jsxName leanuiAttr* "/>" : leanuiElement
/-- `<tag attrs>children</tag>` -/
syntax (name := elemOpen) "<" noWs jsxName leanuiAttr* jsxGt jsxChild* "</" jsxCloseName jsxGt : leanuiElement
/-- `<>children</>`: an `Array (Html Msg)`; spliced when it is a child. -/
syntax (name := elemFrag) "<" noWs jsxGt jsxChild* "</" jsxGt : leanuiElement

/-- A JSX element as a term of type `Html Msg` (a fragment has type `Array (Html Msg)`). The `<`
must touch the tag name (`<div`, never `< div`), which keeps `a < b` an ordinary comparison. -/
syntax:lead (name := jsxTerm) leanuiElement : term

/-- A JSX element as a function argument (`pure <div/>`, `Html.map f <Child/>`). After an
argument-taking term, `<` is also the less-than operator, so this form only applies when a complete
opening tag follows (`<name attrs…>` or `<name attrs…/>`); otherwise `a <b then c` stays a
comparison. In every other position `jsxTerm` takes precedence, with its precise errors. -/
syntax:max (name := jsxArg) (priority := low)
  atomic(lookahead("<" noWs (jsxGt <|> (jsxName leanuiAttr* ("/>" <|> jsxGt))))) leanuiElement : term

/-- The opening tag of a template, for lookahead. -/
meta def jsxOpenTag : Parser := "<" >> checkNoWsBefore >> (jsxGt <|> (jsxName >> many (categoryParser `leanuiAttr 0) >> ("/>" <|> jsxGt)))

/-- `let n := count m` followed by a template on the next line reads as `count m < …`: `<` is also
less-than, and Lean continues an expression across lines through a binary operator. A template that
starts a line at or left of the enclosing `let`/`do` column cannot be a continuation, so report that
case with the fix instead of a puzzling error inside the tag. (Never succeeds; when it does not
apply it fails without consuming input, which the trailing-parser loop ignores.) -/
meta def jsxContinuationFn : ParserFn := fun c s =>
  let iniPos := s.pos
  let iniSz := s.stackSize
  let nope := s.mkErrorAt "" iniPos
  if !checkTailLinebreak s.stxStack.back then nope
  else match c.savedPos? with
    | none => nope
    | some sp =>
      if (c.fileMap.toPosition iniPos).column > (c.fileMap.toPosition sp).column then nope
      else
        let s' := jsxOpenTag.fn c s
        if s'.hasError then nope
        else
          let endPos := s'.pos
          (s'.restore iniSz iniPos).mkUnexpectedErrorAt
            ("this template starts a line, but `<` is also less-than, so Lean reads it as continuing the " ++
             "expression on the line above; end that line with `;` or put the template in parentheses") endPos

meta def jsxContinuation : Parser := { fn := jsxContinuationFn }

@[combinator_formatter jsxContinuation] meta def jsxContinuation.formatter : PrettyPrinter.Formatter := pure ()
@[combinator_parenthesizer jsxContinuation] meta def jsxContinuation.parenthesizer : PrettyPrinter.Parenthesizer := pure ()

/-- See `jsxContinuationFn`. -/
syntax:50 (name := jsxCont) (priority := high) term:51 jsxContinuation : term

/-! Type-directed conversions, filled in while the template is elaborated. -/

/-- A child `{e}`: `Html Msg`, or a `String` (or anything with `ToString`) as a text node. -/
syntax (name := childConv) "leanui_jsx_child% " term:max : term
/-- A spliced child list `{...e}` as an `Array (Html Msg)`: from an `Array`, a `List`, an `Option`,
an `Array String`, or an array of fragments. -/
syntax (name := kidsConv) "leanui_jsx_kids% " term:max : term
/-- An attribute value as a `String`; the string literal names the attribute (for errors). -/
syntax (name := strConv) "leanui_jsx_str% " str term:max : term
/-- A property value as a `PropValue`. -/
syntax (name := propConv) "leanui_jsx_prop% " str term:max : term
/-- A spliced attribute list `{...e}` as an `Array (Attr Msg)`. -/
syntax (name := attrsConv) "leanui_jsx_attrs% " term:max : term

/-! ## Text: JSX whitespace rules and character references -/

meta def dropStr (s : String) (n : Nat) : String := String.ofList (s.toList.drop n)

meta def isBlank (s : String) : Bool := s.all fun c => c == ' ' || c == '\t' || c == '\n' || c == '\r'

/-- JSX's whitespace rule: lines are trimmed where they touch a line break, blank lines vanish,
and the remaining lines are joined by single spaces. Whitespace within a line is kept. -/
meta def cleanText (raw : String) : String := Id.run do
  let raw := raw.replace "\r\n" "\n" |>.replace "\r" "\n" |>.replace "\t" " "
  let lines := (raw.splitOn "\n").toArray
  let mut lastNonEmpty := 0
  for i in [0:lines.size] do
    if lines[i]!.any (· != ' ') then lastNonEmpty := i
  let mut out := ""
  for i in [0:lines.size] do
    let mut l := lines[i]!.toList
    if i != 0 then l := l.dropWhile (· == ' ')
    if i + 1 != lines.size then l := (l.reverse.dropWhile (· == ' ')).reverse
    if !l.isEmpty then
      out := out ++ String.ofList l
      if i != lastNonEmpty then out := out ++ " "
  return out

/-- Decode character references. Returns the text and the unknown names (left as written). -/
meta def decodeEntities (s : String) : Except String (String × Array String) := do
  let cs := s.toList.toArray
  let mut out := ""
  let mut unknown := #[]
  let mut i := 0
  while i < cs.size do
    let c := cs[i]!
    if c != '&' then
      out := out.push c; i := i + 1
    else
      -- find the `;` within a short window
      let mut j := i + 1
      while j < cs.size && j < i + 40 && cs[j]! != ';' && cs[j]! != '&' && cs[j]! != ' ' do j := j + 1
      if j < cs.size && cs[j]! == ';' && j > i + 1 then
        let body := String.ofList (cs.extract (i + 1) j).toList
        if body.startsWith "#" then
          let digits := dropStr body 1
          let hex := digits.startsWith "x" || digits.startsWith "X"
          let num := if hex then
              (dropStr digits 1).toList.foldl (init := some 0) fun acc d =>
                acc.bind fun n =>
                  if d.isDigit then some (n * 16 + (d.toNat - '0'.toNat))
                  else if 'a' ≤ d && d ≤ 'f' then some (n * 16 + (d.toNat - 'a'.toNat + 10))
                  else if 'A' ≤ d && d ≤ 'F' then some (n * 16 + (d.toNat - 'A'.toNat + 10))
                  else none
            else digits.toNat?
          match num with
          | some n =>
            if n == 0 || n > 0x10FFFF || (0xD800 ≤ n && n ≤ 0xDFFF) || (hex && digits.length ≤ 1) then
              throw s!"invalid character reference &{body};"
            out := out.push (Char.ofNat n)
          | none => throw s!"invalid character reference &{body};"
          i := j + 1
        else
          match entities.lookup body with
          | some n => out := out.push (Char.ofNat n); i := j + 1
          | none =>
            if body.all Char.isAlphanum then unknown := unknown.push body
            out := out.push c; i := i + 1
      else
        out := out.push c; i := i + 1
  return (out, unknown)

/-! ## Elaboration of templates -/

/-- Element namespace, as the template sees it. -/
meta inductive NsK where
  | html | svg | mathml
  deriving BEq, Inhabited

meta def NsK.term : NsK → TermElabM Term
  | .html => `(LeanUI.Ns.html)
  | .svg => `(LeanUI.Ns.svg)
  | .mathml => `(LeanUI.Ns.mathml)

/-- One part of an array literal being assembled. -/
meta inductive Seg where
  /-- one element -/
  | one (t : Term)
  /-- an array spliced in -/
  | many (t : Term)
  /-- one element, present only when the `Bool` holds -/
  | cond (c : Term) (t : Term)
  /-- one element built from the payload of an `Option`, present only for `some` -/
  | opt (o : Term) (mk : Term → TermElabM Term)

/-- Assemble segments into an array term: runs of `one` become array literals, the rest push or
append onto the array built so far (which is unique there, so pushing is in place). -/
meta def buildArray (segs : Array Seg) : TermElabM Term := do
  let mut acc : Option Term := none
  let mut grp : Array Term := #[]
  for seg in segs do
    match seg with
    | .one t => grp := grp.push t
    | .many t =>
      if acc.isNone && grp.isEmpty then acc := some t
      else acc := some (← `($(← flush acc grp) ++ $t))
      grp := #[]
    | .cond c t =>
      let a ← flush acc grp
      grp := #[]
      acc := some (← withFreshMacroScope `(let xs := $a; if ($c : Bool) then xs.push $t else xs))
    | .opt o mk =>
      let a ← flush acc grp
      grp := #[]
      acc := some (← withFreshMacroScope do
        let v ← `(v)
        let t ← mk v
        `(let xs := $a; match $o:term with | some $v => xs.push $t | none => xs))
  flush acc grp
where
  flush (acc : Option Term) (grp : Array Term) : TermElabM Term :=
    match acc with
    | none => `(#[$grp,*])
    | some a => grp.foldlM (fun a t => `(Array.push $a $t)) a

meta def nameOf (stx : Syntax) : String := (stx.getArg 0).getAtomVal

/-- Where a tag lives and which namespace its children default to. A tag may force its namespace
with a prefix (`svg:a`, `math:mi`, `html:a`); `svg` and `math` switch it; SVG-only and
MathML-only tags switch it even outside `<svg>`/`<math>`, so a `{...}` inside an `<svg>` can still
produce `<circle>`s; `foreignObject` switches its children back to HTML. -/
meta def resolveTag (ctx : NsK) (raw : String) : NsK × String × NsK :=
  let (forced, tag) :=
    if raw.startsWith "svg:" then (some NsK.svg, dropStr raw 4)
    else if raw.startsWith "math:" then (some NsK.mathml, dropStr raw 5)
    else if raw.startsWith "html:" then (some NsK.html, dropStr raw 5)
    else (none, raw)
  let ns := match forced with
    | some n => n
    | none =>
      if tag == "svg" then .svg
      else if tag == "math" then .mathml
      else if ctx == .html && svgTags.contains tag && !htmlTags.contains tag then .svg
      else if ctx == .html && mathmlTags.contains tag then .mathml
      else ctx
  let kids := if ns == .svg && tag == "foreignObject" then .html else ns
  (ns, tag, kids)

/-- What a template node elaborates to. -/
meta inductive Out where
  /-- one node; `cond` is the `if={c}` condition, if any -/
  | node (t : Term) (cond : Option (Syntax × Term))
  /-- a fragment: an array of nodes -/
  | frag (t : Term)

/-- A parsed attribute value. -/
meta inductive AVal where
  | none
  | str (s : TSyntax `str)
  | term (t : Term)

meta structure RawAttr where
  ref : Syntax
  nameStx : Syntax
  name : String
  val : AVal

meta def parseAttr (stx : Syntax) : Option RawAttr :=
  let k := stx.getKind
  if k == ``attrStr then some ⟨stx, stx[0], nameOf stx[0], .str ⟨stx[2]⟩⟩
  else if k == ``attrTerm then some ⟨stx, stx[0], nameOf stx[0], .term ⟨stx[3]⟩⟩
  else if k == ``attrBare then some ⟨stx, stx[0], nameOf stx[0], .none⟩
  else none

meta def isIdentLike (s : String) : Bool :=
  match s.toList with
  | c :: cs => (c.isAlpha || c == '_') && cs.all fun c => c.isAlphanum || c == '_' || c == '\''
  | [] => false

meta def lowerFirst (s : String) : String :=
  match s.toList with
  | c :: cs => String.ofList (c.toLower :: cs)
  | [] => s

/-- The value of an attribute as a `String` term. -/
meta def strValue (a : RawAttr) (what : String) : TermElabM Term := do
  match a.val with
  | .str s => pure s
  | .term t => `(leanui_jsx_str% $(quote a.name) $t)
  | .none => throwErrorAt a.ref m!"`{a.name}` needs a value: {what}"

/-- Apply event modifiers (`|prevent`, `|stop`) to an `Attr` term that is an event listener. -/
meta def withModifiers (ref : Syntax) (attr : Term) (mods : List String) : TermElabM Term := do
  if mods.isEmpty then return attr
  let mut prevent := false
  let mut stop := false
  for m in mods do
    if m == "prevent" || m == "preventDefault" then prevent := true
    else if m == "stop" || m == "stopPropagation" then stop := true
    else throwErrorAt ref m!"unknown event modifier `|{m}`; the modifiers are `|prevent` (preventDefault) and `|stop` (stopPropagation)"
  let p := quote prevent
  let s := quote stop
  `(match ($attr : LeanUI.Attr _) with
    | LeanUI.Attr.on ev h => LeanUI.Attr.on ev { h with preventDefault := h.preventDefault || $p, stopPropagation := h.stopPropagation || $s }
    | a => a)

/-- Turn the attributes of an HTML/SVG/MathML element into array segments. `class`/`class:x` and
`style`/`style:p` are merged into one attribute each, placed where the first of them appears. -/
meta def elemAttrs (ns : NsK) (tag : String) (attrs : Array Syntax) : TermElabM (Array Seg) := do
  let mut segs : Array Seg := #[]
  -- class: base value, toggles
  let mut classBase : Option (Syntax × Term) := none
  let mut classToggles : Array (String × Term) := #[]
  let mut classAt : Option Nat := none
  -- style: base value, properties
  let mut styleBase : Option (Syntax × Term) := none
  let mut styleProps : Array (String × Term) := #[]
  let mut styleAt : Option Nat := none
  -- duplicate detection: identity → first occurrence
  let mut seen : Array (String × Syntax) := #[]
  let html := ns == .html
  let dup (seen : Array (String × Syntax)) (ident : String) (ref : Syntax) (what : MessageData) : TermElabM (Array (String × Syntax)) := do
    if seen.any (·.1 == ident) then throwErrorAt ref m!"duplicate {what} on <{tag}>"
    return seen.push (ident, ref)
  for stx in attrs do
    if stx.getKind == ``attrSpread then
      segs := segs.push (.many (← `(leanui_jsx_attrs% $(⟨stx[1]⟩))))
      continue
    let some a := parseAttr stx | throwErrorAt stx "unsupported attribute syntax"
    let n := a.name
    -- DOM properties: `.value={e}`
    if n.startsWith "." then
      let p := dropStr n 1
      unless isIdentLike p do throwErrorAt a.nameStx m!"invalid property name `{n}`: write `.name=\{value}` with a DOM property name such as `.value`"
      seen ← dup seen ("." ++ p) a.ref m!"property `{n}`"
      let v ← match a.val with
        | .str s => `(LeanUI.PropValue.str $s)
        | .term t => `(leanui_jsx_prop% $(quote p) $t)
        | .none => `(LeanUI.PropValue.bool true)
      segs := segs.push (.one (← `(LeanUI.Attr.prop $(quote p) $v)))
      continue
    -- events
    let parts := n.splitOn "|"
    let base := parts.head!
    let mods := parts.tail
    let rest := dropStr base 2
    let shorthandLike := base.startsWith "on" && rest.length > 0 && rest.front.isUpper
    let inlineJs := base.startsWith "on" && domEvents.contains rest
    if inlineJs then
      throwErrorAt a.nameStx m!"`{base}` looks like an inline JavaScript handler, which LeanUI does not run; use `on{rest.capitalize}=\{msg}` or `on:{rest}=\{handler}`"
    if base.startsWith "on:" || shorthandLike then
      let (ev, attrTerm) ← do
        if base.startsWith "on:" then
          let ev := dropStr base 3
          if ev.isEmpty then throwErrorAt a.nameStx "`on:` needs an event name, as in `on:mouseenter=\{handler}`"
          let .term h := a.val
            | throwErrorAt a.ref m!"`{base}` takes a handler: `{base}=\{h}` with `h : LeanUI.Handler Msg`"
          pure (ev, ← `(LeanUI.Attr.on $(quote ev) $h))
        else
          match shorthands.find? (·.1 == base) with
          | some (_, fn, ev, takes) =>
            let .term h := a.val
              | throwErrorAt a.ref m!"`{base}` takes {takes}: write `{base}=\{…}`"
            pure (ev, ← `($(mkIdent fn) $h))
          | none =>
            let lower := base.toLower
            let hint := match shorthands.find? (·.1.toLower == lower) with
              | some (k, _, _, _) => m!"Did you mean `{k}`? "
              | none => m!""
            let names := ", ".intercalate (shorthands.map (·.1))
            throwErrorAt a.nameStx m!"unknown event shorthand `{base}`. {hint}The shorthands are {names}; for any other DOM event write `on:{rest.toLower}=\{handler}` with `handler : LeanUI.Handler Msg`"
      seen ← dup seen ("on:" ++ ev) a.ref m!"listener for `{ev}` (`{base}`)"
      segs := segs.push (.one (← withModifiers a.nameStx attrTerm mods))
      continue
    unless mods.isEmpty do throwErrorAt a.nameStx m!"`|` modifiers apply to event listeners only (`onClick|prevent=\{msg}`), not to `{base}`"
    -- `name?={opt}`: present only for `some`
    let optional := n.endsWith "?"
    let n := if optional then String.ofList (n.toList.dropLast) else n
    if n.any (· == '?') then throwErrorAt a.nameStx m!"invalid attribute name `{a.name}`"
    if n == "className" then throwErrorAt a.nameStx "LeanUI uses HTML attribute names: write `class`, not `className`"
    if n == "htmlFor" then throwErrorAt a.nameStx "LeanUI uses HTML attribute names: write `for`, not `htmlFor`"
    if n == "key" then
      if optional then throwErrorAt a.nameStx "`key` cannot be optional"
      seen ← dup seen "key" a.ref "`key`"
      let k ← strValue a "`key=\"…\"` or `key={k}`"
      segs := segs.push (.one (← `(LeanUI.Attr.key $k)))
      continue
    if n == "class" || n.startsWith "class:" then
      if optional then throwErrorAt a.nameStx "a class cannot be optional; toggle it with `class:name=\{cond}`"
      if classAt.isNone then
        classAt := some segs.size
        segs := segs.push (.one (← `(#[])))  -- placeholder, replaced below
      if n == "class" then
        if classBase.isSome then throwErrorAt a.ref m!"duplicate `class` on <{tag}>; add classes with `class:name=\{cond}`"
        classBase := some (a.ref, ← strValue a "`class=\"a b\"` or `class={expr}`")
      else
        let c := dropStr n 6
        if c.isEmpty then throwErrorAt a.nameStx "`class:` needs a class name, as in `class:done=\{cond}`"
        if classToggles.any (·.1 == c) then throwErrorAt a.ref m!"duplicate `class:{c}` on <{tag}>"
        let cond ← match a.val with
          | .term t => pure t
          | .none => `(true)
          | .str _ => throwErrorAt a.ref m!"`class:{c}` takes a condition: `class:{c}=\{cond}` with `cond : Bool`"
        classToggles := classToggles.push (c, cond)
      continue
    if n == "style" || n.startsWith "style:" then
      if optional then throwErrorAt a.nameStx "a style cannot be optional"
      if styleAt.isNone then
        styleAt := some segs.size
        segs := segs.push (.one (← `(#[])))
      if n == "style" then
        if styleBase.isSome then throwErrorAt a.ref m!"duplicate `style` on <{tag}>; set properties with `style:name=\{value}`"
        styleBase := some (a.ref, ← strValue a "`style=\"color: red\"` or `style={expr}`")
      else
        let p := dropStr n 6
        if p.isEmpty then throwErrorAt a.nameStx "`style:` needs a CSS property, as in `style:color=\{c}`"
        if styleProps.any (·.1 == p) then throwErrorAt a.ref m!"duplicate `style:{p}` on <{tag}>"
        styleProps := styleProps.push (p, ← strValue a s!"`style:{p}=\"…\"` or `style:{p}=\{value}`")
      continue
    -- an ordinary attribute
    if n.any (· == '.') || n.startsWith ":" || n.endsWith ":" || n.endsWith "-" then
      throwErrorAt a.nameStx m!"invalid attribute name `{a.name}`"
    let lname := if html then n.toLower else n
    seen ← dup seen lname a.ref m!"attribute `{n}`"
    if optional then
      let .term o := a.val | throwErrorAt a.ref m!"`{n}?` takes an `Option`: `{n}?=\{opt}`"
      let nq : TSyntax `str := quote n
      segs := segs.push (.opt o fun v => `(LeanUI.Attr.attr $nq (leanui_jsx_str% $nq $v)))
      continue
    match a.val with
    | .str s => segs := segs.push (.one (← `(LeanUI.Attr.attr $(quote n) $s)))
    | .none => segs := segs.push (.one (← `(LeanUI.Attr.attr $(quote n) "")))
    | .term t =>
      if html && liveProps.contains lname then
        segs := segs.push (.one (← `(LeanUI.Attr.prop $(quote n) (leanui_jsx_prop% $(quote n) $t))))
      else if html && booleanAttrs.contains lname then
        segs := segs.push (.cond t (← `(LeanUI.Attr.attr $(quote n) "")))
      else
        segs := segs.push (.one (← `(LeanUI.Attr.attr $(quote n) (leanui_jsx_str% $(quote n) $t))))
  -- merged class
  if let some i := classAt then
    let staticBase := classBase.bind fun (_, b) => b.raw.isStrLit?.filter (!·.isEmpty)
    let t ← if classToggles.isEmpty then
        `(LeanUI.Attr.attr "class" $(classBase.get!.2))
      else if let some base := staticBase then
        -- a fixed first class: append the toggled ones directly, the same string `Attr.classes`
        -- builds, without the intermediate list
        let mut acc : Term ← `($(quote base))
        for (c, cond) in classToggles do
          acc ← `($acc ++ (if ($cond : Bool) then $(quote (" " ++ c)) else ""))
        `(LeanUI.Attr.attr "class" $acc)
      else
        let mut items : Array Term := #[]
        if let some (_, b) := classBase then items := items.push (← `(($b, true)))
        for (c, cond) in classToggles do items := items.push (← `(($(quote c), ($cond : Bool))))
        `(LeanUI.Attr.classes [$items,*])
    segs := segs.set! i (.one t)
  -- merged style
  if let some i := styleAt then
    let mut parts : Array Term := #[]
    if let some (_, b) := styleBase then parts := parts.push b
    for (p, v) in styleProps do parts := parts.push (← `($(quote (p ++ ": ")) ++ $v))
    let joined ← match parts.toList with
      | [] => `("")
      | p :: ps => ps.foldlM (fun acc x => `($acc ++ "; " ++ $x)) p
    segs := segs.set! i (.one (← `(LeanUI.Attr.attr "style" $joined)))
  return segs

/-- Arguments for a component call `<Card title="x" featured>…</Card>`: named arguments, with
`true` for a bare name. `key` is applied to the element the component returns. -/
meta def componentArgs (tag : String) (attrs : Array Syntax) : TermElabM (Array Syntax × Option Term) := do
  let mut args : Array Syntax := #[]
  let mut key : Option Term := none
  let mut seen : Array String := #[]
  for stx in attrs do
    if stx.getKind == ``attrSpread then
      throwErrorAt stx m!"attribute spreads are not supported on components; pass the value as a named argument of `{tag}`"
    let some a := parseAttr stx | throwErrorAt stx "unsupported attribute syntax"
    if seen.contains a.name then throwErrorAt a.nameStx m!"duplicate argument `{a.name}` for <{tag}>"
    seen := seen.push a.name
    if a.name == "key" then
      key := some (← withRef a.nameStx (strValue a "`key={k}`"))
      continue
    unless isIdentLike a.name do
      throwErrorAt a.nameStx m!"`{a.name}` is not a valid argument name: a component's attributes are the named arguments of the function `{tag}`"
    if a.name == "children" then
      throwErrorAt a.nameStx m!"pass children between <{tag}> and </{tag}>, not as an attribute"
    let v : Term ← match a.val with
      | .str s => pure s
      | .term t => pure t
      | .none => `(true)
    let n := mkIdentFrom a.nameStx (Name.mkSimple a.name)
    args := args.push (← `(Lean.Parser.Term.namedArgument| ($n := $v)))
  return (args, key)

/-- Add a reconciliation key to the element a component returned. -/
meta def keyed (h : Term) (k : Term) : TermElabM Term :=
  `(match ($h : LeanUI.Html _) with
    | LeanUI.Html.elem ns tag as kids => LeanUI.Html.elem ns tag (as.push (LeanUI.Attr.key $k)) kids
    | other => other)

/-- Does something of this type produce a view (`Html _`, or an `Array` for a fragment) once
applied to its arguments? -/
meta def returnsView (ty : Expr) : MetaM Bool :=
  forallTelescopeReducing ty fun _ body => do
    let body ← whnfR body
    return body.isAppOf ``LeanUI.Html || body.isAppOf ``Array

/-- `<Card …>` calls the function `Card`. Catch the common mistakes early: an HTML element written
with a capital letter (`<Div>`, which would otherwise resolve to the `Div` class), or a name that
is not a function returning `Html`. -/
meta def checkComponent (nameStx : Syntax) (raw : String) : TermElabM Bool := do
  let n := raw.toName
  let lower := raw.toLower
  let isTag := htmlTags.contains lower || svgTags.contains lower
  let hint := if isTag then
      m!"; HTML and SVG element names are written in lowercase: <{lowerFirst raw}>" else m!""
  let types : List Expr ← match (← getLCtx).findFromUserName? n with
    | some d => pure [d.type]
    | none => do
      let cs := (← resolveGlobalName n).filter (·.2.isEmpty)
      cs.mapM fun (c, _) => do pure (← getConstInfo c).type
  if types.isEmpty then
    if isTag then throwErrorAt nameStx m!"unknown component `{raw}`{hint}"
    return false
  unless ← types.anyM fun t => returnsView t do
    throwErrorAt nameStx m!"`{raw}` is not a component (a function whose result is `Html Msg`){hint}"
  -- a component whose result is an array of nodes (a fragment) is spliced where it is used
  types.allM fun t => forallTelescopeReducing t fun _ body => do return (← whnfR body).isAppOf ``Array

mutual

/-- Elaborate the children of an element (or fragment) in namespace `ctx`. -/
meta partial def childSegs (ctx : NsK) (kids : Array Syntax) : TermElabM (Array Seg) := do
  let mut segs := #[]
  for k in kids do
    let kind := k.getKind
    if kind == ``childText then
      let raw := (k[0].getArg 0).getAtomVal
      if isBlank raw then continue
      let cleaned := cleanText raw
      if cleaned.isEmpty then continue
      match decodeEntities cleaned with
      | .error e => throwErrorAt k[0] e
      | .ok (txt, unknown) =>
        for u in unknown do
          logWarningAt k[0] m!"unknown character reference `&{u};` (kept as written); escape `&` as `&amp;`"
        segs := segs.push (.one (← withRef k[0] `(LeanUI.Html.text $(quote txt))))
    else if kind == ``childElem then
      match ← transform ctx k[0] with
      | .node t none => segs := segs.push (.one t)
      | .node t (some (_, c)) => segs := segs.push (.cond c t)
      | .frag t => segs := segs.push (.many t)
    else if kind == ``childTerm then
      let e : Term := ⟨k[1]⟩
      if let some s := e.raw.isStrLit? then
        segs := segs.push (.one (← withRef e `(LeanUI.Html.text $(quote s))))
      else if let some n := e.raw.isNatLit? then
        segs := segs.push (.one (← withRef e `(LeanUI.Html.text $(quote (toString n)))))
      else
        segs := segs.push (.one (← withRef e `(leanui_jsx_child% $e)))
    else if kind == ``childSpread then
      let e : Term := ⟨k[1]⟩
      segs := segs.push (.many (← withRef e `(leanui_jsx_kids% $e)))
    else if kind == ``childEmpty then
      continue
    else throwErrorAt k "unsupported JSX child"
  return segs

/-- Elaborate one element or fragment (as syntax), in namespace `ctx`. -/
meta partial def transform (ctx : NsK) (stx : Syntax) : TermElabM Out := withRef stx do
  let kind := stx.getKind
  if kind == ``elemFrag then
    return .frag (← buildArray (← childSegs ctx stx[2].getArgs))
  let selfClosing := kind == ``elemSelf
  unless selfClosing || kind == ``elemOpen do throwErrorAt stx "unsupported JSX element"
  let nameStx := stx[1]
  let raw := nameOf nameStx
  let kids := if selfClosing then #[] else stx[4].getArgs
  unless selfClosing do
    let close := nameOf stx[6]
    if close != raw then throwErrorAt stx[6] m!"expected </{raw}>, found </{close}>"
  -- `if={cond}`: the element is a child only when `cond` holds
  let mut cond : Option (Syntax × Term) := none
  let mut attrs := #[]
  for a in stx[2].getArgs do
    match parseAttr a with
    | some ra =>
      if ra.name == "if" then
        if cond.isSome then throwErrorAt ra.nameStx "duplicate `if`"
        let .term c := ra.val | throwErrorAt ra.ref "`if` takes a condition: `if=\{cond}` with `cond : Bool`"
        cond := some (ra.nameStx, c)
      else attrs := attrs.push a
    | none => attrs := attrs.push a
  -- components: an uppercase first letter
  if raw.front.isUpper then
    let fn := mkIdentFrom nameStx (raw.toName)
    let isFragment ← checkComponent nameStx raw
    let (args, key) ← componentArgs raw attrs
    let mut args := args
    let realKids := kids.filter fun k => !(k.getKind == ``childText && isBlank ((k[0].getArg 0).getAtomVal)) && k.getKind != ``childEmpty
    unless realKids.isEmpty do
      let kidsTerm ← buildArray (← childSegs ctx kids)
      args := args.push (← `(Lean.Parser.Term.namedArgument| (children := $kidsTerm)))
    let call : Term := if args.isEmpty then fn else ⟨mkNode ``Lean.Parser.Term.app #[fn, mkNullNode args]⟩
    if isFragment then
      if key.isSome then throwErrorAt nameStx m!"`key` needs one element, but `{raw}` returns several"
      if cond.isSome then
        return .frag (← `(if ($(cond.get!.2) : Bool) then $call else #[]))
      return .frag call
    return .node (← match key with | some k => keyed call k | none => pure call) cond
  -- elements
  let (ns, tag, kidCtx) := resolveTag ctx raw
  unless tag.length > 0 && tag.front.isAlpha && tag.all (fun c => c.isAlphanum || c == '-' || c == '_') do
    if tag.any (· == '.') then
      throwErrorAt nameStx m!"invalid element name <{raw}>; components (functions returning `Html`) start with an uppercase letter"
    throwErrorAt nameStx m!"invalid element name <{raw}>"
  let explicit := tag != raw  -- `html:x`, `svg:x`, `math:x` opt out of the unknown-element check
  if explicit then pure ()
  else if ns == .html && !tag.any (· == '-') && !htmlTags.contains tag.toLower then
    logWarningAt nameStx m!"unknown HTML element <{tag}>; custom elements need a dash in their name (<my-{tag}>), SVG and MathML elements belong inside <svg> or <math> (or use the `svg:`/`math:` prefix)"
  else if ns == .svg && !svgTags.contains tag then
    logWarningAt nameStx m!"unknown SVG element <{tag}> (SVG element names are case-sensitive)"
  else if ns == .mathml && !mathmlTags.contains tag then
    logWarningAt nameStx m!"unknown MathML element <{tag}>"
  let segs ← elemAttrs ns tag attrs
  let attrsTerm ← buildArray segs
  let kidSegs ← childSegs kidCtx kids
  if ns == .html && voidTags.contains tag.toLower && !kidSegs.isEmpty then
    throwErrorAt nameStx m!"<{tag}> is a void element and cannot have children; write <{tag} … />"
  let kidsTerm ← buildArray kidSegs
  return .node (← `(LeanUI.Html.elem $(← ns.term) $(quote tag) $attrsTerm $kidsTerm)) cond

end

@[term_elab jsxTerm, term_elab jsxArg] meta def elabJsx : TermElab := fun stx expectedType? => do
  let t ← match ← transform .html stx[0] with
    | .node t none => pure t
    | .node _ (some (ref, _)) =>
      throwErrorAt ref "`if=\{cond}` applies to a child element (it decides whether the child is there); for a whole template write `if cond then <…/> else <…/>`"
    | .frag t => pure t
  withMacroExpansion stx t <| elabTerm t expectedType?

/-! ## Type-directed conversions -/

/-- The type of an elaborated term, instantiated and with reducible definitions unfolded. -/
meta def typeOf (e : Expr) : TermElabM Expr := do whnfR (← instantiateMVars (← inferType e))

/-- The element type of an `Array`, `List` or `Option` type. -/
meta def elemOf (ty : Expr) : TermElabM (Option Expr) := do
  if ty.isAppOf ``Array || ty.isAppOf ``List || ty.isAppOf ``Option then
    match ty.getAppArgs.back? with
    | some a => return some (← whnfR (← instantiateMVars a))
    | none => return none
  else return none

/-- Is the type far enough known to decide a conversion? (Its head, and for a collection the head
of its elements: `xs.map fun (k, v) => <>…</>` is an `Array ?β` for a while.) -/
meta def settled (ty : Expr) : TermElabM Bool := do
  if ty.getAppFn.isMVar then return false
  match ← elemOf ty with
  | some a => return !a.getAppFn.isMVar
  | none => return true

/-- Elaborate the interpolated value `stx[i]` once, then `decide` how to convert it from its type.
When the type is not settled yet (numerals waiting for their default instance, a `match` still
postponed), only the decision waits: the conversion is dispatched again on the elaborated value,
put back into `stx` as a hole, and that is postponed until the type is known. The user's term is
never elaborated twice, and never outside its original context. On the final pass `decide` sees
whatever is known and applies its default. -/
meta def withValue (stx : Syntax) (i : Nat) (expectedType? : Option Expr)
    (elabIt : Syntax → TermElabM Expr) (decide : Expr → Expr → TermElabM Expr) : TermElabM Expr := do
  let e := stx[i]
  let r ← elabIt e
  unless ← settled (← typeOf r) do
    if e.isOfKind ``Lean.Parser.Term.syntheticHole then tryPostpone
    -- `mkSaveInfoAnnotation`: the result is a postponed hole, and without the annotation the info
    -- nodes of the value just elaborated would be dropped with it (they are what tells the
    -- unused-variables linter and the editor that `i` in `key={i}` is used)
    else return mkSaveInfoAnnotation (← elabTerm (stx.setArg i (← exprToSyntax r)) expectedType?)
  decide r (← typeOf r)

meta def hasToString (ty : Expr) : TermElabM Bool := do
  try
    let inst ← mkAppM ``ToString #[ty]
    return (← trySynthInstance inst) matches .some _
  catch _ => return false

meta def isCollection (ty : Expr) : Bool :=
  ty.isAppOf ``Array || ty.isAppOf ``List || ty.isAppOf ``Option

/-- `toString r`, for a value whose type is still unknown on the final pass: `ToString` decides once
the remaining default instances apply. -/
meta def lateToString (r : Expr) : TermElabM Expr := do
  elabTerm (← `(toString $(← exprToSyntax r))) (mkConst ``String)

@[term_elab childConv] meta def elabChildConv : TermElab := fun stx expectedType? =>
  -- The value is elaborated on its own (never against `Html Msg`: for `fun i => <li>{i}</li>` that
  -- would make `i` an `Html`). A view that needs its expected type (`{.text s}`, an `if` over dot
  -- notation) is postponed by its own elaborator; the decision below then waits too, and on the
  -- final pass it settles on `Html Msg`, which lets that view finish.
  withValue stx 1 expectedType? (elabTerm · none) fun r ty => do
    let e := stx[1]
    if ty.isAppOf ``LeanUI.Html || ty.getAppFn.isMVar then return ← ensureHasType expectedType? r
    if ty.isConstOf ``String then
      return ← ensureHasType expectedType? (mkApp2 (.const ``LeanUI.Html.text []) (← mkFreshTypeMVar) r)
    if isCollection ty then
      throwErrorAt e m!"this child has type{indentExpr ty}\nsplice a collection of children with `\{...e}` instead of `\{e}`"
    if ty.isConstOf ``Bool then
      throwErrorAt e m!"a `Bool` is not a child; for a conditional child write `\{...if c then #[…] else #[]}`, for the word write `\{toString b}`"
    if ← hasToString ty then
      return ← ensureHasType expectedType? (mkApp2 (.const ``LeanUI.Html.text []) (← mkFreshTypeMVar) (← mkAppM ``ToString.toString #[r]))
    throwErrorAt e m!"a child must be an `Html Msg`, a `String`, or a value with a `ToString` instance, but this has type{indentExpr ty}"

@[term_elab kidsConv] meta def elabKidsConv : TermElab := fun stx expectedType? =>
  withValue stx 1 expectedType? (elabTerm · none) fun r ty => do
    let e := stx[1]
    let rs ← exprToSyntax r
    let elemTy := (← elemOf ty).getD (mkConst ``Unit)
    if ty.isAppOf ``Array then
      if elemTy.isConstOf ``String then return ← elabTerm (← `(Array.map LeanUI.Html.text $rs)) expectedType?
      -- an array of fragments, as from `xs.map fun x => <>…</>`
      if elemTy.isAppOf ``Array then return ← elabTerm (← `(Array.flatten $rs)) expectedType?
      return ← ensureHasType expectedType? r
    if ty.isAppOf ``List then
      if elemTy.isConstOf ``String then return ← elabTerm (← `((List.map LeanUI.Html.text $rs).toArray)) expectedType?
      return ← elabTerm (← `(List.toArray $rs)) expectedType?
    if ty.isAppOf ``Option then
      return ← elabTerm (← `(match $rs:term with | some h => #[h] | none => #[])) expectedType?
    if ty.isAppOf ``LeanUI.Html then return ← elabTerm (← `(#[$rs])) expectedType?
    if ty.getAppFn.isMVar then return ← ensureHasType expectedType? r
    throwErrorAt e m!"`\{...e}` splices an `Array (Html Msg)` (or a `List`, an `Option`, an `Array String` or an array of fragments), but this has type{indentExpr ty}"

@[term_elab strConv] meta def elabStrConv : TermElab := fun stx expectedType? =>
  withValue stx 2 expectedType? (elabTerm · none) fun r ty => do
    let name := stx[1].isStrLit?.getD "?"
    let e := stx[2]
    if ty.isConstOf ``String then return r
    if ty.getAppFn.isMVar then return ← lateToString r
    if ty.isAppOf ``Option then
      if name == "class" || name == "style" || name == "key" then
        throwErrorAt e m!"`{name}` got an `Option`{indentExpr ty}\nsupply a default, as in `{name}=\{e.getD \"\"}`"
      throwErrorAt e m!"`{name}` got an `Option`{indentExpr ty}\nwrite `{name}?=\{…}` to set the attribute only when the value is `some`"
    if isCollection ty || ty.isAppOf ``LeanUI.Html then
      throwErrorAt e m!"`{name}` needs a string-like value, but this has type{indentExpr ty}"
    if ← hasToString ty then return ← mkAppM ``ToString.toString #[r]
    throwErrorAt e m!"`{name}` needs a `String` (or a value with a `ToString` instance), but this has type{indentExpr ty}"

@[term_elab propConv] meta def elabPropConv : TermElab := fun stx expectedType? =>
  withValue stx 2 expectedType? (elabTerm · none) fun r ty => do
    let name := stx[1].isStrLit?.getD "?"
    let e := stx[2]
    if ty.isConstOf ``LeanUI.PropValue then return r
    if ty.isConstOf ``String then return mkApp (mkConst ``LeanUI.PropValue.str) r
    if ty.isConstOf ``Bool then return mkApp (mkConst ``LeanUI.PropValue.bool) r
    if ty.isConstOf ``Float then return mkApp (mkConst ``LeanUI.PropValue.num) r
    if ty.getAppFn.isMVar then return mkApp (mkConst ``LeanUI.PropValue.str) (← lateToString r)
    if isCollection ty || ty.isAppOf ``LeanUI.Html then
      throwErrorAt e m!"property `{name}` needs a `String`, `Bool` or `Float`, but this has type{indentExpr ty}"
    if ← hasToString ty then return mkApp (mkConst ``LeanUI.PropValue.str) (← mkAppM ``ToString.toString #[r])
    throwErrorAt e m!"property `{name}` needs a `String`, `Bool`, `Float` or a value with a `ToString` instance, but this has type{indentExpr ty}"

@[term_elab attrsConv] meta def elabAttrsConv : TermElab := fun stx expectedType? =>
  withValue stx 1 expectedType? (elabTerm · none) fun r ty => do
    let e := stx[1]
    let rs ← exprToSyntax r
    if ty.isAppOf ``Array || ty.getAppFn.isMVar then return ← ensureHasType expectedType? r
    if ty.isAppOf ``List then return ← elabTerm (← `(List.toArray $rs)) expectedType?
    if ty.isAppOf ``Option then return ← elabTerm (← `(match $rs:term with | some a => #[a] | none => #[])) expectedType?
    if ty.isAppOf ``LeanUI.Attr then return ← elabTerm (← `(#[$rs])) expectedType?
    throwErrorAt e m!"`\{...e}` among attributes splices an `Array (Attr Msg)` (or a `List` or an `Option`), but this has type{indentExpr ty}"

end LeanUI.Syntax
