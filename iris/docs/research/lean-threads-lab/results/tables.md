### 4.1 Boot

| build | where | load (ms) | Lean init (ms) | RSS (MB) |
|---|---|--:|--:|--:|
| Node, wasm-mt (dlmalloc) | | 143.9 | 83.9 | 125.1 |
| Node, wasm-mt (mimalloc) | | 106.3 | 74.9 | 128.1 |
| Node, wasm-st (LeanUI's) | | 16.5 | 62.7 | 67.9 |
| Chromium page, wasm-mt | | 81.1 | 85.2 | – |
| Chromium page, wasm-mt (mimalloc) | | 114.7 | 75.4 | – |
| Chromium Worker, wasm-mt | | 79.9 | 67.3 | – |
| Chromium page, wasm-st | | 43.5 | 54.3 | – |

#### Life 40 × 25, 1,000 generations (LeanUI's board)

| | 1 task | 2 tasks | 4 tasks | 4-task speed-up |
|---|--:|--:|--:|--:|
| native (upstream 4.34, mimalloc) | 31 | 63 | 145 | 0.21× |
| Node, wasm-mt (dlmalloc) | 39 | 83 | 95 | 0.41× |
| Node, wasm-mt (mimalloc) | 39 | 77 | 108 | 0.36× |
| Node, wasm-st (LeanUI's) | 40 | 42 | 42 | 0.96× |
| Chromium page, wasm-mt | 42 | 61 | 89 | 0.48× |
| Chromium page, wasm-mt (mimalloc) | 42 | 72 | 66 | 0.65× |
| Chromium Worker, wasm-mt | 43 | 76 | 87 | 0.49× |
| Chromium page, wasm-st | 39 | 41 | 49 | 0.80× |

#### Life 512 × 512, 50 generations

| | 1 task | 2 tasks | 4 tasks | 4-task speed-up |
|---|--:|--:|--:|--:|
| native (upstream 4.34, mimalloc) | 409 | 311 | 248 | 1.65× |
| Node, wasm-mt (dlmalloc) | 542 | 527 | 379 | 1.43× |
| Node, wasm-mt (mimalloc) | 580 | 536 | 355 | 1.64× |
| Node, wasm-st (LeanUI's) | 522 | 504 | 520 | 1.00× |
| Chromium page, wasm-mt | 525 | 435 | 414 | 1.27× |
| Chromium page, wasm-mt (mimalloc) | 560 | 456 | 417 | 1.34× |
| Chromium Worker, wasm-mt | 610 | 553 | 391 | 1.56× |
| Chromium page, wasm-st | 584 | 618 | 611 | 0.96× |

#### Box blur 640 × 360, r = 2, pure bands (`blurPar`)

| | 1 task | 2 tasks | 4 tasks | 4-task speed-up |
|---|--:|--:|--:|--:|
| native (upstream 4.34, mimalloc) | 423 | 253 | 269 | 1.57× |
| Node, wasm-mt (dlmalloc) | 724 | 744 | 690 | 1.05× |
| Node, wasm-mt (mimalloc) | 708 | 467 | 373 | 1.90× |
| Node, wasm-st (LeanUI's) | 732 | 748 | 770 | 0.95× |
| Chromium page, wasm-mt | 686 | 765 | 692 | 0.99× |
| Chromium page, wasm-mt (mimalloc) | 680 | 385 | 422 | 1.61× |
| Chromium Worker, wasm-mt | 703 | 963 | 834 | 0.84× |
| Chromium page, wasm-st | 753 | 823 | 752 | 1.00× |

#### Box blur 640 × 360, r = 2, disjoint writes to one C buffer (`blurShared`, ParMap pattern)

| | 1 task | 2 tasks | 4 tasks | 4-task speed-up |
|---|--:|--:|--:|--:|
| native (upstream 4.34, mimalloc) | 404 | 278 | 249 | 1.62× |
| Node, wasm-mt (dlmalloc) | 807 | 799 | 702 | 1.15× |
| Node, wasm-mt (mimalloc) | 809 | 415 | 372 | 2.18× |
| Node, wasm-st (LeanUI's) | 743 | 686 | 665 | 1.12× |
| Chromium page, wasm-mt | 712 | 722 | 653 | 1.09× |
| Chromium page, wasm-mt (mimalloc) | 671 | 402 | 403 | 1.67× |
| Chromium Worker, wasm-mt | 710 | 831 | 762 | 0.93× |
| Chromium page, wasm-st | 678 | 774 | 676 | 1.00× |

### Sharing costs

| | rc: plain counts (ms) | rc: same objects after `markMultiThreaded` (ms) | 1 task over a shared array | 4 tasks, one shared array | 4 tasks, private arrays | first `set!` on a shared 4 MB array (µs) | `markMultiThreaded`, 100k objects (µs) |
|---|--:|--:|--:|--:|--:|--:|--:|
| native (upstream 4.34, mimalloc) | 24.2 | 40.4 | 44.1 | 68.5 | 49.0 | 622 | 1,685 |
| Node, wasm-mt (dlmalloc) | 18.6 | 35.8 | 49.8 | 94.8 | 116.2 | 535 | 707 |
| Node, wasm-mt (mimalloc) | 16.8 | 42.6 | 44.5 | 92.1 | 52.9 | 582 | 4,931 |
| Node, wasm-st (LeanUI's) | 15.9 | 14.8 | 15.3 | 54.2 | 86.3 | 8 | 4 |
| Chromium page, wasm-mt | 18.9 | 38.3 | 67.5 | 153.3 | 196.1 | 484 | 879 |
| Chromium page, wasm-mt (mimalloc) | 13.8 | 40.5 | 72.5 | 131.4 | 85.5 | 659 | 1,070 |
| Chromium Worker, wasm-mt | 19.1 | 41.4 | 49.5 | 95.6 | 188.8 | 480 | 830 |
| Chromium page, wasm-st | 16.4 | 14.7 | 15.4 | 56.1 | 94.7 | 0 | 0 |

### Counters: 4 tasks × 1,000,000 increments of one shared counter

| way | native (upstream 4.34, mimalloc) | Node, wasm-mt (dlmalloc) | Node, wasm-mt (mimalloc) | Chromium page, wasm-mt |
|---|--:|--:|--:|--:|
| IO.Ref.modify (take/set) | 354 ms | 577 ms | 533 ms | 180 ms |
| IO.Ref get;set (racy) | 236 ms (kept 51%/42%/59%) | 293 ms (kept 48%/61%/38%) | 363 ms (kept 31%/59%/49%) | 191 ms (kept 72%/50%/61%) |
| Std.Mutex | 362 ms | 750 ms | 630 ms | 748 ms |
| C11 fetch_add (faaIncr) | 72 ms | 125 ms | 112 ms | 37 ms |
| C11 CAS loop (casIncr) | 112 ms | 80 ms | 84 ms | 70 ms |
| per-task shards | 7 ms | 16 ms | 21 ms | 32 ms |

### Background blur 1280 × 720, r = 2, 4 tasks (Chromium page, main thread)

| build | variant | call returned (ms) | result (ms) | frames drawn | longest frame gap (ms) |
|---|---|--:|--:|--:|--:|
| wasm-mt-mimalloc | naive do-block (pure prefix) | 1,550.6 | 1,571 | 6 | 1,549.9 |
| wasm-mt-mimalloc | IO.lazyPure inside IO.asTask | 0.3 | 1,243 | 78 | 16.7 |
| wasm-mt | naive do-block (pure prefix) | 2,804.5 | 2,820 | 6 | 2,799.9 |
| wasm-mt | IO.lazyPure inside IO.asTask | 0.2 | 2,677 | 164 | 16.7 |
| wasm-st | naive do-block (pure prefix) | 2,849.1 | 2,849 | 5 | 2,849.9 |
| wasm-st | IO.lazyPure inside IO.asTask | 2,770.7 | 2,771 | 5 | 2,766.5 |

### JavaScript and Lean on one SharedArrayBuffer (Node, wasm-mt)

- {"bench": "spsc-lean-to-lean", "count": 1000000, "ms": 707.961, "sum": 500000500000, "expected": 500000500000, "outOfOrder": 0, "emptySpins": 2243303}
- {"bench": "mixed-faa", "leanTasks": 2, "jsWorkers": 2, "perThread": 1000000, "ms": 99.8, "got": "4000000", "expected": "4000000", "jsMs": [78.7, 94]}
- {"bench": "spsc-js-to-lean", "count": 1000000, "ms": 893.681, "sum": 500000500000, "expected": 500000500000, "outOfOrder": 0, "emptySpins": 7699339}
- {"bench": "spsc-js-producer", "producerMs": 890.7, "producerFullSpins": 6726000}
- {"bench": "spsc-lean-to-lean", "count": 1000000, "ms": 729.449, "sum": 500000500000, "expected": 500000500000, "outOfOrder": 0, "emptySpins": 2651766}
- {"bench": "mixed-faa", "leanTasks": 2, "jsWorkers": 2, "perThread": 1000000, "ms": 180.1, "got": "4000000", "expected": "4000000", "jsMs": [129, 172]}
- {"bench": "spsc-js-to-lean", "count": 1000000, "ms": 754.982, "sum": 500000500000, "expected": 500000500000, "outOfOrder": 0, "emptySpins": 6718435}
- {"bench": "spsc-js-producer", "producerMs": 752.4, "producerFullSpins": 6357366}
- {"bench": "spsc-lean-to-lean", "count": 1000000, "ms": 511.334, "sum": 500000500000, "expected": 500000500000, "outOfOrder": 0, "emptySpins": 1082807}
- {"bench": "mixed-faa", "leanTasks": 2, "jsWorkers": 2, "perThread": 1000000, "ms": 169.1, "got": "4000000", "expected": "4000000", "jsMs": [144.8, 167.8]}
- {"bench": "spsc-js-to-lean", "count": 1000000, "ms": 461.74, "sum": 500000500000, "expected": 500000500000, "outOfOrder": 0, "emptySpins": 1950544}
- {"bench": "spsc-js-producer", "producerMs": 460.6, "producerFullSpins": 1866437}
