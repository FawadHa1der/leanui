// The photo editor's image operations in plain JavaScript: the same algorithms and parameters as
// the Lean core (examples/Editor/*.lean), written the way a competent developer writes them
// without heroic optimisation: typed arrays and straightforward loops, no WebGL, SIMD or workers.
// Every operation is integer-exact where the Lean code is, and produces the same bytes (checked by
// bench/editor/check-goldens.mjs against the goldens of tests/Editor.lean, and in the browser by
// tests/browser/editor-bench.mjs against the wasm build).
//
// An image is { width, height, data: Uint8ClampedArray } with the DOM's ImageData layout (RGBA,
// straight alpha), so a buffer goes to and from a canvas without conversion.
//
// Usable from Node (`require` / `import` of the CommonJS export) and in a page (globalThis.EditorOps).
(function (root) {
  "use strict";

  const image = (width, height, data) => ({ width, height, data: data || new Uint8ClampedArray(4 * width * height) });
  const copy = (img) => image(img.width, img.height, img.data.slice());

  // x / 255 rounded to nearest (halves up), exact for every x <= 65535 (Editor.div255)
  const div255 = (x) => { const t = x + 128; return (t + (t >>> 8)) >>> 8; };
  const clamp255 = (v) => (v > 255 ? 255 : v);
  // a float clamped to 0..255 and rounded to the nearest byte (Editor.toByte)
  const toByte = (v) => (v <= 0 ? 0 : v >= 255 ? 255 : (v + 0.5) | 0);
  // C round(): halves away from zero (Lean's Float.round)
  const cRound = (v) => (v < 0 ? -Math.round(-v) : Math.round(v));

  // ---------------------------------------------------------------------------------------------
  // Checksum (Image.checksum): FNV-1a 64-bit over width and height (4 little-endian bytes each)
  // and the pixel bytes, as a decimal string. The 64-bit state is kept as two 32-bit halves:
  // h * (2^40 + 0x1b3) mod 2^64 = h * 0x1b3 + (lo << 40).

  function fnvInit() { return [0xcbf29ce4, 0x84222325]; }
  function fnvUpdate(st, bytes, n) {
    let hi = st[0], lo = st[1];
    for (let i = 0; i < n; i++) {
      lo = (lo ^ bytes[i]) >>> 0;
      const m = lo * 0x1b3;                        // < 2^41: exact
      const carry = Math.floor(m / 4294967296);
      hi = (hi * 0x1b3 + carry + ((lo << 8) >>> 0)) >>> 0;
      lo = m >>> 0;
    }
    st[0] = hi; st[1] = lo;
    return st;
  }
  const fnvString = (st) => ((BigInt(st[0]) << 32n) | BigInt(st[1])).toString();
  const le32 = (v) => [v & 255, (v >>> 8) & 255, (v >>> 16) & 255, (v >>> 24) & 255];

  function checksum(img) {
    const st = fnvInit();
    fnvUpdate(st, le32(img.width), 4);
    fnvUpdate(st, le32(img.height), 4);
    fnvUpdate(st, img.data, img.data.length);
    return fnvString(st);
  }
  /** FNV-1a 64 of a byte array (tests/Editor.lean's fnvBytes). */
  function fnvBytes(bytes) { return fnvString(fnvUpdate(fnvInit(), bytes, bytes.length)); }

  // ---------------------------------------------------------------------------------------------
  // Test image (Editor.testImage, examples/Editor/Doc.lean)

  function testImage(w, h) {
    const d = new Uint8ClampedArray(4 * w * h);
    const c = (v) => { v = Math.max(0, Math.min(255, v)); return v | 0; };   // clamp, then truncate
    let i = 0;
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const fx = x / w, fy = y / h;
        const disc = (cx, cy, r) => (fx - cx) * (fx - cx) * 1.78 + (fy - cy) * (fy - cy) < r * r;
        const grain = ((x * 7919 + y * 104729) % 31) - 15;
        let r, g, b;
        if (disc(0.3, 0.4, 0.18)) { r = 230; g = 90 + 80 * fy; b = 60; }
        else if (disc(0.7, 0.6, 0.22)) { r = 50 + 100 * fx; g = 150; b = 220; }
        else if (fy > 0.82 && Math.floor(x / 6) % 2 === 0) { r = 240; g = 240; b = 240; }
        else { r = 40 + 180 * fx; g = 60 + 150 * fy; b = 120 + 100 * (1 - fx); }
        d[i] = c(r + grain); d[i + 1] = c(g + grain); d[i + 2] = c(b + grain); d[i + 3] = 255;
        i += 4;
      }
    }
    return image(w, h, d);
  }

  /** A copy with every alpha set to 160 (EditorBench.translucent). */
  function translucent(img) {
    const out = copy(img), d = out.data;
    for (let i = 3; i < d.length; i += 4) d[i] = 160;
    return out;
  }

  // ---------------------------------------------------------------------------------------------
  // Adjustments (Editor.Adjust): one 256-entry table for the per-channel steps, built in floating
  // point; saturation, hue and grayscale as one 3x3 fixed-point matrix (12 fractional bits).

  const ADJUST_IDENTITY = { brightness: 0, contrast: 0, exposure: 0, saturation: 0, hue: 0, inBlack: 0, inWhite: 255,
    gamma: 1, curve: [], invert: false, grayscale: false };
  const adjust = (o) => Object.assign({}, ADJUST_IDENTITY, o);

  const clampF = (v) => (v < 0 ? 0 : v > 255 ? 255 : v);
  const srgbToLinear = (c) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
  const linearToSrgb = (c) => (c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055);

  function curvePoints(pts) {
    const sorted = pts.map(([x, y], i) => [Math.min(x, 255), Math.min(y, 255), i])
      .sort((a, b) => a[0] - b[0] || a[2] - b[2]);
    let ps = [];
    for (const [x, y] of sorted) {
      if (ps.length > 0 && ps[ps.length - 1][0] === x) ps[ps.length - 1] = [x, y]; else ps.push([x, y]);
    }
    if (!ps.some((p) => p[0] === 0)) ps = [[0, 0]].concat(ps);
    if (!ps.some((p) => p[0] === 255)) ps.push([255, 255]);
    return ps;
  }

  function curveTangents(ps) {
    const n = ps.length;
    if (n < 2) return new Array(n).fill(0);
    const d = [];
    for (let k = 0; k < n - 1; k++) d.push((ps[k + 1][1] - ps[k][1]) / (ps[k + 1][0] - ps[k][0]));
    const m = [];
    for (let k = 0; k < n; k++) {
      m.push(k === 0 ? d[0] : k === n - 1 ? d[n - 2] : d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) / 2);
    }
    for (let k = 0; k < n - 1; k++) {
      if (d[k] === 0) { m[k] = 0; m[k + 1] = 0; }
      else {
        const a = m[k] / d[k], b = m[k + 1] / d[k], s = a * a + b * b;
        if (s > 9) { const t = 3 / Math.sqrt(s); m[k] = t * a * d[k]; m[k + 1] = t * b * d[k]; }
      }
    }
    return m;
  }

  function curveAt(ps, m, v) {
    const n = ps.length;
    if (n === 0) return v;
    if (v <= ps[0][0]) return ps[0][1];
    if (v >= ps[n - 1][0]) return ps[n - 1][1];
    let k = 0;
    while (k + 2 < n && ps[k + 1][0] <= v) k++;
    const [x0, y0] = ps[k], [x1, y1] = ps[k + 1];
    const h = x1 - x0, t = (v - x0) / h, t2 = t * t, t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * y0 + (t3 - 2 * t2 + t) * h * m[k] + (-2 * t3 + 3 * t2) * y1 + (t3 - t2) * h * m[k + 1];
  }

  /** The per-channel table: exposure, brightness, contrast, levels, curve, invert, in that order. */
  function adjustLut(a) {
    const cps = a.curve.length === 0 ? [] : curvePoints(a.curve);
    const cms = curveTangents(cps);
    const c = a.contrast * 2.55;
    const cf = (259 * (c + 255)) / (255 * (259 - c));
    const gain = Math.pow(2, a.exposure);
    const lo = Math.min(a.inBlack, 255), hi = Math.min(a.inWhite, 255);
    const invGamma = 1 / (a.gamma < 0.01 ? 0.01 : a.gamma);
    const levels = a.inBlack !== 0 || a.inWhite !== 255 || a.gamma !== 1;
    const t = new Uint8Array(256);
    for (let i = 0; i < 256; i++) {
      let v = i;
      if (a.exposure !== 0) v = 255 * linearToSrgb(Math.min(1, srgbToLinear(v / 255) * gain));
      if (a.brightness !== 0) v = clampF(v + a.brightness * 1.275);
      if (a.contrast !== 0) v = clampF(cf * (v - 128) + 128);
      if (levels) {
        v = hi <= lo ? (v < hi ? 0 : 255) : v <= lo ? 0 : v >= hi ? 255 : 255 * Math.pow((v - lo) / (hi - lo), invGamma);
      }
      if (cps.length > 0) v = clampF(curveAt(cps, cms, v));
      if (a.invert) v = 255 - v;
      t[i] = toByte(v);
    }
    return t;
  }

  const LUM_R = 0.2126, LUM_G = 0.7152, LUM_B = 0.0722;
  const saturateMat = (s) => [
    LUM_R + (1 - LUM_R) * s, LUM_G - LUM_G * s, LUM_B - LUM_B * s,
    LUM_R - LUM_R * s, LUM_G + (1 - LUM_G) * s, LUM_B - LUM_B * s,
    LUM_R - LUM_R * s, LUM_G - LUM_G * s, LUM_B + (1 - LUM_B) * s];
  function hueMat(deg) {
    const r = deg * 3.141592653589793 / 180, c = Math.cos(r), s = Math.sin(r);
    return [
      LUM_R + c * (1 - LUM_R) - s * LUM_R, LUM_G - c * LUM_G - s * LUM_G, LUM_B - c * LUM_B + s * (1 - LUM_B),
      LUM_R - c * LUM_R + s * 0.143, LUM_G + c * (1 - LUM_G) + s * 0.140, LUM_B - c * LUM_B - s * 0.283,
      LUM_R - c * LUM_R - s * (1 - LUM_R), LUM_G - c * LUM_G + s * LUM_G, LUM_B + c * (1 - LUM_B) + s * LUM_B];
  }
  function matMul(a, b) {
    const out = [];
    for (let ij = 0; ij < 9; ij++) {
      const i = Math.floor(ij / 3), j = ij % 3;
      out.push(a[3 * i] * b[j] + a[3 * i + 1] * b[3 + j] + a[3 * i + 2] * b[6 + j]);
    }
    return out;
  }
  const colorNeutral = (a) => a.saturation === 0 && a.hue % 360 === 0 && !a.grayscale;
  function colorMatrix(a) {
    let m = saturateMat(1 + Math.max(-100, Math.min(100, a.saturation)) / 100);
    if (a.hue % 360 !== 0) m = matMul(hueMat(a.hue), m);
    if (a.grayscale) m = matMul(saturateMat(0), m);
    return m;
  }
  /** The matrix x 4096 as integers, each row corrected to sum to exactly 4096. */
  function fixedMatrix(m) {
    const out = [];
    for (let i = 0; i < 3; i++) {
      const row = [cRound(m[3 * i] * 4096), cRound(m[3 * i + 1] * 4096), cRound(m[3 * i + 2] * 4096)];
      const resid = 4096 - (row[0] + row[1] + row[2]);
      const A = row.map(Math.abs);
      const big = A[0] >= A[1] && A[0] >= A[2] ? 0 : A[1] >= A[2] ? 1 : 2;
      row[big] += resid;
      out.push(...row);
    }
    return out;
  }
  function adjustIsIdentity(a) {
    if (!colorNeutral(a)) return false;
    const t = adjustLut(a);
    for (let i = 0; i < 256; i++) if (t[i] !== i) return false;
    return true;
  }

  function adjustApply(a, img) {
    if (adjustIsIdentity(a)) return img;
    const lut = adjustLut(a);
    const s = img.data, out = image(img.width, img.height), d = out.data, n = s.length;
    if (colorNeutral(a)) {
      for (let i = 0; i < n; i += 4) {
        d[i] = lut[s[i]]; d[i + 1] = lut[s[i + 1]]; d[i + 2] = lut[s[i + 2]]; d[i + 3] = s[i + 3];
      }
    } else {
      const [m0, m1, m2, m3, m4, m5, m6, m7, m8] = fixedMatrix(colorMatrix(a));
      for (let i = 0; i < n; i += 4) {
        const r = lut[s[i]], g = lut[s[i + 1]], b = lut[s[i + 2]];
        let v = m0 * r + m1 * g + m2 * b + 2048;
        d[i] = v < 0 ? 0 : clamp255(v >> 12);
        v = m3 * r + m4 * g + m5 * b + 2048;
        d[i + 1] = v < 0 ? 0 : clamp255(v >> 12);
        v = m6 * r + m7 * g + m8 * b + 2048;
        d[i + 2] = v < 0 ? 0 : clamp255(v >> 12);
        d[i + 3] = s[i + 3];
      }
    }
    return out;
  }

  /** 1024 counts: red, green, blue, luminance ((54 R + 183 G + 19 B + 128) >> 8), 256 bins each. */
  function histogram(img) {
    const t = new Uint32Array(1024), s = img.data, n = s.length;
    for (let i = 0; i < n; i += 4) {
      const r = s[i], g = s[i + 1], b = s[i + 2];
      t[r]++; t[256 + g]++; t[512 + b]++; t[768 + ((54 * r + 183 * g + 19 * b + 128) >> 8)]++;
    }
    return t;
  }

  // ---------------------------------------------------------------------------------------------
  // Filters (Editor.Filter)

  /** 2k + 1 integer weights summing to 65536, k = ceil(radius), sigma = radius / 2. */
  function gaussKernel(radius) {
    if (!(radius > 0)) return Uint32Array.of(65536);
    if (radius > 250) radius = 250;
    const k = Math.ceil(radius), sigma = radius / 2;
    const ws = [];
    for (let i = 0; i < 2 * k + 1; i++) { const x = i - k; ws.push(Math.exp(-(x * x) / (2 * sigma * sigma))); }
    let total = 0;
    for (const w of ws) total += w;
    const fixed = ws.map((w) => cRound(w / total * 65536) >>> 0);
    let s = 0;
    for (const f of fixed) s = (s + f) >>> 0;
    fixed[k] = (fixed[k] + 65536 - s) >>> 0;
    return Uint32Array.from(fixed);
  }

  /** Separable Gaussian, edges clamped, colour blurred premultiplied by alpha: the horizontal pass
      writes premultiplied pixels, the vertical pass divides by the alpha sum again. */
  function blur(img, radius) {
    const w = img.width, h = img.height;
    if (!(radius > 0) || w === 0 || h === 0) return img;
    const kern = gaussKernel(radius), n = kern.length, k = n >> 1;
    const src = img.data, tmp = new Uint8ClampedArray(src.length), pad = new Uint8Array(4 * (w + 2 * k));
    // horizontal: a padded premultiplied copy of the row, then the taps
    for (let y = 0; y < h; y++) {
      const rowOff = 4 * w * y;
      for (let p = 0; p < w + 2 * k; p++) {
        const x = p < k ? 0 : p - k >= w ? w - 1 : p - k;
        const s = rowOff + 4 * x, o = 4 * p, a = src[s + 3];
        pad[o] = div255(src[s] * a); pad[o + 1] = div255(src[s + 1] * a); pad[o + 2] = div255(src[s + 2] * a); pad[o + 3] = a;
      }
      for (let x = 0; x < w; x++) {
        let ar = 0, ag = 0, ab = 0, aa = 0, q = 4 * x;
        for (let j = 0; j < n; j++, q += 4) {
          const wt = kern[j];
          ar += wt * pad[q]; ag += wt * pad[q + 1]; ab += wt * pad[q + 2]; aa += wt * pad[q + 3];
        }
        const o = rowOff + 4 * x;
        tmp[o] = (ar + 32768) >>> 16; tmp[o + 1] = (ag + 32768) >>> 16; tmp[o + 2] = (ab + 32768) >>> 16; tmp[o + 3] = (aa + 32768) >>> 16;
      }
    }
    // vertical: rows clamped at the top and bottom, back to straight alpha
    const out = image(w, h), d = out.data, stride = 4 * w;
    for (let y = 0; y < h; y++) {
      const inside = y >= k && y + k < h;
      for (let x = 0; x < w; x++) {
        const col = 4 * x;
        let ar = 0, ag = 0, ab = 0, aa = 0;
        for (let j = 0; j < n; j++) {
          let q;
          if (inside) q = (y - k + j) * stride + col;
          else { const vr = y + j; q = (vr < k ? 0 : vr - k >= h ? h - 1 : vr - k) * stride + col; }
          const wt = kern[j];
          ar += wt * tmp[q]; ag += wt * tmp[q + 1]; ab += wt * tmp[q + 2]; aa += wt * tmp[q + 3];
        }
        const o = y * stride + col;
        if (aa === 16711680) {
          d[o] = (ar + 32768) >>> 16; d[o + 1] = (ag + 32768) >>> 16; d[o + 2] = (ab + 32768) >>> 16; d[o + 3] = 255;
        } else if (aa === 0) {
          d[o] = 0; d[o + 1] = 0; d[o + 2] = 0; d[o + 3] = 0;
        } else {
          const half = Math.floor(aa / 2);
          d[o] = Math.min(255, Math.floor((ar * 255 + half) / aa));
          d[o + 1] = Math.min(255, Math.floor((ag * 255 + half) / aa));
          d[o + 2] = Math.min(255, Math.floor((ab * 255 + half) / aa));
          d[o + 3] = (aa + 32768) >>> 16;
        }
      }
    }
    return out;
  }

  /** One colour channel of the unsharp mask (amt is the amount x 256). */
  function usm(o, b, amt, thr) {
    if (o >= b) {
      const diff = o - b;
      return diff < thr ? o : clamp255(o + ((diff * amt + 128) >>> 8));
    }
    const diff = b - o;
    if (diff < thr) return o;
    const s = (diff * amt + 128) >>> 8;
    return s >= o ? 0 : o - s;
  }

  /** Unsharp mask: v + amount * (v - blur(v)) where |v - blur(v)| >= threshold. */
  function sharpen(img, amount, radius, threshold = 0) {
    const bl = blur(img, radius).data;
    const amt = cRound((amount < 0 ? 0 : amount > 16 ? 16 : amount) * 256), thr = Math.min(threshold, 256);
    const s = img.data, out = image(img.width, img.height), d = out.data, n = s.length;
    for (let i = 0; i < n; i += 4) {
      d[i] = usm(s[i], bl[i], amt, thr); d[i + 1] = usm(s[i + 1], bl[i + 1], amt, thr); d[i + 2] = usm(s[i + 2], bl[i + 2], amt, thr);
      d[i + 3] = s[i + 3];
    }
    return out;
  }

  const KERNELS = {
    identity: { weights: [0, 0, 0, 0, 1, 0, 0, 0, 0], divisor: 1, bias: 0 },
    emboss: { weights: [-2, -1, 0, -1, 1, 1, 0, 1, 2], divisor: 1, bias: 0 },
    sharpen: { weights: [0, -1, 0, -1, 5, -1, 0, -1, 0], divisor: 1, bias: 0 },
    boxBlur: { weights: [1, 1, 1, 1, 1, 1, 1, 1, 1], divisor: 9, bias: 0 },
  };

  /** A 3x3 kernel applied as sum(w_i v_i) / divisor + bias to each colour channel (edges clamped,
      alpha kept). The sum is an exact integer; the division and bias are in floating point. */
  function convolve(kern, img) {
    const w = img.width, h = img.height, s = img.data, out = image(w, h), d = out.data;
    if (w === 0) return out;
    const wt = kern.weights.map((v) => Math.max(-1048576, Math.min(1048576, v)));
    const [k0, k1, k2, k3, k4, k5, k6, k7, k8] = wt;
    const inv = 1 / (kern.divisor === 0 ? 1 : kern.divisor), bias = kern.bias, stride = 4 * w;
    for (let y = 0; y < h; y++) {
      const up = stride * (y === 0 ? 0 : y - 1), mid = stride * y, dn = stride * (y + 1 >= h ? y : y + 1);
      for (let x = 0; x < w; x++) {
        const l = 4 * (x === 0 ? 0 : x - 1), c = 4 * x, r = 4 * (x + 1 >= w ? x : x + 1), o = mid + c;
        for (let j = 0; j < 3; j++) {
          const sum = k0 * s[up + l + j] + k1 * s[up + c + j] + k2 * s[up + r + j] +
            k3 * s[mid + l + j] + k4 * s[mid + c + j] + k5 * s[mid + r + j] +
            k6 * s[dn + l + j] + k7 * s[dn + c + j] + k8 * s[dn + r + j];
          d[o + j] = toByte(sum * inv + bias);
        }
        d[o + 3] = s[o + 3];
      }
    }
    return out;
  }
  const emboss = (img) => convolve(KERNELS.emboss, img);

  /** Sobel gradient magnitude of the luminance ((54 R + 183 G + 19 B + 128) >> 8), as gray. */
  function edgeDetect(img) {
    const w = img.width, h = img.height, s = img.data, out = image(w, h), d = out.data;
    if (w === 0) return out;
    const stride = 4 * w;
    const lum = (o) => (54 * s[o] + 183 * s[o + 1] + 19 * s[o + 2] + 128) >> 8;
    for (let y = 0; y < h; y++) {
      const up = stride * (y === 0 ? 0 : y - 1), mid = stride * y, dn = stride * (y + 1 >= h ? y : y + 1);
      for (let x = 0; x < w; x++) {
        const l = 4 * (x === 0 ? 0 : x - 1), c = 4 * x, r = 4 * (x + 1 >= w ? x : x + 1), o = mid + c;
        const p00 = lum(up + l), p01 = lum(up + c), p02 = lum(up + r), p10 = lum(mid + l), p12 = lum(mid + r);
        const p20 = lum(dn + l), p21 = lum(dn + c), p22 = lum(dn + r);
        const gx = (p02 + 2 * p12 + p22) - (p00 + 2 * p10 + p20);
        const gy = (p20 + 2 * p21 + p22) - (p00 + 2 * p01 + p02);
        const m = toByte(Math.sqrt(gx * gx + gy * gy));
        d[o] = m; d[o + 1] = m; d[o + 2] = m; d[o + 3] = s[o + 3];
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------------------------
  // Geometry (Editor.Geometry)

  /** The part of img inside the rectangle (clamped to the image), one row copy at a time. */
  function crop(img, rx, ry, rw, rh) {
    const x0 = Math.max(rx, 0), y0 = Math.max(ry, 0);
    const x1 = Math.min(rx + rw, img.width), y1 = Math.min(ry + rh, img.height);
    if (x1 <= x0 || y1 <= y0) return image(0, 0);
    const w = x1 - x0, h = y1 - y0, out = image(w, h), s = img.data, d = out.data, sw = 4 * img.width;
    for (let y = 0; y < h; y++) {
      const off = (y0 + y) * sw + 4 * x0;
      d.set(s.subarray(off, off + 4 * w), 4 * w * y);
    }
    return out;
  }

  /** A w x h image written in order; pixel (x, y) comes from source byte offset s0 + y dr + x ds. */
  function walk(img, w, h, s0, ds, dr) {
    const out = image(w, h), s = img.data, d = out.data;
    let o = 0, rs = s0;
    for (let y = 0; y < h; y++, rs += dr) {
      let q = rs;
      for (let x = 0; x < w; x++, q += ds, o += 4) {
        d[o] = s[q]; d[o + 1] = s[q + 1]; d[o + 2] = s[q + 2]; d[o + 3] = s[q + 3];
      }
    }
    return out;
  }
  const rotate90cw = (img) => walk(img, img.height, img.width, 4 * (img.height - 1) * img.width, -4 * img.width, 4);
  const rotate90ccw = (img) => walk(img, img.height, img.width, 4 * (img.width - 1), 4 * img.width, -4);
  const rotate180 = (img) => walk(img, img.width, img.height, 4 * (img.height * img.width - 1), -4, -4 * img.width);
  const flipH = (img) => walk(img, img.width, img.height, 4 * (img.width - 1), -4, 4 * img.width);

  /** Mirrored top to bottom, one row copy at a time. */
  function flipV(img) {
    const w = img.width, h = img.height, out = image(w, h), s = img.data, d = out.data, sw = 4 * w;
    for (let y = 0; y < h; y++) d.set(s.subarray((h - 1 - y) * sw, (h - y) * sw), y * sw);
    return out;
  }

  /** Sample positions for bilinear resizing, 8-bit fixed point: (i + 1/2) sn / dn - 1/2, clamped;
      three words per output sample (lower and upper neighbour offset x scale, fraction). */
  function samplePositions(sn, dn, scale) {
    const t = new Uint32Array(3 * dn);
    for (let i = 0; i < dn; i++) {
      let p = Math.floor((2 * i + 1) * sn * 256 / (2 * dn)) - 128;
      p = p < 0 ? 0 : Math.min(p, (sn - 1) * 256);
      const i0 = p >> 8, i1 = Math.min(i0 + 1, sn - 1);
      t[3 * i] = i0 * scale; t[3 * i + 1] = i1 * scale; t[3 * i + 2] = p & 255;
    }
    return t;
  }

  /** Bilinear resize (pixel centres aligned, 8-bit fractions, colour interpolated premultiplied
      unless all four neighbours are opaque). */
  function resize(img, w, h) {
    const out = image(w, h);
    if (img.width === 0 || img.height === 0 || w === 0) return out;
    const s = img.data, d = out.data;
    const cols = samplePositions(img.width, w, 4), rows = samplePositions(img.height, h, 4 * img.width);
    let o = 0;
    for (let y = 0; y < h; y++) {
      const r0 = rows[3 * y], r1 = rows[3 * y + 1], fy = rows[3 * y + 2];
      for (let x = 0; x < w; x++, o += 4) {
        const x0 = cols[3 * x], x1 = cols[3 * x + 1], fx = cols[3 * x + 2];
        const p00 = r0 + x0, p01 = r0 + x1, p10 = r1 + x0, p11 = r1 + x1;
        const w00 = (256 - fx) * (256 - fy), w01 = fx * (256 - fy), w10 = (256 - fx) * fy, w11 = fx * fy;
        const a00 = s[p00 + 3], a01 = s[p01 + 3], a10 = s[p10 + 3], a11 = s[p11 + 3];
        if ((a00 & a01 & a10 & a11) === 255) {
          for (let c = 0; c < 3; c++) d[o + c] = (w00 * s[p00 + c] + w01 * s[p01 + c] + w10 * s[p10 + c] + w11 * s[p11 + c] + 32768) >>> 16;
          d[o + 3] = 255;
        } else {
          const sa = w00 * a00 + w01 * a01 + w10 * a10 + w11 * a11;
          const alpha = (w00 * a00 + w01 * a01 + w10 * a10 + w11 * a11 + 32768) >>> 16;
          for (let c = 0; c < 3; c++) {
            if (sa === 0) d[o + c] = (w00 * s[p00 + c] + w01 * s[p01 + c] + w10 * s[p10 + c] + w11 * s[p11 + c] + 32768) >>> 16;
            else {
              const sum = w00 * a00 * s[p00 + c] + w01 * a01 * s[p01 + c] + w10 * a10 * s[p10 + c] + w11 * a11 * s[p11 + c];
              d[o + c] = Math.min(255, Math.floor((sum + Math.floor(sa / 2)) / sa));
            }
          }
          d[o + 3] = alpha;
        }
      }
    }
    return out;
  }

  /** Box downscale: each output pixel averages its block of source pixels (edges at
      floor(i sn / dn)), premultiplied. */
  function downscaleBox(img, w, h) {
    const out = image(w, h);
    if (img.width === 0 || img.height === 0 || w === 0) return out;
    const s = img.data, d = out.data, stride = 4 * img.width;
    const cols = new Uint32Array(w + 1), rows = new Uint32Array(h + 1);
    for (let i = 0; i <= w; i++) cols[i] = Math.floor(i * img.width / w);
    for (let i = 0; i <= h; i++) rows[i] = Math.floor(i * img.height / h);
    let o = 0;
    for (let y = 0; y < h; y++) {
      const r0 = rows[y], r1 = rows[y + 1] <= r0 ? r0 + 1 : rows[y + 1];
      for (let x = 0; x < w; x++, o += 4) {
        const c0 = cols[x], c1 = cols[x + 1] <= c0 ? c0 + 1 : cols[x + 1];
        const n = (c1 - c0) * (r1 - r0);
        let sa = 0, sr = 0, sg = 0, sb = 0, tr = 0, tg = 0, tb = 0;
        for (let r = r0; r < r1; r++) {
          for (let q = r * stride + 4 * c0, e = r * stride + 4 * c1; q < e; q += 4) {
            const a = s[q + 3], cr = s[q], cg = s[q + 1], cb = s[q + 2];
            sa += a; sr += a * cr; sg += a * cg; sb += a * cb; tr += cr; tg += cg; tb += cb;
          }
        }
        const half = Math.floor(n / 2);
        d[o + 3] = Math.floor((sa + half) / n);
        if (sa === 0) {
          d[o] = Math.floor((tr + half) / n); d[o + 1] = Math.floor((tg + half) / n); d[o + 2] = Math.floor((tb + half) / n);
        } else {
          const ha = Math.floor(sa / 2);
          d[o] = Math.floor((sr + ha) / sa); d[o + 1] = Math.floor((sg + ha) / sa); d[o + 2] = Math.floor((sb + ha) / sa);
        }
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------------------------
  // Compositing (Editor.Composite): W3C blending on straight alpha, integer arithmetic.

  const BLENDS = ["normal", "multiply", "screen", "overlay", "darken", "lighten", "add", "difference"];

  function blendCh(mode, cb, cs) {
    switch (mode) {
      case 0: return cs;
      case 1: return div255(cb * cs);
      case 2: return cb + cs - div255(cb * cs);
      case 3: return 2 * cb <= 255 ? div255(2 * cb * cs) : 255 - div255(2 * (255 - cb) * (255 - cs));
      case 4: return cb < cs ? cb : cs;
      case 5: return cb < cs ? cs : cb;
      case 6: return clamp255(cb + cs);
      default: return cb < cs ? cs - cb : cb - cs;
    }
  }

  function compCh(mode, cb, cs, as, ab, ao2) {
    const csp = (255 - ab) * cs + ab * blendCh(mode, cb, cs);
    const num = as * csp + ab * (255 - as) * cb;
    return ao2 === 65025 ? clamp255(Math.floor((num + 32512) / 65025)) : clamp255(Math.floor((num + (ao2 >>> 1)) / ao2));
  }

  /** `top` drawn over a copy of `bottom` (same size) with opacity 0..100 and a blend mode name. */
  function composite(bottom, top, opacity = 100, blend = "normal") {
    const out = copy(bottom);
    if (opacity === 0 || top.width !== bottom.width || top.height !== bottom.height) return out;
    const mode = BLENDS.indexOf(blend), op = Math.floor((Math.min(opacity, 100) * 255 + 50) / 100);
    const d = out.data, t = top.data, n = d.length;
    for (let i = 0; i < n; i += 4) {
      const as = div255(t[i + 3] * op);
      if (as === 0) continue;
      const ab = d[i + 3], ao2 = as * 255 + ab * (255 - as);
      d[i] = compCh(mode, d[i], t[i], as, ab, ao2);
      d[i + 1] = compCh(mode, d[i + 1], t[i + 1], as, ab, ao2);
      d[i + 2] = compCh(mode, d[i + 2], t[i + 2], as, ab, ao2);
      d[i + 3] = div255(ao2);
    }
    return out;
  }

  // ---------------------------------------------------------------------------------------------
  // PNG (Editor.Png.encode): 8-bit RGBA, one IDAT. Level 0: unfiltered rows in stored blocks.
  // Level >= 1: per row the filter (Sub, Up, Paeth) with the smallest sum of |signed byte|, then
  // one fixed-Huffman deflate block, greedy LZ77 through hash chains of at most 4 * 2^(level - 1)
  // links; below level 6 positions inside a match longer than 4 * level are not hashed.

  const CRC_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c >>> 0;
    }
    return t;
  })();
  function crc32(d, start, stop) {
    let c = 0xffffffff;
    for (let i = start; i < stop; i++) c = CRC_TABLE[(c ^ d[i]) & 255] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  }
  function adler32(d, start, stop) {
    let a = 1, b = 0;
    for (let i = start; i < stop;) {
      const e = Math.min(stop, i + 5552);
      for (; i < e; i++) { a += d[i]; b += a; }
      a %= 65521; b %= 65521;
    }
    return ((b << 16) | a) >>> 0;
  }

  const LEN_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
  const LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
  const DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
    4097, 6145, 8193, 12289, 16385, 24577];
  const DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
  const reverseBits = (v, n) => { let r = 0; for (let i = 0; i < n; i++) r |= ((v >>> i) & 1) << (n - 1 - i); return r; };
  // fixed literal/length code of a symbol: reversed code | length << 16
  function fixedLitCode(sym) {
    const [code, len] = sym < 144 ? [0x30 + sym, 8] : sym < 256 ? [0x190 + sym - 144, 9] : sym < 280 ? [sym - 256, 7] : [0xc0 + sym - 280, 8];
    return reverseBits(code, len) | (len << 16);
  }
  const LIT_CODES = Uint32Array.from({ length: 257 }, (_, s) => fixedLitCode(s));
  // per match length: the length code and its extra bits | bit count << 16
  const LEN_CODES = Uint32Array.from({ length: 259 }, (_, l) => {
    if (l < 3) return 0;
    let k = 0;
    for (let i = 0; i < 29; i++) if (LEN_BASE[i] <= l) k = i;
    const c = fixedLitCode(257 + k), clen = c >>> 16;
    return ((c & 0xffff) | ((l - LEN_BASE[k]) << clen)) | ((clen + LEN_EXTRA[k]) << 16);
  });
  // per distance: the distance code and its extra bits | bit count << 24
  const DIST_CODES = Uint32Array.from({ length: 32769 }, (_, d) => {
    if (d < 1) return 0;
    let k = 0;
    for (let i = 0; i < 30; i++) if (DIST_BASE[i] <= d) k = i;
    return (reverseBits(k, 5) | ((d - DIST_BASE[k]) << 5)) | ((5 + DIST_EXTRA[k]) << 24);
  });

  function paeth(a, b, c) {
    const pa = Math.abs(b - c), pb = Math.abs(a - c), pc = Math.abs(a + b - 2 * c);
    return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
  }
  const sabs = (v) => { v &= 255; return v < 128 ? v : 256 - v; };

  /** Filtered scanlines: per row a filter byte (1 Sub, 2 Up, 4 Paeth: smallest sum of |signed byte|,
      ties to the earlier), then the row. */
  function filterRows(src, w, h) {
    const rb = 4 * w, raw = new Uint8Array(h * (rb + 1));
    for (let y = 0; y < h; y++) {
      const cur = y * rb, prior = cur - rb, hasPrior = y > 0;
      let s1 = 0, s2 = 0, s4 = 0;
      for (let i = 0; i < rb; i++) {
        const x = src[cur + i], a = i >= 4 ? src[cur + i - 4] : 0;
        const b = hasPrior ? src[prior + i] : 0, c = hasPrior && i >= 4 ? src[prior + i - 4] : 0;
        s1 += sabs(x - a); s2 += sabs(x - b); s4 += sabs(x - paeth(a, b, c));
      }
      const ft = s2 < s1 ? (s4 < s2 ? 4 : 2) : s4 < s1 ? 4 : 1;
      const o = y * (rb + 1);
      raw[o] = ft;
      for (let i = 0; i < rb; i++) {
        const x = src[cur + i], a = i >= 4 ? src[cur + i - 4] : 0;
        const b = hasPrior ? src[prior + i] : 0, c = hasPrior && i >= 4 ? src[prior + i - 4] : 0;
        raw[o + 1 + i] = (x - (ft === 1 ? a : ft === 2 ? b : paeth(a, b, c))) & 255;
      }
    }
    return raw;
  }

  /** Growable output bytes with an LSB-first bit writer. */
  class Out {
    constructor(cap) { this.b = new Uint8Array(cap); this.n = 0; this.bb = 0; this.nb = 0; }
    grow(k) { if (this.n + k > this.b.length) { const b = new Uint8Array(Math.max(2 * this.b.length, this.n + k)); b.set(this.b.subarray(0, this.n)); this.b = b; } }
    byte(v) { this.grow(1); this.b[this.n++] = v; }
    u32be(v) { this.byte(v >>> 24); this.byte((v >>> 16) & 255); this.byte((v >>> 8) & 255); this.byte(v & 255); }
    bytes(src, off, len) { this.grow(len); this.b.set(src.subarray(off, off + len), this.n); this.n += len; }
    bits(v, n) {
      this.bb |= v << this.nb; this.nb += n;
      while (this.nb >= 8) { if (this.n >= this.b.length) this.grow(1); this.b[this.n++] = this.bb & 255; this.bb >>>= 8; this.nb -= 8; }
    }
    flushBits() { if (this.nb > 0) this.byte(this.bb & 255); this.bb = 0; this.nb = 0; }
  }

  function deflateFixed(src, chain, maxIns, out) {
    const n = src.length, tab = new Uint32Array(65536);   // chain heads by hash, then links by position & 32767 (position + 1)
    const hash = (p) => Math.imul((src[p] << 16) | (src[p + 1] << 8) | src[p + 2], 2654435761 | 0) >>> 17;
    out.bits(3, 3);   // BFINAL = 1, BTYPE = 01
    let p = 0;
    while (p < n) {
      const maxLen = n - p < 258 ? n - p : 258;
      if (maxLen >= 3 && p + 3 < n) {
        const h = hash(p), c1 = tab[h];
        tab[32768 + (p & 32767)] = c1; tab[h] = p + 1;
        // walk the chain for the longest match (greedy)
        let best = 2, bestD = 0, cand = c1, links = chain;
        while (cand !== 0 && links !== 0) {
          const c = cand - 1;
          if (c >= p || p - c > 32768) break;
          if (src[c + best] === src[p + best]) {
            let l = 0;
            while (l < maxLen && src[c + l] === src[p + l]) l++;
            if (l > best) { best = l; bestD = p - c; }
          }
          if (best >= maxLen) break;
          const next = tab[32768 + (c & 32767)];
          if (next > c) break;   // a newer position in the slot ends the chain
          cand = next; links--;
        }
        if (best >= 3) {
          const lc = LEN_CODES[best], dc = DIST_CODES[bestD];
          out.bits(lc & 0xffff, lc >>> 16);
          out.bits(dc & 0xffffff, dc >>> 24);
          const e = p + best;
          if (best <= maxIns) {
            for (let q = p + 1; q < e; q++) {
              if (q + 3 < n) { const hq = hash(q); tab[32768 + (q & 32767)] = tab[hq]; tab[hq] = q + 1; }
            }
          }
          p = e;
          continue;
        }
      }
      const e = LIT_CODES[src[p]];
      out.bits(e & 0xffff, e >>> 16);
      p++;
    }
    const e = LIT_CODES[256];
    out.bits(e & 0xffff, e >>> 16);
    out.flushBits();
  }

  function deflateStored(src, out) {
    let off = 0;
    do {
      const len = Math.min(65535, src.length - off), final = off + len >= src.length;
      out.byte(final ? 1 : 0); out.byte(len & 255); out.byte(len >>> 8); out.byte(~len & 255); out.byte((~len >>> 8) & 255);
      out.bytes(src, off, len);
      off += len;
      if (final) break;
    } while (true);
  }

  function pushChunk(out, type, data) {
    out.u32be(data.length);
    const start = out.n;
    for (let i = 0; i < 4; i++) out.byte(type.charCodeAt(i));
    out.bytes(data, 0, data.length);
    out.u32be(crc32(out.b, start, out.n));
  }

  /** The PNG file of img (8-bit RGBA) as a Uint8Array. */
  function pngEncode(img, level = 1) {
    const w = img.width, h = img.height, rb = 4 * w, rawSize = h * (rb + 1);
    let raw;
    if (level === 0) {
      raw = new Uint8Array(rawSize);
      for (let y = 0; y < h; y++) raw.set(img.data.subarray(y * rb, (y + 1) * rb), y * (rb + 1) + 1);
    } else raw = filterRows(img.data, w, h);
    const out = new Out(rawSize + Math.floor(rawSize / 65535) * 5 + 128);
    for (const b of [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) out.byte(b);
    pushChunk(out, "IHDR", Uint8Array.of(w >>> 24, (w >>> 16) & 255, (w >>> 8) & 255, w & 255,
      h >>> 24, (h >>> 16) & 255, (h >>> 8) & 255, h & 255, 8, 6, 0, 0, 0));
    const lenAt = out.n;
    out.u32be(0);
    for (const c of "IDAT") out.byte(c.charCodeAt(0));
    const dataAt = out.n;
    if (level === 0) { out.byte(0x78); out.byte(0x01); deflateStored(raw, out); }
    else {
      const lv = Math.min(level, 9);
      out.byte(0x78); out.byte(0x5e);
      deflateFixed(raw, 4 * 2 ** (lv - 1), level >= 6 ? 258 : 4 * level, out);
    }
    out.u32be(adler32(raw, 0, raw.length));
    const len = out.n - dataAt;
    out.b[lenAt] = len >>> 24; out.b[lenAt + 1] = (len >>> 16) & 255; out.b[lenAt + 2] = (len >>> 8) & 255; out.b[lenAt + 3] = len & 255;
    out.u32be(crc32(out.b, dataAt - 4, out.n));
    pushChunk(out, "IEND", new Uint8Array(0));
    return out.b.slice(0, out.n);
  }

  // ---------------------------------------------------------------------------------------------
  // The benchmark operations (EditorBench.ops / EditorBench.run, with the same parameters)

  const OPS = ["adjust-lut", "adjust-color", "blur-2", "blur-8", "sharpen", "emboss", "edges", "rotate-90", "rotate-180",
    "flip-h", "flip-v", "resize-50", "downscale-8", "composite-normal", "composite-overlay", "histogram",
    "png-stored", "png-1", "crop-half"];
  const LUT_ADJUST = adjust({ brightness: 20, contrast: 15, gamma: 1.2 });
  const COLOR_ADJUST = adjust({ saturation: 30, hue: 20 });

  /** Run operation `op` on `img` (`top`: its translucent copy, for compositing). Returns { out, n }
      like EditorBench.run: the result image (null for histogram and PNG) and a number (the PNG's
      byte count, or the sum of the histogram's counts). */
  function run(op, img, top) {
    const w = img.width, h = img.height;
    switch (op) {
      case "adjust-lut": return { out: adjustApply(LUT_ADJUST, img), n: 0 };
      case "adjust-color": return { out: adjustApply(COLOR_ADJUST, img), n: 0 };
      case "blur-2": return { out: blur(img, 2), n: 0 };
      case "blur-8": return { out: blur(img, 8), n: 0 };
      case "sharpen": return { out: sharpen(img, 1, 2), n: 0 };
      case "emboss": return { out: emboss(img), n: 0 };
      case "edges": return { out: edgeDetect(img), n: 0 };
      case "rotate-90": return { out: rotate90cw(img), n: 0 };
      case "rotate-180": return { out: rotate180(img), n: 0 };
      case "flip-h": return { out: flipH(img), n: 0 };
      case "flip-v": return { out: flipV(img), n: 0 };
      case "resize-50": return { out: resize(img, Math.floor(w / 2), Math.floor(h / 2)), n: 0 };
      case "downscale-8": return { out: downscaleBox(img, Math.floor(w / 8), Math.floor(h / 8)), n: 0 };
      case "composite-normal": return { out: composite(img, top, 60, "normal"), n: 0 };
      case "composite-overlay": return { out: composite(img, top, 60, "overlay"), n: 0 };
      case "histogram": { const t = histogram(img); let s = 0; for (const v of t) s += v; return { out: null, n: s, hist: t }; }
      case "png-stored": { const b = pngEncode(img, 0); return { out: null, n: b.length, bytes: b }; }
      case "png-1": { const b = pngEncode(img, 1); return { out: null, n: b.length, bytes: b }; }
      case "crop-half": return { out: crop(img, Math.floor(w / 4), Math.floor(h / 4), Math.floor(w / 2), Math.floor(h / 2)), n: 0 };
      default: throw new Error("unknown operation " + op);
    }
  }

  const EditorOps = {
    OPS, run, image, copy, checksum, fnvBytes, testImage, translucent,
    adjust, adjustLut, adjustApply, fixedMatrix, colorMatrix, histogram, LUT_ADJUST, COLOR_ADJUST,
    gaussKernel, blur, sharpen, KERNELS, convolve, emboss, edgeDetect,
    crop, rotate90cw, rotate90ccw, rotate180, flipH, flipV, resize, downscaleBox,
    BLENDS, composite, pngEncode, crc32, adler32,
  };
  root.EditorOps = EditorOps;
  if (typeof module === "object" && module.exports) module.exports = EditorOps;
})(typeof globalThis !== "undefined" ? globalThis : this);
