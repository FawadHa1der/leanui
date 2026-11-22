// Which web APIs accept views of shared memory (what leanui.js hands them today)?
import http from "node:http";
import { createRequire } from "node:module";
const require = createRequire("/opt/node-tools/node_modules/");
const { chromium } = require("playwright");
const srv = http.createServer((q, s) => { s.writeHead(200, { "Content-Type": "text/html", "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp" }); s.end("<!doctype html><canvas id=c width=4 height=4></canvas>"); }).listen(0);
const b = await chromium.launch(); const p = await b.newPage();
await p.goto(`http://127.0.0.1:${srv.address().port}/`);
console.log(JSON.stringify(await p.evaluate(() => {
  const mem = new WebAssembly.Memory({ initial: 1, maximum: 10, shared: true });
  const u8 = new Uint8Array(mem.buffer, 0, 64); u8.set([104, 105]);
  const r = { crossOriginIsolated };
  const t = (name, f) => { try { r[name] = "ok: " + String(f()).slice(0, 20); } catch (e) { r[name] = "THROWS: " + e.message.slice(0, 90); } };
  t("TextDecoder.decode(shared view)", () => new TextDecoder().decode(u8.subarray(0, 2)));
  t("TextDecoder.decode(copy)", () => new TextDecoder().decode(u8.slice(0, 2)));
  t("new ImageData(shared view)", () => new ImageData(new Uint8ClampedArray(mem.buffer, 0, 64), 4, 4).width);
  t("new Blob([shared view])", () => new Blob([u8]).size);
  t("TextEncoder.encodeInto(shared view)", () => new TextEncoder().encodeInto("ab", u8).written);
  return r;
}), null, 1));
await b.close(); srv.close();
