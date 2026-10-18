module
public import TodoMVC
public import LeanUI.Host.Wasm
-- the wasm entry point (tools/build-app.sh TodoMVCApp todomvc)
leanui_app TodoMVC.program
