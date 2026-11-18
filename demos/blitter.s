; blitter.s - Blitter: one scene per optional blitter operation.
;
; The demo reads CAP_BLIT and steps through the operations in the spec's
; order: expand, remap, scaled copy, direction, lists in VRAM.  A scene runs
; when the build has its operation; otherwise the bottom row names it and the
; panel says NOT IN THIS BUILD.  So far the demo has the expand scene:
;
;   - the space picture (from the bullets demo) in a double-buffered 8-bit
;     bitmap;
;   - a sine scroller of 16x16 letters, each one masked expand (0 bits leave
;     the picture alone), over a strip of the picture restored each frame;
;   - a panel of text scrolling up a pixel a frame, each line one opaque
;     expand in its own colour, the 0 bits in the panel's blue.
;
; The fonts are built at start from the C64's character ROM, at one bit per
; pixel, and put in XRAM: the 16x16 font (each ROM pixel doubled) and the
; panel's text, 36 characters a line, ten rows a line.

NEED_XRAM_MB = 2
CPU_TEXT     = $0400 + 24 * 40 + 32     ; bottom row, right
.include "demo.inc"
.include "assets.inc"
.include "tables.inc"

FONT_X  = $100000               ; XRAM: 64 glyphs of 16x16, 32 bytes each
CRED_X  = $101000               ; XRAM: the panel's lines, 360 bytes each
ROMCOPY = $4000                 ; the ROM's first 64 glyphs (512 bytes)
FONTBUF = $4200                 ; the 16x16 font while it is built (2 KB)
LINEBUF = $4A00                 ; one panel line while it is built (360 bytes)

STRIP_Y = 8                     ; the scroller's strip: rows 8-71
STRIP_H = 64
PANEL_X = 16
PANEL_Y = 88
PANEL_H = 104
PANEL_W = 288                   ; 36 bytes of font a row
PANEL_BG = 240
LINE_COL = 241                  ; 241-248
RAINBOW = 208                   ; 208-239
EXPAND_FRAMES = 750             ; 15 s
REMAP_FRAMES  = 600             ; 12 s
GREY_TBL = $0FA00               ; VRAM: the remap table (above buffer 0)
SPOT     = 80                   ; the spotlight's box
CARD_FRAMES   = 150             ; 3 s

; zero page
d_op    = $10                   ; the transfer for dma_go (descriptor 0)
d_fl    = $11
d_src   = $12                   ; 3 bytes
d_dst   = $15                   ; 3 bytes
d_w     = $18                   ; 2 bytes
d_h     = $1A
d_ss    = $1B                   ; 2 bytes
d_ds    = $1D                   ; 2 bytes
d_fill  = $1F
d_trans = $20
back    = $21                   ; buffer being drawn (0 or 1)
lvf     = $22                   ; FRAME at the last frame
tmr     = $23                   ; 2 bytes: frames left in the scene
xs      = $25                   ; 2 bytes: scroller position in pixels
phase   = $27
pl      = $28                   ; panel: first line shown
pr      = $29                   ; ... and its first row (0-9)
t0      = $2A
t1      = $2B
t2      = $2C
ptr     = $2D                   ; 2 bytes
cy      = $2F
rem     = $30
sl      = $31                   ; scroller slot
mi      = $32                   ; message index
cx      = $33                   ; 2 bytes
scn     = $35                   ; scene number
drawn   = $36
lb      = $37                   ; 2 bytes
d_tbl   = $39                   ; 3 bytes: the remap table (+21-+23)
pvx     = $3C                   ; 2 bytes: spotlight left x per buffer, $FF none
pvy     = $3E                   ; 2 bytes: ... and top y
sa      = $40                   ; spotlight path position

.code
main:
        lda #0
        sta $D020
        sta $D021
        sta VICX_CTRL
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
        lda #$15                        ; upper-case set
        sta $D018

        jsr build_fonts

        ; palette: the picture's colours, then the demo's own
        XRAM_TO_VRAM SPACE_PAL, VICX_PALETTE + 16 * 4, SPACE_PAL_LEN
        VICX_P0_SET VICX_PALETTE + RAINBOW * 4, VICX_STEP_1
        ldx #0
:       lda pal_extra,x
        sta VICX_P0_DATA
        inx
        cpx #PAL_EXTRA_N * 4
        bne :-

        ; both buffers: the picture, the bottom text row transparent
        XRAM_TO_VRAM SPACE_PIX, $00000, 64000
        XRAM_TO_VRAM SPACE_PIX, $10000, 64000
        DMA_DESC 0, VICX_DMA_FILL, VICX_DMA_DST_VRAM, 0, 192 * 320, 8 * 320, 0, 0, 0, 0, 0, 1
        DMA_DESC 1, VICX_DMA_FILL, VICX_DMA_DST_VRAM, 0, $10000 + 192 * 320, 8 * 320, 0, 0, 0, 0, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT

        LAYER_SET VICX_LAYER0, VICX_LMODE_BITMAP8, 0, $00000, 0, 0, 0, 320, 0
        lda #VICX_CTRL_L0 | VICX_CTRL_BGTRANS
        sta VICX_CTRL
        lda #1
        sta back                        ; buffer 0 shown, 1 drawn
        lda #0
        sta xs
        sta xs + 1
        sta phase
        sta pl
        sta pr
        sta scn
        lda VICX_FRAME
        sta lvf

; --- the scenes ------------------------------------------------------------
scene:
        jsr show_name
        ldx scn
        lda VICX_CAP_BLIT
        and scene_bit,x
        beq @card
        lda scene_lo,x
        sta @jmp + 1
        lda scene_hi,x
        sta @jmp + 2
@jmp:   jsr $FFFF
        jmp @next
@card:  jsr card
@next:  inc scn
        lda scn
        cmp #5
        bcc scene
        lda #0
        sta scn
        jmp scene

scene_bit: .byte VICX_BLIT_EXPAND, VICX_BLIT_REMAP, VICX_BLIT_SCALED
           .byte VICX_BLIT_DIRECTION, VICX_BLIT_LIST
scene_lo:  .byte <expand_scene, <remap_scene, <card, <card, <card
scene_hi:  .byte >expand_scene, >remap_scene, >card, >card, >card

; The scene's name on the bottom row (cols 0-30).
show_name:
        lda scn
        asl
        tax
        lda names,x
        sta ptr
        lda names + 1,x
        sta ptr + 1
        ldy #0
:       lda (ptr),y
        sta $0400 + 24 * 40,y
        iny
        cpy #31
        bne :-
        rts

names:  .word nm_expand, nm_remap, nm_scaled, nm_dir, nm_list
        .macro SCR text
        .repeat .strlen(text), i
            .if .strat(text, i) = ' '
                .byte $20
            .else
                .byte .strat(text, i) & $3F
            .endif
        .endrepeat
        .endmacro
nm_expand: SCR "EXPAND AND MASKED EXPAND       "
nm_remap:  SCR "REMAP                          "
nm_scaled: SCR "SCALED COPY                    "
nm_dir:    SCR "MIRROR AND BACKWARDS           "
nm_list:   SCR "LISTS IN VRAM                  "
txt_card:  SCR "NOT IN THIS BUILD"

; --- frames ------------------------------------------------------------------
; Wait for the next frame; show what was drawn (if anything), then measure.
frame:
:       lda VICX_FRAME
        cmp lvf
        beq :-
        sta lvf
        lda drawn
        beq :+
        VICX_P0_SET VICX_LAYER0 + VICX_L_BASE, VICX_STEP_1
        lda #0
        sta VICX_P0_DATA
        sta VICX_P0_DATA
        lda back
        sta VICX_P0_DATA
        eor #1
        sta back
:       lda #0
        sta drawn
        jmp cpu_start

; Both buffers: the picture's rows 0-191 (remapped through the table at d_tbl
; when A is VICX_DMA_REMAP, else copied).
pic_both:
        lda #VICX_DMA_COPY
pic_op: sta d_op
        lda #VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM
        sta d_fl
        lda #<SPACE_PIX
        sta d_src
        lda #>SPACE_PIX
        sta d_src + 1
        lda #^SPACE_PIX
        sta d_src + 2
        lda #0
        sta d_trans                     ; never in the picture (16-207)
        sta d_dst
        sta d_dst + 1
        sta d_dst + 2
        lda #<(192 * 320)
        sta d_w
        lda #>(192 * 320)
        sta d_w + 1
        jsr dma_go
        inc d_dst + 2
        jmp dma_go

; --- remap -----------------------------------------------------------------------
; The picture in dim greys (one remap per buffer), and a round spotlight in
; full colour moving over it: each frame one remap puts the grey back where
; the light was in this buffer, and ten copies draw it where it is now.
remap_scene:
        VICX_P0_SET GREY_TBL, VICX_STEP_1
        ldx #0
:       lda grey_table,x
        sta VICX_P0_DATA
        inx
        bne :-
        VICX_P0_SET VICX_PALETTE + RAINBOW * 4, VICX_STEP_1
        ldx #0
:       lda grey_pal,x
        sta VICX_P0_DATA
        inx
        cpx #32 * 4
        bne :-
        lda #<GREY_TBL
        sta d_tbl
        lda #>GREY_TBL
        sta d_tbl + 1
        lda #^GREY_TBL
        sta d_tbl + 2
        lda #VICX_DMA_REMAP
        jsr pic_op
        lda #$FF
        sta pvx
        sta pvx + 1
        lda #<REMAP_FRAMES
        sta tmr
        lda #>REMAP_FRAMES
        sta tmr + 1
@lp:    jsr frame
        ldx back                        ; grey again where it was
        lda pvx,x
        cmp #$FF
        beq @new
        sta cx
        lda #0
        sta cx + 1
        lda pvy,x
        sta cy
        lda #VICX_DMA_REMAP
        sta d_op
        lda #SPOT
        sta d_w
        sta d_h
        jsr box
@new:   ldx sa                          ; where it is now
        lda spot_x,x
        ldy back
        sta pvx,y
        lda spot_y,x
        sta pvy,y
        sta cy
        lda #0
        sta t2                          ; band
@band:  ldx t2
        ldy back
        lda pvx,y                       ; x = left + 40 - half width (to 300)
        clc
        adc #40
        sta cx
        lda #0
        adc #0
        sta cx + 1
        lda cx
        sec
        sbc spot_hw,x
        sta cx
        lda cx + 1
        sbc #0
        sta cx + 1
        lda spot_hw,x
        asl
        sta d_w
        lda #0
        rol
        sta d_w + 1
        lda #8
        sta d_h
        lda #VICX_DMA_COPY
        sta d_op
        jsr box_src
        lda cy
        clc
        adc #8
        sta cy
        inc t2
        lda t2
        cmp #10
        beq :+
        jmp @band
:       inc sa
        lda #1
        sta drawn
        jsr cpu_end
        jsr count
        beq :+
        jmp @lp
:       rts

; A 2D transfer of d_w x d_h from the picture at (cx, cy) to the same place
; in the drawn buffer, with operation d_op.
box:    lda #0
        sta d_w + 1
box_src:
        lda #VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM | VICX_DMA_2D
        sta d_fl
        lda #<320
        sta d_ss
        sta d_ds
        lda #>320
        sta d_ss + 1
        sta d_ds + 1
        lda #0
        sta d_trans
        ldx cy                          ; offset = cy * 320 + cx
        lda row_lo,x
        clc
        adc cx
        sta t0
        lda row_hi,x
        adc cx + 1
        sta t1
        lda t0
        sta d_dst
        clc
        adc #<SPACE_PIX
        sta d_src
        lda t1
        sta d_dst + 1
        adc #>SPACE_PIX
        sta d_src + 1
        lda #^SPACE_PIX
        adc #0
        sta d_src + 2
        lda back
        sta d_dst + 2
        jmp dma_go

; --- a scene this build lacks --------------------------------------------------
; The panel in plain blue in both buffers, NOT IN THIS BUILD over it.
card:
        lda back
        pha
        lda #0
        sta back
        jsr panel_clear
        lda #1
        sta back
        jsr panel_clear
        pla
        sta back
        ldx #16
:       lda txt_card,x
        sta $0400 + 17 * 40 + 11,x
        dex
        bpl :-
        lda #<CARD_FRAMES
        sta tmr
        lda #>CARD_FRAMES
        sta tmr + 1
@lp:    jsr frame
        jsr cpu_end
        jsr count
        bne @lp
        ldx #16
        lda #$20
:       sta $0400 + 17 * 40 + 11,x
        dex
        bpl :-
        rts

; Count tmr down; Z set when it reaches 0.
count:  lda tmr
        bne :+
        dec tmr + 1
:       dec tmr
        lda tmr
        ora tmr + 1
        rts

panel_clear:
        lda #VICX_DMA_FILL
        sta d_op
        lda #VICX_DMA_DST_VRAM | VICX_DMA_2D
        sta d_fl
        lda #PANEL_Y
        ldx #PANEL_X
        jsr dst_at
        lda #<PANEL_W
        sta d_w
        lda #>PANEL_W
        sta d_w + 1
        lda #PANEL_H
        sta d_h
        lda #<320
        sta d_ds
        lda #>320
        sta d_ds + 1
        lda #PANEL_BG
        sta d_fill
        jmp dma_go

; --- expand ------------------------------------------------------------------
expand_scene:
        jsr pic_both                    ; the picture in colour, rainbow palette
        VICX_P0_SET VICX_PALETTE + RAINBOW * 4, VICX_STEP_1
        ldx #0
:       lda pal_extra,x
        sta VICX_P0_DATA
        inx
        cpx #32 * 4
        bne :-
        lda #<EXPAND_FRAMES
        sta tmr
        lda #>EXPAND_FRAMES
        sta tmr + 1
@lp:    jsr frame
        jsr scroller
        jsr panel
        lda #1
        sta drawn
        jsr cpu_end
        jsr count
        bne @lp
        rts

; The scroller: restore the strip, then one masked expand per letter.
scroller:
        lda #VICX_DMA_COPY              ; the strip from the picture
        sta d_op
        lda #VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM
        sta d_fl
        lda #<(SPACE_PIX + STRIP_Y * 320)
        sta d_src
        lda #>(SPACE_PIX + STRIP_Y * 320)
        sta d_src + 1
        lda #^(SPACE_PIX + STRIP_Y * 320)
        sta d_src + 2
        lda #STRIP_Y
        ldx #0
        jsr dst_at
        lda #<(STRIP_H * 320)
        sta d_w
        lda #>(STRIP_H * 320)
        sta d_w + 1
        jsr dma_go

        lda #VICX_DMA_EXPAND_MASKED
        sta d_op
        lda #VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM | VICX_DMA_2D
        sta d_fl
        lda #16
        sta d_w
        sta d_h
        lda #0
        sta d_w + 1
        sta d_ss + 1
        lda #2
        sta d_ss
        lda #<320
        sta d_ds
        lda #>320
        sta d_ds + 1
        lda xs                          ; first letter: xs / 16
        sta t0
        lda xs + 1
        ldx #4
:       lsr
        ror t0
        dex
        bne :-
        lda t0
        sta mi
        lda #0
        sta sl
@slot:  lda sl                          ; x = slot * 16 - (xs & 15)
        asl
        asl
        asl
        asl
        sta cx
        lda #0
        rol
        sta cx + 1
        lda xs
        and #15
        sta t0
        lda cx
        sec
        sbc t0
        sta cx
        lda cx + 1
        sbc #0
        sta cx + 1
        bmi @skip                       ; off the left edge
        bne @hi
        jmp @on
@hi:    lda cx                          ; 256-304 is on screen
        cmp #305 - 256
        bcs @skip
@on:    ldx mi
        lda msg,x
        cmp #$20
        beq @skip
        ; source: FONT_X + code * 32
        sta t0
        lda #0
        sta t1
        ldx #5
:       asl t0
        rol t1
        dex
        bne :-
        lda t0
        sta d_src
        lda t1
        clc
        adc #>FONT_X
        sta d_src + 1
        lda #^FONT_X
        sta d_src + 2
        ; y = STRIP_Y + sine[(mi * 12 + phase) & 255]
        lda mi
        asl
        asl
        sta t0
        asl
        clc
        adc t0
        clc
        adc phase
        tax
        lda sine,x
        clc
        adc #STRIP_Y
        ldx cx
        jsr dst_at
        lda cx + 1                      ; x 256-304: + 256
        beq :+
        inc d_dst + 1
:       lda sl                          ; a moving rainbow
        asl
        clc
        adc phase
        lsr
        and #31
        clc
        adc #RAINBOW
        sta d_fill
        jsr dma_go
@skip:  inc mi                          ; next letter, wrapping the message
        lda mi
        cmp #MSG_LEN
        bcc :+
        lda #0
        sta mi
:       inc sl
        lda sl
        cmp #21
        bcs :+
        jmp @slot
:       ; on: two pixels a frame, the wave moves too
        lda xs
        clc
        adc #2
        sta xs
        bcc :+
        inc xs + 1
:       lda xs + 1
        cmp #>(MSG_LEN * 16)
        bne :+
        lda xs
        cmp #<(MSG_LEN * 16)
        bne :+
        lda #0
        sta xs
        sta xs + 1
:       lda phase
        clc
        adc #3
        sta phase
        rts

; The panel: one opaque expand per line (or part of one) shown.
panel:
        lda #VICX_DMA_EXPAND
        sta d_op
        lda #VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM | VICX_DMA_2D
        sta d_fl
        lda #<PANEL_W
        sta d_w
        lda #>PANEL_W
        sta d_w + 1
        lda #36
        sta d_ss
        lda #0
        sta d_ss + 1
        lda #<320
        sta d_ds
        lda #>320
        sta d_ds + 1
        lda #PANEL_BG
        sta d_trans
        lda #PANEL_Y
        sta cy
        lda #PANEL_H
        sta rem
        lda pl
        sta t2                          ; line
        lda pr
        sta t1                          ; first row in it
@band:  lda #10                         ; rows: 10 - first row, at most rem
        sec
        sbc t1
        cmp rem
        bcc :+
        lda rem
:       sta d_h
        ldx t2                          ; source: CRED_X + line * 360 + row * 36
        lda cred_lo,x
        sta d_src
        lda cred_hi,x
        sta d_src + 1
        lda #^CRED_X
        sta d_src + 2
        ldx t1
        lda d_src
        clc
        adc row36,x
        sta d_src
        lda d_src + 1
        adc row36h,x
        sta d_src + 1
        lda t2
        and #7
        clc
        adc #LINE_COL
        sta d_fill
        lda cy
        ldx #PANEL_X
        jsr dst_at
        jsr dma_go
        lda cy
        clc
        adc d_h
        sta cy
        lda rem
        sec
        sbc d_h
        sta rem
        beq :+
        lda #0
        sta t1
        inc t2
        jmp @band
:       inc pr                          ; up one row a frame
        lda pr
        cmp #10
        bcc :+
        lda #0
        sta pr
        inc pl
        lda pl
        cmp #CRED_LINES
        bcc :+
        lda #0
        sta pl
:       rts

row36:  .repeat 10, i
            .byte <(i * 36)
        .endrepeat
row36h: .repeat 10, i
            .byte >(i * 36)
        .endrepeat
cred_lo: .repeat CRED_ALL, i
            .byte <(CRED_X + i * 360)
        .endrepeat
cred_hi: .repeat CRED_ALL, i
            .byte >(CRED_X + i * 360)
        .endrepeat
.assert CRED_X + CRED_ALL * 360 < $110000, error, "the panel's lines leave XRAM bank $10"

; d_dst = the drawn buffer + line A * 320 + X
dst_at: sta t0
        stx t1
        tax
        lda row_lo,x
        clc
        adc t1
        sta d_dst
        lda row_hi,x
        adc #0
        sta d_dst + 1
        lda back
        sta d_dst + 2
        rts

row_lo: .repeat 200, i
            .byte <(i * 320)
        .endrepeat
row_hi: .repeat 200, i
            .byte >(i * 320)
        .endrepeat

; Run the transfer in d_* with descriptor 0 and wait for it.
dma_go: VICX_P0_SET VICX_DMADESC, VICX_STEP_1
        ldx #0
:       lda d_op,x                      ; +0 op, +1 flags
        sta VICX_P0_DATA
        inx
        cpx #2
        bne :-
        lda d_src
        sta VICX_P0_DATA
        lda d_src + 1
        sta VICX_P0_DATA
        lda d_src + 2
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        lda d_dst
        sta VICX_P0_DATA
        lda d_dst + 1
        sta VICX_P0_DATA
        lda d_dst + 2
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        lda d_w
        sta VICX_P0_DATA
        lda d_w + 1
        sta VICX_P0_DATA
        lda d_h
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        lda d_ss
        sta VICX_P0_DATA
        lda d_ss + 1
        sta VICX_P0_DATA
        lda d_ds
        sta VICX_P0_DATA
        lda d_ds + 1
        sta VICX_P0_DATA
        lda d_fill
        sta VICX_P0_DATA
        lda d_trans
        sta VICX_P0_DATA
        lda #VICX_DMA_NONE
        sta VICX_P0_DATA
        lda d_tbl                       ; +21-+23: remap table
        sta VICX_P0_DATA
        lda d_tbl + 1
        sta VICX_P0_DATA
        lda d_tbl + 2
        sta VICX_P0_DATA
        lda #0
        sta VICX_DMA_CMD
:       lda VICX_DMA_CMD
        bmi :-
        rts

; --- the fonts ------------------------------------------------------------------
; The ROM's 64 upper-case glyphs, doubled into the 16x16 font, and the panel's
; lines; both into XRAM by DMA from C64 RAM.
build_fonts:
        lda $01
        pha
        lda #$33                        ; character ROM at $D000
        sta $01
        ldx #0
:       lda $D000,x
        sta ROMCOPY,x
        lda $D100,x
        sta ROMCOPY + $100,x
        inx
        bne :-
        pla
        sta $01

        ; 16x16: each ROM row doubled across and down
        lda #<ROMCOPY
        sta ptr
        lda #>ROMCOPY
        sta ptr + 1
        lda #<FONTBUF
        sta bf_out + 1
        lda #>FONTBUF
        sta bf_out + 2
bf_rom:   ldy #0
        lda (ptr),y
        sta t0
        lsr
        lsr
        lsr
        lsr
        tay
        lda dbl,y                       ; left half
        sta t1
        lda t0
        and #15
        tay
        lda dbl,y                       ; right half
        jsr bf_put                        ; t1, A twice
        inc ptr
        bne :+
        inc ptr + 1
:       lda ptr
        cmp #<(ROMCOPY + 512)
        bne bf_rom
        lda ptr + 1
        cmp #>(ROMCOPY + 512)
        bne bf_rom
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_C64 | VICX_DMA_DST_XRAM, FONTBUF, FONT_X, 2048, 0, 0, 0, 0, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT

        ; the panel's lines: 10 rows of 36 bytes, rows 8-9 empty
        lda #<cred_text
        sta ptr
        lda #>cred_text
        sta ptr + 1
        lda #0
        sta t2                          ; line
bf_line:  lda #0
        sta t1                          ; row
        lda #<LINEBUF
        sta lb
        lda #>LINEBUF
        sta lb + 1
bf_row:   ldy #0
bf_ch:    lda t1
        cmp #8
        bcs bf_blank
        lda (ptr),y                     ; ROM byte: code * 8 + row
        sta t0
        lda #0
        asl t0
        rol
        asl t0
        rol
        asl t0
        rol
        tax
        lda t0
        ora t1
        sta bf_rd + 1
        txa
        clc
        adc #>ROMCOPY
        sta bf_rd + 2
bf_rd:    lda ROMCOPY
        jmp bf_st
bf_blank: lda #0
bf_st:    sta (lb),y
        iny
        cpy #36
        bne bf_ch
        lda lb                          ; next row of the buffer
        clc
        adc #36
        sta lb
        bcc :+
        inc lb + 1
:       inc t1
        lda t1
        cmp #10
        bne bf_row
        ; LINEBUF -> CRED_X + line * 360
        VICX_P0_SET VICX_DMADESC, VICX_STEP_1
        lda #VICX_DMA_COPY
        sta VICX_P0_DATA
        lda #VICX_DMA_SRC_C64 | VICX_DMA_DST_XRAM
        sta VICX_P0_DATA
        lda #<LINEBUF
        sta VICX_P0_DATA
        lda #>LINEBUF
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        sta VICX_P0_DATA
        ldx t2
        lda cred_lo,x
        sta VICX_P0_DATA
        lda cred_hi,x
        sta VICX_P0_DATA
        lda #^CRED_X
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        lda #<360
        sta VICX_P0_DATA
        lda #>360
        sta VICX_P0_DATA
        lda #0
        ldx #8
:       sta VICX_P0_DATA
        dex
        bne :-
        lda #VICX_DMA_NONE
        sta VICX_P0_DATA
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        lda ptr                         ; next line of text
        clc
        adc #36
        sta ptr
        bcc :+
        inc ptr + 1
:       inc t2
        lda t2
        cmp #CRED_ALL
        beq :+
        jmp bf_line
:       rts

; Store t1, A as two bytes of the font, twice (the row doubled down).
bf_put:   sta t0
        ldy #0
bf_pr:    lda t1
        jsr bf_out
        lda t0
        jsr bf_out
        iny
        cpy #2
        bne bf_pr
        rts
bf_out:   sta FONTBUF
        inc bf_out + 1
        bne :+
        inc bf_out + 2
:       rts
