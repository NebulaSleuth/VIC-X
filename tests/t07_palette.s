; t07_palette - palette register space after reset: entries 0-15 hold the
; C64 palette (black is dark, white is bright), entries 16-255 are 0, and
; entries read back what was written.
;
; The exact RGB of entries 0-15 depends on the emulator's palette settings
; (the counterpart of the Ultimate menu's palette choice), so this test only
; checks their shape; t06_reset checks they come back after a reset.
;
; RUN: -vicx

.include "harness.inc"

.code
main:
        VICX_UNLOCK_SEQ

        ; entry 0 (black): R, G, B all below $30
        VICX_P0_SET VICX_PALETTE + 0*4, VICX_STEP_1
        ldx #3
:       lda VICX_P0_DATA
        cmp #$30
        bcc :+
        FAIL 2
:       dex
        bne :--
        EXPECT VICX_P0_DATA, $00, 3      ; spare byte

        ; entry 1 (white): R, G, B all at least $C0
        ldx #3
:       lda VICX_P0_DATA
        cmp #$C0
        bcs :+
        FAIL 4
:       dex
        bne :--

        ; entry 2 (red): R > G and R > B
        VICX_P0_SET VICX_PALETTE + 2*4, VICX_STEP_1
        lda VICX_P0_DATA
        sta tmp
        lda VICX_P0_DATA
        cmp tmp
        bcc :+
        FAIL 5
:       lda VICX_P0_DATA
        cmp tmp
        bcc :+
        FAIL 6
:

        ; entries 16-255 are 0 (960 bytes from $20040)
        VICX_P0_SET VICX_PALETTE + 16*4, VICX_STEP_1
        ldy #>(240*4 - 1)               ; Y:X counts 959 down to 0, -1 ends
        ldx #<(240*4 - 1)
@zero:  lda VICX_P0_DATA
        beq :+
        FAIL 7
:       dex
        cpx #$FF
        bne @zero
        dey
        bpl @zero

        ; write all 256 entries with a pattern, read them back with step 4
        VICX_P0_SET VICX_PALETTE, VICX_STEP_1
        ldx #0
@wr:    txa
        sta VICX_P0_DATA                ; R = n
        eor #$FF
        sta VICX_P0_DATA                ; G = ~n
        txa
        asl
        sta VICX_P0_DATA                ; B = n*2
        lda #$E5
        sta VICX_P0_DATA                ; spare
        inx
        bne @wr

        VICX_P0_SET VICX_PALETTE + 1, VICX_STEP_4   ; every G byte
        ldx #0
@rd:    txa
        eor #$FF
        cmp VICX_P0_DATA
        beq :+
        FAIL 8
:       inx
        bne @rd
        VICX_P0_SET VICX_PALETTE + 255*4 + 2, VICX_STEP_4 | VICX_STEP_BACK  ; B, backwards
        ldx #255
@rdb:   txa
        asl
        cmp VICX_P0_DATA
        beq :+
        FAIL 9
:       dex
        cpx #$FF
        bne @rdb

        VICX_LOCK_SEQ
        PASS

.bss
tmp:    .res 1
