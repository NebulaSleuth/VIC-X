; uci_probe.s - check the Ultimate Command Interface (UCI) on real hardware.
;
; Needs an Ultimate with "Command Interface" enabled and an REU of 2 MB or
; more. No VIC-X needed: this only tests the loading path the demos will use.
; run_uci_probe.py builds it, uploads PROBE_FILE to the Ultimate, runs it and
; reads the results back from RES (and the screen).
;
; Steps, each printed on screen:
;   1. the ID register $DF1D (expected $C9)
;   2. DOS IDENTIFY                       -> reply, status
;   3. GET_PATH (the path at start-up)    -> reply, status
;   4. COPY_HOME_PATH                     -> reply, status
;   5. CHANGE_DIR PROBE_DIR               -> status
;   6. OPEN_FILE PROBE_FILE (read)        -> status
;   7. LOAD_REU to REU $000000, PROBE_LEN -> reply, status, time in jiffies
;   8. CLOSE_FILE                         -> status
;   9. 16 bytes from REU $000000, $100000 and $1FFFF0, fetched by REU DMA
; Those REU areas are zeroed before step 7, so bytes that match the file
; prove the load.

UCI_CTRL   = $DF1C              ; write: control, read: status
UCI_CMD    = $DF1D              ; write: command data, read: ID ($C9)
UCI_RESP   = $DF1E              ; read: response data
UCI_STAT   = $DF1F              ; read: status data

ST_BUSY    = $01                ; status bits
ST_DACC    = $02
ST_ERR     = $08
ST_STATE   = $30                ; 00 idle, 10 busy, 20 last data, 30 more data
ST_STAT_AV = $40
ST_DATA_AV = $80
CT_PUSH    = $01                ; control bits
CT_DACC    = $02
CT_ABORT   = $04
CT_CLRERR  = $08

DOS        = $01                ; target DOS1
C_IDENTIFY = $01
C_OPEN     = $02
C_CLOSE    = $03
C_CD       = $11
C_GETPATH  = $12
C_HOME     = $17
C_LOADREU  = $21

REU_CMD    = $DF01
REU_C64    = $DF02
REU_REU    = $DF04
REU_LEN    = $DF07
REU_ACTRL  = $DF0A

CHROUT     = $FFD2
TI         = $A0                ; jiffy clock, $A0-$A2 (big-endian)

ptr        = $FB
rbuf       = $FD                ; result buffer pointer

        .include "probe_cfg.inc" ; PROBE_DIR, PROBE_FILE, PROBE_LEN

RES        = $C000              ; results for the host script:
RES_ID     = RES + $00          ;   ID register
RES_ERR    = RES + $08          ;   + n: 1 if step n set the error bit
RES_TIME   = RES + $02          ;   LOAD_REU time, 3 bytes, jiffies
RES_DONE   = RES + $05          ;   $AA when the probe finished
RES_REU0   = RES + $40          ;   REU $000000, 16 bytes
RES_REU1   = RES + $50          ;   REU $100000
RES_REU2   = RES + $60          ;   REU $1FFFF0
RES_TEXT   = RES + $100         ;   step n reply at RES_TEXT + n*$80,
                                ;   status at + $40, both NUL-terminated

        .segment "LOADADDR"
        .word $0801
        .segment "EXEHDR"
        .word :+, 10
        .byte $9E, "2061", 0
:       .word 0

        .code
start:
        lda #$93                ; clear screen
        jsr CHROUT
        ldx #0
        txa
:       sta RES,x
        sta RES + $100,x
        sta RES + $200,x
        sta RES + $300,x
        sta RES + $400,x
        sta RES + $500,x
        inx
        bne :-

        ; 1. ID
        ldx #<m_id
        ldy #>m_id
        jsr puts
        lda UCI_CMD
        sta RES_ID
        jsr puthex
        jsr newline
        lda RES_ID
        cmp #$C9
        beq :+
        ldx #<m_noid
        ldy #>m_noid
        jsr puts
        jmp finish
:
        lda #CT_ABORT | CT_CLRERR       ; start from idle
        sta UCI_CTRL

        lda #2
        ldx #<cmd_identify
        ldy #>cmd_identify
        jsr step
        lda #3
        ldx #<cmd_getpath
        ldy #>cmd_getpath
        jsr step
        lda #4
        ldx #<cmd_home
        ldy #>cmd_home
        jsr step
        lda #5
        ldx #<cmd_cd
        ldy #>cmd_cd
        jsr step
        lda #6
        ldx #<cmd_open
        ldy #>cmd_open
        jsr step

        jsr reu_clear
        sei                     ; read the clock atomically
        lda TI + 2
        sta t0
        lda TI + 1
        sta t0 + 1
        lda TI
        sta t0 + 2
        cli
        lda #7
        ldx #<cmd_loadreu
        ldy #>cmd_loadreu
        jsr step
        sei
        sec
        lda TI + 2
        sbc t0
        sta RES_TIME
        lda TI + 1
        sbc t0 + 1
        sta RES_TIME + 1
        lda TI
        sbc t0 + 2
        sta RES_TIME + 2
        cli
        ldx #<m_time
        ldy #>m_time
        jsr puts
        lda RES_TIME + 2
        jsr puthex
        lda RES_TIME + 1
        jsr puthex
        lda RES_TIME
        jsr puthex
        jsr newline

        lda #8
        ldx #<cmd_close
        ldy #>cmd_close
        jsr step

        ; 9. what the REU holds now
        lda #$00
        ldx #<RES_REU0
        jsr reu_fetch16
        lda #$10
        ldx #<RES_REU1
        jsr reu_fetch16
        lda #$1F
        ldx #<RES_REU2
        jsr reu_fetch16
        ldx #0
:       lda RES_REU2,x
        jsr puthex
        inx
        cpx #8
        bne :-
        jsr newline

finish: lda #$AA
        sta RES_DONE
        ldx #<m_done
        ldy #>m_done
        jsr puts
        rts

; --- run one UCI command ---------------------------------------------------
; A = step number, X/Y = command: length byte, then the bytes.
; Prints "n R:reply" and "  S:status", stores both under RES_TEXT.
step:
        sta stepno
        stx ptr
        sty ptr + 1
        lda #0                  ; result buffer for this step
        sta rbuf
        lda stepno
        lsr a
        sta rbuf + 1
        lda #0
        ror a
        sta rbuf
        clc
        lda rbuf + 1
        adc #>RES_TEXT
        sta rbuf + 1

        ldy #0                  ; send the command
        lda (ptr),y
        sta cnt
:       iny
        lda (ptr),y
        sta UCI_CMD
        cpy cnt
        bne :-
        lda #CT_PUSH
        sta UCI_CTRL

wait:   lda UCI_CTRL            ; wait while busy
        and #ST_STATE
        cmp #$10
        beq wait
        lda UCI_CTRL
        and #ST_BUSY
        bne wait

        lda UCI_CTRL
        and #ST_ERR
        beq :+
        ldx stepno              ; record and clear the error bit
        lda #1
        sta RES_ERR,x
        lda #CT_CLRERR
        sta UCI_CTRL
:
        lda stepno
        ora #$30
        jsr CHROUT
        lda #' '
        jsr CHROUT
        lda #'R'
        jsr CHROUT
        lda #':'
        jsr CHROUT

        ldy #0                  ; reply
rd:     lda UCI_CTRL
        and #ST_DATA_AV
        beq rd_end
        lda UCI_RESP
        cpy #$3F
        bcs rd
        jsr store_put
        jmp rd
rd_end: lda #0
        sta (rbuf),y
        jsr newline

        lda #' '
        jsr CHROUT
        jsr CHROUT
        lda #'S'
        jsr CHROUT
        lda #':'
        jsr CHROUT
        ldy #$40                ; status
st:     lda UCI_CTRL
        and #ST_STAT_AV
        beq st_end
        lda UCI_STAT
        cpy #$7F
        bcs st
        jsr store_put
        jmp st
st_end: lda #0
        sta (rbuf),y
        jsr newline

        lda UCI_CTRL            ; more data? (not expected here: ack and drop)
        and #ST_STATE
        beq :+
        lda #CT_DACC
        sta UCI_CTRL
:       lda UCI_CTRL
        and #ST_DACC
        bne :-
        rts

store_put:                      ; store A at (rbuf),y, print it, y++
        sta (rbuf),y
        iny
        cmp #$61                ; ASCII lower case -> PETSCII upper case
        bcc :+
        cmp #$7B
        bcs :+
        and #$DF
:       cmp #$20
        bcs :+
        lda #'.'
:       jmp CHROUT

; --- REU helpers ------------------------------------------------------------
reu_clear:                      ; zero 16 bytes at $000000, $100000, $1FFFF0
        lda #$00
        jsr rc1
        lda #$10
        jsr rc1
        lda #$1F
rc1:    sta rbank
        lda #<zeros
        sta REU_C64
        lda #>zeros
        sta REU_C64 + 1
        jsr reu_addr
        lda #$90                ; stash
        sta REU_CMD
        rts

reu_fetch16:                    ; A = bank ($1F: offset $FFF0), X = low byte of dest
        sta rbank
        stx REU_C64
        lda #>RES
        sta REU_C64 + 1
        jsr reu_addr
        lda #$91                ; fetch
        sta REU_CMD
        rts

reu_addr:
        lda #0
        sta REU_ACTRL
        lda rbank
        cmp #$1F
        bne :+
        lda #$F0
        sta REU_REU
        lda #$FF
        sta REU_REU + 1
        bne :++
:       lda #0
        sta REU_REU
        sta REU_REU + 1
:       lda rbank
        sta REU_REU + 2
        lda #16
        sta REU_LEN
        lda #0
        sta REU_LEN + 1
        rts

; --- output -----------------------------------------------------------------
puts:   stx ptr
        sty ptr + 1
        ldy #0
:       lda (ptr),y
        beq :+
        jsr CHROUT
        iny
        bne :-
:       rts

newline:
        lda #13
        jmp CHROUT

puthex: pha
        lsr a
        lsr a
        lsr a
        lsr a
        jsr :+
        pla
        and #15
:       cmp #10
        bcc :+
        adc #6
:       adc #'0'
        jmp CHROUT

; --- data -------------------------------------------------------------------
        .rodata
m_id:   .byte "VIC-X UCI PROBE", 13, "1 ID $", 0
m_noid: .byte "NO COMMAND INTERFACE", 13, 0
m_time: .byte "  T:$", 0
m_done: .byte "DONE", 13, 0

cmd_identify: .byte 2, DOS, C_IDENTIFY
cmd_getpath:  .byte 2, DOS, C_GETPATH
cmd_home:     .byte 2, DOS, C_HOME
cmd_cd:       .byte cd_end - cmd_cd - 1, DOS, C_CD
              .byte PROBE_DIR
cd_end:
cmd_open:     .byte open_end - cmd_open - 1, DOS, C_OPEN, $01
              .byte PROBE_FILE
open_end:
cmd_loadreu:  .byte 10, DOS, C_LOADREU
              .dword 0                  ; REU address
              .dword PROBE_LEN          ; length
cmd_close:    .byte 2, DOS, C_CLOSE
zeros:        .res 16, 0

        .bss
stepno: .res 1
cnt:    .res 1
rbank:  .res 1
t0:     .res 3
