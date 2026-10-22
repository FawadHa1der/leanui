module
public import Roster
public import LeanUI.Host.Wasm
-- the wasm entry point (tools/build-app.sh RosterApp roster)
leanui_app Roster.program
