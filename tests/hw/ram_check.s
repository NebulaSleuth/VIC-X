; ram_check - C64 RAM test for a core's memory controller (not a VIC-X test)
;
; Writes an address-dependent pattern (low byte EOR high byte EOR key) to
; all RAM from $0C00 to $FFFF, under the ROMs and I/O too, then reads it
; all back; four keys.  Writing everything before reading catches bytes
; that land at the wrong address or in the wrong half of a 16-bit word.
; Result: PASS, or FAIL 2-5 for the key that failed (assemble with
; -D HW_RESULT to see it on screen).

.include "harness.inc"

ptr = $FB
key = $FD

.code
main:
        ldx #0
pass:   lda keys,x
        sta key
        lda #$34                ; RAM everywhere, no I/O
        sta $01

        lda #0
        sta ptr
        lda #$0C
        sta ptr+1
        ldy #0
wr:     tya
        eor ptr+1
        eor key
        sta (ptr),y
        iny
        bne wr
        inc ptr+1
        bne wr

        lda #$0C
        sta ptr+1
rd:     tya
        eor ptr+1
        eor key
        cmp (ptr),y
        bne bad
        iny
        bne rd
        inc ptr+1
        bne rd

        lda #$37
        sta $01
        inx
        cpx #4
        bne pass
        PASS

bad:    lda #$37
        sta $01
        txa
        clc
        adc #2
.ifdef RESULT_HOOK
        jsr RESULT_HOOK
.endif
        sta DBGCART
        jmp *

keys:   .byte $00, $FF, $55, $A5
