; uci_loader_test.s - run the demos' UCI loader (demos/lib/uci.inc) on an
; Ultimate without VIC-X. XRAM_TO_C64 is done with REU DMA here, which reads
; the same memory. run_uci_loader.py builds and runs it.
;
; Zeroes the signature at REU $1FFFF0, changes to TEST_DIR (standing in for
; the file browser's directory), calls uci_load and leaves:
;   $C000  $AA when done
;   $C001  carry from uci_load (0 = loaded, 1 = not)
;   $C002  time in jiffies, 3 bytes
;   $C010  16 bytes from REU $1FFFF0

        .include "loader_cfg.inc"       ; TEST_DIR, TEST_NAME, TEST_SIG

RES       = $C000
TI        = $A0
ld_src    = $F0
ld_cnt    = $F6
SIG_XRAM  = $1FFFF0
REU_IMAGE_LEN = $200000
REU_NAME_LEN  = .strlen(TEST_NAME)

.macro XRAM_TO_C64 xsrc, cdst, len
        lda #<(cdst)
        sta $DF02
        lda #>(cdst)
        sta $DF03
        lda #<(xsrc)
        sta $DF04
        lda #>(xsrc)
        sta $DF05
        lda #^(xsrc)
        sta $DF06
        lda #<(len)
        sta $DF07
        lda #>(len)
        sta $DF08
        lda #0
        sta $DF0A
        lda #$91                ; fetch
        sta $DF01
.endmacro

        .segment "LOADADDR"
        .word $0801
        .segment "EXEHDR"
        .word :+, 10
        .byte $9E, "2061", 0
:       .word 0

        .code
start:  lda #0
        ldx #$1F
:       sta RES,x
        dex
        bpl :-
        lda #<zeros             ; zero the signature in the REU
        sta $DF02
        lda #>zeros
        sta $DF03
        lda #<SIG_XRAM
        sta $DF04
        lda #>SIG_XRAM
        sta $DF05
        lda #^SIG_XRAM
        sta $DF06
        lda #16
        sta $DF07
        lda #0
        sta $DF08
        sta $DF0A
        lda #$90                ; stash
        sta $DF01

        lda UCI_CMD             ; change to TEST_DIR first (if UCI is there)
        cmp #UCI_ID
        bne :+
        lda #$0C
        sta UCI_CTRL
        ldx #<cmd_cd
        ldy #>cmd_cd
        lda #cd_end - cmd_cd
        jsr uci_send
        jsr uci_exec
:
        sei
        lda TI + 2
        sta t0
        lda TI + 1
        sta t0 + 1
        lda TI
        sta t0 + 2
        cli
        jsr uci_load
        lda #0
        rol a
        sta RES + 1
        sei
        sec
        lda TI + 2
        sbc t0
        sta RES + 2
        lda TI + 1
        sbc t0 + 1
        sta RES + 3
        lda TI
        sbc t0 + 2
        sta RES + 4
        cli
        XRAM_TO_C64 SIG_XRAM, RES + $10, 16
        lda #$AA
        sta RES
        rts

        .include "uci.inc"

        .rodata
cmd_cd:   .byte $01, $11, TEST_DIR
cd_end:
reu_name: .byte TEST_NAME
demo_sig: .byte TEST_SIG
zeros:    .res 16, 0

        .bss
ld_sig: .res 16
t0:     .res 3
