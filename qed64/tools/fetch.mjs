// Download what qed64.lock.json pins for the build, verify every byte, and put it where the build
// reads it (qed64/README.md):
//   <cache>/rt/lean.js, lean.wasm   QED64's runtime, assembled from its chunks; package.json
//                                   beside them (Node's pthreads load lean.js as CommonJS)
//   <cache>/rt/LICENSE-*            the licences that ship with it
//   <cache>/init/                   Init: QED64's lean-core pack (653 modules, every facet), unpacked
// <cache> is qed64/.cache, or $LEANUI_QED64_CACHE (one cache for several checkouts). What is
// already in place with its pinned digest is not fetched again; nothing else is kept (no chunk or
// pack part is stored). Each chunk and part is checked (size and sha256) as it arrives, then each
// whole file and the unpacked pack; any mismatch stops with status 1.
//   node qed64/tools/fetch.mjs        (Node 24; NODE_USE_ENV_PROXY=1 behind an HTTPS proxy)
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const Q = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const lock = JSON.parse(fs.readFileSync(path.join(Q, "qed64.lock.json"), "utf8"));
const C = path.resolve(process.env.LEANUI_QED64_CACHE || path.join(Q, ".cache"));
const sha = (b) => crypto.createHash("sha256").update(b).digest("hex");
const say = (s) => process.stderr.write(`fetch: ${s}\n`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fetched = 0;

// One pinned file, [path, bytes, sha256], from the first source that serves the right bytes
// (each source tried three times: GitHub's release downloads fail now and then)
async function get([rel, bytes, digest], urls = lock.sources.map((s) => s.replace("{name}", path.basename(rel)).replace("{path}", rel))) {
  const why = [];
  for (const url of urls) {
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        const res = await fetch(url);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const b = Buffer.from(await res.arrayBuffer());
        if (b.length !== bytes || sha(b) !== digest) throw new Error(`${b.length} bytes, sha256 ${sha(b)}; the lock pins ${bytes}, ${digest}`);
        fetched += b.length;
        return b;
      } catch (e) { why.push(`${url}: ${e.message}`); await sleep(1000 * attempt); }
    }
  }
  throw new Error(`cannot fetch ${rel}:\n  ${why.join("\n  ")}`);
}

const fileOk = (p, bytes, digest) => { try { return fs.statSync(p).size === bytes && sha(fs.readFileSync(p)) === digest; } catch (e) { return false; } };
const put = (p, b) => { fs.writeFileSync(p + ".tmp", b); fs.renameSync(p + ".tmp", p); };

async function runtime() {
  const rt = path.join(C, "rt");
  fs.mkdirSync(rt, { recursive: true });
  for (const [name, f] of Object.entries(lock.runtime)) {
    const p = path.join(rt, name);
    if (fileOk(p, f.bytes, f.sha256)) continue;
    const parts = [];
    for (const c of f.chunks) parts.push(await get(c));
    const b = Buffer.concat(parts);
    if (b.length !== f.bytes || sha(b) !== f.sha256) throw new Error(`${name}: its chunks make ${b.length} bytes, sha256 ${sha(b)}; the lock pins ${f.bytes}, ${f.sha256}`);
    put(p, b);
    say(`${name}: ${b.length} bytes`);
  }
  put(path.join(rt, "package.json"), '{ "type": "commonjs" }\n');
  for (const [name, [url, bytes, digest]] of Object.entries(lock.licences)) {
    const p = path.join(rt, name);
    if (!fileOk(p, bytes, digest)) put(p, await get([name, bytes, digest], [url]));
  }
}

// The pack is one gzip stream over its parts; the manifest's table says where each file lies in
// the unpacked stream. Unpacked into init.tmp/, then renamed, so init/ is complete or absent.
async function init() {
  const dir = path.join(C, "init"), stamp = path.join(dir, ".pack-sha256");
  const { pack, transport } = lock.init;
  if (fs.existsSync(stamp) && fs.readFileSync(stamp, "utf8").trim() === pack.sha256) return;
  const manifest = JSON.parse(await get(lock.init.manifest)).content;
  if (manifest.pack.digest !== "sha256:" + pack.sha256) throw new Error("the lean-core manifest describes another pack");
  const files = manifest.workerfs.metadata.files.slice().sort((a, b) => a.start - b.start);
  const tmp = dir + ".tmp";
  fs.rmSync(tmp, { recursive: true, force: true });
  const gunzip = zlib.createGunzip(), raw = crypto.createHash("sha256"), whole = crypto.createHash("sha256");
  let pos = 0, fi = 0, fd = null;
  gunzip.on("data", (chunk) => {
    raw.update(chunk);
    let off = 0;
    while (off < chunk.length && fi < files.length) {
      const f = files[fi];
      if (pos + off < f.start) { off = Math.min(chunk.length, f.start - pos); continue; }
      if (fd === null) { const p = path.join(tmp, f.filename); fs.mkdirSync(path.dirname(p), { recursive: true }); fd = fs.openSync(p, "w"); }
      const n = Math.min(chunk.length - off, f.end - (pos + off));
      fs.writeSync(fd, chunk, off, n); off += n;
      if (pos + off >= f.end) { fs.closeSync(fd); fd = null; fi++; }
    }
    pos += chunk.length;
  });
  const ended = new Promise((ok, no) => { gunzip.on("end", ok); gunzip.on("error", no); });
  for (const part of transport.parts) {
    const b = await get(part);
    whole.update(b);
    await new Promise((ok) => (gunzip.write(b) ? ok() : gunzip.once("drain", ok)));
  }
  gunzip.end();
  await ended;
  if (whole.digest("hex") !== transport.sha256) throw new Error("lean-core: the parts do not make the pinned transport");
  if (pos !== pack.bytes || raw.digest("hex") !== pack.sha256 || fi !== files.length) throw new Error(`lean-core: unpacked ${pos} bytes into ${fi} of ${files.length} files; the lock pins ${pack.bytes} bytes, sha256 ${pack.sha256}`);
  fs.writeFileSync(path.join(tmp, ".pack-sha256"), pack.sha256 + "\n");
  fs.rmSync(dir, { recursive: true, force: true });
  fs.renameSync(tmp, dir);
  say(`init: ${files.length} files of ${pack.modules} modules, ${pos} bytes`);
}

try {
  const t = performance.now();
  await runtime();
  await init();
  if (fetched) say(`${(fetched / 1e6).toFixed(1)} MB downloaded in ${((performance.now() - t) / 1000).toFixed(1)} s`);
} catch (e) { say(e.message); process.exit(1); }
