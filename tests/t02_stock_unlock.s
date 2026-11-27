; t02_stock_unlock - with VIC-X disabled (+vicx) the full unlock sequence
; does nothing: $D040-$D06F stay VIC-II mirrors.
;
; Only for a machine WITHOUT VIC-X (VICE with +vicx).  On hardware that has
; VIC-X the unlock works and this test fails at its first check (FAIL 02):
; that is the right result there, not a fault.
;
; RUN: +vicx

.include "harness.inc"

.code
main:
        lda #$00
        sta $D000
        sta $D001
        VICX_UNLOCK_SEQ
        EXPECT $D040, $00, 2
        EXPECT $D041, $00, 3
        lda #$02
        sta $D048                       ; = $D008 (sprite 4 X)
        EXPECT $D008, $02, 4
        lda #$09
        sta VICX_P0_DATA                ; = $D00F (sprite 7 Y)
        EXPECT $D00F, $09, 5
        PASS
