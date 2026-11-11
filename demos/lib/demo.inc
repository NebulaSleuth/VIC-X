; demo.inc - start-up and helpers shared by the VIC-X demos
;
; A demo defines `main' and `NEED_XRAM_MB' (0 if it needs no XRAM).  Start-up
; runs with interrupts off, unlocks VIC-X and checks it is there; if not, it
; prints what to do and stops.

.include "vicx.inc"
.include "vicxlib.inc"

.segment "LOADADDR"
        .word $0801

.segment "EXEHDR"
        .word @next
        .word 10                ; 10 SYS 2061
        .byte $9e, "2061", 0
@next:  .word 0

.segment "CODE"
        sei                     ; $080D
        cld
        ldx #$ff
        txs
        lda #$7F                ; CIA interrupts off: the demos poll the raster
        sta $DC0D
        sta $DD0D
        lda $DC0D
        lda $DD0D
        VICX_UNLOCK_SEQ
        lda VICX_ID0
        cmp #$56
        bne @novicx
        lda VICX_ID1
        cmp #$58
        bne @novicx
        lda VICX_CAP_XRAM
        cmp #NEED_XRAM_MB
        bcc @noxram
        jmp main
@novicx:
        ldx #<msg_novicx
        ldy #>msg_novicx
        jmp demo_fail
@noxram:
        ldx #<msg_noxram
        ldy #>msg_noxram
        jmp demo_fail

; Print the zero-terminated string at Y:X with the KERNAL and stop.
demo_fail:
        stx $FB
        sty $FC
        lda #$93                ; clear screen
        jsr $FFD2
        ldy #0
:       lda ($FB),y
        beq :+
        jsr $FFD2
        iny
        bne :-
:       jmp :-

msg_novicx:
        .byte "VIC-X NOT FOUND.", 13, 13
        .byte "RUN X64SC WITH -VICX.", 0
msg_noxram:
        .byte "THIS DEMO NEEDS XRAM: RUN X64SC WITH", 13
        .byte "-REU -REUSIZE 2048 -REUIMAGE <DEMO>.REU", 0

; --- helpers ------------------------------------------------------------

; Wait for the start of raster line X (< 256).
wait_line:
:       cpx $D012
        beq :-
:       cpx $D012
        bne :-
        lda $D011
        bmi :-
        rts

; The CPU-time meter: the border shows `colour' while the demo works.
.macro METER colour
        lda #(colour)
        sta $D020
.endmacro

; Copy `len' bytes from XRAM to the port space (VRAM or registers) with DMA
; descriptor 0, and wait.
.macro XRAM_TO_VRAM xsrc, vdst, len
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM, xsrc, vdst, len, 0, 0, 0, 0, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
.endmacro

; Copy `len' bytes from XRAM to C64 RAM with DMA descriptor 0 (the CPU halts).
.macro XRAM_TO_C64 xsrc, cdst, len
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_XRAM | VICX_DMA_DST_C64, xsrc, cdst, len, 0, 0, 0, 0, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
.endmacro

; Write 16-bit `value' at register-space address `addr' through port 0.
.macro POKE_REG16 addr, value
        POKE16 addr, value
.endmacro

; Print the zero-terminated string at `addr' to screen row `row' (0-24),
; column 0, in screen codes for upper-case letters, digits and spaces.
.macro PRINT_AT row, addr
        .local loop, done
        ldx #0
loop:   lda addr,x
        beq done
        and #$3F
        sta $0400 + (row) * 40,x
        inx
        bne loop
done:
.endmacro
