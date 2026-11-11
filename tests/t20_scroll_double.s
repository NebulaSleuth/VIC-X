; t20_scroll_double - with double-width pixels, scroll X counts layer
; pixels: one step moves the picture 2 screen pixels.
;
; 8-bit 8x8 tiles, map 32x32 at VRAM $00000, tiles at $01000: tile 0 =
; colour 40, tile 1 = colour 41 (solid).  Map: all tile 0 except (1,0) = 1.
; Double width, scroll X = 4: window pixel x shows layer x (x >> 1) + 4, so
; tile (1,0) (layer x 8-15) covers window x 8-23.  Counting screen pixels
; instead would put it at window x 12-27.  Window (0,0) is screenshot (32,35).
;
; RUN: -vicx
; PIXEL: 39 35 404040
; PIXEL: 40 35 FF0000
; PIXEL: 55 35 FF0000
; PIXEL: 56 35 404040

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

        VICX_P0_SET TILES, VICX_STEP_1
        lda #40
        P0_FILL 64
        lda #41
        P0_FILL 64
        VICX_P0_SET MAP, VICX_STEP_1
        P0_FILL16 $0000, 32 * 32
        POKE16 MAP + 2, 1

        LAYER_SET VICX_LAYER0, VICX_LMODE_TILE8 | VICX_LMODE_DOUBLE, VICX_MAP_W32 | VICX_MAP_H32, MAP, TILES, 4, 0, 0, 0
        lda #VICX_CTRL_L0 | VICX_CTRL_BGTRANS
        sta VICX_CTRL

        WAIT_FRAMES 3
        PASS
