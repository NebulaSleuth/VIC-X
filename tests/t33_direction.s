; t33_direction - the blitter's optional direction bits (descriptor +1 bit 6
; mirror, bit 7 backwards, CAP_BLIT bit 3) and signed strides.  Mirror sends
; byte i of a row to width - 1 - i; backwards moves the bytes last first,
; which matters only when source and destination overlap.  Skipped (PASS
; with nothing checked) on a build whose CAP_BLIT lacks bit 3.
;
; RUN: -vicx -reu -reusize 16384

.include "harness.inc"

.code
main:
        VICX_UNLOCK_SEQ

        lda VICX_CAP_BLIT
        and #VICX_BLIT_DIRECTION
        bne :+
        PASS
:
        VICX_P0_SET $00500, VICX_STEP_1  ; clear $00500-$009FF
        lda #0
        P0_FILL 1280
        VICX_P0_SET $03000, VICX_STEP_1  ; source: 0, 1, ... 15
        ldx #0
:       stx VICX_P0_DATA
        inx
        cpx #16
        bne :-
        VICX_P0_SET $00600, VICX_STEP_1  ; and the same at $00600
        ldx #0
:       stx VICX_P0_DATA
        inx
        cpx #16
        bne :-
        VICX_P0_SET $03100, VICX_STEP_1
        lda #$C0                        ; 11000000
        sta VICX_P0_DATA

        ; 1. mirror: 0..7 -> 7..0
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM | VICX_DMA_MIRROR, $03000, $00500, 8, 0, 0, 0, 0, 0, VICX_DMA_NONE
        jsr go
        PEEK_AT $00500
        EXPECT_A 7, 10
        PEEK_AT $00503
        EXPECT_A 4, 11
        PEEK_AT $00507
        EXPECT_A 0, 12
        PEEK_AT $00508
        EXPECT_A 0, 13

        ; 2. backwards, overlapping: $00600-$0060C moved right by 3 over itself
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM | VICX_DMA_BACKWARD, $00600, $00603, 13, 0, 0, 0, 0, 0, VICX_DMA_NONE
        jsr go
        PEEK_AT $00602
        EXPECT_A 2, 20                  ; left alone
        PEEK_AT $00603
        EXPECT_A 0, 21
        PEEK_AT $00606
        EXPECT_A 3, 22                  ; (forwards would give 0 here)
        PEEK_AT $0060F
        EXPECT_A 12, 23

        ; 3. a negative destination stride ($FFE0 = -32): rows bottom up
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM | VICX_DMA_2D, $03000, $00840, 4, 3, 4, $FFE0, 0, 0, VICX_DMA_NONE
        jsr go
        PEEK_AT $00840
        EXPECT_A 0, 30
        PEEK_AT $00823
        EXPECT_A 7, 31
        PEEK_AT $00800
        EXPECT_A 8, 32
        PEEK_AT $00860
        EXPECT_A 0, 33                  ; nothing below the first row

        ; 4. mirrored expand: pixel n still takes bit n
        DMA_DESC 0, VICX_DMA_EXPAND, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM | VICX_DMA_MIRROR, $03100, $00900, 8, 0, 0, 0, $11, $22, VICX_DMA_NONE
        jsr go
        PEEK_AT $00907
        EXPECT_A $11, 40
        PEEK_AT $00906
        EXPECT_A $11, 41
        PEEK_AT $00905
        EXPECT_A $22, 42
        PEEK_AT $00900
        EXPECT_A $22, 43

        ; 5. mirror and backwards together: where bytes go is still mirrored
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM | VICX_DMA_MIRROR | VICX_DMA_BACKWARD | VICX_DMA_2D, $03000, $00980, 4, 2, 4, 8, 0, 0, VICX_DMA_NONE
        jsr go
        PEEK_AT $00980
        EXPECT_A 3, 50
        PEEK_AT $00983
        EXPECT_A 0, 51
        PEEK_AT $00988
        EXPECT_A 7, 52
        PEEK_AT $0098B
        EXPECT_A 4, 53
        PASS

go:     lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        rts
