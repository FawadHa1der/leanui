// Count every allocation of a LeanUI wasm build. `LEANUI_COUNT_ALLOCS=1 tools/build-app.sh ...`
// links this file, whose malloc, free, calloc, realloc and memalign replace emscripten's (weak) ones
// and count each call before calling dlmalloc through its `emscripten_builtin_*` names. The
// wasm Lean runtime has no allocator of its own (every object, array, string and closure is a
// dlmalloc block; `free_sized` calls `free`), so this counts all of Lean's allocations, and those
// of libc++ and of the page (event payloads). tests/browser/allocs.mjs reads the counters around a
// click. Not for timing: every call goes through one more function.
#include <stddef.h>
#include <stdint.h>
#include <emscripten.h>

void *emscripten_builtin_malloc(size_t);
void emscripten_builtin_free(void *);
void *emscripten_builtin_calloc(size_t, size_t);
void *emscripten_builtin_realloc(void *, size_t);
void *emscripten_builtin_memalign(size_t, size_t);

// allocations (malloc, calloc, memalign), frees of non-null pointers, reallocs, bytes requested
static uint64_t counts[4];

void *malloc(size_t n) { counts[0]++; counts[3] += n; return emscripten_builtin_malloc(n); }
void free(void *p) { if (p) counts[1]++; emscripten_builtin_free(p); }
void *calloc(size_t k, size_t n) { counts[0]++; counts[3] += k * n; return emscripten_builtin_calloc(k, n); }
void *realloc(void *p, size_t n) { counts[2]++; counts[3] += n; return emscripten_builtin_realloc(p, n); }
void *memalign(size_t a, size_t n) { counts[0]++; counts[3] += n; return emscripten_builtin_memalign(a, n); }
int posix_memalign(void **p, size_t a, size_t n) {
  counts[0]++; counts[3] += n;
  void *r = emscripten_builtin_memalign(a, n);
  if (!r) return 12; // ENOMEM
  *p = r; return 0;
}

EMSCRIPTEN_KEEPALIVE double leanui_alloc_counter(int i) { return i >= 0 && i < 4 ? (double)counts[i] : -1; }
