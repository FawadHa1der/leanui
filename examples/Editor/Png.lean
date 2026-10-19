module
public import Editor.Image
/-!
# PNG encoding and decoding

**Encoding** (`encode img level`) writes 8-bit RGBA (colour type 6), non-interlaced, as one `IDAT`
chunk holding a zlib stream:

* `level = 0`: every row unfiltered (filter byte 0) in deflate *stored* blocks of at most 65535
  bytes: no compression, just copies, a CRC-32 and an Adler-32.
* `level ≥ 1`: each row gets the filter (Sub, Up or Paeth) whose output has the smallest sum of
  absolute values (as signed bytes), then one deflate block with the *fixed* Huffman code and
  LZ77 matches found through hash chains of at most `4 · 2 ^ (level - 1)` links (greedy
  matching). Below level 6, the positions inside a match longer than `4 · level` bytes are not
  hashed, as zlib's fast levels do, so long runs cost one step instead of one per byte.

**Decoding** (`decode bytes`) reads colour types 0 (gray), 2 (RGB), 3 (palette), 4 (gray + alpha)
and 6 (RGBA) at bit depth 8, non-interlaced, with `tRNS` transparency, into RGBA8. Chunk CRCs and
the zlib Adler-32 are checked. The inflater handles stored, fixed and dynamic Huffman blocks; its
symbol loop decodes through a 1024-entry table (codes of up to 10 bits; longer ones bit by bit, as
`puff` does), keeps the bit buffer in a `UInt64` and writes into the preallocated output buffer.
Other bit depths and interlaced images are reported as errors.
-/
public section
namespace Editor.Png

/-! ## Checksums -/

/-- The CRC-32 table (polynomial `0xEDB88320`). -/
def crcTable : Array UInt32 := (Array.range 256).map fun (n : Nat) => Id.run do
  let mut c : UInt32 := n.toUInt32
  for _ in [0:8] do c := if c &&& 1 != 0 then (0xEDB88320 : UInt32) ^^^ (c >>> 1) else c >>> 1
  return c

partial def crcLoop (t : @& Array UInt32) (d : @& ByteArray) (n : USize) (hn : InRange d n) (i : USize) (c : UInt32) :
    UInt32 :=
  if hi : i < n then crcLoop t d n hn (i + 1) (rdW t ((c ^^^ (d.uget i (hn.lt hi)).toUInt32) &&& 0xff).toUSize ^^^ (c >>> 8))
  else c

/-- CRC-32 of bytes `start .. stop - 1` of `d`. -/
def crc32 (d : ByteArray) (start stop : Nat) : UInt32 :=
  let ⟨n, hn⟩ := rangeOf d (min stop d.size).toUSize
  crcLoop crcTable d n hn start.toUSize 0xFFFFFFFF ^^^ 0xFFFFFFFF

/-- The Adler-32 sums over bytes `i .. e - 1`, reduced modulo 65521 at the end only (`e - i` is at
most 5552, the longest run whose sums cannot overflow 32 bits), packed as `b <<< 32 ||| a`. -/
partial def adlerBlock (d : @& ByteArray) (e : USize) (he : InRange d e) (i : USize) (a b : UInt64) : UInt64 :=
  if hi : i < e then
    let a := a + (d.uget i (he.lt hi)).toUInt64
    adlerBlock d e he (i + 1) a (b + a)
  else ((b % 65521) <<< 32) ||| (a % 65521)

partial def adlerLoop (d : @& ByteArray) (n : USize) (hn : InRange d n) (i : USize) (a b : UInt64) : UInt32 :=
  if i < n then
    let e := if n - i > 5552 then i + 5552 else n
    if he : e ≤ n then
      let ab := adlerBlock d e (Nat.le_trans (USize.le_iff_toNat_le.mp he) hn) i a b
      adlerLoop d n hn e (ab &&& 0xffffffff) (ab >>> 32)
    else 0
  else ((b <<< 16) ||| a).toUInt32

/-- Adler-32 of bytes `start .. stop - 1` of `d`. -/
def adler32 (d : ByteArray) (start stop : Nat) : UInt32 :=
  let ⟨n, hn⟩ := rangeOf d (min stop d.size).toUSize
  adlerLoop d n hn start.toUSize 1 0

/-! ## Byte helpers -/

def pushU32BE (b : ByteArray) (v : UInt32) : ByteArray :=
  b.push (v >>> 24).toUInt8 |>.push (v >>> 16).toUInt8 |>.push (v >>> 8).toUInt8 |>.push v.toUInt8

def setU32BE (b : ByteArray) (i : Nat) (v : UInt32) : ByteArray :=
  b.set! i (v >>> 24).toUInt8 |>.set! (i + 1) (v >>> 16).toUInt8 |>.set! (i + 2) (v >>> 8).toUInt8
    |>.set! (i + 3) v.toUInt8

def readU32BE (b : ByteArray) (i : Nat) : Nat :=
  (b.get! i).toNat <<< 24 ||| (b.get! (i + 1)).toNat <<< 16 ||| (b.get! (i + 2)).toNat <<< 8 ||| (b.get! (i + 3)).toNat

def signature : ByteArray := ⟨#[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]⟩

/-- Append a chunk: length, type, data, CRC of type and data. -/
def pushChunk (out : ByteArray) (type : String) (data : ByteArray) : ByteArray :=
  let out := pushU32BE out data.size.toUInt32
  let start := out.size
  let out := out ++ type.toUTF8 ++ data
  pushU32BE out (crc32 out start out.size)

/-! ## Row filters -/

/-- The Paeth predictor. -/
@[inline] def paeth (a b c : UInt32) : UInt32 :=
  let pa := if b ≥ c then b - c else c - b
  let pb := if a ≥ c then a - c else c - a
  let s := a + b
  let t := 2 * c
  let pc := if s ≥ t then s - t else t - s
  if pa ≤ pb && pa ≤ pc then a else if pb ≤ pc then b else c

/-- |v| for a byte read as signed. -/
@[inline] def sabs (v : UInt32) : UInt32 := let v := v &&& 0xff; if v < 128 then v else 256 - v

/-- The filter type, Sub (1), Up (2) or Paeth (4), whose output for the row at `cur` (previous
row at `prior` when `hasPrior`; 4 bytes per pixel) has the smallest sum of |byte as signed| over
bytes `i .. rb - 1`, given the sums so far (all three in one pass over the row). Ties go to the
earlier of Sub, Up, Paeth. -/
partial def bestFilter (src : @& ByteArray) (cur prior rb : USize) (hc : RowIn src cur rb) (hasPrior : Bool)
    (hp : hasPrior = true → RowIn src prior rb) (i : USize) (s1 s2 s4 : UInt32) : UInt32 :=
  if hi : i < rb then
    let x := (rowGet src cur rb hc i hi).toUInt32
    let a := if hk : 4 ≤ i then (rowBack src cur rb hc i 4 hi hk).toUInt32 else 0
    let b := if h : hasPrior = true then (rowGet src prior rb (hp h) i hi).toUInt32 else 0
    let c := if h : hasPrior = true then
      (if hk : 4 ≤ i then (rowBack src prior rb (hp h) i 4 hi hk).toUInt32 else 0) else 0
    bestFilter src cur prior rb hc hasPrior hp (i + 1) (s1 + sabs (x - a)) (s2 + sabs (x - b)) (s4 + sabs (x - paeth a b c))
  else if s2 < s1 then (if s4 < s2 then 4 else 2) else if s4 < s1 then 4 else 1

/-- Write the row at `cur` filtered by `ft` (1, 2 or 4) to `raw` at `o`. -/
partial def filterRow (src : @& ByteArray) (raw : ByteArray) (ft : UInt32) (cur prior rb : USize)
    (hc : RowIn src cur rb) (hasPrior : Bool) (hp : hasPrior = true → RowIn src prior rb) (o : USize)
    (ho : RowIn raw o rb) (i : USize) : ByteArray :=
  if hi : i < rb then
    let x := rowGet src cur rb hc i hi
    let v :=
      if ft == 1 then x - (if hk : 4 ≤ i then rowBack src cur rb hc i 4 hi hk else 0)
      else if ft == 2 then x - (if h : hasPrior = true then rowGet src prior rb (hp h) i hi else 0)
      else
        let a := if hk : 4 ≤ i then (rowBack src cur rb hc i 4 hi hk).toUInt32 else 0
        let b := if h : hasPrior = true then (rowGet src prior rb (hp h) i hi).toUInt32 else 0
        let c := if h : hasPrior = true then
          (if hk : 4 ≤ i then (rowBack src prior rb (hp h) i 4 hi hk).toUInt32 else 0) else 0
        x - (paeth a b c).toUInt8
    filterRow src (raw.uset (o + i) v (ho.lt hi)) ft cur prior rb hc hasPrior hp o (ho.uset _ _ _) (i + 1)
  else raw

/-- Whether there is a previous row at `prior` (`y > 0`), with the proof that it is in range. -/
@[inline] def priorRow (a : ByteArray) (y prior rb : USize) : { b : Bool // b = true → RowIn a prior rb } :=
  if h : y > 0 ∧ RowIn a prior rb then ⟨true, fun _ => h.2⟩ else ⟨false, fun h => nomatch h⟩

/-- Filter rows `y .. h - 1` into `raw` (each row: a filter byte, then `rb` bytes). -/
partial def filterRows (src : @& ByteArray) (raw : ByteArray) (y h rb : USize) : ByteArray :=
  if y < h then
    let cur := y * rb
    let prior := cur - rb
    let o := y * (rb + 1)
    if hc : RowIn src cur rb then
      let ⟨hasPrior, hp⟩ := priorRow src y prior rb
      let ft := bestFilter src cur prior rb hc hasPrior hp 0 0 0 0
      let raw := wr32 raw o ft
      if ho : RowIn raw (o + 1) rb then
        filterRows src (filterRow src raw ft cur prior rb hc hasPrior hp (o + 1) ho 0) (y + 1) h rb
      else raw
    else raw
  else raw

/-- The unfiltered scanlines: filter byte 0, then the row. -/
partial def plainRows (src : @& ByteArray) (raw : ByteArray) (y h rb : Nat) : ByteArray :=
  if y < h then plainRows src (src.copySlice (y * rb) raw (y * (rb + 1) + 1) rb) (y + 1) h rb else raw

/-! ## Deflate: fixed Huffman code and LZ77 -/

def lenBase : Array UInt32 := #[3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99,
  115, 131, 163, 195, 227, 258]
def lenExtra : Array UInt32 := #[0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
def distBase : Array UInt32 := #[1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025,
  1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
def distExtra : Array UInt32 := #[0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12,
  12, 13, 13]

/-- The low `n` bits of `v`, reversed (Huffman codes are sent most significant bit first, the
bit stream least significant bit first). -/
def reverseBits (v : UInt32) (n : Nat) : UInt32 := Id.run do
  let mut r : UInt32 := 0
  for i in [0:n] do r := r ||| (((v >>> i.toUInt32) &&& 1) <<< (n - 1 - i).toUInt32)
  return r

/-- The fixed literal/length code of `sym`: `(reversed code) ||| (length <<< 16)`. -/
def fixedLitCode (sym : Nat) : UInt32 :=
  let (code, len) :=
    if sym < 144 then (0x30 + sym, 8) else if sym < 256 then (0x190 + sym - 144, 9)
    else if sym < 280 then (sym - 256, 7) else (0xC0 + sym - 280, 8)
  reverseBits code.toUInt32 len ||| (len.toUInt32 <<< 16)

/-- Literal codes for bytes 0..255 and the end-of-block code (index 256). -/
def litCodes : Array UInt32 := (Array.range 257).map fixedLitCode

/-- For match length `L` (3..258): the length symbol's code followed by its extra bits, as
`bits ||| (count <<< 16)` (at most 13 bits). -/
def lenCodes : Array UInt32 := (Array.range 259).map fun (l : Nat) =>
  if l < 3 then (0 : UInt32) else Id.run do
    let mut k : Nat := 0
    for i in [0:29] do if lenBase[i]!.toNat ≤ l then k := i
    let c : UInt32 := fixedLitCode (257 + k)
    let clen : UInt32 := c >>> (16 : UInt32)
    let bits : UInt32 := (c &&& (0xffff : UInt32)) ||| ((l.toUInt32 - lenBase[k]!) <<< clen)
    return bits ||| ((clen + lenExtra[k]!) <<< (16 : UInt32))

/-- The distance code for distances 1..256 (index `d - 1`) and, from index 256, for larger
distances by `(d - 1) >>> 7`. -/
def distCodes : Array UInt32 := Id.run do
  let code (d : Nat) : UInt32 := Id.run do
    let mut k : UInt32 := 0
    for i in [0:30] do if distBase[i]!.toNat ≤ d then k := i.toUInt32
    return k
  let lo := (Array.range 256).map fun i => code (i + 1)
  let hi := (Array.range 256).map fun i => code ((i <<< 7) + 1)
  return lo ++ hi

/-- Per distance code: its 5-bit code reversed, and its extra-bit count `<<< 16`. -/
def distSyms : Array UInt32 :=
  (Array.range 30).map fun (k : Nat) => reverseBits k.toUInt32 5 ||| (distExtra[k]! <<< (16 : UInt32))

/-- The distance's code followed by its extra bits, as `bits ||| (count <<< 24)`: up to 18 bits
(5 for the code, 13 extra for distances above 24576), so the count cannot share 16 bits with them. -/
@[inline] def distBits (dc syms : Array UInt32) (d : UInt32) : UInt32 :=
  let k : UInt32 := if d ≤ 256 then rdW dc (d - 1).toUSize else rdW dc (256 + ((d - 1) >>> (7 : UInt32)).toUSize)
  let k := k.toUSize
  let e : UInt32 := rdW syms k
  let bits : UInt32 := (e &&& (0xffff : UInt32)) ||| ((d - rdW distBase k) <<< (5 : UInt32))
  bits ||| (((5 : UInt32) + (e >>> (16 : UInt32))) <<< (24 : UInt32))

/-- Hash of the 3 bytes at `p` (15 bits). The guard covers 4 bytes, so the last 3 positions of
the stream are never hashed (they are sent as literals). -/
@[inline] def hash3 (src : ByteArray) (p : USize) (h : InPx src p) : USize :=
  let v := (px32 src p h 0 <<< 16) ||| (px32 src p h 1 <<< 8) ||| px32 src p h 2
  ((v * 2654435761) >>> 17).toUSize

/-- The hash table: chain heads (`0 .. 32767`, by hash) then links (`32768 + (p &&& 32767)`), each
holding a position + 1 (0: none). -/
@[inline] def insertHash (src : ByteArray) (tab : Array UInt32) (p : USize) : Array UInt32 :=
  if hp : InPx src p then
    let h := hash3 src p hp
    let tab := wrW tab (32768 + (p &&& 32767)) (rdW tab h)
    wrW tab h (p.toUInt32 + 1)
  else tab

/-- Hash positions `p .. e - 1`. -/
partial def insertRange (src : @& ByteArray) (tab : Array UInt32) (p e : USize) : Array UInt32 :=
  if p < e then insertRange src (insertHash src tab p) (p + 1) e else tab

/-- Length of the common prefix of positions `a` and `b`, from `l` up to `maxLen`: 4 bytes per
step while a whole group fits, then byte by byte. -/
partial def matchLen (src : @& ByteArray) (a b l maxLen : USize) : USize :=
  if l + 4 ≤ maxLen then
    if ha : InPx src (a + l) then
      if hb : InPx src (b + l) then
        if px src (a + l) ha 0 != px src (b + l) hb 0 then l
        else if px src (a + l) ha 1 != px src (b + l) hb 1 then l + 1
        else if px src (a + l) ha 2 != px src (b + l) hb 2 then l + 2
        else if px src (a + l) ha 3 != px src (b + l) hb 3 then l + 3
        else matchLen src a b (l + 4) maxLen
      else l
    else l
  else if l < maxLen && rd src (a + l) == rd src (b + l) then matchLen src a b (l + 1) maxLen else l

/-- Walk the chain from candidate `c1` (a position + 1) for the longest match at `p`; the best so far
is `best` (length) at distance `bestD`. Returns `length <<< 32 ||| distance`. -/
partial def longestMatch (src : @& ByteArray) (tab : @& Array UInt32) (p c1 maxLen chain best bestD : USize) : UInt64 :=
  if c1 == 0 || chain == 0 then (best.toUInt64 <<< 32) ||| bestD.toUInt64
  else
    let c := c1 - 1
    if c ≥ p || p - c > 32768 then (best.toUInt64 <<< 32) ||| bestD.toUInt64
    else
      -- check the byte that would extend the best match first
      let l := if rd src (c + best) == rd src (p + best) then matchLen src c p 0 maxLen else 0
      let (best, bestD) := if l > best then (l, p - c) else (best, bestD)
      if best ≥ maxLen then (best.toUInt64 <<< 32) ||| bestD.toUInt64
      else
        let next := (rdW tab (32768 + (c &&& 32767))).toUSize
        -- links must go back in the stream; a newer position in the slot ends the chain
        if next > c then (best.toUInt64 <<< 32) ||| bestD.toUInt64
        else longestMatch src tab p next maxLen (chain - 1) best bestD

/-- The LZ77 + fixed-Huffman loop from position `p` of `src` (length `n`), appending to `out` with
`nb` bits pending in `bb`. Ends with the end-of-block code and the last partial byte. -/
partial def lzLoop (src : @& ByteArray) (n : USize) (tab : Array UInt32) (lits lens dcs dsyms : @& Array UInt32)
    (chain maxIns p : USize) (out : ByteArray) (bb nb : UInt64) : ByteArray :=
  if nb ≥ 32 then
    let out := out.push bb.toUInt8 |>.push (bb >>> 8).toUInt8 |>.push (bb >>> 16).toUInt8 |>.push (bb >>> 24).toUInt8
    lzLoop src n tab lits lens dcs dsyms chain maxIns p out (bb >>> 32) (nb - 32)
  else if p ≥ n then
    -- end of block, then flush whole bytes
    let e := rdW lits 256
    let bb := bb ||| ((e &&& 0xffff).toUInt64 <<< nb)
    let nb := nb + (e >>> 16).toUInt64
    flush out bb nb
  else
    let maxLen := if n - p < 258 then n - p else 258
    if hp : maxLen ≥ 3 ∧ InPx src p then
      let h := hash3 src p hp.2
      let c1 := (rdW tab h).toUSize
      let tab := wrW (wrW tab (32768 + (p &&& 32767)) c1.toUInt32) h (p.toUInt32 + 1)
      let m := longestMatch src tab p c1 maxLen chain 2 0
      let len := (m >>> 32).toUSize
      if len ≥ 3 then
        let dist := m.toUInt32
        let lc := rdW lens len
        let dcode := distBits dcs dsyms dist
        let bb := bb ||| ((lc &&& 0xffff).toUInt64 <<< nb)
        let nb := nb + (lc >>> 16).toUInt64
        let bb := bb ||| ((dcode &&& 0xffffff).toUInt64 <<< nb)
        let nb := nb + (dcode >>> 24).toUInt64
        let e := p + len
        -- hash the positions inside the match, unless it is long and the level is low (as zlib's
        -- fast levels do: long runs then cost one step instead of one per byte)
        let tab := if len ≤ maxIns then insertRange src tab (p + 1) e else tab
        lzLoop src n tab lits lens dcs dsyms chain maxIns e out bb nb
      else
        let e := rdW lits (rd src p).toUSize
        lzLoop src n tab lits lens dcs dsyms chain maxIns (p + 1) out (bb ||| ((e &&& 0xffff).toUInt64 <<< nb)) (nb + (e >>> 16).toUInt64)
    else
      let e := rdW lits (rd src p).toUSize
      lzLoop src n tab lits lens dcs dsyms chain maxIns (p + 1) out (bb ||| ((e &&& 0xffff).toUInt64 <<< nb)) (nb + (e >>> 16).toUInt64)
where
  flush (out : ByteArray) (bb nb : UInt64) : ByteArray :=
    if nb == 0 then out else flush (out.push bb.toUInt8) (bb >>> 8) (if nb ≥ 8 then nb - 8 else 0)

/-- One fixed-Huffman deflate block of `src`, appended to `out`; hash chains of at most `chain`
links, positions inside matches longer than `maxIns` not hashed. -/
def deflateFixed (src : ByteArray) (chain maxIns : Nat) (out : ByteArray) : ByteArray :=
  -- block header: BFINAL = 1, BTYPE = 01 (3 bits: 1, 1, 0)
  lzLoop src src.usize (Array.replicate 65536 0) litCodes lenCodes distCodes distSyms chain.toUSize maxIns.toUSize 0
    out 3 3

/-- Deflate stored blocks (at most 65535 bytes each) of `src`, appended to `out`. -/
partial def deflateStored (src : @& ByteArray) (off : Nat) (out : ByteArray) : ByteArray :=
  let len := min 65535 (src.size - off)
  let final := off + len ≥ src.size
  let out := out.push (if final then 1 else 0) |>.push len.toUInt8 |>.push (len >>> 8).toUInt8
    |>.push ((0xff : UInt8) - len.toUInt8) |>.push ((0xff : UInt8) - (len >>> 8).toUInt8)
  let out := src.copySlice off out out.size len
  if final then out else deflateStored src (off + len) out

/-! ## Encoding -/

/-- The PNG file of `img` (8-bit RGBA). `level` 0 stores the pixels uncompressed (fastest); 1..9
filter rows and compress with LZ77 and the fixed Huffman code, searching longer hash chains at
higher levels. -/
def encode (img : Image) (level : Nat := 1) : ByteArray :=
  let w := img.width
  let h := img.height
  let rb := 4 * w
  let rawSize := h * (rb + 1)
  let raw := zeros rawSize
  let raw := if level == 0 then plainRows img.data raw 0 h rb
    else filterRows img.data raw 0 h.toUSize rb.toUSize
  let ihdr := pushU32BE (pushU32BE .empty w.toUInt32) h.toUInt32 |>.push 8 |>.push 6 |>.push 0 |>.push 0 |>.push 0
  let out := pushChunk (signature.copySlice 0 (ByteArray.emptyWithCapacity (rawSize + rawSize / 65535 * 5 + 128)) 0 8) "IHDR" ihdr
  -- IDAT: length placeholder, type, zlib stream, CRC
  let lenAt := out.size
  let out := pushU32BE out 0 ++ "IDAT".toUTF8
  let dataAt := out.size
  let out := if level == 0 then out.push 0x78 |>.push 0x01 else out.push 0x78 |>.push 0x5E
  let out := if level == 0 then deflateStored raw 0 out
    else deflateFixed raw (4 * 2 ^ (min level 9 - 1)) (if level ≥ 6 then 258 else 4 * level) out
  let out := pushU32BE out (adler32 raw 0 raw.size)
  let out := setU32BE out lenAt (out.size - dataAt).toUInt32
  let out := pushU32BE out (crc32 out (dataAt - 4) out.size)
  pushChunk out "IEND" .empty

/-! ## Inflate -/

/-- Fast-table bits: codes of at most this many bits decode with one lookup. -/
def fastBits : Nat := 10

/-- A Huffman decoding table built from code lengths: `2 ^ fastBits` entries `sym <<< 4 ||| len`
(0: no code of at most `fastBits` bits has this prefix), then the 16 counts per length, then the
symbols in canonical order. -/
def buildTable (lens : Array Nat) : Except String (Array UInt32) := do
  let mut count : Array Nat := Array.replicate 16 0
  for l in lens do
    if l > 15 then throw "bad code length"
    count := count.modify l (· + 1)
  count := count.set! 0 0
  -- over-subscribed?
  let mut left : Int := 1
  for l in [1:16] do
    left := 2 * left - (count[l]! : Int)
    if left < 0 then throw "over-subscribed Huffman code"
  -- canonical first code and symbol offset per length
  let mut next : Array Nat := Array.replicate 16 0
  let mut offs : Array Nat := Array.replicate 16 0
  let mut code : Nat := 0
  for l in [1:16] do
    code := (code + count[l - 1]!) <<< 1
    next := next.set! l code
    if l > 1 then offs := offs.set! l (offs[l - 1]! + count[l - 1]!)
  let fast := 1 <<< fastBits
  let nsym := lens.size
  let mut t : Array UInt32 := Array.replicate (fast + 16 + nsym) 0
  for l in [1:16] do
    t := t.set! (fast + l) count[l]!.toUInt32
  let mut pos := offs
  for s in [0:nsym] do
    let l := lens[s]!
    if l > 0 then
      t := t.set! (fast + 16 + pos[l]!) s.toUInt32
      pos := pos.modify l (· + 1)
      let c := next[l]!
      next := next.set! l (c + 1)
      if l ≤ fastBits then
        let r := (reverseBits c.toUInt32 l).toNat
        for k in [0:1 <<< (fastBits - l)] do
          t := t.set! (r ||| (k <<< l)) ((s.toUInt32 <<< 4) ||| l.toUInt32)
  return t

/-- Decode bit by bit (codes longer than `fastBits`): `sym <<< 4 ||| len`, or 0 for no code. -/
partial def slowDecode (t : @& Array UInt32) (bb : UInt64) (len : USize) (code first index : UInt32) : UInt32 :=
  if len > 15 then 0
  else
    let code := code ||| ((bb >>> (len - 1).toUInt64) &&& 1).toUInt32
    let count := rdW t (1024 + len)
    if code < first + count then
      ((rdW t (1040 + (index + code - first).toUSize)) <<< 4) ||| len.toUInt32
    else
      slowDecode t bb (len + 1) (code <<< 1) ((first + count) <<< 1) (index + count)

/-- The symbol at the front of the bit buffer: `sym <<< 4 ||| len`, or 0. -/
@[inline] def decodeSym (t : Array UInt32) (bb : UInt64) : UInt32 :=
  let e := rdW t (bb &&& 1023).toUSize
  if e != 0 then e else slowDecode t bb 1 0 0 0

/-- What the symbol loop returns at the end of a block (or on an error, `err ≠ 0`). -/
structure Inflated where
  out : ByteArray
  op : USize
  pos : USize
  bb : UInt64
  nb : UInt64
  err : UInt32
  deriving Inhabited

/-- Copy `n` bytes from `d` bytes back (overlapping copies repeat): 4 bytes at a time when the
4 source bytes end before the destination (`d ≥ 4`). -/
partial def copyMatch (out : ByteArray) (o d n : USize) : ByteArray :=
  if n ≥ 4 && d ≥ 4 then
    if hs : InPx out (o - d) then
      if ho : InPx out o then copyMatch (copyPx out (o - d) hs out o ho) (o + 4) d (n - 4)
      else out
    else out
  else if n == 0 then out else copyMatch (wr out o (rd out (o - d))) (o + 1) d (n - 1)

/-- The symbol loop of a Huffman block. Errors: 1 bad code, 2 out of input, 3 output overflow,
4 distance too far back. -/
partial def huffLoop (src : @& ByteArray) (n pos : USize) (bb nb : UInt64) (out : ByteArray) (op lim : USize)
    (lit dist : @& Array UInt32) : Inflated :=
  if nb < 48 && pos < n then
    huffLoop src n (pos + 1) (bb ||| ((rd src pos).toUInt64 <<< nb)) (nb + 8) out op lim lit dist
  else
    let e := decodeSym lit bb
    let l := (e &&& 15).toUInt64
    if e == 0 then ⟨out, op, pos, bb, nb, 1⟩
    else if l > nb then ⟨out, op, pos, bb, nb, 2⟩
    else
      let sym := e >>> 4
      let bb := bb >>> l
      let nb := nb - l
      if sym < 256 then
        if op < lim then
          if h : op < out.usize then
            huffLoop src n pos bb nb (out.uset op sym.toUInt8 (lt_size_of_lt_usize h)) (op + 1) lim lit dist
          else ⟨out, op, pos, bb, nb, 3⟩
        else ⟨out, op, pos, bb, nb, 3⟩
      else if sym == 256 then ⟨out, op, pos, bb, nb, 0⟩
      else
        let li := (sym - 257).toUSize
        if li ≥ 29 then ⟨out, op, pos, bb, nb, 1⟩
        else
          let eb := (rdW lenExtra li).toUInt64
          if eb > nb then ⟨out, op, pos, bb, nb, 2⟩
          else
            let len := (rdW lenBase li).toUSize + (bb &&& (((1 : UInt64) <<< eb) - 1)).toUSize
            let bb := bb >>> eb
            let nb := nb - eb
            let e2 := decodeSym dist bb
            let l2 := (e2 &&& 15).toUInt64
            if e2 == 0 then ⟨out, op, pos, bb, nb, 1⟩
            else if l2 > nb then ⟨out, op, pos, bb, nb, 2⟩
            else
              let ds := (e2 >>> 4).toUSize
              let bb := bb >>> l2
              let nb := nb - l2
              if ds ≥ 30 then ⟨out, op, pos, bb, nb, 1⟩
              else
                let db := (rdW distExtra ds).toUInt64
                if db > nb then ⟨out, op, pos, bb, nb, 2⟩
                else
                  let d := (rdW distBase ds).toUSize + (bb &&& (((1 : UInt64) <<< db) - 1)).toUSize
                  let bb := bb >>> db
                  let nb := nb - db
                  if d > op then ⟨out, op, pos, bb, nb, 4⟩
                  else if op + len > lim then ⟨out, op, pos, bb, nb, 3⟩
                  else huffLoop src n pos bb nb (copyMatch out op d len) (op + len) lim lit dist

/-- The fixed literal/length table. -/
def fixedLit : Array UInt32 :=
  match buildTable ((Array.range 288).map fun s => if s < 144 then 8 else if s < 256 then 9 else if s < 280 then 7 else 8) with
  | .ok t => t | .error _ => #[]

/-- The fixed distance table. -/
def fixedDist : Array UInt32 :=
  match buildTable (Array.replicate 30 5) with | .ok t => t | .error _ => #[]

/-- Bit reader state between blocks. -/
structure BitState where
  pos : USize
  bb : UInt64
  nb : UInt64

abbrev BitM := StateT BitState (Except String)

/-- `k` bits (at most 32) from the front of the stream. -/
def getBits (src : ByteArray) (k : UInt64) : BitM UInt32 := do
  let mut s ← get
  while s.nb < k && s.pos < src.usize do
    s := { s with bb := s.bb ||| ((rd src s.pos).toUInt64 <<< s.nb), nb := s.nb + 8, pos := s.pos + 1 }
  if s.nb < k then throw "unexpected end of compressed data"
  set { s with bb := s.bb >>> k, nb := s.nb - k }
  return (s.bb &&& ((1 <<< k) - 1)).toUInt32

/-- One symbol decoded with table `t`. -/
def getSym (src : ByteArray) (t : Array UInt32) : BitM Nat := do
  let mut s ← get
  while s.nb < 15 && s.pos < src.usize do
    s := { s with bb := s.bb ||| ((rd src s.pos).toUInt64 <<< s.nb), nb := s.nb + 8, pos := s.pos + 1 }
  let e := decodeSym t s.bb
  let l := (e &&& 15).toUInt64
  if e == 0 then throw "invalid Huffman code"
  if l > s.nb then throw "unexpected end of compressed data"
  set { s with bb := s.bb >>> l, nb := s.nb - l }
  return (e >>> 4).toNat

def clOrder : Array Nat := #[16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

/-- The literal/length and distance tables of a dynamic block. -/
def readDynamic (src : ByteArray) : BitM (Array UInt32 × Array UInt32) := do
  let hlit := (← getBits src 5).toNat + 257
  let hdist := (← getBits src 5).toNat + 1
  let hclen := (← getBits src 4).toNat + 4
  if hlit > 286 || hdist > 30 then throw "bad dynamic block header"
  let mut cl := Array.replicate 19 0
  for i in [0:hclen] do cl := cl.set! clOrder[i]! (← getBits src 3).toNat
  let clt ← StateT.lift (buildTable cl)
  let mut lens : Array Nat := Array.emptyWithCapacity (hlit + hdist)
  while lens.size < hlit + hdist do
    let sym ← getSym src clt
    if sym < 16 then lens := lens.push sym
    else
      let (v, rep) ← match sym with
        | 16 => do
          if lens.isEmpty then throw "repeat with no previous length"
          pure (lens.back!, 3 + (← getBits src 2).toNat)
        | 17 => do pure (0, 3 + (← getBits src 3).toNat)
        | _ => do pure (0, 11 + (← getBits src 7).toNat)
      if lens.size + rep > hlit + hdist then throw "code lengths overflow"
      for _ in [0:rep] do lens := lens.push v
  if lens[256]! == 0 then throw "no end-of-block code"
  let lit ← StateT.lift (buildTable (lens.extract 0 hlit))
  let dist ← StateT.lift (buildTable (lens.extract hlit (hlit + hdist)))
  return (lit, dist)

/-- Inflate the raw deflate stream of `src` from byte `start` into exactly `size` bytes, followed
by 4 spare zero bytes (so that a 4-byte read at any pixel of the last row is in range).
Returns the data and the position after the stream. -/
partial def inflate (src : ByteArray) (start size : Nat) : Except String (ByteArray × Nat) :=
  go ⟨start.toUSize, 0, 0⟩ (zeros (size + 4)) 0
where
  go (s : BitState) (out : ByteArray) (op : USize) : Except String (ByteArray × Nat) := do
    let ((final, type), s) ← (do return (← getBits src 1, ← getBits src 2) : BitM _).run s
    if type == 0 then
      -- stored: drop to the byte boundary, give back whole buffered bytes
      let pos := (s.pos - (s.nb / 8).toUSize).toNat
      if pos + 4 > src.size then throw "unexpected end of compressed data"
      let len := (src.get! pos).toNat ||| (src.get! (pos + 1)).toNat <<< 8
      let nlen := (src.get! (pos + 2)).toNat ||| (src.get! (pos + 3)).toNat <<< 8
      if len + nlen != 65535 then throw "stored block length mismatch"
      if pos + 4 + len > src.size then throw "unexpected end of compressed data"
      if op.toNat + len > size then throw "too much image data"
      let out := src.copySlice (pos + 4) out op.toNat len
      let s : BitState := ⟨(pos + 4 + len).toUSize, 0, 0⟩
      if final == 1 then return (out, s.pos.toNat) else go s out (op + len.toUSize)
    else if type == 3 then throw "invalid block type"
    else
      let ((lit, dist), s) ←
        if type == 1 then pure ((fixedLit, fixedDist), s) else (readDynamic src).run s
      let r := huffLoop src src.usize s.pos s.bb s.nb out op size.toUSize lit dist
      match r.err with
      | 0 =>
        let s : BitState := ⟨r.pos, r.bb, r.nb⟩
        if final == 1 then return (r.out, (s.pos - (s.nb / 8).toUSize).toNat) else go s r.out r.op
      | 1 => throw "invalid Huffman code"
      | 2 => throw "unexpected end of compressed data"
      | 3 => throw "too much image data"
      | _ => throw "match distance too far back"

/-! ## Decoding -/

/-- Undo the filters in place: `raw` holds `h` rows of a filter byte and `rb` bytes, `bpp` bytes per
pixel. Returns the buffer, or an error message for an unknown filter type. -/
partial def unfilterSub (raw : ByteArray) (cur rb bpp : USize) (hc : RowIn raw cur rb) (i : USize) : ByteArray :=
  if hi : i < rb then
    if hk : bpp ≤ i then
      let v := rowGet raw cur rb hc i hi + rowBack raw cur rb hc i bpp hi hk
      unfilterSub (raw.uset (cur + i) v (hc.lt hi)) cur rb bpp (hc.uset _ _ _) (i + 1)
    else unfilterSub raw cur rb bpp hc (i + 1)
  else raw

partial def unfilterUp (raw : ByteArray) (cur prior rb : USize) (hc : RowIn raw cur rb) (hp : RowIn raw prior rb)
    (i : USize) : ByteArray :=
  if hi : i < rb then
    let v := rowGet raw cur rb hc i hi + rowGet raw prior rb hp i hi
    unfilterUp (raw.uset (cur + i) v (hc.lt hi)) cur prior rb (hc.uset _ _ _) (hp.uset _ _ _) (i + 1)
  else raw

theorem le_succ_of_le_of_lt {k i n : USize} (hk : k ≤ i) (hi : i < n) : k ≤ i + 1 := by
  have hk' := USize.le_iff_toNat_le.mp hk
  have hi' := USize.lt_iff_toNat_lt.mp hi
  have hn := n.toNat_lt_size
  have h1 : (1 : USize).toNat = 1 := by rcases USize.size_eq with hs | hs <;> simp [USize.toNat, hs]
  apply USize.le_iff_toNat_le.mpr
  simp only [USize.toNat_add, h1] at *
  have hs := USize.size_eq
  rcases hs with hs | hs <;> simp only [USize.size, hs] at * <;> omega

/-- Paeth on bytes `i .. rb - 1` of a row with a previous row, from `i ≥ bpp` on (no branches
for missing neighbours). -/
partial def unfilterPaeth (raw : ByteArray) (cur prior rb bpp : USize) (hc : RowIn raw cur rb) (hp : RowIn raw prior rb)
    (i : USize) (hk : bpp ≤ i) : ByteArray :=
  if hi : i < rb then
    let a := (rowBack raw cur rb hc i bpp hi hk).toUInt32
    let b := (rowGet raw prior rb hp i hi).toUInt32
    let c := (rowBack raw prior rb hp i bpp hi hk).toUInt32
    let v := rowGet raw cur rb hc i hi + (paeth a b c).toUInt8
    unfilterPaeth (raw.uset (cur + i) v (hc.lt hi)) cur prior rb bpp (hc.uset _ _ _) (hp.uset _ _ _) (i + 1)
      (le_succ_of_le_of_lt hk hi)
  else raw

/-- Average on bytes `i .. rb - 1` of a row with a previous row, from `i ≥ bpp` on. -/
partial def unfilterAvg (raw : ByteArray) (cur prior rb bpp : USize) (hc : RowIn raw cur rb) (hp : RowIn raw prior rb)
    (i : USize) (hk : bpp ≤ i) : ByteArray :=
  if hi : i < rb then
    let a := (rowBack raw cur rb hc i bpp hi hk).toUInt32
    let b := (rowGet raw prior rb hp i hi).toUInt32
    let v := rowGet raw cur rb hc i hi + ((a + b) >>> 1).toUInt8
    unfilterAvg (raw.uset (cur + i) v (hc.lt hi)) cur prior rb bpp (hc.uset _ _ _) (hp.uset _ _ _) (i + 1)
      (le_succ_of_le_of_lt hk hi)
  else raw

/-- Average and Paeth (`ft` 3 or 4), with or without a previous row, on bytes `i .. e - 1`
(`e ≤ rb`); `unfilterRows` runs it on the first pixel of rows with a previous row and on all of
the first row. -/
partial def unfilterLoop (raw : ByteArray) (ft : UInt32) (cur prior rb bpp : USize) (hc : RowIn raw cur rb)
    (hasPrior : Bool) (hp : hasPrior = true → RowIn raw prior rb) (e i : USize) : ByteArray :=
  if hi : i < rb ∧ i < e then
    have hi := hi.1
    let a := if hk : bpp ≤ i then (rowBack raw cur rb hc i bpp hi hk).toUInt32 else 0
    let b := if h : hasPrior = true then (rowGet raw prior rb (hp h) i hi).toUInt32 else 0
    let pr := if ft == 3 then (a + b) >>> 1
      else paeth a b (if h : hasPrior = true then
        (if hk : bpp ≤ i then (rowBack raw prior rb (hp h) i bpp hi hk).toUInt32 else 0) else 0)
    let v := rowGet raw cur rb hc i hi + pr.toUInt8
    unfilterLoop (raw.uset (cur + i) v (hc.lt hi)) ft cur prior rb bpp (hc.uset _ _ _) hasPrior
      (fun h => (hp h).uset _ _ _) e (i + 1)
  else raw

partial def unfilterRows (raw : ByteArray) (y h rb bpp : USize) : Except String ByteArray :=
  if y < h then
    let o := y * (rb + 1)
    let ft := rd32 raw o
    if ft > 4 then .error s!"unknown filter type {ft}"
    else if ft == 0 then unfilterRows raw (y + 1) h rb bpp
    else if hc : RowIn raw (o + 1) rb then
      let prior := o + 1 - (rb + 1)
      let ⟨hasPrior, hp⟩ := priorRow raw y prior rb
      let raw :=
        if ft == 1 then unfilterSub raw (o + 1) rb bpp hc 0
        else if ft == 2 then
          (if h : hasPrior = true then unfilterUp raw (o + 1) prior rb hc (hp h) 0 else raw)
        else if hasPrior then
          -- the first pixel has no left neighbour; the rest of the row runs without branches
          let raw := unfilterLoop raw ft (o + 1) prior rb bpp hc hasPrior hp bpp 0
          if hc : RowIn raw (o + 1) rb then
            if hp : RowIn raw prior rb then
              if ft == 3 then unfilterAvg raw (o + 1) prior rb bpp hc hp bpp (USize.le_refl _)
              else unfilterPaeth raw (o + 1) prior rb bpp hc hp bpp (USize.le_refl _)
            else raw
          else raw
        else unfilterLoop raw ft (o + 1) prior rb bpp hc hasPrior hp rb 0
      unfilterRows raw (y + 1) h rb bpp
    else .error "image data too short"
  else .ok raw

/-- Expand rows of 1, 2, 3 or 4 bytes per pixel to RGBA. `pal` is a 1024-byte RGBA palette (type 3);
`key` a transparent colour (`r <<< 16 ||| g <<< 8 ||| b`, or gray), or `0xFFFFFFFF` for none. -/
partial def expandLoop (raw : @& ByteArray) (pal : @& ByteArray) (out : ByteArray) (ct : UInt32) (key : UInt32)
    (s o x w : USize) : ByteArray :=
  if x < w then
    if ho : InPx out o then
      -- `raw` ends with 4 spare bytes (`inflate`), so 4 bytes from any pixel start are in range
      if hs : InPx raw s then
        let out :=
          if ct == 2 then
            let r := px32 raw s hs 0
            let g := px32 raw s hs 1
            let b := px32 raw s hs 2
            put4w out o ho r g b (if (r <<< 16 ||| g <<< 8 ||| b) == key then 0 else 255)
          else if ct == 0 then
            let v := px raw s hs 0
            put4 out o ho v v v (if v.toUInt32 == key then 0 else 255)
          else if ct == 4 then
            let v := px raw s hs 0
            put4 out o ho v v v (px raw s hs 1)
          else
            let p := 4 * (px raw s hs 0).toUSize
            if hp : InPx pal p then put4 out o ho (px pal p hp 0) (px pal p hp 1) (px pal p hp 2) (px pal p hp 3)
            else out
        let bpp : USize := if ct == 2 then 3 else if ct == 4 then 2 else 1
        expandLoop raw pal out ct key (s + bpp) (o + 4) (x + 1) w
      else out
    else out
  else out

partial def expandRows (raw : @& ByteArray) (pal : @& ByteArray) (out : ByteArray) (ct key : UInt32) (y h w rb : USize) :
    ByteArray :=
  if y < h then expandRows raw pal (expandLoop raw pal out ct key (y * (rb + 1) + 1) (4 * w * y) 0 w) ct key (y + 1) h w rb
  else out

/-- Decode a PNG file (8-bit gray, gray + alpha, RGB, RGBA or palette, non-interlaced) to RGBA8. -/
def decode (bytes : ByteArray) : Except String Image := do
  if bytes.size < 8 || bytes.extract 0 8 != signature then throw "not a PNG file"
  let mut pos := 8
  let mut ihdr : Option (Nat × Nat × Nat × Nat × Nat) := none  -- width, height, depth, colour type, interlace
  let mut pal : ByteArray := fillPixels 256 0 0 0 255
  let mut palSize := 0
  let mut trns : Option ByteArray := none
  let mut idat : ByteArray := .empty
  let mut ended := false
  while !ended do
    if pos + 12 > bytes.size then throw "truncated PNG file"
    let len := readU32BE bytes pos
    if len > 0x7FFFFFFF || pos + 12 + len > bytes.size then throw "truncated PNG chunk"
    let type := String.ofList ((bytes.extract (pos + 4) (pos + 8)).toList.map fun b => Char.ofNat b.toNat)
    let dataAt := pos + 8
    if crc32 bytes (pos + 4) (dataAt + len) != (readU32BE bytes (dataAt + len)).toUInt32 then
      throw s!"bad CRC in {type} chunk"
    let get (i : Nat) : Nat := (bytes.get! (dataAt + i)).toNat
    match type with
    | "IHDR" =>
      if len != 13 then throw "bad IHDR chunk"
      ihdr := some (readU32BE bytes dataAt, readU32BE bytes (dataAt + 4), get 8, get 9, get 12)
    | "PLTE" =>
      if len % 3 != 0 || len > 768 then throw "bad PLTE chunk"
      palSize := len / 3
      for i in [0:palSize] do
        pal := pal.set! (4 * i) (bytes.get! (dataAt + 3 * i)) |>.set! (4 * i + 1) (bytes.get! (dataAt + 3 * i + 1))
          |>.set! (4 * i + 2) (bytes.get! (dataAt + 3 * i + 2))
    | "tRNS" => trns := some (bytes.extract dataAt (dataAt + len))
    | "IDAT" => idat := bytes.copySlice dataAt idat idat.size len
    | "IEND" => ended := true
    | _ =>
      -- an unknown critical chunk (upper-case first letter) cannot be skipped
      if (bytes.get! (pos + 4)) < 97 then throw s!"unsupported critical chunk {type}"
    pos := dataAt + len + 4
  let some (w, h, depth, ct, interlace) := ihdr | throw "missing IHDR chunk"
  if w == 0 || h == 0 then throw "empty image"
  if depth != 8 then throw s!"unsupported bit depth {depth} (only 8 is supported)"
  if interlace != 0 then throw "interlaced PNG files are not supported"
  let channels ← match ct with
    | 0 => pure 1 | 2 => pure 3 | 3 => pure 1 | 4 => pure 2 | 6 => pure 4
    | _ => throw s!"unsupported colour type {ct}"
  if ct == 3 && palSize == 0 then throw "missing PLTE chunk"
  let rb := w * channels
  let rawSize := h * (rb + 1)
  -- deflate expands at most about 1032:1; refuse to allocate for absurd headers
  if rawSize > 1100 * idat.size + 4096 then throw "image data too short for the image size"
  if idat.size < 6 then throw "missing image data"
  let cmf := (idat.get! 0).toNat
  let flg := (idat.get! 1).toNat
  if cmf % 16 != 8 || cmf / 16 > 7 || (cmf * 256 + flg) % 31 != 0 || flg &&& 0x20 != 0 then
    throw "bad zlib header"
  let (raw, after) ← inflate idat 2 rawSize
  if after + 4 > idat.size then throw "missing Adler-32 checksum"
  if adler32 raw 0 rawSize != (readU32BE idat after).toUInt32 then throw "bad Adler-32 checksum"
  let raw ← unfilterRows raw 0 h.toUSize rb.toUSize channels.toUSize
  -- transparency
  let mut key : UInt32 := 0xFFFFFFFF
  if let some t := trns then
    if ct == 3 then
      for i in [0:min t.size 256] do pal := pal.set! (4 * i + 3) (t.get! i)
    else if ct == 0 && t.size ≥ 2 then
      key := (t.get! 1).toUInt32
    else if ct == 2 && t.size ≥ 6 then
      key := ((t.get! 1).toUInt32 <<< 16) ||| ((t.get! 3).toUInt32 <<< 8) ||| (t.get! 5).toUInt32
  if ct == 6 then
    -- rows are RGBA already: one copy per row
    let mut out := ByteArray.emptyWithCapacity (4 * w * h)
    for y in [0:h] do out := raw.copySlice (y * (rb + 1) + 1) out out.size rb
    return ⟨w, h, out⟩
  let out := (Image.blank w h).data
  return ⟨w, h, expandRows raw pal out ct.toUInt32 key 0 h.toUSize w.toUSize rb.toUSize⟩

end Editor.Png
