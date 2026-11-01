# 单独综合 timing_stats，只为拿资源占用数字（不出 bitstream，所以不需要引脚约束）
set repo "D:/Workbuddy_project/2026-09-16-19-24-33/la_pynq"
set out  "D:/vivado_project/logic_analyzer_loopback"

file mkdir $out
read_verilog ${repo}/rtl/timing_stats.v
synth_design -top timing_stats -part xc7z020clg400-1 -mode out_of_context
report_utilization -file ${out}/stats_utilization.rpt
puts "===> STATS SYNTH DONE"
