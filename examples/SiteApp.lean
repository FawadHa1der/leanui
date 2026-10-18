module
public import Site
public import LeanUI.Host.Wasm
-- the wasm entry point (tools/build-app.sh SiteApp site)
leanui_app Site.program
