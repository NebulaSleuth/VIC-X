#!/usr/bin/env python3
"""lzpack - a small LZ77 compressor whose blocks a 6502 can unpack quickly.

Block format (an LZ4-style byte stream, each block on its own):
  token: high nibble = literal count, low nibble = match length - 3
         (15 in either means more: add following bytes until one is < 255)
  literals
  match offset: 2 bytes, little endian, 1-65535 back from the output end
  ...and again; the block ends after a token's literals when the output is
  full (the last token has no match: low nibble 0 and no offset).

pack(data) -> bytes of one block; the decoder knows the unpacked length.
"""

MIN_MATCH = 3
MAX_OFFSET = 8191           # blocks are 8 KB


def _count(n):
    """Extension bytes for a 4-bit field that overflowed (n >= 15)."""
    out = bytearray()
    n -= 15
    while n >= 255:
        out.append(255)
        n -= 255
    out.append(n)
    return out


def pack(data):
    n = len(data)
    out = bytearray()
    heads = {}                  # 3-byte key -> recent positions
    i = lit_start = 0

    def emit(lit_end, mlen, off):
        lits = data[lit_start:lit_end]
        ln = len(lits)
        ml = 0 if mlen == 0 else mlen - MIN_MATCH
        out.append((min(ln, 15) << 4) | min(ml, 15))
        if ln >= 15:
            out.extend(_count(ln))
        out.extend(lits)
        if mlen:
            out.extend((off & 0xFF, off >> 8))
            if ml >= 15:
                out.extend(_count(ml))

    while i < n:
        best_len, best_off = 0, 0
        if i + MIN_MATCH <= n:
            key = data[i:i + MIN_MATCH]
            for j in reversed(heads.get(key, [])[-32:]):
                if i - j > MAX_OFFSET:
                    break
                k = MIN_MATCH
                while i + k < n and data[j + k] == data[i + k] and k < 4096:
                    k += 1
                if k > best_len:
                    best_len, best_off = k, i - j
            heads.setdefault(key, []).append(i)
        if best_len >= MIN_MATCH:
            emit(i, best_len, best_off)
            for p in range(i + 1, min(i + best_len, n - MIN_MATCH + 1)):
                heads.setdefault(data[p:p + MIN_MATCH], []).append(p)
            i += best_len
            lit_start = i
        else:
            i += 1
    emit(n, 0, 0)               # final literals, no match
    return bytes(out)


def unpack(block, size):
    """Reference decoder (what the 6502 does)."""
    out = bytearray()
    p = 0
    while len(out) < size:
        t = block[p]
        p += 1
        ln = t >> 4
        if ln == 15:
            while True:
                b = block[p]
                p += 1
                ln += b
                if b != 255:
                    break
        out += block[p:p + ln]
        p += ln
        if len(out) >= size:
            break
        off = block[p] | (block[p + 1] << 8)
        p += 2
        ml = (t & 15)
        if ml == 15:
            while True:
                b = block[p]
                p += 1
                ml += b
                if b != 255:
                    break
        ml += MIN_MATCH
        for _ in range(ml):
            out.append(out[-off])
    return bytes(out)
