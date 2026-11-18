#!/usr/bin/env python3
"""gen_music.py - the Big world demo's music, as a stream of SID registers.

Six original sections, one for each of the world's scenes (space, skies,
clouds, valley, caves, molten core), each 16 bars in its own key and mood.
Every frame (50 a second on PAL) is the 25 SID registers $D400-$D418,
padded to 32 bytes, so 256 frames fill one 8 KB XRAM page and a frame never
crosses a page.  Each section is a whole number of pages and of bars.

Voices: 1 bass (through the low-pass filter) with a kick drum on the beat,
2 chord arpeggios, 3 the lead melody (vibrato) with a snare where it rests.

Usage as a module: sections() -> list of dicts with "frames" (bytes) and
"bar" (frames a bar); or run it to write a raw stream and print a summary.
"""

import math
import random
import sys

CLOCK = 985248                      # PAL
FRAME = 32                          # bytes a frame (25 registers + padding)


def freq(midi):
    hz = 440.0 * 2 ** ((midi - 69) / 12)
    return max(0, min(0xFFFF, round(hz * 16777216 / CLOCK)))


MAJOR = [0, 2, 4, 5, 7, 9, 11]
MINOR = [0, 2, 3, 5, 7, 8, 10]

# chord (degree 0-6) -> triad degrees
def triad(deg):
    return [deg, deg + 2, deg + 4]


def note_of(key, scale, deg, octave=0):
    """MIDI note of scale degree deg (any integer) above key."""
    o, d = divmod(deg, 7)
    return key + 12 * (o + octave) + scale[d]


SECTIONS = [
    # name, key, scale, chords (8 bars, degrees), frames per 16th,
    # bass style, arp speed (frames per step), lead density, drums, cutoff,
    # resonance, lead wave, seed
    dict(name="edge of space", key=57, scale=MINOR, chords=[0, 5, 2, 6, 0, 5, 6, 4],
         fp16=6, bass="whole", arp=3, density=0.35, drums=False, cut=0x30, res=0xC,
         lead=0x11, seed=11),
    dict(name="high skies", key=60, scale=MAJOR, chords=[0, 4, 5, 3, 0, 4, 3, 4],
         fp16=6, bass="eighths", arp=2, density=0.75, drums=True, cut=0x60, res=0x6,
         lead=0x41, seed=23),
    dict(name="above the clouds", key=65, scale=MAJOR, chords=[0, 5, 3, 4, 0, 5, 1, 4],
         fp16=6, bass="dotted", arp=2, density=0.6, drums=False, cut=0x50, res=0x8,
         lead=0x21, seed=37),
    dict(name="the valley", key=55, scale=MAJOR, chords=[0, 3, 4, 0, 5, 3, 4, 4],
         fp16=6, bass="walk", arp=2, density=0.7, drums=True, cut=0x58, res=0x4,
         lead=0x41, seed=41),
    dict(name="crystal caves", key=52, scale=MINOR, chords=[0, 5, 3, 4, 0, 5, 6, 4],
         fp16=6, bass="whole", arp=1, density=0.45, drums=False, cut=0x28, res=0xE,
         lead=0x11, seed=53),
    dict(name="molten core", key=50, scale=MINOR, chords=[0, 5, 6, 4, 0, 5, 6, 4],
         fp16=5, bass="sixteenths", arp=1, density=0.85, drums=True, cut=0x48, res=0xA,
         lead=0x41, seed=67),
]

BARS = 16                           # two times the 8-bar progression


class Voice:
    """One SID voice's registers for every frame of a section."""

    def __init__(self, n):
        self.f = [0] * n            # frequency
        self.pw = [0x800] * n
        self.wave = [0] * n         # waveform bits (without gate)
        self.gate = [0] * n
        self.ad = [0] * n
        self.sr = [0] * n

    def note(self, start, length, midi, wave, ad, sr, pw=0x800, vib=0.0, bend=None):
        end = min(start + length, len(self.f))
        for t in range(start, end):
            m = midi
            if bend is not None:
                m = bend(t - start)
            fr = freq(m)
            if vib and t - start > 8:
                fr = round(fr * (1 + vib * math.sin((t - start) * 0.9)))
            self.f[t] = fr
            self.wave[t] = wave
            self.ad[t] = ad
            self.sr[t] = sr
            self.pw[t] = pw
            # gate on, off in the last frame so the next note starts afresh
            self.gate[t] = 1 if t < end - 1 else 0


def melody(sec, rng):
    """(start 16th, length 16ths, scale degree) for 16 bars."""
    rhythms = {
        True: [[4, 2, 2, 4, 4, 2, 2, 4, 8], [2, 2, 4, 2, 2, 4, 8, 8], [4, 4, 2, 2, 4, 8, 8]],
        False: [[8, 4, 4, 8, 8], [12, 4, 16], [6, 2, 8, 8, 8]],
    }[sec["density"] > 0.5]

    def phrase(bar0, rhythm, start_deg, end_on=None):
        notes = []
        pos = 0
        deg = start_deg
        for i, dur in enumerate(rhythm):
            bar = bar0 + pos // 16
            ch = triad(sec["chords"][bar % 8])
            if pos % 8 == 0:                      # strong: a chord tone near
                cands = [c + 7 * o for c in ch for o in (0, 1)]
                deg = min(cands, key=lambda c: abs(c - deg) + rng.random())
            else:                                 # step
                deg += rng.choice([-1, 1, 1, -2, 2])
            deg = max(2, min(11, deg))
            if i == len(rhythm) - 1 and end_on is not None:
                deg = end_on
            if rng.random() < sec["density"] or pos % 16 == 0:
                notes.append((bar0 * 16 + pos, dur, deg))
            pos += dur
        return notes

    out = []
    for half in range(2):
        b = half * 8
        ra, rb = rng.choice(rhythms), rng.choice(rhythms)
        sa = rng.randrange(4, 8)
        a = phrase(b, ra, sa)
        out += a
        out += [(s + 32, d, g + (1 if k == len(a) - 1 else 0)) for k, (s, d, g) in enumerate(a)]
        out += phrase(b + 4, rb, sa + 2)
        out += phrase(b + 6, ra, sa, end_on=7)
    return out


def section(sec):
    rng = random.Random(sec["seed"])
    fp = sec["fp16"]
    n = BARS * 16 * fp
    key, scale = sec["key"], sec["scale"]
    v1, v2, v3 = Voice(n), Voice(n), Voice(n)
    for bar in range(BARS):
        deg = sec["chords"][bar % 8]
        t0 = bar * 16 * fp
        root = note_of(key, scale, deg, -2)
        fifth = note_of(key, scale, deg + 4, -2)
        # bass (voice 1)
        style = sec["bass"]
        if style == "whole":
            steps = [(0, 16, root)]
        elif style == "eighths":
            steps = [(s, 2, root if (s // 2) % 4 != 3 else fifth) for s in range(0, 16, 2)]
        elif style == "dotted":
            steps = [(0, 6, root), (6, 6, fifth), (12, 4, root + 12)]
        elif style == "walk":
            steps = [(0, 4, root), (4, 4, fifth), (8, 4, root + 12),
                     (12, 4, note_of(key, scale, deg + 5, -2))]
        else:                                     # sixteenths
            steps = [(s, 1, root if s % 4 else root + 12) for s in range(16)]
        for s, d, m in steps:
            v1.note(t0 + s * fp, d * fp, m, 0x41 if style == "sixteenths" else 0x21,
                    0x08, 0xA6, pw=0x600)
        # kick drum: a falling blip at each beat 1 and 3 (and every beat in
        # the core)
        if sec["drums"]:
            beats = range(0, 16, 4) if style == "sixteenths" else (0, 8)
            for s in beats:
                v1.note(t0 + s * fp, 3, 0, 0x11, 0x00, 0x00,
                        bend=lambda k, r=root: r + 24 - 10 * k)
        # arpeggio (voice 2): the chord's tones in turn, a frame or more each
        tones = [note_of(key, scale, d, 0) for d in triad(deg)] + [note_of(key, scale, deg, 1)]
        sp = sec["arp"]
        bar_len = 16 * fp
        start = t0
        v2_len = bar_len
        for t in range(start, start + v2_len):
            i = ((t - start) // sp) % len(tones)
            v2.f[t] = freq(tones[i])
            v2.wave[t] = 0x41 if sec["lead"] != 0x41 else 0x11
            v2.pw[t] = 0x400 + 0x80 * ((t // 4) % 8)
            v2.ad[t] = 0x2A
            v2.sr[t] = 0x6A if sec["density"] > 0.5 else 0xA8
            v2.gate[t] = 1 if t < start + v2_len - 1 else 0
    # lead (voice 3)
    lead = melody(sec, rng)
    taken = [False] * n
    for s, d, g in lead:
        m = note_of(key, scale, g, 0)
        v3.note(s * fp, d * fp, m, sec["lead"], 0x2A, 0x9A, pw=0x500, vib=0.006)
        for t in range(s * fp, min(n, (s + d) * fp)):
            taken[t] = True
    # snare where the lead rests: noise on beats 2 and 4
    if sec["drums"]:
        for bar in range(BARS):
            for s in (4, 12):
                t = (bar * 16 + s) * fp
                if not any(taken[t:t + 3]):
                    v3.note(t, 3, 84, 0x81, 0x00, 0x00)
    # the frames
    out = bytearray()
    for t in range(n):
        regs = []
        for v in (v1, v2, v3):
            regs += [v.f[t] & 255, v.f[t] >> 8, v.pw[t] & 255, v.pw[t] >> 8,
                     v.wave[t] | v.gate[t], v.ad[t], v.sr[t]]
        # filter: voice 1 through the low-pass, a slow sweep over 4 bars
        sweep = 0.5 + 0.5 * math.sin(2 * math.pi * t / (4 * 16 * fp))
        cut = int(sec["cut"] * 8 * (0.6 + 0.8 * sweep))
        cut = max(0, min(0x7FF, cut))
        regs += [cut & 7, cut >> 3, (sec["res"] << 4) | 0x01, 0x1F]
        out += bytes(regs) + bytes(FRAME - 25)
    return dict(name=sec["name"], frames=bytes(out), bar=16 * fp, nframes=n)


def sections():
    return [section(s) for s in SECTIONS]


if __name__ == "__main__":
    total = 0
    for s in sections():
        assert s["nframes"] % 256 == 0 and s["nframes"] % s["bar"] == 0
        print(f'{s["name"]:18} {s["nframes"]} frames ({s["nframes"] / 50:.1f} s), '
              f'{len(s["frames"]) // 1024} KB, bar {s["bar"]} frames')
        total += len(s["frames"])
    print(f"total {total // 1024} KB")
    if len(sys.argv) > 1:
        open(sys.argv[1], "wb").write(b"".join(s["frames"] for s in sections()))
