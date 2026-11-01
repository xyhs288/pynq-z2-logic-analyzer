# =====================================================================
#  build_in_gui.tcl
#
#  Run the WHOLE build inside the Vivado GUI, so every step scrolls past
#  in your Tcl Console instead of happening in a hidden batch process.
#
#  Usage - in Vivado's Tcl Console, type this one line:
#
#      source {D:/Workbuddy_project/2026-09-16-19-24-33/la_pynq/build/build_in_gui.tcl}
#
#  To build a different top level, set it first:
#
#      set top "stage2_top"
#      source {D:/Workbuddy_project/2026-09-16-19-24-33/la_pynq/build/build_in_gui.tcl}
#
#  This is the non-project flow (read -> synth -> impl -> bitstream),
#  the same one the batch script uses, so results are identical.
#  Keep this file ASCII-only.
# =====================================================================

if {![info exists top]} {
    set top "loopback_top"
}

set part   "xc7z020clg400-1"
set root   "D:/Workbuddy_project/2026-09-16-19-24-33/la_pynq"
set outdir "D:/vivado_project/logic_analyzer_gui"

puts "=========================================================="
puts "  BUILD IN GUI"
puts "  top    = $top"
puts "  part   = $part"
puts "  outdir = $outdir"
puts "=========================================================="

file mkdir $outdir

# ---- read all RTL (only the module named by -top gets elaborated) ----
puts "===> [1/7] READ RTL"
foreach f [lsort [glob -nocomplain "$root/rtl/*.v"]] {
    read_verilog $f
}

# ---- constraints for the chosen top ----
set xdc "$root/constraints/$top.xdc"
if {[file exists $xdc]} {
    puts "===> [2/7] READ XDC  $xdc"
    read_xdc $xdc
} else {
    puts "!!! XDC not found: $xdc  (continuing without pin constraints)"
}

# ---- synthesis ----
puts "===> [3/7] SYNTHESIS"
synth_design -top $top -part $part -flatten_hierarchy rebuilt

write_checkpoint -force "$outdir/post_synth.dcp"
report_utilization -file "$outdir/post_synth_util.rpt"

# ---- implementation ----
puts "===> [4/7] OPT DESIGN"
opt_design

puts "===> [5/7] PLACE DESIGN"
place_design

puts "===> [6/7] ROUTE DESIGN"
route_design

# ---- reports ----
puts "===> [7/7] REPORTS + BITSTREAM"
report_timing_summary -file "$outdir/timing_summary.rpt"
report_utilization    -file "$outdir/utilization.rpt"
report_drc            -file "$outdir/drc.rpt"
write_checkpoint -force "$outdir/post_route.dcp"
write_bitstream -force "$outdir/$top.bit"

puts "=========================================================="
puts "  DONE"
puts "  bitstream : $outdir/$top.bit"
puts "  timing    : $outdir/timing_summary.rpt"
puts "  resources : $outdir/utilization.rpt"
puts "=========================================================="

# 一句话看时序结论
set fh [open "$outdir/timing_summary.rpt" r]
set txt [read $fh]
close $fh
if {[string match "*All user specified timing constraints are met*" $txt]} {
    puts "TIMING: MET"
} else {
    puts "TIMING: NOT MET - check the report"
}
