; t22_sprite_order - sprites in the mix: lower entries in front of higher
; ones, the behind bit, and the sprite engine's place in the layer order.
;
; Layer 0: 8-bit bitmap, stride 0: window x 0-159 colour 32 (blue), the rest
; transparent.  VIC-II: white reverse spaces at text (8,5) and (8,7), window
; x 64-71, y 40-47 and 56-63; background transparent.  Sprites are 8x8,
; 8-bit, solid:
;   0  colour 41 at (20,20) and 1  colour 42 at (24,24): entry 0 in front
;   2  colour 43 at (60,40), behind: one step back, so behind the VIC-II
;      character but still in front of layer 0
;   3  colour 44 at (60,56): in front of the VIC-II character
;   4  colour 45 at (100,120), 5  colour 46 at (200,120)
; Order $00 (sprite engine, VIC-II, layer 0, layer 1) for window y 0-99,
; then $01 (layer 0 in front) from y 100: sprite 4 hides behind layer 0,
; sprite 5 shows where layer 0 is transparent.
; Window (0,0) is screenshot (32,35).
;
; RUN: -vicx
; PIXEL: 52 55 FF0000
; PIXEL: 56 59 FF0000
; PIXEL: 60 63 00FF00
; PIXEL: 92 75 FFFF00
; PIXEL: 96 75 FFFFFF
; PIXEL: 92 91 FF00FF
; PIXEL: 96 91 FF00FF
; PIXEL: 132 155 0000FF
; PIXEL: 232 155 808080

.include "harness.inc"

.code
main:
        CLEAR_SCREEN
        lda #$00
        sta $D020
        sta $D021
        lda #$A0
        ldx #1
        sta $0400 + 5 * 40 + 8
        stx $D800 + 5 * 40 + 8
        sta $0400 + 7 * 40 + 8
        stx $D800 + 7 * 40 + 8

        VICX_UNLOCK_SEQ
        SET_PAL 32, $00, $00, $FF
        SET_PAL 41, $FF, $00, $00
        SET_PAL 42, $00, $FF, $00
        SET_PAL 43, $FF, $FF, $00
        SET_PAL 44, $FF, $00, $FF
        SET_PAL 45, $00, $FF, $FF
        SET_PAL 46, $80, $80, $80

        ; layer 0 row
        VICX_P0_SET $10000, VICX_STEP_1
        lda #32
        P0_FILL 160
        lda #0
        P0_FILL 160
        LAYER_SET VICX_LAYER0, VICX_LMODE_BITMAP8, 0, $10000, 0, 0, 0, 0, 0

        ; one solid 8x8 pattern per colour 41-46 at $0000 + (c - 41) * 64
        VICX_P0_SET $0000, VICX_STEP_1
        ldy #41
:       tya
        ldx #64
:       sta VICX_P0_DATA
        dex
        bne :-
        iny
        cpy #47
        bne :--

        SPRITE 0, 20, 20,   VICX_SW_8 | VICX_SH_8, VICX_S_ON, 0 * 64, VICX_S_8BIT
        SPRITE 1, 24, 24,   VICX_SW_8 | VICX_SH_8, VICX_S_ON, 1 * 64, VICX_S_8BIT
        SPRITE 2, 60, 40,   VICX_SW_8 | VICX_SH_8, VICX_S_ON | VICX_S_BEHIND, 2 * 64, VICX_S_8BIT
        SPRITE 3, 60, 56,   VICX_SW_8 | VICX_SH_8, VICX_S_ON, 3 * 64, VICX_S_8BIT
        SPRITE 4, 100, 120, VICX_SW_8 | VICX_SH_8, VICX_S_ON, 4 * 64, VICX_S_8BIT
        SPRITE 5, 200, 120, VICX_SW_8 | VICX_SH_8, VICX_S_ON, 5 * 64, VICX_S_8BIT

        lda #VICX_CTRL_L0 | VICX_CTRL_SPR | VICX_CTRL_BGTRANS
        sta VICX_CTRL

        VICX_P0_SET VICX_ORDER, VICX_STEP_0
        lda #4
        sta frames
frame:
        ldx #10
        jsr wait_line
        lda #$00
        sta VICX_P0_DATA
        ldx #150                        ; window y 100 on
        jsr wait_line
        lda #1 << VICX_ORDER_L0
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
