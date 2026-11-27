; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Michael Hartman
;
; demo.inc - start-up and helpers shared by the VIC-X demos
;
; A demo defines `main', `NEED_XRAM_MB' (0 if it needs no XRAM), `NEED_FEAT'
; (the CAP_FEAT bits it cannot run without, VICX_FEAT_*) and
; `CPU_TEXT' (where the frame rate readout goes), and includes its generated
; assets.inc, which names its data file.  Before `main', start-up loads that
; file into XRAM, unless XRAM already holds the demo's data.  Start-up
; runs with interrupts off, unlocks VIC-X and checks it is there, with enough
; XRAM and every feature the demo needs; if not, it prints what is missing
; and stops.

.include "vicx.inc"
.include "vicxlib.inc"

.segment "LOADADDR"
        .word $0801

.segment "EXEHDR"
        .word @next
        .word 10                ; 10 SYS 2061
        .byte $9e, "2061", 0
@next:  .word 0

.segment "CODE"
        sei                     ; $080D
        cld
        ldx #$ff
        txs
        lda #$7F                ; CIA interrupts off: the demos poll the raster
        sta $DC0D
        sta $DD0D
        lda $DC0D
        lda $DD0D
        VICX_UNLOCK_SEQ
        lda VICX_ID0
        cmp #$56
        bne @novicx
        lda VICX_ID1
        cmp #$58
        bne @novicx
        lda VICX_CAP_XRAM
        cmp #NEED_XRAM_MB
        bcc @noxram
        lda VICX_CAP_FEAT               ; every feature this demo needs?
        eor #$FF
        and #NEED_FEAT
        beq :+
        jmp demo_nofeat
:
        lda #0
        sta fps_on
        sta cpu_frames
        jsr load_data
        jmp main
@novicx:
        ldx #<msg_novicx
        ldy #>msg_novicx
        jmp demo_fail
@noxram:
        ldx #<msg_noxram
        ldy #>msg_noxram
        jmp demo_fail

; Print the zero-terminated string at Y:X with the KERNAL and stop.
demo_fail:
        stx $FB
        sty $FC
        lda #$93                ; clear screen
        jsr $FFD2
        ldy #0
:       lda ($FB),y
        beq :+
        jsr $FFD2
        iny
        bne :-
:       jmp :-

msg_novicx:
        .byte "VIC-X NOT FOUND.", 13, 13
        .byte "THIS DEMO NEEDS A C64 WITH VIC-X:", 13
        .byte "X64SC -VICX, OR AN FPGA CORE WITH IT.", 0
; This build of VIC-X lacks features the demo needs (A = the missing
; CAP_FEAT bits): name them and stop.
demo_nofeat:
        sta $FD
        lda #$93
        jsr $FFD2
        ldy #0
:       lda msg_nofeat,y
        beq :+
        jsr $FFD2
        iny
        bne :-
:       ldx #0                          ; X: feature bit, Y: its name
        ldy #0
@bit:   lsr $FD
        bcc @skip
:       lda feat_names,y
        beq :+
        jsr $FFD2
        iny
        bne :-
:       lda #13
        jsr $FFD2
        iny
        bne @next
@skip:  lda feat_names,y                ; over this name
        beq :+
        iny
        bne @skip
:       iny
@next:  inx
        cpx #5
        bne @bit
:       jmp :-

msg_nofeat:
        .byte "THIS BUILD OF VIC-X LACKS FEATURES", 13
        .byte "THE DEMO NEEDS:", 13, 13, 0
feat_names:                             ; CAP_FEAT bits 0-4
        .byte "  TILE LAYERS", 0
        .byte "  BITMAP LAYERS", 0
        .byte "  SPRITES", 0
        .byte "  DMA ENGINE AND BLITTER", 0
        .byte "  XRAM WINDOWS", 0
msg_noxram:
        .byte "THIS DEMO NEEDS AN REU OF 2 MB OR MORE.", 13, 13
        .byte "X64SC: -REU -REUSIZE 2048", 13
        .byte "ULTIMATE: RAM EXPANSION UNIT ENABLED,", 13
        .byte "REU SIZE 2 MB OR MORE.", 0

; --- helpers ------------------------------------------------------------

; Wait for the start of raster line X (< 256).
wait_line:
:       cpx $D012
        beq :-
:       cpx $D012
        bne :-
        lda $D011
        bmi :-
        rts

; Copy `len' bytes from XRAM to the port space (VRAM or registers) with DMA
; descriptor 0, and wait.
.macro XRAM_TO_VRAM xsrc, vdst, len
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_XRAM | VICX_DMA_DST_VRAM, xsrc, vdst, len, 0, 0, 0, 0, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        DMA_WAIT
.endmacro

; Copy `len' bytes from XRAM to C64 RAM with DMA descriptor 0 (the CPU halts).
.macro XRAM_TO_C64 xsrc, cdst, len
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_XRAM | VICX_DMA_DST_C64, xsrc, cdst, len, 0, 0, 0, 0, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
.endmacro

; Write 16-bit `value' at register-space address `addr' through port 0.
.macro POKE_REG16 addr, value
        POKE16 addr, value
.endmacro

; Print the zero-terminated string at `addr' to screen row `row' (0-24),
; column 0, in screen codes for upper-case letters, digits and spaces.
.macro PRINT_AT row, addr
        .local loop, done
        ldx #0
loop:   lda addr,x
        beq done
        and #$3F
        sta $0400 + (row) * 40,x
        inx
        bne loop
done:
.endmacro

; --- frame rate readout ---------------------------------------------------
; Call cpu_end when a frame's work is done (cpu_start, before the work, is
; kept for the demos that call it and does nothing).  Every 16 calls the
; rate of those 16 is printed as "FPS nn" at screen address CPU_TEXT (defined
; by the demo, 8 characters): 16 times the machine's frames a second (50 on
; PAL, 60 on NTSC; the KERNAL notes which at $02A6) over the frames VIC-X
; counted meanwhile (FRAME).  A demo that draws every frame shows 50; one
; whose work takes longer than a frame, and so shows every second frame,
; shows 25.  cpu_start and cpu_end keep X and Y; they use A.
;
; This was a load readout once ("CPU nnn%": the raster lines the work took,
; as a share of a frame).  It took the line the work ended on alone, so work
; of 115 % of a frame read as 15 %: the scenes that looked nearly idle were
; the ones running at half rate.

cpu_start:
        rts

cpu_end:
        inc cpu_frames
        lda cpu_frames
        and #15
        beq :+
        rts
:       txa                             ; keep X and Y
        pha
        tya
        pha
        jsr fps_show
        pla
        tay
        pla
        tax
        rts

fps_show:
        lda VICX_FRAME
        tax
        sec
        sbc fps_f0                      ; frames these 16 calls took
        stx fps_f0
        ldy fps_on                      ; the first 16 only set the start
        bne :+
        inc fps_on
        rts
:       sta fps_div
        cmp #0
        bne :+
        rts
:       lda $02A6                       ; 16 * 50 or 16 * 60
        beq :+
        lda #<800
        ldx #>800
        bne :++
:       lda #<960
        ldx #>960
:       sta fps_num
        stx fps_num + 1
        ldy #0                          ; Y = fps_num / fps_div (255 at most)
@div:   lda fps_num
        sec
        sbc fps_div
        tax
        lda fps_num + 1
        sbc #0
        bcc @done
        sta fps_num + 1
        stx fps_num
        iny
        cpy #255
        bne @div
@done:  ; print "FPS nn"
        ldx #0
:       lda fps_label,x
        sta CPU_TEXT,x
        inx
        cpx #4
        bne :-
        tya
        ldy #0                          ; hundreds
:       cmp #100
        bcc :+
        sbc #100
        iny
        bne :-
:       pha
        tya
        beq :+
        ora #$30
        sta CPU_TEXT,x
        inx
:       pla
        ldy #0                          ; tens
:       cmp #10
        bcc :+
        sbc #10
        iny
        bne :-
:       pha
        tya
        cpx #4                          ; no leading zero
        bne :+
        cmp #0
        beq :++
:       ora #$30
        sta CPU_TEXT,x
        inx
:       pla
        ora #$30
        sta CPU_TEXT,x
        inx
        lda #$20
:       cpx #8
        beq :+
        sta CPU_TEXT,x
        inx
        bne :-
:       rts

fps_label: .byte $06, $10, $13, $20     ; "FPS " in screen codes

.pushseg
.bss
fps_f0:     .res 1                      ; FRAME at the last readout
fps_on:     .res 1                      ; 0 until fps_f0 is set
fps_div:    .res 1
fps_num:    .res 2
cpu_frames: .res 1
.popseg

; --- self-loading ---------------------------------------------------------
; The demo's data file (data_name in assets.inc) is on the disk the demo was
; loaded from: "VX", then blocks of [packed size (2), XRAM address (3),
; unpacked size (2), packed bytes], then a packed size of 0.  Each block is
; read with the KERNAL into LD_IN, unpacked (tools/lzpack.py's format) into
; LD_OUT, and copied into XRAM by DMA.  If the 16 bytes at SIG_XRAM already
; match the demo's signature (an REU image loaded with the demo, or an
; earlier run), there is nothing to load.

.ifndef LD_IN                   ; a demo whose program is longer can move it up
LD_IN   = $3000                 ; packed block (up to ~8.2 KB)
.endif
LD_OUT  = $6000                 ; unpacked block (8 KB)
.import __MAIN_LAST__           ; the end of the program (demo.cfg)
.assert __MAIN_LAST__ <= LD_IN, lderror, "the program runs into LD_IN: set LD_IN higher"
.assert LD_IN + $2100 <= LD_OUT, lderror, "LD_IN is too close to LD_OUT"
ld_src  = $F0                   ; zero-page pointers
ld_dst  = $F2
ld_ref  = $F4
ld_cnt  = $F6
SETNAM  = $FFBD
SETLFS  = $FFBA
OPEN    = $FFC0
CLOSE   = $FFC3
CHKIN   = $FFC6
CLRCHN  = $FFCC
CHRIN   = $FFCF
CLALL   = $FFE7
STATUS  = $90
LAST_DEVICE = $BA
ld_getv = $FD                   ; (word) CHRIN or fl_get

load_data:
        XRAM_TO_C64 SIG_XRAM, ld_sig, 16
        ldx #15
:       lda ld_sig,x
        cmp demo_sig,x
        bne ld_go
        dex
        bpl :-
        rts                             ; already there

ld_go:  jsr uci_load                    ; on an Ultimate: the .reu straight from USB
        bcs :+
        rts
:       jsr ld_screen
        lda #<fl_get                    ; a 1541 or 1581: the fast loader
        sta ld_getv
        lda #>fl_get
        sta ld_getv + 1
        jsr fl_start
        bcs :+
        jmp ld_hdr
:       lda #<CHRIN                     ; else the KERNAL
        sta ld_getv
        lda #>CHRIN
        sta ld_getv + 1
        lda #DATA_NAME_LEN
        ldx #<data_name
        ldy #>data_name
        jsr SETNAM
        lda #2
        ldx LAST_DEVICE
        bne :+
        ldx #8
:       ldy #2
        jsr SETLFS
        jsr OPEN
        bcc :+
        jmp ld_err
:
        ldx #2
        jsr CHKIN
        bcc :+
        jmp ld_err
:
.ifdef FL_RAWTEST
; test build: the file as it arrives, 8 KB at a time, into XRAM from 0
ld_hdr: lda #0
        sta ld_xaddr
        sta ld_xaddr + 1
        sta ld_xaddr + 2
        sta ld_raw
        lda #$04
        sta ld_raw + 1
@blk:   lda #<LD_OUT
        sta ld_dst
        lda #>LD_OUT
        sta ld_dst + 1
@b:     jsr ld_get
        ldy #0
        sta (ld_dst),y
        inc ld_dst
        bne @b
        inc ld_dst + 1
        lda ld_dst + 1
        cmp #>(LD_OUT + $0400)
        bne @b
        jsr ld_store
        clc
        lda ld_xaddr + 1
        adc #$04
        sta ld_xaddr + 1
        bcc @blk
        inc ld_xaddr + 2
        jmp @blk
.else
ld_hdr:
.endif
        jsr ld_get                      ; "VX"
        cmp #$56
        beq :+
        jmp ld_err
:
        jsr ld_get
        cmp #$58
        beq :+
        jmp ld_err
:
        lda #0
        sta ld_acc
        sta ld_col

ld_block:
        jsr ld_get                       ; packed size, 0 = end
        sta ld_csize
        jsr ld_get
        sta ld_csize + 1
        ora ld_csize
        beq ld_done
        jsr ld_get                       ; XRAM address
        sta ld_xaddr
        jsr ld_get
        sta ld_xaddr + 1
        jsr ld_get
        sta ld_xaddr + 2
        jsr ld_get                       ; unpacked size
        sta ld_raw
        jsr ld_get
        sta ld_raw + 1
        lda #<LD_IN                     ; read the packed bytes
        sta ld_dst
        lda #>LD_IN
        sta ld_dst + 1
        lda ld_csize
        sta ld_cnt
        lda ld_csize + 1
        sta ld_cnt + 1
        lda fl_on
        beq ld_rd
        jsr fl_read                     ; fast: straight from the sector buffer
        jmp ld_rdone
ld_rd:  jsr ld_get
        ldy #0
        sta (ld_dst),y
        inc ld_dst
        bne :+
        inc ld_dst + 1
:       lda ld_cnt
        bne :+
        dec ld_cnt + 1
:       dec ld_cnt
        lda ld_cnt
        ora ld_cnt + 1
        bne ld_rd
ld_rdone:
        lda STATUS                      ; device missing, timeouts
        and #%10000011
        beq :+
        jmp ld_err
:
        jsr lz_unpack
        jsr ld_store
        jsr ld_progress
        jmp ld_block

ld_done:
        lda fl_on
        beq :+
        jsr fl_drain                    ; let the fast loader finish
:       jsr CLRCHN
        lda #2
        jsr CLOSE
        ; the signature last: only a complete load counts
        DMA_DESC 0, VICX_DMA_COPY, VICX_DMA_SRC_C64 | VICX_DMA_DST_XRAM, demo_sig, SIG_XRAM, 16, 0, 0, 0, 0, 0, VICX_DMA_NONE
        lda #0
        sta VICX_DMA_CMD
        rts

ld_err: jsr CLRCHN
        lda #2
        jsr CLOSE
        ldx #<msg_loaderr
        ldy #>msg_loaderr
        jmp demo_fail

        .include "uci.inc"             ; uci_load: the .reu from USB on an Ultimate
        .include "fastload.inc"        ; fl_start, fl_get: 1541 and 1581

ld_get: jmp (ld_getv)

; DMA LD_OUT (ld_raw bytes) to XRAM ld_xaddr; the CPU waits while it runs.
ld_store:
        VICX_P0_SET VICX_DMADESC, VICX_STEP_1
        lda #VICX_DMA_COPY
        sta VICX_P0_DATA
        lda #VICX_DMA_SRC_C64 | VICX_DMA_DST_XRAM
        sta VICX_P0_DATA
        lda #<LD_OUT
        sta VICX_P0_DATA
        lda #>LD_OUT
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        sta VICX_P0_DATA
        lda ld_xaddr
        sta VICX_P0_DATA
        lda ld_xaddr + 1
        sta VICX_P0_DATA
        lda ld_xaddr + 2
        sta VICX_P0_DATA
        lda #0
        sta VICX_P0_DATA
        lda ld_raw
        sta VICX_P0_DATA
        lda ld_raw + 1
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
        rts

; Unpack LD_IN into LD_OUT (ld_raw bytes).  Literals and matches are both
; copied with lz_copy, a page at a time.
lz_unpack:
        lda #<LD_IN
        sta ld_src
        lda #>LD_IN
        sta ld_src + 1
        lda #<LD_OUT
        sta ld_dst
        lda #>LD_OUT
        sta ld_dst + 1
        clc
        lda #<LD_OUT
        adc ld_raw
        sta ld_end
        lda #>LD_OUT
        adc ld_raw + 1
        sta ld_end + 1
lz_tok: jsr lz_get                      ; token
        sta ld_tok
        lsr
        lsr
        lsr
        lsr
        sta ld_cnt                      ; literal count
        lda #0
        sta ld_cnt + 1
        lda ld_cnt
        cmp #15
        bne :+
        jsr lz_ext
:       lda ld_cnt
        ora ld_cnt + 1
        beq lz_lend
        lda ld_src                      ; the literals
        sta ld_ref
        lda ld_src + 1
        sta ld_ref + 1
        jsr lz_copy
        lda ld_ref
        sta ld_src
        lda ld_ref + 1
        sta ld_src + 1
lz_lend:
        lda ld_dst + 1                  ; output full?
        cmp ld_end + 1
        bcc lz_match
        lda ld_dst
        cmp ld_end
        bcc lz_match
        rts
lz_match:
        jsr lz_get                      ; offset back from the output end
        sta ld_ref
        jsr lz_get
        sta ld_ref + 1
        sec
        lda ld_dst
        sbc ld_ref
        sta ld_ref
        lda ld_dst + 1
        sbc ld_ref + 1
        sta ld_ref + 1
        lda ld_tok                      ; match length - 3
        and #15
        sta ld_cnt
        lda #0
        sta ld_cnt + 1
        lda ld_cnt
        cmp #15
        bne :+
        jsr lz_ext
:       clc
        lda ld_cnt
        adc #3
        sta ld_cnt
        bcc :+
        inc ld_cnt + 1
:       jsr lz_copy
        jmp lz_tok

; Copy ld_cnt (> 0) bytes from (ld_ref) to (ld_dst), forward one byte at a
; time (so a match may overlap its own output); both pointers move on.
lz_copy:
        ldy #0
        ldx ld_cnt + 1                  ; whole pages
        beq @rest
@pg:    lda (ld_ref),y
        sta (ld_dst),y
        iny
        bne @pg
        inc ld_ref + 1
        inc ld_dst + 1
        dex
        bne @pg
@rest:  ldx ld_cnt
        beq @out
@r:     lda (ld_ref),y
        sta (ld_dst),y
        iny
        dex
        bne @r
        tya
        clc
        adc ld_ref
        sta ld_ref
        bcc :+
        inc ld_ref + 1
:       tya
        clc
        adc ld_dst
        sta ld_dst
        bcc @out
        inc ld_dst + 1
@out:   rts

lz_get: ldy #0
        lda (ld_src),y
        inc ld_src
        bne :+
        inc ld_src + 1
:       rts

; add extension bytes to ld_cnt until one is below 255
lz_ext: jsr lz_get
        pha
        clc
        adc ld_cnt
        sta ld_cnt
        bcc :+
        inc ld_cnt + 1
:       pla
        cmp #255
        beq lz_ext
        rts

; the loading screen: the file's name, and a 32-character bar on row 12
ld_screen:
        lda #0
        sta $D020
        sta $D021
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
        ldx #0
:       lda msg_loading,x
        beq :+
        and #$3F
        sta $0400 + 10 * 40 + 4,x
        inx
        bne :-
:       ldx #0
:       lda data_name,x
        cmp #$2C                        ; ','
        beq :+
        and #$3F
        sta $0400 + 10 * 40 + 23,x
        inx
        cpx #DATA_NAME_LEN
        bne :-
:       ldx #31
        lda #$2E                        ; '.'
:       sta $0400 + 12 * 40 + 4,x
        dex
        bpl :-
        rts

; one more block done: fill the bar in proportion (32 * blocks / total)
ld_progress:
        clc
        lda ld_acc
        adc #32
        sta ld_acc
:       lda ld_acc
        cmp #DATA_BLOCKS
        bcc :+
        sbc #DATA_BLOCKS
        sta ld_acc
        ldx ld_col
        lda #$A0                        ; reverse space
        sta $0400 + 12 * 40 + 4,x
        inc ld_col
        bne :-
:       rts

msg_loading:
        .byte "LOADING DEMO DATA:", 0
msg_loaderr:
        .byte "COULD NOT LOAD THE DEMO DATA.", 13, 13
        .byte "THE DATA FILE MUST BE ON THE SAME DISK", 13
        .byte "AS THE DEMO. ON AN ULTIMATE, THE .REU", 13
        .byte "FILE CAN BE IN THE DEMO'S USB FOLDER", 13
        .byte "(COMMAND INTERFACE ENABLED).", 0

.pushseg
.bss
ld_sig:   .res 16
ld_csize: .res 2
ld_xaddr: .res 3
ld_raw:   .res 2
ld_end:   .res 2
ld_tok:   .res 1
ld_acc:   .res 1
ld_col:   .res 1
.popseg
