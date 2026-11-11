; gallery.s - Gallery: 256-colour pictures streamed from XRAM, double
; buffered, with palette fades.
;
; Four 320x200 8-bit pictures and their fade palettes (16 levels, black to
; full colour) sit in XRAM.  VRAM holds two bitmaps, $00000 and $10000:
; while one is shown, DMA loads the next picture into the other in the
; background.  Each picture fades in (one fade level per frame, copied by
; DMA into the palette), stays, fades out, and the layer base flips to the
; other buffer.  DMA does all the copying; the CPU only starts it, as the
; CPU load on the bottom row shows.

NEED_XRAM_MB = 2
CPU_TEXT     = $0400 + 24 * 40      ; bottom row
.include "demo.inc"
.include "assets.inc"

BUF0    = $00000
BUF1    = $10000
HOLD    = 150                   ; frames each picture stays
LEVELS  = 16
PALDST  = VICX_PALETTE + 16 * 4 ; the pictures use entries 16-255 (0-15 stay the VIC-II colours)

D_SRC   = $F0                   ; 3 bytes
D_DST   = $F3                   ; 3 bytes
D_LEN   = $F6                   ; 2 bytes

; Write descriptor n: copy D_LEN bytes from XRAM D_SRC to port space D_DST.
.macro WRITE_DESC n
        VICX_P0_SET VICX_DMADESC + (n) * 32, VICX_STEP_1
        lda #VICX_DMA_COPY
        sta VICX_P0_DATA
        lda #VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM
        sta VICX_P0_DATA
        lda D_SRC
        sta VICX_P0_DATA
        lda D_SRC + 1
        sta VICX_P0_DATA
        lda D_SRC + 2
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        lda D_DST
        sta VICX_P0_DATA
        lda D_DST + 1
        sta VICX_P0_DATA
        lda D_DST + 2
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        lda D_LEN
        sta VICX_P0_DATA
        lda D_LEN + 1
        sta VICX_P0_DATA
        lda #0
        ldx #8                          ; +12-+19
:       sta VICX_P0_DATA
        dex
        bne :-
        lda #VICX_DMA_NONE
        sta VICX_P0_DATA                ; +20
.endmacro

.code
main:
        ldx #0
        lda #$20
:       sta $0400,x
        sta $0500,x
        sta $0600,x
        sta $06E8,x
        inx
        bne :-
        lda #0
        sta $D020
        sta $D021
        sta VICX_CTRL

        lda #0
        sta cur
        sta buf
        jsr load_picture                ; picture 0 -> buffer 0
        DMA_WAIT
        lda #0
        sta level
        jsr set_palette                 ; black
        DMA_WAIT
        LAYER_SET VICX_LAYER0, VICX_LMODE_BITMAP8, 0, BUF0, 0, 0, 0, 320, 0
        lda #VICX_CTRL_L0 | VICX_CTRL_BGTRANS
        sta VICX_CTRL
        ldx #39                         ; white text on the bottom row
        lda #1
:       sta $D800 + 24 * 40,x
        dex
        bpl :-
        jsr cpu_start

show:
        ; fade in
        lda #0
        sta level
@in:    jsr frame_start
        jsr set_palette
        inc level
        lda level
        cmp #LEVELS
        bne @in

        ; load the next picture into the other buffer, in the background
        lda cur
        clc
        adc #1
        and #3
        sta next
        lda buf
        eor #1
        sta other
        jsr load_next

        ldy #HOLD
@hold:  jsr frame_start
        dey
        bne @hold

        ; fade out
        lda #LEVELS - 1
        sta level
@out:   jsr frame_start
        jsr set_palette
        dec level
        bpl @out

        ; show the other buffer (the screen is black now)
        DMA_WAIT
        lda next
        sta cur
        lda other
        sta buf
        VICX_P0_SET VICX_LAYER0 + VICX_L_BASE + 1, VICX_STEP_1
        lda #0
        sta VICX_P0_DATA                ; base bits 8-15
        lda buf
        sta VICX_P0_DATA                ; base bits 16-23: buffer 0 or 1
        jmp show

; End the last frame's CPU count, wait for the line after the display
; window and start the next count.
frame_start:
        jsr cpu_end
        ldx #251
        jsr wait_line
        jmp cpu_start

; DMA fade level `level' of picture `cur' into palette entries 16-255.
set_palette:
        ldx cur
        lda fad_lo,x
        sta D_SRC
        lda fad_mid,x
        sta D_SRC + 1
        lda fad_hi,x
        sta D_SRC + 2
        ldy level                       ; + level * level size
        beq @done
@add:   clc
        lda D_SRC
        adc lvl_lo,x
        sta D_SRC
        lda D_SRC + 1
        adc lvl_hi,x
        sta D_SRC + 1
        bcc :+
        inc D_SRC + 2
:       dey
        bne @add
@done:  lda #<PALDST
        sta D_DST
        lda #>PALDST
        sta D_DST + 1
        lda #^PALDST
        sta D_DST + 2
        lda lvl_lo,x
        sta D_LEN
        lda lvl_hi,x
        sta D_LEN + 1
        WRITE_DESC 0
        lda #0
        sta VICX_DMA_CMD
        rts

; DMA picture `cur' into buffer `buf' (used once at start).
load_picture:
        lda cur
        sta next
        lda buf
        sta other
        ; fall through

; DMA picture `next' into buffer `other' (background).
load_next:
        ldx next
        lda pix_lo,x
        sta D_SRC
        lda pix_mid,x
        sta D_SRC + 1
        lda pix_hi,x
        sta D_SRC + 2
        lda #0
        sta D_DST
        sta D_DST + 1
        lda other                       ; $00000 or $10000
        sta D_DST + 2
        lda #<64000
        sta D_LEN
        lda #>64000
        sta D_LEN + 1
        WRITE_DESC 1
        lda #1
        sta VICX_DMA_CMD
        rts

.rodata
pix_lo:  .byte <PIC0_PIX, <PIC1_PIX, <PIC2_PIX, <PIC3_PIX
pix_mid: .byte >PIC0_PIX, >PIC1_PIX, >PIC2_PIX, >PIC3_PIX
pix_hi:  .byte ^PIC0_PIX, ^PIC1_PIX, ^PIC2_PIX, ^PIC3_PIX
fad_lo:  .byte <PIC0_FADES, <PIC1_FADES, <PIC2_FADES, <PIC3_FADES
fad_mid: .byte >PIC0_FADES, >PIC1_FADES, >PIC2_FADES, >PIC3_FADES
fad_hi:  .byte ^PIC0_FADES, ^PIC1_FADES, ^PIC2_FADES, ^PIC3_FADES
lvl_lo:  .byte <(PIC0_FADES_LEN / LEVELS), <(PIC1_FADES_LEN / LEVELS)
         .byte <(PIC2_FADES_LEN / LEVELS), <(PIC3_FADES_LEN / LEVELS)
lvl_hi:  .byte >(PIC0_FADES_LEN / LEVELS), >(PIC1_FADES_LEN / LEVELS)
         .byte >(PIC2_FADES_LEN / LEVELS), >(PIC3_FADES_LEN / LEVELS)

.bss
cur:    .res 1
next:   .res 1
buf:    .res 1
other:  .res 1
level:  .res 1
