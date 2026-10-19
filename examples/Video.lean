module
public import LeanUI
public import Editor.Adjust
public import Editor.Filter
/-!
# Video lab

The photo editor's Lean filters applied to every frame of a video. The browser plays the file in
a `<video>` (`Cmd.fileUrl` gives it an object URL) and decodes it; on each animation frame the lab
asks for the frame the video shows (`Cmd.grabFrame`: WebCodecs' `VideoFrame`, copied as RGBA into
wasm memory), runs the chosen filter on it in Lean and draws the result on a canvas
(`Cmd.drawBitmap`). Then it waits for the next animation frame and asks again, so a slow filter
drops source frames rather than queueing them: the frame rate shown is the rate of frames
filtered and drawn, the honest number. A frame the video already showed (paused, or a display
faster than the video) is not filtered again; after half a second of those the lab polls ten
times a second instead of every animation frame.

`tests/Editor.lean` drives it in the DOM model; `tests/browser/video.mjs` plays generated videos
in Chromium and Firefox and measures the frame rates (`docs/BENCHMARKS.md`).
-/
public section
open LeanUI Attr Editor

namespace Video

inductive Filter where
  | none | vivid | mono | invert | blur | sharpen | edges | emboss
  deriving BEq, Inhabited, Repr

def Filter.all : Array Filter := #[.none, .vivid, .mono, .invert, .blur, .sharpen, .edges, .emboss]

def Filter.key : Filter → String
  | .none => "none" | .vivid => "vivid" | .mono => "mono" | .invert => "invert" | .blur => "blur"
  | .sharpen => "sharpen" | .edges => "edges" | .emboss => "emboss"

def Filter.label : Filter → String
  | .none => "None (copy)" | .vivid => "Vivid (contrast, saturation)" | .mono => "Black and white"
  | .invert => "Invert" | .blur => "Blur (radius 4)" | .sharpen => "Sharpen (100 %, radius 2)"
  | .edges => "Edge detect" | .emboss => "Emboss"

def Filter.ofKey (s : String) : Filter := (Filter.all.find? (·.key == s)).getD .none

/-- `img` filtered: in place where the operation allows it (the adjustments), otherwise into a new
image (the blur and the unsharp mask use one temporary image each). -/
def Filter.run (f : Filter) (img : Image) : Image :=
  match f with
  | .none => img
  | .vivid => Adjust.apply { contrast := 25, saturation := 40 } img
  | .mono => Adjust.apply { grayscale := true, contrast := 15 } img
  | .invert => Adjust.apply { invert := true } img
  | .blur => Editor.blur img 4
  | .sharpen => Editor.sharpen img 1 2
  | .edges => Editor.edgeDetect img
  | .emboss => Editor.emboss img

/-- Frames that showed no new picture before the lab polls slowly (half a second at 60 Hz). -/
def idleAfter : Nat := 30

structure Model where
  name : String := ""
  url : String := ""
  filter : Filter := .none
  /-- The animation-frame loop runs (one at a time). -/
  looping : Bool := false
  width : Nat := 0
  height : Nat := 0
  /-- The video time of the last filtered frame, in milliseconds. -/
  lastTime : Option Nat := none
  /-- Frames filtered and drawn. -/
  frames : Nat := 0
  /-- Grabs in a row that showed no new frame. -/
  repeats : Nat := 0
  /-- The current one-second window: its start (animation-frame time) and frames drawn in it. -/
  windowStart : Float := 0
  windowFrames : Nat := 0
  /-- Frames per second over the last complete window. -/
  fps : Float := 0
  status : String := "Choose a video file."

inductive Msg where
  | picked (fs : Array FileInfo)
  | opened (name url : String)
  | setFilter (f : Filter)
  | tick (ms : Float)
  | poll
  | grabbed (r : Except String (Bitmap × Nat))

def grab : Cmd Msg := .grabFrame "#vid-src" .grabbed

/-- Wait for the next animation frame, or poll slowly while the video shows nothing new. -/
def next (m : Model) : Cmd Msg := if m.repeats ≥ idleAfter then .after 100 .poll else .nextFrame .tick

def update (msg : Msg) (m : Model) : Model × Cmd Msg :=
  match msg with
  | .picked fs => match fs[0]? with
    | some f => ({ m with status := s!"Opening {f.name}…" }, .fileUrl f.id (.opened f.name))
    | none => (m, .none)
  | .opened name url =>
    if url.isEmpty then ({ m with status := s!"{name}: the file is gone." }, .none) else
    let m := { m with name, url, lastTime := none, frames := 0, repeats := 0, windowStart := 0, windowFrames := 0,
                      fps := 0, status := s!"Playing {name}." }
    if m.looping then (m, .none) else ({ m with looping := true }, .nextFrame .tick)
  | .setFilter f => ({ m with filter := f, lastTime := none, repeats := 0 }, .none)
  | .tick ms =>
    let m := if m.windowStart == 0 then { m with windowStart := ms, windowFrames := 0 }
      else if ms - m.windowStart ≥ 1000 then
        { m with fps := m.windowFrames.toFloat * 1000 / (ms - m.windowStart), windowStart := ms, windowFrames := 0 }
      else m
    (m, grab)
  | .poll => ({ m with windowStart := 0, windowFrames := 0 }, grab)
  | .grabbed (.error e) =>
    let m := { m with repeats := m.repeats + 1, status := e }
    (m, next m)
  | .grabbed (.ok (b, t)) =>
    if m.lastTime == some t then
      let m := { m with repeats := m.repeats + 1, fps := if m.repeats + 1 ≥ idleAfter then 0 else m.fps }
      (m, next m)
    else
      let img := m.filter.run ⟨b.width, b.height, b.data⟩
      let m := { m with width := img.width, height := img.height, lastTime := some t, frames := m.frames + 1,
                        repeats := 0, windowFrames := m.windowFrames + 1, status := s!"Playing {m.name}." }
      (m, .batch #[.drawBitmap "#vid-out" { width := img.width, height := img.height, data := img.data }, next m])

def fmt1 (x : Float) : String :=
  let t := (x * 10).round.toUInt64.toNat
  s!"{t / 10}.{t % 10}"

def view (m : Model) : Html Msg :=
  el "div" #[cls "video"] #[
    el "header" #[] #[
      el "h1" #[] #[text "LeanUI Video ", el "small" #[] #[text "the photo editor's filters on every frame"]],
      el "a" #[.attr "href" "../"] #[text "← Photo editor"]],
    el "p" #[cls "intro"] #[text "Your browser decodes the video; each frame it shows is copied out \
      (WebCodecs' VideoFrame), run through a filter written in Lean and compiled to WebAssembly, \
      and drawn on the right. A filter too slow for the video's frame rate drops frames: the \
      count below is frames filtered and drawn per second. Nothing is uploaded."],
    el "div" #[cls "controls"] #[
      el "label" #[cls "file"] #[text "Open a video…",
        el "input" #[Attr.id "vid-file", .attr "type" "file", .attr "accept" "video/*", onFiles .picked] #[]],
      el "label" #[] #[text "Filter ",
        el "select" #[Attr.id "vid-filter", .prop "value" (.str m.filter.key), onChange fun s => .setFilter (Filter.ofKey s)]
          (Filter.all.map fun f => el "option" #[.attr "value" f.key] #[text f.label])],
      el "span" #[cls "stats"] #[
        el "output" #[Attr.id "vid-fps"] #[text (fmt1 m.fps)], text " frames/s · ",
        el "output" #[Attr.id "vid-frames"] #[text (toString m.frames)], text " frames · ",
        el "output" #[Attr.id "vid-size"] #[text (if m.width == 0 then "–" else s!"{m.width}×{m.height}")]],
      el "span" #[Attr.id "vid-status", cls "status"] #[text m.status]],
    el "div" #[cls "panes"] #[
      el "figure" #[] #[
        el "video" (#[Attr.id "vid-src", .attr "controls" "", .attr "muted" "", .prop "muted" (.bool true),
          .attr "autoplay" "", .attr "loop" "", .attr "playsinline" ""] ++
          (if m.url.isEmpty then #[] else #[.attr "src" m.url])) #[],
        el "figcaption" #[] #[text "Original"]],
      el "figure" #[] #[
        el "canvas" #[Attr.id "vid-out", .attr "width" (toString m.width), .attr "height" (toString m.height)] #[],
        el "figcaption" #[] #[text s!"{m.filter.label}, in Lean"]]]]

def program : Program Model Msg where
  init _ := ({}, .none)
  update := update
  view := view
  subscriptions _ := .none

end Video
