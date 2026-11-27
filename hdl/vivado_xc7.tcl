# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Michael Hartman
#
# vivado_xc7.tcl - build the VIC-X block alone in Vivado: synthesis, place
# and route out of context, then utilisation for each block and timing.
#
#   vivado -mode batch -source hdl/vivado_xc7.tcl -tclargs NAME PART MHZ [GENERIC=VALUE ...]
#
# or sh hdl/vivado_xc7.sh (runs the usual builds). NAME names the output
# folder, build/vivado/NAME (util.txt, util_hier.txt, timing.txt,
# summary.txt). PART e.g. xc7a50tfgg484-1 or xc7a100tfgg484-1. Generics not
# given keep the MiSTer build's values (VRAM_BITS 17, EXT_VRAM true,
# CAP_SPR 128, CAP_SPRLINE 32, CAP_FEAT 1F, CAP_BLIT 1F); vectors in hex,
# e.g. CAP_FEAT=07. On Windows write CAP_FEAT:07 instead: vivado.bat splits
# its arguments at '='.
#
# Out of context the block has no pins: its inputs are taken to come from
# registers in the core around it (2 ns allowed for the wire), and its
# outputs to go to registers there (2 ns too), so the timing covers its own
# paths and its share of the paths through its ports.

set name [lindex $argv 0]
set part [lindex $argv 1]
set mhz  [lindex $argv 2]
set here [file dirname [file normalize [info script]]]
set out  [file join $here build vivado $name]
file mkdir $out

array set g {VRAM_BITS 17 EXT_VRAM true CAP_SPR 128 CAP_SPRLINE 32 CAP_FEAT 1F CAP_BLIT 1F}
foreach a [lrange $argv 3 end] {
    # NAME=VALUE, or NAME:VALUE when run through vivado.bat, which splits
    # its arguments at '='
    set kv [split $a =:]
    if {[llength $kv] != 2 || ![info exists g([lindex $kv 0])] || [lindex $kv 1] eq ""} {
        error "bad generic '$a' (want NAME=VALUE or NAME:VALUE, NAME one of [lsort [array names g]])"
    }
    set g([lindex $kv 0]) [lindex $kv 1]
}
set gl {}
foreach k {VRAM_BITS CAP_SPR CAP_SPRLINE} { lappend gl "$k=$g($k)" }
lappend gl "EXT_VRAM=$g(EXT_VRAM)"
foreach k {CAP_FEAT CAP_BLIT} { lappend gl "$k=8'h$g($k)" }

create_project -in_memory -part $part
read_vhdl -vhdl2008 [list [file join $here vicx_layer.vhd] \
                          [file join $here vicx_sprites.vhd] \
                          [file join $here vicx.vhd]]
synth_design -top vicx -part $part -mode out_of_context -generic $gl

set period [expr {1000.0 / $mhz}]
create_clock -name clk -period $period [get_ports clk]
set ins [get_ports -filter {DIRECTION == IN && NAME != clk}]
set outs [get_ports -filter {DIRECTION == OUT}]
set_input_delay  -clock clk 2.0 $ins
set_output_delay -clock clk 2.0 $outs

opt_design
place_design
phys_opt_design
route_design

report_utilization -file [file join $out util.txt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $out util_hier.txt]
report_timing_summary -max_paths 10 -file [file join $out timing.txt]
report_timing -max_paths 20 -nworst 1 -unique_pins -file [file join $out paths.txt]
# the block's own paths, register to register, apart from those through its ports
report_timing -from [all_registers] -to [all_registers] -max_paths 30 -nworst 1 \
    -unique_pins -file [file join $out paths_reg.txt]
write_checkpoint -force [file join $out routed.dcp]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fmax [expr {1000.0 / ($period - $wns)}]
set f [open [file join $out summary.txt] w]
puts $f "build $name  part $part  clock $mhz MHz ([format %.3f $period] ns)"
puts $f "generics $gl"
puts $f "WNS [format %.3f $wns] ns  (Fmax about [format %.1f $fmax] MHz)"
close $f
puts "SUMMARY $name $part WNS=$wns FMAX=[format %.1f $fmax]"
