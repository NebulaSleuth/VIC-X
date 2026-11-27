; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t03_unlock - unlock, ID, relock, re-unlock; VIC-X registers do not write
; through to the VIC-II while unlocked.
;
; RUN: -vicx

.include "harness.inc"

.code
main:
        lda #$00
        sta $D000
        sta $D001
        lda #$03
        sta $D020

        VICX_UNLOCK_SEQ
        EXPECT VICX_ID0, $56, 2
        EXPECT VICX_ID1, $58, 3

        ; unlocked registers must not reach the VIC-II mirror
        lda #$0E
        sta $D060                       ; reserved VIC-X register, would be $D020
        lda $D020
        and #$0F
        EXPECT_A $03, 4
        lda #$1F
        sta VICX_CTRL                   ; would be $D008
        EXPECT $D008, $00, 5
        lda #$00
        sta VICX_CTRL
        ; $D000-$D03F keep stock behaviour while unlocked
        lda #$44
        sta $D000
        EXPECT $D000, $44, 6
        EXPECT $D040, $56, 7            ; ... and $D040 is still the ID
        ; the $D030 row and its $D070 mirrors stay stock
        EXPECT $D070, $FF, 8
        EXPECT $D07F, $FF, 9
        ; $D06F reads $FF while unlocked
        EXPECT VICX_UNLOCK, $FF, 10

        ; writing the key again keeps it unlocked
        VICX_UNLOCK_SEQ
        EXPECT VICX_ID0, $56, 11

        ; relock: $D040 is a mirror of $D000 again
        VICX_LOCK_SEQ
        EXPECT $D040, $44, 12
        lda #$0E
        sta $D060
        lda $D020
        and #$0F
        EXPECT_A $0E, 13

        ; a repeated first key byte restarts the sequence: $56 $56 $58 $21
        lda #VICX_KEY1
        sta VICX_UNLOCK
        sta VICX_UNLOCK
        lda #VICX_KEY2
        sta VICX_UNLOCK
        lda #VICX_KEY3
        sta VICX_UNLOCK
        EXPECT VICX_ID0, $56, 14

        ; $00 in mid-sequence relocks and cancels
        VICX_LOCK_SEQ
        lda #VICX_KEY1
        sta VICX_UNLOCK
        lda #$00
        sta VICX_UNLOCK
        lda #VICX_KEY2
        sta VICX_UNLOCK
        lda #VICX_KEY3
        sta VICX_UNLOCK
        EXPECT $D040, $44, 15

        ; state survives a relock/unlock cycle (only reset clears it)
        VICX_UNLOCK_SEQ
        lda #VICX_CTRL_BGTRANS
        sta VICX_CTRL
        VICX_LOCK_SEQ
        VICX_UNLOCK_SEQ
        EXPECT VICX_CTRL, VICX_CTRL_BGTRANS, 16
        lda #0
        sta VICX_CTRL
        VICX_LOCK_SEQ
        PASS
