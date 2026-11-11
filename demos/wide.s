; wide.s - Wide screen: the parallax world filling the whole visible frame.
;
; The same two scrolling layers as parallax.s, drawn 272 rows tall, and the
; wide window ($20842-$20845) switching every 5 seconds between the normal
; 320x200 area and the whole visible frame (all four edges $FF: they stop at
; the edge of what the display shows).  The scroll positions shift by the
; window's left and top extension, so the scene stays where it is and only
; the border fills in.  The VIC-II score bar stays inside the 320x200 area;
; the border is the bar's blue, so in the widened lines the bar runs edge to
; edge.
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

BACK_TILES_V  = $00000          ; up to 24 KB
FRONT_TILES_V = $06000          ; up to 56 KB
BACK_MAP_V    = $14000          ; 16 KB each (128 x 64 tiles)
FRONT_MAP_V   = $18000
ART_ROWS      = 272
LEFT          = 32              ; the widened window's left extension
SWITCH_FRAMES = 250

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
        lda #6                          ; border = bar colour
        sta $D020
        sta $D021
        PRINT_AT 1, title

        ; the window's top/bottom extension on this machine: PAL 35/37,
        ; NTSC 23/12 (VICE's normal border; the window stops there)
        lda $02A6
        beq @ntsc
        lda #35
        sta top
        lda #0                          ; wide: map rows 0-271 = the frame
        sta syw
        jmp @std
@ntsc:  lda #23
        sta top
        lda #ART_ROWS - (23 + 200 + 12) ; wide: the bottom 235 map rows
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

        lda #0
        sta front_x
        sta front_x + 1
        sta back_x
        sta back_x + 1
        sta wide
        sta step
        lda #SWITCH_FRAMES
        sta timer
        jsr show_mode
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
        ; scroll: front 2 pixels, back 1 pixel per frame
        clc
        lda front_x
        adc #2
        sta front_x
        bcc :+
        inc front_x + 1
:       inc back_x
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

        ; score bar: the VIC-II covers the layers on text rows 0-2
        ldx #50
        jsr wait_line
        lda #VICX_CTRL_L0 | VICX_CTRL_L1
        sta VICX_CTRL
        ldx #74                         ; row 3 starts at line 75
        jsr wait_line
        lda #VICX_CTRL_L0 | VICX_CTRL_L1 | VICX_CTRL_BGTRANS
        sta VICX_CTRL
        jmp loop

set_top_bottom:
        VICX_P0_SET VICX_WIDE_TOP, VICX_STEP_1
        lda wide
        beq :+
        lda #$FF
:       sta VICX_P0_DATA                ; top
        sta VICX_P0_DATA                ; bottom
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
txt_wide:   .byte "FULL FRAME      "
offx:       .byte LEFT, 0           ; scroll X offset: normal, wide

.bss
front_x: .res 2
back_x:  .res 2
wide:    .res 1
step:    .res 1
timer:   .res 1
top:     .res 1
syn:     .res 1                 ; scroll Y in normal mode (syn, syw: in this order)
syw:     .res 1                 ; scroll Y in wide mode
t16:     .res 2
