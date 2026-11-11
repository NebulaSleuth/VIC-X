; t17_scroll - tile layer scrolling: scroll X/Y wrap around the map in
; both directions.  Bits 12-15 are set and have no effect (the widest map
; is 4096 pixels, so they could never be seen).
;
; 8-bit 8x8 tiles, map 32x32 (256x256 pixels) at VRAM $00000, tiles at
; $01000: tile 0 = colour 40, 1 = 41, 2 = 42, 3 = 43 (all solid).  Map: all
; tile 0, except (5,30) = 1, (31,31) = 2, (0,0) = 3.
; Scroll X = $F02B (43), scroll Y = $A0F2 (242).  Window pixel (x,y) shows
; map pixel ((x + 43) mod 256, (y + 242) mod 256):
;   tile (5,30)  at window x 0-4,     y 0-5
;   tile (31,31) at window x 205-212, y 6-13
;   tile (0,0)   at window x 213-220, y 14-21 (wrapped in X and Y)
; Window (0,0) is screenshot (32,35).
;
; RUN: -vicx
; PIXEL: 32 35 FF0000
; PIXEL: 36 40 FF0000
; PIXEL: 37 35 404040
; PIXEL: 36 41 404040
; PIXEL: 237 41 00FF00
; PIXEL: 244 48 00FF00
; PIXEL: 245 41 404040
; PIXEL: 245 49 0000FF
; PIXEL: 252 56 0000FF
; PIXEL: 253 56 404040
; PIXEL: 244 49 404040

.include "harness.inc"

MAP   = $00000
TILES = $01000

.code
main:
        CLEAR_SCREEN
        lda #$00
        sta $D020
        sta $D021

        VICX_UNLOCK_SEQ
        SET_PAL 40, $40, $40, $40
        SET_PAL 41, $FF, $00, $00
        SET_PAL 42, $00, $FF, $00
        SET_PAL 43, $00, $00, $FF

        VICX_P0_SET TILES, VICX_STEP_1
        lda #40
        P0_FILL 64
        lda #41
        P0_FILL 64
        lda #42
        P0_FILL 64
        lda #43
        P0_FILL 64

        VICX_P0_SET MAP, VICX_STEP_1
        P0_FILL16 $0000, 32 * 32
        POKE16 MAP + (30 * 32 + 5) * 2,  1
        POKE16 MAP + (31 * 32 + 31) * 2, 2
        POKE16 MAP,                      3

        LAYER_SET VICX_LAYER0, VICX_LMODE_TILE8, VICX_MAP_W32 | VICX_MAP_H32, MAP, TILES, $F02B, $A0F2, 0, 0
        lda #VICX_CTRL_L0 | VICX_CTRL_BGTRANS
        sta VICX_CTRL

        WAIT_FRAMES 3
        PASS
