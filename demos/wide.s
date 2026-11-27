; wide.s - Wide screen: the parallax world filling the whole visible frame.
;
; The same two scrolling layers as parallax.s, drawn 272 rows tall, and the
; wide window ($20842-$20845) switching every 5 seconds between the normal
; 320x200 area and the whole visible frame (all four edges $FF: they stop at
; the edge of what the display shows).  The scroll positions shift by the
; window's left and top extension, so the scene stays where it is and only
; the border fills in.  The border is black; the VIC-II score bar stays
; inside the 320x200 area.
;
; In full-frame mode the bar moves to the top of the frame, where the VIC-II
; cannot draw: six 64x32 sprites of the sprite engine make a 384-pixel bar,
; with the text drawn into their patterns from the character ROM.  The
; layer order puts the sprites in front, then both layers, then the VIC-II,
; whose own bar the (opaque) back layer now hides.
;
; Timing: the top and bottom edges are latched at the start of a frame, the
; left and right edges and the scroll positions at the start of each line.
; A switch writes top/bottom in one frame and left/right/scroll at the start
; of the next, so all of it takes effect on the same frame.  Updates happen
; at raster line 0: in wide mode the picture runs past line 251.

NEED_XRAM_MB = 2
CPU_TEXT     = $0400 + 1 * 40 + 20  ; in the score bar
.include "demo.inc"
.include "assets.inc"

BACK_TILES_V  = $00000          ; up to 21 KB
FRONT_TILES_V = $05400          ; up to 59 KB, to the maps
BACK_MAP_V    = $14000          ; 16 KB each (128 x 64 tiles)
FRONT_MAP_V   = $18000
ART_ROWS      = 272
LEFT          = 32              ; the widened window's left extension
SWITCH_FRAMES = 250
SPRPAT        = $1C000          ; bar sprites: 6 x 64x32 x 8-bit = 12 KB
.assert BACK_TILES_V + BACK_TILES_LEN <= FRONT_TILES_V, error, "back tiles overrun the front tiles"
.assert FRONT_TILES_V + FRONT_TILES_LEN <= BACK_MAP_V, error, "front tiles overrun the back map"
.assert BACK_MAP_V + BACK_MAP_LEN <= FRONT_MAP_V, error, "back map overruns the front map"
.assert FRONT_MAP_V + FRONT_MAP_LEN <= SPRPAT, error, "front map overruns the bar sprites"
BAR_TEXT_ROW  = 12              ; text row inside the 32-pixel bar
BAR_BG        = 254             ; palette entries for the bar
BAR_FG        = 255
CHARS         = $C000           ; screen codes $00-$3F from the character ROM
CPU_COL       = 20              ; bar columns (8 pixels each, 48 across)
glyph         = $F0             ; zero-page pointers
str_p         = $F2
ORDER_WIDE    = (3 << VICX_ORDER_SPR) | (2 << VICX_ORDER_L0) | (1 << VICX_ORDER_L1)

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
        lda #0                          ; black border
        sta $D020
        lda #6                          ; blue bar background
        sta $D021
        PRINT_AT 1, title

        ; the window's top/bottom extension on this machine.  PAL: 35/37,
        ; the whole visible frame.  NTSC: the bottom stops after 12 lines, at
        ; the last raster line (the lines below belong to the next frame), so
        ; the top is kept to 12 as well and the picture stays centred.
        lda $02A6
        beq @ntsc
        lda #$FF                        ; stops at the visible edge (35)
        sta top_reg
        lda #35
        sta top
        lda #0                          ; wide: map rows 0-271 = the frame
        sta syw
        jmp @std
@ntsc:  lda #12
        sta top_reg
        sta top
        lda #ART_ROWS - (12 + 200 + 12) ; wide: the bottom 224 map rows
        sta syw
@std:   clc                             ; normal: the same scene, shifted by top
        lda syw
        adc top
        sta syn

        lda #0
        sta VICX_CTRL
        XRAM_TO_VRAM BACK_TILES, BACK_TILES_V, BACK_TILES_LEN
        XRAM_TO_VRAM FRONT_TILES, FRONT_TILES_V, FRONT_TILES_LEN
        XRAM_TO_VRAM BACK_MAP, BACK_MAP_V, BACK_MAP_LEN
        XRAM_TO_VRAM FRONT_MAP, FRONT_MAP_V, FRONT_MAP_LEN
        XRAM_TO_VRAM BACK_PAL, VICX_PALETTE + 16 * 4, BACK_PAL_LEN
        XRAM_TO_VRAM FRONT_PAL, VICX_PALETTE + 112 * 4, FRONT_PAL_LEN
        LAYER_SET VICX_LAYER0, VICX_LMODE_TILE8, VICX_MAP_W128 | VICX_MAP_H64, FRONT_MAP_V, FRONT_TILES_V, 0, 0, 0, 0
        LAYER_SET VICX_LAYER1, VICX_LMODE_TILE8, VICX_MAP_W128 | VICX_MAP_H64, BACK_MAP_V, BACK_TILES_V, 0, 0, 0, 0

        ; the full-frame bar: character ROM -> CHARS, sprite patterns, entries
        lda $01
        pha
        lda #$33                        ; character ROM in, I/O out
        sta $01
        ldx #0
:       lda $D000,x
        sta CHARS,x
        lda $D100,x
        sta CHARS + $100,x
        inx
        bne :-
        pla
        sta $01
        SET_PAL BAR_BG, 44, 61, 236     ; VIC-II blue as VICE shows it
        SET_PAL BAR_FG, 255, 255, 255
        VICX_P0_SET SPRPAT, VICX_STEP_1
        lda #BAR_BG
        P0_FILL 6 * 2048
.repeat 6, I
        SPRITE I, I * 64, 0, VICX_SW_64 | VICX_SH_32, VICX_S_ON, SPRPAT + I * 2048, VICX_S_8BIT
.endrep
        lda #4
        ldx #<txt_wide
        ldy #>txt_wide
        jsr render_str
        lda #34
        ldx #<txt_name
        ldy #>txt_name
        jsr render_str
        lda #$FF                        ; nothing in the readout's field yet
        ldx #7
:       sta cpu_cache,x
        dex
        bpl :-

        lda #0
        sta front_x
        sta front_x + 1
        sta back_x
        sta back_x + 1
        sta frame
        sta wide
        sta step
        lda #SWITCH_FRAMES
        sta timer
        jsr show_mode
        jsr set_mode_regs
        lda #VICX_CTRL_L0 | VICX_CTRL_L1 | VICX_CTRL_BGTRANS
        sta VICX_CTRL

loop:
        ldx #0                          ; line 0: outside every window size
        jsr wait_line
        jsr cpu_start

        ; second step of a switch: left/right now (top/bottom went last frame)
        lda step
        beq :+
        lda #0
        sta step
        jsr set_left_right
        jsr set_mode_regs
:
        ; time to switch?  First step: top/bottom
        dec timer
        bne @noswitch
        lda #SWITCH_FRAMES
        sta timer
        lda wide
        eor #1
        sta wide
        jsr set_top_bottom
        lda #1
        sta step
        jsr show_mode
@noswitch:
        ; scroll: front 1 pixel per frame, back 1 pixel every second frame
        inc front_x
        bne :+
        inc front_x + 1
:       inc frame
        lda frame
        and #1
        bne :+
        inc back_x
        bne :+
        inc back_x + 1
:       lda step                        ; mid-switch: keep last frame's offsets
        eor wide                        ; (wide xor step = the mode in force)
        tax
        lda offx,x                      ; normal: + left extension; wide: + 0
        sta t16
        lda syn,x
        sta t16 + 1
        VICX_P0_SET VICX_LAYER0 + VICX_L_SCROLLX, VICX_STEP_1
        clc
        lda front_x
        adc t16
        sta VICX_P0_DATA
        lda front_x + 1
        adc #0
        sta VICX_P0_DATA
        lda t16 + 1
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        VICX_P0_SET VICX_LAYER1 + VICX_L_SCROLLX, VICX_STEP_1
        clc
        lda back_x
        adc t16
        sta VICX_P0_DATA
        lda back_x + 1
        adc #0
        sta VICX_P0_DATA
        lda t16 + 1
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA

        jsr cpu_end

        ; normal mode: the VIC-II covers the layers on text rows 0-2
        ldx #50
        jsr wait_line
        lda bar_ctrl
        sta VICX_CTRL
        ldx #74                         ; row 3 starts at line 75
        jsr wait_line
        lda main_ctrl
        sta VICX_CTRL

        ; the bar sprites are drawn by now: copy a changed frame rate readout in
        ldx #7
@cpu:   lda CPU_TEXT,x
        cmp cpu_cache,x
        beq @same
        sta cpu_cache,x
        stx col_i
        pha
        txa
        clc
        adc #CPU_COL
        tax
        pla
        jsr render_char
        ldx col_i
@same:  dex
        bpl @cpu
        jmp loop

; Layer order and CTRL for the mode in force (`wide'): written in the same
; frame as the left/right edges.
set_mode_regs:
        VICX_P0_SET VICX_ORDER, VICX_STEP_0
        lda wide
        beq :+
        lda #ORDER_WIDE
        sta VICX_P0_DATA
        lda #VICX_CTRL_L0 | VICX_CTRL_L1 | VICX_CTRL_SPR | VICX_CTRL_BGTRANS
        sta bar_ctrl
        sta main_ctrl
        rts
:       lda #0
        sta VICX_P0_DATA
        lda #VICX_CTRL_L0 | VICX_CTRL_L1
        sta bar_ctrl
        lda #VICX_CTRL_L0 | VICX_CTRL_L1 | VICX_CTRL_BGTRANS
        sta main_ctrl
        rts

; Draw the zero-terminated text at Y:X into the bar from column A.
render_str:
        sta col_i
        stx str_p
        sty str_p + 1
        ldy #0
:       lda (str_p),y
        beq :+
        sty str_i
        ldx col_i
        jsr render_char
        inc col_i
        ldy str_i
        iny
        bne :-
:       rts

; Draw character A (PETSCII letters, digits, space, %) at bar column X.
render_char:
        and #$3F
        sta glyph
        lda #0
        sta glyph + 1
        asl glyph                       ; * 8: offset into CHARS
        rol glyph + 1
        asl glyph
        rol glyph + 1
        asl glyph
        rol glyph + 1
        clc
        lda glyph + 1
        adc #>CHARS
        sta glyph + 1
        txa                             ; pixel x in its sprite = (col & 7) * 8
        and #7
        asl
        asl
        asl
        sta rc_lo
        txa                             ; sprite = col / 8: + sprite * $800
        lsr
        lsr
        lsr
        asl
        asl
        asl
        clc
        adc #>((SPRPAT & $FFFF) + BAR_TEXT_ROW * 64)
        sta rc_mid
        ldy #0
@row:   lda rc_lo
        sta VICX_P0_ADDRL
        lda rc_mid
        sta VICX_P0_ADDRM
        lda #((SPRPAT >> 16) & 3) | VICX_STEP_1
        sta VICX_P0_ADDRH
        lda (glyph),y
        sta bits
        ldx #8
:       asl bits
        lda #BAR_BG
        bcc :+
        lda #BAR_FG
:       sta VICX_P0_DATA
        dex
        bne :--
        clc                             ; next pixel row: + 64
        lda rc_lo
        adc #64
        sta rc_lo
        bcc :+
        inc rc_mid
:       iny
        cpy #8
        bne @row
        rts

set_top_bottom:
        VICX_P0_SET VICX_WIDE_TOP, VICX_STEP_1
        lda wide
        beq :+
        lda top_reg
:       sta VICX_P0_DATA                ; top
        lda wide
        beq :+
        lda #$FF
:       sta VICX_P0_DATA                ; bottom (stops at the visible edge)
        rts

set_left_right:
        VICX_P0_SET VICX_WIDE_LEFT, VICX_STEP_1
        lda wide
        beq :+
        lda #$FF
:       sta VICX_P0_DATA                ; left
        sta VICX_P0_DATA                ; right
        rts

show_mode:
        ldx #15
        lda wide
        bne @w
:       lda txt_normal,x
        and #$3F
        sta $0400 + 40 + 2,x
        dex
        bpl :-
        rts
@w:
:       lda txt_wide,x
        and #$3F
        sta $0400 + 40 + 2,x
        dex
        bpl :-
        rts

.rodata
title:      .byte "                              VIC-X WIDE", 0
txt_normal: .byte "320 X 200       "
txt_wide:   .byte "FULL FRAME      ", 0
txt_name:   .byte "VIC-X WIDE", 0
offx:       .byte LEFT, 0           ; scroll X offset: normal, wide

.bss
front_x: .res 2
back_x:  .res 2
frame:   .res 1
wide:    .res 1
step:    .res 1
timer:   .res 1
top:     .res 1                 ; top extension in force when wide
top_reg: .res 1                 ; value written for it
syn:     .res 1                 ; scroll Y in normal mode (syn, syw: in this order)
syw:     .res 1                 ; scroll Y in wide mode
t16:     .res 2
bar_ctrl:  .res 1               ; CTRL on the VIC-II bar lines (51-74)
main_ctrl: .res 1               ; CTRL everywhere else
cpu_cache: .res 8
col_i:   .res 1
str_i:   .res 1
rc_lo:   .res 1
rc_mid:  .res 1
bits:    .res 1
