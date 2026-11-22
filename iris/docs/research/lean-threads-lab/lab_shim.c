// Boots the Lean runtime and ThreadLab, as runtime/leanui_wasm.c boots a LeanUI app, plus the one
// call a threaded build needs and LeanUI's shim does not make: lean_init_task_manager_using(n).
// Without it Task.spawn runs its closure at once on the calling thread (object.cpp
// lean_task_spawn_core: `if (!g_task_manager) return lean_task_pure(apply_1(c, box(0)))`).
#include <lean/lean.h>
#include <stdio.h>
#include <stdlib.h>
#if defined(__EMSCRIPTEN__)
#include <emscripten.h>
#define EXPORT EMSCRIPTEN_KEEPALIVE
#else
#define EXPORT
#endif

extern lean_object *initialize_ThreadLab(uint8_t builtin);
extern lean_object *lab_suite(uint32_t, uint32_t, uint32_t, uint32_t);
extern lean_object *lab_consume_ring(uint32_t);
extern lean_object *lab_mixed_faa(uint32_t, uint32_t);
extern uint64_t lab_region(lean_object *);
extern lean_object *lab_warm(uint32_t);
extern lean_object *lab_bg_blur(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
extern lean_object *lab_bg_blur_naive(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
void lean_initialize_runtime_module(void);
void lean_init_task_manager_using(unsigned);

static int ok(lean_object *r) {
  if (lean_io_result_is_error(r)) { lean_io_result_show_error(r); lean_dec_ref(r); return 0; }
  lean_dec_ref(r);
  return 1;
}

EXPORT int lab_boot(int workers) {
  lean_initialize_runtime_module();
  if (!ok(initialize_ThreadLab(1))) return 0;
  lean_io_mark_end_initialization();
  if (workers > 0) {
    lean_init_task_manager_using((unsigned)workers);
    if (!ok(lab_warm((uint32_t)workers))) return 0;
    fflush(stdout);
  }
  return 1;
}
EXPORT int lab_run(int which, int a, int b, int c) { int r = ok(lab_suite(which, a, b, c)); fflush(stdout); return r; }
EXPORT int lab_ring(int count) { int r = ok(lab_consume_ring(count)); fflush(stdout); return r; }
EXPORT int lab_mixed(int k, int n) { int r = ok(lab_mixed_faa(k, n)); fflush(stdout); return r; }
EXPORT int lab_bg(int id, int w, int h, int r, int k) { return ok(lab_bg_blur(id, w, h, r, k)); }
EXPORT int lab_bg_naive(int id, int w, int h, int r, int k) { return ok(lab_bg_blur_naive(id, w, h, r, k)); }
EXPORT uint64_t lab_region_js(void) { return lab_region(lean_box(0)); }

#if !defined(__EMSCRIPTEN__)
int main(int argc, char **argv) {
  int workers = argc > 1 ? atoi(argv[1]) : 4;
  if (!lab_boot(workers)) return 1;
  for (int i = 2; i + 3 < argc; i += 4)
    if (!lab_run(atoi(argv[i]), atoi(argv[i + 1]), atoi(argv[i + 2]), atoi(argv[i + 3]))) return 1;
  return 0;
}
#endif
