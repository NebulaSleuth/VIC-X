; t28_dma - the DMA engine: fill and copy between C64 RAM, VRAM, the
; register space and XRAM, 2D rectangles, masked copy, chains, busy, the
; DMA-done IRQ bit, a start while busy, length 0, a chain that links back.
;
; Transfers that touch C64 RAM halt the CPU, so DMA_CMD reads not busy
; right after them; transfers that do not run in the background.
;
; RUN: -vicx -reu -reusize 16384

.include "harness.inc"

.code
main:
        VICX_UNLOCK_SEQ

        ; C64 RAM: $3000 = 0..255, $3200-$34FF = 0
        ldx #0
:       txa
        sta $3000,x
        lda #0
        sta $3200,x
        sta $3300,x
        sta $3400,x
        inx
        bne :-
        VICX_P0_SET $00000, VICX_STEP_1
        lda #0
        P0_FILL 1024
        VICX_P0_SET $02000, VICX_STEP_1
        lda #$11
        P0_FILL 768
        VICX_P0_SET $03000, VICX_STEP_1
        lda #0
        P0_FILL 768

        ; 1. background fill of VRAM: busy while it runs
        DMA_DESC 0, VICX_DMA_FILL, VICX_DMA_DST_VRAM, 0, $00000, 1000, 0, 0, 0, $5A, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        lda VICX_DMA_CMD
        and #VICX_DMA_BUSY
        EXPECT_A VICX_DMA_BUSY, 2
        DMA_WAIT
        PEEK_AT $00000
        EXPECT_A $5A, 3
        PEEK_AT 999
        EXPECT_A $5A, 4
        PEEK_AT 1000
        EXPECT_A $00, 5

        ; 2. C64 RAM to VRAM: the CPU waits, so it never sees busy
        DMA_DESC 1, VICX_DMA_COPY, VICX_DMA_SRC_C64 | VICX_DMA_DST_VRAM, $3000, $01000, 256, 0, 0, 0, 0, 0, VICX_DMA_NONE
        lda #1
        sta VICX_DMA_CMD
        lda VICX_DMA_CMD
        EXPECT_A $00, 6
        PEEK_AT $010FF
        EXPECT_A $FF, 7
        PEEK_AT $01080
        EXPECT_A $80, 8

        ; 3. a chain: VRAM -> XRAM (descriptor 2), then XRAM -> C64 RAM (3)
        DMA_DESC 2, VICX_DMA_COPY, VICX_DMA_SRC_VRAM | VICX_DMA_DST_XRAM, $01000, $123456, 256, 0, 0, 0, 0, 0, 3
        DMA_DESC 3, VICX_DMA_COPY, VICX_DMA_SRC_XRAM | VICX_DMA_DST_C64, $123456, $3200, 256, 0, 0, 0, 0, 0, VICX_DMA_NONE
        lda #2
        sta VICX_DMA_CMD
        DMA_WAIT
        EXPECT $3280, $80, 9
        EXPECT $32FF, $FF, 10

        ; 4. masked 2D copy: 4x3 bytes from C64 RAM into VRAM rows 320 apart;
        ;    source bytes 0 are skipped
        DMA_DESC 0, VICX_DMA_MASKED, VICX_DMA_SRC_C64 | VICX_DMA_DST_VRAM | VICX_DMA_2D, block, $02000, 4, 3, 4, 320, 0, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        PEEK_AT $02000
        EXPECT_A $01, 11
        PEEK_AT $02001
        EXPECT_A $11, 12
        PEEK_AT $02000 + 320 + 3
        EXPECT_A $14, 13
        PEEK_AT $02000 + 640 + 2
        EXPECT_A $23, 14
        PEEK_AT $02004
        EXPECT_A $11, 15

        ; 5. 2D fill: 3 bytes x 2 rows
        DMA_DESC 1, VICX_DMA_FILL, VICX_DMA_DST_VRAM | VICX_DMA_2D, 0, $03000, 3, 2, 0, 320, $77, 0, VICX_DMA_NONE
        lda #1
        sta VICX_DMA_CMD
        DMA_WAIT
        PEEK_AT $03000
        EXPECT_A $77, 16
        PEEK_AT $03000 + 320 + 2
        EXPECT_A $77, 17
        PEEK_AT $03003
        EXPECT_A $00, 18
        PEEK_AT $03000 + 640
        EXPECT_A $00, 19

        ; 6. into the register space: palette entry 40
        DMA_DESC 2, VICX_DMA_COPY, VICX_DMA_SRC_C64 | VICX_DMA_DST_VRAM, palsrc, VICX_PALETTE + 40 * 4, 3, 0, 0, 0, 0, 0, VICX_DMA_NONE
        lda #2
        sta VICX_DMA_CMD
        PEEK_AT VICX_PALETTE + 40 * 4
        EXPECT_A $12, 20
        PEEK_AT VICX_PALETTE + 40 * 4 + 2
        EXPECT_A $56, 21

        ; 7. IRQ_STAT bit 1 is raised when the transfer ends, not before
        lda #VICX_IRQ_DMA
        sta VICX_IRQ_STAT
        DMA_DESC 0, VICX_DMA_FILL, VICX_DMA_DST_XRAM | VICX_DMA_IRQ, 0, $200000, 4000, 0, 0, 0, $33, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        lda VICX_IRQ_STAT
        and #VICX_IRQ_DMA
        EXPECT_A $00, 22
        DMA_WAIT
        lda VICX_IRQ_STAT
        and #VICX_IRQ_DMA
        EXPECT_A VICX_IRQ_DMA, 23

        ; 8. a start while busy is ignored
        DMA_DESC 0, VICX_DMA_FILL, VICX_DMA_DST_VRAM, 0, $05000, 60000, 0, 0, 0, $00, 0, VICX_DMA_NONE
        DMA_DESC 3, VICX_DMA_FILL, VICX_DMA_DST_C64, 0, $3400, 1, 0, 0, 0, $99, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        lda #3
        sta VICX_DMA_CMD
        DMA_WAIT
        EXPECT $3400, $00, 24
        lda #3
        sta VICX_DMA_CMD
        EXPECT $3400, $99, 25

        ; 9. a chain that links back to itself runs once and ends
        DMA_DESC 3, VICX_DMA_FILL, VICX_DMA_DST_C64, 0, $3401, 1, 0, 0, 0, $42, 0, 3
        lda #3
        sta VICX_DMA_CMD
        DMA_WAIT
        EXPECT $3401, $42, 26

        ; 10. length 0 moves nothing
        DMA_DESC 1, VICX_DMA_FILL, VICX_DMA_DST_C64, 0, $3402, 0, 0, 0, 0, $55, 0, VICX_DMA_NONE
        lda #1
        sta VICX_DMA_CMD
        DMA_WAIT
        EXPECT $3402, $00, 27

        PASS

.rodata
block:  .byte $01, $00, $03, $04
        .byte $11, $00, $13, $14
        .byte $21, $00, $23, $24
palsrc: .byte $12, $34, $56
