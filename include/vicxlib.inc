; vicxlib.inc - ca65 helper macros for VIC-X programs
;
; Port 0 helpers for VRAM and the register space, palette, layer setup,
; sprite table entries and DMA descriptors.  Include after vicx.inc.
; Unless noted, the macros use port 0 and A; VIC-X must be unlocked.

.ifndef VICXLIB_INC_INCLUDED
VICXLIB_INC_INCLUDED = 1

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

; Write a whole sprite table entry.  `xh' = size and flip bits (VICX_SW_*,
; VICX_SH_*, VICX_S_FLIP*), `yh' = VICX_S_ON / VICX_S_BEHIND / groups,
; `pat' = pattern VRAM address (a multiple of 32), `attr' = VICX_S_ATTR.
; Uses A.
.macro SPRITE entry, xpos, ypos, xh, yh, pat, attr
        VICX_P0_SET VICX_SPRITES + (entry) * 8, VICX_STEP_1
        lda #<(xpos)
        sta VICX_P0_DATA
        lda #(((xpos) >> 8) & 3) | (xh)
        sta VICX_P0_DATA
        lda #<(ypos)
        sta VICX_P0_DATA
        lda #(((ypos) >> 8) & 3) | (yh)
        sta VICX_P0_DATA
        lda #<((pat) / 32)
        sta VICX_P0_DATA
        lda #>((pat) / 32)
        sta VICX_P0_DATA
        lda #(attr)
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
.endmacro

; Write the first 21 bytes of DMA descriptor n.  Uses A.
.macro DMA_DESC n, op, flags, src, dst, len, height, sstride, dstride, fill, trans, next
        VICX_P0_SET VICX_DMADESC + (n) * 32, VICX_STEP_1
        lda #(op)
        sta VICX_P0_DATA
        lda #(flags)
        sta VICX_P0_DATA
        lda #<(src)
        sta VICX_P0_DATA
        lda #>(src)
        sta VICX_P0_DATA
        lda #(((src) >> 16) & $FF)
        sta VICX_P0_DATA
        lda #(((src) >> 24) & $FF)
        sta VICX_P0_DATA
        lda #<(dst)
        sta VICX_P0_DATA
        lda #>(dst)
        sta VICX_P0_DATA
        lda #(((dst) >> 16) & $FF)
        sta VICX_P0_DATA
        lda #(((dst) >> 24) & $FF)
        sta VICX_P0_DATA
        lda #<(len)
        sta VICX_P0_DATA
        lda #>(len)
        sta VICX_P0_DATA
        lda #<(height)
        sta VICX_P0_DATA
        lda #>(height)
        sta VICX_P0_DATA
        lda #<(sstride)
        sta VICX_P0_DATA
        lda #>(sstride)
        sta VICX_P0_DATA
        lda #<(dstride)
        sta VICX_P0_DATA
        lda #>(dstride)
        sta VICX_P0_DATA
        lda #(fill)
        sta VICX_P0_DATA
        lda #(trans)
        sta VICX_P0_DATA
        lda #(next)
        sta VICX_P0_DATA
.endmacro

; Wait until the DMA engine is idle.  Uses A.
.macro DMA_WAIT
        .local w
w:      lda VICX_DMA_CMD
        bmi w
.endmacro

; Read the byte at a port address into A.
.macro PEEK_AT addr
        VICX_P0_SET addr, VICX_STEP_0
        lda VICX_P0_DATA
.endmacro

.endif
