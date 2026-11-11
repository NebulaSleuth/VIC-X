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

; Write `count' (1-65535) copies of A through port 0, which must already
; point at the start with a step.  Uses X and Y.
.macro P0_FILL count
        .local outer, inner
        ldy #>(count)
        ldx #<(count)
        beq inner                       ; low byte 0: start with a full page
        iny
inner:  sta VICX_P0_DATA
        dex
        bne inner
        dey
        bne inner
.endmacro

; Write one palette entry (VIC-X must be unlocked).  Uses A.
.macro SET_PAL index, r, g, b
        VICX_P0_SET VICX_PALETTE + (index) * 4, VICX_STEP_1
        lda #r
        sta VICX_P0_DATA
        lda #g
        sta VICX_P0_DATA
        lda #b
        sta VICX_P0_DATA
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

; Write `count' (1-65535) copies of a 16-bit value (low byte first) through
; port 0, which must already point at the start with step 1.  Uses A, X, Y.
.macro P0_FILL16 value, count
        .local inner
        ldy #>(count)
        ldx #<(count)
        beq inner
        iny
inner:  lda #<(value)
        sta VICX_P0_DATA
        lda #>(value)
        sta VICX_P0_DATA
        dex
        bne inner
        dey
        bne inner
.endmacro

; Write one 16-bit value at a VRAM address.  Uses A.
.macro POKE16 addr, value
        VICX_P0_SET addr, VICX_STEP_1
        lda #<(value)
        sta VICX_P0_DATA
        lda #>(value)
        sta VICX_P0_DATA
.endmacro

; Write the first 15 bytes of a layer setup (VICX_LAYER0 or VICX_LAYER1).
; Uses A.
.macro LAYER_SET layer, mode, mapsize, base, tilebase, sx, sy, stride, bank
        VICX_P0_SET layer, VICX_STEP_1
        lda #(mode)
        sta VICX_P0_DATA
        lda #(mapsize)
        sta VICX_P0_DATA
        lda #<(base)
        sta VICX_P0_DATA
        lda #>(base)
        sta VICX_P0_DATA
        lda #(((base) >> 16) & $FF)
        sta VICX_P0_DATA
        lda #<(tilebase)
        sta VICX_P0_DATA
        lda #>(tilebase)
        sta VICX_P0_DATA
        lda #(((tilebase) >> 16) & $FF)
        sta VICX_P0_DATA
        lda #<(sx)
        sta VICX_P0_DATA
        lda #>(sx)
        sta VICX_P0_DATA
        lda #<(sy)
        sta VICX_P0_DATA
        lda #>(sy)
        sta VICX_P0_DATA
        lda #<(stride)
        sta VICX_P0_DATA
        lda #>(stride)
        sta VICX_P0_DATA
        lda #(bank)
        sta VICX_P0_DATA
.endmacro
