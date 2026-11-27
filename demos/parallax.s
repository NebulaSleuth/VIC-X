; parallax.s - Parallax world: two 256-colour tile layers scrolling at
; different speeds behind a normal VIC-II score bar.
;
; Layer 1 (back): mountains and sky, 8x8 8-bit tiles, scrolls 1 pixel every
; 2 frames.  Layer 0 (front): hills and trees with transparent sky, 1 pixel
; per frame.  Both maps are 128x32 tiles (1024 pixels wide, seamless), so
; the scroll registers just count up and the map wraps.  The artwork was
; made with Nano Banana (see art/).  The VIC-II's text rows
; 0-2 are a score bar: CTRL bit 4 is off for those lines (raster split), so
; the VIC-II background covers the layers there, and on below.  The bar
; also shows the CPU load: the share of each frame the demo's own code uses.

NEED_XRAM_MB = 2
NEED_FEAT    = VICX_FEAT_TILES | VICX_FEAT_BLITTER
CPU_TEXT     = $0400 + 1 * 40 + 16  ; in the score bar
.include "demo.inc"
.include "assets.inc"

BACK_TILES_V  = $00000          ; up to 20 KB
FRONT_TILES_V = $05000          ; up to 48 KB
BACK_MAP_V    = $11000          ; 8 KB each
FRONT_MAP_V   = $13000
.assert BACK_TILES_V + BACK_TILES_LEN <= FRONT_TILES_V, error, "back tiles overrun the front tiles"
.assert FRONT_TILES_V + FRONT_TILES_LEN <= BACK_MAP_V, error, "front tiles overrun the back map"
.assert BACK_MAP_V + BACK_MAP_LEN <= FRONT_MAP_V, error, "back map overruns the front map"

.code
main:
        ; text screen: blue background, white text, score bar on row 1
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
        lda #6
        sta $D021
        PRINT_AT 1, title

        lda #0
        sta VICX_CTRL
        XRAM_TO_VRAM BACK_TILES, BACK_TILES_V, BACK_TILES_LEN
        XRAM_TO_VRAM FRONT_TILES, FRONT_TILES_V, FRONT_TILES_LEN
        XRAM_TO_VRAM BACK_MAP, BACK_MAP_V, BACK_MAP_LEN
        XRAM_TO_VRAM FRONT_MAP, FRONT_MAP_V, FRONT_MAP_LEN
        XRAM_TO_VRAM BACK_PAL, VICX_PALETTE + 16 * 4, BACK_PAL_LEN
        XRAM_TO_VRAM FRONT_PAL, VICX_PALETTE + 112 * 4, FRONT_PAL_LEN
        LAYER_SET VICX_LAYER0, VICX_LMODE_TILE8, VICX_MAP_W128 | VICX_MAP_H32, FRONT_MAP_V, FRONT_TILES_V, 0, 0, 0, 0
        ; scroll Y 40 lifts the mountains above the front hills; the empty map
        ; rows that come into view at the bottom stay behind the hills
        LAYER_SET VICX_LAYER1, VICX_LMODE_TILE8, VICX_MAP_W128 | VICX_MAP_H32, BACK_MAP_V, BACK_TILES_V, 0, 40, 0, 0

        lda #0
        sta front_x
        sta front_x + 1
        sta back_x
        sta back_x + 1
        sta frame
        sta score
        sta score + 1
        sta score + 2

loop:
        ; score bar: the VIC-II background covers the layers on text rows 0-2
        ldx #40
        jsr wait_line
        lda #VICX_CTRL_L0 | VICX_CTRL_L1
        sta VICX_CTRL
        ldx #74                         ; row 3 starts at line 75
        jsr wait_line
        lda #VICX_CTRL_L0 | VICX_CTRL_L1 | VICX_CTRL_BGTRANS
        sta VICX_CTRL

        ldx #251                        ; below the display window
        jsr wait_line
        jsr cpu_start

        ; front layer: 1 pixel per frame
        inc front_x
        bne :+
        inc front_x + 1
:       VICX_P0_SET VICX_LAYER0 + VICX_L_SCROLLX, VICX_STEP_1
        lda front_x
        sta VICX_P0_DATA
        lda front_x + 1
        sta VICX_P0_DATA

        ; back layer: 1 pixel every second frame
        inc frame
        lda frame
        and #1
        bne :++
        inc back_x
        bne :+
        inc back_x + 1
:       VICX_P0_SET VICX_LAYER1 + VICX_L_SCROLLX, VICX_STEP_1
        lda back_x
        sta VICX_P0_DATA
        lda back_x + 1
        sta VICX_P0_DATA
:
        ; score + 1 (BCD), shown on row 1 from column 8
        sed
        clc
        lda score
        adc #1
        sta score
        lda score + 1
        adc #0
        sta score + 1
        lda score + 2
        adc #0
        sta score + 2
        cld
        ldx #0
        ldy #2
:       lda score,y
        lsr
        lsr
        lsr
        lsr
        ora #$30
        sta $0400 + 40 + 8,x
        inx
        lda score,y
        and #$0F
        ora #$30
        sta $0400 + 40 + 8,x
        inx
        dey
        bpl :-

        jsr cpu_end
        jmp loop

.rodata
title:  .byte "  SCORE 000000          VIC-X PARALLAX", 0

.bss
front_x: .res 2
back_x:  .res 2
frame:   .res 1
score:   .res 3
