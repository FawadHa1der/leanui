// ThreadLab's C side: C11/GCC atomics on a static region, compiled to native x86-64 atomics or
// to wasm `i64.atomic.*` (with -pthread / -matomics). The region is plain linear memory, so in a
// threaded wasm build JavaScript workers that hold the module's SharedArrayBuffer can use
// Atomics.* on the very same cells.
//
// Layout (64-bit words, each group on its own 64-byte line to avoid false sharing):
//   cells[0]       counter used by the Lean-only counter benchmarks
//   cells[8]       counter shared by Lean tasks and JavaScript workers (lab_mixed_faa)
//   cells[16]      ring head (consumer index)          } SpscRing.tryPush / tryPop,
//   cells[24]      ring tail (producer index)          } iris-audit/proofs/SpscRing.lean
//   cells[32..32+RING_N)  ring slots (plain loads/stores)
// The JavaScript side finds the region with lab_region() and uses the same offsets.
#include <lean/lean.h>
#include <stdint.h>
#include <stdlib.h>
#if defined(__EMSCRIPTEN__)
#include <emscripten.h>
#endif

#define RING_N 1024
#define HD 16
#define TL 24
#define SLOTS 32
static _Alignas(64) uint64_t cells[SLOTS + RING_N];

// Index i of the Lean API maps to cell i*8 (one cache line per logical cell).
static inline uint64_t *cell(size_t i) { return &cells[i * 8]; }

uint64_t lab_region_addr(lean_object *unit) { (void)unit; return (uint64_t)(uintptr_t)cells; }

lean_object *lab_store(size_t i, uint64_t v) { __atomic_store_n(cell(i), v, __ATOMIC_SEQ_CST); return lean_box(0); }
uint64_t lab_load(size_t i) { return __atomic_load_n(cell(i), __ATOMIC_SEQ_CST); }
uint64_t lab_faa(size_t i, uint64_t d) { return __atomic_fetch_add(cell(i), d, __ATOMIC_SEQ_CST); }
uint8_t lab_cas(size_t i, uint64_t expected, uint64_t desired) {
  return __atomic_compare_exchange_n(cell(i), &expected, desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}

// Hand translation of SpscRing.tryPush/tryPop (HeapLang, SC) to C11. Trusted, not verified:
// - the index cells use SC atomics (HeapLang's ! and <- are SC; JS Atomics.load/store are SC);
// - the slot accesses are plain: race-free because the proof gives each slot to exactly one side
//   at a time, and ordered by the SC index store/load (release/acquire would suffice in C11; that
//   step is an argument about the C11/JS memory model, outside the SC proof);
// - indices are uint64_t, HeapLang's are unbounded Int: wrap-around after 2^64 operations is not
//   covered (unreachable in practice);
// - values are u64 with 0 meaning "empty" in tryPop's result (HeapLang returns an option).
uint8_t lab_ring_push(uint64_t v) {
  uint64_t t = __atomic_load_n(&cells[TL], __ATOMIC_SEQ_CST);
  uint64_t h = __atomic_load_n(&cells[HD], __ATOMIC_SEQ_CST);
  if (t - h < RING_N) {
    cells[SLOTS + t % RING_N] = v;                       // plain store: we own slot t
    __atomic_store_n(&cells[TL], t + 1, __ATOMIC_SEQ_CST); // publish
    return 1;
  }
  return 0;
}
uint64_t lab_ring_pop(lean_object *unit) {
  (void)unit;
  uint64_t h = __atomic_load_n(&cells[HD], __ATOMIC_SEQ_CST);
  uint64_t t = __atomic_load_n(&cells[TL], __ATOMIC_SEQ_CST);
  if (h < t) {
    uint64_t v = cells[SLOTS + h % RING_N];              // plain load: we own slot h
    __atomic_store_n(&cells[HD], h + 1, __ATOMIC_SEQ_CST); // hand the slot back
    return v + 1;
  }
  return 0;
}
lean_object *lab_ring_reset(lean_object *unit) {
  (void)unit;
  __atomic_store_n(&cells[HD], 0, __ATOMIC_SEQ_CST);
  __atomic_store_n(&cells[TL], 0, __ATOMIC_SEQ_CST);
  return lean_box(0);
}

static lean_object *volatile g_sink;
lean_object *lab_keep(lean_object *a) { g_sink = a; return lean_box(0); }

lean_object *lab_notify_main(uint32_t id, uint32_t value) {
#if defined(__EMSCRIPTEN__)
  MAIN_THREAD_ASYNC_EM_ASM({ if (Module.onLabDone) Module.onLabDone($0, $1); }, id, value);
#else
  (void)id; (void)value;
#endif
  return lean_box(0);
}

lean_object *lab_cpu_relax(lean_object *unit) {
  (void)unit;
#if defined(__x86_64__)
  __builtin_ia32_pause();
#endif
  return lean_box(0);
}

// The shared output buffer of blurShared (ParMap pattern: disjoint plain stores).
static uint8_t *g_out; static size_t g_out_n;
lean_object *lab_out_set(size_t i, uint8_t v) {
  if (i >= g_out_n) abort(); // lab_out_reserve sizes it before any task starts
  g_out[i] = v;
  return lean_box(0);
}
uint32_t lab_out_hash(size_t n) {
  uint32_t h = 2166136261u;
  for (size_t i = 0; i < n && i < g_out_n; i++) h = (h ^ g_out[i]) * 16777619u;
  return h;
}
lean_object *lab_out_reserve(size_t n) { free(g_out); g_out = calloc(n, 1); g_out_n = n; return lean_box(0); }
