; t29_palette_split - palette writes show at once, mid-frame.
;
; Background = colour 6, remapped (CTRL bit 3) to palette entry 6.  Each
; frame the program sets entry 6 to red when the raster reaches line 100 and
; back to green at line 200, so the background is green above line 100, red
; between the two lines and green again below.  The spec says palette
; writes are immediate; VICE used to apply them only at the next frame.
;
; Screenshot y = raster line - 16 (PAL, 384x272): line 100 is y 84, line 200
; is y 184.  Points are taken well away from the lines where the writes land.
;
; RUN: -vicx
; PIXEL: 192 60 00FF00
; PIXEL: 192 130 FF0000
; PIXEL: 192 210 00FF00
; RUN: +vicx
; PIXEL: 192 130 !FF0000
; PIXEL: 192 60 !00FF00

.include "harness.inc"

.code
main:
        CLEAR_SCREEN
        lda #$00
        sta $D020
        lda #$06
        sta $D021

        VICX_UNLOCK_SEQ
        SET_PAL 6, $00, $FF, $00
        lda #VICX_CTRL_PALMAP
        sta VICX_CTRL

        sei
        ldx #4                          ; four frames of splits
frame:
        lda #100
:       cmp $D012
        bne :-
        VICX_P0_SET VICX_PALETTE + 6*4, VICX_STEP_1
        lda #$FF
        sta VICX_P0_DATA
        lda #$00
        sta VICX_P0_DATA
        sta VICX_P0_DATA

        lda #200
:       cmp $D012
        bne :-
        VICX_P0_SET VICX_PALETTE + 6*4, VICX_STEP_1
        lda #$00
        sta VICX_P0_DATA
        lda #$FF
        sta VICX_P0_DATA
        lda #$00
        sta VICX_P0_DATA

        dex
.ifdef HW_RESULT
        ; on hardware the screenshot comes long after the end: show PASS,
        ; then keep splitting so the screenshot catches the bands
        bne frame
        lda #0
        jsr hw_result
        ldx #1
        jmp frame
.else
        bne frame
.endif
        cli

        ; with VIC-X disabled the writes above went to VIC-II mirrors
        lda #$00
        sta $D020
        lda #$06
        sta $D021
        PASS
