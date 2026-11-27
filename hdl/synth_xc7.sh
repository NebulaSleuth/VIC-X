#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Michael Hartman
#
# synth_xc7.sh - count VIC-X's Artix-7 (xc7) resources with GHDL + Yosys.
#
#   sh hdl/synth_xc7.sh [full|nodma|nospr]          a named build (default: full)
#   sh hdl/synth_xc7.sh NAME [GENERIC=VALUE ...]     any build, named NAME
#
# e.g.  sh hdl/synth_xc7.sh spr64 CAP_SPR=64 CAP_SPRLINE=16
#       sh hdl/synth_xc7.sh noblit CAP_BLIT=00       (vectors in hex)
#
# Generics not given keep the MiSTer build's values: VRAM_BITS 17, EXT_VRAM
# true, CAP_SPR 128, CAP_SPRLINE 32, CAP_FEAT 1F, CAP_BLIT 1F. Each build
# works in build/yosys/NAME, so several can run at once.
#
# Needs GHDL 6 and Yosys from MSYS2 UCRT64 (mingw-w64-ucrt-x86_64-ghdl-llvm,
# mingw-w64-ucrt-x86_64-yosys). Takes a few minutes. The hierarchy is kept
# (no -flatten): each block is mapped on its own, which maps better and,
# unlike a flattened run, gives counts that do not swing by a thousand LUTs
# between nearly equal designs. Prints LUTs (logic, and LUT RAM at 4 a
# RAM32M/RAM64M), flip-flops, RAMB36/RAMB18 and DSP48 for each block (the
# layer block once; the top has two) and the total; stat.txt in
# build/yosys/NAME has the full counts. No timing: Yosys does not place or
# route.
set -e
name=${1:-full}
[ $# -gt 0 ] && shift
VRAM_BITS=17 EXT_VRAM=true CAP_SPR=128 CAP_SPRLINE=32 CAP_FEAT=1F CAP_BLIT=1F
case $name in
    full)  ;;
    nodma) CAP_FEAT=07 CAP_BLIT=00 ;;
    nospr) CAP_SPR=0 CAP_SPRLINE=0 CAP_FEAT=03 CAP_BLIT=00 ;;
esac
for a in "$@"; do
    case $a in
        VRAM_BITS=*|EXT_VRAM=*|CAP_SPR=*|CAP_SPRLINE=*|CAP_FEAT=*|CAP_BLIT=*)
            eval "$a" ;;
        *) echo "unknown generic: $a" >&2; exit 2 ;;
    esac
done
here=$(cd "$(dirname "$0")" && pwd)
out=$here/build/yosys/$name
mkdir -p "$out"
cd "$out"
rm -f work-obj08.cf
ghdl -a --std=08 --workdir=. "$here/vicx_layer.vhd" "$here/vicx_sprites.vhd" "$here/vicx.vhd"
ghdl --synth --std=08 --workdir=. --out=verilog \
    "-gVRAM_BITS=$VRAM_BITS" "-gEXT_VRAM=$EXT_VRAM" "-gCAP_SPR=$CAP_SPR" \
    "-gCAP_SPRLINE=$CAP_SPRLINE" "-gCAP_FEAT=x\"$CAP_FEAT\"" \
    "-gCAP_BLIT=x\"$CAP_BLIT\"" vicx > vicx.v 2> ghdl.log
yosys -q -l yosys.log -p "read_verilog vicx.v; synth_xilinx -family xc7 -top vicx -abc9; tee -o stat.txt stat" > /dev/null
awk '
    /^=== / && $2 != "design" { m = $2; sub(/_Brtl.*/, "", m); if (!(m in seen)) { seen[m] = 1; ord[++n] = m } }
    /design hierarchy/       { done = 1 }
    done && /^ +[0-9]+ +vicx_layer/ { nlay = $1 }
    done                     { next }
    /^ +[0-9]+ +LUT[1-6]$/   { lut[m] += $1 }
    /^ +[0-9]+ +RAM(32|64)M$/ { lr[m] += 4 * $1 }
    /^ +[0-9]+ +FD[RSCP]E$/  { ff[m] += $1 }
    /^ +[0-9]+ +RAMB36E1$/   { b36[m] += $1 }
    /^ +[0-9]+ +RAMB18E1$/   { b18[m] += $1 }
    /^ +[0-9]+ +DSP48E1$/    { dsp[m] += $1 }
    END {
        printf "%-14s %7s %7s %7s %6s %6s %4s\n", "block", "LUT", "LUTRAM", "FF", "RAMB36", "RAMB18", "DSP"
        for (i = 1; i <= n; i++) {
            k = ord[i]; c = (k == "vicx_layer") ? (nlay ? nlay : 2) : 1
            printf "%-14s %7d %7d %7d %6d %6d %4d%s\n", k, lut[k], lr[k], ff[k], b36[k], b18[k], dsp[k], (c > 1 ? " (x" c ")" : "")
            tl += c * lut[k]; tr += c * lr[k]; tf += c * ff[k]; t36 += c * b36[k]; t18 += c * b18[k]; td += c * dsp[k]
        }
        printf "%-14s %7d %7d %7d %6d %6d %4d   LUTs in all: %d\n", "total", tl, tr, tf, t36, t18, td, tl + tr
    }' stat.txt
