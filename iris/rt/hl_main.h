// The thread pool and driver for translated C programs; the translation unit includes it last.
//   ./prog [pool=4] [runs=3] [heapMB=256]   prints one JSON line, like run.mjs --json
// The pool is fixed (the JS launcher grows its own): a program needing more simultaneously live
// HeapLang threads than the pool can hang, which is liveness; it cannot compute a wrong value.
static double now_ms(void) {
#ifdef __EMSCRIPTEN__
  return emscripten_get_now();
#else
  struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
#endif
}

static void decode(char *out, size_t cap, int32_t w, int depth) {
  if (depth > 32) { snprintf(out, cap, "..."); return; }
  char a[512], b[512];
  switch (w & 7) {
    case 0: snprintf(out, cap, "%d", w >> 3); return;
    case 1: snprintf(out, cap, "#loc%d", w >> 3); return;
    case 2: case 3: decode(a, sizeof a, w - 2, depth + 1); snprintf(out, cap, "injl(%s)", a); return;
    case 4: case 5: decode(a, sizeof a, w - 4, depth + 1); snprintf(out, cap, "injr(%s)", a); return;
    case 7: {
      static const char *lits[] = {"()", "false", "true", "poison"};
      const char *l = lits[(w >> 3) & 3]; int inj = (w >> 5) & 3;
      if (inj == 1) snprintf(out, cap, "injl(%s)", l); else if (inj == 2) snprintf(out, cap, "injr(%s)", l); else snprintf(out, cap, "%s", l);
      return;
    }
    case 6: {
      int32_t p = w >> 3, h = H[p];
      if (h == HDR_PAIR) { decode(a, sizeof a, H[p + 1], depth + 1); decode(b, sizeof b, H[p + 2], depth + 1); snprintf(out, cap, "(%s, %s)", a, b); }
      else if (h == HDR_INJL) { decode(a, sizeof a, H[p + 1], depth + 1); snprintf(out, cap, "injl(%s)", a); }
      else if (h == HDR_INJR) { decode(a, sizeof a, H[p + 1], depth + 1); snprintf(out, cap, "injr(%s)", a); }
      else snprintf(out, cap, "<closure code %d>", h >> 3);
      return;
    }
  }
}

static void *pool_thread(void *arg) {
  (void)arg;
  for (;;) {
    int32_t j = __atomic_fetch_add(&H[C_QHEAD], 1, SEQ);
    int32_t *slot = &H[QBASE + (j & (QCAP - 1))];
    int32_t c;
    while ((c = __atomic_load_n(slot, SEQ)) == 0) fwait(slot, 0, 1000.0);
    __atomic_store_n(slot, 0, SEQ);
    fwake(slot, 1);
    int32_t live = __atomic_add_fetch(&H[C_LIVE], 1, SEQ), m;
    while (live > (m = __atomic_load_n(&H[C_MAXLIVE], SEQ)) && !__atomic_compare_exchange_n(&H[C_MAXLIVE], &m, live, 0, SEQ, SEQ));
    int32_t r = hl_FUNS[H[c >> 3] >> 3](c, UNIT);
    __atomic_sub_fetch(&H[C_LIVE], 1, SEQ);
    if (c == hl_MAIN) {
      __atomic_store_n(&H[C_RESULT], r, SEQ);
      __atomic_store_n(&H[C_DONE], 1, SEQ);
      fwake(&H[C_DONE], 1);
    }
  }
  return 0;
}

int main(int argc, char **argv) {
  int pool = argc > 1 ? atoi(argv[1]) : 4, runs = argc > 2 ? atoi(argv[2]) : 3, mb = argc > 3 ? atoi(argv[3]) : 256;
  H_LEN = (int64_t)mb * 1024 * 1024 / 4;
  H = (int32_t *)calloc((size_t)H_LEN, 4);
  if (!H) { fprintf(stderr, "calloc failed\n"); return 3; }
  memcpy(&H[STATIC_BASE], hl_STATICS, sizeof(int32_t) * hl_NSTATICS);
  __atomic_store_n(&H[C_BRK], (STATIC_BASE + hl_NSTATICS + 1024) & ~1023, SEQ);
  __atomic_store_n(&H[C_READY], 1, SEQ);
  pthread_attr_t attr; pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, (size_t)8 << 20);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  for (int i = 0; i < pool; i++) { pthread_t t; if (pthread_create(&t, &attr, pool_thread, 0)) { fprintf(stderr, "pthread_create failed\n"); return 3; } }
  double times[64]; int nt = 0;
  for (int r = 0; r < runs && r < 64; r++) {
    __atomic_store_n(&H[C_DONE], 0, SEQ);
    double t0 = now_ms();
    hl_fork(hl_MAIN);
    while (__atomic_load_n(&H[C_DONE], SEQ) == 0) fwait(&H[C_DONE], 0, 100.0);
    times[nt++] = now_ms() - t0;
  }
  for (int i = 1; i < nt; i++) for (int k = i; k > 0 && times[k] < times[k - 1]; k--) { double x = times[k]; times[k] = times[k - 1]; times[k - 1] = x; }
  static char res[4096];
  decode(res, sizeof res, __atomic_load_n(&H[C_RESULT], SEQ), 0);
  printf("{\"program\":\"%s\",\"result\":\"%s\",\"median_ms\":%.3f,\"min_ms\":%.3f,\"pool\":%d,\"forks\":%d,\"max_live\":%d,\"heap_cells_used\":%d}\n",
         hl_NAME, res, times[nt / 2], times[0], pool, H[C_FORKS], H[C_MAXLIVE], H[C_BRK]);
  fflush(stdout);
  _Exit(0);
}
