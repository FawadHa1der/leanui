#!/usr/bin/env python3
"""Build the small PNG fixtures of tests/Editor.lean (`pngFixtures`) with Python's zlib.

Each fixture: a PNG file (hex) and the RGBA8 pixels a decoder must produce (hex), both computed
here from pixel formulas, independently of the Lean code. Rows use filters 0..4 in turn (applied
with the textbook definitions), the zlib stream is level 9, and the script checks that the first
deflate block is a dynamic Huffman block (BTYPE = 2) where the fixture says so.
"""
import struct, zlib, sys

def chunk(t, data):
    return struct.pack('>I', len(data)) + t + data + struct.pack('>I', zlib.crc32(t + data) & 0xffffffff)

def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc: return a
    if pb <= pc: return b
    return c

def filt(rows, bpp):
    out = b''
    prev = bytes(len(rows[0]))
    for y, row in enumerate(rows):
        ft = y % 5
        f = bytearray()
        for i, x in enumerate(row):
            a = row[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            pred = [0, a, b, (a + b) // 2, paeth(a, b, c)][ft]
            f.append((x - pred) & 255)
        out += bytes([ft]) + bytes(f)
        prev = row
    return out

def png(w, h, ct, rows, bpp, extra=b'', need_dynamic=True, level=9):
    raw = filt(rows, bpp)
    z = zlib.compress(raw, level)
    btype = (z[2] >> 1) & 3
    if need_dynamic and btype != 2:
        sys.exit(f'fixture {w}x{h} ct{ct}: first block type {btype}, not dynamic')
    ihdr = struct.pack('>IIBBBBB', w, h, 8, ct, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + extra + chunk(b'IDAT', z) + chunk(b'IEND', b''), btype

fixtures = []

# 1. RGBA 16x12 gradient-ish
w, h = 16, 12
pix = lambda x, y: (x * 16 % 256, y * 20 % 256, (x * y) & 255, 255 - x * 8)
rows = [bytes(v for x in range(w) for v in pix(x, y)) for y in range(h)]
f, bt = png(w, h, 6, rows, 4)
fixtures.append(('rgba16x12', w, h, f, b''.join(rows), bt))

# 2. RGB 9x7 with a tRNS colour key (10, 20, 30)
w, h = 9, 7
def pix2(x, y):
    return (10, 20, 30) if (x + y) % 4 == 0 else ((x * 28) % 256, (y * 36) % 256, (x * 3 + y * 5) % 256)
rows = [bytes(v for x in range(w) for v in pix2(x, y)) for y in range(h)]
trns = chunk(b'tRNS', struct.pack('>HHH', 10, 20, 30))
f, bt = png(w, h, 2, rows, 3, trns, need_dynamic=False)
exp = b''.join(bytes(v for x in range(w) for v in pix2(x, y) + ((0,) if pix2(x, y) == (10, 20, 30) else (255,))) for y in range(h))
fixtures.append(('rgb9x7trns', w, h, f, exp, bt))

# 3. gray 11x5 with tRNS gray 77
w, h = 11, 5
g = lambda x, y: 77 if x == y else (x * 23 + y * 41) % 256
rows = [bytes(g(x, y) for x in range(w)) for y in range(h)]
f, bt = png(w, h, 0, rows, 1, chunk(b"tRNS", struct.pack(">H", 77)), need_dynamic=False)
exp = b''.join(bytes(v for x in range(w) for v in (g(x, y),) * 3 + ((0,) if g(x, y) == 77 else (255,))) for y in range(h))
fixtures.append(('gray11x5trns', w, h, f, exp, bt))

# 4. palette 6x5, 7 colours, tRNS for the first 3 entries
w, h = 6, 5
pal = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (17, 34, 51), (200, 100, 50), (1, 2, 3), (250, 250, 250)]
alphas = [0, 128, 200]
idx = lambda x, y: (x * 3 + y) % 7
rows = [bytes(idx(x, y) for x in range(w)) for y in range(h)]
extra = chunk(b'PLTE', bytes(v for c in pal for v in c)) + chunk(b'tRNS', bytes(alphas))
f, bt = png(w, h, 3, rows, 1, extra, need_dynamic=False)
def rgba3(i):
    return pal[i] + ((alphas[i],) if i < len(alphas) else (255,))
exp = b''.join(bytes(v for x in range(w) for v in rgba3(idx(x, y))) for y in range(h))
fixtures.append(('pal6x5', w, h, f, exp, bt))

# 5. gray + alpha 7x3
w, h = 7, 3
ga = lambda x, y: ((x * 37 + y) % 256, (255 - x * 30 - y * 7) % 256)
rows = [bytes(v for x in range(w) for v in ga(x, y)) for y in range(h)]
f, bt = png(w, h, 4, rows, 2, need_dynamic=False)
exp = b''.join(bytes(v for x in range(w) for v in (ga(x, y)[0],) * 3 + (ga(x, y)[1],)) for y in range(h))
fixtures.append(('grayalpha7x3', w, h, f, exp, bt))

# 6. a larger RGBA image (64x40) at zlib level 1 (several blocks may appear), multiple IDAT chunks
w, h = 64, 40
pix6 = lambda x, y: ((x * x + y) % 256, (y * 3 + x // 4) % 256, (x ^ y) % 256, 255 if (x // 8 + y // 8) % 2 else 90)
rows = [bytes(v for x in range(w) for v in pix6(x, y)) for y in range(h)]
raw = filt(rows, 4)
z = zlib.compress(raw, 6)
ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
parts = [z[:100], z[100:101], z[101:]]
f = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'tEXt', b'Comment\x00split IDAT') + \
    b''.join(chunk(b'IDAT', p) for p in parts) + chunk(b'IEND', b'')
fixtures.append(('rgba64x40split', w, h, f, b''.join(rows), (z[2] >> 1) & 3))

# printed as hex: PNG file, then the RGBA pixels (the test computes the last fixture's pixels itself)
for name, w, h, f, exp, bt in fixtures:
    print(f'-- {name}: {w}x{h}, {len(f)} bytes, first block type {bt}')
    print(f'("{name}", {w}, {h},\n  "{f.hex()}",\n  "{exp.hex()}"),')
