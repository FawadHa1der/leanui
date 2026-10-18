module
public import LeanUI.Server.Cli
/-! The `leanui` command; see `LeanUI.Server.Cli`. -/
public section

def main (args : List String) : IO UInt32 := LeanUI.Server.Cli.main args
