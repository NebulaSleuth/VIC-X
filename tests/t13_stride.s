; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t13_stride - bitmap base, stride and double-width pixels.
;
; Stride 0 makes every line show the same VRAM row.  The row starts at base
; $00100 and holds colour 40 at +0, 41 at +1, 42 at +2 and 43 at +159; the
; rest is 32 (blue).  With double-width pixels, window pixels 2n and 2n+1
; both show byte n: 0-1 = 40, 2-3 = 41, 4-5 = 42, 318-319 = 43.
; Window (0,0) is screenshot (32,35).
;
; RUN: -vicx
; PIXEL: 32 35 FF0000
; PIXEL: 33 35 FF0000
; PIXEL: 34 35 00FF00
; PIXEL: 35 35 00FF00
; PIXEL: 36 35 0000FF
; PIXEL: 37 35 0000FF
; PIXEL: 38 35 202020
; PIXEL: 350 35 FFFFFF
; PIXEL: 351 35 FFFFFF
; PIXEL: 349 35 202020
; PIXEL: 32 234 FF0000
; PIXEL: 351 234 FFFFFF
; PIXEL: 200 150 202020

.include "harness.inc"

.code
main:
        CLEAR_SCREEN
        lda #$00
        sta $D020

        VICX_UNLOCK_SEQ
        SET_PAL 32, $20, $20, $20
        SET_PAL 40, $FF, $00, $00
        SET_PAL 41, $00, $FF, $00
        SET_PAL 42, $00, $00, $FF
        SET_PAL 43, $FF, $FF, $FF
        ; a decoy at $00000: must not show, since the base is $00100
        VICX_P0_SET $00000, VICX_STEP_1
        lda #43
        P0_FILL 256
        lda #32
        P0_FILL 320
        VICX_P0_SET $00100, VICX_STEP_1
        lda #40
        sta VICX_P0_DATA
        lda #41
        sta VICX_P0_DATA
        lda #42
        sta VICX_P0_DATA
        VICX_P0_SET $00100 + 159, VICX_STEP_0
        lda #43
        sta VICX_P0_DATA

        ; layer 0: 8-bit bitmap, double-width, base $00100, stride 0
        VICX_P0_SET VICX_LAYER0, VICX_STEP_1
        lda #$03 | $08
        sta VICX_P0_DATA
        lda #$00
        sta VICX_P0_DATA                ; +1
        sta VICX_P0_DATA                ; +2 base low
        lda #$01
        sta VICX_P0_DATA                ; +3 base mid
        lda #$00
        ldx #10                         ; +4..+13: base high, ..., stride 0
:       sta VICX_P0_DATA
        dex
        bne :-
        lda #VICX_CTRL_L0 | VICX_CTRL_BGTRANS
        sta VICX_CTRL

        WAIT_FRAMES 3
        PASS
