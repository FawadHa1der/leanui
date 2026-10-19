module
import LeanUI
import LeanUI.Testing.Harness
import Counter
meta import LeanUI.Syntax
-- compile-time checks (`#guard`, parser tests) evaluate these; none of it is linked
meta import LeanUI.Render
meta import LeanUI.Testing.Dom
meta import Lean
/-!
# Tests for the JSX-style template syntax (`LeanUI.Syntax`)

Every runtime case builds a view with a template and the same view by hand with the smart
constructors, and requires them to be *structurally identical*: same namespaces, tags, attribute
order, keys, listener events, payload kinds and flags, and texts (`shape`), plus equal
`Html.render` and `canonHtml`. Handlers are compared by decoding payloads (`fire`). Compile-time
cases check error messages (`#guard_msgs`), parse errors (`runParserCategory`) and that ordinary
Lean (`a < b`) still parses. The zero-cost property is checked on the generated C and on this
binary.
-/
open LeanUI LeanUI.Testing

namespace SyntaxTests

/-! ## Infrastructure -/

structure Stats where
  passed : Nat := 0
  failed : Array String := #[]

abbrev T := StateT Stats IO

def check (name : String) (ok : Bool) (detail : String := "") : T Unit :=
  if ok then modify fun s => { s with passed := s.passed + 1 }
  else modify fun s => { s with failed := s.failed.push s!"{name}{detail}" }

def checkEq [BEq α] [Repr α] (name : String) (got want : α) : T Unit :=
  check name (got == want) s!"\n     got: {reprStr got}\n    want: {reprStr want}"

def payloadName : Payload → String
  | .none => "none" | .value => "value" | .checked => "checked" | .key => "key" | .formData => "formData"
  | .files => "files" | .pointer => "pointer"

def propStr : PropValue → String
  | .str s => s!"str {s.quote}" | .bool b => s!"bool {b}" | .num x => s!"num {x}"

def attrShape {Msg : Type} : Attr Msg → String
  | .attr n v => s!"{n}={v.quote}"
  | .prop n v => s!".{n}=({propStr v})"
  | .on e h => s!"on:{e}[{payloadName h.payload}{if h.preventDefault then ",prevent" else ""}{if h.stopPropagation then ",stop" else ""}]"
  | .key k => s!"key={k.quote}"

def nsPrefix : Ns → String
  | .html => "" | .svg => "svg:" | .mathml => "math:"

/-- The exact structure of a view: everything except the handler functions. -/
partial def shape {Msg : Type} : Html Msg → String
  | .text s => s.quote
  | .lazy k d r => s!"lazy[{k}|{reprStr d}]" ++ shape (r ())
  | .elem ns tag as kids =>
    "<" ++ nsPrefix ns ++ tag ++ String.join (as.toList.map (" " ++ attrShape ·)) ++ ">" ++
      String.join (kids.toList.map shape) ++ "</" ++ tag ++ ">"

/-- Template and hand-built views must agree exactly. -/
def same {Msg : Type} (name : String) (got want : Html Msg) : T Unit := do
  checkEq (name ++ " (shape)") (shape got) (shape want)
  checkEq (name ++ " (render)") got.render want.render
  checkEq (name ++ " (canon)") (canonHtml got) (canonHtml want)

def sameAll {Msg : Type} (name : String) (got want : Array (Html Msg)) : T Unit :=
  checkEq name (got.map shape) (want.map shape)

partial def findById {Msg : Type} (h : Html Msg) (i : String) : Option (Html Msg) :=
  match h with
  | .elem _ _ as kids =>
    if as.any (fun | .attr "id" v => v == i | _ => false) then some h
    else kids.findSome? (findById · i)
  | .lazy _ _ r => findById (r ()) i
  | .text _ => none

/-- Decode a payload with the `ev` listener of the element `#i` (`none`: no such listener). -/
def fire {Msg : Type} (h : Html Msg) (i ev : String) (payload := "") : Option (Option Msg) := do
  let .elem _ _ as _ ← findById h i | none
  let hd ← as.findSome? fun | .on e hd => if e == ev then some hd else none | _ => none
  return hd.decode payload

/-! ## Fixtures -/

inductive Child where
  | ping | pong
  deriving BEq, Repr

inductive Msg where
  | inc | dec | reset | go
  | set (s : String)
  | check (b : Bool)
  | key (k : String)
  | submit (form : String)
  | blur
  | pick (n : Nat)
  | child (c : Child)
  deriving BEq, Repr

/-- A value with its own `ToString`, used as an attribute and as a child. -/
structure Celsius where
  deg : Int

instance : ToString Celsius := ⟨fun c => s!"{c.deg}°C"⟩

def rowId := "r1"

/-! ## Elements and attributes -/

def attrs : T Unit := do
  let k : Nat := 7
  same "string, interpolated, dashed attributes"
    (<div class="row" id={rowId} data-id={k} aria-label="x"></div> : Html Msg)
    (el "div" #[Attr.cls "row", Attr.id rowId, .attr "data-id" "7", .attr "aria-label" "x"])
  same "self-closing with props and events"
    (<input type="text" value={"draft"} onInput={Msg.set} /> : Html Msg)
    (el "input" #[.attr "type" "text", Attr.value "draft", Attr.onInput Msg.set])
  let i : Int := -3
  same "Nat, Int, Bool, Float, Char and ToString values"
    (<p a={k} b={i} aria-hidden={true} c={(2.5 : Float)} d={'x'} e={Celsius.mk 21}></p> : Html Msg)
    (el "p" #[.attr "a" "7", .attr "b" "-3", .attr "aria-hidden" "true", .attr "c" (toString (2.5 : Float)),
      .attr "d" "x", .attr "e" "21°C"])
  same "attribute order is source order"
    (<a z="1" y="2" x="3"></a> : Html Msg) (el "a" #[.attr "z" "1", .attr "y" "2", .attr "x" "3"])
  same "boolean attribute without a value"
    (<input disabled required /> : Html Msg) (el "input" #[.attr "disabled" "", .attr "required" ""])
  for b in [true, false] do
    same s!"boolean attribute from a Bool ({b})"
      (<button id="b" disabled={b} hidden={!b}>x</button> : Html Msg)
      (el "button" (#[Attr.id "b"] ++ (if b then #[.attr "disabled" ""] else #[]) ++
        (if !b then #[.attr "hidden" ""] else #[])) #[text "x"])
  same "enumerated attributes keep \"true\"/\"false\""
    (<div draggable={true} spellcheck={false} contenteditable="true"></div> : Html Msg)
    (el "div" #[.attr "draggable" "true", .attr "spellcheck" "false", .attr "contenteditable" "true"])
  same "attribute names with colons (SVG)"
    (<svg><use xlink:href="#a" xml:lang="en" /></svg> : Html Msg)
    (.elem .svg "svg" #[] #[.elem .svg "use" #[.attr "xlink:href" "#a", .attr "xml:lang" "en"] #[]])
  same "a Lean keyword as an attribute name"
    (<label for="name" class="l">Name</label> : Html Msg)
    (el "label" #[.attr "for" "name", Attr.cls "l"] #[text "Name"])
  same "names that start with `on` but are not events stay attributes"
    (<p one="1" onward="2"></p> : Html Msg) (el "p" #[.attr "one" "1", .attr "onward" "2"])
  same "string escapes in attribute literals"
    (<p title="a \"b\" <c> & d"></p> : Html Msg) (el "p" #[.attr "title" "a \"b\" <c> & d"])

/-! ## Properties: `.name`, live form state -/

def props : T Unit := do
  same "`.prop` syntax with String, Bool, Float"
    (<input .value={"x"} .checked={true} .valueAsNumber={(3.5 : Float)} .indeterminate /> : Html Msg)
    (el "input" #[.prop "value" (.str "x"), .prop "checked" (.bool true), .prop "valueAsNumber" (.num 3.5),
      .prop "indeterminate" (.bool true)])
  same "`.prop` with a literal and a Nat"
    (<li .value="a" .tabIndex={(2 : Nat)}></li> : Html Msg)
    (el "li" #[.prop "value" (.str "a"), .prop "tabIndex" (.str "2")])
  for b in [true, false] do
    same s!"value/checked/selected are live properties ({b})"
      (<div><input type="checkbox" checked={b} value={"v"} /><option selected={!b}>o</option></div> : Html Msg)
      (el "div" #[] #[el "input" #[.attr "type" "checkbox", Attr.checked b, Attr.value "v"],
        el "option" #[.prop "selected" (.bool !b)] #[text "o"]])
  same "literal value and bare checked stay attributes (initial state)"
    (<input value="init" checked /> : Html Msg) (el "input" #[.attr "value" "init", .attr "checked" ""])
  same "a PropValue passes through"
    (<video .currentTime={PropValue.num 1.5} muted={true}></video> : Html Msg)
    (el "video" #[.prop "currentTime" (.num 1.5), .prop "muted" (.bool true)])

/-! ## Events -/

def events : T Unit := do
  let v : Html Msg :=
    <form id="f" onSubmit={Msg.submit}>
      <button id="inc" onClick={.inc} onDblClick={.reset}>+</button>
      <input id="t" onInput={Msg.set} onKeyDown={fun k => if k == "Enter" then some .go else none} onBlur={.blur} />
      <select id="s" onChange={fun v => .pick (v.toNat?.getD 0)}></select>
      <input id="c" type="checkbox" onCheck={Msg.check} />
      <div id="m" on:mouseenter={{ decode := fun _ => some (Msg.key "enter") }}></div>
      <a id="l" href="#" onClick|prevent={.go}>go</a>
      <span id="x" onClick|stop|prevent={.dec} on:pointerdown|stop={{ decode := fun _ => some Msg.reset }}></span>
    </form>
  let want : Html Msg :=
    el "form" #[Attr.id "f", Attr.onSubmit Msg.submit] #[
      el "button" #[Attr.id "inc", Attr.onClick .inc, Attr.onDblClick .reset] #[text "+"],
      el "input" #[Attr.id "t", Attr.onInput Msg.set, Attr.onKeyDown (fun k => if k == "Enter" then some .go else none), Attr.onBlur .blur],
      el "select" #[Attr.id "s", Attr.onChange fun v => .pick (v.toNat?.getD 0)],
      el "input" #[Attr.id "c", .attr "type" "checkbox", Attr.onCheck Msg.check],
      el "div" #[Attr.id "m", .on "mouseenter" { decode := fun _ => some (Msg.key "enter") }],
      el "a" #[Attr.id "l", .attr "href" "#", .on "click" { decode := fun _ => some .go, preventDefault := true }] #[text "go"],
      el "span" #[Attr.id "x", .on "click" { decode := fun _ => some .dec, preventDefault := true, stopPropagation := true },
        .on "pointerdown" { decode := fun _ => some .reset, stopPropagation := true }]]
  same "every event form" v want
  checkEq "onClick decodes its message" (fire v "inc" "click") (some (some Msg.inc))
  checkEq "onDblClick" (fire v "inc" "dblclick") (some (some Msg.reset))
  checkEq "onInput passes the value" (fire v "t" "input" "hello") (some (some (Msg.set "hello")))
  checkEq "onKeyDown Enter" (fire v "t" "keydown" "Enter") (some (some Msg.go))
  checkEq "onKeyDown other key is ignored" (fire v "t" "keydown" "a") (some none)
  checkEq "onBlur listens to focusout" (fire v "t" "focusout") (some (some Msg.blur))
  checkEq "onChange passes the value" (fire v "s" "change" "4") (some (some (Msg.pick 4)))
  checkEq "onCheck true" (fire v "c" "change" "true") (some (some (Msg.check true)))
  checkEq "onCheck false" (fire v "c" "change" "false") (some (some (Msg.check false)))
  checkEq "onSubmit passes the form" (fire v "f" "submit" "a=1") (some (some (Msg.submit "a=1")))
  checkEq "on:<event> with a Handler" (fire v "m" "mouseenter") (some (some (Msg.key "enter")))
  checkEq "modifier keeps the message" (fire v "l" "click") (some (some Msg.go))
  checkEq "two modifiers" (fire v "x" "click") (some (some Msg.dec))

/-! ## Text and whitespace -/

def textCases : T Unit := do
  same "inline text keeps its spaces"
    (<p>Hello <b>world</b>, again!</p> : Html Msg)
    (el "p" #[] #[text "Hello ", el "b" #[] #[text "world"], text ", again!"])
  same "space after an element is kept"
    (<p><b>Hi</b> there</p> : Html Msg) (el "p" #[] #[el "b" #[] #[text "Hi"], text " there"])
  same "space after an interpolation is kept"
    (<p>{"a"} b {"c"}</p> : Html Msg) (el "p" #[] #[text "a", text " b ", text "c"])
  same "whitespace between tags makes no text nodes"
    (<ul> <li>a</li>   <li>b</li> </ul> : Html Msg) (el "ul" #[] #[el "li" #[] #[text "a"], el "li" #[] #[text "b"]])
  same "lines are trimmed and joined (JSX rules)"
    (<p>
       First line
         second   line
       third
     </p> : Html Msg)
    (el "p" #[] #[text "First line second   line third"])
  same "an explicit space"
    (<p><b>a</b>{" "}<i>b</i></p> : Html Msg) (el "p" #[] #[el "b" #[] #[text "a"], text " ", el "i" #[] #[text "b"]])
  same "character references"
    (<p>&lt;div&gt; &amp; &quot;q&quot; &nbsp;|&#169;&#x1F600;&lbrace;x&rbrace; &mdash; &alpha;</p> : Html Msg)
    (el "p" #[] #[text "<div> & \"q\"  |©😀{x} — α"])
  same "an unescaped ampersand is text"
    (<p>Tom & Jerry &&</p> : Html Msg) (el "p" #[] #[text "Tom & Jerry &&"])
  same "a string child is escaped when rendered, never parsed"
    (<p>{"<b>not bold</b>"}</p> : Html Msg) (el "p" #[] #[text "<b>not bold</b>"])
  same "text that looks like Lean"
    (<p>'tis "half quoted, don't $5 #1 @x `tick` 0x 3.14 -- not a comment</p> : Html Msg)
    (el "p" #[] #[text "'tis \"half quoted, don't $5 #1 @x `tick` 0x 3.14 -- not a comment"])
  same "comments between children, `{}` adds nothing"
    (<ul>
      -- a line comment where a child starts
      <li>a</li>
      {/- a block comment -/}
      {}
      <li>b</li>
    </ul> : Html Msg)
    (el "ul" #[] #[el "li" #[] #[text "a"], el "li" #[] #[text "b"]])
  same "unicode text"
    (<p>−→ λ 日本語 🎉</p> : Html Msg) (el "p" #[] #[text "−→ λ 日本語 🎉"])

/-! ## Children: interpolation and splices -/

def viewItem (n : Nat) : Html Msg := <li id={s!"i{n}"}>{n}</li>

def children : T Unit := do
  let h : Html Msg := <b>x</b>
  let s := "str"
  let n : Nat := 42
  let i : Int := -1
  same "Html, String, Nat, Int, ToString children"
    (<p>{h}{s}{n}{i}{Celsius.mk 5}</p> : Html Msg)
    (el "p" #[] #[h, text "str", text "42", text "-1", text "5°C"])
  same "literal children"
    (<p>{"lit"}{7}</p> : Html Msg) (el "p" #[] #[text "lit", text "7"])
  let xs : Array Nat := #[1, 2, 3]
  same "spliced Array"
    (<ul><li>first</li>{...xs.map viewItem}<li>last</li></ul> : Html Msg)
    (el "ul" #[] (#[el "li" #[] #[text "first"]] ++ xs.map viewItem ++ #[el "li" #[] #[text "last"]]))
  same "spliced List and Array String"
    (<p>{...[h, h]}{...#["a", "b"]}</p> : Html Msg) (el "p" #[] #[h, h, text "a", text "b"])
  for o in [some h, none] do
    same s!"spliced Option ({o.isSome})"
      (<p>{...o}<i>y</i></p> : Html Msg) (el "p" #[] ((match o with | some x => #[x] | none => #[]) ++ #[el "i" #[] #[text "y"]]))
  same "only a splice"
    (<ul>{...xs.map viewItem}</ul> : Html Msg) (el "ul" #[] (xs.map viewItem))
  same "a splice between texts"
    (<p>a{...#["b"]}c</p> : Html Msg) (el "p" #[] #[text "a", text "b", text "c"])
  same "nested templates inside interpolations"
    (<div>{if n > 3 then <b>big</b> else <i>small</i>}</div> : Html Msg) (el "div" #[] #[el "b" #[] #[text "big"]])
  let late : Array (Html Msg) := xs.map fun i => <li key={i}>{i}</li>
  sameAll "values whose type is decided late (an untyped binder)" late
    (xs.map fun i => el "li" #[Attr.key (toString i)] #[text (toString i)])
  for c in [true, false] do
    same s!"a child that needs its expected type ({c})"
      (<p>{if c then .text "yes" else .elem .html "i" #[] #[]}</p> : Html Msg)
      (el "p" #[] #[if c then text "yes" else el "i"])
  same "anonymous-function argument inside a splice"
    (<ul>{...xs.map (<li>{·}</li>)}</ul> : Html Msg) (el "ul" #[] (xs.map fun x => el "li" #[] #[text (toString x)]))
  for c in [true, false] do
    same s!"if=\{cond} ({c})"
      (<ul><li if={c}>maybe</li><li>always</li><Badge if={!c} n={1} /></ul> : Html Msg)
      (el "ul" #[] ((if c then #[el "li" #[] #[text "maybe"]] else #[]) ++ #[el "li" #[] #[text "always"]] ++
        (if !c then #[Badge 1] else #[])))
  same "an element with many children (one array literal)"
    (<tr><td>1</td><td>2</td><td>3</td><td>4</td><td>5</td><td>6</td><td>7</td><td>8</td><td>9</td></tr> : Html Msg)
    (el "tr" #[] ((Array.range 9).map fun i => el "td" #[] #[text (toString (i + 1))]))
where
  Badge (n : Nat) : Html Msg := <span class="badge">{n}</span>

/-! ## Fragments -/

def pair : Array (Html Msg) := <><b>a</b><i>b</i></>

def fragments : T Unit := do
  sameAll "a fragment is an array" pair #[el "b" #[] #[text "a"], el "i" #[] #[text "b"]]
  same "a fragment child is spliced"
    (<p><>x<br/></>y</p> : Html Msg) (el "p" #[] #[text "x", el "br", text "y"])
  same "a spliced fragment value"
    (<div>{...pair}</div> : Html Msg) (el "div" #[] pair)
  sameAll "an empty fragment" (<></> : Array (Html Msg)) #[]
  let kv : Array (String × Nat) := #[("a", 1), ("b", 2)]
  same "an array of fragments is flattened"
    (<dl>{...kv.map fun (k, v) => <><dt>{k}</dt><dd>{v}</dd></>}</dl> : Html Msg)
    (el "dl" #[] #[el "dt" #[] #[text "a"], el "dd" #[] #[text "1"], el "dt" #[] #[text "b"], el "dd" #[] #[text "2"]])

/-! ## class and style -/

def classes : T Unit := do
  for (a, b) in [(true, true), (true, false), (false, true), (false, false)] do
    same s!"class with toggles ({a}, {b})"
      (<li class="todo" class:done={a} class:editing={b}></li> : Html Msg)
      (el "li" #[Attr.classes [("todo", true), ("done", a), ("editing", b)]])
    same s!"toggles only ({a}, {b})"
      (<li class:done={a} class:editing={b}></li> : Html Msg)
      (el "li" #[Attr.classes [("done", a), ("editing", b)]])
    let base := if a then "x y" else ""
    same s!"computed base with a toggle ({a}, {b})"
      (<li id="i" class={base} class:on={b}></li> : Html Msg)
      (el "li" #[Attr.id "i", Attr.classes [(base, true), ("on", b)]])
  same "a bare toggle, a Tailwind-style name"
    (<p class:always class:hover:underline={true}></p> : Html Msg)
    (el "p" #[Attr.classes [("always", true), ("hover:underline", true)]])
  same "class keeps its position"
    (<p id="a" class:x={true} title="t"></p> : Html Msg)
    (el "p" #[Attr.id "a", Attr.classes [("x", true)], .attr "title" "t"])
  let w : Nat := 10
  same "style and style:prop"
    (<p style="color: red" style:width={s!"{w}px"} style:margin="0"></p> : Html Msg)
    (el "p" #[.attr "style" "color: red; width: 10px; margin: 0"])
  same "style:prop only, numeric value"
    (<p style:opacity={(1 : Nat)} style:z-index={w}></p> : Html Msg)
    (el "p" #[.attr "style" "opacity: 1; z-index: 10"])

/-! ## Optional attributes and attribute splices -/

def optionals : T Unit := do
  for t in [some "tip", none] do
    same s!"name?=\{opt} ({t.isSome})"
      (<a href="#" title?={t} data-n?={t.map String.length}>x</a> : Html Msg)
      (el "a" (#[.attr "href" "#"] ++ (match t with | some v => #[.attr "title" v] | none => #[]) ++
        (match t with | some v => #[.attr "data-n" (toString v.length)] | none => #[])) #[text "x"])
  let extra : Array (Attr Msg) := #[.attr "role" "button", Attr.onClick .go]
  same "attribute splice"
    (<div id="d" {...extra} tabindex="0"></div> : Html Msg)
    (el "div" (#[Attr.id "d"] ++ extra ++ #[.attr "tabindex" "0"]))
  same "attribute splice from a List and an Option"
    (<div {...[Attr.cls "a"]} {...(some (Attr.id "i") : Option (Attr Msg))} {...(none : Option (Attr Msg))}></div> : Html Msg)
    (el "div" #[Attr.cls "a", Attr.id "i"])

/-! ## Keys -/

def keys : T Unit := do
  let ids : Array Nat := #[3, 1, 2]
  let v : Html Msg := <ul>{...ids.map fun i => <li key={i}>{i}</li>}<li key="end">end</li></ul>
  same "keys from Nat and String"
    v (el "ul" #[] (ids.map (fun i => el "li" #[Attr.key (toString i)] #[text (toString i)]) |>.push
      (el "li" #[Attr.key "end"] #[text "end"])))
  match v with
  | .elem _ _ _ kids => checkEq "Html.key? sees template keys" (kids.map Html.key?) #[some "3", some "1", some "2", some "end"]
  | _ => check "keys: not an element" false

/-! ## Namespaces -/

def namespaces : T Unit := do
  let pts : Array Nat := #[1, 2]
  same "svg subtree, foreignObject switches back, math subtree"
    (<div>
      <svg viewBox="0 0 10 10">
        <g><circle cx={5} r="4" /><text x="1">label</text></g>
        <foreignObject><p>html <b>inside</b></p></foreignObject>
      </svg>
      <math><mrow><mi>x</mi><mo>=</mo><mn>1</mn></mrow></math>
    </div> : Html Msg)
    (el "div" #[] #[
      .elem .svg "svg" #[.attr "viewBox" "0 0 10 10"] #[
        .elem .svg "g" #[] #[.elem .svg "circle" #[.attr "cx" "5", .attr "r" "4"] #[],
          .elem .svg "text" #[.attr "x" "1"] #[text "label"]],
        .elem .svg "foreignObject" #[] #[el "p" #[] #[text "html ", el "b" #[] #[text "inside"]]]],
      .elem .mathml "math" #[] #[.elem .mathml "mrow" #[] #[.elem .mathml "mi" #[] #[text "x"],
        .elem .mathml "mo" #[] #[text "="], .elem .mathml "mn" #[] #[text "1"]]]])
  same "SVG-only tags keep their namespace inside interpolations"
    (<svg>{...pts.map fun p => <circle r={p} />}<g>{<path d="M0 0" />}</g></svg> : Html Msg)
    (.elem .svg "svg" #[] ((pts.map fun p => .elem .svg "circle" #[.attr "r" (toString p)] #[]) |>.push
      (.elem .svg "g" #[] #[.elem .svg "path" #[.attr "d" "M0 0"] #[]])))
  same "ambiguous tags follow the context; prefixes force it"
    (<div><a href="/">html a</a><svg><a href="#x">svg a</a></svg><svg:a href="#y" /><html:title>t</html:title></div> : Html Msg)
    (el "div" #[] #[el "a" #[.attr "href" "/"] #[text "html a"],
      .elem .svg "svg" #[] #[.elem .svg "a" #[.attr "href" "#x"] #[text "svg a"]],
      .elem .svg "a" #[.attr "href" "#y"] #[], el "title" #[] #[text "t"]])
  same "math: prefix and MathML-only tags"
    (<p>inline <math:mi>y</math:mi> and <mn>2</mn></p> : Html Msg)
    (el "p" #[] #[text "inline ", .elem .mathml "mi" #[] #[text "y"], text " and ", .elem .mathml "mn" #[] #[text "2"]])
  same "camelCase SVG names are kept"
    (<svg><linearGradient id="g"><stop offset="0" /></linearGradient><feGaussianBlur stdDeviation="2" /></svg> : Html Msg)
    (.elem .svg "svg" #[] #[.elem .svg "linearGradient" #[Attr.id "g"] #[.elem .svg "stop" #[.attr "offset" "0"] #[]],
      .elem .svg "feGaussianBlur" #[.attr "stdDeviation" "2"] #[]])

/-! ## Components -/

/-- A component: a function with named arguments; `children` receives the content. -/
def Card (title : String) (children : Array (Html Msg) := #[]) (featured : Bool := false) (level : Nat := 2) :
    Html Msg :=
  <section class="card" class:featured={featured}>
    {.elem .html s!"h{level}" #[] #[text title]}
    {...children}
  </section>

def Icon (name : String) : Html Msg := <svg class="icon"><use href={s!"#{name}"} /></svg>

def Empty : Html Msg := <hr />

namespace Ui
def Button (label : String) (onPress : Msg) (primary := false) : Html Msg :=
  <button class="btn" class:primary={primary} onClick={onPress}>{label}</button>
end Ui

/-- A component with its own message type, embedded with `Html.map`. -/
def Toggle (on : Bool) : Html Child :=
  <button id="toggle" onClick={if on then Child.pong else Child.ping}>{if on then "on" else "off"}</button>

/-- A component that returns several nodes (a fragment): spliced where it is used. -/
def Pair (a b : String) : Array (Html Msg) := <><dt>{a}</dt><dd>{b}</dd></>

def components : T Unit := do
  same "a fragment component is spliced; `if` applies to all of it"
    (<dl><Pair a="k" b="v" /><Pair if={false} a="x" b="y" /><Pair if={true} a="p" b="q" /></dl> : Html Msg)
    (el "dl" #[] (Pair "k" "v" ++ Pair "p" "q"))
  same "a component call with named arguments and children"
    (<Card title="Hello" featured level={3}><p>body</p>text</Card> : Html Msg)
    (Card "Hello" #[el "p" #[] #[text "body"], text "text"] true 3)
  same "a component without children uses the default"
    (<Card title="T" /> : Html Msg) (Card "T")
  same "a component without arguments"
    (<div><Empty /></div> : Html Msg) (el "div" #[] #[Empty])
  same "a qualified component; message argument"
    (<Ui.Button label="Save" onPress={.go} primary /> : Html Msg) (Ui.Button "Save" .go true)
  checkEq "the component's handler" (fire (<div id="w"><Ui.Button label="x" onPress={.reset} /></div> : Html Msg) "w" "click") none
  same "a key on a component goes on its root element"
    (<ul><Card key="c1" title="A" /></ul> : Html Msg)
    (el "ul" #[] #[match Card "A" with
      | .elem ns t as ks => .elem ns t (as.push (Attr.key "c1")) ks
      | other => other])
  same "components nest, and SVG components work"
    (<Card title="Icons"><Icon name="star" /><Card title="inner"><Icon name="moon" /></Card></Card> : Html Msg)
    (Card "Icons" #[Icon "star", Card "inner" #[Icon "moon"]])
  let v : Html Msg := <div>{(<Toggle on={true} /> : Html Child).map Msg.child}</div>
  same "Html.map composes components with their own messages"
    v (el "div" #[] #[(Toggle true).map Msg.child])
  checkEq "the mapped handler" (fire v "toggle" "click") (some (some (Msg.child .pong)))
  same "functions returning Html as children"
    (<ul>{viewItem 1}{viewItem 2}</ul> : Html Msg) (el "ul" #[] #[viewItem 1, viewItem 2])

/-! ## Term positions -/

def positions : T Unit := do
  -- as a function argument (guarded: a complete opening tag must follow)
  let a : Html Msg := Html.map id <p>arg</p>
  same "argument position" a (el "p" #[] #[text "arg"])
  let b : Html Msg ← pure <span>pure</span>
  same "pure <…/>" b (el "span" #[] #[text "pure"])
  let c : Array (Html Msg) := #[<i>1</i>, <i>2</i>].push <i>3</i>
  sameAll "array literal and push" c #[el "i" #[] #[text "1"], el "i" #[] #[text "2"], el "i" #[] #[text "3"]]
  let d : List (Html Msg) := [<b/>, <b/>]
  checkEq "list literal" d.length 2
  let e : Html Msg := match (3 : Nat) with | 0 => <p>zero</p> | _ => <p>many</p>
  same "match arms" e (el "p" #[] #[text "many"])
  let f := fun (s : String) => (<em>{s}</em> : Html Msg)
  same "lambda body" (f "x") (el "em" #[] #[text "x"])

/-! ## Ordinary Lean still parses (these would fail to compile otherwise) -/

def o1 (a b : Nat) : Bool := if a < b then true else false
def o2 (a b : Nat) : Bool := a<b
def o3 (xs : List Nat) : List Nat := xs.filter (· < 3)
def o4 (a b : Nat) : Nat := if a <b then 1 else 2
def o5 (a b : Nat) : Bool := a <b
def o6 (x : Nat) : Nat := Id.run do
  let mut m := 0
  for i in [0:x] do
    if m < i then m := i
  return m
theorem o7 (a b : Nat) (h : a < b) : a < b + 1 := by omega
def o8 (a b : Int) : Bool := (a < b - 1) && b > a

def ordinary : T Unit := do
  checkEq "a < b" (o1 1 2, o1 2 1) (true, false)
  checkEq "a<b" (o2 1 2) true
  checkEq "(· < 3)" (o3 [1, 5, 2]) [1, 2]
  checkEq "if a <b then" (o4 1 2, o4 2 1) (1, 2)
  checkEq "a <b at the end of a definition" (o5 1 2) true
  checkEq "comparisons in do blocks" (o6 5) 4
  checkEq "&& and >" (o8 0 5) true

/-! ## The counter example is the same view as its hand-written original -/

open Counter in
def counterOriginal (n : Int) : Html Counter.Msg :=
  el "main" #[Attr.cls "counter"] #[
    el "h1" #[] #[text "LeanUI counter"],
    el "p" #[] #[
      el "button" #[Attr.id "dec", Attr.onClick .dec] #[text "−"],
      el "output" #[Attr.id "value", Attr.cls (if n < 0 then "neg" else "pos")] #[text (toString n)],
      el "button" #[Attr.id "inc", Attr.onClick .inc] #[text "+"]],
    el "p" #[] #[
      el "input" #[Attr.id "box", Attr.attr "type" "number", Attr.value (toString n),
        Attr.onInput fun s => .set (s.toInt?.getD n)] #[],
      el "button" #[Attr.id "reset", Attr.onClick .reset] #[text "reset"]]]

instance : BEq Counter.Msg where
  beq
    | .inc, .inc | .dec, .dec | .reset, .reset => true
    | .set a, .set b => a == b
    | _, _ => false

instance : Repr Counter.Msg where
  reprPrec m _ := match m with
    | .inc => "inc" | .dec => "dec" | .reset => "reset" | .set n => s!"set {n}"

def counter : T Unit := do
  for n in [(0 : Int), 3, -7] do
    same s!"Counter.view {n}" (Counter.view n) (counterOriginal n)
    for (i, ev, p) in [("inc", "click", ""), ("dec", "click", ""), ("reset", "click", ""), ("box", "input", "12"), ("box", "input", "x")] do
      checkEq s!"Counter.view {n}: {ev} on #{i}" (fire (Counter.view n) i ev p) (fire (counterOriginal n) i ev p)

/-! ## The whole engine on a template-built app (DOM model) -/

structure Todo where
  id : Nat
  title : String
  done : Bool := false

structure Model where
  todos : Array Todo := #[]
  draft : String := ""
  next : Nat := 1
  editing : Option Nat := none

inductive TMsg where
  | draft (s : String) | add | toggle (id : Nat) | remove (id : Nat) | edit (id : Nat) | clear

def tupdate : TMsg → Model → Model
  | .draft s, m => { m with draft := s }
  | .add, m => if m.draft.isEmpty then m else
      { m with todos := m.todos.push { id := m.next, title := m.draft }, draft := "", next := m.next + 1 }
  | .toggle i, m => { m with todos := m.todos.map fun t => if t.id == i then { t with done := !t.done } else t }
  | .remove i, m => { m with todos := m.todos.filter (·.id != i) }
  | .edit i, m => { m with editing := some i }
  | .clear, m => { m with todos := m.todos.filter (!·.done) }

def tview (m : Model) : Html TMsg :=
  -- `;` ends the `let`: a template on the next line would otherwise continue it as `… < …`
  let left := (m.todos.filter (!·.done)).size;
  <section class="todoapp">
    <header>
      <h1>todos</h1>
      <input id="new" class="new-todo" placeholder="What needs to be done?" value={m.draft}
        onInput={TMsg.draft} onKeyDown={fun k => if k == "Enter" then some .add else none} />
    </header>
    <ul class="todo-list">
      {...m.todos.map fun t =>
        <li key={t.id} class:completed={t.done} class:editing={m.editing == some t.id}>
          <input id={s!"t{t.id}"} class="toggle" type="checkbox" checked={t.done} onCheck={fun _ => .toggle t.id} />
          <label id={s!"l{t.id}"} onDblClick={.edit t.id}>{t.title}</label>
          <button id={s!"x{t.id}"} class="destroy" onClick={.remove t.id} />
        </li>}
    </ul>
    <footer if={!m.todos.isEmpty} class="footer">
      <span class="todo-count"><strong>{left}</strong> {if left == 1 then "item" else "items"} left</span>
      <button id="clear" if={left < m.todos.size} onClick={.clear}>Clear completed</button>
    </footer>
  </section>

def todoProgram : Program Model TMsg where
  init _ := ({}, .none)
  update msg m := (tupdate msg m, .none)
  view := tview

def engine : T Unit := do
  let r ← run todoProgram
  let mut m : Model := {}
  let step (what : String) (m : Model) : T Unit := do
    try r.check (tview m) what; check what true
    catch e => check what false s!": {e}"
  step "mount" m
  for title in ["milk", "eggs", "bread", "jam"] do
    r.fire (← r.find "id" "new") "input" title
    m := tupdate (.draft title) m
    r.fire (← r.find "id" "new") "keydown" "Enter"
    m := tupdate .add m
    step s!"add {title}" m
  r.fire (← r.find "id" "t2") "change" "true"; m := tupdate (.toggle 2) m; step "toggle 2" m
  r.fire (← r.find "id" "l3") "dblclick"; m := tupdate (.edit 3) m; step "edit 3" m
  r.fire (← r.find "id" "x1") "click"; m := tupdate (.remove 1) m; step "remove 1" m
  r.fire (← r.find "id" "t4") "change" "true"; m := tupdate (.toggle 4) m; step "toggle 4" m
  r.fire (← r.find "id" "clear") "click"; m := tupdate .clear m; step "clear completed" m
  r.fire (← r.find "id" "x3") "click"; m := tupdate (.remove 3) m; step "remove the last one" m
  checkEq "footer gone with the last todo" m.todos.size 0

/-! ## Zero runtime cost -/

/-- Does `hay` contain `needle`? (Byte search; a binary is not UTF-8.) -/
def containsBytes (hay : ByteArray) (needle : String) : Bool := Id.run do
  let n := needle.toUTF8
  if n.size == 0 then return true
  for i in [0:hay.size + 1 - n.size] do
    if hay[i]! == n[0]! then
      let mut ok := true
      for j in [1:n.size] do
        if hay[i + j]! != n[j]! then ok := false; break
      if ok then return true
  return false

/-- Search strings are spelled backwards in the source: this binary and its C contain the source's
string constants, so a forward spelling would always be found. -/
def needle (reversed : String) : String := String.ofList reversed.toList.reverse

/-- The body of the C function whose definition starts with `header`. -/
def cFunction (c header : String) : Option String :=
  match c.splitOn header with
  | _ :: rest :: _ => some ((rest.splitOn "\n}\n").headD "")
  | _ => none

def zeroCost : T Unit := do
  -- modules that use templates: this test and the counter app
  -- (this test module also defines `meta` code of its own, so only an app module like the counter
  -- can be required to mention no compiler declaration at all)
  for (file, mod, isApp) in [(".lake/build/ir/tests/Syntax.c", "tests_Syntax", false), (".lake/build/ir/Counter.c", "Counter", true)] do
    unless ← System.FilePath.pathExists file do
      check s!"zero-cost: {file} exists (run from the repository root after `lake build`)" false
      continue
    let c ← IO.FS.readFile file
    -- control: the module does reach the template code, at compile time
    match cFunction c s!"LEAN_EXPORT lean_object* meta_initialize_leanui_{mod}(uint8_t builtin) \{" with
    | some body => check s!"zero-cost: {mod} meta-imports the template module (control)" ((body.splitOn (needle "xatnyS_IUnaeL")).length > 1)
    | none => check s!"zero-cost: meta initializer of {mod} found" false
    match cFunction c s!"LEAN_EXPORT lean_object* runtime_initialize_leanui_{mod}(uint8_t builtin) \{" with
    | none => check s!"zero-cost: runtime initializer of {mod} found" false
    | some body =>
      check s!"zero-cost: {mod}'s runtime initializer does not initialize Lean" ((body.splitOn (needle "naeL_ezilaitini")).length == 1)
      check s!"zero-cost: {mod}'s runtime initializer does not initialize LeanUI.Syntax" ((body.splitOn (needle "xatnyS_IUnaeL")).length == 1)
      IO.println s!"  {file}: runtime initializer calls {((body.splitOn "runtime_initialize_").drop 1).map (·.takeWhile (· != '('))}"
    -- an app's compiled code refers to neither the compiler nor the template module
    if isApp then
      check s!"zero-cost: {mod} code references no Lean.* declaration" ((c.splitOn (needle "_naeL_l ")).length == 1 && (c.splitOn (needle "_naeL_l(")).length == 1)
      check s!"zero-cost: {mod} code references no LeanUI.Syntax declaration" ((c.splitOn (needle "xatnyS_IUnaeL_iunael_pl")).length == 1)
  -- this binary was linked from a module that uses templates
  let exe ← IO.appPath
  let bytes ← IO.FS.readBinFile exe
  -- control: the symbol table is there, so an absent symbol means absent code
  check "zero-cost: this binary has a symbol table (control)" (containsBytes bytes (needle "lmtH_IUnaeL_iunael_ezilaitini_emitnur"))
  check "zero-cost: no Lean initializer is linked into this binary" (!containsBytes bytes (needle "_naeL_ezilaitini"))
  check "zero-cost: no template elaborator is linked into this binary" (!containsBytes bytes (needle "dnahtrohs tneve nwonknu"))
  check "zero-cost: this binary is small (no compiler: < 16 MB)" (bytes.size < 16 * 1024 * 1024)
  IO.println s!"  {exe}: {bytes.size} bytes, no Lean initializers, no template code"


/-! ## Compile-time checks

Templates evaluated while this file compiles, and the error messages a template author sees. A
`#guard_msgs` fails the build when the message changes. -/

#guard (<p class="x">hi <b>there</b></p> : Html Unit).render == "<p class=\"x\">hi <b>there</b></p>"
#guard (<ul> <li>a</li> <li>b</li> </ul> : Html Unit).render == "<ul><li>a</li><li>b</li></ul>"
#guard (<p>{"a"}{"b"}</p> : Html Unit).render == "<p>a<!--|-->b</p>"
#guard canonHtml (<input value={"v"} disabled={false} /> : Html Unit) == "<input .value=\"v\"></input>"
#guard (match (<svg><circle /></svg> : Html Unit) with
  | .elem .svg _ _ #[.elem .svg "circle" _ _] => true | _ => false)

-- uses inside templates are visible to the unused-variables linter, also when a value's type is
-- decided late (`i` has no type until `ids` is elaborated; the pair pattern is a postponed `match`)
#guard_msgs in
def usesSeen (ids : Array Nat) : Array (Html Msg) := ids.map fun i => <li key={i} title={i} .tabIndex={i}>{i}</li>
#guard_msgs in
def usesSeen2 (kv : Array (String × Nat)) : Html Msg := <dl>{...kv.map fun (k, v) => <><dt>{k}</dt><dd>{v}</dd></>}</dl>

-- parse errors (reported where they happen)
open Lean Elab Command in
meta def parseTerm (input : String) : CommandElabM Unit := do
  match Parser.runParserCategory (← getEnv) `term input with
  | .ok _ => logInfo "ok"
  | .error e => logInfo e

/-- info: <input>:1:11: expected </li>, found </div> -/
#guard_msgs in run_cmd parseTerm "<ul><li>a</div></ul>"
/-- info: <input>:1:26: expected </input>, found </div>; <input> is a void element: write <input … /> -/
#guard_msgs in run_cmd parseTerm "<div><input type=\"text\"></div>"
/-- info: <input>:1:8: expected </div>, found </> -/
#guard_msgs in run_cmd parseTerm "<div>x</>"
/-- info: <input>:1:6: '>' cannot appear in JSX text; write &gt; or {">"} -/
#guard_msgs in run_cmd parseTerm "<p>a > b</p>"
/-- info: <input>:1:6: '}' cannot appear in JSX text; write &rbrace; or {"}"} -/
#guard_msgs in run_cmd parseTerm "<p>a } b</p>"
/-- info: <input>:3:1: template text starts in column 0 here; indent it (or, if this is Lean code, an element above is missing its closing tag) -/
#guard_msgs in run_cmd parseTerm "<div>\n  <p>a</p>\nlost text\n</div>"
/-- info: <input>:2:3: this template starts a line, but `<` is also less-than, so Lean reads it as continuing the expression on the line above; end that line with `;` or put the template in parentheses -/
#guard_msgs in run_cmd parseTerm "let n := 1\n<p>{n}</p>"
/-- info: ok -/
#guard_msgs in run_cmd parseTerm "let n := 1;\n<p>{n}</p>"
/-- info: ok -/
#guard_msgs in run_cmd parseTerm "<mo>=</mo>"
/-- info: ok -/
#guard_msgs in run_cmd parseTerm "a <b"
/-- info: ok -/
#guard_msgs in run_cmd parseTerm "if a <b then c <d else e<f"
/-- info: ok -/
#guard_msgs in run_cmd parseTerm "Html.map id\n  <p>an argument on the next line</p>"

-- elaboration errors
/-- error: unknown event shorthand `onFoo`. The shorthands are onClick, onDblClick, onInput, onChange, onCheck, onKeyDown, onSubmit, onBlur; for any other DOM event write `on:foo={handler}` with `handler : LeanUI.Handler Msg` -/
#guard_msgs in example : Html Msg := <button onFoo={.inc}>x</button>
/-- error: unknown event shorthand `onKeydown`. Did you mean `onKeyDown`? The shorthands are onClick, onDblClick, onInput, onChange, onCheck, onKeyDown, onSubmit, onBlur; for any other DOM event write `on:keydown={handler}` with `handler : LeanUI.Handler Msg` -/
#guard_msgs in example : Html Msg := <button onKeydown={fun _ => none}>x</button>
/-- error: `onclick` looks like an inline JavaScript handler, which LeanUI does not run; use `onClick={msg}` or `on:click={handler}` -/
#guard_msgs in example : Html Msg := <button onclick="alert(1)">x</button>
/-- error: `onClick` takes a message `Msg`: write `onClick={…}` -/
#guard_msgs in example : Html Msg := <button onClick="inc">x</button>
/-- error: `onClick` takes a message `Msg`: write `onClick={…}` -/
#guard_msgs in example : Html Msg := <button onClick>x</button>
/-- error: `on:click` takes a handler: `on:click={h}` with `h : LeanUI.Handler Msg` -/
#guard_msgs in example : Html Msg := <div on:click="go()"></div>
/-- error: unknown event modifier `|once`; the modifiers are `|prevent` (preventDefault) and `|stop` (stopPropagation) -/
#guard_msgs in example : Html Msg := <button onClick|once={.inc}>x</button>
/-- error: `|` modifiers apply to event listeners only (`onClick|prevent={msg}`), not to `title` -/
#guard_msgs in example : Html Msg := <p title|prevent="x"></p>
/-- error: LeanUI uses HTML attribute names: write `class`, not `className` -/
#guard_msgs in example : Html Msg := <p className="x"></p>
/-- error: LeanUI uses HTML attribute names: write `for`, not `htmlFor` -/
#guard_msgs in example : Html Msg := <label htmlFor="x"></label>
/-- error: duplicate attribute `id` on <p> -/
#guard_msgs in example : Html Msg := <p id="a" id="b"></p>
/-- error: duplicate `class` on <p>; add classes with `class:name={cond}` -/
#guard_msgs in example : Html Msg := <p class="a" class="b"></p>
/-- error: duplicate listener for `change` (`onCheck`) on <input> -/
#guard_msgs in example : Html Msg := <input onChange={Msg.set} onCheck={Msg.check} />
/-- error: duplicate `key` on <li> -/
#guard_msgs in example : Html Msg := <li key="a" key="b"></li>
/-- error: `key` needs a value: `key="…"` or `key={k}` -/
#guard_msgs in example : Html Msg := <li key></li>
/-- error: `class:done` takes a condition: `class:done={cond}` with `cond : Bool` -/
#guard_msgs in example : Html Msg := <li class:done="yes"></li>
/--
error: `title` got an `Option`
  Option String
write `title?={…}` to set the attribute only when the value is `some`
-/
#guard_msgs in example : Html Msg := <p title={some "x"}></p>
/-- error: `title?` takes an `Option`: `title?={opt}` -/
#guard_msgs in example : Html Msg := <p title?="x"></p>
/--
error: `class` got an `Option`
  Option String
supply a default, as in `class={e.getD ""}`
-/
#guard_msgs in example : Html Msg := <p class={some "x"}></p>
/-- error: `key` needs one element, but `Pair` returns several -/
#guard_msgs in example : Html Msg := <dl><Pair key="k" a="x" b="y" /></dl>
/--
error: `title` needs a string-like value, but this has type
  Html Msg
-/
#guard_msgs in example : Html Msg := <p title={(<b/> : Html Msg)}></p>
/--
error: this child has type
  Array (Html Msg)
splice a collection of children with `{...e}` instead of `{e}`
-/
#guard_msgs in example : Html Msg := <p>{#[(<b/> : Html Msg)]}</p>
/-- error: a `Bool` is not a child; for a conditional child write `{...if c then #[…] else #[]}`, for the word write `{toString b}` -/
#guard_msgs in example : Html Msg := <p>{true}</p>
/--
error: a child must be an `Html Msg`, a `String`, or a value with a `ToString` instance, but this has type
  Nat → Nat
-/
#guard_msgs in example : Html Msg := <p>{fun (x : Nat) => x}</p>
/--
error: `{...e}` splices an `Array (Html Msg)` (or a `List`, an `Option`, an `Array String` or an array of fragments), but this has type
  Nat
-/
#guard_msgs in example : Html Msg := <p>{...(5 : Nat)}</p>
/-- error: <input> is a void element and cannot have children; write <input … /> -/
#guard_msgs in example : Html Msg := <input>x</input>
/-- error: `Div` is not a component (a function whose result is `Html Msg`); HTML and SVG element names are written in lowercase: <div> -/
#guard_msgs in example : Html Msg := <Div>x</Div>
/-- error: `Nat` is not a component (a function whose result is `Html Msg`) -/
#guard_msgs in example : Html Msg := <Nat />
/-- error: `if={cond}` applies to a child element (it decides whether the child is there); for a whole template write `if cond then <…/> else <…/>` -/
#guard_msgs in example : Html Msg := <p if={true}>x</p>
/-- error: `if` takes a condition: `if={cond}` with `cond : Bool` -/
#guard_msgs in example : Html Msg := <ul><li if="yes">x</li></ul>
/-- error: attribute spreads are not supported on components; pass the value as a named argument of `Card` -/
#guard_msgs in example : Html Msg := <Card title="x" {...#[]} />
/-- error: `data-x` is not a valid argument name: a component's attributes are the named arguments of the function `Card` -/
#guard_msgs in example : Html Msg := <Card data-x="1" title="x" />
/-- error: pass children between <Card> and </Card>, not as an attribute -/
#guard_msgs in example : Html Msg := <Card title="x" children={#[]} />
/-- error: invalid property name `.`: write `.name={value}` with a DOM property name such as `.value` -/
#guard_msgs in example : Html Msg := <input .="x" />
/-- error: invalid element name <ui.Button>; components (functions returning `Html`) start with an uppercase letter -/
#guard_msgs in example : Html Msg := <ui.Button />
/-- error: invalid character reference &#0; -/
#guard_msgs in example : Html Msg := <p>&#0;</p>

-- warnings
/-- warning: unknown HTML element <dvi>; custom elements need a dash in their name (<my-dvi>), SVG and MathML elements belong inside <svg> or <math> (or use the `svg:`/`math:` prefix) -/
#guard_msgs in example : Html Msg := <dvi>x</dvi>
/-- warning: unknown SVG element <circel> (SVG element names are case-sensitive) -/
#guard_msgs in example : Html Msg := <svg><circel /></svg>
/-- warning: unknown character reference `&bogus;` (kept as written); escape `&` as `&amp;` -/
#guard_msgs in example : Html Msg := <p>&bogus;</p>
#guard_msgs in example : Html Msg := <html:marquee>allowed</html:marquee>

end SyntaxTests

open SyntaxTests in
public def main : IO UInt32 := do
  IO.println "leanui syntax tests"
  let groups : List (String × T Unit) := [
    ("attributes", attrs), ("properties", props), ("events", events), ("text", textCases),
    ("children", children), ("fragments", fragments), ("class and style", classes),
    ("optional attributes and splices", optionals), ("keys", keys), ("namespaces", namespaces),
    ("components", components), ("term positions", positions), ("ordinary Lean", ordinary),
    ("counter example", counter), ("engine (DOM model)", engine), ("zero runtime cost", zeroCost)]
  let mut total : Stats := {}
  for (name, g) in groups do
    let ((), s) ← g.run {}
    IO.println s!"  {name}: {s.passed} passed{if s.failed.isEmpty then "" else s!", {s.failed.size} FAILED"}"
    for f in s.failed do IO.println s!"    FAIL {f}"
    total := { passed := total.passed + s.passed, failed := total.failed ++ s.failed }
  if total.failed.isEmpty then
    IO.println s!"all {total.passed} checks passed"
    return 0
  else
    IO.println s!"{total.failed.size} of {total.passed + total.failed.size} checks FAILED"
    return 1
