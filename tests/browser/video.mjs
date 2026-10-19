// Browser test for the video lab (examples/Video.lean, built to dist/editor/video): a video made in
// the page (an animated canvas recorded by MediaRecorder: no binary fixture) is opened through the
// file input (FILE_URL), played, and every frame is grabbed (FRAME_GRAB), filtered in Lean and
// drawn. Checks the pixels against the frame the video shows, that a paused video is not filtered
// again, and with --perf measures the frames filtered and drawn per second for every filter at
// three sizes (a 30 fps source), with the time per frame of the grab and of the Lean side.
//   node tests/browser/video.mjs <url of dist/editor/video/index.html> [chromium|firefox] [--perf] [--out file.json]
import { pw } from "./playwright.mjs";
import fs from "node:fs";

const args = process.argv.slice(2);
const url = args.find((a) => a.startsWith("http")) || "http://127.0.0.1:5331/editor/video/index.html";
const engine = args.find((a) => a === "chromium" || a === "firefox") || "chromium";
const perf = args.includes("--perf");
const oi = args.indexOf("--out"), out = oi >= 0 ? args[oi + 1] : null;
const browser = await pw[engine].launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
const errors = [], checks = [];
page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
page.on("console", (m) => { if (m.type() === "error" || (m.type() === "warning" && m.text().includes("LeanUI"))) errors.push("console: " + m.text()); });
const check = (name, ok, detail = "") => { checks.push({ name, ok: !!ok, detail: ok ? undefined : detail }); };
const text = (id) => page.$eval("#" + id, (e) => e.textContent);
const frames = async () => +(await text("vid-frames"));
const until = async (f, ms = 10000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (await f()) return true; await page.waitForTimeout(50); } return false; };
const setFilter = (key) => page.evaluate((key) => { const s = document.querySelector("#vid-filter"); s.value = key; s.dispatchEvent(new Event("change", { bubbles: true })); }, key);

await page.goto(url);
await page.waitForFunction(() => window.__leanui, null, { timeout: 30000 });
check("boot", (await text("vid-status")) === "Choose a video file.", await text("vid-status"));

// time each grab (FRAME_GRAB to its reply) and each reply's Lean side (bytes into wasm, the
// update with the filter, the view, and the drawing), keyed by the frame's timestamp
await page.evaluate(() => {
  const rt = window.__leanui, grab = rt.grabFrame, tr = rt.transport, reply = tr.callbackBytes.bind(tr), starts = new Map();
  window.__log = [];
  rt.grabFrame = function (cb, sel) { starts.set(cb, performance.now()); return grab.call(this, cb, sel); };
  tr.callbackBytes = (cb, ok, payload, bytes) => {
    const t1 = performance.now(), s = starts.get(cb);
    reply(cb, ok, payload, bytes);
    if (s !== undefined) { starts.delete(cb); window.__log.push({ at: t1, grab: t1 - s, lean: performance.now() - t1, ok, t: ok ? payload.split(" ")[2] : null }); }
  };
});

// a w×h WebM video of `seconds` at 30 fps: a gradient, a bar sweeping across, the frame number.
// Encoded offline by WebCodecs (VP8, exact timestamps, a keyframe a second) into a minimal WebM
// file; where VideoEncoder is missing, recorded in real time by MediaRecorder, which drops frames
// when the page is busy (the lab's video is paused meanwhile) or the encoder is slow.
async function makeVideo(w, h, seconds) {
  return page.evaluate(async ([w, h, seconds]) => {
    document.querySelector("#vid-src").pause();
    const c = document.createElement("canvas"); c.width = w; c.height = h;
    const ctx = c.getContext("2d");
    const draw = (n) => {
      const g = ctx.createLinearGradient(0, 0, w, h); g.addColorStop(0, "#1e3a8a"); g.addColorStop(1, "#f59e0b");
      ctx.fillStyle = g; ctx.fillRect(0, 0, w, h);
      ctx.fillStyle = "#e11d48"; ctx.fillRect(((n / 100) % 1) * w, 0, w / 10, h);
      ctx.fillStyle = "#f8fafc"; ctx.font = `${Math.round(h / 5)}px sans-serif`; ctx.fillText(String(n), w / 20, h / 4);
    };
    const name = `test-${w}x${h}.webm`, bitrate = Math.round(w * h * 30 * 0.15), count = seconds * 30;
    const config = { codec: "vp8", width: w, height: h, bitrate, framerate: 30 };
    if (typeof VideoEncoder === "function" && (await VideoEncoder.isConfigSupported(config)).supported) {
      const chunks = [];
      const enc = new VideoEncoder({ output: (ch) => { const d = new Uint8Array(ch.byteLength); ch.copyTo(d); chunks.push({ key: ch.type === "key", ms: Math.round(ch.timestamp / 1000), d }); },
                                     error: (e) => { throw e; } });
      enc.configure(config);
      for (let n = 0; n < count; n++) {
        draw(n);
        const f = new VideoFrame(c, { timestamp: Math.round(n * 1e6 / 30) });
        enc.encode(f, { keyFrame: n % 30 === 0 }); f.close();
        while (enc.encodeQueueSize > 4) await new Promise((r) => setTimeout(r, 1));
      }
      await enc.flush(); enc.close();
      // WebM (Matroska): EBML header, then a segment with the track and one cluster per keyframe
      const bytes = (n, k) => Array.from({ length: k }, (_, i) => Math.floor(n / 2 ** (8 * (k - 1 - i))) & 255);
      const uint = (n) => bytes(n, Math.max(1, Math.ceil(Math.log2(n + 1) / 8)));
      const el = (id, body) => [...bytes(id, Math.ceil(Math.log2(id + 1) / 8)), 1, ...bytes(body.length, 7), ...body];
      const str = (s) => [...new TextEncoder().encode(s)];
      const f64 = (x) => { const b = new DataView(new ArrayBuffer(8)); b.setFloat64(0, x); return [...new Uint8Array(b.buffer)]; };
      const clusters = [];
      for (const ch of chunks) {
        if (ch.key || !clusters.length) clusters.push({ ms: ch.ms, blocks: [] });
        const cl = clusters.at(-1), rel = ch.ms - cl.ms;
        cl.blocks.push(el(0xA3, [0x81, (rel >> 8) & 255, rel & 255, ch.key ? 0x80 : 0, ...ch.d]));
      }
      const file = [
        ...el(0x1A45DFA3, [...el(0x4286, uint(1)), ...el(0x42F7, uint(1)), ...el(0x42F2, uint(4)), ...el(0x42F3, uint(8)),
          ...el(0x4282, str("webm")), ...el(0x4287, uint(2)), ...el(0x4285, uint(2))]),
        ...el(0x18538067, [
          ...el(0x1549A966, [...el(0x2AD7B1, uint(1e6)), ...el(0x4D80, str("leanui test")), ...el(0x5741, str("leanui test")),
            ...el(0x4489, f64(count * 1000 / 30))]),
          ...el(0x1654AE6B, el(0xAE, [...el(0xD7, uint(1)), ...el(0x73C5, uint(1)), ...el(0x83, uint(1)), ...el(0x86, str("V_VP8")),
            ...el(0xE0, [...el(0xB0, uint(w)), ...el(0xBA, uint(h))])])),
          ...clusters.flatMap((cl) => el(0x1F43B675, [...el(0xE7, uint(cl.ms)), ...cl.blocks.flat()]))])];
      window.__file = new File([new Uint8Array(file)], name, { type: "video/webm" });
      return "VideoEncoder";
    }
    const type = ["video/webm;codecs=vp8", "video/webm;codecs=vp9", "video/webm"].find((t) => MediaRecorder.isTypeSupported(t));
    const rec = new MediaRecorder(c.captureStream(30), { mimeType: type, videoBitsPerSecond: bitrate });
    const chunks = [];
    rec.ondataavailable = (e) => chunks.push(e.data);
    const stopped = new Promise((r) => (rec.onstop = r));
    rec.start();
    const t0 = performance.now();
    await new Promise((resolve) => (function frame() {
      const t = (performance.now() - t0) / 1000;
      draw(Math.floor(t * 30));
      if (t < seconds) requestAnimationFrame(frame); else resolve();
    })());
    rec.stop(); await stopped;
    window.__file = new File([new Blob(chunks, { type: "video/webm" })], name, { type: "video/webm" });
    return "MediaRecorder";
  }, [w, h, seconds]);
}
// the frames per second the file presents when played on its own (requestVideoFrameCallback)
async function sourceFps() {
  return page.evaluate(async () => {
    const v = document.createElement("video"); v.muted = true; v.src = URL.createObjectURL(window.__file);
    document.body.append(v);
    await v.play();
    const ts = [];
    await new Promise((done) => {
      const f = (now) => { ts.push(now); if (now - ts[0] < 1500) v.requestVideoFrameCallback(f); else done(); };
      v.requestVideoFrameCallback(f);
    });
    v.remove(); URL.revokeObjectURL(v.src);
    return (ts.length - 1) * 1000 / (ts.at(-1) - ts[0]);
  });
}
async function openVideo() {
  await page.evaluate(() => {
    const dt = new DataTransfer(); dt.items.add(window.__file);
    const input = document.querySelector("#vid-file"); input.files = dt.files;
    input.dispatchEvent(new Event("change", { bubbles: true }));
  });
}

// ---- the pipeline, on a small video ----
await makeVideo(320, 180, 2);
await openVideo();
check("plays", await until(async () => (await frames()) > 5), `${await frames()} frames, status ${await text("vid-status")}`);
check("status", (await text("vid-status")).startsWith("Playing test-320x180.webm"), await text("vid-status"));
check("size", (await text("vid-size")) === "320×180", await text("vid-size"));
check("canvas size", (await page.$eval("#vid-out", (c) => c.width + "x" + c.height)) === "320x180");
check("object URL", (await page.$eval("#vid-src", (v) => v.src)).startsWith("blob:"));

// paused: the frame shown is filtered once, then not again
await page.evaluate(() => document.querySelector("#vid-src").pause());
await page.waitForTimeout(400);
let n0 = await frames();
await page.waitForTimeout(700);
check("paused: no new frames", (await frames()) === n0, `${n0} -> ${await frames()}`);

// the output against the frame the video shows (drawn on a 2D canvas: the RGBA conversion may
// differ from VideoFrame.copyTo's by a little)
async function compare(fn) {
  return page.evaluate(async (fn) => {
    const v = document.querySelector("#vid-src"), o = document.querySelector("#vid-out");
    const w = o.width, h = o.height, c = new OffscreenCanvas(w, h), ctx = c.getContext("2d");
    ctx.drawImage(v, 0, 0, w, h);
    const want = ctx.getImageData(0, 0, w, h).data, got = o.getContext("2d").getImageData(0, 0, w, h).data;
    const f = new Function("v", "i", fn);
    let sum = 0, max = 0;
    for (let i = 0; i < want.length; i++) { if ((i & 3) === 3) continue; const d = Math.abs(got[i] - f(want, i)); sum += d; if (d > max) max = d; }
    return { mean: sum / (want.length * 0.75), max };
  }, fn);
}
const none = await compare("return v[i];");
check("filter none: the frame", none.mean < 2.5, JSON.stringify(none));
n0 = await frames();
await setFilter("invert");
check("a new filter refilters the paused frame", await until(async () => (await frames()) === n0 + 1), `${n0} -> ${await frames()}`);
const inv = await compare("return 255 - v[i];");
check("filter invert", inv.mean < 2.5, JSON.stringify(inv));
await setFilter("mono");
await until(async () => (await frames()) === n0 + 2);
const mono = await page.$eval("#vid-out", (o) => {
  const d = o.getContext("2d").getImageData(0, 0, o.width, o.height).data; let gray = 0;
  for (let i = 0; i < d.length; i += 4) if (d[i] === d[i + 1] && d[i + 1] === d[i + 2]) gray++;
  return gray / (d.length / 4);
});
check("filter mono: gray pixels", mono > 0.999, mono);
await page.evaluate(() => document.querySelector("#vid-src").play());
for (const key of ["vivid", "blur", "sharpen", "edges", "emboss", "none"]) {
  await setFilter(key);
  const n = await frames();
  check(`filter ${key} runs`, await until(async () => (await frames()) >= n + 2), `${n} -> ${await frames()}`);
}
const grabs = await page.evaluate(() => window.__log.length);
check("grabs replied", grabs > 0 && (await page.evaluate(() => window.__log.every((e) => e.ok || e.t === null))));

// ---- frames per second per filter, 30 fps sources ----
const results = { engine, version: browser.version(), url, sizes: {} };
if (perf) {
  const FILTERS = ["none", "vivid", "mono", "invert", "blur", "sharpen", "edges", "emboss"];
  for (const [w, h] of [[640, 360], [1280, 720], [1920, 1080]]) {
    console.error(`[${engine}] ${w}×${h}`);
    results.made = await makeVideo(w, h, 4);
    const source = await sourceFps();
    await openVideo();
    await until(async () => (await text("vid-size")) === `${w}×${h}`);
    const row = { source: +source.toFixed(1) };
    for (const key of FILTERS) {
      await setFilter(key);
      await page.waitForTimeout(600);
      const r = await page.evaluate(async () => {
        const n = () => +document.querySelector("#vid-frames").textContent;
        const a = n(), t0 = performance.now(), from = window.__log.length;
        await new Promise((r) => setTimeout(r, 3000));
        const b = n(), t1 = performance.now(), log = window.__log.slice(from).filter((e) => e.ok);
        // filtered frames: replies with a new timestamp (the lab skips a frame it already showed)
        const fresh = log.filter((e, i) => i > 0 && e.t !== log[i - 1].t);
        const med = (xs) => { const s = [...xs].sort((p, q) => p - q); return s.length ? s[Math.floor(s.length / 2)] : null; };
        return { fps: (b - a) * 1000 / (t1 - t0), grabMs: med(fresh.map((e) => e.grab)), leanMs: med(fresh.map((e) => e.lean)), filtered: fresh.length };
      });
      row[key] = { fps: +r.fps.toFixed(1), grabMs: r.grabMs && +r.grabMs.toFixed(1), leanMs: r.leanMs && +r.leanMs.toFixed(1) };
    }
    results.sizes[`${w}×${h}`] = row;
  }
}
results.errors = errors;
await browser.close();

if (perf) {
  const sizes = Object.keys(results.sizes);
  console.log(`| filter | ${sizes.map((s) => s + " fps · grab ms · Lean ms").join(" | ")} |\n|---|${sizes.map(() => "--:").join("|")}|`);
  console.log(`| the video alone (fps) | ${sizes.map((s) => results.sizes[s].source).join(" | ")} |`);
  for (const key of Object.keys(results.sizes[sizes[0]]).filter((k) => k !== "source"))
    console.log(`| ${key} | ${sizes.map((s) => { const r = results.sizes[s][key]; return `${r.fps} · ${r.grabMs} · ${r.leanMs}`; }).join(" | ")} |`);
  if (out) fs.writeFileSync(out, JSON.stringify(results, null, 1));
}
for (const e of errors) check("no page errors", false, e);
const failed = checks.filter((c) => !c.ok);
for (const c of failed) console.log(`FAIL ${c.name} ${JSON.stringify(c.detail)}`);
console.log(`video (${engine}): ${checks.length - failed.length} of ${checks.length} checks passed`);
process.exit(failed.length ? 1 : 0);
