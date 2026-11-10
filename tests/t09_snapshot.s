; t09_snapshot - VIC-X state survives a snapshot save and load.
;
; Run 1 sets up VIC-X state (unlocked, CTRL with the palette remap, port
; addresses, palette entry 0 = red, a VRAM byte), calls a trap at $033C
; where a monitor tracepoint saves a snapshot, then checks the state and
; exits through the debug cartridge.
;
; Runs 2 and 3 start from that snapshot instead of the PRG, so their checks
; only pass if the snapshot restored VIC-X; run 3 starts with VIC-X disabled
; and the snapshot must enable it.  Loading a snapshot detaches all
; cartridges, the debug cartridge included, so these runs report on screen:
; the result hook sets palette entry 6 to green (pass) or magenta (fail)
; and shows it as the background, and the run ends at the cycle limit with
; a screenshot.  The border (colour 0) must show the remapped red.
;
; RUN: -vicx -moncommands {tests}/t09_snapshot.mon
; RUN: -vicx -autostart {build}/t09_snapshot.vsf
; EXIT: cycle-limit
; PIXEL: 4 4 FF0000
; PIXEL: 192 150 00FF00
; RUN: +vicx -autostart {build}/t09_snapshot.vsf
; EXIT: cycle-limit
; PIXEL: 4 4 FF0000
; PIXEL: 192 150 00FF00

TRAP  = $033C
RESULT_HOOK = show_result

.include "harness.inc"

.code
main:
        lda #$20                        ; clear the screen
        ldx #0
:       sta $0400,x
        sta $0500,x
        sta $0600,x
        sta $06E8,x
        inx
        bne :-
        lda #$00
        sta $D020
        sta $D021
        lda #$60                        ; RTS
        sta TRAP

        VICX_UNLOCK_SEQ
        VICX_P0_SET VICX_PALETTE, VICX_STEP_1
        lda #$FF
        sta VICX_P0_DATA
        lda #$00
        sta VICX_P0_DATA
        sta VICX_P0_DATA
        VICX_P0_SET $1ABCD, VICX_STEP_0
        lda #$A5
        sta VICX_P0_DATA
        VICX_P0_SET $12345, VICX_STEP_160 | VICX_STEP_BACK
        lda #$67
        sta VICX_P1_ADDRL
        lda #VICX_CTRL_PALMAP | VICX_CTRL_BGTRANS
        sta VICX_CTRL

        jsr TRAP                        ; run 1: snapshot saved here
        WAIT_FRAMES 2

        ; --- checks (runs 2 and 3 resume here) ----------------------------
        EXPECT VICX_ID0, $56, 2         ; still unlocked
        EXPECT VICX_CTRL, VICX_CTRL_PALMAP | VICX_CTRL_BGTRANS, 3
        EXPECT VICX_P1_ADDRL, $67, 4
        EXPECT VICX_P0_ADDRL, <$12345, 5
        EXPECT VICX_P0_ADDRM, >$12345, 6
        EXPECT VICX_P0_ADDRH, VICX_STEP_160 | VICX_STEP_BACK | $01, 7
        VICX_P0_SET $1ABCD, VICX_STEP_0
        EXPECT VICX_P0_DATA, $A5, 8
        VICX_P0_SET VICX_PALETTE, VICX_STEP_1
        EXPECT VICX_P0_DATA, $FF, 9
        EXPECT VICX_P0_DATA, $00, 10
        EXPECT VICX_P0_DATA, $00, 11
        PASS

; Show the result: background = colour 6, palette entry 6 = green on pass,
; magenta on fail.  Keeps A (the result code).
show_result:
        sta result
        VICX_P0_SET VICX_PALETTE + 6*4, VICX_STEP_1
        lda result
        bne @fail
        lda #$00
        sta VICX_P0_DATA
        lda #$FF
        sta VICX_P0_DATA
        lda #$00
        sta VICX_P0_DATA
        beq @show
@fail:  lda #$FF
        sta VICX_P0_DATA
        lda #$00
        sta VICX_P0_DATA
        lda #$FF
        sta VICX_P0_DATA
@show:  lda #$06
        sta $D021
        WAIT_FRAMES 2                   ; the remap is applied per frame
        lda result
        rts

.bss
result: .res 1
