; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; bigworld.s - Big world: a 1 MB, 256-colour world streamed from XRAM.
;
; The world is one 320-pixel-wide picture about 3200 rows tall (six scenes,
; from the edge of space down to a molten core; made with Nano Banana), kept
; in XRAM.  VRAM holds a ring of 256 rows, 512 bytes apart: all 128 KB.  The
; bitmap layer's base points at the row on top of the screen and wraps
; around VRAM.  Each frame the view moves one row, and one DMA copies the
; single new row that will come into view from XRAM into the ring row that
; just left it, so there is never a loading pause.  At either end the view
; turns round.
;
; The CPU reads where each scene starts through XRAM window 0 (the header
; at XRAM $000000, mapped at $4000), and the REU's own DMA copies a scene's
; caption from XRAM straight into screen memory, since XRAM is the REU's
; memory.
;
; The music streams from XRAM too: 280 KB of SID register frames
; (tools/gen_music.py), one section for each scene.  Each frame the CPU
; points window 1 ($6000) at the frame's 8 KB page and copies its 25 bytes
; to the SID; a new scene's section starts at the next bar line.

NEED_XRAM_MB = 2
NEED_FEAT    = VICX_FEAT_BITMAP | VICX_FEAT_BLITTER | VICX_FEAT_WINDOWS
CPU_TEXT     = $0400 + 0 * 40 + 32  ; top row, right
.include "demo.inc"
.include "assets.inc"

RING_ROWS = 256
RING_STRIDE = 512
VIEW_ROWS = 200
WIN       = $4000               ; window 0: XRAM page 0 = the header
MWIN      = $6000               ; window 1: the music's current page
mptr      = $FD                 ; 2 bytes: the music frame in window 1
SID       = $D400
CAPTION   = $0400 + 24 * 40     ; bottom row

REU_CMD   = $DF01
REU_C64   = $DF02
REU_ADDR  = $DF04
REU_LEN   = $DF07
REU_CTRL  = $DF0A

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
        lda #0
        sta $D020
        sta $D021
        PRINT_AT 0, title
        lda #0
        sta VICX_CTRL

        XRAM_TO_VRAM WORLD_PAL, VICX_PALETTE + 16 * 4, WORLD_PAL_LEN
        ; fill the ring with world rows 0-255: one 2D DMA, 320 x 256 bytes
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM | VICX_DMA_2D, WORLD_PIX, $00000, 320, RING_ROWS, 320, RING_STRIDE, 0, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
        LAYER_SET VICX_LAYER0, VICX_LMODE_BITMAP8, 0, $00000, 0, 0, 0, RING_STRIDE, 0

        ; window 0 at $4000 shows XRAM page 0, where the header is
        lda #0
        sta VICX_W0_PAGEL
        sta VICX_W0_PAGEH
        lda #VICX_SLOT_4000 | VICX_SLOT_ON
        sta VICX_W0_SLOT
        ; window 1 at $6000 for the music (the loader's buffer, free now)
        lda #<(MUSIC >> 13)
        sta VICX_W1_PAGEL
        lda #>(MUSIC >> 13)
        sta VICX_W1_PAGEH
        lda #VICX_SLOT_6000 | VICX_SLOT_ON
        sta VICX_W1_SLOT
        lda #$FF
        sta msec                        ; no section yet: the first starts at once
        lda #0
        sta mbc

        lda #0
        sta ypos
        sta ypos + 1
        lda #1
        sta dir
        lda #$FF
        sta seg
        lda #VICX_CTRL_L0 | VICX_CTRL_BGTRANS
        sta VICX_CTRL

loop:
        ldx #251                        ; after the display window
        jsr wait_line
        jsr cpu_start

        lda dir
        bmi @up
        ; down: at the bottom, turn round
        lda ypos
        cmp #<(WORLD_ROWS - VIEW_ROWS)
        bne :+
        lda ypos + 1
        cmp #>(WORLD_ROWS - VIEW_ROWS)
        bne :+
        lda #$FF
        sta dir
        jmp @moved
:       inc ypos
        bne :+
        inc ypos + 1
:       clc                             ; new row = y + 255, ring row = (y + 255) & 255
        lda ypos
        adc #RING_ROWS - 1
        sta row
        lda ypos + 1
        adc #0
        sta row + 1
        jsr stream_row
        jmp @moved
@up:    ; up: at the top, turn round
        lda ypos
        ora ypos + 1
        bne :+
        lda #1
        sta dir
        jmp @moved
:       lda ypos
        bne :+
        dec ypos + 1
:       dec ypos
        lda ypos                        ; new row = y, ring row = y & 255
        sta row
        lda ypos + 1
        sta row + 1
        jsr stream_row

@moved:
        ; layer base = (y & 255) * 512
        VICX_P0_SET VICX_LAYER0 + VICX_L_BASE, VICX_STEP_1
        lda #0
        sta VICX_P0_DATA
        lda ypos
        asl
        sta VICX_P0_DATA
        lda #0
        rol
        sta VICX_P0_DATA

        jsr caption
        jsr music
        jsr cpu_end
        jmp loop

; One frame of music: the scene's section (switching at a bar line), frame
; mf of it, from XRAM through window 1 into the SID's 25 registers.
music:  lda seg
        cmp msec
        beq @play
        lda mbc                         ; a new scene: at the next bar line
        bne @play
        lda seg
        sta msec
        lda #0
        sta mf
        sta mf + 1
@play:  ldx msec
        clc                             ; page: MUSIC's + the section's + mf / 256
        lda #<(MUSIC >> 13)
        adc mus_start,x
        sta t16
        lda #>(MUSIC >> 13)
        adc #0
        sta t16 + 1
        lda t16
        clc
        adc mf + 1
        sta VICX_W1_PAGEL
        lda t16 + 1
        adc #0
        sta VICX_W1_PAGEH
        lda mf                          ; frame (mf & 255) * 32 in the window
        lsr
        lsr
        lsr
        clc
        adc #>MWIN
        sta mptr + 1
        lda mf
        asl
        asl
        asl
        asl
        asl
        sta mptr
        ldy #24
:       lda (mptr),y
        sta SID,y
        dey
        bpl :-
        inc mf                          ; next frame; the section loops
        bne :+
        inc mf + 1
:       lda mf + 1
        cmp mus_pages,x
        bne :+
        lda #0
        sta mf
        sta mf + 1
:       inc mbc                         ; the bar counter
        lda mbc
        cmp mus_bar,x
        bne :+
        lda #0
        sta mbc
:       rts

; DMA world row `row' into ring row `row' & 255 (rows past the end are not
; needed and are skipped).
stream_row:
        lda row + 1
        cmp #>WORLD_ROWS
        bcc @ok
        bne @past
        lda row
        cmp #<WORLD_ROWS
        bcc @ok
@past:  rts
@ok:    ; source = WORLD_PIX + row * 320 = row * 256 + row * 64
        lda #0
        sta src + 2
        lda row
        sta t16
        lda row + 1
        sta t16 + 1
        ldx #6                          ; row * 64 -> src (24 bits)
        lda row
        sta src
        lda row + 1
        sta src + 1
:       asl src
        rol src + 1
        rol src + 2
        dex
        bne :-
        clc                             ; + row * 256
        lda src + 1
        adc t16
        sta src + 1
        lda src + 2
        adc t16 + 1
        sta src + 2
        clc                             ; + WORLD_PIX
        lda src
        adc #<WORLD_PIX
        sta src
        lda src + 1
        adc #>WORLD_PIX
        sta src + 1
        lda src + 2
        adc #^WORLD_PIX
        sta src + 2
        ; descriptor 1: XRAM src -> VRAM (row & 255) * 512, 320 bytes
        VICX_P0_SET VICX_DMADESC + 1 * 32, VICX_STEP_1
        lda #VICX_DMA_COPY
        sta VICX_P0_DATA
        lda #VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM
        sta VICX_P0_DATA
        lda src
        sta VICX_P0_DATA
        lda src + 1
        sta VICX_P0_DATA
        lda src + 2
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        sta VICX_P0_DATA                ; destination bits 0-7
        lda row
        asl
        sta VICX_P0_DATA                ; bits 8-15
        lda #0
        rol
        sta VICX_P0_DATA                ; bits 16-23
        lda #0
        sta VICX_P0_DATA
        lda #<320
        sta VICX_P0_DATA
        lda #>320
        sta VICX_P0_DATA
        lda #0
        ldx #8
:       sta VICX_P0_DATA
        dex
        bne :-
        lda #VICX_DMA_NONE
        sta VICX_P0_DATA
        lda #1
        sta VICX_DMA_CMD
        rts

; Which scene is the middle of the screen in?  The header, read through the
; window: count, then each scene's start row.  On a change, the REU copies
; that scene's caption into the bottom row.
caption:
        clc                             ; mid = y + 100
        lda ypos
        adc #VIEW_ROWS / 2
        sta t16
        lda ypos + 1
        adc #0
        sta t16 + 1
        ldx WIN                         ; scene count
        dex
        stx newseg
@find:  lda newseg                      ; from the last scene back
        asl
        tay
        lda WIN + 2,y                   ; start row, high byte
        cmp t16 + 1
        bcc @found
        bne @next
        lda WIN + 1,y
        cmp t16
        bcc @found
        beq @found
@next:  dec newseg
        bne @find
@found: lda newseg
        cmp seg
        beq @done
        sta seg
        ; REU: caption seg (40 bytes at WORLD_CAPS + seg * 40) -> screen
        lda #0
        sta REU_CTRL
        lda #<CAPTION
        sta REU_C64
        lda #>CAPTION
        sta REU_C64 + 1
        lda seg                         ; seg * 40 = seg * 32 + seg * 8
        asl
        asl
        asl
        sta t16
        asl
        asl
        clc
        adc t16
        clc
        adc #<WORLD_CAPS
        sta REU_ADDR
        lda #>WORLD_CAPS
        adc #0
        sta REU_ADDR + 1
        lda #^WORLD_CAPS
        adc #0
        sta REU_ADDR + 2
        lda #40
        sta REU_LEN
        lda #0
        sta REU_LEN + 1
        lda #$91                        ; execute: REU -> C64, no $FF00 trigger
        sta REU_CMD
@done:  rts

.rodata
title:  .byte "BIG WORLD: 1 MB IN XRAM", 0

.bss
ypos:   .res 2
dir:    .res 1
row:    .res 2
src:    .res 3
t16:    .res 2
seg:    .res 1
newseg: .res 1
msec:   .res 1                  ; music: the section playing
mf:     .res 2                  ; ... its frame
mbc:    .res 1                  ; ... the frame in its bar
