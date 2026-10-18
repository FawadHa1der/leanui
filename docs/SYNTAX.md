# LeanUI templates

LeanUI views are values of type `Html Msg`. They can be built with the smart constructors of
`LeanUI.Html` (`el`, `text`, `Attr.*`), or written as JSX-style templates:

```lean
module
public import LeanUI
meta import LeanUI.Syntax          -- templates are compile-time only
public section
open LeanUI

def item (t : Todo) (editing : Bool) : Html Msg :=
  <li key={t.id} class="todo" class:completed={t.done} class:editing={editing}>
    <input class="toggle" type="checkbox" checked={t.done} onCheck={fun _ => .toggle t.id} />
    <label onDblClick={.edit t.id}>{t.title}</label>
    <button class="destroy" onClick={.remove t.id} disabled={editing} />
  </li>
```

A template is an ordinary Lean term. It is type-checked like the code it stands for, it can appear
wherever an `Html Msg` can, and Lean expressions go inside `{…}`.

Contents: [setup and cost](#setup-and-cost) · [elements](#elements) ·
[attributes](#attributes) · [events](#events) · [children and text](#children-and-text) ·
[fragments](#fragments) · [components](#components) · [namespaces](#namespaces-svg-and-mathml) ·
[where templates can appear](#where-templates-can-appear) · [errors](#errors-and-warnings) ·
[grammar](#grammar) · [limitations](#limitations) · [how it works](#how-it-works)

## Setup and cost

Add `meta import LeanUI.Syntax` to a module that writes templates. Nothing else is needed: the
syntax is active in that module only (modules importing it do not see it, and need their own
`meta import` to write templates).

The import is `meta` because templates cost nothing at run time. `LeanUI.Syntax` and the Lean
compiler it is built on run while your module compiles and are never linked into the program. A
template expands to the constructors you would write by hand (`Html.elem`, `Html.text`,
`Attr.attr`, `Attr.prop`, `Attr.key`, the `Attr.on*` helpers, array literals, `toString`); every
decision that depends on the type of an interpolated value is made by the elaborator, not by a
type class at run time. The example above expands to

```lean
Html.elem Ns.html "li"
  #[Attr.key (toString t.id),
    Attr.attr "class" (("todo" ++ if t.done then " completed" else "") ++ if editing then " editing" else "")]
  #[Html.elem Ns.html "input"
      #[Attr.attr "class" "toggle", Attr.attr "type" "checkbox", Attr.prop "checked" (PropValue.bool t.done),
        Attr.onCheck fun _ => Msg.toggle t.id] #[],
    Html.elem Ns.html "label" #[Attr.onDblClick (Msg.edit t.id)] #[Html.text t.title],
    Html.elem Ns.html "button"
      (let xs := #[Attr.attr "class" "destroy", Attr.onClick (Msg.remove t.id)];
       if editing then xs.push (Attr.attr "disabled" "") else xs) #[]]
```

Measured on `examples/Counter.lean`, which is written as a template:

- the generated C is the same as for the hand-written view except for the numbering of constants;
  its runtime initializer calls `Init` and `LeanUI` only, and the file mentions no `Lean.*` and no
  `LeanUI.Syntax` declaration (checked by `leanui-syntax-tests`);
- the wasm64 build is 1,034,481 bytes (hand-written: 1,034,487), and the browser test
  `tests/browser/counter.mjs` sends the same 7 flushes, 279 commands and 1,250 bytes in Chromium
  and Firefox;
- the native test binary that uses templates links no compiler code (about 1.9 MB; a runtime
  `import Lean` would add about 100 MB).

## Elements

```lean
<div class="row">…</div>      -- element with children
<input type="text" />          -- self-closing
<my-widget size="3" />         -- custom elements (with a dash) are fine
```

- The `<` must touch the tag name: `<div`, never `< div`. This is what keeps `a < b` a comparison.
- A closing tag must repeat its opening tag; a mismatch is reported where it happens:
  `expected </li>, found </div>`.
- Void elements (`area base br col embed hr img input link meta source track wbr`) cannot have
  children: write `<br />`, `<input … />`.
- Tag names are case-sensitive and are emitted as written (SVG needs `linearGradient`,
  `foreignObject`, …). A name starting with an uppercase letter is a [component](#components).
- An unknown lowercase HTML element without a dash gets a warning (`<dvi>` is probably a typo); so
  does an unknown SVG or MathML element inside `<svg>`/`<math>`. Use an explicit prefix
  (`<html:marquee>`) to opt out.

## Attributes

Attribute names may contain letters, digits, `-`, `_` and `:` (`data-id`, `aria-label`,
`xlink:href`, `accept-charset`). Lean keywords are fine as names (`for`, `open`, `default`, `in`).

| Template | Becomes |
|---|---|
| `name="text"` | `Attr.attr "name" "text"` (a Lean string literal, with Lean escapes) |
| `name={e}` | `Attr.attr "name" s`, `s` the string form of `e` (below) |
| `name` | `Attr.attr "name" ""` (a boolean attribute that is present) |
| `disabled={b}` (HTML boolean attributes) | `Attr.attr "disabled" ""` when `b`, nothing otherwise |
| `value={e}`, `checked={b}`, `selected={b}`, `indeterminate={b}`, `muted={b}` | `Attr.prop …` (live form state, below) |
| `.name={e}` | `Attr.prop "name" v` (a DOM property) |
| `.name="text"` / `.name` | `Attr.prop "name" (.str "text")` / `Attr.prop "name" (.bool true)` |
| `name?={o}` | `Attr.attr "name" …` when `o = some v`, nothing for `none` |
| `class="a b"`, `class={e}`, `class:x={b}`, `class:x` | one `class` attribute (below) |
| `style="…"`, `style={e}`, `style:p={v}`, `style:p="v"` | one `style` attribute (below) |
| `key="k"`, `key={k}` | `Attr.key …` (reconciliation key) |
| `onClick={m}` … `on:event={h}` | listeners, see [events](#events) |
| `{...attrs}` | splices an `Array (Attr Msg)`, a `List`, or an `Option` |
| `if={c}` | the element is a child only when `c` (see [conditional children](#conditional-children)) |

Attributes keep their source order (except that the `class` and `style` parts are gathered into
one attribute at the position of the first of them).

**String forms of values.** In `name={e}`, `key={e}`, `style:p={e}`:

| type of `e` | string |
|---|---|
| `String` | `e` itself |
| `Nat`, `Int`, `Float`, `Char`, `UInt*`, … | `toString e` (`7`, `-3`) |
| `Bool` | `"true"` / `"false"` (right for `aria-*`, `draggable`, `spellcheck`, `contenteditable`) |
| any type with a `ToString` instance | `toString e`: this is the extension point for your own types |
| `Option _` | error: use `name?={e}` (or `e.getD …`) |
| `List`, `Array`, `Html` | error |

The conversion is chosen while the template compiles; for a `String` no code is added at all. A
value whose type is not known yet (say `i` in `#[1, 2].map fun i => <li key={i}/>`) waits until
Lean has decided it (`Nat` there).

**Boolean attributes.** For HTML's boolean attributes (`allowfullscreen async autofocus autoplay
controls default defer disabled formnovalidate hidden inert ismap itemscope loop multiple nomodule
novalidate open playsinline readonly required reversed`), `{b}` decides whether the attribute is
present, as HTML requires (`disabled="false"` would disable). Without a value they are present.

**Live form state.** `value={…}`, `checked={…}`, `selected={…}`, `indeterminate={…}` and
`muted={…}` set the DOM *property*. An attribute only sets the initial value, so an input whose
attribute follows the model stops following it once the user edits it. With a string literal
(`value="x"`, `checked`) they stay attributes: the initial state, as in HTML. Server-side
rendering prints properties as attributes, so the page is right before any wasm runs.

**Properties.** `.name={e}` sets any DOM property: a `String` becomes `PropValue.str`, a `Bool`
`PropValue.bool`, a `Float` `PropValue.num`, a `PropValue` is used as is, other `ToString` values
become strings (`.tabIndex={2}`).

**Optional attributes.** `title?={hint?}` adds `title` only for `some`; the payload is converted
like any value (`data-n?={count?}` with `count? : Option Nat`).

**Classes.**

```lean
<li class="todo" class:completed={t.done} class:editing={editing}>
<p class={base} class:active={on}>
<button class:primary class:hover:underline={hover}>   -- bare = always; names may contain `:`
```

All parts become one `class` attribute: the base value, then each toggled class whose condition
holds, separated by spaces. With a literal base this is a direct string append; otherwise it is
`Attr.classes`. `class` may appear once; `class:x` once per name.

**Styles.**

```lean
<div style="display: flex" style:width={s!"{w}px"} style:opacity={o}>
-- style="display: flex; width: 120px; opacity: 1"
```

**Attribute splices.** `<button {...extra} type="button">` splices `extra : Array (Attr Msg)`
(or a `List`, or an `Option (Attr Msg)`, or a single `Attr Msg`) at that position.

**React names.** `className` and `htmlFor` are rejected with a hint: LeanUI uses HTML names
(`class`, `for`).

## Events

The shorthands map to the helpers in `LeanUI.Html`:

| Template | Helper | DOM event | Value |
|---|---|---|---|
| `onClick={m}` | `Attr.onClick` | `click` | `m : Msg` |
| `onDblClick={m}` | `Attr.onDblClick` | `dblclick` | `m : Msg` |
| `onInput={f}` | `Attr.onInput` | `input` | `f : String → Msg` (the input's value) |
| `onChange={f}` | `Attr.onChange` | `change` | `f : String → Msg` (the value) |
| `onCheck={f}` | `Attr.onCheck` | `change` | `f : Bool → Msg` (`checked`) |
| `onKeyDown={f}` | `Attr.onKeyDown` | `keydown` | `f : String → Option Msg` (`KeyboardEvent.key`; `none` ignores) |
| `onSubmit={f}` | `Attr.onSubmit` | `submit` | `f : String → Msg` (the form's `name=value` lines; default prevented) |
| `onBlur={m}` | `Attr.onBlur` | `focusout` | `m : Msg` |

Any other event: `on:<event>={h}` with `h : Handler Msg` says what the browser extracts and how it
decodes:

```lean
<div on:mouseenter={{ decode := fun _ => some .hover }} />
<input on:keyup={{ payload := .key, decode := fun k => if k == "Escape" then some .cancel else none }} />
```

Non-bubbling events (`focus`, `blur`, `mouseenter`, `mouseleave`, `scroll`, `load`, …) work: the
runtime delegates them in the capture phase.

**Modifiers.** `|prevent` (`preventDefault`) and `|stop` (`stopPropagation`) apply to any listener:

```lean
<a href="#" onClick|prevent={.go}>go</a>
<span onClick|stop|prevent={.pick i} on:pointerdown|stop={h} />
```

**Mistakes caught:** an unknown shorthand (`onFoo`, with a suggestion for a near miss such as
`onKeydown` → `onKeyDown`, and the `on:foo` form for everything else), an inline JavaScript
handler (`onclick="…"`, which LeanUI never runs), a string where a message is expected
(`onClick="inc"`), two listeners for the same event (`onChange` with `onCheck`, both `change`), an
unknown modifier.

## Children and text

| Child | Becomes |
|---|---|
| `<tag …>` | that element |
| text | `Html.text "…"` (whitespace rules below) |
| `{e}` with `e : Html Msg` | `e` |
| `{e}` with `e : String` | `Html.text e` |
| `{e}` with a `ToString` value (`Nat`, `Int`, `Float`, your types) | `Html.text (toString e)` |
| `{...e}` | the elements of `e : Array (Html Msg)`, `List (Html Msg)`, `Option (Html Msg)`, `Array String` (each a text) or `Array (Array (Html Msg))` (fragments, flattened) |
| `{}`, `{/- comment -/}` | nothing |

```lean
<ul class="todo-list">
  <li>first</li>
  {...m.todos.map viewTodo}
  {...m.error?.map fun e => <li class="error">{e}</li>}
</ul>
```

A `Bool`, `Option`, `List` or `Array` in `{e}` is an error with a hint (`{...e}` splices; a
`Bool` renders nothing useful). A child whose type is still unknown when the template is checked is
taken to be an `Html Msg`; this is what lets `{.text s}` and `{if c then .text a else .text b}`
work, but it means a bare numeral needs its type: `#[(1 : Nat), 2].map fun i => <li>{i}</li>`.

**Whitespace** follows JSX, with one extra rule:

- whitespace *between tags* never makes a text node: `<ul> <li>a</li> <li>b</li> </ul>` has two
  children;
- whitespace inside a line is kept: `Hello <b>world</b>!` is `"Hello "`, `<b>`, `"!"`, and
  `<b>Hi</b> there` keeps the space before `there`;
- a text that spans lines is trimmed where it touches a line break, blank lines vanish, and the
  remaining lines are joined with single spaces:

  ```lean
  <p>
    First line
      second   line
  </p>
  -- <p>First line second   line</p>
  ```
- an explicit space between elements is `{" "}`.

**Text characters.** Text may contain anything except `{`, `<`, `>` and `}`: quotes, apostrophes,
`$`, `#`, `@`, `--` in the middle of a line. Write the four as character references or as strings:
`&lbrace;` `&lt;` `&gt;` `&rbrace;`, or `{"<"}`.

**Character references** are decoded: `&amp; &lt; &gt; &quot; &apos; &nbsp; &copy; &mdash;
&hellip; &rarr; &times; &alpha;` and about 170 more, and numeric ones `&#169;` `&#x1F600;`. An
unknown name is kept as written with a warning; a bare `&` is just text (`Tom & Jerry`). They are
decoded after the whitespace rules, so `&#32;` keeps a space at the end of a line and `&nbsp;` is
never trimmed.

**Strings are text, never markup:** `{"<b>x</b>"}` renders the characters `<b>x</b>`.

**Comments.** A Lean comment may stand where a child starts (`-- …` on its own line, or
`/- … -/`); inside a text run `--` is text. `{/- … -/}` works anywhere.

### Conditional children

`if={cond}` on a child element (or component) includes it only when `cond` holds:

```lean
<footer if={!m.todos.isEmpty} class="footer">
  <span class="todo-count"><strong>{left}</strong> items left</span>
  <button if={left < m.todos.size} onClick={.clear}>Clear completed</button>
</footer>
```

For an either/or, use `{if c then <a/> else <b/>}`; for an optional child, `{...o.map view}`.

## Fragments

`<>…</>` is an `Array (Html Msg)`. As a child it is spliced in place.

```lean
def pair (k v : String) : Array (Html Msg) := <><dt>{k}</dt><dd>{v}</dd></>
<dl><><dt>a</dt><dd>1</dd></></dl>                                  -- two children of <dl>
<dl>{...entries.map fun (k, v) => <><dt>{k}</dt><dd>{v}</dd></>}</dl>  -- an array of fragments is flattened
```

## Components

A tag that starts with an uppercase letter calls a function. Attributes become named arguments,
and the children become the `children` argument:

```lean
def Card (title : String) (children : Array (Html Msg) := #[]) (featured := false) : Html Msg :=
  <section class="card" class:featured={featured}>
    <h2>{title}</h2>
    {...children}
  </section>

<Card title="Hello" featured>      -- Card (title := "Hello") (featured := true) (children := #[…])
  <p>body</p>
</Card>
<Card title={t} />                 -- Card (title := t)
<Ui.Button label="Save" onPress={.save} />   -- qualified names
```

- `"text"` passes a string, `{e}` passes `e`, a bare name passes `true`;
- `key={k}` puts the key on the element the component returns (so components can be keyed list
  items);
- `if={c}` works as for elements;
- a component whose result is an `Array (Html Msg)` (a fragment) is spliced where it is used;
- arguments must be valid Lean identifiers; attribute splices are not supported on components.

A component with its own message type is embedded with `Html.map`:

```lean
<div>{(<Toggle on={m.on} /> : Html Child.Msg).map Msg.child}</div>
```

`<Div>` is rejected with a hint (the name would otherwise resolve to the `Div` class), and so is
a name that is not a function returning `Html`.

## Namespaces: SVG and MathML

Elements inside `<svg>` are created with the SVG namespace and elements inside `<math>` with
MathML's, automatically. `<foreignObject>` switches its children back to HTML.

```lean
<svg viewBox="0 0 100 100">
  <circle cx="50" cy="50" r={r} />
  <foreignObject x="0" y="0" width="100" height="20"><p>HTML again</p></foreignObject>
</svg>
<p>Euler: <math><mi>e</mi><mo>=</mo><mn>2.718</mn></math></p>
```

A template inside `{…}` starts fresh, but SVG-only and MathML-only tags (`circle`, `path`, `g`,
`rect`, `text`, `mi`, `mrow`, …) always get their namespace, so
`<svg>{...pts.map fun p => <circle cx={p.x} cy={p.y} r="1" />}</svg>` is right. The names shared
by HTML and SVG (`a`, `title`, `script`, `style`) follow the lexical context; force one with a
prefix: `<svg:a href="#x">`, `<html:title>`, `<math:mi>`.

## Where templates can appear

Anywhere a term can, including as a function argument (`pure <div/>`, `Html.map f <Child/>`,
`xs.push <li/>`), as `fun` and `match` bodies, in `if` branches and array literals.

**After a `let`.** A template at the start of a line right after `let x := v` is read by Lean as
`v < …` (`<` is also less-than, and a binary operator continues an expression across lines). End
the `let` with `;`, or parenthesize the template, or use `where`:

```lean
def view (m : Model) : Html Msg :=
  let left := count m;
  <span>{left} left</span>
```

Without the `;` the error says exactly this.

**Ordinary code is unaffected:** `a < b`, `a<b`, `a <b then …`, `(· < 3)` all parse as before
(a template as an argument is recognized only when a complete opening tag follows the `<`).

## Errors and warnings

Parse errors (reported at the offending spot):

| Input | Message |
|---|---|
| `<ul><li>a</div></ul>` | `expected </li>, found </div>` |
| `<div><input type="text"></div>` | `expected </input>, found </div>; <input> is a void element: write <input … />` |
| `<div>x</>` | `expected </div>, found </>` |
| `<p>a > b</p>` | `'>' cannot appear in JSX text; write &gt; or {">"}` |
| text at column 0 inside a template | `template text starts in column 0 here; indent it (or, if this is Lean code, an element above is missing its closing tag)` |
| `let n := 1` + newline + `<p>…</p>` | `this template starts a line, but < is also less-than, …; end that line with ; or put the template in parentheses` |

Elaboration errors and warnings (selection; `tests/Syntax.lean` checks the exact text of each):
unknown or misspelled event shorthands, inline JavaScript handlers, wrong value forms (`onClick="x"`,
`class:done="yes"`, `key` without a value, `title?="x"`), duplicates (attribute, `class`, `key`,
two listeners for one event), `Option` values without `?`, collections where one child is expected,
`Bool` children, values without `ToString`, void elements with children, `<Div>`, non-components,
`if` outside a child or without a condition, React attribute names, unknown elements and unknown
character references (warnings).

## Grammar

```
element   ::= '<' NAME attr* '/>'
            | '<' NAME attr* '>' child* '</' NAME '>'
            | '<' '>' child* '</' '>'                       -- fragment
attr      ::= NAME '=' STRING | NAME '=' '{' term '}' | NAME | '{...' term '}'
child     ::= element | TEXT | '{' term '}' | '{...' term '}' | '{' '}'
NAME      ::= [A-Za-z_.] [A-Za-z0-9_.:|?-]*                 -- `.prop`, `on:x`, `x?`, `onClick|prevent`
TEXT      ::= [^{}<>]+
```

`<` must be followed immediately by the name (or `>`), with no space.

## Limitations

- After `let x := v`, a template on the next line needs `;` (see
  [above](#where-templates-can-appear)); the error says so.
- A Lean comment can only stand where a child starts; text cannot begin with `--` or `/-` (write
  `{"--"}`), and template text may not start in column 0.
- Inside `{…}`, the tags shared by HTML and SVG (`a`, `title`, `script`, `style`) default to HTML;
  use `svg:a`.
- A child whose type is unknown until after the template (bare numerals) is taken to be a view.
- As a function argument, `<` followed by a complete opening tag is a template: `f <b c >` is
  never ordinary Lean (`<` and `>` do not chain), so no comparison is affected.
- Templates do not change what the runtime does: a `<select value={v}>` sets `select.value`
  before its options exist, so mark the chosen `<option selected={…}>` instead; `<script>` and
  `<style>` content is escaped like any text by server-side rendering.

## How it works

`LeanUI/Syntax.lean` is about a thousand lines of `meta` code:

- **Tokens.** Names and text runs are custom parsers, not Lean tokens, so names can contain `-`
  and `:` and text can contain anything but `{<>}` (`'tis`, `"`, `--`). Lean's tokenizer gives
  the whitespace after a token to that token, so a text run recovers the whitespace before it from
  the source; without this `<b>x</b> y` would lose its space. A child is dispatched on its first
  character, never through the tokenizer. The `>` that ends a tag is read as one character, so
  `<mo>=</mo>` is not `<mo` `>=`.
- **Closing tags** are checked in the parser against the opening name on the syntax stack, so a
  mismatch fails where it is, not as "unexpected end of input" later.
- **Two term forms.** In term position a template is a leading term with full error messages. As
  a function argument (where `<` is also less-than) it applies only when a complete opening tag
  follows (an `atomic(lookahead …)` guard), so ordinary comparisons are untouched. A third,
  never-succeeding trailing parser recognises the "template after a `let`" case and reports it.
- **Elaboration.** The element tree is turned into a term of constructors and array literals:
  runs of fixed children or attributes become one array literal; `{...}` splices, `if={}` and
  `name?={}` push onto the array built so far (which is unique at that point, so the push is in
  place). Values whose treatment depends on their type go through small elaborators
  (`leanui_jsx_child%`, `leanui_jsx_str%`, `leanui_jsx_prop%`, `leanui_jsx_kids%`,
  `leanui_jsx_attrs%`) that elaborate the value once, look at its type and produce the conversion
  (`Html.text`, `toString`, `PropValue.bool`, `List.toArray`, `Array.flatten`, …). When the type
  is not known yet, only the decision is postponed (it is dispatched again on the elaborated value,
  as a hole), so the user's term is never elaborated twice or out of its context, and its info
  nodes are kept (`mkSaveInfoAnnotation`) for hovers and the unused-variables linter.

The tests (`lake build leanui-syntax-tests && .lake/build/bin/leanui-syntax-tests`) compare every
template with the same view built by hand (structure, attribute order, keys, listener payloads and
flags, namespaces, `Html.render`, `canonHtml`), decode handlers, run a template-built app through
the DOM model, check the counter example against its hand-written original, check the error
messages at compile time, and check the zero-cost property on the generated C and on the binary.
