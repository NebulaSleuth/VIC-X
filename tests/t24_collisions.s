; t24_collisions - sprite collisions: the list at $20900, group masks,
; transparent pixels, three-way overlaps, IRQ_STAT bit 0 and the CPU IRQ.
;
; 8x8 8-bit sprites; "solid" is colour 41 everywhere, "edge" has only its
; left column opaque.  Entries (x,y, groups):
;   0 solid (10,10) %0001 and 1 solid (14,12) %0011: collide
;   2 solid (40,10) %0001 and 3 solid (44,10) %0010: no shared group
;   4 edge  (70,10) %1111 and 5 solid (72,10) %1111: overlap only where 4 is
;     transparent
;   6, 7, 8 solid (100,50) %1111: three pairs
;   9 solid (200,50) %0000 and 10 solid (202,50) %1111: group mask 0
;   11, 12 solid (150,100) and (152,100): groups %0010, hit mask (+7)
;     %0001, like two bullets: they ignore each other
;   13 solid (154,100): groups %0001, hit mask %0010, like the player:
;     hits both bullets
; The list for a frame is published after the last display line (raster
; line 250): count 6, then pairs (0,1) (6,7) (6,8) (7,8) (11,13) (12,13), in
; the order the lines and pixels are drawn.  Then: with IRQ_EN bit 0 clear no IRQ arrives;
; with it set, the IRQ handler runs every frame, on raster line 251 or 252,
; and acknowledges by writing IRQ_STAT.
;
; RUN: -vicx

.include "harness.inc"

SOLID = $0000
EDGE  = $0040
G1    = VICX_S_GROUP

.macro HITMASK entry, mask
        VICX_P0_SET VICX_SPRITES + (entry) * 8 + VICX_S_HITS, VICX_STEP_0
        lda #(mask)
        sta VICX_P0_DATA
.endmacro

.code
main:
        CLEAR_SCREEN
        VICX_UNLOCK_SEQ

        VICX_P0_SET SOLID, VICX_STEP_1
        lda #41
        P0_FILL 64
        ldx #8                          ; edge: rows of 41, 0 x 7
:       lda #41
        sta VICX_P0_DATA
        lda #0
        ldy #7
:       sta VICX_P0_DATA
        dey
        bne :-
        dex
        bne :--

        SPRITE 0,  10,  10, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %0001, SOLID, VICX_S_8BIT
        SPRITE 1,  14,  12, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %0011, SOLID, VICX_S_8BIT
        SPRITE 2,  40,  10, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %0001, SOLID, VICX_S_8BIT
        SPRITE 3,  44,  10, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %0010, SOLID, VICX_S_8BIT
        SPRITE 4,  70,  10, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %1111, EDGE,  VICX_S_8BIT
        SPRITE 5,  72,  10, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %1111, SOLID, VICX_S_8BIT
        SPRITE 6, 100,  50, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %1111, SOLID, VICX_S_8BIT
        SPRITE 7, 100,  50, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %1111, SOLID, VICX_S_8BIT
        SPRITE 8, 100,  50, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %1111, SOLID, VICX_S_8BIT
        SPRITE 9, 200,  50, VICX_SW_8 | VICX_SH_8, VICX_S_ON,              SOLID, VICX_S_8BIT
        SPRITE 10, 202, 50, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %1111, SOLID, VICX_S_8BIT

        SPRITE 11, 150, 100, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %0010, SOLID, VICX_S_8BIT
        SPRITE 12, 152, 100, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %0010, SOLID, VICX_S_8BIT
        SPRITE 13, 154, 100, VICX_SW_8 | VICX_SH_8, VICX_S_ON | G1 * %0001, SOLID, VICX_S_8BIT
        HITMASK 11, %0001
        HITMASK 12, %0001
        HITMASK 13, %0010

        lda #VICX_CTRL_SPR
        sta VICX_CTRL
        WAIT_FRAMES 3

        ; the collision list
        VICX_P0_SET VICX_COLLIST, VICX_STEP_1
        ldx #0
@cmp:   lda VICX_P0_DATA
        cmp expected,x
        beq :+
        txa
        clc
        adc #10                         ; check 10 + byte index
        jmp fail_a
:       inx
        cpx #13
        bne @cmp

        ; IRQ_STAT bit 0 is set
        lda VICX_IRQ_STAT
        and #VICX_IRQ_SPRCOL
        EXPECT_A VICX_IRQ_SPRCOL, 2

        ; the CPU IRQ: only CIA interrupts off, our handler on $0314
        lda #$7F
        sta $DC0D
        lda $DC0D
        lda #<irq
        sta $0314
        lda #>irq
        sta $0315
        lda #0
        sta count
        cli
        WAIT_FRAMES 2                   ; IRQ_EN still 0: no IRQ
        lda count
        EXPECT_A 0, 3
        lda #VICX_IRQ_SPRCOL
        sta VICX_IRQ_EN
        WAIT_FRAMES 3
        sei
        lda #0
        sta VICX_IRQ_EN
        lda count
        cmp #2
        bcs :+
        FAIL 4
:       lda irqline
        cmp #251
        bcc :+
        cmp #253
        bcs :+
        PASS
:       FAIL 5

fail_a:
  .ifdef RESULT_HOOK
        jsr RESULT_HOOK
  .endif
        sta DBGCART
:       jmp :-

irq:
        lda $D012
        sta irqline
        inc count
        lda #VICX_IRQ_SPRCOL
        sta VICX_IRQ_STAT
        jmp $EA81

.rodata
expected: .byte 6, 0, 1, 6, 7, 6, 8, 7, 8, 11, 13, 12, 13

.bss
count: .res 1
irqline: .res 1
