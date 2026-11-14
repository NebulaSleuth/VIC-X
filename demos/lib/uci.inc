; uci.inc - load a demo's REU image through the Ultimate Command Interface.
;
; Needs, from the includer: XRAM_TO_C64 (macro), SIG_XRAM, demo_sig,
; reu_name, REU_NAME_LEN, REU_IMAGE_LEN (assets.inc), ld_sig (16 bytes) and
; the zero-page words ld_src and ld_cnt.

; On an Ultimate (U64, C64 Ultimate) with "Command Interface" on, the DOS
; target loads <demo>.reu from the current directory (where the file browser
; is), or else from the home directory, straight into the REU, which is
; XRAM: about 0.2 s for 2 MB. Carry clear when the demo's signature is in
; XRAM afterwards; carry set (nothing changed or a partial load) sends the
; caller to the KERNAL loader. Without UCI, $DF1D does not read $C9 and
; nothing else is touched. Checked on an Ultimate 64 Elite, firmware 3.15a
; (tests/hw/uci_probe.s).

UCI_CTRL  = $DF1C               ; write: control, read: status
UCI_CMD   = $DF1D               ; write: command data, read: ID ($C9)
UCI_RESP  = $DF1E               ; read: reply data
UCI_STAT  = $DF1F               ; read: status data
UCI_ID    = $C9

uci_load:
        lda UCI_CMD
        cmp #UCI_ID
        beq @go
@fail:  sec
        rts
@go:
        lda #$0C                        ; abort anything pending, clear error
        sta UCI_CTRL
        jsr uci_open
        bcc @load
        ldx #<uci_c_home                ; not here: try the home directory
        ldy #>uci_c_home
        lda #2
        jsr uci_send
        jsr uci_exec
        jsr uci_open
        bcs @fail
@load:  ldx #<uci_c_loadreu
        ldy #>uci_c_loadreu
        lda #10
        jsr uci_send
        jsr uci_exec
        php
        ldx #<uci_c_close
        ldy #>uci_c_close
        lda #2
        jsr uci_send
        jsr uci_exec
        plp
        bcs @fail
        XRAM_TO_C64 SIG_XRAM, ld_sig, 16  ; the whole image arrived?
        ldx #15
:       lda ld_sig,x
        cmp demo_sig,x
        bne @no
        dex
        bpl :-
        clc
        rts
@no:    sec
        rts

uci_open:                               ; OPEN_FILE reu_name for reading
        ldx #<uci_c_open
        ldy #>uci_c_open
        lda #3
        jsr uci_send
        ldx #<reu_name
        ldy #>reu_name
        lda #REU_NAME_LEN
        jsr uci_send
        jmp uci_exec

; Write A bytes from Y:X to the command register.
uci_send:
        stx ld_src
        sty ld_src + 1
        tax
        ldy #0
:       lda (ld_src),y
        sta UCI_CMD
        iny
        dex
        bne :-
        rts

; Push the command, wait for it (about 20 s at most), drop the reply, keep
; the status's first two characters, acknowledge. Carry clear for "00".
uci_exec:
        lda #$01                        ; push
        sta UCI_CTRL
        lda #0
        sta ld_cnt
        sta ld_cnt + 1
        lda #16                         ; about 20 s: a slow USB stick
        sta uci_t
@wait:  lda UCI_CTRL
        and #$31                        ; busy bit, or state "processing"
        cmp #$10
        beq @tick
        and #$01
        beq @done
@tick:  inc ld_cnt
        bne @wait
        inc ld_cnt + 1
        bne @wait
        dec uci_t
        bne @wait
        lda #$04                        ; timed out: abort
        sta UCI_CTRL
        sec
        rts
@done:  lda #0
        sta uci_st
        sta uci_st + 1
:       lda UCI_CTRL                    ; reply: not needed
        bpl :+
        lda UCI_RESP
        jmp :-
:       ldx #0
:       lda UCI_CTRL                    ; status, e.g. "00,OK"
        and #$40
        beq :+
        lda UCI_STAT
        cpx #2
        bcs :-
        sta uci_st,x
        inx
        bne :-
:       lda UCI_CTRL
        tax
        and #$30                        ; data state: acknowledge it
        beq :+
        lda #$02
        sta UCI_CTRL
:       txa
        and #$08                        ; error bit
        beq :+
        lda #$08
        sta UCI_CTRL
        sec
        rts
:       ldx #0                          ; wait for the acknowledge to land
:       lda UCI_CTRL
        and #$02
        beq :+
        dex
        bne :-
:       lda uci_st
        cmp #'0'
        bne :+
        lda uci_st + 1
        cmp #'0'
        bne :+
        clc
        rts
:       sec
        rts

        .pushseg
        .rodata
uci_c_open:    .byte $01, $02, $01              ; DOS1, OPEN_FILE, read
uci_c_home:    .byte $01, $17                   ; DOS1, COPY_HOME_PATH
uci_c_loadreu: .byte $01, $21                   ; DOS1, LOAD_REU
               .dword 0, REU_IMAGE_LEN          ;   to REU 0, the whole image
uci_c_close:   .byte $01, $03                   ; DOS1, CLOSE_FILE
        .bss
uci_st: .res 2
uci_t:  .res 1
        .popseg

