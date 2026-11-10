; t08_remap - CTRL bit 3 shows VIC-II colours through palette entries 0-15.
;
; Border = colour 0, background = colour 6, then palette entry 0 := FF0000
; (red) and entry 6 := 00FF00 (green) with CTRL bit 3 on.  The screenshot
; taken when VICE exits must show the remapped colours.  The same program
; with VIC-X disabled must show the stock colours, since every VIC-X write
; then lands in a VIC-II mirror.
;
; The remap is applied per frame in step 1, so the program waits two frames
; before it ends.
;
; RUN: -vicx
; PIXEL: 4 4 FF0000
; PIXEL: 192 150 00FF00
; RUN: +vicx
; PIXEL: 4 4 !FF0000
; PIXEL: 192 150 !00FF00

.include "harness.inc"

.code
main:
        ; clear the screen so the sampled background pixel is not text
        lda #$20
        ldx #0
:       sta $0400,x
        sta $0500,x
        sta $0600,x
        sta $06E8,x
        inx
        bne :-

        lda #$00
        sta $D020
        lda #$06
        sta $D021

        VICX_UNLOCK_SEQ
        VICX_P0_SET VICX_PALETTE + 0*4, VICX_STEP_1
        lda #$FF
        sta VICX_P0_DATA
        lda #$00
        sta VICX_P0_DATA
        sta VICX_P0_DATA
        VICX_P0_SET VICX_PALETTE + 6*4, VICX_STEP_1
        lda #$00
        sta VICX_P0_DATA
        lda #$FF
        sta VICX_P0_DATA
        lda #$00
        sta VICX_P0_DATA
        lda #VICX_CTRL_PALMAP
        sta VICX_CTRL
        VICX_LOCK_SEQ                   ; relocking keeps the remap on

        ; with VIC-X disabled the writes above went to VIC-II mirrors;
        ; put the stock colours back so the negative run stays meaningful
        lda #$00
        sta $D020
        lda #$06
        sta $D021

        WAIT_FRAMES 3
        PASS
