module
public import LeanUI.Server.Url
public import LeanUI.Server.Mime
public import LeanUI.Server.Http
public import LeanUI.Server.Static
public import LeanUI.Server.Page
public import LeanUI.Server.Session
public import LeanUI.Server.Site
public import LeanUI.Server.Run
/-!
# LeanUI on a native Lean server

Server-side rendering, static files and server-driven sessions on `Std.Http` (Lean 4.34): one
`Program` served as a server-rendered page that its wasm build hydrates, as a page a native session
drives over the remote protocol (for browsers without Memory64), or as plain HTML; `LeanUI.boot`
chooses in the browser. See `docs/SERVER.md`.

Native only (`tools/build-app.sh` leaves `*/Server*` out of wasm builds). `LeanUI.Server.Testing`
(a browser stand-in for native tests), `LeanUI.Server.Cli` (the `leanui` command) and
`LeanUI.Server.Demo` (the demo site) are imported separately.
-/
public section
