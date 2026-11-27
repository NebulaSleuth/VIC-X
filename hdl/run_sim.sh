#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Michael Hartman
#
# Simulate the VIC-X block with GHDL.  Run from the UCRT64 shell:
#   C:\msys64\usr\bin\bash.exe -lc "hdl/run_sim.sh"   (MSYSTEM=UCRT64, CHERE_INVOKING=1)
# Exits 0 when every testbench passes.  Each testbench runs with VRAM in
# block RAM, then with external VRAM behind a memory model: step 1 at C64
# speed against random waits, step 2 against the SDRAM controller's slots,
# also with the REU holding its slot, and with the DMA engine copying all
# frame long while the window starts early in the line.
set -e
cd "$(dirname "$0")"
mkdir -p build
cd build
GHDL="ghdl"
FLAGS="--std=08 --workdir=. -frelaxed"
$GHDL -a $FLAGS ../vicx_layer.vhd ../vicx_sprites.vhd ../vicx.vhd
status=0
run() {
    echo "== $*"
    if ! $GHDL -r $FLAGS "$@" --assert-level=failure; then
        status=1
    fi
}
# a run that must fail: it shows a check can catch what it is there for
run_fail() {
    echo "== (must fail) $*"
    if $GHDL -r $FLAGS "$@" --assert-level=failure >/dev/null 2>&1; then
        echo "FAIL: it passed"
        status=1
    fi
}
for tb in ../tb/tb_*.vhd; do
    name=$(basename "$tb" .vhd)
    $GHDL -a $FLAGS "$tb"
    $GHDL -e $FLAGS "$name"
    run "$name"
done
run tb_vicx_step1 -gEXT=true -gGAP=128 -gMAXLAT=16
run tb_vicx_step1 -gEXT=true -gGAP=128 -gMAXLAT=40
run_fail tb_vicx_step1 -gEXT=true -gGAP=128 -gMAXLAT=16 -gDROP=true
run tb_vicx_step2 -gEXT=true
run tb_vicx_step2 -gEXT=true -gREU=true
run tb_vicx_step2 -gEXT=true -gDMA=true -gWX=40
run tb_vicx_step3 -gEXT=true
run tb_vicx_step4 -gEXT=true
run tb_vicx_step4 -gNENT=64 -gNLINE=16
run tb_vicx_step4 -gEXT=true -gNENT=64 -gNLINE=16
run tb_vicx_wide -gEXT=true
exit $status
