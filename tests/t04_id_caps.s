; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t04_id_caps - ID, VERSION, capability registers, CTRL, IRQ_EN, reserved
; registers and the frame counter.
;
; Values in the VICE model: VERSION $01 (spec 0.1 draft), CAP_VRAM $10
; (128 KB), CAP_SPR $80 and CAP_SPRLINE $20 (the target limits), CAP_FEAT $1F
; (all features since step 5), CAP_BLIT $1F (all the optional blitter operations).  CAP_XRAM is the REU size in MB: 0 here,
; since this run has no REU (t27 checks it with one).
;
; On real hardware (-D HW_RESULT) the capability values are the build's own:
; there the test only asks that they are ones a build can have (VRAM 8 KB to
; 128 KB, 1 to 128 table entries, 1 to 32 sprites a line and no more than
; entries, the three display features), and takes any XRAM size, since the
; machine may have its REU on.
;
; RUN: -vicx

.include "harness.inc"

.code
main:
        VICX_UNLOCK_SEQ
        EXPECT VICX_ID0,         $56, 2
        EXPECT VICX_ID1,         $58, 3
        EXPECT VICX_VERSION,     $01, 4
.ifdef HW_RESULT
        lda VICX_CAP_VRAM
        sta capvram
        bne :+
        FAIL 5
:       cmp #$11
        bcc :+
        FAIL 5
:
        lda VICX_CAP_SPR
        bne :+
        FAIL 7
:       cmp #$81
        bcc :+
        FAIL 7
:
        lda VICX_CAP_SPRLINE
        bne :+
        FAIL 8
:       cmp #$21
        bcc :+
        FAIL 8
:       cmp VICX_CAP_SPR
        bcc :+
        beq :+
        FAIL 8
:
        lda VICX_CAP_FEAT
        and #VICX_FEAT_TILES | VICX_FEAT_BITMAP | VICX_FEAT_SPRITES
        EXPECT_A VICX_FEAT_TILES | VICX_FEAT_BITMAP | VICX_FEAT_SPRITES, 9
.else
        lda VICX_CAP_VRAM
        sta capvram
        EXPECT VICX_CAP_VRAM,    $10, 5
        EXPECT VICX_CAP_XRAM,    $00, 6
        EXPECT VICX_CAP_SPR,     $80, 7
        EXPECT VICX_CAP_SPRLINE, $20, 8
        EXPECT VICX_CAP_FEAT,    VICX_FEAT_TILES | VICX_FEAT_BITMAP | VICX_FEAT_SPRITES | VICX_FEAT_BLITTER | VICX_FEAT_WINDOWS, 9
.endif

        ; ID and capabilities are read-only
        lda #$12
        sta VICX_ID0
        sta VICX_VERSION
        sta VICX_CAP_VRAM
        EXPECT VICX_ID0,      $56, 10
        EXPECT VICX_VERSION,  $01, 11
        EXPECT_SAME VICX_CAP_VRAM, capvram, 12

        ; CTRL: reset value 0, bits 0-4 read back, bits 5-7 read 0
        EXPECT VICX_CTRL, $00, 13
        lda #$FF
        sta VICX_CTRL
        EXPECT VICX_CTRL, $1F, 14
        lda #$00
        sta VICX_CTRL
        EXPECT VICX_CTRL, $00, 15

        ; IRQ_EN keeps bits 0-2.  IRQ_STAT: writing 1s clears; with nothing
        ; colliding, bits 0-1 stay 0 (bit 2, start of frame, may set again)
        lda #$FF
        sta VICX_IRQ_EN
        EXPECT VICX_IRQ_EN, $07, 16
        lda #$00
        sta VICX_IRQ_EN
        lda #$07
        sta VICX_IRQ_STAT
        lda VICX_IRQ_STAT
        and #$03
        EXPECT_A $00, 17

        ; DMA_CMD: not busy
        EXPECT VICX_DMA_CMD, $00, 18

        ; CAP_BLIT: bits 5-7 read 0 (bits 0-4 say which optional blitter
        ; operations the build has)
        lda VICX_CAP_BLIT
        and #$E0
        EXPECT_A $00, 22

        ; reserved $D05C-$D06E read $FF and ignore writes
        ldx #$5C
@res:   lda #$00
        sta $D000,x
        lda $D000,x
        cmp #$FF
        beq @resok
        FAIL 19
@resok: inx
        cpx #$6F
        bne @res

        ; FRAME counts frames
        WAIT_FRAMES 1
        lda VICX_FRAME
        sta frame0
        WAIT_FRAMES 3
        lda VICX_FRAME
        sec
        sbc frame0
        EXPECT_A 3, 20

        VICX_LOCK_SEQ
        PASS

.bss
frame0: .res 1
capvram: .res 1
