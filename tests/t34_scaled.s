; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t34_scaled - the blitter's optional scaled copy (operation 6, CAP_BLIT bit
; 2): destination byte c of row r takes source byte (c * X step) >> 8 of
; source row (r * Y step) >> 8 (steps 8.8 at descriptor +24-+27); bytes equal
; to the transparent value are skipped.  Skipped (PASS with nothing checked)
; on a build whose CAP_BLIT lacks bit 2.
;
; Source: VRAM $03000, 4 rows of 16 bytes, byte r * 16 + c = r * 16 + c,
; except byte 3, which is $FF (transparent).
;
; RUN: -vicx -reu -reusize 16384

.include "harness.inc"

.macro STEPS xstep, ystep             ; descriptor 0 +24-+27
        VICX_P0_SET VICX_DMADESC + 24, VICX_STEP_1
        lda #<(xstep)
        sta VICX_P0_DATA
        lda #>(xstep)
        sta VICX_P0_DATA
        lda #<(ystep)
        sta VICX_P0_DATA
        lda #>(ystep)
        sta VICX_P0_DATA
.endmacro

.code
main:
        VICX_UNLOCK_SEQ

        lda VICX_CAP_BLIT
        and #VICX_BLIT_SCALED
        bne :+
        PASS
:
        VICX_P0_SET $00500, VICX_STEP_1
        lda #$EE
        P0_FILL 768
        VICX_P0_SET $03000, VICX_STEP_1
        ldx #0
:       txa
        cpx #3
        bne :+
        lda #$FF
:       sta VICX_P0_DATA
        inx
        cpx #64
        bne :--

        ; 1. twice the size: 8 x 4 from 4 x 2, destination stride 32
        DMA_DESC 0, VICX_DMA_SCALED, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM | VICX_DMA_2D, $03000, $00500, 8, 4, 16, 32, 0, $FF, VICX_DMA_NONE
        STEPS $0080, $0080
        jsr go
        PEEK_AT $00500
        EXPECT_A 0, 10
        PEEK_AT $00501
        EXPECT_A 0, 11
        PEEK_AT $00502
        EXPECT_A 1, 12
        PEEK_AT $00524                  ; row 1, byte 4: source row 0, byte 2
        EXPECT_A 2, 13
        PEEK_AT $00540                  ; row 2: source row 1
        EXPECT_A 16, 14
        PEEK_AT $00565
        EXPECT_A 18, 15
        PEEK_AT $00506                  ; source byte 3: transparent, skipped
        EXPECT_A $EE, 16

        ; 2. a step of 0.75, one row
        DMA_DESC 0, VICX_DMA_SCALED, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM, $03000, $00600, 8, 0, 0, 0, 0, $FF, VICX_DMA_NONE
        STEPS $00C0, 0
        jsr go
        PEEK_AT $00600
        EXPECT_A 0, 20
        PEEK_AT $00601
        EXPECT_A 0, 21
        PEEK_AT $00602
        EXPECT_A 1, 22
        PEEK_AT $00603
        EXPECT_A 2, 23
        PEEK_AT $00604
        EXPECT_A $EE, 24
        PEEK_AT $00606
        EXPECT_A 4, 25
        PEEK_AT $00607
        EXPECT_A 5, 26

        ; 3. half the size
        DMA_DESC 0, VICX_DMA_SCALED, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM | VICX_DMA_2D, $03000, $00700, 4, 2, 16, 32, 0, $FF, VICX_DMA_NONE
        STEPS $0200, $0200
        jsr go
        PEEK_AT $00701
        EXPECT_A 2, 30
        PEEK_AT $00720
        EXPECT_A 32, 31
        PEEK_AT $00723
        EXPECT_A 38, 32

        ; 4. mirrored, 1:1
        DMA_DESC 0, VICX_DMA_SCALED, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM | VICX_DMA_MIRROR, $03000, $00780, 4, 0, 0, 0, 0, $FF, VICX_DMA_NONE
        STEPS $0100, 0
        jsr go
        PEEK_AT $00780
        EXPECT_A $EE, 40
        PEEK_AT $00781
        EXPECT_A 2, 41
        PEEK_AT $00783
        EXPECT_A 0, 42
        PASS

go:     lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        rts
