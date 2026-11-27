#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Michael Hartman
#
# vivado_xc7.sh - the usual Vivado builds of the VIC-X block (see
# vivado_xc7.tcl): all of it on both Artix-7 parts, and the smaller builds
# on the XC7A50T, all at 77 MHz. Results in hdl/build/vivado/NAME, a line
# each at the end.
#
#   sh hdl/vivado_xc7.sh [NAME ...]        default: all of them
#
# VIVADO names vivado.bat (default the 2026.2 install). The builds run side
# by side, started a little apart.

VIVADO=${VIVADO:-'C:\AMDDesignTools\2026.2\Vivado\bin\vivado.bat'}
A50=xc7a50tfgg484-1
A100=xc7a100tfgg484-1

cd "$(dirname "$0")" || exit 1
mkdir -p build/vivado
cd build/vivado || exit 1

build() {   # NAME PART [GENERIC:VALUE ...]
    # each in its own folder: Vivado keeps scratch files (.Xil) in the
    # folder it runs in, and runs sharing one trip over each other
    n=$1; p=$2; shift 2
    mkdir -p "$n"
    # Vivado 2026.2 now and then fails opt_design with an empty
    # "[Synth 20-411]" when several run at once; one more try gets past it
    for try in 1 2; do
        rm -rf "$n/.Xil"
        (cd "$n" && cmd //c "$VIVADO -mode batch -nojournal -log vivado.log -source ..\\..\\..\\vivado_xc7.tcl -tclargs $n $p 77 $*") > $n.out 2>&1
        grep -q 'Synth 20-411' $n.out || break
    done
}

all="full50 full100 full64 nodma64 layers"
[ $# -gt 0 ] && all="$*"
for n in $all; do
    case $n in
        full50)  build $n $A50 & ;;
        full100) build $n $A100 & ;;
        full64)  build $n $A50 CAP_SPR:64 CAP_SPRLINE:16 & ;;
        nodma64) build $n $A50 CAP_SPR:64 CAP_SPRLINE:16 CAP_FEAT:07 CAP_BLIT:00 & ;;
        layers)  build $n $A50 CAP_SPR:0 CAP_SPRLINE:0 CAP_FEAT:03 CAP_BLIT:00 & ;;
        *) echo "unknown build: $n" >&2; continue ;;
    esac
    sleep 20
done
wait
for n in $all; do
    if grep -q '^SUMMARY' "$n.out"; then
        grep -h SUMMARY "$n.out" | tail -1
    else
        echo "$n FAILED: $(grep -m1 '^ERROR' "$n.out")"
    fi
done
