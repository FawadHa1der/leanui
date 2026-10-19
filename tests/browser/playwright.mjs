// Playwright for the browser tests. LEANUI_PLAYWRIGHT_FROM names a package.json whose node_modules
// holds Playwright (CI installs one outside the checkout); otherwise it resolves from this checkout,
// then from the QED64 checkout next to it, where the development machine keeps its copy.
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";

const from = [process.env.LEANUI_PLAYWRIGHT_FROM, import.meta.url,
  path.join(os.homedir(), "code/wasm64-lean-fable/qed64/package.json")];

function load() {
  for (const f of from) {
    if (!f) continue;
    try { return createRequire(f)("playwright"); } catch (e) { if (e.code !== "MODULE_NOT_FOUND") throw e; }
  }
  throw new Error("Playwright not found: set LEANUI_PLAYWRIGHT_FROM to a package.json whose node_modules has playwright");
}

export const pw = load();
