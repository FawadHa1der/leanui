#!/usr/bin/env python3
"""Decode the PNG files written by `leanui-editor-tests --write-pngs DIR` (or
`leanui-editor-perf png-out DIR`) with Python's zlib, and compare them with the raw RGBA files next
to them: chunk CRCs, the zlib stream (zlib checks the Adler-32), the row filters, the pixels."""
import glob, os, struct, sys, zlib

def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else b if pb <= pc else c

def decode(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, idat, ihdr = 8, b'', None
    while pos < len(data):
        ln, = struct.unpack('>I', data[pos:pos + 4]); t = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        crc, = struct.unpack('>I', data[pos + 8 + ln:pos + 12 + ln])
        assert zlib.crc32(t + body) == crc, f'{path}: bad CRC in {t}'
        if t == b'IHDR': ihdr = struct.unpack('>IIBBBBB', body)
        if t == b'IDAT': idat += body
        pos += 12 + ln
    w, h, depth, ct, _, _, il = ihdr
    assert (depth, ct, il) == (8, 6, 0)
    raw = zlib.decompress(idat)
    rb = 4 * w
    assert len(raw) == h * (rb + 1)
    out, prev = bytearray(), bytearray(rb)
    filters = [0] * 5
    for y in range(h):
        ft = raw[y * (rb + 1)]; filters[ft] += 1
        row = bytearray(raw[y * (rb + 1) + 1:(y + 1) * (rb + 1)])
        for i in range(rb):
            a = row[i - 4] if i >= 4 else 0
            b = prev[i]; c = prev[i - 4] if i >= 4 else 0
            row[i] = (row[i] + [0, a, b, (a + b) // 2, paeth(a, b, c)][ft]) & 255
        out += row; prev = row
    return w, h, bytes(out), filters, len(data)

ok = True
for path in sorted(glob.glob(os.path.join(sys.argv[1], '*.png'))):
    w, h, px, filters, size = decode(path)
    want = open(path.rsplit('-level', 1)[0] + '.rgba', 'rb').read()
    same = px == want
    ok &= same
    print(f'{os.path.basename(path)}: {size} bytes, filters {filters}, pixels {"match" if same else "DIFFER"}')
sys.exit(0 if ok else 1)
