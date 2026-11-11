; sixteen.s - Any sixteen colours: a plain C64 multicolour bitmap, in the
; stock palette and in sixteen colours chosen for the picture.
;
; Both versions are ordinary VIC-II multicolour bitmaps (bitmap $2000,
; screen $0400, colour RAM, background $D021): the same rules, the same 4
; colours per 4x8 cell.  The stock one is converted to the C64's own
; palette.  The custom one is converted to 16 colours picked for this
; picture, and shown with CTRL bit 3 on, so VIC-II colour n comes from VIC-X
; palette entry n.  Every 4 seconds the demo switches between them; the
; screen is blanked for the moment the data is copied in.  The picture was
; made with Nano Banana (see art/), converted by tools/prep_art.py.
;
; No CPU readout here: the bitmap fills the screen and there is no text.

NEED_XRAM_MB = 2
CPU_TEXT     = $C800            ; unused: the CPU readout is not shown
.include "demo.inc"
.include "assets.inc"

BITMAP  = $2000
SCREEN  = $0400
COLBUF  = $C000                 ; colour RAM data + background, staged
HOLD    = 200                   ; frames each version stays

.code
main:
        lda #0
        sta $D020
        sta VICX_CTRL
        lda #$18                        ; screen $0400, bitmap $2000
        sta $D018
        lda #$18                        ; multicolour, 40 columns
        sta $D016

show:
        lda #0                          ; stock palette
        sta which
        jsr load_set
        jsr hold
        lda #1                          ; custom palette
        sta which
        jsr load_set
        jsr hold
        jmp show

; Blank the screen, copy set `which' into place, set the palette, show it.
load_set:
        ldx #251
        jsr wait_line
        lda #$0B                        ; display off (bitmap mode kept)
        sta $D011
        lda which
        beq :+
        jmp ls_custom
:
        XRAM_TO_C64 STOCK, BITMAP, 8000
        XRAM_TO_C64 STOCK + 8000, SCREEN, 1000
        XRAM_TO_C64 STOCK + 9000, COLBUF, 1001
        lda #0                          ; VIC-II colours as they are
        sta VICX_CTRL
        jmp ls_colour
ls_custom:
        XRAM_TO_C64 CUSTOM, BITMAP, 8000
        XRAM_TO_C64 CUSTOM + 8000, SCREEN, 1000
        XRAM_TO_C64 CUSTOM + 9000, COLBUF, 1001
        XRAM_TO_VRAM CUSTOM_PAL, VICX_PALETTE, CUSTOM_PAL_LEN
        lda #VICX_CTRL_PALMAP           ; VIC-II colour n = palette entry n
        sta VICX_CTRL
ls_colour:
        ldx #0                          ; colour RAM from the staging copy
:       lda COLBUF,x
        sta $D800,x
        lda COLBUF + $100,x
        sta $D900,x
        lda COLBUF + $200,x
        sta $DA00,x
        lda COLBUF + $2E8,x
        sta $DAE8,x
        inx
        bne :-
        lda COLBUF + 1000               ; background
        sta $D021
        ldx #251                        ; one more frame for the palette
        jsr wait_line
        lda #$3B                        ; display on, bitmap mode
        sta $D011
        rts

hold:
        ldy #HOLD
:       ldx #251
        jsr wait_line
        dey
        bne :-
        rts

.bss
which:  .res 1
