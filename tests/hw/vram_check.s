; vram_check - all of VRAM through the ports, for an FPGA build whose VRAM
; is external memory (the MiSTer's SDRAM).  Not a conformance test: it
; checks the memory path, not the spec.
;
;   02  port 0 writes all 128 KB, port 1 reads it back forwards
;   03  port 1 reads it back backwards (step 1, backwards)
;   04  port 1 with step 640, read back to back four cycles apart, so every
;       read needs a new 8-byte block from memory
;   05  port 0 writes, port 1 at the same address reads it the next
;       instruction (the write must reach port 1's copy)
;
; Byte at address hi:mid:lo holds lo EOR mid EOR (hi ? $A7 : 0).
; Takes about 10 seconds.

.include "harness.inc"

pg   = $FB                      ; middle address byte
hk   = $FC                      ; $A7 in the upper 64 KB, else 0
buf  = $0340

.code
main:
        VICX_UNLOCK_SEQ

        ; --- 02: write all of VRAM through port 0, read through port 1 ---
        VICX_P0_SET 0, VICX_STEP_1
        lda #0
        sta hk
w_bank: lda #0
        sta pg
w_page: ldy #0
w_byte: tya
        eor pg
        eor hk
        sta VICX_P0_DATA
        iny
        bne w_byte
        inc pg
        bne w_page
        lda hk
        bne w_done
        lda #$A7
        sta hk
        bne w_bank
w_done:

        lda #0
        sta VICX_P1_ADDRL
        sta VICX_P1_ADDRM
        lda #VICX_STEP_1
        sta VICX_P1_ADDRH
        lda #0
        sta hk
r_bank: lda #0
        sta pg
r_page: ldy #0
r_byte: tya
        eor pg
        eor hk
        cmp VICX_P1_DATA
        bne fail2
        iny
        bne r_byte
        inc pg
        bne r_page
        lda hk
        bne r_done
        lda #$A7
        sta hk
        bne r_bank
fail2:  FAIL 2
r_done:

        ; --- 03: backwards from $1FFFF ---
        lda #$FF
        sta VICX_P1_ADDRL
        sta VICX_P1_ADDRM
        lda #VICX_STEP_1 | VICX_STEP_BACK | 1
        sta VICX_P1_ADDRH
        lda #$A7
        sta hk
b_bank: lda #$FF
        sta pg
b_page: ldy #$FF
b_byte: tya
        eor pg
        eor hk
        cmp VICX_P1_DATA
        bne fail3
        dey
        cpy #$FF
        bne b_byte
        dec pg
        lda pg
        cmp #$FF
        bne b_page
        lda hk
        beq b_done
        lda #0
        sta hk
        beq b_bank
fail3:  FAIL 3
b_done:

        ; --- 04: step 640, reads four cycles apart ---
        lda #0
        sta VICX_P1_ADDRL
        sta VICX_P1_ADDRM
        lda #VICX_STEP_640
        sta VICX_P1_ADDRH
.repeat 5, G
        lda VICX_P1_DATA
        ldx VICX_P1_DATA
        ldy VICX_P1_DATA
        sta buf + G * 3
        stx buf + G * 3 + 1
        sty buf + G * 3 + 2
.endrepeat
        lda VICX_P1_DATA
        sta buf + 15
        ldx #15
s_cmp:  lda buf,x
        cmp s_want,x
        bne fail4
        dex
        bpl s_cmp
        jmp s_done
fail4:  FAIL 4
s_done:

        ; --- 05: write through port 0, read the same address through port 1 ---
        VICX_P0_SET $10000, VICX_STEP_1
        lda #0
        sta VICX_P1_ADDRL
        sta VICX_P1_ADDRM
        lda #VICX_STEP_1 | 1
        sta VICX_P1_ADDRH
        ldy #0
x_byte: tya
        eor #$5C
        sta VICX_P0_DATA
        cmp VICX_P1_DATA
        bne fail5
        iny
        bne x_byte
        PASS
fail5:  FAIL 5

; bytes at k * 640, k = 0..15 (all in the lower 64 KB)
s_want:
.repeat 16, K
        .byte <(K * 640) ^ >(K * 640)
.endrepeat
