; t10_bitmap - layer 0 as an 8-bit 320x200 bitmap, aligned with the VIC-II
; display window, behind VIC-II characters.
;
; The bitmap at VRAM $00000 (stride 320) is colour 32 (blue) everywhere,
; except column 0 = 33 (yellow), row 0 = 34 (cyan) and the last pixel
; (319,199) = 35 (magenta).  CTRL = layer 0 on + VIC-II background
; transparent.  A white reverse space at text position (1,1) is VIC-II
; foreground and must cover window pixels 8-15 of lines 8-15.
;
; In the 384x272 PAL screenshot the window starts at (32,35).  The second
; run uses the old 6569 VIC-II, whose colour pipeline is drawn by other code.
;
; RUN: -vicx
; PIXEL: 31 43 000000
; PIXEL: 32 43 FFFF00
; PIXEL: 33 43 0000FF
; PIXEL: 40 34 000000
; PIXEL: 40 35 00FFFF
; PIXEL: 32 35 FFFF00
; PIXEL: 40 36 0000FF
; PIXEL: 351 234 FF00FF
; PIXEL: 350 234 0000FF
; PIXEL: 351 233 0000FF
; PIXEL: 352 234 000000
; PIXEL: 351 235 000000
; PIXEL: 40 43 FFFFFF
; PIXEL: 47 50 FFFFFF
; PIXEL: 48 50 0000FF
; PIXEL: 39 50 0000FF
; PIXEL: 32 50 FFFF00
; RUN: -vicx -VICIImodel 6569
; PIXEL: 31 43 000000
; PIXEL: 32 43 FFFF00
; PIXEL: 33 43 0000FF
; PIXEL: 40 34 000000
; PIXEL: 40 35 00FFFF
; PIXEL: 32 35 FFFF00
; PIXEL: 40 36 0000FF
; PIXEL: 351 234 FF00FF
; PIXEL: 350 234 0000FF
; PIXEL: 351 233 0000FF
; PIXEL: 352 234 000000
; PIXEL: 351 235 000000
; PIXEL: 40 43 FFFFFF
; PIXEL: 47 50 FFFFFF
; PIXEL: 48 50 0000FF
; PIXEL: 39 50 0000FF
; PIXEL: 32 50 FFFF00
; RUN: +vicx
; PIXEL: 33 43 !0000FF
; PIXEL: 192 150 !0000FF

.include "harness.inc"

.code
main:
        CLEAR_SCREEN
        lda #$A0                        ; reverse space at column 1, row 1
        sta $0400 + 40 + 1
        lda #$01                        ; white
        sta $D800 + 40 + 1
        lda #$00                        ; black border, black background
        sta $D020
        sta $D021

        VICX_UNLOCK_SEQ
        SET_PAL 32, $00, $00, $FF
        SET_PAL 33, $FF, $FF, $00
        SET_PAL 34, $00, $FF, $FF
        SET_PAL 35, $FF, $00, $FF

        ; bitmap: all 32, then row 0 = 34, then column 0 = 33, last pixel 35
        VICX_P0_SET $00000, VICX_STEP_1
        lda #32
        P0_FILL 64000
        VICX_P0_SET $00000, VICX_STEP_1
        lda #34
        P0_FILL 320
        VICX_P0_SET $00000, VICX_STEP_320
        lda #33
        P0_FILL 200
        VICX_P0_SET 63999, VICX_STEP_0
        lda #35
        sta VICX_P0_DATA

        ; layer 0 setup: 8-bit bitmap, base $00000, stride 320
        VICX_P0_SET VICX_LAYER0, VICX_STEP_1
        lda #$03                        ; +0 mode: 8-bit bitmap
        sta VICX_P0_DATA
        lda #$00
        ldx #11                         ; +1..+11: map codes, base, tile base, scroll
:       sta VICX_P0_DATA
        dex
        bne :-
        lda #<320                       ; +12/+13 stride
        sta VICX_P0_DATA
        lda #>320
        sta VICX_P0_DATA

        lda #VICX_CTRL_L0 | VICX_CTRL_BGTRANS
        sta VICX_CTRL
        VICX_LOCK_SEQ

        WAIT_FRAMES 3
        PASS
