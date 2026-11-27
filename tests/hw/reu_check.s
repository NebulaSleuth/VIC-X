; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; reu_check - REU test for a core's memory controller (not a VIC-X test)
;
; Needs a 16 MB REU.  Stashes a different 4 KB pattern into each of six
; banks spread over 16 MB (at the odd address $x:1231), then fetches each
; back and compares, so banks that alias each other or bytes in the wrong
; half of a word show up.
; Result: PASS; FAIL 02 = no REU; FAIL 03-08 = the bank in the list that
; came back wrong.

.include "harness.inc"

REU_CMD  = $DF01
REU_C64  = $DF02
REU_ADDR = $DF04
REU_LEN  = $DF07
REU_CTRL = $DF0A

ptr  = $FB
bank = $FD
idx  = $FE

NBANKS = 6

.code
main:
        ; an REU's address registers hold what is written
        lda #$5A
        sta REU_C64
        lda #$A5
        sta REU_C64+1
        lda REU_C64
        cmp #$5A
        bne noreu
        lda REU_C64+1
        cmp #$A5
        beq found
noreu:  FAIL 2

found:  lda #0
        sta REU_CTRL            ; both addresses count up
        sta $DF09               ; no REU IRQs

        ; stash a pattern into each bank
        ldx #0
st:     stx idx
        lda banks,x
        sta bank
        lda #$20
        jsr fill
        lda #$20
        jsr setup
        lda #$90                ; execute, no $FF00 trigger, C64 -> REU
        sta REU_CMD
        ldx idx
        inx
        cpx #NBANKS
        bne st

        ; fetch each back into $3000 and compare
        ldx #0
ft:     stx idx
        lda banks,x
        sta bank
        ldy #0                  ; clear $3000-$3FFF first
        lda #$30
        sta ptr+1
        sty ptr
        tya
clr:    sta (ptr),y
        iny
        bne clr
        inc ptr+1
        ldx ptr+1
        cpx #$40
        bne clr
        lda #$30
        jsr setup
        lda #$91                ; execute, no $FF00 trigger, REU -> C64
        sta REU_CMD
        lda #$30
        sta ptr+1
        ldy #0
cmp1:   tya
        eor ptr+1
        eor bank
        eor #$10                ; buffer page $3x vs $2x when written
        cmp (ptr),y
        bne bad
        iny
        bne cmp1
        inc ptr+1
        lda ptr+1
        cmp #$40
        bne cmp1
        ldx idx
        inx
        cpx #NBANKS
        bne ft
        PASS

bad:    lda idx
        clc
        adc #3
.ifdef RESULT_HOOK
        jsr RESULT_HOOK
.endif
        sta DBGCART
        jmp *

; fill 4 KB from page A with (low byte EOR page EOR bank)
fill:   sta ptr+1
        clc
        adc #$10
        sta endp
        lda #0
        sta ptr
        ldy #0
fl:     tya
        eor ptr+1
        eor bank
        sta (ptr),y
        iny
        bne fl
        inc ptr+1
        lda ptr+1
        cmp endp
        bne fl
        rts
endp:   .byte 0

; REU transfer of 4 KB between C64 page A and bank:$1231
setup:  sta REU_C64+1
        lda #0
        sta REU_C64
        lda #$31
        sta REU_ADDR
        lda #$12
        sta REU_ADDR+1
        lda bank
        sta REU_ADDR+2
        lda #$00
        sta REU_LEN
        lda #$10
        sta REU_LEN+1
        rts

banks:  .byte $00, $01, $1F, $20, $80, $FF
