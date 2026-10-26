module
public import LeanUIQed.Host
public import Life
/-! `life-host`: Life (`examples/Life.lean`) on the stdin/stdout host, compiled. -/
public def main (args : List String) : IO UInt32 := LeanUIQed.serve Life.program args
