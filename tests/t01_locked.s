; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t01_locked - while locked (or with VIC-X disabled), $D040-$D06F behave as
; stock VIC-II mirrors of $D000-$D02F, and broken unlock sequences do not
; unlock.
;
; RUN: -vicx
; RUN: +vicx

.include "harness.inc"

.code
main:
        ; --- the mirrors read and write the VIC-II -----------------------
        lda #$00
        sta $D000
        EXPECT $D040, $00, 2            ; $D040 = mirror of $D000, not ID $56
        lda #$5A
        sta $D000
        EXPECT $D040, $5A, 3
        lda #$33
        sta $D041                       ; write through the mirror of $D001
        EXPECT $D001, $33, 4
        lda #$05
        sta $D060                       ; mirror of $D020 (border)
        lda $D020
        and #$0F
        EXPECT_A $05, 5
        EXPECT $D06F, $FF, 6            ; mirror of unused $D02F
        lda #$07                        ; sprite 7 colour reads with the high nibble set
        sta $D02E
        EXPECT $D06E, $F7, 8

        ; --- broken sequences must not unlock -----------------------------
        lda #$00
        sta $D000

        ; another VIC-II write in between
        lda #VICX_KEY1
        sta VICX_UNLOCK
        lda #VICX_KEY2
        sta VICX_UNLOCK
        lda #$00
        sta $D020
        lda #VICX_KEY3
        sta VICX_UNLOCK
        EXPECT $D040, $00, 9

        ; a write to a far mirror ($D120 = $D020) in between
        lda #VICX_KEY1
        sta VICX_UNLOCK
        sta $D120
        lda #VICX_KEY2
        sta VICX_UNLOCK
        lda #VICX_KEY3
        sta VICX_UNLOCK
        EXPECT $D040, $00, 10

        ; wrong order
        lda #VICX_KEY2
        sta VICX_UNLOCK
        lda #VICX_KEY1
        sta VICX_UNLOCK
        lda #VICX_KEY3
        sta VICX_UNLOCK
        EXPECT $D040, $00, 11

        ; the key written to $D02F itself (not the $D06F mirror)
        lda #VICX_KEY1
        sta $D02F
        lda #VICX_KEY2
        sta $D02F
        lda #VICX_KEY3
        sta $D02F
        EXPECT $D040, $00, 12

        ; the key written to another $D02F mirror ($D0AF)
        lda #VICX_KEY1
        sta $D0AF
        lda #VICX_KEY2
        sta $D0AF
        lda #VICX_KEY3
        sta $D0AF
        EXPECT $D040, $00, 13

        ; the $D030-$D03F row and its mirrors stay stock ($FF)
        EXPECT $D030, $FF, 14
        EXPECT $D071, $FF, 15
        EXPECT $D07F, $FF, 16

        PASS
