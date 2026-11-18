; t31_expand - the blitter's optional expand and masked expand (operations
; 3 and 4), and CAP_BLIT.  Skipped (PASS with nothing checked) on a build
; whose CAP_BLIT lacks bit 0.  Also: a descriptor with a direction bit, and
; DMA_CMD with bit 2, do nothing on a build without them.
;
; Source bits: $A5 $0F $81 = 10100101 00001111 10000001.
;
; RUN: -vicx -reu -reusize 16384

.include "harness.inc"

.code
main:
        VICX_UNLOCK_SEQ

        lda VICX_CAP_BLIT
        and #VICX_BLIT_EXPAND
        bne :+
        PASS
:
        ; VRAM $00000-$003FF = 0; the source bytes at $03000
        VICX_P0_SET $00000, VICX_STEP_1
        lda #0
        P0_FILL 1024
        VICX_P0_SET $03000, VICX_STEP_1
        lda #$A5
        sta VICX_P0_DATA
        lda #$0F
        sta VICX_P0_DATA
        lda #$81
        sta VICX_P0_DATA
        ; C64 RAM $3010: two rows of one byte
        lda #$F0
        sta $3010
        lda #$0F
        sta $3011

        ; 1. expand, VRAM to VRAM, 20 pixels: 1 = fill $77, 0 = transparent $11
        DMA_DESC 0, VICX_DMA_EXPAND, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM, $03000, $00000, 20, 0, 0, 0, $77, $11, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        lda #0                          ; port 1 reads them back
        sta VICX_P1_ADDRL
        sta VICX_P1_ADDRM
        lda #VICX_STEP_1
        sta VICX_P1_ADDRH
        ldx #0
c1:    lda VICX_P1_DATA
        cmp want1,x
        beq :+
        txa
        clc
        adc #10                         ; codes 10-30: pixel n wrong
  .ifdef RESULT_HOOK
        jsr RESULT_HOOK
  .endif
        sta DBGCART
        jmp *
:       inx
        cpx #21
        bne c1

        ; 2. masked expand over zeros at $00100: 0 bits leave the byte
        DMA_DESC 0, VICX_DMA_EXPAND_MASKED, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM, $03000, $00100, 8, 0, 0, 0, $77, $11, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        PEEK_AT $00100
        EXPECT_A $77, 40
        PEEK_AT $00101
        EXPECT_A $00, 41
        PEEK_AT $00102
        EXPECT_A $77, 42
        PEEK_AT $00105
        EXPECT_A $77, 43
        PEEK_AT $00106
        EXPECT_A $00, 44
        PEEK_AT $00108
        EXPECT_A $00, 45

        ; 3. 2D from C64 RAM: rows of one source byte, 8 pixels, stride 16
        DMA_DESC 0, VICX_DMA_EXPAND, VICX_DMA_SRC_C64 | VICX_DMA_DST_VRAM | VICX_DMA_2D, $3010, $00200, 8, 2, 1, 16, $22, $33, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        PEEK_AT $00200
        EXPECT_A $22, 50
        PEEK_AT $00203
        EXPECT_A $22, 51
        PEEK_AT $00204
        EXPECT_A $33, 52
        PEEK_AT $00207
        EXPECT_A $33, 53
        PEEK_AT $00208
        EXPECT_A $00, 54
        PEEK_AT $00210
        EXPECT_A $33, 55
        PEEK_AT $00214
        EXPECT_A $22, 56
        PEEK_AT $00217
        EXPECT_A $22, 57

        ; 4. a direction bit on a build without them: nothing happens
        lda VICX_CAP_BLIT
        and #VICX_BLIT_DIRECTION
        beq :+
        jmp dir_done
:
        DMA_DESC 0, VICX_DMA_FILL, VICX_DMA_DST_VRAM | VICX_DMA_MIRROR, 0, $00300, 4, 0, 0, 0, $99, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        PEEK_AT $00300
        EXPECT_A $00, 60
dir_done:

        ; 5. DMA_CMD bit 2 on a build without lists: nothing starts
        lda VICX_CAP_BLIT
        and #VICX_BLIT_LIST
        beq :+
        jmp list_done
:
        DMA_DESC 0, VICX_DMA_FILL, VICX_DMA_DST_VRAM, 0, $00300, 4, 0, 0, 0, $99, 0, VICX_DMA_NONE
        lda #VICX_DMA_LIST
        sta VICX_DMA_CMD
        DMA_WAIT
        PEEK_AT $00300
        EXPECT_A $00, 61
list_done:
        PASS

want1: .byte $77, $11, $77, $11, $11, $77, $11, $77
        .byte $11, $11, $11, $11, $77, $77, $77, $77
        .byte $77, $11, $11, $11
        .byte $00                       ; byte 20 untouched
