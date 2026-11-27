; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t18_bitmap4 - layer 0 as a 4-bit bitmap with a palette bank.
;
; Bitmap at VRAM $00000, stride 160, palette bank 6 (setup +14).  High
; nibble = left pixel; pixel n shows palette entry 6*16 + n, n = 0 is
; transparent.  All bytes are $22 (entry 98) except line 0: byte 0 = $1F
; (entries 97, 111) and byte 1 = $00 (transparent).  Scroll X is set to 5
; and must be ignored, as for every bitmap.  $D021 = black.
; Window (0,0) is screenshot (32,35).
;
; RUN: -vicx
; PIXEL: 32 35 FF0000
; PIXEL: 33 35 00FF00
; PIXEL: 34 35 000000
; PIXEL: 35 35 000000
; PIXEL: 36 35 0000FF
; PIXEL: 32 36 0000FF
; PIXEL: 351 234 0000FF

.include "harness.inc"

.code
main:
        CLEAR_SCREEN
        lda #$00
        sta $D020
        sta $D021

        VICX_UNLOCK_SEQ
        SET_PAL 97,  $FF, $00, $00
        SET_PAL 98,  $00, $00, $FF
        SET_PAL 111, $00, $FF, $00

        VICX_P0_SET $00000, VICX_STEP_1
        lda #$22
        P0_FILL 32000
        VICX_P0_SET $00000, VICX_STEP_1
        lda #$1F
        sta VICX_P0_DATA
        lda #$00
        sta VICX_P0_DATA

        LAYER_SET VICX_LAYER0, VICX_LMODE_BITMAP4, 0, $00000, 0, 5, 0, 160, 6
        lda #VICX_CTRL_L0 | VICX_CTRL_BGTRANS
        sta VICX_CTRL

        WAIT_FRAMES 3
        PASS
