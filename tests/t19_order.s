; t19_order - the layer order register: two layers and the VIC-II in four
; orders, set by raster splits; the border stays on top of every order.
;
; Layer 0: 8-bit bitmap, stride 0 (every line the same): window x 0-287 =
; colour 32 (blue), x 288-319 = 0 (transparent).  Layer 1: 8-bit bitmap,
; stride 0: x 0-159 = colour 36 (green), x 160-319 transparent.
; VIC-II: 38 columns (the border covers window x 0-6), white reverse spaces
; at text column 1 (window x 8-15) in rows 0, 7, 13 and 19, background
; transparent.  CTRL bit 3 shows VIC-II colours through palette entries
; 0-15: 0 = black, 1 = white, 2 = red (border).
;
; Order per band (a write in line L shows from line L+1):
;   window y   0-49  $00  equal: VIC-II, layer 0, layer 1 (front to back)
;   window y  50-99  $01  layer 0 (1) in front of VIC-II and layer 1 (0)
;   window y 100-149 $04  layer 1 (1) in front
;   window y 150-199 $F4  VIC-II (3), layer 1 (1), layer 0 (0); the sprite
;                         engine field (3) has no effect
; Screenshot = window + (32,35).  Checked per band: the character (x 10),
; x 50, x 200, x 300 and the border (x 3).
;
; RUN: -vicx
; PIXEL: 42 38 FFFFFF
; PIXEL: 82 38 0000FF
; PIXEL: 232 38 0000FF
; PIXEL: 332 38 000000
; PIXEL: 35 38 FF0000
; PIXEL: 42 94 0000FF
; PIXEL: 82 94 0000FF
; PIXEL: 232 94 0000FF
; PIXEL: 332 94 000000
; PIXEL: 35 94 FF0000
; PIXEL: 42 142 00FF00
; PIXEL: 82 142 00FF00
; PIXEL: 232 142 0000FF
; PIXEL: 332 142 000000
; PIXEL: 35 142 FF0000
; PIXEL: 42 190 FFFFFF
; PIXEL: 82 190 00FF00
; PIXEL: 232 190 0000FF
; PIXEL: 332 190 000000
; PIXEL: 35 190 FF0000

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
        lda #$A0                        ; reverse space, white
        ldx #1
        sta $0400 + 0 * 40 + 1
        stx $D800 + 0 * 40 + 1
        sta $0400 + 7 * 40 + 1
        stx $D800 + 7 * 40 + 1
        sta $0400 + 13 * 40 + 1
        stx $D800 + 13 * 40 + 1
        sta $0400 + 19 * 40 + 1
        stx $D800 + 19 * 40 + 1

        VICX_UNLOCK_SEQ
        SET_PAL 0,  $00, $00, $00
        SET_PAL 1,  $FF, $FF, $FF
        SET_PAL 2,  $FF, $00, $00
        SET_PAL 32, $00, $00, $FF
        SET_PAL 36, $00, $FF, $00

        VICX_P0_SET $00000, VICX_STEP_1
        lda #32
        P0_FILL 288
        lda #0
        P0_FILL 32
        VICX_P0_SET $10000, VICX_STEP_1
        lda #36
        P0_FILL 160
        lda #0
        P0_FILL 160

        LAYER_SET VICX_LAYER0, VICX_LMODE_BITMAP8, 0, $00000, 0, 0, 0, 0, 0
        LAYER_SET VICX_LAYER1, VICX_LMODE_BITMAP8, 0, $10000, 0, 0, 0, 0, 0
        lda #VICX_CTRL_L0 | VICX_CTRL_L1 | VICX_CTRL_BGTRANS | VICX_CTRL_PALMAP
        sta VICX_CTRL

        ; port 0 stays on the order register for the splits
        VICX_P0_SET VICX_ORDER, VICX_STEP_0

        lda #4
        sta frames
frame:
        ldx #10
        jsr wait_line
        lda #$00
        sta VICX_P0_DATA
        ldx #100
        jsr wait_line
        lda #1 << VICX_ORDER_L0
        sta VICX_P0_DATA
        ldx #150
        jsr wait_line
        lda #1 << VICX_ORDER_L1
        sta VICX_P0_DATA
        ldx #200
        jsr wait_line
        lda #(3 << VICX_ORDER_VIC) | (1 << VICX_ORDER_L1) | (3 << VICX_ORDER_SPR)
        sta VICX_P0_DATA

        dec frames
        bne frame
        PASS

; wait for the start of raster line X (< 256)
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
