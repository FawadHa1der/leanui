// In-page side of the editor benchmark (tests/browser/editor-bench.mjs injects it, after ops.js,
// into dist/editor-bench/index.html, the EditorBench app). It times one operation three ways on
// the same image, in the same browser process:
//   * Lean: the synchronous `input` event that carries `run OP` (update, view and diff in wasm,
//     then applying the small DOM patch; the view is three tiny elements and a canvas);
//   * JS: the call of EditorOps.run (bench/editor/ops.js), the same algorithm in plain JavaScript;
//   * canvas built-in, where one exists: a 2D canvas draw (ctx.filter, a transform, drawImage
//     scaling, globalCompositeOperation; not the same algorithm), then getImageData of the whole
//     result, which forces the drawing to complete and brings the pixels back to JavaScript.
//     Also recorded: the draw call alone (Chrome's canvas records draws and rasterises them on the
//     next flush, so this is the cost of issuing it), and the draw followed by a 1-pixel
//     getImageData (forces the work without the full readback).
(function (root) {
  "use strict";
  const E = root.EditorOps;
  const now = () => performance.now();
  const tick = () => new Promise((r) => setTimeout(r, 0));
  const st = { w: 0, h: 0 };

  // ---- Lean: commands through the app's <input id="cmd"> ----
  function lean(cmd) {
    const el = document.getElementById("cmd");
    const t0 = now();
    el.value = cmd;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    return now() - t0;
  }
  const text = (id) => document.getElementById(id).textContent;
  function leanSum() { lean("sum"); return text("sum"); }
  function wasmBytes() {
    const rt = root.__leanui;
    return { statsHeapBytes: rt.stats.heapBytes ?? null, memoryBytes: rt.transport?.mod?.HEAPU8?.buffer?.byteLength ?? null };
  }

  // ---- canvas helpers ----
  function canvas(w, h, attach = false) {
    const c = document.createElement("canvas");
    c.width = w; c.height = h;
    if (attach) { c.style.cssText = "width:64px;height:48px"; document.body.appendChild(c); }
    return { c, ctx: c.getContext("2d"), w, h };
  }
  // one destination canvas per operation and size, reused across runs (as an app keeps a work canvas)
  function dest(op, w, h) {
    const d = st.dest[op];
    if (d && d.w === w && d.h === h) return d;
    return (st.dest[op] = canvas(w, h));
  }
  function fresh(d) {
    const ctx = d.ctx;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1; ctx.globalCompositeOperation = "source-over"; ctx.filter = "none";
    ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = "low";
    ctx.clearRect(0, 0, d.w, d.h);
    return ctx;
  }
  function filtered(op, f) {
    const d = dest(op, st.w, st.h), ctx = fresh(d);
    ctx.filter = f; ctx.drawImage(st.srcBitmap, 0, 0); ctx.filter = "none";
    return d;
  }
  function transformed(op, w, h, setup) {
    const d = dest(op, w, h), ctx = fresh(d);
    setup(ctx); ctx.drawImage(st.srcBitmap, 0, 0);
    return d;
  }
  function scaled(op, w, h, quality) {
    const d = dest(op, w, h), ctx = fresh(d);
    ctx.imageSmoothingQuality = quality; ctx.drawImage(st.srcBitmap, 0, 0, w, h);
    return d;
  }
  function composited(op, mode) {
    const d = dest(op, st.w, st.h), ctx = fresh(d);
    ctx.drawImage(st.srcBitmap, 0, 0);
    ctx.globalAlpha = 0.6; ctx.globalCompositeOperation = mode; ctx.drawImage(st.topBitmap, 0, 0);
    return d;
  }

  /** Canvas built-in counterparts: what they do, and a function issuing the draw (returns the
      destination canvas) or, for PNG, a promise of the encoded blob. */
  const CANVAS = {
    "adjust-lut": ["filter brightness(1.1) contrast(1.15) (no gamma; CSS brightness scales, Lean adds)", () => filtered("adjust-lut", "brightness(1.1) contrast(1.15)")],
    "adjust-color": ["filter saturate(1.3) hue-rotate(20deg) (the same CSS matrices, in floating point)", () => filtered("adjust-color", "saturate(1.3) hue-rotate(20deg)")],
    "blur-2": ["filter blur(1px) (σ = 1, as Lean's radius 2)", () => filtered("blur-2", "blur(1px)")],
    "blur-8": ["filter blur(4px) (σ = 4, as Lean's radius 8)", () => filtered("blur-8", "blur(4px)")],
    "rotate-90": ["translate + rotate(90°) + drawImage", () => transformed("rotate-90", st.h, st.w, (c) => { c.translate(st.h, 0); c.rotate(Math.PI / 2); })],
    "rotate-180": ["translate + rotate(180°) + drawImage", () => transformed("rotate-180", st.w, st.h, (c) => { c.translate(st.w, st.h); c.rotate(Math.PI); })],
    "flip-h": ["translate + scale(-1, 1) + drawImage", () => transformed("flip-h", st.w, st.h, (c) => { c.translate(st.w, 0); c.scale(-1, 1); })],
    "flip-v": ["translate + scale(1, -1) + drawImage", () => transformed("flip-v", st.w, st.h, (c) => { c.translate(0, st.h); c.scale(1, -1); })],
    "resize-50": ["drawImage to half size, imageSmoothingQuality low (bilinear)", () => scaled("resize-50", Math.floor(st.w / 2), Math.floor(st.h / 2), "low")],
    "downscale-8": ["drawImage to 1/8 size, imageSmoothingQuality medium (mipmapped)", () => scaled("downscale-8", Math.floor(st.w / 8), Math.floor(st.h / 8), "medium")],
    "composite-normal": ["drawImage base, then top with globalAlpha 0.6, source-over", () => composited("composite-normal", "source-over")],
    "composite-overlay": ["drawImage base, then top with globalAlpha 0.6, overlay", () => composited("composite-overlay", "overlay")],
    "crop-half": ["drawImage of the centre quarter-area rectangle", () => {
      const x = Math.floor(st.w / 4), y = Math.floor(st.h / 4), w = Math.floor(st.w / 2), h = Math.floor(st.h / 2);
      const d = dest("crop-half", w, h), ctx = fresh(d);
      ctx.drawImage(st.srcBitmap, x, y, w, h, 0, 0, w, h);
      return d;
    }],
    "png-1": ["canvas.toBlob('image/png') (the browser's encoder, async: time until the blob arrives)", () =>
      new Promise((ok) => st.src.c.toBlob((b) => ok(b), "image/png"))],
  };

  /** One canvas run: [ms with the full readback, ms of the draw call alone] (PNG: [ms to the blob, same]). */
  async function canvasFull(op) {
    const t0 = now();
    const d = CANVAS[op][1]();
    const t1 = now();
    if (d instanceof Promise) { const b = await d; const t = now() - t0; st.blobBytes = b ? b.size : 0; return [t, t]; }
    d.ctx.getImageData(0, 0, d.w, d.h);
    return [now() - t0, t1 - t0];
  }
  /** One canvas run forced to complete by a 1-pixel readback (no full readback); null for PNG. */
  function canvasForced(op) {
    const t0 = now();
    const d = CANVAS[op][1]();
    if (d instanceof Promise) return null;
    d.ctx.getImageData(0, 0, 1, 1);
    return now() - t0;
  }

  // ---- per size ----
  async function setup(w, h) {
    st.img = st.top = st.out = st.src = st.srcBitmap = st.topBitmap = st.blit = null;
    st.dest = {};
    if (st.blitCanvas) { st.blitCanvas.c.remove(); st.blitCanvas = null; }
    await tick();
    st.w = w; st.h = h;
    const leanMakeMs = lean(`make ${w} ${h}`);
    const status = text("status");
    if (status !== `made ${w}x${h}`) throw new Error(`Lean make ${w} ${h}: status ${status}`);
    let t0 = now();
    st.img = E.testImage(w, h);
    st.top = E.translucent(st.img);
    const jsMakeMs = now() - t0;
    st.src = canvas(w, h);
    st.src.ctx.putImageData(new ImageData(st.img.data, w, h), 0, 0);
    st.srcBitmap = await createImageBitmap(st.src.c);
    st.topBitmap = await createImageBitmap(new ImageData(st.top.data, w, h));
    return { leanMakeMs, jsMakeMs, wasm: wasmBytes() };
  }

  /** Time operation `op`: one warm-up each, then `runs` interleaved runs (Lean, JS, canvas); at
      most `slowRuns` runs when a warm-up took longer than `slowMs`. */
  async function timeOp(op, runs, slowMs, slowRuns) {
    const hasCanvas = op in CANVAS;
    const r = { op, runs, reduced: false, lean: [], js: [], canvas: hasCanvas ? [] : null, canvasDraw: hasCanvas ? [] : null,
      canvasForced: hasCanvas && op !== "png-1" ? [] : null, canvasDesc: hasCanvas ? CANVAS[op][0] : null };
    // warm-up
    const wl = lean("run " + op);
    r.status = text("status");
    if (!r.status.startsWith(op + " ")) throw new Error(`Lean run ${op}: status ${r.status}`);
    await tick();
    let t0 = now();
    st.out = E.run(op, st.img, st.top);
    const wj = now() - t0;
    r.jsN = st.out.n; r.jsOut = st.out.out ? `${st.out.out.width}x${st.out.out.height}` : null;
    await tick();
    let wc = null;
    if (hasCanvas) { wc = (await canvasFull(op))[0]; if (r.canvasForced) canvasForced(op); await tick(); }
    r.warm = { lean: wl, js: wj, canvas: wc };
    if (Math.max(wl, wj, wc || 0) > slowMs && runs > slowRuns) { r.runs = slowRuns; r.reduced = true; }
    for (let i = 0; i < r.runs; i++) {
      r.lean.push(lean("run " + op));
      await tick();
      t0 = now();
      st.out = E.run(op, st.img, st.top);
      r.js.push(now() - t0);
      await tick();
      if (hasCanvas) {
        const [full, draw] = await canvasFull(op);
        r.canvas.push(full); r.canvasDraw.push(draw);
        await tick();
        if (r.canvasForced) { r.canvasForced.push(canvasForced(op)); await tick(); }
      }
    }
    if (op === "png-1" && hasCanvas) r.canvasBlobBytes = st.blobBytes;
    return r;
  }

  /** Lean `blit` (Cmd.drawBitmap: putImageData of the image from wasm memory onto #bench-canvas)
      against JS putImageData of the same pixels onto a canvas of the same size, also in the page. */
  async function timeBlit(runs) {
    st.blitCanvas = canvas(st.w, st.h, true);
    const ctx = st.blitCanvas.ctx;
    const js = () => { const t0 = now(); ctx.putImageData(new ImageData(st.img.data, st.w, st.h), 0, 0); return now() - t0; };
    const r = { op: "blit", runs, lean: [], js: [], warm: { lean: lean("blit") } };
    await tick();
    r.warm.js = js();
    await tick();
    for (let i = 0; i < runs; i++) {
      r.lean.push(lean("blit")); await tick();
      r.js.push(js()); await tick();
    }
    return r;
  }

  /** getImageData of the whole (already drawn) source canvas: the readback alone. */
  async function timeReadback(runs) {
    const out = [];
    st.src.ctx.getImageData(0, 0, 1, 1);
    for (let i = 0; i < runs; i++) { const t0 = now(); st.src.ctx.getImageData(0, 0, st.w, st.h); out.push(now() - t0); await tick(); }
    return out;
  }

  /** Checksums of every operation's result, Lean (`sum`, `#status`) against JS, on a w x h image;
      and whether the canvas built-in gives the same pixels. */
  async function verify(w, h) {
    await setup(w, h);
    const rows = [];
    for (const op of E.OPS) {
      lean("run " + op);
      const status = text("status"), sum = leanSum();
      const [, dims, n] = status.split(" ");
      const r = E.run(op, st.img, st.top);
      let kind, lv, jv, canvasSame = null;
      if (r.out) {
        kind = "checksum"; lv = `${dims} ${sum}`; jv = `${r.out.width}x${r.out.height} ${E.checksum(r.out)}`;
        if (op in CANVAS) {
          const d = CANVAS[op][1]();
          const px = d.ctx.getImageData(0, 0, d.w, d.h).data;
          canvasSame = E.checksum(E.image(d.w, d.h, px)) === E.checksum(r.out);
        }
      }
      else if (op === "histogram") { kind = "sum of the counts"; lv = n; jv = String(r.n); }
      else { kind = "PNG size (bytes)"; lv = n; jv = String(r.n); }
      rows.push({ op, kind, lean: lv, js: jv, match: lv === jv, canvasSame });
    }
    return rows;
  }

  /** What renders the canvas: the WebGL renderer string (no GPU here: none or a software one). */
  function gpuInfo() {
    try {
      const gl = document.createElement("canvas").getContext("webgl");
      if (!gl) return "no WebGL";
      const ext = gl.getExtension("WEBGL_debug_renderer_info");
      return ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
    } catch (e) { return "WebGL error: " + e.message; }
  }

  root.EditorBenchPage = { setup, timeOp, timeBlit, timeReadback, verify, gpuInfo, wasmBytes, canvasOps: Object.keys(CANVAS) };
})(globalThis);
