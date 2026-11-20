// C11 runtime for the translation units iris/LeanUIIris/Translate.lean writes. Trusted, not
// verified. The same value encoding and heap layout as runtime.mjs (one int32 word per value,
// tag = w & 7), and the same rule: every HeapLang Load/Store/CmpXchg/Xchg/FAA is a seq_cst
// __atomic operation; plain accesses only initialise fresh blocks and read immutable ones.
// Builds natively (cc -O2 -pthread) or to wasm32 with Emscripten (-pthread: wasm atomics, futexes).
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#ifdef __EMSCRIPTEN__
#include <emscripten/threading.h>
#include <emscripten/emscripten.h>
#else
#include <linux/futex.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

typedef int32_t (*hl_fn)(int32_t, int32_t);
extern hl_fn hl_FUNS[];
extern const int32_t hl_MAIN, hl_STATICS[], hl_NSTATICS;
extern const char *hl_NAME;

enum { UNIT = 7, FALSE_W = 15, TRUE_W = 23, POISON = 31, HDR_PAIR = 1, HDR_INJL = 2, HDR_INJR = 3 };
enum { C_BRK = 1, C_QHEAD = 2, C_QTAIL = 3, C_DONE = 4, C_RESULT = 5, C_GROW = 6, C_TRAP = 7, C_READY = 8,
       C_FORKS = 9, C_LIVE = 10, C_MAXLIVE = 11, C_FREED = 12, QBASE = 64, QCAP = 4096, STATIC_BASE = 64 + 4096 };
#define SEQ __ATOMIC_SEQ_CST
#define CHUNK (1 << 15)
#define WAIT_MS 20.0

static int32_t *H;
static int64_t H_LEN;
static _Thread_local int32_t tlab, tlab_end;

__attribute__((noreturn)) static void stuck(const char *msg) {
  fprintf(stderr, "{\"program\":\"%s\",\"trap\":\"HeapLang program stuck / unsupported: %s\"}\n", hl_NAME, msg);
  fflush(stderr); _Exit(2);
}
__attribute__((noreturn, cold)) static void ovf(void) { stuck("integer overflow: result outside the 29-bit encoding (HeapLang ints are unbounded)"); }

static void fwait(int32_t *addr, int32_t v, double ms) {
#ifdef __EMSCRIPTEN__
  emscripten_futex_wait(addr, (uint32_t)v, ms);
#else
  struct timespec ts = { (time_t)(ms / 1000), (long)((ms - 1000 * (long)(ms / 1000)) * 1e6) };
  syscall(SYS_futex, addr, FUTEX_WAIT_PRIVATE, v, &ts, 0, 0);
#endif
}
static void fwake(int32_t *addr, int n) {
#ifdef __EMSCRIPTEN__
  emscripten_futex_wake(addr, n);
#else
  syscall(SYS_futex, addr, FUTEX_WAKE_PRIVATE, n, 0, 0, 0);
#endif
}

static inline int32_t allocBlock(int32_t n) {
  int32_t p = tlab;
  if (__builtin_expect(p + n > tlab_end, 0)) {
    int32_t sz = n > CHUNK ? n : CHUNK;
    p = __atomic_fetch_add(&H[C_BRK], sz, SEQ);
    if ((int64_t)p + sz > H_LEN) stuck("out of memory: HeapLang never frees, heap exhausted");
    tlab_end = p + sz;
  }
  tlab = p + n;
  return p;
}
static inline int32_t allocN(int32_t nw, int32_t v) {
  if ((nw & 7) != 0 || nw <= 0) stuck("allocN with non-positive size");
  int32_t n = nw >> 3, p = allocBlock(n);
  for (int32_t i = 0; i < n; i++) H[p + i] = v;
  return (p << 3) | 1;
}
static inline void hl_free(int32_t l) { (void)l; __atomic_fetch_add(&H[C_FREED], 1, SEQ); }
static inline int32_t mkPair(int32_t a, int32_t b) { int32_t p = allocBlock(3); H[p] = HDR_PAIR; H[p + 1] = a; H[p + 2] = b; return (p << 3) | 6; }
static inline int32_t mkInjL(int32_t w) {
  int32_t t = w & 7;
  if (t < 2) return w + 2;
  if (t == 7 && (w & 0x60) == 0) return w + 32;
  int32_t p = allocBlock(2); H[p] = HDR_INJL; H[p + 1] = w; return (p << 3) | 6;
}
static inline int32_t mkInjR(int32_t w) {
  int32_t t = w & 7;
  if (t < 2) return w + 4;
  if (t == 7 && (w & 0x60) == 0) return w + 64;
  int32_t p = allocBlock(2); H[p] = HDR_INJR; H[p + 1] = w; return (p << 3) | 6;
}
static inline int isInjL(int32_t w) {
  int32_t t = w & 7;
  if (t == 2 || t == 3) return 1;
  if (t == 4 || t == 5) return 0;
  if (t == 7) { int32_t i = w & 0x60; if (i == 32) return 1; if (i == 64) return 0; }
  if (t == 6) { int32_t h = H[w >> 3]; if (h == HDR_INJL) return 1; if (h == HDR_INJR) return 0; }
  stuck("case on a non-sum value");
}
static inline int32_t payload(int32_t w) {
  int32_t t = w & 7;
  if (t == 2 || t == 3) return w - 2;
  if (t == 4 || t == 5) return w - 4;
  if (t == 7) return w & ~0x60;
  return H[(w >> 3) + 1];
}
static inline int32_t add(int32_t a, int32_t b) { int32_t r; if (__builtin_add_overflow(a, b, &r)) ovf(); return r; }
static inline int32_t sub(int32_t a, int32_t b) { int32_t r; if (__builtin_sub_overflow(a, b, &r)) ovf(); return r; }
static inline int32_t mul(int32_t a, int32_t b) { int32_t r; if (__builtin_mul_overflow(a >> 3, b, &r)) ovf(); return r; }
static inline int32_t quot(int32_t a, int32_t b) { if (b == 0) return 0; int64_t r = (int64_t)(a >> 3) / (b >> 3) * 8; if (r != (int32_t)r) ovf(); return (int32_t)r; }
static inline int32_t rem(int32_t a, int32_t b) { if (b == 0) return a; return ((a >> 3) % (b >> 3)) * 8; }
static inline int isBool(int32_t w) { return w == TRUE_W || w == FALSE_W; }
static inline int32_t band(int32_t a, int32_t b) { if (isBool(a)) return (a == TRUE_W && b == TRUE_W) ? TRUE_W : FALSE_W; return a & b; }
static inline int32_t bor(int32_t a, int32_t b) { if (isBool(a)) return (a == TRUE_W || b == TRUE_W) ? TRUE_W : FALSE_W; return a | b; }
static inline int32_t bxor(int32_t a, int32_t b) { if (isBool(a)) return (a != b) ? TRUE_W : FALSE_W; return a ^ b; }
static inline int32_t shl(int32_t a, int32_t b) {
  int32_t n = b >> 3, m = a >> 3;
  if (n >= 0) { if (n > 30) { if (m == 0) return 0; ovf(); } int64_t r = (int64_t)m * ((int64_t)1 << n) * 8; if (r != (int32_t)r) ovf(); return (int32_t)r; }
  return (m >> (-n > 31 ? 31 : -n)) * 8;
}
// m >>> n is m <<< (-n) in HeapLang; -b overflows for the word of -2^28 alone (m <<< 2^28)
static inline int32_t shr(int32_t a, int32_t b) { if (b == INT32_MIN) { if ((a >> 3) == 0) return 0; ovf(); } return shl(a, -b); }
static inline int32_t off(int32_t l, int32_t i) { return add(l, i); }
static inline int32_t neg(int32_t w) { if (isBool(w)) return w == TRUE_W ? FALSE_W : TRUE_W; return ~(w >> 3) * 8; }
static inline int32_t minus(int32_t w) { if (w == INT32_MIN) ovf(); return -w; }
static inline int32_t ald(int32_t l) { return __atomic_load_n(&H[l >> 3], SEQ); }
static inline void ast(int32_t l, int32_t v) { __atomic_store_n(&H[l >> 3], v, SEQ); }
static inline int32_t acas(int32_t l, int32_t e, int32_t d) { __atomic_compare_exchange_n(&H[l >> 3], &e, d, 0, SEQ, SEQ); return e; }
static inline int32_t axchg(int32_t l, int32_t v) { return __atomic_exchange_n(&H[l >> 3], v, SEQ); }
static inline int32_t faa(int32_t l, int32_t d) {
  int32_t old = __atomic_fetch_add(&H[l >> 3], d, SEQ), r;
  if (__builtin_add_overflow(old, d, &r)) ovf();
  return old;
}
static inline void futexWait(int32_t l, int32_t v) { if ((l & 7) == 1) fwait(&H[l >> 3], v, WAIT_MS); }
static inline void futexWake(int32_t l) { if ((l & 7) == 1) fwake(&H[l >> 3], 1); }

static int32_t hl_fork(int32_t clo) {
  int32_t i = __atomic_fetch_add(&H[C_QTAIL], 1, SEQ);
  if (i - __atomic_load_n(&H[C_QHEAD], SEQ) >= QCAP) stuck("fork queue overflow");
  int32_t *slot = &H[QBASE + (i & (QCAP - 1))];
  int32_t z = 0;
  while (!__atomic_compare_exchange_n(slot, &z, clo, 0, SEQ, SEQ)) { fwait(slot, z, 1.0); z = 0; }
  fwake(slot, 1);
  __atomic_fetch_add(&H[C_FORKS], 1, SEQ);
  if (i >= __atomic_load_n(&H[C_QHEAD], SEQ)) __atomic_fetch_add(&H[C_GROW], 1, SEQ);  // no growth in C: counted only
  return UNIT;
}
