; t14_transparent - bitmap colour 0 is transparent.
;
; The bitmap is colour 0 in its top 100 lines and colour 32 (blue) below.
; With the VIC-II in front of layer 0 and CTRL bit 4 set, colour-0 pixels
; show the VIC-II background ($D021 = 2) instead of palette entry 0.
; CTRL bit 3 is on so the VIC-II colours come from the VIC-X palette:
; entry 2 = $800000, entry 0 = $00FF00 (the border, $D020 = 0, shows it).
; Window (0,0) is screenshot (32,35).
;
; RUN: -vicx
; PIXEL: 100 50 800000
; PIXEL: 32 35 800000
; PIXEL: 351 134 800000
; PIXEL: 100 135 0000FF
; PIXEL: 351 234 0000FF
; PIXEL: 10 10 00FF00

.include "harness.inc"

.code
main:
        CLEAR_SCREEN
        lda #$00
        sta $D020
        lda #$02
        sta $D021

        VICX_UNLOCK_SEQ
        SET_PAL 0,  $00, $FF, $00
        SET_PAL 2,  $80, $00, $00
        SET_PAL 32, $00, $00, $FF
        VICX_P0_SET $00000, VICX_STEP_1
        lda #32
        P0_FILL 64000
        VICX_P0_SET $00000, VICX_STEP_1
        lda #0
        P0_FILL 32000

        ; layer 0: 8-bit bitmap, base $00000, stride 320
        VICX_P0_SET VICX_LAYER0, VICX_STEP_1
        lda #VICX_LMODE_BITMAP8
        sta VICX_P0_DATA
        lda #$00
        ldx #11                         ; +1..+11
:       sta VICX_P0_DATA
        dex
        bne :-
        lda #<320
        sta VICX_P0_DATA                ; +12 stride
        lda #>320
        sta VICX_P0_DATA                ; +13
        lda #VICX_CTRL_L0 | VICX_CTRL_BGTRANS | VICX_CTRL_PALMAP
        sta VICX_CTRL

        WAIT_FRAMES 3
        PASS
