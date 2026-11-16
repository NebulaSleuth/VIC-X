; t11_split - CTRL and the layer setup are latched at the start of each
; raster line, so raster splits work like VIC-II register splits.
;
; Two bitmaps: A at $00000 (all colour 32, blue) and B at $10000 (all
; colour 36, green).  Every frame:
;   line  10: base = A, CTRL = layer 0 + background transparent
;   line 120: base = B (one write of base byte +4)
;   line 180: CTRL = layer 0 only (the VIC-II background hides the layer)
; A write during line L takes effect from line L+1.  Window y = line - 51,
; screenshot y = line - 16.  Background $D021 = black.
;
; RUN: -vicx
; PIXEL: 100 35 0000FF
; PIXEL: 100 104 0000FF
; PIXEL: 100 105 00FF00
; PIXEL: 100 164 00FF00
; PIXEL: 100 165 000000
; PIXEL: 100 234 000000

.include "harness.inc"

.code
main:
        CLEAR_SCREEN
        lda #$00
        sta $D020
        sta $D021

        VICX_UNLOCK_SEQ
        SET_PAL 32, $00, $00, $FF
        SET_PAL 36, $00, $FF, $00
        VICX_P0_SET $00000, VICX_STEP_1
        lda #32
        P0_FILL 64000
        VICX_P0_SET $10000, VICX_STEP_1
        lda #36
        P0_FILL 64000

        ; layer 0: 8-bit bitmap at $00000, stride 320
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

        ; port 0 stays on the base high byte for the splits
        VICX_P0_SET VICX_LAYER0 + 4, VICX_STEP_0

        lda #4
        sta frames
frame:
        ldx #10
        jsr wait_line
        lda #$00
        sta VICX_P0_DATA                ; base = $00000
        lda #VICX_CTRL_L0 | VICX_CTRL_BGTRANS
        sta VICX_CTRL

        ldx #120
        jsr wait_line
        lda #$01
        sta VICX_P0_DATA                ; base = $10000

        ldx #180
        jsr wait_line
        lda #VICX_CTRL_L0
        sta VICX_CTRL

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

; wait for the start of raster line X (< 256)
wait_line:
:       cpx $D012                       ; leave the line if we are in it
        beq :-
:       cpx $D012
        bne :-
        lda $D011
        bmi :-
        rts

.bss
frames: .res 1
