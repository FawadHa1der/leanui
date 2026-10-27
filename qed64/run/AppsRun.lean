import LeanUIQed.Host
import Bench
import Life
/-! What the lane's `lean --run` runs (qed64/README.md), for either app, so one header snapshot
serves both. A plain file, not a `module`: a module's imports bring no IR for the interpreter. -/
def main : List String → IO UInt32
  | "bench" :: args => LeanUIQed.serve Bench.program args
  | "life" :: args => LeanUIQed.serve Life.program args
  | _ => do IO.eprintln "usage: AppsRun.lean bench|life [--out raw|b64] [--selector s] [--flags s]"; return 2
