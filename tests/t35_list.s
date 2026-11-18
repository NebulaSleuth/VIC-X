; t35_list - the blitter's optional lists in VRAM (DMA_CMD bit 2, CAP_BLIT
; bit 4): 32-byte descriptors one after another from the VRAM address at
; $2085C-$2085E, each read when its turn comes, until one whose operation is
; $FF.  DMA_CMD bits 0-1 are ignored; IRQ_STAT bit 1 is raised at the end if
; a descriptor in the list asked for it.  Skipped (PASS with nothing checked)
; on a build whose CAP_BLIT lacks bit 4.
;
; RUN: -vicx -reu -reusize 16384

.include "harness.inc"

LIST = $01000

.code
main:
        VICX_UNLOCK_SEQ

        lda VICX_CAP_BLIT
        and #VICX_BLIT_LIST
        bne :+
        PASS
:
        VICX_P0_SET $00500, VICX_STEP_1
        lda #0
        P0_FILL 1024
        ; the list
        VICX_P0_SET LIST, VICX_STEP_1
        ldx #0
:       lda list,x
        sta VICX_P0_DATA
        inx
        cpx #list_end - list
        bne :-
        ; its address
        VICX_P0_SET VICX_DMALIST, VICX_STEP_1
        lda #<LIST
        sta VICX_P0_DATA
        lda #>LIST
        sta VICX_P0_DATA
        lda #^LIST
        sta VICX_P0_DATA
        ; descriptor 0 in the register space: must not run (bits 0-1 ignored)
        DMA_DESC 0, VICX_DMA_FILL, VICX_DMA_DST_VRAM, 0, $00700, 4, 0, 0, 0, $99, 0, VICX_DMA_NONE
        lda #$07
        sta VICX_IRQ_STAT               ; clear

        lda #VICX_DMA_LIST | 3
        sta VICX_DMA_CMD
        DMA_WAIT

        PEEK_AT $00500                  ; 1. the fill
        EXPECT_A $11, 10
        PEEK_AT $00517                  ; 2. the copy saw it
        EXPECT_A $11, 11
        PEEK_AT $00600                  ; 3. its fill value was changed by 1
        EXPECT_A $77, 12
        PEEK_AT $00601
        EXPECT_A $77, 13
        PEEK_AT $00602
        EXPECT_A $00, 14
        PEEK_AT $00523                  ; 4. after the changed one
        EXPECT_A $33, 15
        PEEK_AT $00700                  ; descriptor 0 did not run
        EXPECT_A $00, 16
        lda VICX_IRQ_STAT
        and #$02
        EXPECT_A $02, 17                ; descriptor 4 asked for the IRQ
        PASS

; Descriptor: op, flags, src (4), dst (4), w (2), h (2), ss (2), ds (2),
; fill, trans, next, then 11 bytes
.macro LD op, flags, src, dst, w, fill
        .byte op, flags
        .dword src, dst
        .word w, 0, 0, 0
        .byte fill, 0, $FF
        .res 11
.endmacro

list:   LD VICX_DMA_FILL, VICX_DMA_DST_VRAM, 0, $00500, 8, $11
        ; overwrites the fill value (+18) of the third descriptor
        LD VICX_DMA_FILL, VICX_DMA_DST_VRAM, 0, LIST + 2 * 32 + 18, 1, $77
        LD VICX_DMA_FILL, VICX_DMA_DST_VRAM, 0, $00600, 2, $44
        LD VICX_DMA_COPY, VICX_DMA_SRC_VRAM | VICX_DMA_DST_VRAM, $00500, $00510, 8, 0
        LD VICX_DMA_FILL, VICX_DMA_DST_VRAM | VICX_DMA_IRQ, 0, $00520, 4, $33
        .byte $FF                       ; the end
        .res 31
list_end:
