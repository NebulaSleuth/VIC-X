#!/usr/bin/env python3
"""sidplay.py - TimeWarrior's SID music player (src/sound.s there), in Python.

It plays a tune compiled by musfmt.py frame by frame, as the 6502 player does
(the same state, the same 8-bit arithmetic, the same order), and returns the
SID's 25 registers ($D400-$D418) after each frame.  The music only: no sound
effects.  Written to turn tunes into the register streams the VIC-X Big
world demo plays from XRAM.

    frames = render(mus_path, instruments_path, n_frames)   # [bytes(25), ...]

Every register the player writes in a frame is kept; writes within a frame
collapse into the last one.  That is enough for this player: its hard
restart turns the gate off (with ADSR 0) two frames before every new note,
so a note's gate-on never needs an off in the same frame.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import musfmt  # noqa: E402

CMD_REST, CMD_INST, CMD_JUMP = 0x60, 0x61, 0x62
I_AD, I_SR, I_WAVE, I_WAVE1, I_PWLO, I_PWHI, I_PWSWEEP, I_VIB, I_VIBDELAY, I_ARP, \
    I_SLIDELO, I_SLIDEHI, I_GAP, I_FILT, I_CUT, I_FSWEEP = range(16)
VOFS = (0, 7, 14)
ARP_TAB = [0, 0, 0, 0, 4, 7, 0, 3, 7, 0, 12, 0, 0, 5, 7, 0, 3, 6, 0, 7, 12, 0, 4, 8]
BIT_TAB = (1, 2, 4)
VIB_TAB = (0, 1, 2, 1, 0, 0x81, 0x82, 0x81)
FREQ = musfmt.freq_table()
FREQ_LO = [f & 0xFF for f in FREQ]
FREQ_HI = [f >> 8 for f in FREQ]
TUNE_BASE = 0x8000                  # where the tune "sits" (its jumps are absolute)


def s8(v):
    return v - 256 if v & 0x80 else v


class Player:
    def __init__(self, tune, insts):
        self.mem = bytearray(0x10000)
        self.mem[TUNE_BASE:TUNE_BASE + len(tune)] = tune
        self.inst = insts                       # list of 16-byte records
        self.sid = bytearray(25)
        n = range(3)
        self.on = [0] * 3
        self.p = [0] * 3
        self.ticks = [0] * 3
        self.note = [0] * 3
        self.vi = [0] * 3                       # instrument number
        self.ctrl = [0] * 3
        self.rest = [0] * 3
        self.age = [0] * 3
        self.pwlo = [0] * 3
        self.pwhi = [0] * 3
        self.psw = [0] * 3
        self.arp = [0] * 3
        self.arpb = [0] * 3
        self.sllo = [0] * 3
        self.slhi = [0] * 3
        self.vamp = [0] * 3
        self.hr = [0] * 3
        self.tmpf = 0                           # shared, as in the player
        self.f_own = 0xFF
        self.f_cut = self.f_sweep = self.f_res = self.f_mode = 0
        del n
        # start_tune
        for x in range(3):
            self.on[x] = 0
            self.ctrl[x] = 0
            self.sid[VOFS[x] + 4] = 0
        self.tempo = tune[0]
        self.hrf = 2 if self.tempo >= 4 else 1
        self.frame_ctr = 0
        for x in range(3):
            self.p[x] = tune[1 + 2 * x] | (tune[2 + 2 * x] << 8)
            self.on[x] = 1
            self.ticks[x] = 1
            self.vi[x] = 0

    def I(self, x, k):
        return self.inst[self.vi[x]][k]

    # one frame -> the 25 registers
    def frame(self):
        self.tick = 0
        self.frame_ctr = (self.frame_ctr - 1) & 0xFF
        if self.frame_ctr & 0x80:
            self.frame_ctr = (self.tempo - 1) & 0xFF
            self.tick = 1
        for x in range(3):
            self.voice(x)
        self.filter_frame()
        return bytes(self.sid)

    def filter_frame(self):
        if self.f_own & 0x80:
            self.sid[0x17] = 0
            self.sid[0x18] = 0x0F
            return
        sw = self.f_sweep
        if sw:
            if not sw & 0x80:
                c = sw + self.f_cut
                self.f_cut = 0xFF if c > 0xFF else c
            else:
                c = sw + self.f_cut
                self.f_cut = (c & 0xFF) if c > 0xFF else 0      # no carry: went below 0
        self.sid[0x16] = self.f_cut
        self.sid[0x15] = 0
        self.sid[0x17] = BIT_TAB[self.f_own] | self.f_res
        self.sid[0x18] = self.f_mode | 0x0F

    def voice(self, x):
        if not self.on[x]:
            return
        if self.tick:
            self.ticks[x] = (self.ticks[x] - 1) & 0xFF
            if self.ticks[x] == 0:
                self.fetch(x)
                if not self.on[x]:
                    return
        # the gate on the last tick
        if self.ticks[x] == 1:
            go_gap = True
            if self.hr[x]:
                if self.I(x, I_GAP) & 0x80:
                    go_gap = False                      # legato: no restart
                elif self.frame_ctr < self.hrf:
                    self.ctrl[x] &= 0xFE                # hard restart
                    o = VOFS[x]
                    self.sid[o + 5] = 0
                    self.sid[o + 6] = 0
                    go_gap = False
            if go_gap and self.ctrl[x] & 1:
                g = self.I(x, I_GAP) & 0x7F
                if g:
                    if g >= self.tempo:
                        g = self.tempo - 1
                    if g == self.frame_ctr:
                        self.ctrl[x] &= 0xFE
        # effects
        if self.rest[x]:
            self.write(x)
            return
        old = self.age[x]
        if old != 0xFF:
            self.age[x] = old + 1
        if old == 1:                                    # the attack waveform is over
            self.ctrl[x] = (self.ctrl[x] & 1) | self.I(x, I_WAVE)
        if self.I(x, I_PWSWEEP):
            psw = self.psw[x]
            if not psw & 0x80:
                s = self.pwlo[x] + psw
                self.pwlo[x] = s & 0xFF
                if s > 0xFF:
                    self.pwhi[x] = (self.pwhi[x] + 1) & 0xFF
                if self.pwhi[x] >= 0x0E:
                    self.psw[x] = (-psw) & 0xFF
            else:
                s = self.pwlo[x] + psw
                self.pwlo[x] = s & 0xFF
                if s <= 0xFF:
                    self.pwhi[x] = (self.pwhi[x] - 1) & 0xFF
                if self.pwhi[x] < 0x01:
                    self.psw[x] = (-psw) & 0xFF
        n = self.note[x]
        if self.arp[x]:
            n += ARP_TAB[self.arp[x]]
            if n >= 96:
                n = 95
        tf = FREQ_LO[n] | (FREQ_HI[n] << 8)
        if self.arp[x]:
            self.arp[x] += 1
            if self.arp[x] - self.arpb[x] >= 3:
                self.arp[x] = self.arpb[x]
        sl = self.I(x, I_SLIDELO) | (self.I(x, I_SLIDEHI) << 8)
        if sl:
            acc = ((self.slhi[x] << 8) | self.sllo[x]) + sl
            self.sllo[x], self.slhi[x] = acc & 0xFF, (acc >> 8) & 0xFF
            t = tf + ((self.slhi[x] << 8) | self.sllo[x])
            carry = t > 0xFFFF
            tf = t & 0xFFFF
            if self.slhi[x] & 0x80 and not carry:
                tf = 0                                  # slid below the bottom
        if self.vamp[x] and self.age[x] >= self.I(x, I_VIBDELAY):
            v = VIB_TAB[(self.age[x] >> 1) & 7]
            if v:
                amt = self.vamp[x] >> 1 if (v & 0x7F) & 1 else self.vamp[x]
                if v & 0x80:
                    lo = (tf & 0xFF) - amt
                    hi = tf >> 8
                    if lo < 0:
                        hi = (hi - 1) & 0xFF
                    tf = (hi << 8) | (lo & 0xFF)
                else:
                    lo = (tf & 0xFF) + amt
                    hi = tf >> 8
                    if lo > 0xFF:
                        hi = (hi + 1) & 0xFF
                    tf = (hi << 8) | (lo & 0xFF)
        self.tmpf = tf
        self.write(x)

    def write(self, x):
        o = VOFS[x]
        self.sid[o + 0] = self.tmpf & 0xFF
        self.sid[o + 1] = self.tmpf >> 8
        self.sid[o + 2] = self.pwlo[x]
        self.sid[o + 3] = self.pwhi[x]
        self.sid[o + 4] = self.ctrl[x]

    def fetch(self, x):
        m = self.mem
        p = self.p[x]
        while True:
            b = m[p]
            if b < CMD_REST:
                self.note[x] = b
                self.ticks[x] = m[p + 1]
                p += 2
                self.note_on(x)
                break
            if b == CMD_REST:
                self.ticks[x] = m[p + 1]
                self.rest[x] = 1
                self.ctrl[x] &= 0xFE
                p += 2
                break
            if b == CMD_INST:
                self.vi[x] = m[p + 1]
                p += 2
                continue
            if b == CMD_JUMP:
                p = m[p + 1] | (m[p + 2] << 8)
                continue
            self.on[x] = 0                              # the end
            self.ctrl[x] &= 0xFE
            self.write(x)
            return
        self.peek(x, p)
        self.p[x] = p

    def peek(self, x, p):
        m = self.mem
        while True:
            b = m[p]
            if b < CMD_REST:
                self.hr[x] = 1
                return
            if b == CMD_REST:
                break
            if b == CMD_INST:
                p += 2
                continue
            if b == CMD_JUMP:
                p = m[p + 1] | (m[p + 2] << 8)
                continue
            break
        self.hr[x] = 0

    def note_on(self, x):
        legato = False
        if not self.rest[x] and self.ctrl[x] & 1 and self.I(x, I_GAP) & 0x80:
            legato = True
            self.sllo[x] = self.slhi[x] = 0
        else:
            self.rest[x] = 0
            self.age[x] = 0
            self.sllo[x] = self.slhi[x] = 0
            self.pwlo[x] = self.I(x, I_PWLO)
            self.pwhi[x] = self.I(x, I_PWHI)
            self.psw[x] = self.I(x, I_PWSWEEP)
            c = self.I(x, I_ARP)
            self.arp[x] = self.arpb[x] = 3 * c if c else 0
        a = 0
        for _ in range(self.I(x, I_VIB)):
            a += FREQ_HI[self.note[x]]
            if a > 0xFF:
                a = 0xFF
                break
        self.vamp[x] = a >> 3
        if legato:
            return
        filt = self.I(x, I_FILT)
        if filt:
            if self.f_own & 0x80 or self.f_own == x:
                self.f_own = x
                self.f_mode = filt & 0x70
                self.f_res = (filt << 4) & 0xFF
                self.f_cut = self.I(x, I_CUT)
                self.f_sweep = self.I(x, I_FSWEEP)
        elif x == self.f_own:
            self.f_own = 0xFF
        w = self.I(x, I_WAVE1) or self.I(x, I_WAVE)
        self.ctrl[x] = w | 1
        o = VOFS[x]
        self.sid[o + 4] = 0
        self.sid[o + 6] = self.I(x, I_SR)
        self.sid[o + 5] = self.I(x, I_AD)


def load(mus_path, insts_path):
    insts = musfmt.parse_instruments(insts_path)
    recs = [rec for _, rec in sorted(insts.values())]
    tune = musfmt.compile_tune(mus_path, insts, TUNE_BASE)
    return tune, recs


def render(mus_path, insts_path, n_frames):
    tune, recs = load(mus_path, insts_path)
    pl = Player(tune, recs)
    return [pl.frame() for _ in range(n_frames)]


def tune_frames(mus_path, insts_path):
    """(frames of one pass through the tune's loop, frames a bar): every voice
    must have the same length (musfmt's check warns otherwise)."""
    insts = musfmt.parse_instruments(insts_path)
    tempo, rep = musfmt.voice_report(mus_path, insts)
    lens = {intro + (loop or 0) for intro, loop, _ in rep.values()}
    if len(lens) != 1:
        raise musfmt.MusError(f"{mus_path}: the voices' lengths differ: {sorted(lens)}")
    return lens.pop() * tempo, 16 * tempo


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit("sidplay.py <tune.mus> <instruments.txt> <frames> [out.bin]")
    fr = render(sys.argv[1], sys.argv[2], int(sys.argv[3]))
    print(f"{len(fr)} frames")
    if len(sys.argv) > 4:
        open(sys.argv[4], "wb").write(b"".join(f + bytes(7) for f in fr))
