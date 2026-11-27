; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t23_sprite_limits - per-line limits (32 sprites, 640 sprite pixels): the
; highest entries drop out for that line only, and the overflow flag
; ($20841 bit 0) reports it for the frame.
;
; Line A, window y 20-27: entries 0-31 (8x8, colour 41) at x = n * 9, and
; entry 32 (colour 43) at x 288: the 33rd sprite drops out.
; Line B, window y 60-67: entries 33-42 (64x8, colour 42) at x = (n-33) * 28
; use 640 pixels; entry 43 (64x8, colour 44) at x 300 drops out.
; Checks: the overflow flag is set; with entries 32 and 43 off it clears;
; with them on again the screenshot shows both dropped.
; Window (0,0) is screenshot (32,35).
;
; RUN: -vicx
; PIXEL: 311 55 FF0000
; PIXEL: 320 55 000000
; PIXEL: 282 95 00FF00
; PIXEL: 348 95 000000

.include "harness.inc"

PAT8  = $0000           ; 8x8, colour 41
PAT64 = $0040           ; 64x8, colour 42
PATX  = $0240           ; 8x8, colour 43
PATY  = $0280           ; 64x8, colour 44

.code
main:
        CLEAR_SCREEN
        lda #$00
        sta $D020
        sta $D021

        VICX_UNLOCK_SEQ
        SET_PAL 41, $FF, $00, $00
        SET_PAL 42, $00, $FF, $00
        SET_PAL 43, $FF, $FF, $00
        SET_PAL 44, $FF, $00, $FF

        VICX_P0_SET PAT8, VICX_STEP_1
        lda #41
        P0_FILL 64
        lda #42
        P0_FILL 512
        lda #43
        P0_FILL 64
        lda #44
        P0_FILL 512

.repeat 32, I
        SPRITE I, I * 9, 20, VICX_SW_8 | VICX_SH_8, VICX_S_ON, PAT8, VICX_S_8BIT
.endrep
        SPRITE 32, 288, 20, VICX_SW_8 | VICX_SH_8, VICX_S_ON, PATX, VICX_S_8BIT
.repeat 10, I
        SPRITE 33 + I, I * 28, 60, VICX_SW_64 | VICX_SH_8, VICX_S_ON, PAT64, VICX_S_8BIT
.endrep
        SPRITE 43, 300, 60, VICX_SW_64 | VICX_SH_8, VICX_S_ON, PATY, VICX_S_8BIT

        lda #VICX_CTRL_SPR | VICX_CTRL_BGTRANS
        sta VICX_CTRL

        WAIT_FRAMES 3
        jsr read_status
        and #VICX_SPRSTAT_OVERFLOW
        EXPECT_A VICX_SPRSTAT_OVERFLOW, 2

        ; entries 32 and 43 off: nothing drops
        lda #0
        jsr set_extra
        WAIT_FRAMES 3
        jsr read_status
        EXPECT_A $00, 3

        lda #VICX_S_ON
        jsr set_extra
        WAIT_FRAMES 3
        jsr read_status
        and #VICX_SPRSTAT_OVERFLOW
        EXPECT_A VICX_SPRSTAT_OVERFLOW, 4
        PASS

read_status:
        VICX_P0_SET VICX_SPRSTAT, VICX_STEP_0
        lda VICX_P0_DATA
        rts

; A = new YH byte (Y high bits are 0) for entries 32 and 43
set_extra:
        pha
        VICX_P0_SET VICX_SPRITES + 32 * 8 + VICX_S_YH, VICX_STEP_0
        pla
        sta VICX_P0_DATA
        pha
        VICX_P0_SET VICX_SPRITES + 43 * 8 + VICX_S_YH, VICX_STEP_0
        pla
        sta VICX_P0_DATA
        rts
