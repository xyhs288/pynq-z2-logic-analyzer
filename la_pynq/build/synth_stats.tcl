# 单独综合 timing_stats，只为拿资源占用数字（不出 bitstream，所以不需要引脚约束）
set here [file dirname [file normalize [info script]]]
set repo [file dirname $here]
set out    [file join $here "out"]

file mkdir $out
read_verilog ${repo}/rtl/timing_stats.v
synth_design -top timing_stats -part xc7z020clg400-1 -mode out_of_context
report_utilization -file ${out}/stats_utilization.rpt
puts "===> STATS SYNTH DONE"
