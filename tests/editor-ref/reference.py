#!/usr/bin/env python3
"""Independent reference for the golden checksums of tests/Editor.lean.

Implements the editor operations from their definitions (the module docs of examples/Editor/*.lean)
with Python integers (unbounded: a 32-bit overflow in the Lean code shows up as a mismatch) and
Python floats (IEEE doubles, the same libm), and prints the FNV-1a checksums in the test's format.

    python3 tests/editor-ref/reference.py                     # print them
    python3 tests/editor-ref/reference.py tests/Editor.lean   # compare with the pinned table

The compressed PNG files are not covered (their bytes depend on the match finder); check them with
`leanui-editor-tests --write-pngs DIR` and `checkpng.py DIR`.
"""
import math, struct, zlib, sys

M32 = 0xffffffff

def lcg(s): return (s * 1103515245 + 12345) & M32

def noise(w, h, seed, alpha=True):
    d = bytearray(); s = seed
    for _ in range(w * h):
        s1 = lcg(s); s2 = lcg(s1); s3 = lcg(s2); s4 = lcg(s3)
        a0 = s4 >> 24
        a = 255 if not alpha else (0 if a0 < 64 else 255 if a0 > 160 else a0)
        d += bytes([s1 >> 24, s2 >> 24, s3 >> 24, a]); s = s4
    return (w, h, bytes(d))

def fnv(w, h, data):
    hsh = 0xcbf29ce484222325
    for b in struct.pack('<II', w, h) + bytes(data):
        hsh = ((hsh ^ b) * 0x100000001b3) & 0xffffffffffffffff
    return hsh

def fnv_bytes(data):
    hsh = 0xcbf29ce484222325
    for b in data:
        hsh = ((hsh ^ b) * 0x100000001b3) & 0xffffffffffffffff
    return hsh

def cs(img): return fnv(*img)

def px(img, x, y):
    w, h, d = img
    i = 4 * (y * w + x); return d[i:i + 4]

def gradient(w, h):
    d = bytearray()
    for y in range(h):
        for x in range(w):
            d += bytes([x * 255 // max(1, w - 1), y * 255 // max(1, h - 1), (x + y) * 4 % 256, 255])
    return (w, h, bytes(d))

def checker(w, h, k):
    d = bytearray()
    for y in range(h):
        for x in range(w):
            d += bytes([240, 240, 240, 255] if (x // k + y // k) % 2 == 0 else [20, 40, 60, 255])
    return (w, h, bytes(d))

def c_round(v):  # C round(): halves away from zero
    return math.floor(v + 0.5) if v >= 0 else -math.floor(-v + 0.5)

def to_byte(v):
    if v <= 0: return 0
    if v >= 255: return 255
    return int(v + 0.5)

def div255(x):  # round(x / 255), halves up
    return (2 * x + 255) // 510

# ---------------------------------------------------------------- adjustments
def srgb_to_lin(c): return c / 12.92 if c <= 0.04045 else math.pow((c + 0.055) / 1.055, 2.4)
def lin_to_srgb(c): return c * 12.92 if c <= 0.0031308 else 1.055 * math.pow(c, 1 / 2.4) - 0.055
def clampf(v): return 0.0 if v < 0 else 255.0 if v > 255 else v

def curve_points(pts):
    pts = [(min(x, 255), min(y, 255)) for x, y in pts]
    srt = [p for _, p in sorted(((p[0], i), p) for i, p in enumerate(pts))]
    dd = []
    for p in srt:
        if dd and dd[-1][0] == p[0]: dd[-1] = p
        else: dd.append(p)
    if not any(p[0] == 0 for p in dd): dd = [(0, 0)] + dd
    if not any(p[0] == 255 for p in dd): dd.append((255, 255))
    return [(float(x), float(y)) for x, y in dd]

def tangents(ps):
    n = len(ps)
    d = [(ps[k + 1][1] - ps[k][1]) / (ps[k + 1][0] - ps[k][0]) for k in range(n - 1)]
    m = []
    for k in range(n):
        if k == 0: m.append(d[0])
        elif k == n - 1: m.append(d[n - 2])
        elif d[k - 1] * d[k] <= 0: m.append(0.0)
        else: m.append((d[k - 1] + d[k]) / 2)
    for k in range(n - 1):
        if d[k] == 0: m[k] = 0.0; m[k + 1] = 0.0
        else:
            a = m[k] / d[k]; b = m[k + 1] / d[k]; s = a * a + b * b
            if s > 9:
                t = 3 / math.sqrt(s); m[k] = t * a * d[k]; m[k + 1] = t * b * d[k]
    return m

def curve_at(ps, m, v):
    n = len(ps)
    if v <= ps[0][0]: return ps[0][1]
    if v >= ps[-1][0]: return ps[-1][1]
    k = 0
    while k + 2 < n and ps[k + 1][0] <= v: k += 1
    x0, y0 = ps[k]; x1, y1 = ps[k + 1]
    h = x1 - x0; t = (v - x0) / h; t2 = t * t; t3 = t2 * t
    return (2 * t3 - 3 * t2 + 1) * y0 + (t3 - 2 * t2 + t) * h * m[k] + (-2 * t3 + 3 * t2) * y1 + (t3 - t2) * h * m[k + 1]

def lut(a):
    cps = curve_points(a.get('curve', [])) if a.get('curve') else []
    cms = tangents(cps) if cps else []
    c = a.get('contrast', 0) * 2.55
    cf = (259 * (c + 255)) / (255 * (259 - c))
    gain = math.pow(2, a.get('exposure', 0.0))
    lo = float(min(a.get('inBlack', 0), 255)); hi = float(min(a.get('inWhite', 255), 255))
    g = a.get('gamma', 1.0); inv_g = 1 / (0.01 if g < 0.01 else g)
    levels = a.get('inBlack', 0) != 0 or a.get('inWhite', 255) != 255 or g != 1
    t = []
    for i in range(256):
        v = float(i)
        if a.get('exposure', 0) != 0: v = 255 * lin_to_srgb(min(1, srgb_to_lin(v / 255) * gain))
        if a.get('brightness', 0) != 0: v = clampf(v + a['brightness'] * 1.275)
        if a.get('contrast', 0) != 0: v = clampf(cf * (v - 128) + 128)
        if levels:
            if hi <= lo: v = 0.0 if v < hi else 255.0
            elif v <= lo: v = 0.0
            elif v >= hi: v = 255.0
            else: v = 255 * math.pow((v - lo) / (hi - lo), inv_g)
        if cps: v = clampf(curve_at(cps, cms, v))
        if a.get('invert'): v = 255 - v
        t.append(to_byte(v))
    return t

LR, LG, LB = 0.2126, 0.7152, 0.0722
def sat_mat(s):
    return [LR + (1 - LR) * s, LG - LG * s, LB - LB * s,
            LR - LR * s, LG + (1 - LG) * s, LB - LB * s,
            LR - LR * s, LG - LG * s, LB + (1 - LB) * s]
def hue_mat(deg):
    r = deg * 3.141592653589793 / 180; c = math.cos(r); s = math.sin(r)
    return [LR + c * (1 - LR) - s * LR, LG - c * LG - s * LG, LB - c * LB + s * (1 - LB),
            LR - c * LR + s * 0.143, LG + c * (1 - LG) + s * 0.140, LB - c * LB - s * 0.283,
            LR - c * LR - s * (1 - LR), LG - c * LG + s * LG, LB + c * (1 - LB) + s * LB]
def mat_mul(a, b):
    return [a[3 * i] * b[j] + a[3 * i + 1] * b[3 + j] + a[3 * i + 2] * b[6 + j] for i in range(3) for j in range(3)]

def color_neutral(a): return a.get('saturation', 0) == 0 and a.get('hue', 0) % 360 == 0 and not a.get('grayscale')

def fixed_matrix(m):
    out = []
    for i in range(3):
        row = [int(c_round(v * 4096)) for v in m[3 * i:3 * i + 3]]
        resid = 4096 - sum(row)
        big = 0 if abs(row[0]) >= abs(row[1]) and abs(row[0]) >= abs(row[2]) else 1 if abs(row[1]) >= abs(row[2]) else 2
        row[big] += resid
        out += row
    return out

def adjust(a, img):
    w, h, d = img
    t = lut(a)
    if not color_neutral(a):
        m = sat_mat(1 + max(-100, min(100, a.get('saturation', 0))) / 100)
        if a.get('hue', 0) % 360 != 0: m = mat_mul(hue_mat(float(a['hue'])), m)
        if a.get('grayscale'): m = mat_mul(sat_mat(0), m)
        fm = fixed_matrix(m)
    out = bytearray(d)
    for i in range(0, len(d), 4):
        r, g, b = t[d[i]], t[d[i + 1]], t[d[i + 2]]
        if color_neutral(a):
            out[i:i + 3] = bytes([r, g, b])
        else:
            for c in range(3):
                v = fm[3 * c] * r + fm[3 * c + 1] * g + fm[3 * c + 2] * b + 2048
                out[i + c] = 0 if v < 0 else min(255, v >> 12)
    return (w, h, bytes(out))

def histogram(img):
    w, h, d = img
    hs = [0] * 1024
    for i in range(0, len(d), 4):
        r, g, b = d[i], d[i + 1], d[i + 2]
        hs[r] += 1; hs[256 + g] += 1; hs[512 + b] += 1
        hs[768 + ((54 * r + 183 * g + 19 * b + 128) >> 8)] += 1
    return hs

# ---------------------------------------------------------------- filters
def gauss_kernel(radius):
    if not radius > 0: return [65536]
    radius = min(radius, 250)
    k = int(math.ceil(radius)); sigma = radius / 2
    ws = [math.exp(-((i - k) * (i - k)) / (2 * sigma * sigma)) for i in range(2 * k + 1)]
    total = 0.0
    for wv in ws: total += wv
    fx = [int(c_round(wv / total * 65536)) for wv in ws]
    fx[k] += 65536 - sum(fx)
    return fx

def blur(img, radius):
    w, h, d = img
    if not radius > 0: return img
    kern = gauss_kernel(radius); k = len(kern) // 2
    def P(x, y):
        x = min(max(x, 0), w - 1); y = min(max(y, 0), h - 1)
        return d[4 * (y * w + x):4 * (y * w + x) + 4]
    # horizontal, premultiplied, rounded to bytes
    tmp = [[None] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            acc = [0, 0, 0, 0]
            for j, wt in enumerate(kern):
                r, g, b, a = P(x + j - k, y)
                pm = [div255(r * a), div255(g * a), div255(b * a), a]
                for c in range(4): acc[c] += wt * pm[c]
            tmp[y][x] = [(v + 32768) >> 16 for v in acc]
    out = bytearray()
    for y in range(h):
        for x in range(w):
            acc = [0, 0, 0, 0]
            for j, wt in enumerate(kern):
                yy = min(max(y + j - k, 0), h - 1)
                for c in range(4): acc[c] += wt * tmp[yy][x][c]
            if acc[3] == 0: out += bytes(4)
            else:
                cols = [min(255, (acc[c] * 255 + acc[3] // 2) // acc[3]) for c in range(3)]
                out += bytes(cols + [(acc[3] + 32768) >> 16])
    return (w, h, bytes(out))

def sharpen(img, amount, radius, threshold):
    bl = blur(img, radius)
    amt = int(c_round(max(0, min(16, amount)) * 256)); thr = min(threshold, 256)
    w, h, d = img
    out = bytearray(d)
    for i in range(len(d)):
        if i % 4 == 3: continue
        o, b = d[i], bl[2][i]
        if o >= b:
            diff = o - b
            out[i] = o if diff < thr else min(255, o + ((diff * amt + 128) >> 8))
        else:
            diff = b - o
            if diff < thr: out[i] = o
            else:
                s = (diff * amt + 128) >> 8
                out[i] = 0 if s >= o else o - s
    return (w, h, bytes(out))

def convolve(img, kern, div, bias):
    w, h, d = img
    inv = 1 / (1 if div == 0 else div)
    out = bytearray(d)
    for y in range(h):
        for x in range(w):
            for c in range(3):
                s = None
                for j in range(9):
                    xx = min(max(x + j % 3 - 1, 0), w - 1); yy = min(max(y + j // 3 - 1, 0), h - 1)
                    term = float(kern[j]) * float(d[4 * (yy * w + xx) + c])
                    s = term if s is None else s + term
                out[4 * (y * w + x) + c] = to_byte(s * inv + float(bias))
    return (w, h, bytes(out))

def edges(img):
    w, h, d = img
    def L(x, y):
        x = min(max(x, 0), w - 1); y = min(max(y, 0), h - 1); i = 4 * (y * w + x)
        return float((54 * d[i] + 183 * d[i + 1] + 19 * d[i + 2] + 128) >> 8)
    out = bytearray(d)
    for y in range(h):
        for x in range(w):
            p00, p01, p02 = L(x - 1, y - 1), L(x, y - 1), L(x + 1, y - 1)
            p10, p12 = L(x - 1, y), L(x + 1, y)
            p20, p21, p22 = L(x - 1, y + 1), L(x, y + 1), L(x + 1, y + 1)
            gx = (p02 + 2 * p12 + p22) - (p00 + 2 * p10 + p20)
            gy = (p20 + 2 * p21 + p22) - (p00 + 2 * p01 + p02)
            m = to_byte(math.sqrt(gx * gx + gy * gy))
            out[4 * (y * w + x):4 * (y * w + x) + 3] = bytes([m, m, m])
    return (w, h, bytes(out))

# ---------------------------------------------------------------- geometry
def from_fn(w, h, f):
    return (w, h, b''.join(bytes(f(x, y)) for y in range(h) for x in range(w)))

def crop(img, x0, y0, cw, ch):
    w, h, d = img
    x1 = min(x0 + cw, w); y1 = min(y0 + ch, h)
    return from_fn(x1 - x0, y1 - y0, lambda x, y: px(img, x0 + x, y0 + y))

def rot_cw(img):  w, h, _ = img; return from_fn(h, w, lambda x, y: px(img, y, h - 1 - x))
def rot_ccw(img): w, h, _ = img; return from_fn(h, w, lambda x, y: px(img, w - 1 - y, x))
def rot180(img):  w, h, _ = img; return from_fn(w, h, lambda x, y: px(img, w - 1 - x, h - 1 - y))
def flip_h(img):  w, h, _ = img; return from_fn(w, h, lambda x, y: px(img, w - 1 - x, y))
def flip_v(img):  w, h, _ = img; return from_fn(w, h, lambda x, y: px(img, x, h - 1 - y))

def sample(sn, dn, i):
    p = (2 * i + 1) * sn * 256 // (2 * dn) - 128
    p = 0 if p < 0 else min(p, (sn - 1) * 256)
    return p // 256, min(p // 256 + 1, sn - 1), p % 256

def resize(img, dw, dh):
    sw, sh, d = img
    def f(x, y):
        x0, x1, fx = sample(sw, dw, x); y0, y1, fy = sample(sh, dh, y)
        ps = [px(img, x0, y0), px(img, x1, y0), px(img, x0, y1), px(img, x1, y1)]
        ws = [(256 - fx) * (256 - fy), fx * (256 - fy), (256 - fx) * fy, fx * fy]
        straight = [(sum(wv * p[c] for wv, p in zip(ws, ps)) + 32768) >> 16 for c in range(4)]
        sa = sum(wv * p[3] for wv, p in zip(ws, ps))
        if all(p[3] == 255 for p in ps) or sa == 0: return straight
        cols = [min(255, (sum(wv * p[3] * p[c] for wv, p in zip(ws, ps)) + sa // 2) // sa) for c in range(3)]
        return cols + [straight[3]]
    return from_fn(dw, dh, f)

def box(img, dw, dh):
    sw, sh, d = img
    def f(x, y):
        c0, c1 = x * sw // dw, (x + 1) * sw // dw
        r0, r1 = y * sh // dh, (y + 1) * sh // dh
        c1 = max(c1, c0 + 1); r1 = max(r1, r0 + 1)
        ps = [px(img, xx, yy) for yy in range(r0, r1) for xx in range(c0, c1)]
        n = len(ps); sa = sum(p[3] for p in ps)
        if sa == 0: cols = [(sum(p[c] for p in ps) + n // 2) // n for c in range(3)]
        else: cols = [(sum(p[3] * p[c] for p in ps) + sa // 2) // sa for c in range(3)]
        return cols + [(sa + n // 2) // n]
    return from_fn(dw, dh, f)

# ---------------------------------------------------------------- compositing
def blend_fn(m, cb, cs):
    if m == 'normal': return cs
    if m == 'multiply': return div255(cb * cs)
    if m == 'screen': return cb + cs - div255(cb * cs)
    if m == 'overlay': return div255(2 * cb * cs) if 2 * cb <= 255 else 255 - div255(2 * (255 - cb) * (255 - cs))
    if m == 'darken': return min(cb, cs)
    if m == 'lighten': return max(cb, cs)
    if m == 'add': return min(255, cb + cs)
    if m == 'difference': return abs(cb - cs)

def composite(bot, top, opacity, m):
    w, h, d = bot; t = top[2]
    op = (min(opacity, 100) * 255 + 50) // 100
    out = bytearray(d)
    for i in range(0, len(d), 4):
        a_s = div255(t[i + 3] * op)
        if a_s == 0: continue
        ab = d[i + 3]
        ao2 = a_s * 255 + ab * (255 - a_s)
        for c in range(3):
            csp = (255 - ab) * t[i + c] + ab * blend_fn(m, d[i + c], t[i + c])
            num = a_s * csp + ab * (255 - a_s) * d[i + c]
            out[i + c] = min(255, (num + ao2 // 2) // ao2)
        out[i + 3] = div255(ao2)
    return (w, h, bytes(out))

# ---------------------------------------------------------------- painting
def dab(img, cx, cy, r, hard, opacity, color, erase=False):
    w, h, d = img
    hard = max(0.0, min(1.0, hard)); opacity = max(0.0, min(1.0, opacity))
    rr = r + 0.5
    fl = lambda v, n: 0 if v <= 0 else min(n, int(math.floor(v)))
    cl = lambda v, n: 0 if v <= 0 else min(n, int(math.ceil(v)))
    x0, y0, x1, y1 = fl(cx - rr, w), fl(cy - rr, h), cl(cx + rr, w), cl(cy + rr, h)
    inner = hard * r; span = r - inner; span = span if span > 0 else 1.0
    ca = opacity if erase else opacity * float(color[3]) * (1 / 255)
    out = bytearray(d)
    for y in range(y0, y1):
        dy = float(y) + 0.5 - cy; dy2 = dy * dy
        for x in range(x0, x1):
            dx = float(x) + 0.5 - cx
            dist = math.sqrt(dx * dx + dy2)
            edge = r + 0.5 - dist
            if edge <= 0: continue
            edge = min(edge, 1.0)
            near = dist - 0.5
            if near <= inner: fall = 1.0
            else:
                t = min((near - inner) / span, 1.0); fall = 1 - t * t * (3 - 2 * t)
            s = ca * fall * edge
            if s <= 0: continue
            o = 4 * (y * w + x)
            ab = float(out[o + 3]) * (1 / 255)
            if erase: out[o + 3] = to_byte(ab * (1 - s) * 255)
            else:
                ao = s + ab * (1 - s); kb = ab * (1 - s) / ao; ks = s / ao
                for c in range(3): out[o + c] = to_byte(ks * float(color[c]) + kb * float(out[o + c]))
                out[o + 3] = to_byte(ao * 255)
    return (w, h, bytes(out))

def stroke(img, x0, y0, x1, y1, radius, hard, opacity, color):
    dx, dy = x1 - x0, y1 - y0
    ln = math.sqrt(dx * dx + dy * dy); spacing = max(1.0, radius / 4)
    n = int(math.ceil(ln / spacing))
    if n == 0: return dab(img, x0, y0, radius, hard, opacity, color)
    for i in range(0, n + 1):
        t = float(i) / float(n)
        img = dab(img, x0 + dx * t, y0 + dy * t, radius, hard, opacity, color)
    return img

# ---------------------------------------------------------------- PNG (stored)
def png_stored(img):
    w, h, d = img
    raw = b''.join(b'\x00' + d[4 * w * y:4 * w * (y + 1)] for y in range(h))
    z = b'\x78\x01'
    off = 0
    while True:
        ln = min(65535, len(raw) - off); final = off + ln >= len(raw)
        z += bytes([1 if final else 0]) + struct.pack('<HH', ln, ln ^ 0xffff) + raw[off:off + ln]
        off += ln
        if final: break
    z += struct.pack('>I', zlib.adler32(raw))
    def chunk(t, data): return struct.pack('>I', len(data)) + t + data + struct.pack('>I', zlib.crc32(t + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + \
        chunk(b'IDAT', z) + chunk(b'IEND', b'')

# ---------------------------------------------------------------- goldens
base = noise(37, 23, 7); top = noise(37, 23, 11); opaque = noise(37, 23, 5, False)
filled = lambda w, h, c: (w, h, bytes(c) * (w * h))
adjustments = [
    ("brightness +30", {'brightness': 30}), ("brightness -45", {'brightness': -45}),
    ("contrast +40", {'contrast': 40}), ("contrast -60", {'contrast': -60}),
    ("exposure +1", {'exposure': 1.0}), ("exposure -1.5", {'exposure': -1.5}),
    ("saturation +50", {'saturation': 50}), ("saturation -100", {'saturation': -100}),
    ("hue +90", {'hue': 90}), ("hue -150", {'hue': -150}),
    ("levels 20 230 1.5", {'inBlack': 20, 'inWhite': 230, 'gamma': 1.5}),
    ("curve", {'curve': [(64, 40), (192, 220)]}), ("invert", {'invert': True}), ("grayscale", {'grayscale': True}),
    ("everything", {'brightness': 10, 'contrast': 20, 'exposure': 0.5, 'saturation': 30, 'hue': 45, 'inBlack': 5,
                    'inWhite': 250, 'gamma': 0.8, 'curve': [(128, 150)], 'invert': True})]
g = [("base", cs(base)), ("top", cs(top)), ("opaque base", cs(opaque))]
for n, a in adjustments: g.append((f"adjust {n}", cs(adjust(a, base))))
hs = histogram(base)
g.append(("histogram", fnv_bytes(b''.join(bytes([v & 255, (v >> 8) & 255]) for v in hs))))
g.append(("blur 2", cs(blur(base, 2.0))))
g.append(("blur 5.5", cs(blur(base, 5.5))))
g.append(("blur 1 opaque", cs(blur(opaque, 1.0))))
g.append(("sharpen 1.5 2 4", cs(sharpen(base, 1.5, 2.0, 4))))
g.append(("emboss", cs(convolve(base, [-2, -1, 0, -1, 1, 1, 0, 1, 2], 1, 0))))
g.append(("edges", cs(edges(base))))
g.append(("convolve sharpen", cs(convolve(base, [0, -1, 0, -1, 5, -1, 0, -1, 0], 1, 0))))
g.append(("convolve box", cs(convolve(base, [1] * 9, 9, 0))))
g.append(("crop", cs(crop(base, 5, 3, 20, 11))))
g.append(("rotate90cw", cs(rot_cw(base)))); g.append(("rotate90ccw", cs(rot_ccw(base))))
g.append(("rotate180", cs(rot180(base)))); g.append(("flipH", cs(flip_h(base)))); g.append(("flipV", cs(flip_v(base))))
g.append(("resize 50x31", cs(resize(base, 50, 31)))); g.append(("resize 19x12", cs(resize(base, 19, 12))))
g.append(("resize opaque 61x9", cs(resize(opaque, 61, 9))))
g.append(("downscaleBox 9x6", cs(box(base, 9, 6)))); g.append(("downscaleBox opaque 10x7", cs(box(opaque, 10, 7))))
for m in ['normal', 'multiply', 'screen', 'overlay', 'darken', 'lighten', 'add', 'difference']:
    g.append((f"composite {m} 70", cs(composite(base, top, 70, m))))
g.append(("composite normal 100 opaque", cs(composite(base, opaque, 100, 'normal'))))
g.append(("dab", cs(dab(filled(37, 23, [128, 128, 128, 255]), 12.3, 9.7, 6.0, 0.3, 0.8, [255, 0, 0, 255]))))
g.append(("dab erase", cs(dab(base, 20.0, 11.0, 7.5, 0.6, 0.9, [0, 0, 0, 255], True))))
g.append(("stroke", cs(stroke(base, 2.0, 3.0, 33.0, 19.0, 3.0, 0.8, 0.5, [20, 200, 90, 200]))))
g.append(("png level 0", fnv_bytes(png_stored(base))))
if len(sys.argv) > 1:
    import re
    text = open(sys.argv[1]).read()
    table = text[text.index('def goldens'):]
    table = table[:table.index('def testGoldens')]
    pinned = dict(re.findall(r'\("([^"]+)", (\d+)\)', table))
    bad = [n for n, v in g if pinned.get(n) != str(v)]
    for n in bad:
        print(f'MISMATCH {n}: pinned {pinned.get(n)}, reference {dict(g)[n]}')
    print(f'{len(g) - len(bad)} of {len(g)} reference values match; '
          f'{len(pinned) - len(g)} pinned values have no reference')
    sys.exit(1 if bad else 0)
for n, v in g:
    print(f'  ("{n}", {v}),')
