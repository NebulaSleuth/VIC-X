; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t06_reset - a machine reset locks VIC-X and restores its defaults
; (CTRL, ports, palette entries 0-15).
;
; Phase 1 unlocks VIC-X, saves the stock palette, changes CTRL, a port and
; palette entries, puts a CBM80 signature at $8000 and jumps to a trap at
; $033C.  The monitor file sets a breakpoint there that resets the machine
; (like the reset button; RAM survives).  The KERNAL then starts phase 2
; through the CBM80 vector, which checks the state after the reset.
;
; RUN: -vicx
; MON: t06_reset.mon

.include "harness.inc"

TRAP = $033C

.code
main:
        ; CBM80 autostart signature -> phase2 after the reset
        ldx #8
:       lda cbm80,x
        sta $8000,x
        dex
        bpl :-

        lda #$00
        sta $D000

        VICX_UNLOCK_SEQ
        EXPECT VICX_ID0, $56, 2

        ; save the stock palette entries 0-15 (64 bytes)
        VICX_P0_SET VICX_PALETTE, VICX_STEP_1
        ldx #0
:       lda VICX_P0_DATA
        sta stock_pal,x
        inx
        cpx #64
        bne :-

        ; change state: CTRL, port 1, palette entries 0 and 15
        lda #VICX_CTRL_PALMAP | VICX_CTRL_BGTRANS
        sta VICX_CTRL
        VICX_P0_SET VICX_PALETTE, VICX_STEP_1
        lda #$12
        sta VICX_P0_DATA
        lda #$34
        sta VICX_P0_DATA
        lda #$56
        sta VICX_P0_DATA
        VICX_P0_SET VICX_PALETTE + 15*4, VICX_STEP_1
        lda #$9A
        sta VICX_P0_DATA
        lda #$BC
        sta VICX_P0_DATA
        lda #$DE
        sta VICX_P0_DATA
        lda #$AA
        sta VICX_P1_ADDRL
        lda #$BB
        sta VICX_P1_ADDRM
        lda #VICX_STEP_8 | $01
        sta VICX_P1_ADDRH
        ; leave port 0 somewhere too
        VICX_P0_SET $12345, VICX_STEP_320
        ; and a byte of VRAM, which survives the reset like RAM
        lda #$5C
        sta VICX_P0_DATA

        lda #1
        sta phase1_done
        ; trap: the monitor breakpoint resets the machine here
        lda #$4C                ; JMP TRAP
        sta TRAP
        lda #<TRAP
        sta TRAP + 1
        lda #>TRAP
        sta TRAP + 2
        jmp TRAP

phase2:
        sei
        lda phase1_done
        EXPECT_A 1, 3                   ; phase 1 really ran before the reset

        ; locked: $D040 is the mirror of $D000 again
        lda #$00
        sta $D000
        EXPECT $D040, $00, 4
        lda #$21
        sta $D000
        EXPECT $D040, $21, 5

        VICX_UNLOCK_SEQ
        EXPECT VICX_ID0, $56, 6
        EXPECT VICX_CTRL, $00, 7
        EXPECT VICX_P1_ADDRL, $00, 8
        EXPECT VICX_P1_ADDRM, $00, 9
        EXPECT VICX_P1_ADDRH, $00, 10
        EXPECT VICX_P0_ADDRL, $00, 11
        EXPECT VICX_P0_ADDRM, $00, 12
        EXPECT VICX_P0_ADDRH, $00, 13

        ; palette entries 0-15 are the stock palette again
        VICX_P0_SET VICX_PALETTE, VICX_STEP_1
        ldx #0
@pal:   lda VICX_P0_DATA
        cmp stock_pal,x
        beq :+
        FAIL 14
:       inx
        cpx #64
        bne @pal

        ; VRAM kept its contents
        VICX_P0_SET $12345, VICX_STEP_0
        EXPECT VICX_P0_DATA, $5C, 15

        VICX_LOCK_SEQ
        PASS

.rodata
cbm80:  .word phase2, phase2
        .byte $C3, $C2, $CD, $38, $30

.bss
stock_pal:   .res 64
phase1_done: .res 1
