; bullets.s - Bullet storm: 128 sprites, collision groups, DMA table updates.
;
; A build with fewer sprite table entries (CAP_SPR below 128) gets as many
; sprites as it has entries; the title shows the count.
;
; Entry 0 is the player's 32x32 ship, sliding along the bottom (x 16-240),
; over a deep-space picture on layer 1 (an 8-bit bitmap).  The ship and the
; backdrop were made with Nano Banana (see art/).  Entries
; 1-127 are 8x8 bullets fired from the centre in four rotating spiral arms,
; two per frame; a bullet that leaves the screen waits for its next turn.
; Bullets belong to group 2 and hit group 1; the ship belongs to group 1 and
; hits group 2, so bullets ignore each other and the collision list holds
; only ship hits.  HITS counts the frames with a hit.
;
; Each frame, at line 251 (after the display window), DMA copies the 1 KB
; sprite table built in C64 RAM during the previous frame to $20400; the
; engine latches it at the start of the next frame.  Then the CPU moves
; every bullet for the frame after.  The bottom row shows the frame
; rate.

NEED_XRAM_MB = 2
NEED_FEAT    = VICX_FEAT_BITMAP | VICX_FEAT_SPRITES | VICX_FEAT_BLITTER
CPU_TEXT     = $0400 + 24 * 40      ; bottom row
.include "demo.inc"
.include "assets.inc"
.include "tables.inc"           ; vx_lo/vx_hi/vy_lo/vy_hi: speed x cos/sin, 8.8

NB      = 127                   ; bullets, entries 1-127
SPRTAB  = $9000                 ; sprite table being built (1 KB)
XF      = $9400                 ; per bullet: x 16.8, y 16.8, velocity 8.8 + sign
XL      = $9480
XH      = $9500
YF      = $9580
YL      = $9600
YH      = $9680
VXL     = $9700
VXH     = $9780
VXS     = $9800
VYL     = $9880
VYH     = $9900
VYS     = $9980
PTR     = $FD

SHIP_V  = $00000                ; patterns in VRAM (ship 1 KB)
BUL_V   = $00400
SPACE_V = $10000                ; backdrop bitmap
CX      = 156                   ; emitter (window pixels)
CY      = 90
PLAYER_Y = 164
PARKED  = $80                   ; XH value of a bullet waiting to fire

GROUPS_SHIP   = $10             ; +3 bits 4-7: group 1
GROUPS_BULLET = $20             ; group 2

.code
main:
        ldx #0
:       lda #$20
        sta $0400,x
        sta $0500,x
        sta $0600,x
        sta $06E8,x
        lda #1
        sta $D800,x
        sta $D900,x
        sta $DA00,x
        sta $DAE8,x
        inx
        bne :-
        lda #0
        sta $D020
        sta $D021
        PRINT_AT 0, title

        ; as many sprites as the build has entries, 128 at most
        lda VICX_CAP_SPR
        beq @all                        ; (0: 256 entries)
        cmp #NB + 2
        bcc @few
@all:   lda #NB + 1
@few:   sta nspr
        cmp #NB + 1
        beq @shown
        ldx #$20                        ; the count in the title, in decimal
        cmp #100
        bcc :+
        sbc #100
        ldx #$31
:       ldy #$30
:       cmp #10
        bcc :+
        sbc #10
        iny
        bne :-
:       ora #$30
        sta $0400 + 17
        cpx #$20
        bne :+
        cpy #$30
        bne :+
        ldy #$20
:       sty $0400 + 16
        stx $0400 + 15
@shown:

        lda #0
        sta VICX_CTRL
        XRAM_TO_VRAM SHIP_SPR, SHIP_V, SHIP_SPR_LEN
        XRAM_TO_VRAM BULLET_SPR, BUL_V, BULLET_SPR_LEN
        XRAM_TO_VRAM SHIP_PAL, VICX_PALETTE + 208 * 4, SHIP_PAL_LEN
        XRAM_TO_VRAM SPACE_PIX, SPACE_V, SPACE_PIX_LEN
        XRAM_TO_VRAM SPACE_PAL, VICX_PALETTE + 16 * 4, SPACE_PAL_LEN
        LAYER_SET VICX_LAYER1, VICX_LMODE_BITMAP8, 0, SPACE_V, 0, 0, 0, 320, 0
        XRAM_TO_VRAM BULLET_PAL, VICX_PALETTE + 232 * 4, BULLET_PAL_LEN

        ; descriptor 1: the sprite table, C64 RAM -> $20400, every frame
        DMA_DESC 1, VICX_DMA_COPY, VICX_DMA_SRC_C64 | VICX_DMA_DST_VRAM, SPRTAB, VICX_SPRITES, 1024, 0, 0, 0, 0, 0, VICX_DMA_NONE

        ; entry 0: the ship
        lda #<150
        sta px
        lda #1
        sta pdir
        lda #VICX_SW_32 | VICX_SH_32
        sta SPRTAB + 1
        lda #PLAYER_Y
        sta SPRTAB + 2
        lda #VICX_S_ON | GROUPS_SHIP
        sta SPRTAB + 3
        lda #<(SHIP_V / 32)
        sta SPRTAB + 4
        lda #>(SHIP_V / 32)
        sta SPRTAB + 5
        lda #VICX_S_8BIT
        sta SPRTAB + 6
        lda #%0010                      ; hits group 2
        sta SPRTAB + 7

        ; entries 1-127: bullets, parked; patterns cycle through 4 colours
        lda #<(SPRTAB + 8)
        sta PTR
        lda #>(SPRTAB + 8)
        sta PTR + 1
        ldx #1
@init:  ldy #0
        lda #0
        sta (PTR),y                     ; +0
        iny
        sta (PTR),y                     ; +1: 8x8
        iny
        sta (PTR),y                     ; +2
        iny
        sta (PTR),y                     ; +3: off
        iny
        txa
        and #3
        asl
        clc
        adc #<(BUL_V / 32)
        sta (PTR),y                     ; +4: pattern / 32
        iny
        lda #0
        sta (PTR),y                     ; +5
        iny
        lda #VICX_S_8BIT
        sta (PTR),y                     ; +6
        iny
        lda #%0001                      ; hits group 1
        sta (PTR),y                     ; +7
        lda #PARKED
        sta XH,x
        jsr ptr_next
        inx
        cpx #NB + 1
        bne @init

        lda #0
        sta base_angle
        sta arm
        sta hits
        sta hits + 1
        lda #VICX_CTRL_SPR | VICX_CTRL_L1 | VICX_CTRL_BGTRANS
        sta VICX_CTRL

loop:
        ldx #251
        jsr wait_line
        jsr cpu_start
        lda #1                          ; table built last frame -> engine
        sta VICX_DMA_CMD

        ; a ship hit in the frame that just ended?
        PEEK_AT VICX_COLLIST
        beq :+
        sed
        clc
        lda hits
        adc #1
        sta hits
        lda hits + 1
        adc #0
        sta hits + 1
        cld
        jsr show_hits
:
        ; the ship slides between x 16 and 240 (its size bits stay in +1)
        lda px
        clc
        adc pdir
        sta px
        cmp #16
        beq @flip
        cmp #240
        bne @shipok
@flip:  lda #0
        sec
        sbc pdir
        sta pdir
@shipok:
        lda px
        sta SPRTAB + 0

        ; bullets
        lda #2
        sta budget
        lda #<(SPRTAB + 8)
        sta PTR
        lda #>(SPRTAB + 8)
        sta PTR + 1
        ldx #1
@bullet:
        lda XH,x
        cmp #PARKED
        beq @spawn
        clc                             ; move
        lda XF,x
        adc VXL,x
        sta XF,x
        lda XL,x
        adc VXH,x
        sta XL,x
        lda XH,x
        adc VXS,x
        sta XH,x
        clc
        lda YF,x
        adc VYL,x
        sta YF,x
        lda YL,x
        adc VYH,x
        sta YL,x
        lda YH,x
        adc VYS,x
        sta YH,x
        lda XH,x                        ; still on screen?  0 <= x < 328
        bmi @out
        beq @xok
        cmp #1
        bne @out
        lda XL,x
        cmp #328 - 256
        bcs @out
@xok:   lda YH,x                        ; 0 <= y < 208
        bne @out
        lda YL,x
        cmp #208
        bcs @out
        jmp @write
@out:   lda #PARKED
        sta XH,x
@spawn: lda budget
        beq @hide
        dec budget
        lda #$80
        sta XF,x
        sta YF,x
        lda #CX
        sta XL,x
        lda #CY
        sta YL,x
        lda #0
        sta XH,x
        sta YH,x
        lda arm                         ; four arms, 64 apart, turning slowly
        clc
        adc #1
        and #3
        sta arm
        asl
        asl
        asl
        asl
        asl
        asl
        clc
        adc base_angle
        tay
        lda vx_lo,y
        sta VXL,x
        lda vx_hi,y
        sta VXH,x
        jsr sign
        sta VXS,x
        lda vy_lo,y
        sta VYL,x
        lda vy_hi,y
        sta VYH,x
        jsr sign
        sta VYS,x
@write: ldy #0
        lda XL,x
        sta (PTR),y
        iny
        lda XH,x
        and #3
        sta (PTR),y
        iny
        lda YL,x
        sta (PTR),y
        iny
        lda YH,x
        and #3
        ora #VICX_S_ON | GROUPS_BULLET
        sta (PTR),y
        jmp @next
@hide:  ldy #3
        lda #0
        sta (PTR),y
@next:  jsr ptr_next
        inx
        cpx nspr
        beq :+
        jmp @bullet
:
        inc base_angle
        jsr cpu_end
        jmp loop

ptr_next:
        lda PTR
        clc
        adc #8
        sta PTR
        bcc :+
        inc PTR + 1
:       rts

; A = high byte of a velocity -> $FF if negative, else 0
sign:   and #$80
        beq :+
        lda #$FF
:       rts

show_hits:
        ldx #0
        ldy #1
:       lda hits,y
        lsr
        lsr
        lsr
        lsr
        ora #$30
        sta $0400 + 35,x
        inx
        lda hits,y
        and #$0F
        ora #$30
        sta $0400 + 35,x
        inx
        dey
        bpl :-
        rts

.rodata
title:  .byte "BULLET STORM   128 SPRITES    HITS 0000", 0

.bss
nspr:       .res 1                  ; sprite entries in use (the ship and the bullets)
px:         .res 1
pdir:       .res 1
budget:     .res 1
arm:        .res 1
base_angle: .res 1
hits:       .res 2
