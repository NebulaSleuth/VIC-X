; fastload.inc - a fast loader for the demos' data file, for 1541 and 1581.
;
; Needs, from the includer: data_name / DATA_NAME_LEN (assets.inc), ld_src
; (a zero-page word), ld_err, SETNAM, SETLFS, OPEN, CLOSE, CHKIN, CLRCHN,
; CHRIN, STATUS, LAST_DEVICE.
;
; fl_start finds out what drive the data is on by reading its ROM (M-R):
; "154" at $E5C4 is a 1541 (1541-II and DolphinDOS too), "158" at $A6E7 a
; 1581.  For either, it sends I0, puts the drive code below into drive RAM
; at $0500 (M-W) and starts it (M-E); carry clear.  Anything else (1571,
; SD2IEC, a virtual drive, no drive) gives carry set, and the caller loads
; with the KERNAL as before.
;
; The drive code finds the file in the directory and reads its sectors
; through the job queue (buffer 0, $0300).  For each sector it sends a byte
; count (1-254) and the sector's data bytes; after the last sector a 0, and
; $FF if the file is not there or a sector cannot be read.  Then it resets
; the drive.  fl_get hands the file to the loader a byte at a time, in
; place of CHRIN; fl_read copies a run of bytes from the sector buffer.
;
; A byte goes over CLK and DATA, two bits at a time, timed from a handshake:
; the drive releases CLK when it has a byte ready; the C64 pulls DATA, then
; releases it (time R); from the drive seeing the release, it puts four
; pairs on the lines for 16 us each (the inverted byte's bits 1/3, 0/2, 5/7,
; 4/6 on DATA/CLK; the C64 sorts them back with fl_dec), the first 12 us
; after it saw the release, then pulls CLK again (busy).  The drive polls
; DATA every 9 cycles (4.5 us on the 2 MHz 1581), so a pair is on the lines
; from at most R+21 to at least R+28 us (+16 for each later pair), and the
; C64 reads at R+24, +40, +56, +72 cycles.  Nothing may stop the C64 from R
; to R+72: VIC-II sprites are off, interrupts are off (the demos run with
; SEI), and the release is timed around badlines: at once when none can
; come in this line or the next two, else about 30 cycles into a raster
; line, so a badline's stall on that line comes before R (and one line
; later if the next line is a badline).  The drive waits for the release
; however long it takes.  PAL and NTSC C64 clocks are within 2.3% of the
; drive's 1 MHz.
;
; The 1541 reads a sector, sends it, then reads the next: the data file is
; written with its sectors about 122 ms apart (tools/d64write.py), or each
; one is missed and waits a whole turn.  The 1581 reads whole tracks into
; its cache.

FL_ORG = $0500

; Delay n cycles (n = 0 or 2 or more).
.macro FL_DLY n
  .if (n) > 0
    .if (n) .mod 2
        bit $00
      .repeat ((n) - 3) / 2
        nop
      .endrepeat
    .else
      .repeat (n) / 2
        nop
      .endrepeat
    .endif
  .endif
.endmacro

; The drive code.  PORT: the serial port (bit 0 DATA in, 1 DATA out, 3 CLK
; out; out bits pull low).  SPD: 1 for 1 MHz, 2 for 2 MHz.  JOB, HT, HS:
; buffer 0's job code and header track/sector.  DIRT/DIRS: the directory's
; first sector.
.macro FL_DRIVE PORT, SPD, JOB, HT, HS, DIRT, DIRS
BUF   = $0300
BUSY  = $08                     ; CLK low
READY = $00

start:  sei
        lda #BUSY
        sta PORT
        lda #DIRT
        sta ftrk
        lda #DIRS
        sta fsec
dirsec: jsr rdsec
        bcs fail
        lda #2
        sta ebase
entry:  ldx ebase
        lda BUF,x               ; file type, 0 = empty or deleted
        beq next
        ldy #0
cmpn:   lda BUF+3,x
        cmp name,y
        bne next
        inx
        iny
        cpy #16
        bne cmpn
        ldx ebase               ; found: its first sector
        lda BUF+1,x
        sta ftrk
        lda BUF+2,x
        sta fsec
        jmp file
next:   lda ebase
        clc
        adc #32
        sta ebase
        bcc entry
        lda BUF                 ; the next directory sector
        beq fail
        sta ftrk
        lda BUF+1
        sta fsec
        jmp dirsec
fail:   lda #$FF
        jsr send
        jmp ($FFFC)

file:   jsr rdsec
        bcs fail
        ldx #254
        lda BUF
        bne full
        ldx BUF+1               ; the last sector: bytes 2 to BUF+1
        dex
full:   stx cnt
        txa
        jsr send
        lda #2
        sta idx
sbyte:  ldx idx
        lda BUF,x
        jsr send
        inc idx
        dec cnt
        bne sbyte
        lda BUF
        beq done
        sta ftrk
        lda BUF+1
        sta fsec
        jmp file
done:   lda #0
        jsr send
        jmp ($FFFC)

; Read sector trk/sec into buffer 0; carry set if it cannot be read.
rdsec:  lda #5
        sta rtry
again:  lda ftrk
        sta HT
        lda fsec
        sta HS
        lda #$80                ; read
        sta JOB
        cli                     ; the controller runs from the IRQ
waitj:  lda JOB
        bmi waitj
        sei
        cmp #2                  ; 0 or 1: done
        bcc rdok
        dec rtry
        bne again
        sec
rdok:   rts

; Send A.  The port gets the inverted byte's bits 1 and 3 (DATA, CLK),
; then 0 and 2, 5 and 7, 4 and 6; the C64 sorts them back with a table.
send:   eor #$FF
        sta t
        and #$0A
        sta w1
        lda t
        lsr
        lsr
        lsr
        lsr
        sta t2
        lda #READY
        sta PORT
waitl:  lda PORT                ; the C64 pulls DATA ...
        lsr
        bcc waitl
waith:  lda PORT                ; ... and releases it
        lsr
        bcs waith
        FL_DLY 12 * SPD - 12    ; first pair 12 us after
        lda w1                  ; 8 cycles
        sta PORT
        FL_DLY 16 * SPD - 12
        lda t                   ; 12
        asl
        and #$0A
        sta PORT
        FL_DLY 16 * SPD - 10
        lda t2                  ; 10
        and #$0A
        sta PORT
        FL_DLY 16 * SPD - 12
        lda t2                  ; 12
        asl
        and #$0A
        sta PORT
        FL_DLY 16 * SPD - 6
        lda #BUSY
        sta PORT
        rts

t:      .byte 0
t2:     .byte 0
w1:     .byte 0
ftrk:   .byte 0
fsec:   .byte 0
ebase:  .byte 0
cnt:    .byte 0
idx:    .byte 0
rtry:   .byte 0
name:   .res 16, $A0
.endmacro

.pushseg
.rodata
fl1541_img:
.scope fl1541
        .org ::FL_ORG
        FL_DRIVE $1800, 1, $00, $06, $07, 18, 1
        .reloc
.endscope
fl1541_end:
fl1581_img:
.scope fl1581
        .org ::FL_ORG
        FL_DRIVE $4001, 2, $02, $0B, $0C, 40, 3
        .reloc
.endscope
fl1581_end:

fl_mr1541: .byte "M-R", $C4, $E5, 4
fl_mr1581: .byte "M-R", $E7, $A6, 4
fl_id1541: .byte "154", $B1
fl_id1581: .byte "158", $B1
fl_i0:     .byte "I0"
fl_src:    .byte $08, $02, $04, $01, $80, $20, $40, $10   ; byte bit for bit n
fl_bitv:   .byte $01, $02, $04, $08, $10, $20, $40, $80
.popseg

.pushseg
.bss
fl_dev:   .res 1
fl_type:  .res 1                ; 0: 1541, 1: 1581
fl_rel:   .res 1                ; $DD00 with CLK and DATA released
fl_pull:  .res 1                ; ... and DATA pulled
fl_k:     .res 1                ; what the port's other bits add to a byte
fl_sx:    .res 1
fl_end:   .res 1
fl_on:    .res 1                ; the fast loader runs
fl_pos:   .res 1
fl_cnt:   .res 1
fl_left:  .res 2
fl_daddr: .res 2
fl_sig:   .res 4
fl_cmd:   .res 40
fl_buf:   .res 256
fl_dec:   .res 256              ; what arrives -> the byte
.popseg

; Open the command channel with the command in fl_cmd (A bytes long), so
; the drive runs it.  Carry set if the device did not answer.
fl_open:
        ldx #<fl_cmd
        ldy #>fl_cmd
        jsr SETNAM
        lda #15
        ldx fl_dev
        ldy #15
        jsr SETLFS
        lda #0
        sta STATUS
        jsr OPEN
        bcs :+
        lda STATUS
        bmi :+
        clc
        rts
:       jsr CLALL               ; forget the file without talking to the bus
        sec
        rts

; Run a command (fl_cmd, A bytes) and close the channel.
fl_do:  jsr fl_open
        bcs :+
        lda #15
        jsr CLOSE
        clc
:       rts

; Copy A bytes from Y:X to fl_cmd.
fl_setcmd:
        stx ld_src
        sty ld_src + 1
        tax
        ldy #0
:       lda (ld_src),y
        sta fl_cmd,y
        iny
        dex
        bne :-
        rts

; Read 4 bytes of drive memory (the M-R command at Y:X) into fl_sig.
fl_mr:  lda #6
        jsr fl_setcmd
        lda #6
        jsr fl_open
        bcs @out
        ldx #15
        jsr CHKIN
        lda #0
        sta fl_pos
:       jsr CHRIN
        ldx fl_pos
        sta fl_sig,x
        inc fl_pos
        lda fl_pos
        cmp #4
        bne :-
        jsr CLRCHN
        lda #15
        jsr CLOSE
        clc
@out:   rts

; Compare fl_sig with the 4 bytes at Y:X; Z set if equal.
fl_cmp: stx ld_src
        sty ld_src + 1
        ldy #3
:       lda (ld_src),y
        cmp fl_sig,y
        bne :+
        dey
        bpl :-
        lda #0
:       rts

fl_start:
        lda #0
        sta fl_on
        lda LAST_DEVICE
        bne :+
        lda #8
:       sta fl_dev
        ldx #<fl_mr1541
        ldy #>fl_mr1541
        jsr fl_mr
        bcs @no
        ldx #<fl_id1541
        ldy #>fl_id1541
        jsr fl_cmp
        bne @not41
        lda #0
        beq @known
@not41: ldx #<fl_mr1581
        ldy #>fl_mr1581
        jsr fl_mr
        bcs @no
        ldx #<fl_id1581
        ldy #>fl_id1581
        jsr fl_cmp
        bne @no
        lda #1
@known: sta fl_type
        ldx #<fl_i0                     ; the disk's ID for the job queue
        ldy #>fl_i0
        lda #2
        jsr fl_setcmd
        lda #2
        jsr fl_do
        bcc @name
@no:    sec
        rts

        ; the file name, padded with $A0, into the drive code
@name:  lda fl_type
        bne :+
        lda #<(fl1541_img + fl1541::name - FL_ORG)
        ldx #>(fl1541_img + fl1541::name - FL_ORG)
        bne :++
:       lda #<(fl1581_img + fl1581::name - FL_ORG)
        ldx #>(fl1581_img + fl1581::name - FL_ORG)
:       sta ld_src
        stx ld_src + 1
        ldy #0
:       lda data_name,y
        cmp #','
        beq :+
        sta (ld_src),y
        iny
        cpy #DATA_NAME_LEN
        bne :-
:       lda #$A0
:       cpy #16
        beq :+
        sta (ld_src),y
        iny
        bne :-
:
        ; upload with M-W, 32 bytes at a time
        lda fl_type
        bne :+
        lda #<fl1541_img
        ldx #>fl1541_img
        ldy #<(fl1541_end - fl1541_img)
        sty fl_left
        ldy #>(fl1541_end - fl1541_img)
        bne :++
:       lda #<fl1581_img
        ldx #>fl1581_img
        ldy #<(fl1581_end - fl1581_img)
        sty fl_left
        ldy #>(fl1581_end - fl1581_img)
:       sty fl_left + 1
        sta ld_src
        stx ld_src + 1
        lda #<FL_ORG
        sta fl_daddr
        lda #>FL_ORG
        sta fl_daddr + 1
@up:    lda fl_left
        ora fl_left + 1
        beq @run
        ldx #32                         ; this chunk: min(32, left)
        lda fl_left + 1
        bne :+
        cpx fl_left
        bcc :+
        ldx fl_left
:       stx fl_cmd + 5
        lda #'M'
        sta fl_cmd
        lda #'-'
        sta fl_cmd + 1
        lda #'W'
        sta fl_cmd + 2
        lda fl_daddr
        sta fl_cmd + 3
        lda fl_daddr + 1
        sta fl_cmd + 4
        ldy #0
:       lda (ld_src),y
        sta fl_cmd + 6,y
        iny
        dex
        bne :-
        tya                             ; advance by the chunk
        clc
        adc ld_src
        sta ld_src
        bcc :+
        inc ld_src + 1
:       tya
        clc
        adc fl_daddr
        sta fl_daddr
        bcc :+
        inc fl_daddr + 1
:       sty fl_cmd + 39                 ; (scratch)
        sec
        lda fl_left
        sbc fl_cmd + 39
        sta fl_left
        bcs :+
        dec fl_left + 1
:       tya
        clc
        adc #6
        jsr fl_do
        bcc :+
        jmp @no
:       jmp @up

        ; start it: M-E, then forget channel 15 without a CLOSE (the drive
        ; no longer listens to the bus)
@run:   lda #'M'
        sta fl_cmd
        lda #'-'
        sta fl_cmd + 1
        lda #'E'
        sta fl_cmd + 2
        lda #<FL_ORG
        sta fl_cmd + 3
        lda #>FL_ORG
        sta fl_cmd + 4
        lda #5
        jsr fl_open
        bcc :+
        jmp @no
:       jsr CLALL

        lda #0
        sta $D015                       ; VIC-II sprites off: no stolen cycles
.ifdef FL_BLANKTEST
        lda $D011
        and #$EF
        sta $D011
        lda #0
.endif
        sta STATUS
        sta fl_pos
        sta fl_cnt
        lda $DD00                       ; CLK, DATA and ATN released
        and #$07
        sta fl_rel
        sta $DD00
        ora #$20
        sta fl_pull
        lda fl_rel                      ; K = c ^ c>>2 ^ c>>4
        lsr
        lsr
        eor fl_rel
        lsr
        lsr
        eor fl_rel
        sta fl_k
        ldx #0                          ; the table: byte b arrives as
@tb:    stx fl_sx                       ; b4 b6 b5 b7 b0 b2 b1 b3, eor K
        lda #0
        sta fl_pos
        ldy #7
@bit:   lda fl_sx
        and fl_src,y
        beq :+
        lda fl_pos
        ora fl_bitv,y
        sta fl_pos
:       dey
        bpl @bit
        lda fl_pos
        eor fl_k
        tay
        txa
        sta fl_dec,y
        inx
        bne @tb
        stx fl_pos
        inc fl_on
        ldx #8                          ; let the drive code start (it
:       lda $D012                       ; pulls CLK at once): ~4 frames
        bne :-
:       lda $D012
        beq :-
        dex
        bne :--
        clc
        rts

; One byte from the drive.  Keeps X and Y.
fl_byte:
        bit $DD00                       ; drive ready: CLK high
        bvc fl_byte
        stx fl_sx
        lda $D012                       ; no badline this line or the next
        sec                             ; two: go at once
        sbc $D011
        and #7
        beq @sync
        cmp #6
        bcs @sync
        lda fl_pull
        sta $DD00                       ; pull DATA
        FL_DLY 12
        jmp @go
@sync:  lda fl_pull
        sta $DD00                       ; pull DATA (the drive waits for the release)
        ldx $D012
:       cpx $D012                       ; start on a raster line, R about 30
        beq :-                          ; cycles in: R..R+72 then has no
        inx                             ; badline stall in it, unless the
        txa                             ; next line is a badline
        sec
        sbc $D011
        and #7
        cmp #7
        bne @go
        ldx $D012                       ; it is: start on that line, R after
:       cpx $D012                       ; its stall (cycles 15-54)
        beq :-
        FL_DLY 16
@go:    lda fl_rel
        sta $DD00                       ; release: R
        FL_DLY 20
        lda $DD00                       ; R+24: bits 1-0 in 7-6
        lsr
        lsr
        FL_DLY 8
        eor $DD00                       ; R+40: bits 3-2
        lsr
        lsr
        FL_DLY 8
        eor $DD00                       ; R+56: bits 5-4
        lsr
        lsr
        FL_DLY 8
        eor $DD00                       ; R+72: bits 7-6
        tax                             ; sort the bits back
        lda fl_dec,x
        ldx fl_sx
        rts

; The next sector into fl_buf.
fl_fill:
        jsr fl_byte                     ; its byte count
        cmp #0
        beq fl_bad
        cmp #$FF
        beq fl_bad
        sta fl_cnt
        ldy #0
:       jsr fl_byte
        sta fl_buf,y
        iny
        cpy fl_cnt
        bne :-
        lda #0
        sta fl_pos
        rts
fl_bad: jmp ld_err

; The next byte of the file, in place of CHRIN.
fl_get: ldy fl_pos
        cpy fl_cnt
        bcc :+
        jsr fl_fill
        ldy #0
:       lda fl_buf,y
        inc fl_pos
        rts

; The next ld_cnt (> 0) bytes of the file to (ld_dst), straight from the
; sector buffer; ld_dst and ld_cnt are moved on.
fl_read:
@next:  ldy fl_pos
        cpy fl_cnt
        bcc :+
        jsr fl_fill
        ldy #0
:       sty fl_sx                       ; from here to the sector's end, or
        lda ld_cnt + 1                  ; fewer if that is all that is wanted
        bne @all
        tya
        clc
        adc ld_cnt
        bcs @all
        cmp fl_cnt
        bcc @end
@all:   lda fl_cnt
@end:   sta fl_end
        sec                             ; ld_ref + y = ld_dst + (y - start)
        lda ld_dst
        sbc fl_sx
        sta ld_ref
        lda ld_dst + 1
        sbc #0
        sta ld_ref + 1
@cp:    lda fl_buf,y
        sta (ld_ref),y
        iny
        cpy fl_end
        bne @cp
        sty fl_pos
        tya
        sec
        sbc fl_sx
        sta fl_sx                       ; bytes copied
        clc
        adc ld_dst
        sta ld_dst
        bcc :+
        inc ld_dst + 1
:       sec
        lda ld_cnt
        sbc fl_sx
        sta ld_cnt
        bcs :+
        dec ld_cnt + 1
:       lda ld_cnt
        ora ld_cnt + 1
        bne @next
        rts

; After the last block: take what the drive still sends, up to its end
; marker, so it finishes and resets.
fl_drain:
        jsr fl_byte
        cmp #0
        beq @out
        cmp #$FF
        beq @out
        tax
:       jsr fl_byte
        dex
        bne :-
        beq fl_drain
@out:   rts
