; streamplay.s - plays a SID register stream from XRAM, for listening to and
; recording (tools/sound/render_wav.py).  The stream starts at XRAM 0: 32
; bytes a frame, the 25 SID registers first.  Each frame (at raster line
; 251) window 0 at $6000 shows the frame's 8 KB page and the 25 bytes go to
; the SID, highest first (so the envelope is set before the gate).

.include "harness.inc"

ptr = $FB
frm = $FD                       ; 2 bytes: the frame

.code
main:
        VICX_UNLOCK_SEQ
        lda #VICX_SLOT_6000 | VICX_SLOT_ON
        sta VICX_W0_SLOT
        lda #0
        sta frm
        sta frm + 1
loop:
:       lda $D012                       ; wait for line 251
        cmp #251
        bne :-
        lda $D011
        bmi :-
        lda frm + 1                     ; page = frame / 256
        sta VICX_W0_PAGEL
        lda #0
        sta VICX_W0_PAGEH
        lda frm                         ; $6000 + (frame & 255) * 32
        lsr
        lsr
        lsr
        clc
        adc #$60
        sta ptr + 1
        lda frm
        asl
        asl
        asl
        asl
        asl
        sta ptr
        ldy #24
:       lda (ptr),y
        sta $D400,y
        dey
        bpl :-
        inc frm
        bne :+
        inc frm + 1
:
:       lda $D012                       ; past line 251
        cmp #251
        beq :-
        jmp loop
