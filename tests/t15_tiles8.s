; t15_tiles8 - layer 0 as 8-bit 8x8 tiles: map entries, flips, tile
; numbers above 255, colour 0 transparent, map wrap.
;
; Map 32x32 at VRAM $00000, tile data at $01000 (64 bytes per tile).
; Tile 0 is all colour 0 (transparent).  Tile 1 is colour 40 with marks:
; pixel (0,0) = 41, (7,0) = 42, (0,7) = 43.  Tile 257 is all 44.
; Every map entry is tile 1, except in map row 0:
;   tx 1 = tile 1 flipped in X, tx 2 = tile 1 flipped in Y,
;   tx 3 = tile 0, tx 4 = tile 257, tx 5 = tile 1 with palette bank bits
;   (ignored for 8-bit tiles).
; The map is 256 pixels wide, so window x 256 shows map x 0 again.
; $D021 = black.  Window (0,0) is screenshot (32,35).
;
; RUN: -vicx
; PIXEL: 32 35 FF0000
; PIXEL: 39 35 00FF00
; PIXEL: 32 42 0000FF
; PIXEL: 33 36 404040
; PIXEL: 40 35 00FF00
; PIXEL: 47 35 FF0000
; PIXEL: 47 42 0000FF
; PIXEL: 48 35 0000FF
; PIXEL: 48 42 FF0000
; PIXEL: 55 42 00FF00
; PIXEL: 56 35 000000
; PIXEL: 63 42 000000
; PIXEL: 64 38 FFFF00
; PIXEL: 72 35 FF0000
; PIXEL: 32 43 FF0000
; PIXEL: 288 35 FF0000
; PIXEL: 295 35 00FF00

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
        SET_PAL 44, $FF, $FF, $00

        ; tiles 0 and 1
        VICX_P0_SET TILES, VICX_STEP_1
        lda #0
        P0_FILL 64
        lda #40
        P0_FILL 64
        VICX_P0_SET TILES + 64 + 0, VICX_STEP_0
        lda #41
        sta VICX_P0_DATA
        VICX_P0_SET TILES + 64 + 7, VICX_STEP_0
        lda #42
        sta VICX_P0_DATA
        VICX_P0_SET TILES + 64 + 56, VICX_STEP_0
        lda #43
        sta VICX_P0_DATA
        ; tile 257
        VICX_P0_SET TILES + 257 * 64, VICX_STEP_1
        lda #44
        P0_FILL 64

        ; map
        VICX_P0_SET MAP, VICX_STEP_1
        P0_FILL16 $0001, 32 * 32
        POKE16 MAP + 2,  $0001 | VICX_TILE_FLIPX
        POKE16 MAP + 4,  $0001 | VICX_TILE_FLIPY
        POKE16 MAP + 6,  $0000
        POKE16 MAP + 8,  257
        POKE16 MAP + 10, $0001 | (15 * VICX_TILE_BANK)

        LAYER_SET VICX_LAYER0, VICX_LMODE_TILE8, VICX_MAP_W32 | VICX_MAP_H32, MAP, TILES, 0, 0, 0, 0
        lda #VICX_CTRL_L0 | VICX_CTRL_BGTRANS
        sta VICX_CTRL

        WAIT_FRAMES 3
        PASS
