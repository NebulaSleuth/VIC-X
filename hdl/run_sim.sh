#!/bin/sh
# Simulate the VIC-X block with GHDL.  Run from the UCRT64 shell:
#   C:\msys64\usr\bin\bash.exe -lc "hdl/run_sim.sh"   (MSYSTEM=UCRT64, CHERE_INVOKING=1)
# Exits 0 when every testbench passes.
set -e
cd "$(dirname "$0")"
mkdir -p build
cd build
GHDL="ghdl"
FLAGS="--std=08 --workdir=. -frelaxed"
$GHDL -a $FLAGS ../vicx.vhd
status=0
for tb in ../tb/tb_*.vhd; do
    name=$(basename "$tb" .vhd)
    $GHDL -a $FLAGS "$tb"
    $GHDL -e $FLAGS "$name"
    echo "== $name"
    if ! $GHDL -r $FLAGS "$name" --assert-level=failure; then
        status=1
    fi
done
exit $status
