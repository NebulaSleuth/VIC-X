#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Michael Hartman

"""gen_desktop - the desktop demo's art, layout and script.

  gen_desktop.py ART_DIR BUILD_DIR

Draws everything the desktop demo needs except its text (the demo writes
the text itself, with the C64's character ROM, into the images in XRAM):

  desktop.img             the desktop (wallpaper, menu bar, icons), 320x200
                          8-bit pixels; the icon labels are text
  desktop.pal             palette entries 16-95 (interface, wallpaper,
                          icons, the 48-colour rainbow the demo rotates)
  desktop_photo.pal       entries 96-255, the photo's colours
  desktop_pointer.spr     the mouse pointer, a 16x16 8-bit sprite
  desk_win0-3.img         the four windows (8-bit pixels, row by row)
  desk_menu0-2.img        the three menus, and desk_menu0-2i.img with
                          every item highlighted
  desktop/desktop.inc     sizes, positions, menus, texts, the notes text,
                          a test build's script, the zoom rectangles

The photo is art/desktop_photo.png (160x100, made by prep_art.py).  Text
in desktop.inc is in screen codes for the C64's lower-case character set.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio  # noqa: E402

# --- palette --------------------------------------------------------------
BLACK, WHITE, LGREY, MGREY, DGREY = 16, 17, 18, 19, 20
TDARK, TLIGHT, RED, YELLOW, GREEN = 21, 22, 23, 24, 25
SHADOW, SKY, ORANGE, PURPLE, BROWN, PAPER = 26, 27, 28, 29, 30, 31
WALL = 32                       # 32-35, set by the View menu
RAINBOW, NRAIN = 48, 48         # 48-95
PHOTO = 96                      # 96-255

UI = {
    BLACK: (0, 0, 0), WHITE: (255, 255, 255), LGREY: (204, 204, 212),
    MGREY: (140, 140, 152), DGREY: (76, 76, 88), TDARK: (36, 56, 116),
    TLIGHT: (96, 128, 210), RED: (214, 64, 52), YELLOW: (250, 212, 64),
    GREEN: (78, 178, 92), SHADOW: (16, 16, 28), SKY: (120, 178, 238),
    ORANGE: (240, 142, 44), PURPLE: (150, 92, 204), BROWN: (140, 92, 52),
    PAPER: (255, 250, 222),
}
EXTRA = [(255, 150, 160), (120, 220, 220), (60, 120, 60), (200, 160, 100),
         (90, 90, 180), (230, 230, 120), (180, 60, 120), (100, 200, 140),
         (250, 190, 120), (60, 60, 60), (160, 200, 255), (255, 255, 180)]   # 36-47
WALLPAPERS = [                  # entries 32-35: base, lines, shade, light
    ("Blue", [(64, 104, 168), (96, 140, 204), (48, 80, 138), (150, 190, 240)]),
    ("Green", [(60, 130, 90), (92, 168, 116), (44, 104, 70), (150, 214, 160)]),
    ("Grey", [(120, 120, 128), (156, 156, 164), (96, 96, 104), (200, 200, 208)]),
    ("Sunset", [(170, 80, 96), (220, 120, 96), (130, 56, 88), (250, 190, 120)]),
]


def rainbow():
    out = []
    for i in range(NRAIN):
        h = i / NRAIN * 6
        k = int(h)
        f = h - k
        v = [(1, f, 0), (1 - f, 1, 0), (0, 1, f), (0, 1 - f, 1), (f, 0, 1), (1, 0, 1 - f)][k % 6]
        out.append(tuple(round(40 + 215 * c) for c in v))
    return out


# --- the C64 side -----------------------------------------------------------
SCREEN_W, SCREEN_H = 320, 200
MENU_H = 12                     # menu bar, black line at y 11
SH = 3                          # window shadow
TEXT_Y = 2                      # VIC-II text row r is at y 8r+2 (YSCROLL 5)


def sc(text):
    """ASCII -> screen codes of the lower-case character set."""
    out = []
    for ch in text:
        o = ord(ch)
        if "a" <= ch <= "z":
            out.append(o - 96)
        elif "A" <= ch <= "Z":
            out.append(o)       # 65-90: upper case in this set
        elif ch == "@":
            out.append(0)
        elif 32 <= o < 64:
            out.append(o)
        elif ch == "\n":
            out.append(255)      # newline (13 is "m")
        else:
            raise ValueError(f"no screen code for {ch!r}")
    return out


class Img:
    def __init__(self, w, h, c=0):
        self.w, self.h = w, h
        self.p = [[c] * w for _ in range(h)]

    def rect(self, x1, y1, x2, y2, c):          # x2, y2 exclusive
        for y in range(max(0, y1), min(self.h, y2)):
            for x in range(max(0, x1), min(self.w, x2)):
                self.p[y][x] = c

    def box(self, x1, y1, x2, y2, c):
        self.rect(x1, y1, x2, y1 + 1, c)
        self.rect(x1, y2 - 1, x2, y2, c)
        self.rect(x1, y1, x1 + 1, y2, c)
        self.rect(x2 - 1, y1, x2, y2, c)

    def put(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.p[y][x] = c

    def blit(self, other, x0, y0):
        for y in range(other.h):
            for x in range(other.w):
                if other.p[y][x]:
                    self.put(x0 + x, y0 + y, other.p[y][x])

    def bytes(self):
        return bytes(v for row in self.p for v in row)


# --- icons (32x24) -------------------------------------------------------
def icon_notes():
    i = Img(32, 24)
    i.rect(6, 2, 26, 24, PAPER)
    i.box(6, 2, 26, 24, BLACK)
    for y in range(7, 22, 3):
        i.rect(8, y, 25, y + 1, SKY)
    i.rect(10, 3, 11, 23, RED)
    for x in range(9, 25, 4):
        i.rect(x, 0, x + 2, 4, DGREY)
    i.rect(18, 8, 23, 9, BLACK)
    return i


def icon_photo():
    i = Img(32, 24)
    i.rect(2, 2, 30, 22, BROWN)
    i.box(2, 2, 30, 22, BLACK)
    i.rect(5, 5, 27, 19, SKY)
    for x in range(5, 27):                      # hills
        top = 13 + round(3 * __import__("math").sin(x / 3.0))
        i.rect(x, top, x + 1, 19, GREEN)
    i.rect(20, 7, 24, 11, YELLOW)
    i.box(5, 5, 27, 19, BLACK)
    return i


def icon_colours():
    i = Img(32, 24)
    i.rect(3, 3, 29, 21, WHITE)
    i.box(3, 3, 29, 21, BLACK)
    cols = [RED, ORANGE, YELLOW, GREEN, SKY, TLIGHT, PURPLE, BROWN, 36, 37, 38, 39]
    for k, c in enumerate(cols):
        x = 5 + (k % 4) * 6
        y = 5 + (k // 4) * 5
        i.rect(x, y, x + 5, y + 4, c)
    return i


def icon_chip():
    i = Img(32, 24)
    i.rect(6, 4, 26, 20, DGREY)
    i.box(6, 4, 26, 20, BLACK)
    for y in range(6, 19, 3):
        i.rect(2, y, 6, y + 1, LGREY)
        i.rect(26, y, 30, y + 1, LGREY)
    for k in range(10):                         # an X
        i.rect(11 + k, 7 + k, 12 + k, 8 + k, YELLOW)
        i.rect(20 - k, 7 + k, 21 - k, 8 + k, YELLOW)
    i.rect(8, 6, 10, 8, LGREY)
    return i


def icon_trash():
    i = Img(32, 24)
    i.rect(8, 5, 24, 23, LGREY)
    i.box(8, 5, 24, 23, BLACK)
    i.rect(6, 3, 26, 6, MGREY)
    i.box(6, 3, 26, 6, BLACK)
    i.rect(13, 1, 19, 4, MGREY)
    i.box(13, 1, 19, 4, BLACK)
    for x in (12, 16, 20):
        i.rect(x, 8, x + 1, 21, DGREY)
    return i


# label row r -> icon top 8r-25 (box at 8r+1 .. 8r+12)
ICONS = [  # (label, draw, x, label row, action)
    ("Notes", icon_notes, 272, 6, 0),
    ("Photos", icon_photo, 272, 11, 1),
    ("Colours", icon_colours, 272, 16, 2),
    ("VIC-X", icon_chip, 272, 21, 3),
    ("Trash", icon_trash, 16, 23, 0x20),
]

# --- menus -------------------------------------------------------------------
MENUS = [  # (title, first column of the title's span, items: (text, action))
    ("VIC-X", 0, [("About VIC-X", 3)]),
    ("File", 7, [("Open Notes", 0), ("Open Photos", 1), ("Open Colours", 2), ("Close all", 0x20)]),
    ("View", 13, [(f"{n} desktop", 0x10 + k) for k, (n, _) in enumerate(WALLPAPERS)]),
]
ITEM_H = 10

# --- windows -------------------------------------------------------------------
NOTES_W, NOTES_H = 184, 98
NX0, NY0, NLINE = 8, 15, 10
NCOLS = (NOTES_W - NX0 - 4) // 8
NROWS = (NOTES_H - NY0 - 2) // NLINE
PHOTO_W, PHOTO_H = 164, 115
COL_W, COL_H = 132, 105
ABOUT_W, ABOUT_H = 188, 97
WINDOWS = [  # (title, w, h, default x, default y)
    ("Notes", NOTES_W, NOTES_H, 12, 20),
    ("Photos", PHOTO_W, PHOTO_H, 96, 40),
    ("Colours", COL_W, COL_H, 40, 76),
    ("About VIC-X", ABOUT_W, ABOUT_H, 70, 34),
]
ABOUT_LINES = [
    "VIC-X graphics for",
    "the Commodore 64",
    "",
    "VRAM     {0} KB",
    "XRAM     {1} MB",
    "Sprites  {2}",
    "Per line {3}",
    "2 layers, DMA blitter",
]
NOTES_TEXT = (
    "Dear diary,\n"
    "today my C64 got windows. They live in XRAM, and the blitter "
    "draws them in 256 colours. The CPU mostly waits."
)


def wrap(text, cols, rows):
    lines = []
    for para in text.split("\n"):
        line = ""
        for word in para.split(" "):
            if line and len(line) + 1 + len(word) > cols:
                lines.append(line)
                line = word
            else:
                line = f"{line} {word}" if line else word
        lines.append(line)
    if len(lines) > rows or any(len(l) > cols for l in lines):
        raise SystemExit(f"notes text does not fit {cols}x{rows}: {lines}")
    return lines


def window_frame(title, w, h, body):
    i = Img(w, h, body)
    for y in range(1, 11):
        i.rect(1, y, w - 1, y + 1, TLIGHT if y % 2 else TDARK)
    i.rect(0, 11, w, 12, BLACK)
    i.box(0, 0, w, h, BLACK)
    i.rect(3, 2, 11, 10, WHITE)                 # close box
    i.box(3, 2, 11, 10, BLACK)
    tw = len(title) * 8
    tx = (w - tw) // 2
    i.rect(tx - 4, 1, tx + tw + 4, 11, WHITE)
    return i, tx


def main():
    art, out = sys.argv[1], sys.argv[2]
    os.makedirs(os.path.join(out, "desktop"), exist_ok=True)
    texts = []          # (symbol, stride, x, y, fg, bg, screen codes) or number

    def text(sym, stride, x, y, fg, bg, s):
        texts.append(("t", sym, stride, x, y, fg, bg, sc(s)))

    # palette 16-95
    pal = {}
    pal.update(UI)
    for k, c in enumerate(EXTRA):
        pal[36 + k] = c
    for k, c in enumerate(WALLPAPERS[0][1]):
        pal[WALL + k] = c
    rain = rainbow()
    for k, c in enumerate(rain):
        pal[RAINBOW + k] = c
    with open(os.path.join(out, "desktop.pal"), "wb") as f:
        f.write(bytes(v for e in range(16, 96) for v in (*pal.get(e, (0, 0, 0)), 0)))

    # desktop picture
    d = Img(SCREEN_W, SCREEN_H)
    for y in range(MENU_H, SCREEN_H):
        for x in range(SCREEN_W):
            u, v = (x + y) % 8, (x - y) % 8
            c = WALL
            if u == 0 or v == 0:
                c = WALL + 1
            if u == 0 and v == 0:
                c = WALL + 3
            elif (u == 1 and v == 7) or (u == 7 and v == 1):
                c = WALL + 2
            d.p[y][x] = c
    d.rect(0, 0, SCREEN_W, 11, WHITE)
    d.rect(0, 11, SCREEN_W, 12, BLACK)
    icon_rects = []
    for label, draw, x, row, action in ICONS:
        top = 8 * row - 25
        d.blit(draw(), x, top)
        n = len(label)
        col = round((x + 16 - 4 * n) / 8)
        col = max(0, min(40 - n, col))
        d.rect(col * 8 - 2, 8 * row + 1, (col + n) * 8 + 2, 8 * row + 11, WHITE)
        d.box(col * 8 - 2, 8 * row + 1, (col + n) * 8 + 2, 8 * row + 11, BLACK)
        text("DESK_IMG", SCREEN_W, col * 8, 8 * row + 2, BLACK, WHITE, label)
        x1 = min(x, col * 8 - 2)
        x2 = max(x + 32, (col + n) * 8 + 2)
        icon_rects.append((x1, top, x2, 8 * row + 11, action))

    with open(os.path.join(out, "desktop.img"), "wb") as f:
        f.write(d.bytes())

    # pointer
    arrow = [
        "X...............",
        "XX..............",
        "XWX.............",
        "XWWX............",
        "XWWWX...........",
        "XWWWWX..........",
        "XWWWWWX.........",
        "XWWWWWWX........",
        "XWWWWWWWX.......",
        "XWWWWWXXXX......",
        "XWWXWWX.........",
        "XWX.XWWX........",
        "XX..XWWX........",
        "X....XWWX.......",
        ".....XWWX.......",
        "......XX........",
    ]
    with open(os.path.join(out, "desktop_pointer.spr"), "wb") as f:
        f.write(bytes({"X": BLACK, "W": WHITE, ".": 0}[c] for row in arrow for c in row))

    # windows
    imgs = []
    for k, (title, w, h, _, _) in enumerate(WINDOWS):
        img, tx = window_frame(title, w, h, PAPER if k == 0 else WHITE)
        text(f"WIN{k}_IMG", w, tx, 2, BLACK, WHITE, title)
        imgs.append(img)
    notes = imgs[0]
    for r in range(NROWS):
        notes.rect(2, NY0 + r * NLINE + 9, NOTES_W - 2, NY0 + r * NLINE + 10, SKY)
    notes.rect(5, 12, 6, NOTES_H - 1, RED)
    lines = wrap(NOTES_TEXT, NCOLS - 1, NROWS)     # the cursor stays inside

    photo = imgs[1]
    _, ph, prow = pngio.read(os.path.join(art, "desktop_photo.png"))
    colours = sorted({(r, g, b) for row in prow for (r, g, b, a) in row})
    if len(colours) > 160:
        raise SystemExit(f"desktop_photo.png has {len(colours)} colours, 160 at most")
    cidx = {c: PHOTO + k for k, c in enumerate(colours)}
    for y, row in enumerate(prow):
        for x, (r, g, b, a) in enumerate(row):
            photo.put(2 + x, 13 + y, cidx[(r, g, b)])
    with open(os.path.join(out, "desktop_photo.pal"), "wb") as f:
        f.write(bytes(v for c in colours for v in (*c, 0)))

    cw = imgs[2]
    for row in range(15):
        for col in range(16):
            x, y = 2 + col * 8, 13 + row * 6
            cw.rect(x, y, x + 7, y + 5, 16 + row * 16 + col)

    about = imgs[3]
    for n, line in enumerate(ABOUT_LINES):
        y = 15 + n * 10
        parts = line.split("{")
        x = 8
        for p in parts:
            if "}" in p:
                num, rest = p.split("}", 1)
                texts.append(("n", "WIN3_IMG", ABOUT_W, x, y, BLACK, WHITE, int(num)))
                x += 8 * 4              # numbers up to 4 digits
                p = rest
            if p:
                text("WIN3_IMG", ABOUT_W, x, y, BLACK, WHITE, p)
                x += 8 * len(p)
    for k, img in enumerate(imgs):
        with open(os.path.join(out, f"desk_win{k}.img"), "wb") as f:
            f.write(img.bytes())

    # menus
    menu_info = []
    for k, (title, col, items) in enumerate(MENUS):
        w = max(len(t) for t, _ in items) * 8 + 10
        h = len(items) * ITEM_H + 2
        for inv in (0, 1):
            m = Img(w, h, BLACK if inv else WHITE)
            m.box(0, 0, w, h, BLACK)
            for n, (t, _) in enumerate(items):
                text(f"MENU{k}_{'INV' if inv else 'IMG'}", w, 5, 1 + n * ITEM_H + 1,
                     WHITE if inv else BLACK, BLACK if inv else WHITE, t)
            with open(os.path.join(out, f"desk_menu{k}{'i' if inv else ''}.img"), "wb") as f:
                f.write(m.bytes())
        span = (col, col + len(title) + 1)
        menu_info.append((span, col * 8, w, h, [a for _, a in items]))

    # the menu bar: " VIC-X  File  View", the CPU readout at column 32
    bar = [32] * 40
    for title, col, _ in MENUS:
        for n, c in enumerate(sc(title)):
            bar[col + 1 + n] = c

    # zoom rectangles from each window's icon (or the bar) to the window
    def icon_of(win):
        for r in icon_rects:
            if r[4] == win:
                return r[:4]
        return (0, 0, 40, MENU_H)
    zoom = []
    for k, (_, w, h, x, y) in enumerate(WINDOWS):
        a = icon_of(k)
        b = (x, y, x + w, y + h)
        steps = []
        for s in range(1, 9):
            steps.append(tuple(round(a[j] + (b[j] - a[j]) * s / 9) for j in range(4)))
        zoom.append(steps)

    # the script a test build plays (headless VICE has no mouse)
    script = []

    def move(x, y):
        script.append(f"S_MOVE {x}, {y}")

    def wait(n):
        script.append(f"S_WAIT {n}")

    def click():
        script.extend(["S_DOWN", "S_WAIT 3", "S_UP", "S_WAIT 3"])

    def dbl(k):
        x1, y1, x2, y2, _ = icon_rects[k]
        move((x1 + x2) // 2, y1 + 12)
        wait(10)
        click()
        click()

    def drag(x1, y1, x2, y2):
        move(x1, y1)
        wait(10)
        script.append("S_DOWN")
        wait(5)
        move(x2, y2)
        wait(5)
        script.append("S_UP")

    def menu(m, item):
        (lo, hi), mx, w, h, _ = menu_info[m]
        move(lo * 8 + 12, 5)
        wait(10)
        click()
        wait(15)
        move(mx + w // 2, MENU_H + 1 + item * ITEM_H + 5)
        wait(20)
        click()

    def closebox(k, pos):
        x, y = pos
        move(x + 6, y + 5)
        wait(10)
        click()

    pos = {k: (x, y) for k, (_, _, _, x, y) in enumerate(WINDOWS)}
    wait(50)
    dbl(0)                                       # Notes
    wait(200)
    dbl(1)                                       # Photos
    wait(60)
    x, y = pos[1]
    drag(x + 120, y + 5, 88 + 120, 82 + 5)       # clear of the icons
    pos[1] = (88, 82)
    wait(40)
    menu(2, 3)                                   # Sunset desktop
    wait(60)
    dbl(2)                                       # Colours
    wait(150)
    x, y = pos[2]
    drag(x + 80, y + 5, 20 + 80, 90 + 5)
    pos[2] = (20, 90)
    wait(40)
    move(150, 60)                                # Notes to the front
    wait(10)
    click()
    wait(100)
    menu(0, 0)                                   # About VIC-X
    wait(250)
    closebox(3, pos[3])
    wait(30)
    closebox(0, pos[0])
    wait(30)
    closebox(2, pos[2])
    wait(30)
    closebox(1, pos[1])
    wait(30)
    menu(2, 0)                                   # Blue desktop
    wait(100)
    script.append("S_LOOP")

    # --- desktop.inc -------------------------------------------------------
    L = ["; desktop.inc - layout, menus, texts and script of the desktop demo",
         "; (generated by tools/gen_desktop.py)", "",
         f"MENU_H    = {MENU_H}", f"SH        = {SH}", f"NWIN      = {len(WINDOWS)}",
         f"NMENU     = {len(MENUS)}", f"NICON     = {len(ICONS)}", f"ITEM_H    = {ITEM_H}",
         f"SHADOW_COL = {SHADOW}", f"WALL_PAL  = {WALL}", f"RAINBOW   = {RAINBOW}",
         f"NRAIN     = {NRAIN}", f"NOTES_W   = {NOTES_W}", f"NOTES_H   = {NOTES_H}",
         f"NX0       = {NX0}", f"NY0       = {NY0}", f"NLINE     = {NLINE}",
         f"NCOLS     = {NCOLS}", f"NROWS     = {NROWS}", f"CURSOR_COL = {SKY}",
         f"PAPER_COL = {PAPER}", f"INK_COL   = {BLACK}", "",
         "S_LOOP = 0", "S_MOVE_ = 1", "S_DOWN = 2", "S_UP = 3", "S_WAIT_ = 4",
         ".define S_MOVE(xx, yy) 1, <(xx), >(xx), (yy)",
         ".define S_WAIT(nn) 4, (nn)", "",
         ".pushseg", ".rodata"]

    def bytes_line(name, vals):
        L.append(f"{name}:")
        for i in range(0, len(vals), 16):
            L.append("        .byte " + ", ".join(str(v) for v in vals[i:i + 16]))

    bytes_line("win_w", [w for _, w, _, _, _ in WINDOWS])
    bytes_line("win_h", [h for _, _, h, _, _ in WINDOWS])
    bytes_line("win_x0_lo", [x & 255 for *_, x, _ in WINDOWS])
    bytes_line("win_x0_hi", [x >> 8 for *_, x, _ in WINDOWS])
    bytes_line("win_y0", [y for *_, y in WINDOWS])
    bytes_line("win_maxx_lo", [(SCREEN_W - w - SH) & 255 for _, w, *_ in WINDOWS])
    bytes_line("win_maxx_hi", [(SCREEN_W - w - SH) >> 8 for _, w, *_ in WINDOWS])
    bytes_line("win_maxy", [SCREEN_H - h - SH for _, _, h, *_ in WINDOWS])
    for part, sh in (("lo", 0), ("mid", 8), ("hi", 16)):
        L.append(f"win_img_{part}:")
        L.append("        .byte " + ", ".join(f"<(WIN{k}_IMG >> {sh})" for k in range(len(WINDOWS))))
    bytes_line("icon_x1_lo", [r[0] & 255 for r in icon_rects])
    bytes_line("icon_x1_hi", [r[0] >> 8 for r in icon_rects])
    bytes_line("icon_y1", [r[1] for r in icon_rects])
    bytes_line("icon_x2_lo", [r[2] & 255 for r in icon_rects])
    bytes_line("icon_x2_hi", [r[2] >> 8 for r in icon_rects])
    bytes_line("icon_y2", [r[3] for r in icon_rects])
    bytes_line("icon_action", [r[4] for r in icon_rects])
    bytes_line("menu_lo", [m[0][0] for m in menu_info])
    bytes_line("menu_hi", [m[0][1] for m in menu_info])
    bytes_line("menu_x", [m[1] for m in menu_info])
    bytes_line("menu_w", [m[2] for m in menu_info])
    bytes_line("menu_h", [m[3] for m in menu_info])
    bytes_line("menu_n", [len(m[4]) for m in menu_info])
    acts = []
    starts = []
    for m in menu_info:
        starts.append(len(acts))
        acts += m[4]
    bytes_line("menu_first", starts)
    bytes_line("menu_actions", acts)
    for part, sh in (("lo", 0), ("mid", 8), ("hi", 16)):
        L.append(f"menu_img_{part}:")
        L.append("        .byte " + ", ".join(f"<(MENU{k}_IMG >> {sh})" for k in range(len(MENUS))))
        L.append(f"menu_inv_{part}:")
        L.append("        .byte " + ", ".join(f"<(MENU{k}_INV >> {sh})" for k in range(len(MENUS))))
    bytes_line("bar_text", bar)
    L.append("texts:           ; 1, XRAM address (3), stride (2), fg, bg, codes, 0 | 2, ..., number | 0")
    for t in texts:
        kind, sym, stride, x, y, fg, bg, payload = t
        addr = f"{sym} + {y * stride + x}"
        L.append(f"        .byte {1 if kind == 't' else 2}, <({addr}), >({addr}), ^({addr}), "
                 f"<{stride}, >{stride}, {fg}, {bg}")
        if kind == "t":
            L.append("        .byte " + ", ".join(str(c) for c in payload) + ", 0")
        else:
            L.append(f"        .byte {payload}")
    L.append("        .byte 0")
    notes_codes = sc("\n".join(lines)) + [0]
    bytes_line("notes_text", notes_codes)
    bytes_line("wallpapers", [v for _, cs in WALLPAPERS for c in cs for v in (*c, 0)])
    bytes_line("rainbow_rgb", [v for c in rain for v in (*c, 0)] + [v for c in rain for v in (*c, 0)])
    L.append("zoom:            ; per window, 8 steps of x1 (2), y1, x2 (2), y2")
    for steps in zoom:
        for (x1, y1, x2, y2) in steps:
            L.append(f"        .byte {x1 & 255}, {x1 >> 8}, {y1}, {x2 & 255}, {x2 >> 8}, {y2}")
    bytes_line("row_lo", [(y * 320) & 255 for y in range(200)])
    bytes_line("row_hi", [(y * 320) >> 8 for y in range(200)])
    L.append(".ifdef DESK_TEST          ; the test build's script")
    L.append("script:")
    for s in script:
        L.append(f"        .byte {s}")
    L.append(".endif")
    L += [".popseg", ""]
    with open(os.path.join(out, "desktop", "desktop.inc"), "w", newline="\n") as f:
        f.write("\n".join(L))

    # a preview of the desktop with the default windows, for checking the art
    prev = [[None] * SCREEN_W for _ in range(SCREEN_H)]
    full = dict(pal)
    for k, c in enumerate(colours):
        full[PHOTO + k] = c
    rows = [[(*full.get(d.p[y][x], (255, 0, 255)), 255) for x in range(SCREEN_W)] for y in range(SCREEN_H)]
    for k, img in enumerate(imgs):
        _, w, h, x0, y0 = WINDOWS[k]
        for y in range(h + SH):
            for x in range(w + SH):
                if x < w and y < h:
                    c = img.p[y][x]
                elif (x >= w and y >= SH) or (y >= h and x >= SH):
                    c = SHADOW
                else:
                    continue
                rows[y0 + y][x0 + x] = (*full.get(c, (255, 0, 255)), 255)
    pngio.write(os.path.join(out, "desktop_preview.png"), SCREEN_W, SCREEN_H, rows)
    print(f"desktop: {len(texts)} texts, script {len(script)} steps, "
          f"notes {len(lines)} lines")


if __name__ == "__main__":
    main()
