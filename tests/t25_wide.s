; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t25_wide - the wide window at full size: layers and sprites fill the
; whole visible frame, (0,0) moves to its corner, and the border over the
; 320x200 area stays on top.
;
; All four edges $FF, clamped at the visible edge of VICE's normal PAL
; border: 32 pixels left and right, 35 lines top, 37 bottom.  The window is
; then the whole 384x272 screenshot, window (0,0) = screenshot (0,0).
; Layer 0: 8-bit bitmap, stride 384, colour 32 (blue), pixel (0,0) = 33,
; pixel (383,271) = 34.  Sprite: 8x8 colour 35 at (370,260).
; 38 columns: the VIC-II border covers 320x200-area columns 0-6 and 311-319
; (screenshot x 32-38 and 343-351) and stays on top there; in the widened
; part, border pixels are background and, with CTRL bit 4, transparent.
; CTRL bit 3: VIC-II colours through palette entries 0-15, border = 2 = red.
;
; RUN: -vicx
; PIXEL: 0 0 00FF00
; PIXEL: 1 0 0000FF
; PIXEL: 383 271 FFFF00
; PIXEL: 100 10 0000FF
; PIXEL: 20 100 0000FF
; PIXEL: 35 100 FF0000
; PIXEL: 345 100 FF0000
; PIXEL: 360 100 0000FF
; PIXEL: 370 260 FF00FF
; PIXEL: 378 260 0000FF

.include "harness.inc"

.code
main:
        CLEAR_SCREEN
        lda #$02
        sta $D020
        lda #$00
        sta $D021
        lda $D016                       ; 38 columns
        and #$F7
        sta $D016

        VICX_UNLOCK_SEQ
        SET_PAL 0,  $00, $00, $00
        SET_PAL 2,  $FF, $00, $00
        SET_PAL 32, $00, $00, $FF
        SET_PAL 33, $00, $FF, $00
        SET_PAL 34, $FF, $FF, $00
        SET_PAL 35, $FF, $00, $FF

        ; 384 x 272 bitmap at $00000 (104448 bytes)
        VICX_P0_SET $00000, VICX_STEP_1
        lda #32
        P0_FILL 65535
        P0_FILL 104448 - 65535
        VICX_P0_SET $00000, VICX_STEP_0
        lda #33
        sta VICX_P0_DATA
        VICX_P0_SET 104447, VICX_STEP_0
        lda #34
        sta VICX_P0_DATA
        LAYER_SET VICX_LAYER0, VICX_LMODE_BITMAP8, 0, $00000, 0, 0, 0, 384, 0

        ; sprite pattern at $1A000
        VICX_P0_SET $1A000, VICX_STEP_1
        lda #35
        P0_FILL 64
        SPRITE 0, 370, 260, VICX_SW_8 | VICX_SH_8, VICX_S_ON, $1A000, VICX_S_8BIT

        VICX_P0_SET VICX_WIDE_LEFT, VICX_STEP_1
        lda #$FF
        sta VICX_P0_DATA
        sta VICX_P0_DATA
        sta VICX_P0_DATA
        sta VICX_P0_DATA

        lda #VICX_CTRL_L0 | VICX_CTRL_SPR | VICX_CTRL_BGTRANS | VICX_CTRL_PALMAP
        sta VICX_CTRL

        WAIT_FRAMES 3
        PASS
