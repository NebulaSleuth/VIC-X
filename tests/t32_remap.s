; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t32_remap - the blitter's optional remap (operation 5): each source byte
; that is not the transparent value is looked up in a 256-byte table in VRAM
; (descriptor +21-+23) and the table's byte is written.  The table is read
; when the descriptor starts, so a remap that writes into its own table
; still uses the old values.  Skipped (PASS with nothing checked) on a build
; whose CAP_BLIT lacks bit 1.
;
; RUN: -vicx -reu -reusize 16384

.include "harness.inc"

TABLE = $01F00                  ; table[i] = i EOR $5A

.code
main:
        VICX_UNLOCK_SEQ

        lda VICX_CAP_BLIT
        and #VICX_BLIT_REMAP
        bne :+
        PASS
:
        VICX_P0_SET TABLE, VICX_STEP_1
        ldx #0
:       txa
        eor #$5A
        sta VICX_P0_DATA
        inx
        bne :-
        VICX_P0_SET $03000, VICX_STEP_1  ; source: 0, 1, ... 15
        ldx #0
:       stx VICX_P0_DATA
        inx
        cpx #16
        bne :-
        VICX_P0_SET $03100, VICX_STEP_1  ; source for the self-overwrite: 1, 0
        lda #1
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        VICX_P0_SET $00400, VICX_STEP_1
        lda #$EE
        P0_FILL 128
        lda #$31                        ; C64 RAM: two rows of two bytes
        sta $3020
        lda #$32
        sta $3021
        lda #$07                        ; transparent: skipped
        sta $3028
        lda #$34
        sta $3029

        ; 1. VRAM to VRAM, 16 bytes, transparent $07: byte 7 is left alone
        DMA_DESC 0, VICX_DMA_REMAP, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM, $03000, $00400, 16, 0, 0, 0, 0, $07, VICX_DMA_NONE
        jsr table_addr
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        lda #0                          ; port 1 reads them back
        sta VICX_P1_ADDRL
        lda #$04
        sta VICX_P1_ADDRM
        lda #VICX_STEP_1
        sta VICX_P1_ADDRH
        ldx #0
c1:     lda VICX_P1_DATA
        cpx #7
        bne :+
        cmp #$EE
        beq c1n
        FAIL 9
:       sta tmp
        txa
        eor #$5A
        cmp tmp
        beq c1n
        txa
        clc
        adc #10                         ; codes 10-25: byte n wrong
  .ifdef RESULT_HOOK
        jsr RESULT_HOOK
  .endif
        sta DBGCART
        jmp *
c1n:    inx
        cpx #16
        bne c1
        PEEK_AT $00410
        EXPECT_A $EE, 30

        ; 2. 2D from C64 RAM: rows of 2, source stride 8, destination stride 32
        DMA_DESC 0, VICX_DMA_REMAP, VICX_DMA_SRC_C64 | VICX_DMA_DST_VRAM | VICX_DMA_2D, $3020, $00420, 2, 2, 8, 32, 0, $07, VICX_DMA_NONE
        jsr table_addr
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        PEEK_AT $00420
        EXPECT_A $31 ^ $5A, 31
        PEEK_AT $00421
        EXPECT_A $32 ^ $5A, 32
        PEEK_AT $00440
        EXPECT_A $EE, 33                ; transparent
        PEEK_AT $00441
        EXPECT_A $34 ^ $5A, 34

        ; 3. into its own table: source 1, 0 to table[0], table[1]
        DMA_DESC 0, VICX_DMA_REMAP, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM, $03100, TABLE, 2, 0, 0, 0, 0, $FF, VICX_DMA_NONE
        jsr table_addr
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        PEEK_AT TABLE
        EXPECT_A 1 ^ $5A, 40
        PEEK_AT TABLE + 1
        EXPECT_A 0 ^ $5A, 41            ; the old table[0], not the new one
        PASS

; Descriptor 0 +21-+23: the table's address.
table_addr:
        VICX_P0_SET VICX_DMADESC + 21, VICX_STEP_1
        lda #<TABLE
        sta VICX_P0_DATA
        lda #>TABLE
        sta VICX_P0_DATA
        lda #^TABLE
        sta VICX_P0_DATA
        rts

.bss
tmp:    .res 1
