; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; t27_windows - the XRAM windows: CAP_XRAM, page switching, the REU seeing
; the same memory, priority over RAM and KERNAL ROM, slot rules, code
; running from a window, the last page.
;
; XRAM is the REU's memory, so the test runs with a 16 MB REU.  Window
; page p covers XRAM p * 8 KB.
;
; RUN: -vicx -reu -reusize 16384

.include "harness.inc"

REU_CMD  = $DF01
REU_C64  = $DF02
REU_REU  = $DF04
REU_LEN  = $DF07
REU_CTRL = $DF0A

.macro W0 page, slot
        lda #<(page)
        sta VICX_W0_PAGEL
        lda #>(page)
        sta VICX_W0_PAGEH
        lda #(slot)
        sta VICX_W0_SLOT
.endmacro

.macro W1 page, slot
        lda #<(page)
        sta VICX_W1_PAGEL
        lda #>(page)
        sta VICX_W1_PAGEH
        lda #(slot)
        sta VICX_W1_SLOT
.endmacro

.code
main:
        lda #$11                        ; RAM under the $4000 slot
        sta $4000

        VICX_UNLOCK_SEQ
        EXPECT VICX_CAP_XRAM, 16, 2

        ; W0 at $4000, page 5
        W0 5, VICX_SLOT_4000 | VICX_SLOT_ON
        lda #$AA
        sta $4000
        lda #$BB
        sta $5FFF
        EXPECT $4000, $AA, 3

        ; page 6, then back
        W0 6, VICX_SLOT_4000 | VICX_SLOT_ON
        lda #$CC
        sta $4000
        W0 5, VICX_SLOT_4000 | VICX_SLOT_ON
        EXPECT $4000, $AA, 4
        W0 6, VICX_SLOT_4000 | VICX_SLOT_ON
        EXPECT $4000, $CC, 5

        ; the REU sees the same bytes: fetch XRAM $00BFFF (page 5 + $1FFF)
        lda #$00
        sta REU_CTRL
        lda #<$8200
        sta REU_C64
        lda #>$8200
        sta REU_C64 + 1
        lda #$FF
        sta REU_REU
        lda #$BF
        sta REU_REU + 1
        lda #$00
        sta REU_REU + 2
        lda #1
        sta REU_LEN
        lda #0
        sta REU_LEN + 1
        lda #$91                        ; execute, REU -> C64, no $FF00 trigger
        sta REU_CMD
        EXPECT $8200, $BB, 6

        ; window off: the RAM was never touched
        lda #0
        sta VICX_W0_SLOT
        EXPECT $4000, $11, 7

        ; over the KERNAL ROM at $E000
        lda $E000
        sta kernal
        W1 7, VICX_SLOT_E000 | VICX_SLOT_ON
        lda #$55
        sta $E000
        EXPECT $E000, $55, 8
        lda #0
        sta VICX_W1_SLOT
        EXPECT_SAME $E000, kernal, 9

        ; slot codes 6 and 7 are not allowed: the window stays off
        W0 5, 6 | VICX_SLOT_ON
        EXPECT $4000, $11, 10

        ; both windows in one slot: W0 wins
        W0 5, VICX_SLOT_4000 | VICX_SLOT_ON
        W1 6, VICX_SLOT_4000 | VICX_SLOT_ON
        EXPECT $4000, $AA, 11
        lda #0
        sta VICX_W1_SLOT

        ; code runs from a window: LDA #$42 / RTS
        W0 8, VICX_SLOT_4000 | VICX_SLOT_ON
        lda #$A9
        sta $4000
        lda #$42
        sta $4001
        lda #$60
        sta $4002
        lda #0
        jsr $4000
        EXPECT_A $42, 12

        ; the page register keeps 11 bits; page $7FF is the last 8 KB
        W0 $7FF, VICX_SLOT_4000 | VICX_SLOT_ON
        lda #$FF
        sta VICX_W0_PAGEH
        EXPECT VICX_W0_PAGEH, $07, 13
        lda #$66
        sta $5FFF
        EXPECT $5FFF, $66, 14

        lda #0
        sta VICX_W0_SLOT
        EXPECT $4000, $11, 15
        PASS

.bss
kernal: .res 1
