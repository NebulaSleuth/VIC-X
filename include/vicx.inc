; vicx.inc - VIC-X register names for ca65
;
; Follows the VIC-X spec register map (draft, spec rev 30, 2026-11-10).
; Direct registers exist only after the unlock sequence; while locked,
; $D040-$D06F are plain VIC-II mirrors of $D000-$D02F.

.ifndef VICX_INC_INCLUDED
VICX_INC_INCLUDED = 1

; --- Unlock -------------------------------------------------------------
VICX_UNLOCK     = $D06F         ; write $56,$58,$21 ("VX!") to unlock, $00 to relock
VICX_KEY1       = $56           ; 'V'
VICX_KEY2       = $58           ; 'X'
VICX_KEY3       = $21           ; '!'
VICX_RELOCK     = $00

; --- Direct registers ($D040-$D05F) -------------------------------------
VICX_ID0        = $D040         ; R  $56
VICX_ID1        = $D041         ; R  $58
VICX_VERSION    = $D042         ; R  spec version, major in high nibble
VICX_CAP_VRAM   = $D043         ; R  VRAM size in 8 KB units ($10 = 128 KB)
VICX_CAP_XRAM   = $D044         ; R  XRAM size in MB
VICX_CAP_SPR    = $D045         ; R  sprite table entries
VICX_CAP_SPRLINE = $D046        ; R  sprites per raster line
VICX_CAP_FEAT   = $D047         ; R  feature bits (VICX_FEAT_*)
VICX_CTRL       = $D048         ; RW control bits (VICX_CTRL_*)
VICX_IRQ_EN     = $D049         ; RW IRQ enable (VICX_IRQ_*)
VICX_IRQ_STAT   = $D04A         ; RW IRQ status, write 1 to clear
VICX_FRAME      = $D04B         ; R  frame counter, wraps at 256

VICX_P0_ADDR    = $D04C         ; RW port 0 address, 18 bits, little endian
VICX_P0_ADDRL   = $D04C         ;    bits 0-7
VICX_P0_ADDRM   = $D04D         ;    bits 8-15
VICX_P0_ADDRH   = $D04E         ;    bits 0-1: addr 16-17; bits 3-7: step code
VICX_P0_DATA    = $D04F         ; RW read/write at port 0, then step

VICX_P1_ADDR    = $D050
VICX_P1_ADDRL   = $D050
VICX_P1_ADDRM   = $D051
VICX_P1_ADDRH   = $D052
VICX_P1_DATA    = $D053

VICX_W0_PAGEL   = $D054         ; RW window 0 page bits 0-7
VICX_W0_PAGEH   = $D055         ; RW window 0 page bits 8-10
VICX_W0_SLOT    = $D056         ; RW bits 0-2 slot, bit 7 enable
VICX_W1_PAGEL   = $D057
VICX_W1_PAGEH   = $D058
VICX_W1_SLOT    = $D059
VICX_DMA_CMD    = $D05A         ; W start descriptor 0-3; R bit 7 busy

; --- CTRL bits ----------------------------------------------------------
VICX_CTRL_L0     = $01          ; layer 0 on
VICX_CTRL_L1     = $02          ; layer 1 on
VICX_CTRL_SPR    = $04          ; sprite engine on
VICX_CTRL_PALMAP = $08          ; VIC-II colours through palette entries 0-15
VICX_CTRL_BGTRANS = $10         ; VIC-II background colour transparent

; --- CAP_FEAT bits ------------------------------------------------------
VICX_FEAT_TILES   = $01
VICX_FEAT_BITMAP  = $02
VICX_FEAT_SPRITES = $04
VICX_FEAT_BLITTER = $08
VICX_FEAT_WINDOWS = $10

; --- IRQ bits -----------------------------------------------------------
VICX_IRQ_SPRCOL = $01
VICX_IRQ_DMA    = $02
VICX_IRQ_FRAME  = $04

; --- Port step codes (value for bits 3-7 of Px_ADDRH) -------------------
; Step index n (0-15) goes in bits 3-6; bit 7 steps backwards.
VICX_STEP_0     = 0  << 3
VICX_STEP_1     = 1  << 3
VICX_STEP_2     = 2  << 3
VICX_STEP_4     = 3  << 3
VICX_STEP_8     = 4  << 3
VICX_STEP_16    = 5  << 3
VICX_STEP_32    = 6  << 3
VICX_STEP_40    = 7  << 3
VICX_STEP_64    = 8  << 3
VICX_STEP_80    = 9  << 3
VICX_STEP_128   = 10 << 3
VICX_STEP_160   = 11 << 3
VICX_STEP_256   = 12 << 3
VICX_STEP_320   = 13 << 3
VICX_STEP_512   = 14 << 3
VICX_STEP_640   = 15 << 3
VICX_STEP_BACK  = $80

; --- Port address space -------------------------------------------------
VICX_VRAM_BASE  = $00000        ; $00000-$1FFFF VRAM
VICX_REG_BASE   = $20000        ; $20000 and up: register space
VICX_PALETTE    = $20000        ; 256 entries x 4 bytes (R, G, B, spare)
VICX_SPRITES    = $20400        ; 128 entries x 8 bytes
VICX_LAYER0     = $20800        ; 32 bytes
VICX_LAYER1     = $20820        ; 32 bytes
VICX_MIXSETUP   = $20840        ; layer order and sprite engine setup
VICX_DMADESC    = $20880        ; 4 descriptors x 32 bytes
VICX_COLLIST    = $20900        ; collision list

; --- Macros -------------------------------------------------------------

; Unlock VIC-X. Run with interrupts disabled so nothing writes in between.
.macro VICX_UNLOCK_SEQ
        lda #VICX_KEY1
        sta VICX_UNLOCK
        lda #VICX_KEY2
        sta VICX_UNLOCK
        lda #VICX_KEY3
        sta VICX_UNLOCK
.endmacro

.macro VICX_LOCK_SEQ
        lda #VICX_RELOCK
        sta VICX_UNLOCK
.endmacro

; Set port 0 to a 18-bit address with a step code (VICX_STEP_* | VICX_STEP_BACK).
.macro VICX_P0_SET addr, step
        lda #<(addr)
        sta VICX_P0_ADDRL
        lda #>(addr)
        sta VICX_P0_ADDRM
        lda #(((addr) >> 16) & $03) | (step)
        sta VICX_P0_ADDRH
.endmacro

.endif
