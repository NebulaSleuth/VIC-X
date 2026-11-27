#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Michael Hartman

"""Music and sound effects for the SID player (src/sound.s): text in, bytes out.

    src/music/instruments.txt   the instrument bank (shared by every tune)
    src/music/sfx.txt           sound effects (played on voice 3)
    src/music/<name>.mus        tunes: title, boss, victory, gameover, jump (global, always
                                in memory) and era_<era dir>.mus (one per era, loaded with it)
    src/music/try<1-9>.mus      test variants to compare in the jukebox (keys 1-9)

Instruments (one per line):
    inst <name> <wave> ad=<hex> sr=<hex> [wave1=<wave>] [pw=<hex>] [pwsweep=<n>]
         [vib=<depth>,<delay>] [arp=<chord>] [slide=<n>] [gap=<frames>]
         [filter=<lp|bp|hp, or joined with +> cutoff=<hex 00-FF> [res=<0-15>] [fsweep=<n>]] [legato]
  wave: tri saw pulse noise (or two joined with +, e.g. tri+pulse); wave1 = waveform of the
  first frame of each note (for attacks / drums); pw = pulse width 000-FFF; pwsweep = pulse
  width change per frame (bounces); vib = vibrato depth 1-7 and delay in frames; arp = chord
  arpeggio cycled every frame: major minor oct sus4 dim power aug; slide = frequency change
  per frame (signed); gap = frames of release before the next note (default 2).
  filter: the note goes through the SID filter, which restarts at `cutoff` (the high 8 bits)
  and moves by `fsweep` per frame (signed; stops at 0 / FF), with resonance `res`. There is
  one filter: the first voice to play a filtered note owns it until that voice plays an
  unfiltered one; filtered instruments on the other voices meanwhile play unfiltered.
  legato: a note that follows another without a rest slurs into it (no new attack, the
  gate stays on, only the pitch changes), like a flute or a bowed string.
  Every other note gets a hard restart (gate off, ADSR 0) two frames before the next note, so
  attacks are crisp.

Sound effects (one per line, in priority order: later ones interrupt earlier ones):
    sfx <name> <wave> ad=<hex> sr=<hex> freq=<hex> slide=<n> len=<frames> [pw=<hex>] [gap=<n>]

Tunes:
    tempo <frames per 16th note>
    pattern <name> { <mml> }          (insert with $name)
    v1 { <mml> }  v2 { <mml> }  v3 { <mml> }

MML: @inst  o<octave 0-7>  < >  l<length>  notes c d e f g a b (+ or # sharp, - flat) with an
optional length (1 2 4 8 16, dotted with .), r = rest, [ ... ]<n> repeat n times, k<n>
transpose by n semitones (k0 resets), | = loop point (the voice restarts there at its end;
without one it restarts from the top), ! = play once (stop at the end). ; starts a comment.
Lengths are in 16th notes: 1 = 16 ticks, 4 = 4 ticks, 16 = 1 tick.

Outputs (build/gen): music_global.bin (at GLOBAL_BASE: header, instruments, sfx, global
tunes), music.inc (SFX_* and TUNE_* constants), <code>.mus.prg per era (at ERA_BASE).
Standard library only.
"""
import os
import re

GLOBAL_BASE = 0xEC80
ERA_BASE = 0xF800
ERA_END = 0xFFF0                    # (the CPU vectors at $FFFA must stay free)
GLOBAL_END = 0xF800
GLOBAL_TUNES = ["title", "boss", "victory", "gameover", "jump"]     # TUNE_* 1..5; 6 = the era's
WAVES = {"tri": 0x10, "saw": 0x20, "pulse": 0x40, "noise": 0x80}
ARPS = {"none": 0, "major": 1, "minor": 2, "oct": 3, "sus4": 4, "dim": 5, "power": 6, "aug": 7}
FILTERS = {"lp": 0x10, "bp": 0x20, "hp": 0x40}
INST_SIZE, SFX_SIZE = 16, 12
CMD_REST, CMD_INST, CMD_JUMP, CMD_END = 0x60, 0x61, 0x62, 0x63
NOTE_NAMES = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}


class MusError(Exception):
    pass


def _wave(text, where):
    v = 0
    for part in text.split("+"):
        if part not in WAVES:
            raise MusError(f"{where}: unknown waveform '{part}' ({', '.join(WAVES)})")
        v |= WAVES[part]
    return v


def _opts(words, where):
    out = {}
    for w in words:
        if "=" in w:
            k, v = w.split("=", 1)
            out[k] = v
        else:
            out[w] = True
    return out


def parse_instruments(path):
    insts = {}
    for lineno, raw in enumerate(open(path, encoding="ascii"), 1):
        w = raw.split(";", 1)[0].split()
        if not w:
            continue
        where = f"{path}:{lineno}"
        if w[0] != "inst" or len(w) < 3:
            raise MusError(f"{where}: expected 'inst <name> <wave> ...'")
        o = _opts(w[3:], where)
        try:
            rec = bytearray(INST_SIZE)
            rec[0] = int(o.get("ad", "09"), 16)
            rec[1] = int(o.get("sr", "a0"), 16)
            rec[2] = _wave(w[2], where)
            rec[3] = _wave(o["wave1"], where) if "wave1" in o else 0
            pw = int(o.get("pw", "800"), 16)
            rec[4], rec[5] = pw & 0xFF, pw >> 8
            rec[6] = int(o.get("pwsweep", "0")) & 0xFF
            if "vib" in o:
                d, dl = (int(x) for x in o["vib"].split(","))
                if not 0 <= d <= 7:
                    raise MusError(f"{where}: vib depth 0-7")
                rec[7], rec[8] = d, dl
            rec[9] = ARPS[o.get("arp", "none")]
            sl = int(o.get("slide", "0")) & 0xFFFF
            rec[10], rec[11] = sl & 0xFF, sl >> 8
            rec[12] = int(o.get("gap", "2")) & 0x7F
            if "legato" in o:
                rec[12] |= 0x80
            if "filter" in o:
                mode = 0
                for part in o["filter"].split("+"):
                    if part not in FILTERS:
                        raise MusError(f"{where}: unknown filter '{part}' (lp, bp, hp)")
                    mode |= FILTERS[part]
                res = int(o.get("res", "8"))
                if not 0 <= res <= 15:
                    raise MusError(f"{where}: res 0-15")
                rec[13] = mode | res
                rec[14] = int(o["cutoff"], 16) & 0xFF
                rec[15] = int(o.get("fsweep", "0")) & 0xFF
        except (ValueError, KeyError) as e:
            raise MusError(f"{where}: {e}")
        if w[1] in insts:
            raise MusError(f"{where}: instrument '{w[1]}' defined twice")
        insts[w[1]] = (len(insts), bytes(rec))
    if len(insts) > 64:
        raise MusError(f"{path}: at most 64 instruments")
    return insts


def parse_sfx(path):
    out = []
    for lineno, raw in enumerate(open(path, encoding="ascii"), 1):
        w = raw.split(";", 1)[0].split()
        if not w:
            continue
        where = f"{path}:{lineno}"
        if w[0] != "sfx" or len(w) < 3:
            raise MusError(f"{where}: expected 'sfx <name> <wave> ...'")
        o = _opts(w[3:], where)
        try:
            rec = bytearray(SFX_SIZE)
            rec[0] = _wave(w[2], where)
            rec[1] = int(o.get("ad", "00"), 16)
            rec[2] = int(o.get("sr", "f0"), 16)
            rec[3] = int(o.get("pw", "800"), 16) >> 8
            f = int(o["freq"], 16)
            rec[4], rec[5] = f & 0xFF, f >> 8
            sl = int(o.get("slide", "0")) & 0xFFFF
            rec[6], rec[7] = sl & 0xFF, sl >> 8
            rec[8] = int(o["len"])
            rec[9] = int(o.get("gap", "2"))
        except (ValueError, KeyError) as e:
            raise MusError(f"{where}: {e}")
        out.append((w[1], bytes(rec)))
    if len(out) > 31:
        raise MusError(f"{path}: at most 31 sound effects")
    return out


# ---------------------------------------------------------------- tunes
def _strip_comments(text):
    return "\n".join(line.split(";", 1)[0] for line in text.splitlines())


def _blocks(text, where):
    """tempo, {pattern name: mml}, {voice: mml}"""
    text = _strip_comments(text)
    m = re.search(r"\btempo\s+(\d+)", text)
    if not m:
        raise MusError(f"{where}: missing 'tempo <frames per 16th>'")
    tempo = int(m.group(1))
    pats, voices = {}, {}
    for m in re.finditer(r"\b(pattern\s+(\w+)|v([123]))\s*\{([^{}]*)\}", text):
        if m.group(2):
            pats[m.group(2)] = m.group(4)
        else:
            voices[int(m.group(3))] = m.group(4)
    for v in (1, 2, 3):
        voices.setdefault(v, "r1 !")
    return tempo, pats, voices


def _expand(mml, pats, where, depth=0):
    """Insert $patterns and unroll [ ]n repeats -> a flat token list."""
    if depth > 8:
        raise MusError(f"{where}: patterns nested too deep")
    tokens = re.findall(r"\$\w+|\[|\]\d*|[a-gr][+#-]?\d*\.?|@\w+|o\d|l\d+\.?|k-?\d+|[<>|!]|\S", mml)
    stack = [[]]
    for t in tokens:
        if t.startswith("$"):
            name = t[1:]
            if name not in pats:
                raise MusError(f"{where}: unknown pattern '{name}'")
            stack[-1].extend(_expand(pats[name], pats, where, depth + 1))
        elif t == "[":
            stack.append([])
        elif t.startswith("]"):
            if len(stack) < 2:
                raise MusError(f"{where}: ']' without '['")
            body = stack.pop()
            stack[-1].extend(body * int(t[1:] or 2))
        else:
            stack[-1].append(t)
    if len(stack) != 1:
        raise MusError(f"{where}: '[' without ']'")
    return stack[0]


def _length(text, default, where):
    if not text:
        return default
    dotted = text.endswith(".")
    n = int(text.rstrip("."))
    if n not in (1, 2, 4, 8, 16):
        raise MusError(f"{where}: length {n} (use 1 2 4 8 16)")
    ticks = 16 // n
    if dotted:
        if ticks % 2:
            raise MusError(f"{where}: a dotted 16th is too short")
        ticks += ticks // 2
    return ticks


def compile_voice(mml, pats, insts, where, base):
    """Voice data placed at `base` -> (bytes, [(offset, 'loop')]) with jumps resolved."""
    toks = _expand(mml, pats, where)
    data = bytearray()
    octave, length, transpose = 4, 4, 0
    loop_at, once = 0, False
    for t in toks:
        if t.startswith("@"):
            name = t[1:]
            if name not in insts:
                raise MusError(f"{where}: unknown instrument '{name}'")
            data += bytes([CMD_INST, insts[name][0]])
        elif t[0] == "o":
            octave = int(t[1:])
        elif t == "<":
            octave -= 1
        elif t == ">":
            octave += 1
        elif t[0] == "l":
            length = _length(t[1:], length, where)
        elif t[0] == "k":
            transpose = int(t[1:])
        elif t == "|":
            loop_at = len(data)
        elif t == "!":
            once = True
        elif t[0] == "r":
            ticks = _length(t[1:], length, where)
            while ticks > 255:
                data += bytes([CMD_REST, 255])
                ticks -= 255
            data += bytes([CMD_REST, ticks])
        elif t[0] in NOTE_NAMES:
            m = re.match(r"([a-g])([+#-]?)(.*)", t)
            n = NOTE_NAMES[m.group(1)] + {"": 0, "+": 1, "#": 1, "-": -1}[m.group(2)]
            note = octave * 12 + n + transpose
            if not 0 <= note <= 95:
                raise MusError(f"{where}: note {t} in octave {octave} is out of range (C0-B7)")
            ticks = _length(m.group(3), length, where)
            data += bytes([note, ticks])
        else:
            raise MusError(f"{where}: can't read '{t}'")
    if once:
        data.append(CMD_END)
    else:
        target = base + loop_at
        data += bytes([CMD_JUMP, target & 0xFF, target >> 8])
    return bytes(data)


def compile_tune(path, insts, base):
    """A tune placed at `base`: header (tempo, voice pointers), then the three voices."""
    tempo, pats, voices = _blocks(open(path, encoding="ascii").read(), path)
    if not 2 <= tempo <= 30:
        raise MusError(f"{path}: tempo 2-30 frames per 16th")
    out = bytearray(7)
    out[0] = tempo
    for v in (1, 2, 3):
        addr = base + len(out)
        out[1 + (v - 1) * 2:3 + (v - 1) * 2] = addr.to_bytes(2, "little")
        out += compile_voice(voices[v], pats, insts, f"{path} v{v}", addr)
    return bytes(out)


def freq_table():
    """SID frequency values of notes C0..B7 on a PAL C64 (clock 985248 Hz)."""
    out = []
    for n in range(96):
        hz = 440.0 * 2 ** ((n - 57) / 12)                 # n 57 = A4
        out.append(min(0xFFFF, round(hz * 16777216 / 985248)))
    return out


def build(music_dir, out_dir, era_codes):
    """Everything -> out_dir. era_codes: {era dir name: disk code}. Returns a summary."""
    insts = parse_instruments(os.path.join(music_dir, "instruments.txt"))
    sfx = parse_sfx(os.path.join(music_dir, "sfx.txt"))
    # global block: header (inst ptr, sfx ptr, tune table ptr), instruments, sfx, tune table, tunes
    head = 6
    inst_at = GLOBAL_BASE + head
    sfx_at = inst_at + INST_SIZE * len(insts)
    table_at = sfx_at + SFX_SIZE * len(sfx)
    tunes_at = table_at + 2 * len(GLOBAL_TUNES)
    blob = bytearray()
    blob += inst_at.to_bytes(2, "little") + sfx_at.to_bytes(2, "little") + table_at.to_bytes(2, "little")
    for _, rec in sorted(insts.values()):
        blob += rec
    for _, rec in sfx:
        blob += rec
    table = bytearray()
    tunes = bytearray()
    for name in GLOBAL_TUNES:
        path = os.path.join(music_dir, name + ".mus")
        addr = tunes_at + len(tunes)
        table += addr.to_bytes(2, "little")
        if os.path.exists(path):
            tunes += compile_tune(path, insts, addr)
        else:                                           # missing: silence
            tunes += bytes([6]) + (addr + 7).to_bytes(2, "little") * 3 + bytes([CMD_END])
    blob += table + tunes
    if GLOBAL_BASE + len(blob) > GLOBAL_END:
        raise MusError(f"global music is {len(blob)} bytes: more than ${GLOBAL_END - GLOBAL_BASE:X}")
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "music_global.bin"), "wb") as f:
        f.write(blob)
    ft = freq_table()
    with open(os.path.join(out_dir, "freqtab.inc"), "w", encoding="ascii", newline="\n") as f:
        f.write("; generated by tools/sound/musfmt.py: SID frequencies of C0..B7 (PAL)\n")
        for label, shift in (("freq_lo", 0), ("freq_hi", 8)):
            f.write(f"{label}:\n")
            for i in range(0, 96, 12):
                f.write("        .byte " + ", ".join(f"${(v >> shift) & 0xFF:02X}" for v in ft[i:i + 12]) + "\n")
    with open(os.path.join(out_dir, "music.inc"), "w", encoding="ascii", newline="\n") as f:
        f.write("; generated by tools/sound/musfmt.py from src/music - edit those\n")
        f.write(f"MUSIC_GLOBAL = ${GLOBAL_BASE:04X}\nMUSIC_ERA = ${ERA_BASE:04X}\n")
        f.write("TUNE_NONE = 0\n")
        for i, name in enumerate(GLOBAL_TUNES, 1):
            f.write(f"TUNE_{name.upper()} = {i}\n")
        f.write(f"TUNE_ERA = {len(GLOBAL_TUNES) + 1}\n")
        for i, (name, _) in enumerate(sfx, 1):
            f.write(f"SFX_{name.upper()} = {i}\n")
    eras = {}
    for era, code in era_codes.items():
        path = os.path.join(music_dir, f"era_{era}.mus")
        if os.path.exists(path):
            data = compile_tune(path, insts, ERA_BASE)
        else:
            data = bytes([6]) + (ERA_BASE + 7).to_bytes(2, "little") * 3 + bytes([CMD_END])
        if ERA_BASE + len(data) > ERA_END:
            raise MusError(f"{path}: {len(data)} bytes, more than ${ERA_END - ERA_BASE:X}")
        with open(os.path.join(out_dir, f"{code}.mus.prg"), "wb") as f:
            f.write(ERA_BASE.to_bytes(2, "little") + data)
        eras[era] = len(data)
    # try1.mus .. try9.mus: test variants, loaded like an era tune (keys 1-9 in the jukebox)
    for n in range(1, 10):
        path, out = os.path.join(music_dir, f"try{n}.mus"), os.path.join(out_dir, f"try{n}.mus.prg")
        if not os.path.exists(path):
            if os.path.exists(out):
                os.remove(out)
            continue
        data = compile_tune(path, insts, ERA_BASE)
        if ERA_BASE + len(data) > ERA_END:
            raise MusError(f"{path}: {len(data)} bytes, more than ${ERA_END - ERA_BASE:X}")
        with open(out, "wb") as f:
            f.write(ERA_BASE.to_bytes(2, "little") + data)
    return len(insts), len(sfx), len(blob), eras


def voice_report(path, insts):
    """Per voice: (intro ticks, loop ticks or None for play-once, bytes)."""
    tempo, pats, voices = _blocks(open(path, encoding="ascii").read(), path)
    out = {}
    for v in (1, 2, 3):
        toks = _expand(voices[v], pats, f"{path} v{v}")
        length, ticks, loop_at, once = 4, 0, 0, False
        for t in toks:
            if t[0] == "l":
                length = _length(t[1:], length, path)
            elif t == "|":
                loop_at = ticks
            elif t == "!":
                once = True
            elif t[0] in "abcdefgr":
                m = re.match(r"[a-gr][+#-]?(.*)", t)
                ticks += _length(m.group(1), length, path)
        data = compile_voice(voices[v], pats, insts, f"{path} v{v}", 0)
        out[v] = (loop_at, None if once else ticks - loop_at, len(data))
    return tempo, out


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 3 or sys.argv[1] != "check":
        sys.exit("python tools/sound/musfmt.py check src/music/<tune>.mus ...")
    here = os.path.dirname(os.path.abspath(__file__))
    insts = parse_instruments(os.path.join(here, "..", "..", "src", "music", "instruments.txt"))
    for path in sys.argv[2:]:
        tempo, rep = voice_report(path, insts)
        total = sum(b for _, _, b in rep.values()) + 7
        print(f"{path}: tempo {tempo}, {total} bytes")
        loops = set()
        for v, (intro, loop, size) in rep.items():
            secs = lambda t: t * tempo / 50
            if loop is None:
                print(f"  v{v}: plays once, {intro} 16ths ({secs(intro):.1f} s), {size} bytes")
            else:
                print(f"  v{v}: intro {intro} 16ths, loop {loop} 16ths ({secs(loop):.1f} s), {size} bytes")
                loops.add((intro, loop))
        if len(loops) > 1:
            print("  WARNING: the voices' intro/loop lengths differ - they will drift apart")
