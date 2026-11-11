; demo.inc - start-up and helpers shared by the VIC-X demos
;
; A demo defines `main', `NEED_XRAM_MB' (0 if it needs no XRAM) and
; `CPU_TEXT' (where the CPU load readout goes).  Start-up
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
        lda #0
        sta cpu_max
        sta cpu_max + 1
        sta cpu_frames
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

; --- CPU load readout -----------------------------------------------------
; Call cpu_start when the frame's work begins and cpu_end when it is done.
; The raster line counts the time (one frame = 312 lines on PAL, 263 on
; NTSC; the KERNAL notes which at $02A6).  Every 16 frames the busiest of
; them is printed as "CPU nnn%" at screen address CPU_TEXT (defined by the
; demo, 8 characters).  Uses A, X, Y.

; Current raster line -> cpu_line (9 bits)
read_line:
:       lda $D012
        sta cpu_line
        lda $D011
        and #$80
        asl
        rol                             ; bit 8 -> bit 0
        sta cpu_line + 1
        lda $D012
        cmp cpu_line                    ; re-read if the line changed meanwhile
        bne :-
        rts

cpu_start:
        jsr read_line
        lda cpu_line
        sta cpu_t0
        lda cpu_line + 1
        sta cpu_t0 + 1
        rts

cpu_end:
        jsr read_line
        sec                             ; lines = now - start (+ frame if wrapped)
        lda cpu_line
        sbc cpu_t0
        sta cpu_line
        lda cpu_line + 1
        sbc cpu_t0 + 1
        sta cpu_line + 1
        bpl :+
        jsr frame_lines
        clc
        lda cpu_line
        adc cpu_div
        sta cpu_line
        lda cpu_line + 1
        adc cpu_div + 1
        sta cpu_line + 1
:       lda cpu_line + 1                ; keep the highest
        cmp cpu_max + 1
        bcc @nomax
        bne @max
        lda cpu_line
        cmp cpu_max
        bcc @nomax
@max:   lda cpu_line
        sta cpu_max
        lda cpu_line + 1
        sta cpu_max + 1
@nomax: inc cpu_frames
        lda cpu_frames
        and #15
        beq :+
        rts
:       ; percent = max * 100 / frame lines
        lda cpu_max
        sta cpu_num
        lda cpu_max + 1
        sta cpu_num + 1
        asl cpu_num                     ; * 4
        rol cpu_num + 1
        asl cpu_num
        rol cpu_num + 1
        lda cpu_num                     ; keep max * 4
        sta cpu_line
        lda cpu_num + 1
        sta cpu_line + 1
        ldx #3                          ; * 32
:       asl cpu_num
        rol cpu_num + 1
        dex
        bne :-
        clc                             ; max * 32 + max * 4
        lda cpu_num
        adc cpu_line
        sta cpu_line
        lda cpu_num + 1
        adc cpu_line + 1
        sta cpu_line + 1
        asl cpu_num                     ; * 64
        rol cpu_num + 1
        clc                             ; + max * 64 = max * 100
        lda cpu_num
        adc cpu_line
        sta cpu_num
        lda cpu_num + 1
        adc cpu_line + 1
        sta cpu_num + 1
        jsr frame_lines
        lda #0                          ; 16-bit divide: cpu_num / cpu_div
        sta cpu_line
        sta cpu_line + 1
        ldx #16
:       asl cpu_num
        rol cpu_num + 1
        rol cpu_line
        rol cpu_line + 1
        lda cpu_line
        sec
        sbc cpu_div
        tay
        lda cpu_line + 1
        sbc cpu_div + 1
        bcc @skip
        sta cpu_line + 1
        sty cpu_line
        inc cpu_num
@skip:  dex
        bne :-
        ; print "CPU nnn%" (cpu_num < 256)
        ldx #0
:       lda cpu_label,x
        sta CPU_TEXT,x
        inx
        cpx #4
        bne :-
        lda cpu_num
        ldy #0                          ; hundreds
:       cmp #100
        bcc :+
        sbc #100
        iny
        bne :-
:       pha
        tya
        beq :+
        ora #$30
        sta CPU_TEXT,x
        inx
:       pla
        ldy #0                          ; tens
:       cmp #10
        bcc :+
        sbc #10
        iny
        bne :-
:       pha
        tya
        cpx #4                          ; no leading zero
        bne :+
        cmp #0
        beq :++
:       ora #$30
        sta CPU_TEXT,x
        inx
:       pla
        ora #$30
        sta CPU_TEXT,x
        inx
        lda #$25                        ; %
        sta CPU_TEXT,x
        inx
        lda #$20
:       cpx #8
        beq :+
        sta CPU_TEXT,x
        inx
        bne :-
:       lda #0
        sta cpu_max
        sta cpu_max + 1
        rts

; cpu_div = raster lines per frame
frame_lines:
        lda $02A6
        beq :+
        lda #<312
        sta cpu_div
        lda #>312
        sta cpu_div + 1
        rts
:       lda #<263
        sta cpu_div
        lda #>263
        sta cpu_div + 1
        rts

cpu_label: .byte $03, $10, $15, $20     ; "CPU " in screen codes

.pushseg
.bss
cpu_line:   .res 2
cpu_t0:     .res 2
cpu_max:    .res 2
cpu_num:    .res 2
cpu_div:    .res 2
cpu_frames: .res 1
.popseg
