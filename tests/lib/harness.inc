; harness.inc - common start-up and check macros for VIC-X conformance tests
;
; A test defines `main' and ends with PASS or a failed check.  Results go to
; VICE's debug cartridge at $D7FF (run with -debugcart): VICE exits with the
; value written, 0 = pass.  Every check has its own failure code (2-255) so
; the exit code names the failing check.  Code 1 is avoided because VICE
; also exits with 1 when -limitcycles runs out.

.include "vicx.inc"
.include "vicxlib.inc"

DBGCART = $D7FF

.segment "LOADADDR"
        .word $0801

.segment "EXEHDR"
        .word @next
        .word 10                ; 10 SYS 2061
        .byte $9e, "2061", 0
@next:  .word 0

.segment "CODE"
        sei                     ; $080D
        cld
        ldx #$ff
        txs
        jmp main

; Real hardware has no debug cartridge.  Assembled with -D HW_RESULT, a test
; also shows its result: border green (colour 5) and "PASS", or border red
; (colour 2) and "FAIL xx" with the failure code in hex, on the top line.
.if .defined(HW_RESULT) .and (.not .defined(RESULT_HOOK))
RESULT_HOOK = hw_result
hw_result:
        pha
        tax
        beq @pass
        lda #2
        sta $D020
        ldy #3
:       lda @fail_txt,y
        sta $0400,y
        lda #1
        sta $D800,y
        dey
        bpl :-
        txa
        lsr
        lsr
        lsr
        lsr
        jsr @hex
        sta $0405
        txa
        and #$0F
        jsr @hex
        sta $0406
        lda #1
        sta $D805
        sta $D806
        pla
        rts
@pass:  lda #5
        sta $D020
        ldy #3
:       lda @pass_txt,y
        sta $0400,y
        lda #1
        sta $D800,y
        dey
        bpl :-
        pla
        rts
@hex:   cmp #10                 ; 0-9 -> "0"-"9", 10-15 -> "A"-"F"
        bcc :+
        sbc #9
        rts
:       ora #$30
        rts
@pass_txt: .byte 16, 1, 19, 19  ; PASS (screen codes)
@fail_txt: .byte 6, 1, 9, 12    ; FAIL
.endif

; --- result macros -------------------------------------------------------

; A test may define RESULT_HOOK (a subroutine) before including this file;
; it is called with the result code in A (and must keep A) right before the
; result is written.
.macro PASS
        lda #0
  .ifdef RESULT_HOOK
        jsr RESULT_HOOK
  .endif
        sta DBGCART
        jmp *
.endmacro

.macro FAIL code
        lda #code
  .ifdef RESULT_HOOK
        jsr RESULT_HOOK
  .endif
        sta DBGCART
        jmp *
.endmacro

; A == value, else fail with code (A is preserved on success)
.macro EXPECT_A value, code
        .local ok
        cmp #value
        beq ok
        FAIL code
ok:
.endmacro

; A != value, else fail
.macro EXPECT_A_NOT value, code
        .local ok
        cmp #value
        bne ok
        FAIL code
ok:
.endmacro

; (addr) == value
.macro EXPECT addr, value, code
        lda addr
        EXPECT_A value, code
.endmacro

; (addr) != value
.macro EXPECT_NOT addr, value, code
        lda addr
        EXPECT_A_NOT value, code
.endmacro

; (addr1) == (addr2)
.macro EXPECT_SAME addr1, addr2, code
        .local ok
        lda addr1
        cmp addr2
        beq ok
        FAIL code
ok:
.endmacro

; Clear the text screen at $0400 to spaces.  Uses A and X.
.macro CLEAR_SCREEN
        .local loop
        lda #$20
        ldx #0
loop:   sta $0400,x
        sta $0500,x
        sta $0600,x
        sta $06E8,x
        inx
        bne loop
.endmacro

; Wait until the VIC-II raster passes line 0 `count' times (count >= 1).
.macro WAIT_FRAMES count
        .local w1, w2, loop
        ldy #count
loop:
w1:     lda $D012               ; wait for a line other than 0 ...
        beq w1
w2:     lda $D012               ; ... then for line 0: $D012 = 0 and bit 8 clear.
        bne w2                  ; ($D012 first: reading $D011 first races at
        lda $D011               ;  line 255 -> 256, which also has $D012 = 0)
        bmi w2
        dey
        bne loop
.endmacro

