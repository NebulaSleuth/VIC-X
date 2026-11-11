; t16_tiles4 - layer 1 alone, 4-bit 16x16 tiles with palette banks, on a
; map 64 tiles wide.
;
; Map at VRAM $02000 (64x32), tile data at $03000 (128 bytes per tile, high
; nibble = left pixel).  Tile 0 is all 0.  Tile 1 is all $12 (pixels 1, 2)
; except byte 0 = $30 (pixel 0 = 3, pixel 1 = 0).  A 4-bit pixel n in bank b
; is palette entry b*16 + n; n = 0 is transparent.
; Map: (0,0) = tile 1 bank 2; (1,0) = tile 1 bank 5 flipped in X;
; (0,1) = tile 1 bank 3; the rest tile 0.  Entry 32 of row 0 is a decoy
; (tile 1, bank 7) that would show at (0,1) if the map were 32 wide.
; $D021 = black.  Window (0,0) is screenshot (32,35).
;
; RUN: -vicx
; PIXEL: 32 35 0000FF
; PIXEL: 33 35 000000
; PIXEL: 34 35 FF0000
; PIXEL: 35 35 00FF00
; PIXEL: 32 36 FF0000
; PIXEL: 47 50 00FF00
; PIXEL: 63 35 FF00FF
; PIXEL: 62 35 000000
; PIXEL: 48 35 FFFF00
; PIXEL: 32 51 FFFFFF
; PIXEL: 34 51 00FFFF
; PIXEL: 32 67 000000
; PIXEL: 64 35 000000

.include "harness.inc"

MAP   = $02000
TILES = $03000

.code
main:
        CLEAR_SCREEN
        lda #$00
        sta $D020
        sta $D021

        VICX_UNLOCK_SEQ
        SET_PAL 33, $FF, $00, $00       ; bank 2: 1, 2, 3
        SET_PAL 34, $00, $FF, $00
        SET_PAL 35, $00, $00, $FF
        SET_PAL 49, $00, $FF, $FF       ; bank 3: 1, 3
        SET_PAL 51, $FF, $FF, $FF
        SET_PAL 82, $FF, $FF, $00       ; bank 5: 2, 3
        SET_PAL 83, $FF, $00, $FF

        VICX_P0_SET TILES, VICX_STEP_1
        lda #$00
        P0_FILL 128
        lda #$12
        P0_FILL 128
        VICX_P0_SET TILES + 128, VICX_STEP_0
        lda #$30
        sta VICX_P0_DATA

        VICX_P0_SET MAP, VICX_STEP_1
        P0_FILL16 $0000, 64 * 32
        POKE16 MAP + 0,          $0001 | (2 * VICX_TILE_BANK)
        POKE16 MAP + 2,          $0001 | (5 * VICX_TILE_BANK) | VICX_TILE_FLIPX
        POKE16 MAP + 64 * 2,     $0001 | (3 * VICX_TILE_BANK)
        POKE16 MAP + 32 * 2,     $0001 | (7 * VICX_TILE_BANK)

        LAYER_SET VICX_LAYER1, VICX_LMODE_TILE4 | VICX_LMODE_TILE16, VICX_MAP_W64 | VICX_MAP_H32, MAP, TILES, 0, 0, 0, 0
        lda #VICX_CTRL_L1 | VICX_CTRL_BGTRANS
        sta VICX_CTRL

        WAIT_FRAMES 3
        PASS
