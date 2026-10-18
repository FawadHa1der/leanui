// A Lean-shaped workload for comparing wasm32 and wasm64 code generation (bench/wasm64/build.sh).
// A Lean-like workload: allocate small reference-counted trees, walk and compare them, free them.
#include <stdlib.h>
#include <stdint.h>
#include <emscripten.h>
typedef struct Node { int rc; int tag; struct Node *kids[4]; int nkids; uint32_t val; } Node;
static uint64_t seed = 42;
static uint32_t rnd(void) { seed = seed * 6364136223846793005ULL + 1442695040888963407ULL; return (uint32_t)(seed >> 33); }
static Node *mk(int depth) {
  Node *n = malloc(sizeof(Node)); n->rc = 1; n->tag = depth; n->val = rnd(); n->nkids = depth > 0 ? 3 : 0;
  for (int i = 0; i < n->nkids; i++) n->kids[i] = mk(depth - 1);
  return n;
}
static void dec(Node *n) { if (--n->rc == 0) { for (int i = 0; i < n->nkids; i++) dec(n->kids[i]); free(n); } }
static int same(Node *a, Node *b) {
  if (a->tag != b->tag || a->nkids != b->nkids || (a->val & 7) != (b->val & 7)) return 0;
  for (int i = 0; i < a->nkids; i++) if (!same(a->kids[i], b->kids[i])) return 0;
  return 1;
}
EMSCRIPTEN_KEEPALIVE double run(int iters) {
  double t0 = emscripten_get_now(); int acc = 0;
  for (int i = 0; i < iters; i++) {
    Node *rows[200];
    for (int r = 0; r < 200; r++) rows[r] = mk(3);
    for (int r = 1; r < 200; r++) acc += same(rows[r - 1], rows[r]);
    for (int r = 0; r < 200; r++) dec(rows[r]);
  }
  return (emscripten_get_now() - t0) + (acc & 0);
}
