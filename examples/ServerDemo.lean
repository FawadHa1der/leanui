module
public import LeanUI.Server.Demo
/-!
# `leanui-demo-server`

A native Lean server that serves the counter example every way LeanUI runs it, from one URL
scheme: `/counter` (wasm when the browser has Memory64, the server otherwise), `/counter/wasm`
(server-rendered, hydrated by `dist/counter`), `/counter/server` (server-rendered, driven by a
native session), `/counter/ssr`, plus a server-driven ticker with timers and HTTP effects. The site
itself is `LeanUI.Server.Demo` (so the native tests drive the same routes).

    leanui-demo-server [--port 5340] [--host 127.0.0.1] [--dist dist] [--runtime runtime/leanui.js] [--quiet]
-/
public section

def main (args : List String) : IO UInt32 := LeanUI.Server.Demo.main args
