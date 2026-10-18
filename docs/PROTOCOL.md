# The LeanUI protocol (version 1)

Lean never touches the DOM. Every update produces one **command buffer**; a JavaScript runtime
(`runtime/leanui.js`) applies it. The same bytes are produced in the browser (wasm64) and on a
native server, and `LeanUI/Testing/Dom.lean` is an executable reference model of the semantics
below. This document is normative for both.

## 1. Framing

A buffer is two byte arrays:

- **words**: little-endian unsigned 32-bit integers, a sequence of *commands*. Each command is an
  opcode word followed by a fixed number of operand words (section 3).
- **strings**: UTF-8 text. A string operand is two words, `(offset, length)`, counted in **UTF-16
  code units** from the start of the decoded string area. The receiver decodes the whole area once
  (`TextDecoder`) and slices it (`substr(offset, length)`), so a buffer costs one decode no matter
  how many strings it carries. Writers compute UTF-16 lengths as 1 unit per code point below
  U+10000 and 2 above.

In the browser, the wasm module passes both arrays as views into its memory (no copy). Over HTTP
(server-driven mode) they travel as `[u32 wordsBytes][words][strings]` (`Buf.encode`).

## 2. Identifiers

- **Node handles** (`u32`, ≥ 1) name DOM nodes. Lean allocates them (with reuse after `FREE`), so
  commands never need answers. Handle 0 is never used.
- **Names** (`u32`, ≥ 1) stand for tag, attribute, property and event names. A name is defined by
  `INTERN id str` *before* the first command that uses it; definitions last for the session.
- **Slots** (`u32`, ≥ 1) identify event handlers; **callbacks** (`u32`, ≥ 1) identify effect
  continuations and subscriptions. Both are allocated by Lean and reused.

## 3. Commands

`n` = node handle, `nm` = name id, `s` = string (2 words), `cb`/`sub` = callback id.

| Op | Name | Operands | Browser semantics |
|---|---|---|---|
| 1 | CREATE_ELEMENT | n, ns, nm | `nodes[n] = createElement(nm)`; ns 1 = SVG, 2 = MathML (`createElementNS`) |
| 2 | CREATE_TEXT | n, s | `nodes[n] = createTextNode(s)` |
| 3 | SET_ATTR | n, nm, s | `setAttribute(nm, s)` |
| 4 | REMOVE_ATTR | n, nm | `removeAttribute(nm)` |
| 5 | SET_PROP_STR | n, nm, s | `el[nm] = s` (skipped when equal, so a focused input keeps its caret) |
| 6 | SET_PROP_BOOL | n, nm, b | `el[nm] = (b == 1)` |
| 7 | SET_PROP_NUM | n, nm, s | `el[nm] = Number(s)` |
| 8 | REMOVE_PROP | n, nm | `el[nm] = false` if the property is boolean, else `""` |
| 9 | SET_TEXT | n, s | `nodeValue = s` |
| 10 | APPEND_CHILD | parent, child | `parent.appendChild(child)` (moves it if attached) |
| 11 | INSERT_BEFORE | parent, child, ref | `parent.insertBefore(child, ref)`; `ref` is a child of `parent` |
| 12 | REMOVE | n | detach `n` from its parent |
| 13 | REPLACE | old, new | `old.replaceWith(new)` |
| 14 | FREE | n | forget handle `n`; the node is detached or inside a detached subtree |
| 15 | SET_LISTENER | n, nm, slot, payload, flags | `n` now reports event `nm` as `slot` (section 4) |
| 16 | REMOVE_LISTENER | n, nm | `n` no longer reports `nm` |
| 17 | INTERN | id, s | define name `id` |
| 18 | MOUNT | s, n | `querySelector(s).replaceChildren(n)`; `s` becomes the app's container |
| 19 | HYDRATE | s, first, count | adopt the container's existing nodes (section 5) |
| 32 | FETCH | cb, s method, s url, s body, s headers | `fetch`; headers are `name: value` lines; reply `cb` with ok = 2xx and payload `"<status>\n<body>"` (status 0 on network error) |
| 33 | TIMEOUT | cb, ms | reply `cb` (ok, `""`) after `ms` |
| 34 | INTERVAL_SET | sub, ms | reply `sub` (ok, `""`) every `ms` until cleared |
| 35 | SUB_CLEAR | sub | stop subscription `sub` (interval or URL) |
| 36 | STORAGE_SET | s key, s value | `localStorage.setItem` |
| 37 | STORAGE_GET | cb, s key | reply `cb` with ok = present, payload = value |
| 38 | STORAGE_REMOVE | s key | `localStorage.removeItem` |
| 39 | URL_PUSH | s url | `history.pushState` |
| 40 | URL_REPLACE | s url | `history.replaceState` |
| 41 | URL_LISTEN | sub | reply `sub` with the new path+query+hash after `popstate` and after a primary-button click on `a[data-link]` (which is then handled without a reload) |
| 42 | FOCUS | s selector | after this buffer is applied, focus the first match |
| 43 | LOG | s | `console.log` |
| 44 | TITLE | s | `document.title = s` |
| 45 | FRAME | cb | reply `cb` on the next animation frame, payload = rounded timestamp (ms) |
| 46 | BLUR | s selector | after this buffer, blur the first match |
| 47 | SCROLL_INTO_VIEW | s selector | after this buffer, scroll the first match into view |

Unknown opcodes are fatal (the receiver stops and reports). New commands get new numbers; numbers
are never reused.

## 4. Events

Listeners are **delegated**: the runtime registers one real listener per event type on the
container (capture phase for events that do not bubble: `focus`, `blur`, `mouseenter`,
`mouseleave`, `load`, `error`, `scroll`, `pointerenter`, `pointerleave`). An event walks from its
target up to the container; every node with a listener for its type reports, in order, unless a
listener's flags stop propagation.

- **payload** says what the browser extracts from the node that registered the listener:
  0 nothing, 1 `value`, 2 `checked` (`"true"`/`"false"`), 3 `KeyboardEvent.key`,
  4 the form's fields as `name=value` lines.
- **flags**: bit 0 `preventDefault`, bit 1 `stopPropagation`.

The runtime reports `event(slot, payload)` to Lean. Reports are serialised: an event that fires
while a buffer is being applied (for example `focusin` caused by a `FOCUS`) is queued and
delivered after the current call into Lean returns.

## 5. Mount and hydration

A buffer that creates the initial view ends with `MOUNT`; listener commands may precede it, so the
runtime remembers wanted event types and attaches them once the container exists.

`HYDRATE s first count` adopts server-rendered HTML instead: the runtime walks the container in
**pre-order** and assigns handles `first, first+1, …` to element and text nodes, skipping comments
except two markers written by `LeanUI.Render`: `<!--|-->` separates adjacent text nodes (skipped)
and `<!--t-->` stands for an empty text node (replaced by one, which takes the next handle). The
walk must find exactly `count` nodes; otherwise the server and client views differ and the
runtime reports an error. Lean's `mount` in hydration mode allocates handles in the same
pre-order, emits no creation commands, and emits listeners and properties (which HTML cannot
carry). Attributes are already in the HTML.

## 6. Server-driven mode

The page calls `LeanUI.connect({ endpoint, session })`. Every report is a `POST
<endpoint>/<session>` with a `text/plain` body:

- `h` — hydrate: the response adopts the server-rendered page (section 5);
- `e\n<slot>\n<payload>` — an event;
- `c\n<cb>\n<0|1>\n<payload>` — an effect result or subscription tick (effects always run in the
  browser).

The response body is an encoded buffer (possibly empty). Requests are sent one at a time, in
order.
