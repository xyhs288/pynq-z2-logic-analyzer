# =====================================================================
#  report_la_sys.tcl —— 重跑整机实现并生成时序/DRC/资源报告
#
#  为什么需要：此前的直接命令流程（synth_design -> place -> route ->
#  write_bitstream）没有生成任何报告，所以整机实现的时序从未被检查过。
#  AXI 在真实硬件上不响应，时序不收敛是一个必须排除的可能。
# =====================================================================

set out "D:/vivado_project/la_sys"

open_project ${out}/la_sys.xpr

puts "===> SYNTH"
if {[catch {synth_design -top sys_wrapper -part xc7z020clg400-1} e]} {
    puts "!!! synth failed: $e"; exit 1
}

puts "===> IMPL"
if {[catch {opt_design; place_design; route_design} e]} {
    puts "!!! impl failed: $e"; exit 1
}

puts "===> CHECKPOINT"
write_checkpoint -force ${out}/routed.dcp

puts "===> REPORTS"
report_timing_summary -file ${out}/ts.rpt
report_drc            -file ${out}/drc.rpt
report_utilization    -file ${out}/util.rpt
report_clocks         -file ${out}/clocks.rpt
report_clock_interaction -file ${out}/clock_int.rpt

puts "===> SUMMARY"
if {[catch {
    set wns [get_property SLACK [get_timing_paths -delay_type max]]
    set whs [get_property SLACK [get_timing_paths -delay_type min]]
    puts "  WNS = $wns"
    puts "  WHS = $whs"
} e]} {
    puts "  (timing path query failed: $e)"
}

set clks [get_clocks -quiet]
puts "  clocks = [llength $clks]"
foreach c $clks {
    puts "    [get_property NAME $c]  period=[get_property PERIOD $c]"
}
puts "===> DONE"
