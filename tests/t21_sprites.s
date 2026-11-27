; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t21_sprites - the sprite engine draws: sizes, 4- and 8-bit pixels, palette
; bank, flips, double width, X/Y wrap at 1024, the on bit.
;
; Sprite X/Y are display-window pixels: (0,0) is screenshot (32,35).
; Patterns in VRAM (row by row, 4-bit high nibble = left pixel):
;   $0000 16x16 8-bit: colour 40, pixel (0,0) = 41
;   $0100  8x8  4-bit: bytes $12, byte 0 = $30 (pixels 3, 0, then 1 2 1 2 ...)
;   $0120  8x8  8-bit: colour 42, pixel (0,0) = 43
;   $0160  8x8  8-bit: colour 44
;   $01A0  8x8  8-bit: colour 45
;   $0200 64x8  8-bit: colour 46
; Entries:
;   0  16x16 8-bit at (10,20)
;   1   8x8  4-bit bank 3, flip X, at (100,20): column c shows pixel 7-c
;   2   8x8  8-bit, double width, flip Y, at (200,20): 16 pixels wide,
;       pattern row 0 on window line 27
;   3   8x8  8-bit at (1020,1020): wraps to window x 0-3, y 0-3
;   4   8x8  8-bit at (150,100), on bit clear: not drawn
;   5  64x8  8-bit at (150,150)
; $D021 = black.
;
; RUN: -vicx
; PIXEL: 42 55 FF0000
; PIXEL: 43 55 404040
; PIXEL: 57 70 404040
; PIXEL: 58 55 000000
; PIXEL: 42 71 000000
; PIXEL: 139 55 FF8000
; PIXEL: 138 55 000000
; PIXEL: 137 55 FFFFFF
; PIXEL: 132 55 808080
; PIXEL: 232 62 0000FF
; PIXEL: 233 62 0000FF
; PIXEL: 234 62 00FF00
; PIXEL: 232 55 00FF00
; PIXEL: 247 55 00FF00
; PIXEL: 248 55 000000
; PIXEL: 32 35 FFFF00
; PIXEL: 35 38 FFFF00
; PIXEL: 36 35 000000
; PIXEL: 32 39 000000
; PIXEL: 182 135 000000
; PIXEL: 182 185 00FFFF
; PIXEL: 245 185 00FFFF
; PIXEL: 246 185 000000
; PIXEL: 182 193 000000

.include "harness.inc"

.macro FILL_AT addr, value, count
        VICX_P0_SET addr, VICX_STEP_1
        lda #value
        P0_FILL count
.endmacro

.macro POKE_AT addr, value
        VICX_P0_SET addr, VICX_STEP_0
        lda #value
        sta VICX_P0_DATA
.endmacro

.code
main:
        CLEAR_SCREEN
        lda #$00
        sta $D020
        sta $D021

        VICX_UNLOCK_SEQ
        SET_PAL 40, $40, $40, $40
        SET_PAL 41, $FF, $00, $00
        SET_PAL 42, $00, $FF, $00
        SET_PAL 43, $00, $00, $FF
        SET_PAL 44, $FF, $FF, $00
        SET_PAL 45, $FF, $00, $FF
        SET_PAL 46, $00, $FF, $FF
        SET_PAL 49, $FF, $FF, $FF
        SET_PAL 50, $80, $80, $80
        SET_PAL 51, $FF, $80, $00

        FILL_AT $0000, 40, 256
        POKE_AT $0000, 41
        FILL_AT $0100, $12, 32
        POKE_AT $0100, $30
        FILL_AT $0120, 42, 64
        POKE_AT $0120, 43
        FILL_AT $0160, 44, 64
        FILL_AT $01A0, 45, 64
        FILL_AT $0200, 46, 512

        SPRITE 0, 10, 20,     VICX_SW_16 | VICX_SH_16, VICX_S_ON, $0000, VICX_S_8BIT
        SPRITE 1, 100, 20,    VICX_SW_8 | VICX_SH_8 | VICX_S_FLIPX, VICX_S_ON, $0100, 3
        SPRITE 2, 200, 20,    VICX_SW_8 | VICX_SH_8 | VICX_S_FLIPY, VICX_S_ON, $0120, VICX_S_8BIT | VICX_S_DOUBLE
        SPRITE 3, 1020, 1020, VICX_SW_8 | VICX_SH_8, VICX_S_ON, $0160, VICX_S_8BIT
        SPRITE 4, 150, 100,   VICX_SW_8 | VICX_SH_8, 0, $01A0, VICX_S_8BIT
        SPRITE 5, 150, 150,   VICX_SW_64 | VICX_SH_8, VICX_S_ON, $0200, VICX_S_8BIT

        lda #VICX_CTRL_SPR | VICX_CTRL_BGTRANS
        sta VICX_CTRL

        WAIT_FRAMES 3
        PASS
