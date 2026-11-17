; dma_bench - how fast the DMA engine runs on the hardware, with the
; layers off and with a bitmap layer fetching.  Not a conformance test.
;
; Each case starts at raster line 0 and prints the raster lines it took
; (decimal; PAL has 312 a frame).  Needs XRAM (the REU) for the XRAM cases.
;
;   A  XRAM -> VRAM, 64000 bytes, 1D            layers off
;   B  XRAM -> VRAM, 320 x 200, 2D              layers off
;   C  fill VRAM, 64000 bytes                   layers off
;   D  VRAM -> VRAM, 64000 bytes, 1D            layers off
;   E  XRAM -> VRAM, 164 x 115, 2D, stride 320  layers off
;   F  XRAM -> VRAM, 64000 bytes, 1D            8-bit bitmap layer on
;   G  fill VRAM, 64000 bytes                   8-bit bitmap layer on
;   H  XRAM -> VRAM, 320 x 200, 2D              8-bit bitmap layer on

.include "harness.inc"

f0   = $FB
lnl  = $FC
lnh  = $FD
sp   = $FE                      ; screen pointer, 2 bytes ($FE-$FF)
num  = $F7                      ; 2 bytes
t0   = $F9

.code
main:
        VICX_UNLOCK_SEQ
        lda #0
        sta VICX_CTRL
        lda #$1B
        sta $D011
        lda #$15                ; upper case set
        sta $D018
        ldx #0
:       lda #$20
        sta $0400,x
        sta $0500,x
        sta $0600,x
        sta $06E8,x
        lda #1
        sta $D800,x
        sta $D900,x
        sta $DA00,x
        sta $DAE8,x
        inx
        bne :-
        lda #<($0400 + 40)
        sta sp
        lda #>($0400 + 40)
        sta sp + 1
        lda #$01                ; "A"
        sta label

        ; the layer the cases with the layer on show: VRAM $10000, 8-bit
        LAYER_SET VICX_LAYER0, VICX_LMODE_BITMAP8, 0, $10000, 0, 0, 0, 320, 0

        ; layers off
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM, $000000, $00000, 64000, 0, 0, 0, 0, 0, VICX_DMA_NONE
        jsr run
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM | VICX_DMA_2D, $000000, $00000, 320, 200, 320, 320, 0, 0, VICX_DMA_NONE
        jsr run
        DMA_DESC 0, VICX_DMA_FILL, VICX_DMA_DST_VRAM, 0, $00000, 64000, 0, 0, 0, $55, 0, VICX_DMA_NONE
        jsr run
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM, $10000, $00000, 64000, 0, 0, 0, 0, 0, VICX_DMA_NONE
        jsr run
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM | VICX_DMA_2D, $000000, $00000, 164, 115, 320, 320, 0, 0, VICX_DMA_NONE
        jsr run

        ; bitmap layer 0 on
        lda #VICX_CTRL_L0
        sta VICX_CTRL
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM, $000000, $00000, 64000, 0, 0, 0, 0, 0, VICX_DMA_NONE
        jsr run
        DMA_DESC 0, VICX_DMA_FILL, VICX_DMA_DST_VRAM, 0, $00000, 64000, 0, 0, 0, $55, 0, VICX_DMA_NONE
        jsr run
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM | VICX_DMA_2D, $000000, $00000, 320, 200, 320, 320, 0, 0, VICX_DMA_NONE
        jsr run
        lda #0
        sta VICX_CTRL
        lda #5                  ; done: green border
        sta $D020
:       jmp :-

; Run descriptor 0 from raster line 0, print "x nnnnn" (lines taken).
run:
        lda VICX_FRAME          ; wait for the next frame (line 0)
:       cmp VICX_FRAME
        beq :-
        lda VICX_FRAME
        sta f0
        lda #0
        sta VICX_DMA_CMD
:       lda VICX_DMA_CMD
        bmi :-
        ; frame and line now
:       lda $D012
        sta lnl
        lda $D011
        and #$80
        asl
        rol
        sta lnh
        lda $D012
        cmp lnl
        bne :-
        lda VICX_FRAME
        sec
        sbc f0                  ; frames passed
        tax
:       cpx #0
        beq :+
        clc
        lda lnl
        adc #<312
        sta lnl
        lda lnh
        adc #>312
        sta lnh
        dex
        jmp :-
:       lda lnl
        sta num
        lda lnh
        sta num + 1
        ; print
        ldy #0
        lda label
        sta (sp),y
        inc label
        ldy #2
        ldx #4
@dig:   lda #0
        sta t0
@sub:   lda num
        sec
        sbc pow_lo,x
        pha
        lda num + 1
        sbc pow_hi,x
        bcc @nd
        sta num + 1
        pla
        sta num
        inc t0
        bne @sub
@nd:    pla
        lda t0
        ora #$30
        sta (sp),y
        iny
        dex
        bpl @dig
        clc
        lda sp
        adc #40
        sta sp
        bcc :+
        inc sp + 1
:       rts

pow_lo: .byte <1, <10, <100, <1000, <10000
pow_hi: .byte >1, >10, >100, >1000, >10000

.bss
label:  .res 1
