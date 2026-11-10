; t12_front - the VIC-II stays in front of layer 0: its border, its sprites
; and every pixel not drawn in the $D021 colour.  The test uses 38-column
; mode, where the border covers window columns 0-6 and 311-319.  Changing $D021
; does not change which pixels are transparent.  Relocking VIC-X keeps the
; layer on.
;
; The bitmap is all colour 32 (blue).  Border = colour 0 (black), $D021 =
; colour 6.  Sprite 0 is a solid white 24x21 block at sprite (124,101),
; which the VIC-II shows from the next line: screenshot (132,86)-(155,106).
;
; RUN: -vicx
; PIXEL: 32 100 000000
; PIXEL: 38 100 000000
; PIXEL: 39 100 0000FF
; PIXEL: 342 100 0000FF
; PIXEL: 343 100 000000
; PIXEL: 132 86 FFFFFF
; PIXEL: 155 106 FFFFFF
; PIXEL: 156 106 0000FF
; PIXEL: 131 86 0000FF
; PIXEL: 132 85 0000FF
; PIXEL: 192 150 0000FF

.include "harness.inc"

SPRITE_BLOCK = $0340 / 64              ; 13: sprite data at $0340

.code
main:
        CLEAR_SCREEN
        lda #$00
        sta $D020
        lda #$06
        sta $D021

        ; solid sprite 0
        lda #$FF
        ldx #62
:       sta $0340,x
        dex
        bpl :-
        lda #SPRITE_BLOCK
        sta $07F8
        lda #132 - 32 + 24              ; screenshot x 132 = sprite x 124
        sta $D000
        lda #85 - 35 + 51               ; screenshot y 85 = sprite y 101
        sta $D001
        lda #$01
        sta $D027
        sta $D015

        ; 38 columns
        lda $D016
        and #$F7
        sta $D016

        VICX_UNLOCK_SEQ
        SET_PAL 32, $00, $00, $FF
        VICX_P0_SET $00000, VICX_STEP_1
        lda #32
        P0_FILL 64000
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

        WAIT_FRAMES 2
        lda #$02                        ; a new $D021 colour: still transparent
        sta $D021
        WAIT_FRAMES 2
        PASS
