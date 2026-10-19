# The LeanUI protocol (version 1)

Lean never touches the DOM. Every update produces one **command buffer**; a JavaScript runtime
(`runtime/leanui.js`) applies it. The same bytes are produced in the browser (wasm64) and on a
native server, and `LeanUI/Testing/Dom.lean` is an executable reference model of the semantics
below. This document is normative for both.

## 1. Framing

A buffer is two byte arrays:

- **words**: little-endian unsigned 32-bit integers, a sequence of *commands*. Each command is an
  opcode word followed by its operand words (section 3): a fixed number, except for `TEMPLATE`
  and `CLONE`, whose operands end with a count and that many node handles.
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
| 20 | TEMPLATE | tid, count, n1..ncount | keep a copy of the subtree rooted at `n1`, whose nodes are `n1..ncount` in pre-order, as template `tid` (section 7) |
| 21 | CLONE | tid, count, n1..ncount | `nodes[n1..ncount]` = a copy of template `tid`, in pre-order (section 7) |
| 32 | FETCH | cb, s method, s url, s body, s headers | `fetch`; headers are `name: value` lines; reply `cb` with ok = 2xx and payload `"<status>\n<body>"` (status 0 on network error) |
| 33 | TIMEOUT | cb, ms | reply `cb` (ok, `""`) after `ms` |
| 34 | INTERVAL_SET | sub, ms | reply `sub` (ok, `""`) every `ms` until cleared |
| 35 | SUB_CLEAR | sub | stop subscription `sub` (interval, URL or keys) |
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
| 48 | PUT_IMAGE | s selector, blob, w, h, x, y, dw, dh | at the end of this buffer, `putImageData` blob (`w`×`h` RGBA pixels) at (0, 0) of the first `<canvas>` matching `selector`, copying only the rectangle (`x`, `y`, `dw`, `dh`) (section 8) |
| 49 | FILE_READ | cb, file | reply `cb` with the bytes of file `file` (section 8) |
| 50 | IMAGE_DECODE | cb, file | reply `cb` with file `file` decoded to RGBA pixels, payload `"<width> <height>"` (section 8) |
| 51 | DOWNLOAD | s name, s type, blob | offer blob's bytes as a download named `name` of media type `type` |
| 52 | KEYS_LISTEN | sub | reply `sub` for every `keydown` on the document except in text fields (`textarea`, `select`, editable content, and `input`s other than checkboxes, radio buttons, ranges, buttons, file and colour pickers), payload `Ctrl+`, `Alt+`, `Shift+`, `Meta+` prefixes (in that order) then `KeyboardEvent.key`; presses of a modifier key alone are not reported, and no default is prevented |
| 53 | FRAME_GRAB | cb, s selector | reply `cb` with the frame the first `<video>` matching `selector` shows, as RGBA pixels (a WebCodecs `VideoFrame` copied as RGBA, or drawn on a 2D canvas where that conversion is not available), payload `"<width> <height> <timeMs>"` with the frame's timestamp (`VideoFrame.timestamp`; `currentTime` without WebCodecs); `ok` = 0 when there is no frame yet (section 8) |
| 54 | FILE_URL | cb, file | reply `cb` with an object URL for file `file` (`ok` = 0 and an empty payload for an unknown id) |

Unknown opcodes are fatal (the receiver stops and reports). New commands get new numbers; numbers
are never reused. Opcode 22 is unused: an `INSERT_MANY` (insert a run of children with one
DocumentFragment) was measured and left out, since it made creating rows slower in Chromium and
no faster in Firefox.

## 4. Events

Listeners are **delegated**: the runtime registers one real listener per event type on the
container (capture phase for events that do not bubble: `focus`, `blur`, `mouseenter`,
`mouseleave`, `load`, `error`, `scroll`, `pointerenter`, `pointerleave`). An event that bubbles
walks from its target up to the container; every node with a listener for its type reports, in
order, unless a listener's flags stop propagation. An event that does not bubble reports only the
listener of its target, as it would without delegation.

- **payload** says what the browser extracts from the node that registered the listener:
  0 nothing, 1 `value`, 2 `checked` (`"true"`/`"false"`), 3 `KeyboardEvent.key`,
  4 the fields of the node's form (the node itself if it is a `form`, else the form a control
  belongs to) as `name=value` lines, a file field as its file name; empty without a form;
  5 the event's files (`dataTransfer.files` if it has any, else the node's `files`), one line
  per file, `id\tsize\ttype\tname` (tabs and line breaks in the name become spaces): the
  runtime keeps each file under a new id (≥ 1; the 64 most recent are kept) for `FILE_READ`
  and `IMAGE_DECODE`;
  6 a pointer: `x y width height buttons modifiers pointerId pressure deltaX deltaY clientX
  clientY`, space separated, where `x`, `y` are the pointer's position relative to the node's
  bounding box and `width`, `height` that box's size (CSS pixels, after transforms),
  `modifiers` is 1 shift + 2 ctrl + 4 alt + 8 meta, `pointerId` 0 for events that have none,
  the deltas are a wheel event's in CSS pixels (lines count 16, pages the box's height; 0 for
  other events), and `clientX`, `clientY` the position in the viewport; numbers have at most two
  decimals and no exponent.
- **flags**: bit 0 `preventDefault`, bit 1 `stopPropagation`, bit 2 capture the pointer: on a
  `pointerdown`, `setPointerCapture` on the node, so the pointer's later events target it
  until it is released. Listeners for `wheel`, `touchstart` and `touchmove` are registered as
  not passive, so `preventDefault` works for them.

The runtime reports `event(slot, payload)` to Lean. Reports are serialised: an event that fires
while a buffer is being applied (for example `focusin` caused by a `FOCUS`) is queued and
delivered after the current call into Lean returns. In the wasm host a payload crosses as UTF-8
bytes with an explicit length, so it may contain any character, U+0000 included.

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

## 7. Template cloning

Most created DOM comes from lists whose rows share one shape, so Lean creates repeated subtrees
by copying a template (one `cloneNode(true)`) instead of one command per node.

- `TEMPLATE tid count n1..ncount` follows, in the same buffer, the commands that built a
  *prototype*: the subtree rooted at `n1`, detached, with its elements and texts and each
  element's attributes up to its first property (an `input` with none), and no property and no
  listener yet. `n1..ncount` are exactly the nodes of that subtree in pre-order (elements and
  texts); the receiver keeps a copy taken now as template `tid` and rejects a `TEMPLATE` whose
  subtree has another number of nodes. The commands after it finish the prototype as they finish
  a clone (below). Template ids are ≥ 1, defined once per session; there are at most 256.
- `CLONE tid count n1..ncount` makes `n1..ncount` (handles that are not live) the nodes of a new
  copy of template `tid`, in pre-order; `count` is the template's size. The copy is detached and
  carries the template's namespaces, tags, attributes and texts, and no listeners. The commands
  that follow make it what a mount of the view builds: `SET_TEXT` for the texts that differ,
  then element by element (pre-order) and in view order: `SET_ATTR` for the attributes before
  the first property whose value differs from the template's, and from the first property on
  everything a mount sends (`SET_PROP_*`, `SET_ATTR`), and every listener (`SET_LISTENER`). An
  `input` gets all of its attributes this way.

So every element of a copy reaches its first property in the state a fresh mount has there (the
same attributes in the same order, no property set, no dirty value or checkedness), and from then
on receives the same commands: a property that reflects onto an attribute (`className`, `id`,
`hidden`, `value`), or the runtime's skip of a string property that already has its value, sees
what it sees in a mount. `tests/browser/templates.mjs` checks this in Chromium and Firefox on
engine-generated buffers, comparing every node with and without templates: attributes in order,
`value`/`checked`/`selected`, listener slots, scripts run, and dirty flags.

Lean templates element subtrees of 4 to 64 nodes that contain no lazy node and no property on an
element with children (mount sets properties before the children exist; a copy has them
already). A subtree's shape is its namespaces and tags, each element's attribute names (in
order), property names (in order) and where its first property comes, and its structure;
listeners, keys, texts and most attribute values are not part of it. The values *are* part of
the shape on elements where setting an attribute does more than hold a value or where the order
of a history matters (`select`, `textarea`, `option`, media and resource elements such as `img`,
`script`, `iframe`, `link`; SVG `image`, `use`, `script`; custom elements; any element that
repeats an attribute name), so a copy never re-sets an attribute there. The second subtree of a
shape becomes the template, later ones are clones; shapes are compared exactly, never by hash
alone. Candidates are the children a patch mounts and, in a new subtree, children with a
neighbouring sibling of their kind: the same tag, or both lazy (list rows; for a lazy child, the
subtree it renders). `LeanUI/Testing/Dom.lean` models both commands (the model's copy carries
attributes and texts, not properties).

What a copy can still do differently from a mount: a custom element's callbacks run in another
order (its attributes arrive while it is copied, before its children), and a property on a leaf
is set while the leaf is already inside its (detached) parent, where a mount sets it before the
leaf has a parent; no difference has been observed for radio groups and selects.

## 8. Bytes: pixels and files

Some commands carry bytes rather than strings. A buffer may have **blobs**: byte arrays its
commands refer to by index (a *blob* operand, one word). In the wasm host the blobs stay where
they are in wasm memory: before a flush, the module reports each blob's address and length
(`LeanUI.__blob(index, address, length)`), and the runtime reads them as views of that memory
while it applies the buffer. They are valid until the buffer has been applied, so a command that
needs them later copies them (`DOWNLOAD`: the `Blob` constructor copies), and `PUT_IMAGE` runs at
the end of the buffer, after its DOM commands (so it may draw on a canvas the same buffer
created), but before control returns to Lean. `PUT_IMAGE` wraps the view in an `ImageData`
(no copy) and `putImageData` copies the dirty rectangle into the canvas; the blob must hold
exactly `4 × w × h` bytes (RGBA, straight alpha, rows top to bottom). A `PUT_IMAGE` that cannot
be done (another size, no such canvas or no 2D context) is logged and skipped. The canvas keeps its own
size (`width` and `height` attributes, from the view).

Results with bytes (`FILE_READ`, `IMAGE_DECODE`) come back through a second callback,
`callbackBytes(cb, ok, payload, bytes)`. In the wasm host the runtime asks the module for a Lean
`ByteArray` of the right size (`leanui_bytes_alloc`, `leanui_bytes_data`), writes the bytes into
it and passes it to `leanui_callback_bytes`, which hands it to Lean: one copy, from the browser's
buffer into wasm memory, and none in Lean. A failure has `ok` = 0, the reason as the payload and
no bytes; that includes a result too large for the module's memory (`leanui_bytes_alloc`
returns null rather than stopping the program). `IMAGE_DECODE` decodes with `createImageBitmap` (no premultiplication, no colour space
conversion) and reads the pixels back from a 2D canvas, so it decodes whatever the browser
decodes (PNG, JPEG, WebP, GIF's first frame, …); semi-transparent pixels may lose precision in
the canvas's premultiplied storage.

The server-driven host carries no bytes: its buffers have no blobs (`PUT_IMAGE` and `DOWNLOAD`
are skipped, with one console warning), and a result with bytes arrives as an ordinary callback
with `ok` = 0 and the payload `bytes need the in-page (wasm) host`.
