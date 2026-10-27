module
public import LeanUIQed.Host
public import Bench
/-! `bench-host`: the benchmark app (`examples/Bench.lean`) on the stdin/stdout host, compiled. -/
public def main (args : List String) : IO UInt32 := LeanUIQed.serve Bench.program args
