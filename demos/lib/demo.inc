; demo.inc - start-up and helpers shared by the VIC-X demos
;
; A demo defines `main', `NEED_XRAM_MB' (0 if it needs no XRAM) and
; `CPU_TEXT' (where the CPU load readout goes), and includes its generated
; assets.inc, which names its data file.  Before `main', start-up loads that
; file into XRAM, unless XRAM already holds the demo's data.  Start-up
; runs with interrupts off, unlocks VIC-X and checks it is there; if not, it
; prints what to do and stops.

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
        lda #0
        sta cpu_max
        sta cpu_max + 1
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

; --- CPU load readout -----------------------------------------------------
; Call cpu_start when the frame's work begins and cpu_end when it is done.
; The raster line counts the time (one frame = 312 lines on PAL, 263 on
; NTSC; the KERNAL notes which at $02A6).  Every 16 frames the busiest of
; them is printed as "CPU nnn%" at screen address CPU_TEXT (defined by the
; demo, 8 characters).  cpu_start and cpu_end keep X and Y; they use A.

; Current raster line -> cpu_line (9 bits)
read_line:
:       lda $D012
        sta cpu_line
        lda $D011
        and #$80
        asl
        rol                             ; bit 8 -> bit 0
        sta cpu_line + 1
        lda $D012
        cmp cpu_line                    ; re-read if the line changed meanwhile
        bne :-
        rts

cpu_start:
        jsr read_line                   ; uses A only
        lda cpu_line
        sta cpu_t0
        lda cpu_line + 1
        sta cpu_t0 + 1
        rts

cpu_end:
        txa                             ; keep X and Y
        pha
        tya
        pha
        jsr cpu_measure
        pla
        tay
        pla
        tax
        rts

cpu_measure:
        jsr read_line
        sec                             ; lines = now - start (+ frame if wrapped)
        lda cpu_line
        sbc cpu_t0
        sta cpu_line
        lda cpu_line + 1
        sbc cpu_t0 + 1
        sta cpu_line + 1
        bpl :+
        jsr frame_lines
        clc
        lda cpu_line
        adc cpu_div
        sta cpu_line
        lda cpu_line + 1
        adc cpu_div + 1
        sta cpu_line + 1
:       lda cpu_line + 1                ; keep the highest
        cmp cpu_max + 1
        bcc @nomax
        bne @max
        lda cpu_line
        cmp cpu_max
        bcc @nomax
@max:   lda cpu_line
        sta cpu_max
        lda cpu_line + 1
        sta cpu_max + 1
@nomax: inc cpu_frames
        lda cpu_frames
        and #15
        beq :+
        rts
:       ; percent = max * 100 / frame lines
        lda cpu_max
        sta cpu_num
        lda cpu_max + 1
        sta cpu_num + 1
        asl cpu_num                     ; * 4
        rol cpu_num + 1
        asl cpu_num
        rol cpu_num + 1
        lda cpu_num                     ; keep max * 4
        sta cpu_line
        lda cpu_num + 1
        sta cpu_line + 1
        ldx #3                          ; * 32
:       asl cpu_num
        rol cpu_num + 1
        dex
        bne :-
        clc                             ; max * 32 + max * 4
        lda cpu_num
        adc cpu_line
        sta cpu_line
        lda cpu_num + 1
        adc cpu_line + 1
        sta cpu_line + 1
        asl cpu_num                     ; * 64
        rol cpu_num + 1
        clc                             ; + max * 64 = max * 100
        lda cpu_num
        adc cpu_line
        sta cpu_num
        lda cpu_num + 1
        adc cpu_line + 1
        sta cpu_num + 1
        jsr frame_lines
        lda #0                          ; 16-bit divide: cpu_num / cpu_div
        sta cpu_line
        sta cpu_line + 1
        ldx #16
:       asl cpu_num
        rol cpu_num + 1
        rol cpu_line
        rol cpu_line + 1
        lda cpu_line
        sec
        sbc cpu_div
        tay
        lda cpu_line + 1
        sbc cpu_div + 1
        bcc @skip
        sta cpu_line + 1
        sty cpu_line
        inc cpu_num
@skip:  dex
        bne :-
        ; print "CPU nnn%" (cpu_num < 256)
        ldx #0
:       lda cpu_label,x
        sta CPU_TEXT,x
        inx
        cpx #4
        bne :-
        lda cpu_num
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
        lda #$25                        ; %
        sta CPU_TEXT,x
        inx
        lda #$20
:       cpx #8
        beq :+
        sta CPU_TEXT,x
        inx
        bne :-
:       lda #0
        sta cpu_max
        sta cpu_max + 1
        rts

; cpu_div = raster lines per frame
frame_lines:
        lda $02A6
        beq :+
        lda #<312
        sta cpu_div
        lda #>312
        sta cpu_div + 1
        rts
:       lda #<263
        sta cpu_div
        lda #>263
        sta cpu_div + 1
        rts

cpu_label: .byte $03, $10, $15, $20     ; "CPU " in screen codes

.pushseg
.bss
cpu_line:   .res 2
cpu_t0:     .res 2
cpu_max:    .res 2
cpu_num:    .res 2
cpu_div:    .res 2
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

LD_IN   = $3000                 ; packed block (up to ~8.2 KB)
LD_OUT  = $6000                 ; unpacked block (8 KB)
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
STATUS  = $90
LAST_DEVICE = $BA

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
        jsr CHRIN                       ; "VX"
        cmp #$56
        beq :+
        jmp ld_err
:
        jsr CHRIN
        cmp #$58
        beq :+
        jmp ld_err
:
        lda #0
        sta ld_acc
        sta ld_col

ld_block:
        jsr CHRIN                       ; packed size, 0 = end
        sta ld_csize
        jsr CHRIN
        sta ld_csize + 1
        ora ld_csize
        beq ld_done
        jsr CHRIN                       ; XRAM address
        sta ld_xaddr
        jsr CHRIN
        sta ld_xaddr + 1
        jsr CHRIN
        sta ld_xaddr + 2
        jsr CHRIN                       ; unpacked size
        sta ld_raw
        jsr CHRIN
        sta ld_raw + 1
        lda #<LD_IN                     ; read the packed bytes
        sta ld_dst
        lda #>LD_IN
        sta ld_dst + 1
        lda ld_csize
        sta ld_cnt
        lda ld_csize + 1
        sta ld_cnt + 1
ld_rd:  jsr CHRIN
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
        jsr CLRCHN
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

; Unpack LD_IN into LD_OUT (ld_raw bytes).
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
lz_lit: jsr lz_get                      ; copy the literals
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
        bne lz_lit
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
:       ldy #0
lz_copy:
        lda (ld_ref),y
        sta (ld_dst),y
        inc ld_ref
        bne :+
        inc ld_ref + 1
:       inc ld_dst
        bne :+
        inc ld_dst + 1
:       lda ld_cnt
        bne :+
        dec ld_cnt + 1
:       dec ld_cnt
        lda ld_cnt
        ora ld_cnt + 1
        bne lz_copy
        jmp lz_tok

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
