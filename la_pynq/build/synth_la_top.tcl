# 单独综合 la_top（out-of-context，不做引脚约束）——只为拿资源与层次数据
# 完整工程要在 Vivado 里配 Zynq PS7 + AXI Interconnect，但资源占用 OOC 即可评估
set here [file dirname [file normalize [info script]]]
set repo [file dirname $here]
set out    [file join $here "out"]

file mkdir $out

read_verilog [list \
    ${repo}/rtl/din_sync.v \
    ${repo}/rtl/smp_clk_div.v \
    ${repo}/rtl/cap_mem.v \
    ${repo}/rtl/trig_fsm.v \
    ${repo}/rtl/proto_uart.v \
    ${repo}/rtl/proto_spi.v \
    ${repo}/rtl/proto_i2c.v \
    ${repo}/rtl/proto_trig.v \
    ${repo}/rtl/timing_stats.v \
    ${repo}/rtl/axi_regs.v \
    ${repo}/rtl/i2c_src.v \
    ${repo}/rtl/uart_tx.v \
    ${repo}/rtl/la_top.v \
]

synth_design -top la_top -part xc7z020clg400-1 -mode out_of_context
report_utilization -file ${out}/la_top_utilization.rpt
report_utilization -hierarchical -file ${out}/la_top_util_hier.rpt
puts "===> LA_TOP SYNTH DONE"
