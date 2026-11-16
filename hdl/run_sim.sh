#!/bin/sh
# Simulate the VIC-X block with GHDL.  Run from the UCRT64 shell:
#   C:\msys64\usr\bin\bash.exe -lc "hdl/run_sim.sh"   (MSYSTEM=UCRT64, CHERE_INVOKING=1)
# Exits 0 when every testbench passes.  tb_vicx_step1 runs twice: with VRAM
# in block RAM, and with external VRAM behind a memory model at C64 speed.
set -e
cd "$(dirname "$0")"
mkdir -p build
cd build
GHDL="ghdl"
FLAGS="--std=08 --workdir=. -frelaxed"
$GHDL -a $FLAGS ../vicx.vhd
status=0
run() {
    echo "== $*"
    if ! $GHDL -r $FLAGS "$@" --assert-level=failure; then
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
exit $status
