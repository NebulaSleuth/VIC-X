#!/usr/bin/env python3
"""Build the VIC-X demos.

  python build.py              art, conversion, REU images, PRGs
  python build.py --check      also run each demo headless and save a
                               screenshot as build/<demo>-check.png

Each demo is a PRG plus an REU image that holds its pictures, tiles and
palettes (XRAM is the REU's memory).  The artwork is art/*.png, made from
the Nano Banana pictures in art/raw/ by ../tools/prep_art.py (run again with
--prep after changing them); the bullet sprites come from ../tools/gen_art.py.  Run one in the GTK fork with:

  x64sc -vicx -reu -reusize 2048 -reuimage build/<demo>.reu build/<demo>.prg

or from its disk image (build/<demo>.d64 or .d81), where the demo loads its
own data into XRAM before it starts:

  x64sc -vicx -reu -reusize 2048 build/<demo>.d64
"""

import argparse
import json
import math
import os
import subprocess
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import lzpack  # noqa: E402
import d64write  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
BUILD = HERE / "build"
ART = HERE / "art"                  # prepared artwork (committed)
GEN = BUILD / "art"                 # procedural artwork (bullets)
TOOLS = REPO / "tools"

CC65 = os.environ.get("VICX_CC65", r"D:\Repos\TimeWarrior\tools\cc65\bin")
X64SC = os.environ.get("VICX_X64SC", r"D:\Repos\vice-vicx\vice\build-headless\src\x64sc.exe")
DLLDIR = os.environ.get("VICX_DLLDIR", r"C:\msys64\ucrt64\bin")

REU_SIZE = 2 * 1024 * 1024          # -reusize 2048
SIG_XRAM = REU_SIZE - 16            # the demo's signature once its data is in XRAM
BLOCK = 8192                        # data file blocks (unpacked size)
C1541 = os.environ.get("VICX_C1541", r"D:\Repos\vice-vicx\vice\build-headless\src\c1541.exe")
D64_BYTES = 664 * 254               # free space on a 1541 disk

# (png, folder) -> converter arguments
CONVERSIONS = [
    ("parallax_back", ART, ["--mode", "tiles8", "--palbase", "16", "--colours", "96"]),
    ("parallax_front", ART, ["--mode", "tiles8", "--palbase", "112", "--colours", "96"]),
    ("ship", ART, ["--mode", "sprites8", "--sprite", "32x32", "--palbase", "208", "--colours", "24"]),
    ("space", ART, ["--mode", "bitmap8", "--palbase", "16", "--colours", "192"]),
    ("bullets", GEN, ["--mode", "sprites8", "--sprite", "8x8", "--palbase", "232", "--colours", "24"]),
    ("parallax_back_wide", ART, ["--mode", "tiles8", "--palbase", "16", "--colours", "96"]),
    ("parallax_front_wide", ART, ["--mode", "tiles8", "--palbase", "112", "--colours", "96"]),
    ("bigworld", ART, ["--mode", "bitmap8", "--palbase", "16", "--colours", "240"]),
] + [(f"gallery{i}", ART, ["--mode", "bitmap8", "--palbase", "16", "--colours", "240", "--fades", "16"])
     for i in range(4)]

# demo -> assets in its REU image: (symbol, file in build/ or art/)
DEMOS = {
    "parallax": [
        ("BACK_TILES", "parallax_back.tiles"), ("BACK_MAP", "parallax_back.map"),
        ("BACK_PAL", "parallax_back.pal"),
        ("FRONT_TILES", "parallax_front.tiles"), ("FRONT_MAP", "parallax_front.map"),
        ("FRONT_PAL", "parallax_front.pal"),
    ],
    "bullets": [
        ("SHIP_SPR", "ship.spr"), ("SHIP_PAL", "ship.pal"),
        ("SPACE_PIX", "space.pix"), ("SPACE_PAL", "space.pal"),
        ("BULLET_SPR", "bullets.spr"), ("BULLET_PAL", "bullets.pal"),
    ],
    "gallery": [(f"PIC{i}_PIX", f"gallery{i}.pix") for i in range(4)]
             + [(f"PIC{i}_FADES", f"gallery{i}.fades") for i in range(4)],
    "bigworld": [
        ("WORLD_HDR", "bigworld_hdr.bin"),      # first: XRAM $000000, window page 0
        ("WORLD_PIX", "bigworld.pix"), ("WORLD_PAL", "bigworld.pal"),
        ("WORLD_CAPS", "bigworld_caps.bin"),
    ],
    "wide": [
        ("BACK_TILES", "parallax_back_wide.tiles"), ("BACK_MAP", "parallax_back_wide.map"),
        ("BACK_PAL", "parallax_back_wide.pal"),
        ("FRONT_TILES", "parallax_front_wide.tiles"), ("FRONT_MAP", "parallax_front_wide.map"),
        ("FRONT_PAL", "parallax_front_wide.pal"),
    ],
    "sixteen": [
        ("STOCK", "sixteen_stock.bin"), ("CUSTOM", "sixteen_custom.bin"),
        ("CUSTOM_PAL", "sixteen_custom.pal"),
    ],
    "blitter": [("SPACE_PIX", "space.pix"), ("SPACE_PAL", "space.pal"),
                ("SHIP_SPR", "ship.spr"), ("SHIP_PAL", "ship.pal")],
    "desktop": [
        ("DESK_IMG", "desktop.img"),
        ("DESK_PAL", "desktop.pal"), ("PHOTO_PAL", "desktop_photo.pal"),
        ("POINTER", "desktop_pointer.spr"),
    ] + [(f"WIN{i}_IMG", f"desk_win{i}.img") for i in range(4)]
      + [("NOTES_CLEAN", "desk_win0.img")]
      + [(f"MENU{i}_{k}", f"desk_menu{i}{s}.img") for i in range(3) for k, s in (("IMG", ""), ("INV", "i"))],
}

WORLD_CAPTIONS = ["THE EDGE OF SPACE", "HIGH SKIES", "ABOVE THE CLOUDS",
                  "THE VALLEY", "CRYSTAL CAVES", "THE MOLTEN CORE"]


def screen_codes(text, width=40):
    """Upper-case text centred in `width' characters, as C64 screen codes."""
    text = text.upper().center(width)
    return bytes((ord(c) & 0x3F) if c != " " else 0x20 for c in text)


def world_files():
    """bigworld_hdr.bin (segment count, then start rows) and the captions,
    from art/bigworld.json; returns lines for assets.inc."""
    info = json.loads((ART / "bigworld.json").read_text())
    starts = info["starts"]
    hdr = bytes([len(starts)]) + b"".join(s.to_bytes(2, "little") for s in starts)
    (BUILD / "bigworld_hdr.bin").write_bytes(hdr)
    (BUILD / "bigworld_caps.bin").write_bytes(b"".join(screen_codes(c) for c in WORLD_CAPTIONS))
    return [f"WORLD_ROWS    = {info['rows']}", f"WORLD_SEGS    = {len(starts)}"]


PREPACK = {"bigworld": world_files}


def run(cmd, **kw):
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def make_assets(prep):
    if prep:
        run([sys.executable, TOOLS / "prep_art.py", ART / "raw", ART])
    GEN.mkdir(parents=True, exist_ok=True)
    run([sys.executable, TOOLS / "gen_art.py", GEN], stdout=subprocess.DEVNULL)
    run([sys.executable, TOOLS / "gen_desktop.py", ART, BUILD], stdout=subprocess.DEVNULL)
    for name, folder, args in CONVERSIONS:
        run([sys.executable, TOOLS / "png2vicx.py", folder / f"{name}.png", "-o", BUILD / name] + args)


def pack(demo, assets):
    """Write build/<demo>.reu and build/<demo>/assets.inc."""
    image = bytearray(REU_SIZE)
    lines = [f"; assets.inc - XRAM addresses of the {demo} demo's data (generated by build.py)", ""]
    if demo in PREPACK:
        lines += PREPACK[demo]()
    pos = 0
    for sym, fname in assets:
        path = BUILD / fname if (BUILD / fname).exists() else ART / fname
        data = path.read_bytes()
        if pos + len(data) > REU_SIZE:
            raise SystemExit(f"{demo}: assets do not fit in {REU_SIZE} bytes")
        image[pos:pos + len(data)] = data
        lines.append(f"{sym:<14}= ${pos:06X}")
        lines.append(f"{sym + '_LEN':<14}= {len(data)}")
        end = pos + len(data)
        pos = (pos + len(data) + 0xFF) & ~0xFF

    # the data file for loading from disk: the used part of the image, in
    # packed 8 KB blocks
    out = bytearray(b"VX")
    blocks = 0
    for a in range(0, end, BLOCK):
        raw = bytes(image[a:min(a + BLOCK, end)])
        packed = lzpack.pack(raw)
        out += len(packed).to_bytes(2, "little") + a.to_bytes(3, "little")
        out += len(raw).to_bytes(2, "little") + packed
        blocks += 1
    out += b"\0\0"
    if blocks > 223:
        raise SystemExit(f"{demo}: {blocks} blocks; the progress bar handles up to 223")
    (BUILD / f"{demo}.dat").write_bytes(out)

    # name and checksum: a changed build loads its data again, even where
    # XRAM still holds an older build's (the MiSTer keeps the REU over resets)
    sig = f"{demo.upper()[:9]:<9} {zlib.crc32(bytes(image[:end])) & 0xFFFFFF:06X}".encode("ascii")
    image[SIG_XRAM:SIG_XRAM + 16] = sig        # a preloaded image needs no loading
    name = f"{demo.upper()}.DAT"
    lines += ["", f"SIG_XRAM      = ${SIG_XRAM:06X}", f"DATA_BLOCKS   = {blocks}",
              f"DATA_NAME_LEN = {len(name) + 4}",
              ".pushseg", ".rodata",
              f'data_name:    .byte "{name},S,R"',
              f'demo_sig:     .byte "{sig.decode()}"',
              f"REU_NAME_LEN  = {len(demo) + 4}",
              f'reu_name:     .byte "{demo}.reu"',      # ASCII, for the Ultimate's UCI
              f"REU_IMAGE_LEN = {REU_SIZE}",
              ".popseg"]
    (BUILD / f"{demo}.reu").write_bytes(image)
    inc = BUILD / demo
    inc.mkdir(exist_ok=True)
    (inc / "assets.inc").write_text("\n".join(lines) + "\n", newline="\n")
    if demo in EXTRAS:
        EXTRAS[demo](inc)
    return pos


def bullet_tables(path, speed=1.5):
    """vx/vy for 256 angles in 8.8 fixed point, low and high bytes."""
    lines = ["; tables.inc - bullet velocities (generated by build.py)", ""]
    for name, fn in (("vx", math.cos), ("vy", math.sin)):
        vals = [round(speed * 256 * fn(2 * math.pi * a / 256)) & 0xFFFF for a in range(256)]
        for part, shift in (("lo", 0), ("hi", 8)):
            lines.append(f"{name}_{part}:")
            for i in range(0, 256, 16):
                lines.append("        .byte " + ", ".join(f"${(v >> shift) & 0xFF:02X}" for v in vals[i:i + 16]))
    path.write_text("\n".join(lines) + "\n", newline="\n")


BLITTER_CREDITS = [
    "VIC-X BLITTER: EXPAND",
    "",
    "EVERY LINE OF THIS PANEL IS ONE",
    "BLITTER TRANSFER. THE TEXT SITS IN",
    "XRAM AT ONE BIT PER PIXEL, AND",
    "EXPAND TURNS EACH 1 BIT INTO THE",
    "LINE'S COLOUR AND EACH 0 BIT INTO",
    "THE PANEL'S BLUE.",
    "",
    "THE LETTERS ABOVE ARE MASKED",
    "EXPAND: A 0 BIT LEAVES THE PICTURE",
    "ALONE, SO EACH 16X16 LETTER IS",
    "STAMPED STRAIGHT ONTO THE PHOTO.",
    "",
    "ONE BYTE OF FONT MAKES EIGHT",
    "PIXELS, SO THE BLITTER READS ALMOST",
    "NOTHING, AND THE CPU ONLY WRITES A",
    "FEW DESCRIPTORS EACH FRAME.",
    "",
    "THE FONT IS THE C64'S OWN, READ",
    "FROM ITS CHARACTER ROM AT START.",
    "",
]
BLITTER_SCROLL = ("VIC-X BLITTER  ...  EXPAND: ONE BIT PER PIXEL IN, ANY COLOUR OUT  ...  "
                  "MASKED EXPAND STAMPS TEXT, ICONS AND PATTERNS OVER ANY PICTURE  ...  ")
PANEL_LINES = 11                    # lines the 104-row panel can show at once


def blitter_tables(path):
    """tables.inc for the blitter demo: the credits panel's lines (36 screen
    codes each, the first PANEL_LINES repeated at the end so the panel never
    wraps), the scroller's message, a sine table, the bit-doubling table and
    the demo's own palette entries (208-248)."""
    def sc(t):
        return [(ord(c) & 0x3F) if c != " " else 0x20 for c in t]
    lines = ["; tables.inc - generated by build.py for the blitter demo", ""]
    cred = BLITTER_CREDITS + BLITTER_CREDITS[:PANEL_LINES]
    for t in BLITTER_CREDITS:
        assert len(t) <= 36, t
    lines.append(f"CRED_LINES = {len(BLITTER_CREDITS)}")
    lines.append(f"CRED_ALL   = {len(cred)}")
    lines.append(f"MSG_LEN    = {len(BLITTER_SCROLL)}")
    lines.append("cred_text:")
    for t in cred:
        lines.append("        .byte " + ", ".join(f"${b:02X}" for b in sc(t.ljust(36))))
    lines.append("msg:")
    m = sc(BLITTER_SCROLL)
    for i in range(0, len(m), 16):
        lines.append("        .byte " + ", ".join(f"${b:02X}" for b in m[i:i + 16]))
    lines.append("sine:                           ; 0-48")
    vals = [round(24 + 24 * math.sin(2 * math.pi * a / 256)) for a in range(256)]
    for i in range(0, 256, 16):
        lines.append("        .byte " + ", ".join(str(v) for v in vals[i:i + 16]))
    lines.append("dbl:                            ; a nibble with each bit doubled")
    lines.append("        .byte " + ", ".join(
        "$%02X" % sum(3 << (2 * b) for b in range(4) if n >> b & 1) for n in range(16)))
    pal = []
    for k in range(32):                 # 208-239: a rainbow
        h = k / 32
        r, g, b = (max(0, min(1, 2 - abs(6 * ((h + o) % 1) - 3))) for o in (0, 2 / 3, 1 / 3))
        pal.append((int(80 + 175 * r), int(80 + 175 * g), int(80 + 175 * b)))
    pal.append((16, 24, 72))            # 240: the panel
    pal += [(255, 255, 255), (255, 210, 90), (120, 230, 255), (150, 255, 150),
            (255, 150, 200), (200, 170, 255), (255, 180, 120), (230, 230, 160)]   # 241-248: lines
    lines.append("pal_extra:                      ; entries 208-248, R G B 0")
    for (r, g, b) in pal:
        lines.append(f"        .byte {r}, {g}, {b}, 0")
    lines.append(f"PAL_EXTRA_N = {len(pal)}")
    # remap: the picture's 192 colours (entries 16-207) to 32 dim greys at
    # 208-239; every other entry to itself
    spal = (BUILD / "space.pal").read_bytes()
    grey = list(range(256))
    for k in range(192):
        r, g, b = spal[4 * k:4 * k + 3]
        y = (299 * r + 587 * g + 114 * b) / 1000
        grey[16 + k] = 208 + min(31, int(y * 32 / 256))
    lines.append("grey_table:                     ; the remap table")
    for i in range(0, 256, 16):
        lines.append("        .byte " + ", ".join(str(v) for v in grey[i:i + 16]))
    lines.append("grey_pal:                       ; entries 208-239: dim greys")
    for k in range(32):
        v = int(k * 150 / 31)
        lines.append(f"        .byte {v}, {v}, {v + 8 if v < 247 else v}, 0")
    # the spotlight: half-widths of ten bands of 8 rows, radius 40
    lines.append("spot_hw:")
    lines.append("        .byte " + ", ".join(
        str(int(math.sqrt(max(0, 40 ** 2 - (-36 + 8 * k) ** 2)))) for k in range(10)))
    lines.append("spot_x:                         ; centre x - 40, 256 steps")
    for i in range(0, 256, 16):
        lines.append("        .byte " + ", ".join(
            str(int(120 + 100 * math.sin(2 * math.pi * a / 256))) for a in range(i, i + 16)))
    # scaled copy: the 8.8 step that draws the 32-pixel ship d pixels big,
    # the orbit (x, y, size), the centre ship's zoom and its card flip
    def tbl(name, vals, comment=""):
        lines.append(f"{name}:{comment}")
        for i in range(0, len(vals), 16):
            lines.append("        .byte " + ", ".join(str(v) for v in vals[i:i + 16]))
    steps = [32 * 256 // max(1, d) for d in range(129)]
    tbl("step_lo", [v & 255 for v in steps], "                         ; d = 0-128")
    tbl("step_hi", [v >> 8 for v in steps])
    ang = [2 * math.pi * a / 256 for a in range(256)]
    ox = [int(160 + 120 * math.cos(t)) for t in ang]
    tbl("ox_lo", [v & 255 for v in ox], "                           ; orbit")
    tbl("ox_hi", [v >> 8 for v in ox])
    tbl("oy", [int(96 + 34 * math.sin(t)) for t in ang])
    tbl("od", [int(24 + 14 * math.sin(t)) for t in ang], "                              ; size 10-38: depth")
    tbl("cz", [int(80 + 30 * math.sin(t)) for t in ang], "                              ; centre size 50-110")
    tbl("fwq", [max(4, int(128 * abs(math.cos(t)))) for t in ang], "                             ; flip width, /128")
    tbl("fm", [1 if math.cos(t) < 0 else 0 for t in ang], "                              ; flip: mirrored")
    lines.append("spot_y:                         ; centre y - 40")
    for i in range(0, 256, 16):
        lines.append("        .byte " + ", ".join(
            str(int(56 + 50 * math.sin(2 * math.pi * 2 * a / 256 + 1))) for a in range(i, i + 16)))
    path.write_text("\n".join(lines) + "\n", newline="\n")


EXTRAS = {"bullets": lambda d: bullet_tables(d / "tables.inc"),
          "blitter": lambda d: blitter_tables(d / "tables.inc")}


def assemble(demo):
    obj = BUILD / f"{demo}.o"
    prg = BUILD / f"{demo}.prg"
    defs = [x for d in os.environ.get("VICX_DEMO_DEFS", "").split() for x in ("-D", d)]
    run([Path(CC65) / "ca65", "-g", *defs, "-I", REPO / "include", "-I", HERE / "lib", "-I", BUILD / demo,
         "-o", obj, HERE / f"{demo}.s"])
    run([Path(CC65) / "ld65", "-C", HERE / "lib" / "demo.cfg", "-Ln", BUILD / f"{demo}.lbl", "-o", prg, obj])
    return prg


def disk(demo, prg):
    """build/<demo>.d64 (or .d81 when the data needs more than a 1541 disk):
    the PRG first, so it autostarts, then the data file."""
    dat = BUILD / f"{demo}.dat"
    kind = "d64" if prg.stat().st_size + dat.stat().st_size < D64_BYTES - 2048 else "d81"
    image = BUILD / f"{demo}.{kind}"
    for old in (BUILD / f"{demo}.d64", BUILD / f"{demo}.d81"):
        old.unlink(missing_ok=True)
    if kind == "d64":
        # the data file's sectors ~122 ms apart, what the fast loader needs
        # between two (tools/d64write.py); the 1581 reads whole tracks
        d64write.write(image, f"VIC-X {demo.upper()}", "VX",
                       [(demo.upper(), "prg", prg.read_bytes(), 10),
                        (f"{demo.upper()}.DAT", "seq", dat.read_bytes(), "122ms")])
        return image
    env = dict(os.environ)
    env["PATH"] = DLLDIR + os.pathsep + env.get("PATH", "")
    run([C1541, "-format", f"vic-x {demo},vx", kind, image,
         "-write", prg, demo, "-write", dat, f"{demo}.dat,s"], stdout=subprocess.DEVNULL, env=env)
    return image


def check(demo, prg, cycles, ntsc=False):
    shot = BUILD / f"{demo}-check{'-ntsc' if ntsc else ''}.png"
    env = dict(os.environ)
    env["PATH"] = DLLDIR + os.pathsep + env.get("PATH", "")
    data = Path(X64SC).parents[2] / "data"
    cmd = [X64SC, "-default", "-warp", "-sounddev", "dummy", "-autostartprgmode", "1",
           "-directory", data, "-vicx", "-reu", "-reusize", "2048",
           "-reuimage", BUILD / f"{demo}.reu", "-limitcycles", str(cycles),
           "-exitscreenshot", shot, "-autostart", prg]
    if ntsc:
        cmd[2:2] = ["-ntsc"]          # after -default, which would reset it
    subprocess.run([str(c) for c in cmd], env=env, capture_output=True, cwd=BUILD, timeout=600)
    return shot


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("demos", nargs="*", help="demos to build (default: all)")
    ap.add_argument("--check", action="store_true", help="run each demo headless and save a screenshot")
    ap.add_argument("--cycles", type=int, default=12000000, help="cycles to run for --check")
    ap.add_argument("--ntsc", action="store_true", help="run --check as an NTSC machine")
    ap.add_argument("--skip-art", action="store_true", help="reuse the converted art in build/")
    ap.add_argument("--prep", action="store_true",
                    help="remake art/*.png from art/raw/ first (needs Pillow)")
    args = ap.parse_args()

    BUILD.mkdir(exist_ok=True)
    if not args.skip_art:
        make_assets(args.prep)
    for demo in args.demos or DEMOS:
        used = pack(demo, DEMOS[demo])
        prg = assemble(demo)
        image = disk(demo, prg)
        print(f"{demo}: {prg.name}, {prg.stat().st_size} bytes; {demo}.reu uses {used} bytes; "
              f"{image.name} with {(BUILD / f'{demo}.dat').stat().st_size} bytes of packed data")
        if args.check:
            print(f"  screenshot: {check(demo, prg, args.cycles, args.ntsc)}")


if __name__ == "__main__":
    main()
