; desktop.s - Desktop: a GEOS-style windowing desktop.
;
; Layer 1 is the desktop: an 8-bit tile layer with the wallpaper, the menu
; bar and the icons.  The menu titles, the icon labels and the CPU readout
; are VIC-II text (lower-case set, YSCROLL 5 so the text sits in the bar),
; with the background transparent.  Layer 0, in front, is a 320x200 8-bit
; bitmap holding the windows and menus; colour 0 is transparent, so where
; nothing is open the desktop shows through.  The pointer is entry 0 of
; the sprite engine.  Order, front to back: sprites, layer 0, VIC-II,
; layer 1, so windows cover the icon labels.
;
; Every window and menu is a picture in XRAM.  The demo draws them with
; the DMA blitter: a 2D copy for the window, two fills for its shadow.  When
; a window moves, only the strips it uncovers are repainted (cleared, then
; every window below copied into them, clipped) and the window is copied
; at its new place, so dragging moves about twice its size per frame.  The
; text in the windows is written into those pictures by the CPU through
; an XRAM window at $A000, from the character ROM: the titles at start-up,
; the About box's numbers from the capability registers, and the notes,
; typed a letter at a time.
;
; Controls: a 1351 mouse in either port, or a joystick in port 2; the left
; button or fire clicks.  Double-click an icon to open its window, drag a
; window by its title bar, click the box on the left of the title to close
; it, click a window to bring it to the front, click a menu title and then
; an item.  A test build (VICX_DEMO_DEFS=DESK_TEST) plays a script that
; does all of it, for checking the demo in headless VICE.

NEED_XRAM_MB = 2
CPU_TEXT     = $0400 + 32           ; menu bar, right
LD_IN        = $3800                ; the loader's buffer, above this program
.include "demo.inc"
.include "assets.inc"
.include "desktop.inc"

BMP_V   = $00000                    ; layer 0: 320x200 8-bit bitmap
PTR_V   = $0FA00                    ; pointer pattern (16x16, 256 bytes)
MAP_V   = $10000                    ; layer 1: desktop map, 64x32
TILES_V = $11000                    ; desktop tiles
FONT    = $C000                     ; lower-case character set, from ROM
WIN_SLOT = $A000                    ; XRAM window 0 for writing text

DBL_FRAMES = 30                     ; double-click time
TYPE_RATE  = 4                      ; frames per letter
BLACK      = 16

; --- zero page -----------------------------------------------------------
r_x1    = $10                       ; clip rectangle (x2, y2 exclusive)
r_y1    = $12
r_x2    = $13
r_y2    = $15
a_x1    = $16                       ; rectangle being clipped
a_y1    = $18
a_x2    = $19
a_y2    = $1B
i_x1    = $1C                       ; intersection
i_y1    = $1E
i_x2    = $1F
i_y2    = $21
o_x     = $22                       ; object being drawn: position, size,
o_y     = $24                       ; XRAM picture, shadow on/off
o_w     = $25
o_h     = $26
o_img   = $27
o_shadow = $2A
d_op    = $2B                       ; DMA descriptor fields
d_flags = $2C
d_src   = $2D
d_dst   = $30
d_w     = $33
d_h     = $35
d_ss    = $36
d_ds    = $37
d_fill  = $39
m_res   = $3A                       ; multiply result
t0      = $3C
t1      = $3D
t2      = $3E
t3      = $3F
wptr    = $40                       ; pointer into the XRAM window
tx_addr = $42                       ; text: XRAM address, stride, colours
tx_stride = $45
tx_fg   = $46
tx_bg   = $47
fptr    = $48                       ; font row
tptr    = $4A                       ; texts table / strings
sc_pc   = $4C                       ; script
num     = $4E                       ; 16-bit number to print

.macro MOVW src, dst
        lda src
        sta dst
        lda src + 1
        sta dst + 1
.endmacro

; dst = src16 + A (8 bit)
.macro ADDW8 src, dst
        clc
        adc src
        sta dst
        lda src + 1
        adc #0
        sta dst + 1
.endmacro

; carry set if a16 >= b16 (unsigned); uses A
.macro CMPW a16, b16
        lda a16
        cmp b16
        lda a16 + 1
        sbc b16 + 1
.endmacro

.code
main:
        lda #0
        sta VICX_CTRL
        sta $D020
        sta $D021
        lda #$0B                        ; blank while setting up
        sta $D011

        ; the lower-case character set from ROM to FONT
        lda #$33
        sta $01
        ldx #0
:
        .repeat 8, I
        lda $D800 + I * 256,x
        sta FONT + I * 256,x
        .endrepeat
        inx
        bne :-
        lda #$37
        sta $01

        ; the menu bar and the icon labels as text
        ldx #0
:       lda #$20
        sta $0400,x
        sta $0500,x
        sta $0600,x
        sta $06E8,x
        lda #0
        sta $D800,x
        sta $D900,x
        sta $DA00,x
        sta $DAE8,x
        inx
        bne :-
        ldx #39
:       lda bar_text,x
        sta $0400,x
        dex
        bpl :-
        lda #<labels
        sta tptr
        lda #>labels
        sta tptr + 1
@lab:   ldy #0
        lda (tptr),y
        sta wptr
        iny
        lda (tptr),y
        beq @labdone
        sta wptr + 1
        lda tptr
        clc
        adc #2
        sta tptr
        bcc :+
        inc tptr + 1
:       ldy #0
:       lda (tptr),y
        beq :+
        sta (wptr),y
        iny
        bne :-
:       iny                             ; past the 0
        tya
        clc
        adc tptr
        sta tptr
        bcc @lab
        inc tptr + 1
        bne @lab
@labdone:

        ; VRAM: desktop, pointer, palette; layer 0 cleared
        XRAM_TO_VRAM DESK_TILES, TILES_V, DESK_TILES_LEN
        XRAM_TO_VRAM DESK_MAP, MAP_V, DESK_MAP_LEN
        XRAM_TO_VRAM POINTER, PTR_V, POINTER_LEN
        XRAM_TO_VRAM DESK_PAL, VICX_PALETTE + 16 * 4, DESK_PAL_LEN
        XRAM_TO_VRAM PHOTO_PAL, VICX_PALETTE + 96 * 4, PHOTO_PAL_LEN
        DMA_DESC 0, VICX_DMA_FILL, VICX_DMA_DST_VRAM, 0, BMP_V, 64000, 0, 0, 0, 0, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT

        ; the text in the windows and menus
        lda #VICX_SLOT_A000 | VICX_SLOT_ON
        sta VICX_W0_SLOT
        jsr render_texts

        LAYER_SET VICX_LAYER1, VICX_LMODE_TILE8, VICX_MAP_W64 | VICX_MAP_H32, MAP_V, TILES_V, 0, 0, 0, 0
        LAYER_SET VICX_LAYER0, VICX_LMODE_BITMAP8, 0, BMP_V, 0, 0, 0, 320, 0
        VICX_P0_SET VICX_ORDER, VICX_STEP_0
        lda #(3 << VICX_ORDER_SPR) | (2 << VICX_ORDER_L0) | (1 << VICX_ORDER_VIC)
        sta VICX_P0_DATA
        SPRITE 0, 160, 100, VICX_SW_16 | VICX_SH_16, VICX_S_ON, PTR_V, VICX_S_8BIT

        ; the paddle lines of each port in turn to the SID (a 1351 mouse in
        ; either port); a selection needs a while before the SID has read it
        lda #$C0
        sta $DC02
        lda #$80                        ; port 2
        sta $DC00
        ldx #100
        jsr wait_line
        ldx #200
        jsr wait_line
        lda $D419
        sta opotx + 1
        lda $D41A
        sta opoty + 1
        lda #$40                        ; port 1
        sta $DC00
        ldx #100
        jsr wait_line
        ldx #200
        jsr wait_line
        lda $D419
        sta opotx
        lda $D41A
        sta opoty
        lda #0
        sta psel
        lda #$FF
        sta mport                       ; no mouse seen yet

        lda #<160
        sta px
        lda #0
        sta px + 1
        lda #100
        sta py
        lda #0
        sta frame
        sta btn_prev
        sta in_btn
        sta jspeed
        lda #$FF
        sta menu_open
        jsr reset_desktop
.ifdef DESK_TEST
        lda #1                          ; test build: the script plays
        sta attract
        jsr start_script
.endif

        lda #$17                        ; screen $0400, lower-case set
        sta $D018
        lda #$1D                        ; screen on, YSCROLL 5
        sta $D011
        lda #VICX_CTRL_SPR | VICX_CTRL_L0 | VICX_CTRL_L1 | VICX_CTRL_BGTRANS
        sta VICX_CTRL

; --- the frame loop -------------------------------------------------------
loop:
        ldx #251
        jsr wait_line
        jsr cpu_start
        inc frame
        jsr read_input
.ifdef DESK_TEST
        lda attract
        beq :+
        jsr script_step
:
.endif
        jsr place_pointer
        jsr ui_step
        jsr type_step
        jsr rainbow_step
        jsr cpu_end
        jmp loop

; --- input ----------------------------------------------------------------
; Joystick 2 and the mouse move (px, py); in_btn = a button is down.  Until
; a mouse has moved, the SID reads port 1's and port 2's paddle lines in
; turns, a frame each; the first that moves is the mouse's port from then on.
read_input:
        lda #0
        sta active
        sta t1                          ; a button is down
        lda $DC00
        eor #$FF
        and #$1F
        sta t2                          ; joystick 2
        lda $DC01
        eor #$FF
        and #$11                        ; mouse buttons: fire = left, up = right
        sta t3
        ora t2
        beq :+
        inc active
:       lda t2
        ora t3
        and #$10                        ; fire on either port (left button) clicks
        beq :+
        inc t1
:       ; joystick directions, speeding up while held
        lda t2
        and #$0F
        bne :+
        lda #0
        sta jspeed
        beq @mouse
:       lda jspeed
        cmp #4 * 8 - 1
        bcs :+
        inc jspeed
:       lda jspeed
        lsr
        lsr
        lsr
        clc
        adc #1
        sta t0                          ; step 1-4
        lda t2
        lsr                             ; up
        bcc :+
        lda py
        sec
        sbc t0
        sta py
        bcs :+
        lda #0
        sta py
:       lda t2
        and #2                          ; down
        beq :+
        lda py
        clc
        adc t0
        sta py
:       lda t2
        and #4                          ; left
        beq :+
        lda px
        sec
        sbc t0
        sta px
        lda px + 1
        sbc #0
        sta px + 1
:       lda t2
        and #8                          ; right
        beq @mouse
        lda px
        clc
        adc t0
        sta px
        bcc @mouse
        inc px + 1
@mouse: ldx psel
        ldy opotx,x
        lda $D419
        jsr movchk
        sta mdx
        stx mdxs
        tya
        ldx psel
        sta opotx,x
        ldy opoty,x
        lda $D41A
        jsr movchk
        sta mdy
        stx mdys
        tya
        ldx psel
        sta opoty,x
        lda #0
        sta pyh
        lda mdx
        ora mdy
        beq @still
        lda mport                       ; the first port that moves is the mouse's
        bpl :+
        lda psel
        sta mport
:       inc active
        lda mdx                         ; px += dx
        clc
        adc px
        sta px
        lda mdxs
        adc px + 1
        sta px + 1
        lda py                          ; (py, pyh) -= dy
        sec
        sbc mdy
        sta py
        lda #0
        sbc mdys
        sta pyh
@still: lda mport
        bpl @clamp
        lda psel                        ; no mouse yet: the other port next
        eor #1
        sta psel
        tax
        lda port_sel,x
        sta $DC00
@clamp: lda px + 1                      ; px: 0-319
        bpl :+
        lda #0
        sta px
        sta px + 1
:       lda px + 1
        beq :+
        lda px
        cmp #<320
        bcc :+
        lda #<319
        sta px
:       lda pyh                         ; py: 0-199 (joystick steps stay below 204)
        bmi @ytop
        bne @ybot
        lda py
        cmp #200
        bcc @yok
@ybot:  lda #199
        sta py
        bne @yok
@ytop:  lda #0
        sta py
@yok:
.ifdef DESK_TEST
        lda attract                     ; test build: the script has the button
        beq :+                          ; until something moves
        lda active
        beq @rts
        lda #0
        sta attract
:
.endif
        lda t1
        sta in_btn
@rts:   rts

port_sel: .byte $40, $80                ; $DC00: port 1's or port 2's paddle lines

; 1351: A = new pot value, Y = old -> A = signed movement, X = sign,
; Y = value to keep (the old one when there was no movement)
movchk: sty t0
        sta t1
        ldx #0
        sec
        sbc t0
        and #%01111111
        cmp #%01000000
        bcs @neg
        lsr
        beq @null
        ldy t1
        rts
@neg:   ora #%11000000
        cmp #$FF
        beq @null
        sec
        ror
        ldx #$FF
        ldy t1
        rts
@null:  lda #0
        ldx #0
        rts

place_pointer:
        VICX_P0_SET VICX_SPRITES, VICX_STEP_1
        lda px
        sta VICX_P0_DATA
        lda px + 1
        ora #VICX_SW_16 | VICX_SH_16
        sta VICX_P0_DATA
        lda py
        sta VICX_P0_DATA
        rts

; --- the script (test builds only: VICX_DEMO_DEFS=DESK_TEST) --------------
.ifdef DESK_TEST
start_script:
        lda #<script
        sta sc_pc
        lda #>script
        sta sc_pc + 1
        lda #0
        sta sc_wait
        rts

script_step:
        lda sc_wait
        beq :+
        dec sc_wait
        rts
:       ldy #0
        lda (sc_pc),y
        bne :+
        jsr reset_desktop               ; S_LOOP
        jmp start_script
:       cmp #S_MOVE_
        beq @move
        cmp #S_DOWN
        bne :+
        lda #1
        sta in_btn
        lda #1
        jmp sc_skip
:       cmp #S_UP
        bne :+
        lda #0
        sta in_btn
        lda #1
        jmp sc_skip
:       iny                             ; S_WAIT
        lda (sc_pc),y
        sta sc_wait
        lda #2
        jmp sc_skip
@move:  iny
        lda (sc_pc),y
        sta t0                          ; target x (16 bit)
        iny
        lda (sc_pc),y
        sta t1
        iny
        lda (sc_pc),y
        sta t2                          ; target y
        lda t0                          ; x: a step of |d| / 8 + 1, at most 6
        sec
        sbc px
        sta dxl
        lda t1
        sbc px + 1
        sta dxh
        bmi @xneg
        bne @xpbig
        lda dxl
        beq @xdone
        jsr step_of
        jmp @xadd
@xpbig: lda #6
@xadd:  clc
        adc px
        sta px
        bcc @xdone
        inc px + 1
        jmp @xdone
@xneg:  lda #0
        sec
        sbc dxl
        sta dxl
        lda #0
        sbc dxh
        bne @xnbig
        lda dxl
        jsr step_of
        jmp @xsub
@xnbig: lda #6
@xsub:  sta t3
        lda px
        sec
        sbc t3
        sta px
        lda px + 1
        sbc #0
        sta px + 1
@xdone: lda t2
        sec
        sbc py
        beq @ydone
        bcc @yneg
        jsr step_of
        clc
        adc py
        sta py
        jmp @ydone
@yneg:  eor #$FF
        clc
        adc #1
        jsr step_of
        sta t3
        lda py
        sec
        sbc t3
        sta py
@ydone: lda t0                          ; there?
        cmp px
        bne :+
        lda t1
        cmp px + 1
        bne :+
        lda t2
        cmp py
        bne :+
        lda #4
        jmp sc_skip
:       rts

; A = distance (1-255) -> step 1-6
step_of:
        lsr
        lsr
        lsr
        clc
        adc #1
        cmp #7
        bcc :+
        lda #6
:       rts

sc_skip:
        clc
        adc sc_pc
        sta sc_pc
        bcc :+
        inc sc_pc + 1
:       rts

.endif

; --- the user interface -----------------------------------------------------
; state: 0 nothing, 1 dragging window `drag_win', 2 a menu is open
ui_step:
        lda in_btn
        ldx btn_prev
        sta btn_prev
        cpx #0
        bne @wasdown
        cmp #0
        beq @held
        lda #1                          ; pressed
        sta pressed
        lda #0
        sta released
        beq @go
@wasdown:
        cmp #0
        bne @held
        lda #0
        sta pressed
        lda #1
        sta released
        bne @go
@held:  lda #0
        sta pressed
        sta released
@go:    lda state
        cmp #1
        bne :+
        jmp ui_drag
:       cmp #2
        bne :+
        jmp ui_menu
:       lda pressed
        bne :+
        rts
:       ; a press: the menu bar, a window, an icon
        lda py
        cmp #MENU_H
        bcs @notbar
        jsr bar_menu_at
        bmi :+
        jsr open_menu
        lda #2
        sta state
:       rts
@notbar:
        jsr window_at
        bmi @icons
        sta hit_win
        tax
        lda py                          ; title bar?
        sec
        sbc win_y,x
        cmp #12
        bcs @body
        lda px                          ; close box: x 2-11 from the left
        sec
        sbc win_x_lo,x
        sta t0
        lda px + 1
        sbc win_x_hi,x
        bne @title
        lda t0
        cmp #12
        bcs @title
        cmp #2
        bcc @title
        ldx hit_win
        jmp close_win
@title: ldx hit_win
        jsr raise_win
        ldx hit_win
        stx drag_win
        lda px
        sec
        sbc win_x_lo,x
        sta drag_dx
        lda py
        sec
        sbc win_y,x
        sta drag_dy
        lda #1
        sta state
        rts
@body:  ldx hit_win
        jmp raise_win
@icons: jsr icon_at
        bmi @none
        cmp last_icon
        bne @first
        lda frame
        sec
        sbc last_time
        cmp #DBL_FRAMES
        bcs @first2
        lda #$FF
        sta last_icon
        ldx hit_icon
        lda icon_action,x
        jmp do_action
@first2:
        lda hit_icon
@first: sta last_icon
        lda frame
        sta last_time
@none:  rts

ui_drag:
        lda in_btn
        bne :+
        lda #0
        sta state
        rts
:       ldx drag_win
        ; new x = px - drag_dx, 0 .. maxx
        lda px
        sec
        sbc drag_dx
        sta nx
        lda px + 1
        sbc #0
        sta nx + 1
        bpl :+
        lda #0
        sta nx
        sta nx + 1
:       lda nx + 1
        cmp win_maxx_hi,x
        bcc @xok
        bne @xmax
        lda nx
        cmp win_maxx_lo,x
        bcc @xok
        beq @xok
@xmax:  lda win_maxx_lo,x
        sta nx
        lda win_maxx_hi,x
        sta nx + 1
@xok:   ; new y = py - drag_dy, MENU_H .. maxy
        lda py
        sec
        sbc drag_dy
        bcc @ytop
        cmp #MENU_H
        bcs :+
@ytop:  lda #MENU_H
:       cmp win_maxy,x
        bcc :+
        lda win_maxy,x
:       sta ny
        cmp win_y,x
        bne @move
        lda nx
        cmp win_x_lo,x
        bne @move
        lda nx + 1
        cmp win_x_hi,x
        bne @move
        rts
@move:  jmp move_win

ui_menu:
        jsr item_at
        cmp menu_hl
        beq :+
        pha
        lda menu_hl
        ldx #0                          ; normal picture
        jsr draw_item
        pla
        sta menu_hl
        ldx #1                          ; highlighted
        jsr draw_item
:       lda released
        beq @press
        lda menu_hl
        bmi @rts
        ldx menu_open
        clc
        adc menu_first,x
        tax
        lda menu_actions,x
        pha
        jsr close_menu
        lda #0
        sta state
        pla
        jmp do_action
@press: lda pressed
        beq @rts
        lda menu_hl                     ; a press outside the items
        bpl @rts
        lda py
        cmp #MENU_H
        bcs @close
        jsr bar_menu_at                 ; another title: switch menus
        bmi @close
        cmp menu_open
        beq @rts
        pha
        jsr close_menu
        pla
        jmp open_menu
@close: jsr close_menu
        lda #0
        sta state
@rts:   rts

; A = action: 0-3 open window, $1n wallpaper n, $20 close all
do_action:
        cmp #$10
        bcs :+
        tax
        jmp open_win
:       cmp #$20
        bcs :+
        and #$0F
        jmp set_wallpaper
:       jmp close_all

; --- hit tests -------------------------------------------------------------
; menu title under the pointer (in the bar) -> A, or $FF (N set)
bar_menu_at:
        lda px + 1
        bne @no
        lda px
        lsr
        lsr
        lsr
        sta t0                          ; column
        ldx #0
:       lda t0
        cmp menu_lo,x
        bcc @next
        cmp menu_hi,x
        bcs @next
        txa
        rts
@next:  inx
        cpx #NMENU
        bne :-
@no:    lda #$FF
        rts

; topmost window under the pointer -> A, or $FF
window_at:
        ldy zcount
@lp:    dey
        bmi @no
        ldx zlist,y
        lda py
        cmp win_y,x
        bcc @lp
        sec
        sbc win_y,x
        cmp win_h,x
        bcs @lp
        lda px                          ; 0 <= px - x < w
        sec
        sbc win_x_lo,x
        sta t0
        lda px + 1
        sbc win_x_hi,x
        bne @lp
        lda t0
        cmp win_w,x
        bcs @lp
        txa
        rts
@no:    lda #$FF
        rts

; icon under the pointer -> A (its action) and hit_icon, or $FF
icon_at:
        ldx #0
@lp:    lda py
        cmp icon_y1,x
        bcc @next
        cmp icon_y2,x
        bcs @next
        lda px + 1
        cmp icon_x1_hi,x
        bcc @next
        bne :+
        lda px
        cmp icon_x1_lo,x
        bcc @next
:       lda px + 1
        cmp icon_x2_hi,x
        bcc @in
        bne @next
        lda px
        cmp icon_x2_lo,x
        bcs @next
@in:    stx hit_icon
        txa
        rts
@next:  inx
        cpx #NICON
        bne @lp
        lda #$FF
        rts

; item of the open menu under the pointer -> A, or $FF
item_at:
        ldx menu_open
        lda px + 1
        bne @no
        lda px
        sec
        sbc menu_x,x
        bcc @no
        beq @no
        clc
        adc #1
        cmp menu_w,x
        bcs @no
        lda py
        sec
        sbc #MENU_H + 1
        bcc @no
        ldy #0
:       cmp #ITEM_H
        bcc :+
        sbc #ITEM_H
        iny
        bne :-
:       tya
        cmp menu_n,x
        bcs @no
        rts
@no:    lda #$FF
        rts

; --- drawing -----------------------------------------------------------------
; Intersect a with r into i; carry set if empty.
intersect:
        CMPW a_x1, r_x1
        bcs :+
        MOVW r_x1, i_x1
        jmp @x2
:       MOVW a_x1, i_x1
@x2:    CMPW a_x2, r_x2
        bcc :+
        MOVW r_x2, i_x2
        jmp @y
:       MOVW a_x2, i_x2
@y:     lda a_y1
        cmp r_y1
        bcs :+
        lda r_y1
:       sta i_y1
        lda a_y2
        cmp r_y2
        bcc :+
        lda r_y2
:       sta i_y2
        lda i_y1
        cmp i_y2
        bcs @empty
        CMPW i_x1, i_x2
        bcs @empty
        clc
        rts
@empty: sec
        rts

; Write descriptor 0 from d_* and run it.
dma_go:
        VICX_P0_SET VICX_DMADESC, VICX_STEP_1
        lda d_op
        sta VICX_P0_DATA
        lda d_flags
        sta VICX_P0_DATA
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
        lda #0
        sta VICX_P0_DATA
        lda d_ds
        sta VICX_P0_DATA
        lda d_ds + 1
        sta VICX_P0_DATA
        lda d_fill
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        lda #VICX_DMA_NONE
        sta VICX_P0_DATA
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        rts

; Fill rectangle i of the bitmap with A.
fill_i: sta d_fill
        lda #VICX_DMA_FILL
        sta d_op
        lda #VICX_DMA_DST_VRAM | VICX_DMA_2D
        sta d_flags
        jmp blit

; Copy rectangle i from the object's picture.
copy_i: lda i_y1
        sec
        sbc o_y
        ldx o_w
        jsr mul8
        lda i_x1
        sec
        sbc o_x
        clc
        adc m_res
        sta d_src
        lda m_res + 1
        adc #0
        sta d_src + 1
        lda d_src
        clc
        adc o_img
        sta d_src
        lda d_src + 1
        adc o_img + 1
        sta d_src + 1
        lda #0
        adc o_img + 2
        sta d_src + 2
        lda o_w
        sta d_ss
        lda #VICX_DMA_COPY
        sta d_op
        lda #VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM | VICX_DMA_2D
        sta d_flags
blit:   ldx i_y1
        lda row_lo,x
        clc
        adc i_x1
        sta d_dst
        lda row_hi,x
        adc i_x1 + 1
        sta d_dst + 1
        lda #0
        sta d_dst + 2
        lda i_x2
        sec
        sbc i_x1
        sta d_w
        lda i_x2 + 1
        sbc i_x1 + 1
        sta d_w + 1
        lda i_y2
        sec
        sbc i_y1
        sta d_h
        lda #<320
        sta d_ds
        lda #>320
        sta d_ds + 1
        jmp dma_go

; m_res = A * X
mul8:   sta t0
        stx t1
        lda #0
        sta m_res
        sta m_res + 1
        ldx #8
:       asl m_res
        rol m_res + 1
        asl t0
        bcc :+
        lda m_res
        clc
        adc t1
        sta m_res
        bcc :+
        inc m_res + 1
:       dex
        bne :--
        rts

; Draw the object (o_*) clipped to r: picture, then shadow.
draw_obj:
        MOVW o_x, a_x1
        lda o_y
        sta a_y1
        lda o_w
        ADDW8 o_x, a_x2
        lda o_y
        clc
        adc o_h
        sta a_y2
        jsr intersect
        bcs :+
        jsr copy_i
:       lda o_shadow
        beq @done
        MOVW a_x2, a_x1                 ; right: (x+w, y+SH) - (x+w+SH, y+h)
        lda #SH
        ADDW8 a_x1, a_x2
        lda o_y
        clc
        adc #SH
        sta a_y1
        jsr intersect
        bcs :+
        lda #SHADOW_COL
        jsr fill_i
:       lda #SH                         ; bottom: (x+SH, y+h) - (x+w+SH, y+h+SH)
        ADDW8 o_x, a_x1
        lda a_y2
        sta a_y1
        clc
        adc #SH
        sta a_y2
        jsr intersect
        bcs @done
        lda #SHADOW_COL
        jsr fill_i
@done:  rts

; o_* = window X
load_win:
        lda win_x_lo,x
        sta o_x
        lda win_x_hi,x
        sta o_x + 1
        lda win_y,x
        sta o_y
        lda win_w,x
        sta o_w
        lda win_h,x
        sta o_h
        lda win_img_lo,x
        sta o_img
        lda win_img_mid,x
        sta o_img + 1
        lda win_img_hi,x
        sta o_img + 2
        lda #1
        sta o_shadow
        rts

; o_* = menu X (its normal picture)
load_menu:
        lda menu_x,x
        sta o_x
        lda #0
        sta o_x + 1
        lda #MENU_H
        sta o_y
        lda menu_w,x
        sta o_w
        lda menu_h,x
        sta o_h
        lda menu_img_lo,x
        sta o_img
        lda menu_img_mid,x
        sta o_img + 1
        lda menu_img_hi,x
        sta o_img + 2
        lda #1
        sta o_shadow
        rts

set_screen:
        lda #0
        sta r_x1
        sta r_x1 + 1
        sta r_y1
        lda #<320
        sta r_x2
        lda #>320
        sta r_x2 + 1
        lda #200
        sta r_y2
        rts

; r = footprint of object o (with its shadow)
r_from_obj:
        MOVW o_x, r_x1
        lda o_y
        sta r_y1
        lda o_w
        clc
        adc #SH
        ADDW8 o_x, r_x2
        lda o_y
        clc
        adc o_h
        adc #SH
        sta r_y2
        rts

; Repaint r: clear it, then every window bottom to top and the open menu.
repaint:
        MOVW r_x1, i_x1
        MOVW r_x2, i_x2
        lda r_y1
        sta i_y1
        lda r_y2
        sta i_y2
        CMPW i_x1, i_x2
        bcs @rts
        lda i_y1
        cmp i_y2
        bcs @rts
        lda #0
        jsr fill_i
        lda #0
        jmp repaint_from
@rts:   rts

; Draw the windows from z position A up, and the open menu, clipped to r.
repaint_from:
        sta zk
@lp:    lda zk
        cmp zcount
        bcs @menu
        tax
        lda zlist,x
        tax
        jsr load_win
        jsr draw_obj
        inc zk
        bne @lp
@menu:  ldx menu_open
        bmi @rts
        jsr load_menu
        jsr draw_obj
@rts:   rts

; Copy menu item A (if not $FF) from the normal (X = 0) or highlighted
; (X = 1) picture.
draw_item:
        cmp #$FF
        beq @rts
        sta t2
        stx t3
        ldx menu_open
        jsr load_menu
        lda t3
        beq :+
        lda menu_inv_lo,x
        sta o_img
        lda menu_inv_mid,x
        sta o_img + 1
        lda menu_inv_hi,x
        sta o_img + 2
:       lda #0
        sta o_shadow
        lda #1                          ; r = the item, inside the border
        ADDW8 o_x, r_x1
        lda o_w
        sec
        sbc #1
        ADDW8 o_x, r_x2
        lda t2
        ldx #ITEM_H
        jsr mul8
        lda m_res
        clc
        adc #MENU_H + 1
        sta r_y1
        clc
        adc #ITEM_H
        sta r_y2
        jmp draw_obj
@rts:   rts

; --- windows -------------------------------------------------------------------
; Move window X (the top one) to (nx, ny).
move_win:
        stx mv_win
        jsr load_win
        MOVW o_x, fa_x1                 ; old footprint
        lda o_y
        sta fa_y1
        lda o_w
        clc
        adc #SH
        sta t2
        ADDW8 o_x, fa_x2
        lda o_y
        clc
        adc o_h
        adc #SH
        sta fa_y2
        ldx mv_win                      ; new place and footprint
        lda nx
        sta win_x_lo,x
        sta fb_x1
        lda nx + 1
        sta win_x_hi,x
        sta fb_x1 + 1
        lda ny
        sta win_y,x
        sta fb_y1
        lda t2
        ADDW8 fb_x1, fb_x2
        lda ny
        clc
        adc o_h
        adc #SH
        sta fb_y2
        ; the strips of the old footprint outside the new one
        lda fb_y1                       ; top: fa_y1 .. min(fb_y1, fa_y2)
        cmp fa_y1
        beq @nobtop
        bcc @nobtop
        cmp fa_y2
        bcc :+
        lda fa_y2
:       sta r_y2
        lda fa_y1
        sta r_y1
        MOVW fa_x1, r_x1
        MOVW fa_x2, r_x2
        jsr repaint
@nobtop:
        lda fb_y2                       ; bottom: max(fb_y2, fa_y1) .. fa_y2
        cmp fa_y2
        bcs @nobot
        cmp fa_y1
        bcs :+
        lda fa_y1
:       sta r_y1
        lda fa_y2
        sta r_y2
        MOVW fa_x1, r_x1
        MOVW fa_x2, r_x2
        jsr repaint
@nobot: lda fa_y1                       ; middle rows: max(y1) .. min(y2)
        cmp fb_y1
        bcs :+
        lda fb_y1
:       sta my1
        lda fa_y2
        cmp fb_y2
        bcc :+
        lda fb_y2
:       sta my2
        lda my1
        cmp my2
        bcc @mid
        jmp @nomid
@mid:
        ; left: fa_x1 .. min(fb_x1, fa_x2)
        CMPW fa_x1, fb_x1
        bcs @noleft
        MOVW fa_x1, r_x1
        CMPW fb_x1, fa_x2
        bcc :+
        MOVW fa_x2, r_x2
        jmp :++
:       MOVW fb_x1, r_x2
:       lda my1
        sta r_y1
        lda my2
        sta r_y2
        jsr repaint
@noleft:                                ; right: max(fb_x2, fa_x1) .. fa_x2
        CMPW fb_x2, fa_x2
        bcs @nomid
        MOVW fa_x2, r_x2
        CMPW fb_x2, fa_x1
        bcs :+
        MOVW fa_x1, r_x1
        jmp :++
:       MOVW fb_x2, r_x1
:       lda my1
        sta r_y1
        lda my2
        sta r_y2
        jsr repaint
@nomid: ; the window at its new place
        jsr set_screen
        ldx mv_win
        jsr load_win
        jsr draw_obj
        ; the shadow's two notches show what is below
        ldx mv_win
        jmp repaint_notches

; Repaint the corners beside window X's shadow: top right and bottom left.
repaint_notches:
        jsr load_win
        lda o_w
        ADDW8 o_x, r_x1
        lda #SH
        ADDW8 r_x1, r_x2
        lda o_y
        sta r_y1
        clc
        adc #SH
        sta r_y2
        jsr repaint
        MOVW o_x, r_x1
        lda #SH
        ADDW8 o_x, r_x2
        lda o_y
        clc
        adc o_h
        sta r_y1
        clc
        adc #SH
        sta r_y2
        jmp repaint

; Bring window X to the front.
raise_win:
        ldy zcount
        dey
        txa
        cmp zlist,y
        beq @rts                        ; already in front
        jsr z_remove
        ldy zcount
        txa
        sta zlist,y
        inc zcount
        stx t3
        jsr set_screen
        ldx t3
        jsr load_win
        jmp draw_obj
@rts:   rts

; Take window X out of the order (X kept).
z_remove:
        ldy #0
:       txa
        cmp zlist,y
        beq :+
        iny
        cpy zcount
        bne :-
        rts
:       lda zlist + 1,y
        sta zlist,y
        iny
        cpy zcount
        bne :-
        dec zcount
        rts

close_win:
        lda win_open,x
        beq @rts
        lda #0
        sta win_open,x
        jsr z_remove
        jsr load_win
        jsr r_from_obj
        jmp repaint
@rts:   rts

close_all:
        lda #0
        sta zcount
        ldx #NWIN - 1
:       sta win_open,x
        dex
        bpl :-
        jsr set_screen
        jmp repaint

; Open window X at its first place, zooming out from its icon; if it is
; open already, bring it to the front.
open_win:
        lda win_open,x
        beq :+
        jmp raise_win
:       stx mv_win
        lda win_x0_lo,x
        sta win_x_lo,x
        lda win_x0_hi,x
        sta win_x_hi,x
        lda win_y0,x
        sta win_y,x
        txa                             ; zoom table: 48 bytes a window
        asl
        asl
        asl
        asl
        sta t0
        asl
        clc
        adc t0
        sta zoom_i
        lda #8
        sta zoom_n
@step:  jsr zoom_rect
        lda #BLACK
        jsr outline
        lda zoom_i
        pha
        lda zoom_n
        pha
        jsr frame_wait
        pla
        sta zoom_n
        pla
        sta zoom_i
        jsr zoom_rect
        lda #$FF                        ; erase: repaint the four sides
        jsr outline
        lda zoom_i
        clc
        adc #6
        sta zoom_i
        dec zoom_n
        bne @step
        ldx mv_win
        lda #1
        sta win_open,x
        ldy zcount
        txa
        sta zlist,y
        inc zcount
        jsr set_screen
        ldx mv_win
        jsr load_win
        jmp draw_obj

; zoom rectangle at zoom_i -> zr_*
zoom_rect:
        ldx zoom_i
        lda zoom,x
        sta zr_x1
        lda zoom + 1,x
        sta zr_x1 + 1
        lda zoom + 2,x
        sta zr_y1
        lda zoom + 3,x
        sta zr_x2
        lda zoom + 4,x
        sta zr_x2 + 1
        lda zoom + 5,x
        sta zr_y2
        rts

; Draw the sides of zr_* in colour A, or repaint them if A = $FF.
outline:
        sta t3
        jsr ol_x                        ; top
        lda zr_y1
        sta i_y1
        clc
        adc #1
        sta i_y2
        jsr side
        jsr ol_x                        ; bottom
        lda zr_y2
        sta i_y2
        sec
        sbc #1
        sta i_y1
        jsr side
        MOVW zr_x1, i_x1                ; left
        lda #1
        ADDW8 zr_x1, i_x2
        jsr ol_y
        jsr side
        MOVW zr_x2, i_x2                ; right
        lda zr_x2
        sec
        sbc #1
        sta i_x1
        lda zr_x2 + 1
        sbc #0
        sta i_x1 + 1
        jsr ol_y
side:   lda t3
        cmp #$FF
        beq :+
        jmp fill_i
:       MOVW i_x1, r_x1
        MOVW i_x2, r_x2
        lda i_y1
        sta r_y1
        lda i_y2
        sta r_y2
        jmp repaint

ol_x:   MOVW zr_x1, i_x1
        MOVW zr_x2, i_x2
        rts

ol_y:   lda zr_y1
        sta i_y1
        lda zr_y2
        sta i_y2
        rts

; wait for the next frame's line 251, keeping the pointer and the CPU
; readout going
frame_wait:
        jsr cpu_end
        ldx #251
        jsr wait_line
        jsr cpu_start
        inc frame
        rts

; --- menus -----------------------------------------------------------------------
open_menu:
        sta menu_open
        lda #$FF
        sta menu_hl
        jsr title_reverse
        jsr set_screen
        ldx menu_open
        jsr load_menu
        jmp draw_obj

close_menu:
        jsr title_reverse
        ldx menu_open
        jsr load_menu
        jsr r_from_obj
        lda #$FF
        sta menu_open
        jmp repaint

; Flip the reverse bit of the open menu's title in the bar.
title_reverse:
        ldx menu_open
        ldy menu_lo,x
:       lda $0400,y
        eor #$80
        sta $0400,y
        iny
        tya
        cmp menu_hi,x
        bcc :-
        beq :-
        rts

; --- desktop state ---------------------------------------------------------------
reset_desktop:
        lda menu_open
        bmi :+
        jsr title_reverse
:       lda #$FF
        sta menu_open
        sta last_icon
        lda #0
        sta state
        sta in_btn
        sta btn_prev
        jsr close_all
        lda #0
        jsr set_wallpaper
        jmp notes_reset

; A = wallpaper 0-3: palette entries WALL_PAL-WALL_PAL+3
set_wallpaper:
        asl
        asl
        asl
        asl
        tax
        VICX_P0_SET VICX_PALETTE + WALL_PAL * 4, VICX_STEP_1
        ldy #16
:       lda wallpapers,x
        sta VICX_P0_DATA
        inx
        dey
        bne :-
        rts

; Rotate the rainbow entries while the Colours window is open.
rainbow_step:
        lda win_open + 2
        beq @rts
        lda frame
        lsr
        bcs @rts
        inc rain_pos
        lda rain_pos
        cmp #NRAIN
        bcc :+
        lda #0
        sta rain_pos
:       asl
        asl
        clc
        adc #<rainbow_rgb
        sta tptr
        lda #>rainbow_rgb
        adc #0
        sta tptr + 1
        VICX_P0_SET VICX_PALETTE + RAINBOW * 4, VICX_STEP_1
        ldy #0
:       lda (tptr),y
        sta VICX_P0_DATA
        iny
        cpy #NRAIN * 4
        bne :-
@rts:   rts

; --- the notes ---------------------------------------------------------------------
notes_reset:
        ; the clean body over the typed one (XRAM to XRAM)
        lda #VICX_DMA_COPY
        sta d_op
        lda #VICX_DMA_SRC_XRAM | VICX_DMA_DST_XRAM
        sta d_flags
        lda #<(NOTES_CLEAN + 12 * NOTES_W)
        sta d_src
        lda #>(NOTES_CLEAN + 12 * NOTES_W)
        sta d_src + 1
        lda #^(NOTES_CLEAN + 12 * NOTES_W)
        sta d_src + 2
        lda #<(WIN0_IMG + 12 * NOTES_W)
        sta d_dst
        lda #>(WIN0_IMG + 12 * NOTES_W)
        sta d_dst + 1
        lda #^(WIN0_IMG + 12 * NOTES_W)
        sta d_dst + 2
        lda #<((NOTES_H - 12) * NOTES_W)
        sta d_w
        lda #>((NOTES_H - 12) * NOTES_W)
        sta d_w + 1
        lda #0
        sta d_h
        sta d_ss
        sta d_ds
        sta d_ds + 1
        jsr dma_go
        lda #0
        sta n_pos
        sta n_col
        sta n_row
        sta n_wait
        lda #TYPE_RATE
        sta n_timer
        lda #160                        ; the cursor: a reversed space
        ldx #CURSOR_COL
        jmp notes_cell

; Type the next letter of the notes.
type_step:
        lda win_open                    ; window 0 = the notes
        beq @rts
        lda menu_open
        bpl @rts
        dec n_timer
        bne @rts
        lda #TYPE_RATE
        sta n_timer
        lda n_wait
        beq @type
        dec n_wait
        bne @rts
        jsr notes_reset                 ; start again
        jmp notes_show
@type:  ldy n_pos
        lda notes_text,y
        bne :+
        lda #150                        ; all typed: wait 150 x TYPE_RATE frames
        sta n_wait
@rts:   rts
:       inc n_pos
        cmp #255                        ; newline
        beq @newline
        ldx #INK_COL
        jsr notes_cell
        jsr notes_show_cell
        inc n_col
        jmp @cursor
@newline:
        lda #32                         ; the cursor's cell blank
        ldx #INK_COL
        jsr notes_cell
        jsr notes_show_cell
        lda #0
        sta n_col
        inc n_row
@cursor:
        lda n_row
        cmp #NROWS
        bcs @rts
        lda #160
        ldx #CURSOR_COL
        jsr notes_cell
        jmp notes_show_cell

; Write screen code A in colour X at the cursor cell of the notes picture.
notes_cell:
        pha
        stx tx_fg
        lda #PAPER_COL
        sta tx_bg
        lda #NOTES_W
        sta tx_stride
        lda n_row
        ldx #NLINE
        jsr mul8
        lda m_res
        clc
        adc #NY0
        ldx #NOTES_W
        jsr mul8
        lda n_col
        asl
        asl
        asl
        clc
        adc #NX0
        clc
        adc m_res
        sta tx_addr
        lda m_res + 1
        adc #0
        sta tx_addr + 1
        lda tx_addr
        clc
        adc #<WIN0_IMG
        sta tx_addr
        lda tx_addr + 1
        adc #>WIN0_IMG
        sta tx_addr + 1
        lda #^WIN0_IMG
        adc #0
        sta tx_addr + 2
        pla
        jmp glyph

; Show the cursor cell on screen (the notes window and any above it).
notes_show_cell:
        ldx #0
        jsr load_win
        lda n_col
        asl
        asl
        asl
        clc
        adc #NX0
        ADDW8 o_x, r_x1
        lda #8
        ADDW8 r_x1, r_x2
        lda n_row
        ldx #NLINE
        jsr mul8
        lda m_res
        clc
        adc #NY0
        adc o_y
        sta r_y1
        clc
        adc #8
        sta r_y2
        jmp notes_from

; Show the whole notes window (after a reset).
notes_show:
        ldx #0
        jsr load_win
        jsr set_screen
notes_from:
        ldy #0                          ; from the notes' place in the order
:       lda zlist,y
        beq :+
        iny
        cpy zcount
        bne :-
        rts
:       tya
        jmp repaint_from

; --- text --------------------------------------------------------------------------
; Write the texts table into the pictures in XRAM.
render_texts:
        lda #<texts
        sta tptr
        lda #>texts
        sta tptr + 1
@rec:   ldy #0
        lda (tptr),y
        bne :+
        rts
:       sta t3                          ; 1 text, 2 number
        iny
        lda (tptr),y
        sta tx_addr
        iny
        lda (tptr),y
        sta tx_addr + 1
        iny
        lda (tptr),y
        sta tx_addr + 2
        iny
        lda (tptr),y
        sta tx_stride
        iny
        lda (tptr),y
        sta tx_fg
        iny
        lda (tptr),y
        sta tx_bg
        lda #7
        jsr tadv
        lda t3
        cmp #2
        beq @num
@chr:   ldy #0
        lda (tptr),y
        beq @end
        jsr glyph_next
        lda #1
        jsr tadv
        jmp @chr
@end:   lda #1
        jsr tadv
        jmp @rec
@num:   ldy #0
        lda (tptr),y                    ; source 0-3
        tax
        lda #0
        sta num + 1
        lda cap_regs,x
        tay
        lda $D000,y                     ; $D0xx: the capability register
        sta num
        cpx #0
        bne :+
        asl num                         ; VRAM: 8 KB units
        rol num + 1
        asl num
        rol num + 1
        asl num
        rol num + 1
:       jsr print_num
        lda #1
        jsr tadv
        jmp @rec

cap_regs: .byte <VICX_CAP_VRAM, <VICX_CAP_XRAM, <VICX_CAP_SPR, <VICX_CAP_SPRLINE

tadv:   clc
        adc tptr
        sta tptr
        bcc :+
        inc tptr + 1
:       rts

; Print num (16 bit) in decimal at tx_addr.
print_num:
        lda #0
        sta t2                          ; digits printed
        ldx #4
@digit: ldy #0
@sub:   lda num
        sec
        sbc pow_lo,x
        sta t0
        lda num + 1
        sbc pow_hi,x
        bcc @done
        sta num + 1
        lda t0
        sta num
        iny
        bne @sub
@done:  tya
        bne @show
        lda t2
        bne @show
        cpx #0
        bne @skip
@show:  tya
        ora #$30
        stx pn_x
        jsr glyph_next
        ldx pn_x
        inc t2
@skip:  dex
        bpl @digit
        rts

pow_lo: .byte <1, <10, <100, <1000, <10000
pow_hi: .byte >1, >10, >100, >1000, >10000

; Glyph A at tx_addr, then move tx_addr 8 pixels right.
glyph_next:
        jsr glyph
        lda tx_addr
        clc
        adc #8
        sta tx_addr
        bcc :+
        inc tx_addr + 1
        bne :+
        inc tx_addr + 2
:       rts

; Draw screen code A, 8x8, at XRAM tx_addr (stride tx_stride) in tx_fg on
; tx_bg, through the XRAM window at $A000.  tx_addr is kept.
glyph:  ldx #0
        stx fptr + 1
        asl
        rol fptr + 1
        asl
        rol fptr + 1
        asl
        rol fptr + 1
        sta fptr
        lda fptr + 1
        ora #>FONT
        sta fptr + 1
        lda tx_addr
        sta g_addr
        lda tx_addr + 1
        sta g_addr + 1
        lda tx_addr + 2
        sta g_addr + 2
        lda #8
        sta g_rows
@row:   ; window page and pointer for g_addr
        lda g_addr + 1
        lsr
        lsr
        lsr
        lsr
        lsr
        sta t0
        lda g_addr + 2
        asl
        asl
        asl
        ora t0
        sta VICX_W0_PAGEL
        lda g_addr + 2
        lsr
        lsr
        lsr
        lsr
        lsr
        sta VICX_W0_PAGEH
        lda g_addr
        sta wptr
        lda g_addr + 1
        and #$1F
        ora #>WIN_SLOT
        sta wptr + 1
        ldy #0
        lda (fptr),y
        sta t1
        lda wptr + 1                    ; the row inside this page: Y indexes it
        cmp #>(WIN_SLOT + $1F00)
        bcc @fast
        lda wptr
        cmp #$F9
        bcs @slow
@fast:  ldy #0
:       asl t1
        lda tx_bg
        bcc :+
        lda tx_fg
:       sta (wptr),y
        iny
        cpy #8
        bne :--
        beq @nextrow
@slow:  ldx #8
@px:    asl t1
        lda tx_bg
        bcc :+
        lda tx_fg
:       ldy #0
        sta (wptr),y
        inc wptr
        bne :+
        inc wptr + 1
        lda wptr + 1
        cmp #>(WIN_SLOT + $2000)
        bne :+
        jsr next_page
:       dex
        bne @px
@nextrow:
        inc fptr
        lda g_addr
        clc
        adc tx_stride
        sta g_addr
        bcc :+
        inc g_addr + 1
        bne :+
        inc g_addr + 2
:       dec g_rows
        beq :+
        jmp @row
:       rts

; the window ran off its 8 KB: the next page, from $A000
next_page:
        lda #>WIN_SLOT
        sta wptr + 1
        inc VICX_W0_PAGEL               ; (pages of a 2 MB XRAM fit 8 bits)
        rts

.bss
px:         .res 2
py:         .res 1
frame:      .res 1
in_btn:     .res 1
btn_prev:   .res 1
pressed:    .res 1
released:   .res 1
active:     .res 1
attract:    .res 1
jspeed:     .res 1
opotx:      .res 2                  ; per port
opoty:      .res 2
psel:       .res 1                  ; port whose paddle lines the SID reads
mport:      .res 1                  ; the mouse's port, $FF until it moves
mdx:        .res 1
mdxs:       .res 1
mdy:        .res 1
mdys:       .res 1
sc_wait:    .res 1
state:      .res 1
hit_win:    .res 1
hit_icon:   .res 1
last_icon:  .res 1
last_time:  .res 1
drag_win:   .res 1
drag_dx:    .res 1
drag_dy:    .res 1
nx:         .res 2
ny:         .res 1
mv_win:     .res 1
fa_x1:      .res 2
fa_y1:      .res 1
fa_x2:      .res 2
fa_y2:      .res 1
fb_x1:      .res 2
fb_y1:      .res 1
fb_x2:      .res 2
fb_y2:      .res 1
my1:        .res 1
my2:        .res 1
zk:         .res 1
zcount:     .res 1
zlist:      .res NWIN + 1
win_open:   .res NWIN
win_x_lo:   .res NWIN
win_x_hi:   .res NWIN
win_y:      .res NWIN
menu_open:  .res 1
menu_hl:    .res 1
zoom_i:     .res 1
zoom_n:     .res 1
zr_x1:      .res 2
zr_y1:      .res 1
zr_x2:      .res 2
zr_y2:      .res 1
rain_pos:   .res 1
n_pos:      .res 1
n_col:      .res 1
n_row:      .res 1
n_wait:     .res 1
n_timer:    .res 1
g_addr:     .res 3
g_rows:     .res 1
pn_x:       .res 1
pyh:        .res 1
dxl:        .res 1
dxh:        .res 1
