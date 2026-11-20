/-
The axiom audit, checked on every `lake build`: each headline theorem may depend on `propext`,
`Classical.choice` and `Quot.sound` only. `sorryAx`, or any new axiom, changes the message and
fails the build. The list is every theorem `Manifest.lean` names, the closed theorems, the
encoding lemma and the futex mutex's `Lock` instance; `test/node.mjs` checks it against the
manifest.
-/
import LeanUIIris.Manifest
import LeanUIIris.Translate

/-- info: 'LeanUIIris.FutexMutex.isLock_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.FutexMutex.isLock_iff
/-- info: 'LeanUIIris.FutexMutex.instLock' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.FutexMutex.instLock
/-- info: 'Iris.HeapLang.SpinLock.newlock_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.SpinLock.newlock_spec
/-- info: 'Iris.HeapLang.SpinLock.try_acquire_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.SpinLock.try_acquire_spec
/-- info: 'Iris.HeapLang.SpinLock.acquire_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.SpinLock.acquire_spec
/-- info: 'Iris.HeapLang.SpinLock.release_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.SpinLock.release_spec
/-- info: 'Iris.HeapLang.TicketLock.newlock_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.TicketLock.newlock_spec
/-- info: 'Iris.HeapLang.TicketLock.waitLoop_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.TicketLock.waitLoop_spec
/-- info: 'Iris.HeapLang.TicketLock.acquire_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.TicketLock.acquire_spec
/-- info: 'Iris.HeapLang.TicketLock.release_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.TicketLock.release_spec
/-- info: 'Iris.HeapLang.RwSpinLock.newlock_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.RwSpinLock.newlock_spec
/-- info: 'Iris.HeapLang.RwSpinLock.tryAcquireReader_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.RwSpinLock.tryAcquireReader_spec
/-- info: 'Iris.HeapLang.RwSpinLock.acquireReader_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.RwSpinLock.acquireReader_spec
/-- info: 'Iris.HeapLang.RwSpinLock.releaseReader_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.RwSpinLock.releaseReader_spec
/-- info: 'Iris.HeapLang.RwSpinLock.tryAcquireWriter_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.RwSpinLock.tryAcquireWriter_spec
/-- info: 'Iris.HeapLang.RwSpinLock.acquireWriter_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.RwSpinLock.acquireWriter_spec
/-- info: 'Iris.HeapLang.RwSpinLock.releaseWriter_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.RwSpinLock.releaseWriter_spec
/-- info: 'Iris.HeapLang.Counter.newcounter_mono_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Counter.newcounter_mono_spec
/-- info: 'Iris.HeapLang.Counter.incr_mono_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Counter.incr_mono_spec
/-- info: 'Iris.HeapLang.Counter.read_mono_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Counter.read_mono_spec
/-- info: 'Iris.HeapLang.Counter.newcounter_contrib_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Counter.newcounter_contrib_spec
/-- info: 'Iris.HeapLang.Counter.incr_contrib_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Counter.incr_contrib_spec
/-- info: 'Iris.HeapLang.Counter.read_contrib_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Counter.read_contrib_spec
/-- info: 'Iris.HeapLang.Counter.read_contrib_spec_1' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Counter.read_contrib_spec_1
/-- info: 'Iris.HeapLang.Spawn.spawn_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Spawn.spawn_spec
/-- info: 'Iris.HeapLang.Spawn.join_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Spawn.join_spec
/-- info: 'Iris.HeapLang.Par.par_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Par.par_spec
/-- info: 'Iris.HeapLang.Quicksort.nil_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Quicksort.nil_spec
/-- info: 'Iris.HeapLang.Quicksort.cons_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Quicksort.cons_spec
/-- info: 'Iris.HeapLang.Quicksort.append_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Quicksort.append_spec
/-- info: 'Iris.HeapLang.Quicksort.partition_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Quicksort.partition_spec
/-- info: 'Iris.HeapLang.Quicksort.quicksort_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Quicksort.quicksort_spec
/-- info: 'Iris.HeapLang.Quicksort.wp_checkSorted' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Quicksort.wp_checkSorted
/-- info: 'LeanUIIris.AtomicCounter.faaIncr_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.AtomicCounter.faaIncr_spec
/-- info: 'LeanUIIris.AtomicCounter.casIncr_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.AtomicCounter.casIncr_spec
/-- info: 'LeanUIIris.AtomicCounter.casIncr_seq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.AtomicCounter.casIncr_seq
/-- info: 'LeanUIIris.ParMap.pmap_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.ParMap.pmap_spec
/-- info: 'LeanUIIris.Treiber.newStack_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.Treiber.newStack_spec
/-- info: 'LeanUIIris.Treiber.push_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.Treiber.push_spec
/-- info: 'LeanUIIris.Treiber.pop_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.Treiber.pop_spec
/-- info: 'LeanUIIris.TreiberAtomic.newStackA_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.TreiberAtomic.newStackA_spec
/-- info: 'LeanUIIris.TreiberAtomic.pushA_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.TreiberAtomic.pushA_spec
/-- info: 'LeanUIIris.TreiberAtomic.popA_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.TreiberAtomic.popA_spec
/-- info: 'LeanUIIris.SpscRing.rb_init' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.SpscRing.rb_init
/-- info: 'LeanUIIris.SpscRing.tryPush_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.SpscRing.tryPush_spec
/-- info: 'LeanUIIris.SpscRing.tryPop_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.SpscRing.tryPop_spec
/-- info: 'LeanUIIris.SpscClient.pushLoop_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.SpscClient.pushLoop_spec
/-- info: 'LeanUIIris.SpscClient.popLoop_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.SpscClient.popLoop_spec
/-- info: 'LeanUIIris.Hints.futexWait_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.Hints.futexWait_spec
/-- info: 'LeanUIIris.Hints.futexWake_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.Hints.futexWake_spec
/-- info: 'LeanUIIris.FutexMutex.newlock_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.FutexMutex.newlock_spec
/-- info: 'LeanUIIris.FutexMutex.slow_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.FutexMutex.slow_spec
/-- info: 'LeanUIIris.FutexMutex.acquire_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.FutexMutex.acquire_spec
/-- info: 'LeanUIIris.FutexMutex.release_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.FutexMutex.release_spec
/-- info: 'LeanUIIris.TwoThreads.twoIncr_adequate' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.TwoThreads.twoIncr_adequate
/-- info: 'LeanUIIris.SpscClient.spscClient_adequate' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.SpscClient.spscClient_adequate
/-- info: 'Iris.HeapLang.Quicksort.sortAndCheckAdequate' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Iris.HeapLang.Quicksort.sortAndCheckAdequate
/-- info: 'LeanUIIris.Translate.cas_word_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.Translate.cas_word_iff
/-- info: 'LeanUIIris.FutexMutex.isLock_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.FutexMutex.isLock_iff
/-- info: 'LeanUIIris.FutexMutex.instLock' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms LeanUIIris.FutexMutex.instLock
