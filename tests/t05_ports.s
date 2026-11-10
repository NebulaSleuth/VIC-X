; t05_ports - VRAM ports 0 and 1: address registers, all 16 step codes in
; both directions, 18-bit wrap, data round trips through VRAM and the
; register space, and unmapped port space.
;
; RUN: -vicx

.include "harness.inc"

.code
main:
        VICX_UNLOCK_SEQ

        ; --- address registers read back; bit 2 of ADDRH reads 0 ----------
        lda #$12
        sta VICX_P0_ADDRL
        lda #$34
        sta VICX_P0_ADDRM
        lda #$AF                        ; step bits $A8, address bits 16-17 = 3
        sta VICX_P0_ADDRH
        EXPECT VICX_P0_ADDRL, $12, 2
        EXPECT VICX_P0_ADDRM, $34, 3
        EXPECT VICX_P0_ADDRH, $AB, 4

        ; --- every step code, forwards and backwards from $10000 ---------
        ldx #0                          ; step index 0-15
@steps:
        lda #$00
        sta VICX_P0_ADDRL
        sta VICX_P0_ADDRM
        txa
        asl
        asl
        asl
        ora #$01                        ; address bit 16
        sta VICX_P0_ADDRH
        sta stepcode
        lda #$AA
        sta VICX_P0_DATA                ; a write steps
        lda VICX_P0_ADDRL
        cmp fwd_lo,x
        beq :+
        FAIL 5
:       lda VICX_P0_ADDRM
        cmp fwd_hi,x
        beq :+
        FAIL 6
:       lda VICX_P0_ADDRH               ; bit 16 still set, step bits unchanged
        cmp stepcode
        beq :+
        FAIL 7
:       lda #$00
        sta VICX_P0_ADDRL
        sta VICX_P0_ADDRM
        lda stepcode
        ora #VICX_STEP_BACK
        sta VICX_P0_ADDRH
        lda VICX_P0_DATA                ; a read steps too
        lda VICX_P0_ADDRL
        cmp bwd_lo,x
        beq :+
        FAIL 8
:       lda VICX_P0_ADDRM
        cmp bwd_hi,x
        beq :+
        FAIL 9
:       lda VICX_P0_ADDRH
        and #$03
        cmp bwd_bank,x
        beq :+
        FAIL 10
:       inx
        cpx #16
        beq @stepsdone
        jmp @steps
@stepsdone:

        ; --- 18-bit wrap ---------------------------------------------------
        VICX_P0_SET $3FFFF, VICX_STEP_1
        lda #$00
        sta VICX_P0_DATA                ; $3FFFF is unmapped: write ignored
        EXPECT VICX_P0_ADDRL, $00, 11
        EXPECT VICX_P0_ADDRM, $00, 12
        EXPECT VICX_P0_ADDRH, VICX_STEP_1, 13
        VICX_P0_SET $00000, VICX_STEP_2 | VICX_STEP_BACK
        lda VICX_P0_DATA
        EXPECT VICX_P0_ADDRL, $FE, 14
        EXPECT VICX_P0_ADDRM, $FF, 15
        EXPECT VICX_P0_ADDRH, VICX_STEP_2 | VICX_STEP_BACK | $03, 16

        ; --- data round trip at the top of VRAM, step 1 --------------------
        VICX_P0_SET $1FFF0, VICX_STEP_1
        ldx #0
:       txa
        eor #$5A
        sta VICX_P0_DATA
        inx
        cpx #16
        bne :-
        VICX_P0_SET $1FFF0, VICX_STEP_1
        ldx #0
@rt:    txa
        eor #$5A
        cmp VICX_P0_DATA
        beq :+
        FAIL 17
:       inx
        cpx #16
        bne @rt

        ; --- step 40 walks a column; port 1 reads what port 0 wrote ------
        VICX_P0_SET $00100, VICX_STEP_40
        lda #$11
        sta VICX_P0_DATA
        lda #$22
        sta VICX_P0_DATA
        lda #$33
        sta VICX_P0_DATA
        lda #<$00100
        sta VICX_P1_ADDRL
        lda #>$00100
        sta VICX_P1_ADDRM
        lda #VICX_STEP_40
        sta VICX_P1_ADDRH
        EXPECT VICX_P1_DATA, $11, 18
        EXPECT VICX_P1_DATA, $22, 19
        EXPECT VICX_P1_DATA, $33, 20
        EXPECT VICX_P1_ADDRL, <($00100 + 3*40), 21
        EXPECT VICX_P0_ADDRL, <($00100 + 3*40), 22  ; port 0 moved on its own
        ; step 0 stays put
        lda #<$00128
        sta VICX_P1_ADDRL
        lda #VICX_STEP_0
        sta VICX_P1_ADDRH
        EXPECT VICX_P1_DATA, $22, 23
        EXPECT VICX_P1_DATA, $22, 24
        EXPECT VICX_P1_ADDRL, <$00128, 25

        ; --- register space: palette entry 255 incl. the spare byte -------
        VICX_P0_SET $203FC, VICX_STEP_1
        lda #$C1
        sta VICX_P0_DATA
        lda #$C2
        sta VICX_P0_DATA
        lda #$C3
        sta VICX_P0_DATA
        lda #$C4
        sta VICX_P0_DATA
        VICX_P0_SET $203FC, VICX_STEP_1
        EXPECT VICX_P0_DATA, $C1, 26
        EXPECT VICX_P0_DATA, $C2, 27
        EXPECT VICX_P0_DATA, $C3, 28
        EXPECT VICX_P0_DATA, $C4, 29

        ; last register-space byte $209FF holds data; $20A00 up is unmapped
        VICX_P0_SET $209FF, VICX_STEP_0
        lda #$77
        sta VICX_P0_DATA
        EXPECT VICX_P0_DATA, $77, 30
        VICX_P0_SET $20A00, VICX_STEP_0
        lda #$77
        sta VICX_P0_DATA
        EXPECT VICX_P0_DATA, $FF, 31
        VICX_P0_SET $3FFFF, VICX_STEP_0
        EXPECT VICX_P0_DATA, $FF, 32

        VICX_LOCK_SEQ
        PASS

.rodata
; expected address after one access from $10000, per step index
.define FWD $10000+0, $10000+1, $10000+2, $10000+4, $10000+8, $10000+16, $10000+32, $10000+40, $10000+64, $10000+80, $10000+128, $10000+160, $10000+256, $10000+320, $10000+512, $10000+640
.define BWD $10000-0, $10000-1, $10000-2, $10000-4, $10000-8, $10000-16, $10000-32, $10000-40, $10000-64, $10000-80, $10000-128, $10000-160, $10000-256, $10000-320, $10000-512, $10000-640
fwd_lo:   .lobytes FWD
fwd_hi:   .hibytes FWD
bwd_lo:   .lobytes BWD
bwd_hi:   .hibytes BWD
bwd_bank: .byte 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

.bss
stepcode: .res 1
