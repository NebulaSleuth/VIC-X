; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t30_layer_low_colours - layer pixels in colours 1-15 use the VIC-X palette.
;
; Palette entry 5 := FF8000 (orange), remapping (CTRL bit 3) off.  Layer 0 is
; an 8-bit bitmap of colour 5 behind a transparent VIC-II background, and the
; border is VIC-II colour 5.  The layer must show orange, while the border
; keeps the stock colour 5 because VIC-II colours go through the palette only
; with remapping on.  VICE used to show the stock colour for layer pixels too.
;
; In the 384x272 PAL screenshot the window starts at (32,35).
;
; RUN: -vicx
; PIXEL: 192 150 FF8000
; PIXEL: 4 4 !FF8000
; RUN: +vicx
; PIXEL: 192 150 !FF8000

.include "harness.inc"

.code
main:
        CLEAR_SCREEN
        lda #$05
        sta $D020
        lda #$00
        sta $D021

        VICX_UNLOCK_SEQ
        SET_PAL 5, $FF, $80, $00

        VICX_P0_SET $00000, VICX_STEP_1
        lda #5
        P0_FILL 64000

        ; layer 0 setup: 8-bit bitmap, base $00000, stride 320
        VICX_P0_SET VICX_LAYER0, VICX_STEP_1
        lda #$03
        sta VICX_P0_DATA
        lda #$00
        ldx #11
:       sta VICX_P0_DATA
        dex
        bne :-
        lda #<320
        sta VICX_P0_DATA
        lda #>320
        sta VICX_P0_DATA

        lda #VICX_CTRL_L0 | VICX_CTRL_BGTRANS
        sta VICX_CTRL
        VICX_LOCK_SEQ

        ; with VIC-X disabled the writes above went to VIC-II mirrors
        lda #$05
        sta $D020
        lda #$00
        sta $D021

        WAIT_FRAMES 3
        PASS
