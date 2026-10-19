// LeanUI's C shim for the browser (Emscripten, single-threaded wasm64).
// Boots the Lean runtime and the app, keeps the running Instance, and moves data across the
// boundary: command buffers out (zero-copy views of Lean ByteArrays), events and effect results
// in (UTF-8 bytes the JavaScript runtime allocates with malloc, passed with their length so a
// payload may contain U+0000; freed here). Byte arrays travel without copies in Lean: the page
// reads a command's blobs (pixels, downloads) in place, and a file's bytes are written straight
// into a ByteArray allocated here (leanui_bytes_alloc) that Lean then owns.
#include <lean/lean.h>
#include <emscripten.h>
#include <stdlib.h>

extern lean_object *leanui_initialize_app(void); // generated per app: runtime_initialize_<pkg>_<Mod>(1)
extern lean_object *leanui_app_start(lean_object *flags, lean_object *selector, uint8_t hydrate);
extern lean_object *leanui_instance_event(lean_object *inst, uint32_t slot, lean_object *payload);
extern lean_object *leanui_instance_callback(lean_object *inst, uint32_t cb, uint8_t ok, lean_object *payload);
extern lean_object *leanui_instance_callback_bytes(lean_object *inst, uint32_t cb, uint8_t ok, lean_object *payload, lean_object *bytes);

static lean_object *g_inst;

EM_JS(void, leanui_js_flush, (const uint8_t *ops, size_t ops_len, const uint8_t *strs, size_t strs_len), {
  globalThis.LeanUI.__flush(HEAPU8, Number(ops), Number(ops_len), Number(strs), Number(strs_len));
});

lean_obj_res leanui_host_flush(b_lean_obj_arg ops, b_lean_obj_arg strs) {
  leanui_js_flush(lean_sarray_cptr(ops), lean_sarray_size(ops), lean_sarray_cptr(strs), lean_sarray_size(strs));
  return lean_io_result_mk_ok(lean_box(0));
}

EM_JS(void, leanui_js_blob, (size_t i, const uint8_t *p, size_t len), {
  globalThis.LeanUI.__blob(Number(i), Number(p), Number(len));
});

// The blobs of the next flush: their addresses and sizes, valid until that flush returns.
lean_obj_res leanui_host_blobs(b_lean_obj_arg blobs) {
  size_t n = lean_array_size(blobs);
  for (size_t i = 0; i < n; i++) {
    lean_object *b = lean_array_get_core(blobs, i);
    leanui_js_blob(i, lean_sarray_cptr(b), lean_sarray_size(b));
  }
  return lean_io_result_mk_ok(lean_box(0));
}

// A ByteArray of len bytes for the page to fill (leanui_bytes_data) and pass to
// leanui_callback_bytes, which hands it to Lean.
EMSCRIPTEN_KEEPALIVE lean_object *leanui_bytes_alloc(size_t len) { return lean_alloc_sarray(1, len, len); }
EMSCRIPTEN_KEEPALIVE uint8_t *leanui_bytes_data(lean_object *o) { return lean_sarray_cptr(o); }

static int ok_or_report(lean_object *r) {
  if (lean_io_result_is_error(r)) { lean_io_result_show_error(r); lean_dec_ref(r); return 0; }
  return 1;
}

static lean_object *take_string(char *s, size_t len) {
  lean_object *o = s ? lean_mk_string_from_bytes(s, len) : lean_mk_string("");
  free(s);
  return o;
}

// flags and selector are malloc'd UTF-8 bytes (ownership passes to C).
EMSCRIPTEN_KEEPALIVE int leanui_boot(char *flags, size_t flags_len, char *selector, size_t selector_len, int hydrate) {
  lean_object *r = leanui_initialize_app();
  if (!ok_or_report(r)) return 0;
  lean_dec_ref(r);
  lean_io_mark_end_initialization();
  r = leanui_app_start(take_string(flags, flags_len), take_string(selector, selector_len), (uint8_t)hydrate);
  if (!ok_or_report(r)) return 0;
  g_inst = lean_io_result_get_value(r);
  lean_inc(g_inst);
  lean_dec_ref(r);
  return 1;
}

EMSCRIPTEN_KEEPALIVE void leanui_event(uint32_t slot, char *payload, size_t len) {
  if (!g_inst) { free(payload); return; }
  lean_inc(g_inst);
  lean_object *r = leanui_instance_event(g_inst, slot, take_string(payload, len));
  if (ok_or_report(r)) lean_dec_ref(r);
}

EMSCRIPTEN_KEEPALIVE void leanui_callback(uint32_t cb, int ok, char *payload, size_t len) {
  if (!g_inst) { free(payload); return; }
  lean_inc(g_inst);
  lean_object *r = leanui_instance_callback(g_inst, cb, (uint8_t)ok, take_string(payload, len));
  if (ok_or_report(r)) lean_dec_ref(r);
}

EMSCRIPTEN_KEEPALIVE void leanui_callback_bytes(uint32_t cb, int ok, char *payload, size_t len, lean_object *bytes) {
  if (!g_inst) { free(payload); lean_dec(bytes); return; }
  lean_inc(g_inst);
  lean_object *r = leanui_instance_callback_bytes(g_inst, cb, (uint8_t)ok, take_string(payload, len), bytes);
  if (ok_or_report(r)) lean_dec_ref(r);
}
