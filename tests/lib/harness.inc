; harness.inc - common start-up and check macros for VIC-X conformance tests
;
; A test defines `main' and ends with PASS or a failed check.  Results go to
; VICE's debug cartridge at $D7FF (run with -debugcart): VICE exits with the
; value written, 0 = pass.  Every check has its own failure code (2-255) so
; the exit code names the failing check.  Code 1 is avoided because VICE
; also exits with 1 when -limitcycles runs out.

.include "vicx.inc"

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
