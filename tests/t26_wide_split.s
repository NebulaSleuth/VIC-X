; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t26_wide_split - a partly widened window: the left edge latched per line
; (a raster split), the top edge, a layer in front of the VIC-II with CTRL
; bit 4 clear, and the border over the 320x200 area on top.
;
; Window: left 16, right 0, top 10, bottom 0.  Every frame the left edge is
; set to 16 at raster line 10 and to 0 at line 150 (from line 151, screenshot
; y 135).  Screenshot y = line - 16; the 320x200 area starts at (32,35).
; Layer 0, in front of the VIC-II (order $01): 8-bit bitmap, stride 0, window
; x 0-15 colour 33 (green), the rest colour 32 (blue).  So window x 0 is
; screenshot x 16 above the split and x 32 below it.  38 columns: the border
; over the 320x200 area's columns 0-6 (screenshot x 32-38) stays on top even
; of a layer in front.  Border colour 2 = red through CTRL bit 3.
;
; RUN: -vicx
; PIXEL: 20 100 00FF00
; PIXEL: 35 100 FF0000
; PIXEL: 39 100 0000FF
; PIXEL: 20 170 FF0000
; PIXEL: 35 170 FF0000
; PIXEL: 39 170 00FF00
; PIXEL: 40 30 0000FF
; PIXEL: 40 20 FF0000
; PIXEL: 100 240 FF0000

.include "harness.inc"

.code
main:
        CLEAR_SCREEN
        lda #$02
        sta $D020
        lda #$00
        sta $D021
        lda $D016
        and #$F7
        sta $D016

        VICX_UNLOCK_SEQ
        SET_PAL 0,  $00, $00, $00
        SET_PAL 2,  $FF, $00, $00
        SET_PAL 32, $00, $00, $FF
        SET_PAL 33, $00, $FF, $00

        VICX_P0_SET $10000, VICX_STEP_1
        lda #33
        P0_FILL 16
        lda #32
        P0_FILL 384
        LAYER_SET VICX_LAYER0, VICX_LMODE_BITMAP8, 0, $10000, 0, 0, 0, 0, 0

        VICX_P0_SET VICX_ORDER, VICX_STEP_1
        lda #1 << VICX_ORDER_L0
        sta VICX_P0_DATA                ; order
        lda #0
        sta VICX_P0_DATA                ; sprite status (not used)
        lda #16
        sta VICX_P0_DATA                ; left
        lda #0
        sta VICX_P0_DATA                ; right
        lda #10
        sta VICX_P0_DATA                ; top
        lda #0
        sta VICX_P0_DATA                ; bottom

        lda #VICX_CTRL_L0 | VICX_CTRL_PALMAP
        sta VICX_CTRL

        VICX_P0_SET VICX_WIDE_LEFT, VICX_STEP_0
        lda #4
        sta frames
frame:
        ldx #10
        jsr wait_line
        lda #16
        sta VICX_P0_DATA
        ldx #150
        jsr wait_line
        lda #0
        sta VICX_P0_DATA
        dec frames
        bne frame
.ifdef HW_RESULT
        ; on hardware the screenshot comes later: show the result, and keep
        ; the splits going
        lda #0
        jsr RESULT_HOOK
        jmp frame
.endif
        PASS

wait_line:
:       cpx $D012
        beq :-
:       cpx $D012
        bne :-
        lda $D011
        bmi :-
        rts

.bss
frames: .res 1
