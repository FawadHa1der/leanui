module
/-!
# Media types

The `Content-Type` of a static file, from its extension. Two entries matter for LeanUI itself:
`application/wasm` (browsers compile a module while it downloads only with this type; the
Emscripten loader falls back to a slower path, with a console warning, without it) and
`text/javascript` for the runtime and the app's loader.
-/
public section
namespace LeanUI.Server.Mime

/-- Extension (lower case, without the dot) → media type. Text types carry `charset=utf-8`. -/
def table : List (String × String) := [
  ("html", "text/html; charset=utf-8"), ("htm", "text/html; charset=utf-8"),
  ("js", "text/javascript; charset=utf-8"), ("mjs", "text/javascript; charset=utf-8"),
  ("cjs", "text/javascript; charset=utf-8"),
  ("css", "text/css; charset=utf-8"),
  ("json", "application/json"), ("map", "application/json"), ("webmanifest", "application/manifest+json"),
  ("wasm", "application/wasm"),
  -- lean-vir's IR packages (vir/README.md): binary, but about 8:1 under brotli
  ("irpkg", "application/vnd.lean-vir.irpkg"),
  ("txt", "text/plain; charset=utf-8"), ("md", "text/markdown; charset=utf-8"),
  ("lean", "text/plain; charset=utf-8"), ("csv", "text/csv; charset=utf-8"),
  ("xml", "application/xml"), ("svg", "image/svg+xml"),
  ("png", "image/png"), ("jpg", "image/jpeg"), ("jpeg", "image/jpeg"), ("gif", "image/gif"),
  ("webp", "image/webp"), ("avif", "image/avif"), ("ico", "image/x-icon"), ("bmp", "image/bmp"),
  ("woff", "font/woff"), ("woff2", "font/woff2"), ("ttf", "font/ttf"), ("otf", "font/otf"),
  ("pdf", "application/pdf"), ("zip", "application/zip"),
  ("mp4", "video/mp4"), ("webm", "video/webm"), ("mp3", "audio/mpeg"), ("wav", "audio/wav"),
  ("ogg", "audio/ogg"), ("data", "application/octet-stream")]

/-- The lower-cased extension of a file name (`"app.WASM"` → `"wasm"`), or `""`. -/
def extension (name : String) : String :=
  let base := (name.splitOn "/").getLast!
  match base.splitOn "." with
  | [] | [_] => ""
  | parts => parts.getLast!.toLower

/-- The media type for a file name; `application/octet-stream` when the extension is unknown. -/
def ofPath (name : String) : String :=
  (table.lookup (extension name)).getD "application/octet-stream"

/-- Is this a type worth compressing (text, JSON, JavaScript, wasm, SVG, lean-vir packages)? -/
def compressible (ctype : String) : Bool :=
  ctype.startsWith "text/" || ctype.startsWith "application/json" || ctype.startsWith "application/wasm" ||
  ctype.startsWith "image/svg" || ctype.startsWith "application/xml" || ctype.startsWith "application/manifest" ||
  ctype.startsWith "application/vnd.lean-vir"

end LeanUI.Server.Mime
