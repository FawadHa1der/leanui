| group | scenario | thr | JS hand-written | ms | result | HeapLang program (iris-lean) | HL->JS ms | HL->C native ms | HL->C->wasm ms | result | HL->JS / JS |
|---|---|---|---|---|---|---|---|---|---|---|---|
| counter | fetch-and-add | 1 | Atomics.add | 2.395 | 200000 | faa (wp_faa) | 3.003 | 2.1 | 2.465 | 200000 | 1.25 |
| counter | CAS loop | 1 | CAS loop | 3.744 | 200000 | Counter.incr (verified) | 4.418 | 2.089 | 2.143 | 200000 | 1.18 |
| counter | spin lock | 1 | CAS spinlock, plain ++ | 4.437 | 200000 | SpinLock (verified) | 7.573 | 3.84 | 4.017 | 200000 | 1.71 |
| counter | spin lock, all-SC body | 1 | CAS spinlock, SC ++ | 7.53 | 200000 |  |  |  |  |  |  |
| counter | ticket lock | 1 | ticket lock | 5.683 | 200000 | TicketLock (verified) | 20.018 | 3.525 | 4.229 | 200000 | 3.52 |
| counter | futex mutex | 1 | Drepper mutex, wait/notify | 4.832 | 200000 | FutexMutex + hints (hints verified no-op) | 8.444 | 3.804 | 4.281 | 200000 | 1.75 |
| counter | spin lock + hints | 1 |  |  |  | SpinLock + hints | 12.882 | 27.69 | 10.47 | 200000 |  |
| counter | NO lock (racy) | 1 | plain I[c]++ | 0.604 | 200000 | c <- !c + 1 (no proof possible) | 4.713 | 2.197 | 2.531 | 200000 | 7.80 |
| counter | fetch-and-add | 2 | Atomics.add | 24.442 | 400000 | faa (wp_faa) | 30.785 | 19.041 | 27.311 | 400000 | 1.26 |
| counter | CAS loop | 2 | CAS loop | 43.655 | 400000 | Counter.incr (verified) | 56.896 | 33.572 | 34.066 | 400000 | 1.30 |
| counter | spin lock | 2 | CAS spinlock, plain ++ | 77.63 | 400000 | SpinLock (verified) | 123.777 | 73.697 | 78.635 | 400000 | 1.59 |
| counter | spin lock, all-SC body | 2 | CAS spinlock, SC ++ | 97.149 | 400000 |  |  |  |  |  |  |
| counter | ticket lock | 2 | ticket lock | 96.819 | 400000 | TicketLock (verified) | 175.266 | 97.405 | 90.346 | 400000 | 1.81 |
| counter | futex mutex | 2 | Drepper mutex, wait/notify | 29.346 | 400000 | FutexMutex + hints (hints verified no-op) | 66.017 | 38.885 | 33.813 | 400000 | 2.25 |
| counter | spin lock + hints | 2 |  |  |  | SpinLock + hints | 101.534 | 65.329 | 89.365 | 400000 |  |
| counter | NO lock (racy) | 2 | plain I[c]++ | 0.609 | 215664 | 207525 | c <- !c + 1 (no proof possible) | 32.479 | 21.59 | 24.402 | 258489 | 224750 / 264830 | 274473 / 294509 | 276469 | 53.33 |
| counter | fetch-and-add | 4 | Atomics.add | 86.023 | 800000 | faa (wp_faa) | 89.039 | 33.546 | 74.835 | 800000 | 1.04 |
| counter | CAS loop | 4 | CAS loop | 137.279 | 800000 | Counter.incr (verified) | 146.811 | 91.29 | 85.632 | 800000 | 1.07 |
| counter | spin lock | 4 | CAS spinlock, plain ++ | 319.688 | 800000 | SpinLock (verified) | 524.224 | 398.594 | 412.801 | 800000 | 1.64 |
| counter | spin lock, all-SC body | 4 | CAS spinlock, SC ++ | 434.196 | 800000 |  |  |  |  |  |  |
| counter | ticket lock | 4 | ticket lock | 354.918 | 800000 | TicketLock (verified) | 816.786 | 521.081 | 390.19 | 800000 | 2.30 |
| counter | futex mutex | 4 | Drepper mutex, wait/notify | 62.274 | 800000 | FutexMutex + hints (hints verified no-op) | 131.557 | 70.556 | 85.658 | 800000 | 2.11 |
| counter | spin lock + hints | 4 |  |  |  | SpinLock + hints | 272.2 | 228.131 | 120.232 | 800000 |  |
| counter | NO lock (racy) | 4 | plain I[c]++ | 1.106 | 401300 | 397748 | c <- !c + 1 (no proof possible) | 80.238 | 54.627 | 52.954 | 387473 | 325171 / 431611 | 369521 / 382429 | 376321 | 72.55 |
| counter | spin lock (8 thr / 4 vCPU) | 8 | CAS spinlock, plain ++ | 265.868 | 400000 | SpinLock (verified) | 416.952 | 225.223 | 309.786 | 400000 | 1.57 |
| counter | CAS loop (8 thr / 4 vCPU) | 8 | CAS loop | 79.597 | 400000 | Counter.incr (verified) | 76.698 | 40.766 | 49.436 | 400000 | 0.96 |
| counter | futex mutex (8 thr / 4 vCPU) | 8 | Drepper mutex | 25.951 | 400000 | FutexMutex + hints | 52.251 | 32.738 | 33.846 | 400000 | 2.01 |
| counter | spin + hints (8 thr / 4 vCPU) | 8 |  |  |  | SpinLock + hints | 104.061 | 95.844 | 68.221 | 400000 |  |
| counter | ticket lock (8 thr / 4 vCPU) | 8 | ticket lock | 3140.028 | 16000 | TicketLock (verified) | 20572.9 | 2659.373 | 10.006 | 16000 | 6.55 |
| rwlock | readers/writer, 1 write in 10 | 4 | RW spinlock | 86.147 | (0, 40000) | RwSpinLock (verified) | 159.533 | 74.38 | 111.639 | (0, 40000) | 1.85 |
| lockfree | Treiber stack push/pop | 4 | Treiber over SAB | 13.448 | (200020000, true) | Treiber (iris-audit proof) | 15 | 12.63 | 16.32 | (200020000, true) | 1.12 |
| forkjoin | sum 4M, sequential | 1 | loop | 9.763 | 8004000 | sumSq | 22.854 | 10.38 | 8.09 | 8004000 | 2.34 |
| forkjoin | sum 4M, two halves | 2 | 2 workers | 5.522 | 8004000 | Par.par (verified) | 16.033 | 4.007 | 4.235 | 8004000 | 2.90 |
| forkjoin | sum 4M with i*i (overflows 2^28) | 1 |  |  |  | sumSqOvf |  |  |  | TRAP: integer overflow: result outside the 29- / TRAP: HeapLang program stuck / unsupported: in |  |
| forkjoin | fib(32) sequential | 1 | fib | 20.357 | 2178309 | pfib d=0 | 24.541 | 13.717 | 19.444 | 2178309 | 1.21 |
| forkjoin | fib(32), 4 leaves | 4 | 4 workers | 19.289 | 2178309 | pfib d=2 (Par) | 34.952 | 29.22 | 25.485 | 2178309 | 1.81 |
| forkjoin | fib(32), 64 leaves, spin-join | 4 |  |  |  | pfib d=6 (Par) | 207.914 | 187.991 | 88.498 | 2178309 |  |
| forkjoin | fib(32), 64 leaves, hinted join | 4 |  |  |  | pfib d=6 (Par + hints) | 62.191 | 9.225 | 12.104 | 2178309 |  |
| seq | quicksort 20k linked list | 1 | same algorithm, JS objects | 29.571 | true | Quicksort.quicksort (verified) | 35.101 | 27.697 | 13.34 | true | 1.19 |
| seq | quicksort 20k (context) | 1 | Array.prototype.sort | 10.262 | true |  |  |  |  |  |  |
| threads | 1000 tiny tasks | 4 | postMessage pool | 4.906 | 1000 | 1000 x fork | 55.891 | 3.453 | 4.079 | 1000 | 11.39 |
| threads | 50 tasks, new Worker each | 50 | new Worker per task | 920.188 | 50 |  |  |  |  |  |  |

{"loadavg_start":[19.08,13.5,9.6],"loadavg_end":[21.02,12.91,10.73],"date":"2026-11-20T18:43:21.186Z","node":"v22.23.5","cpus":4,"cpu":"Intel(R) Xeon(R) Processor @ 2.10GHz","runs":5,"reps":2,"note":"CI machine (4 vCPU cloud VM); use ratios, re-measure on the reference Mac"}
