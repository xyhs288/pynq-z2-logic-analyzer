# =====================================================================
#  build_nonproj.tcl —— 非工程批处理流程（自动构建一条龙）
#
#  用法：
#    vivado -mode batch -source build_nonproj.tcl -tclargs <顶层名>
#  例：
#    vivado -mode batch -source build_nonproj.tcl -tclargs stage2_top
#  不传参数时默认 loopback_top。
#
#  跑完在 $out 下得到 <顶层名>.bit 以及时序/资源报告。
#  需要浏览设计时，打开 $out/post_route.dcp。
# =====================================================================

set repo "D:/Workbuddy_project/2026-09-16-19-24-33/la_pynq"
set out  "D:/vivado_project/logic_analyzer_loopback"
set part "xc7z020clg400-1"

if {$argc > 0} { set top [lindex $argv 0] } else { set top "loopback_top" }
puts "===> TOP = ${top}"

set common [list \
    ${repo}/rtl/test_gen.v \
    ${repo}/rtl/smp_clk_div.v \
    ${repo}/rtl/din_sync.v \
]

switch $top {
    loopback_top {
        set srcs [concat $common [list ${repo}/rtl/loopback_top.v]]
    }
    stage2_top {
        set srcs [concat $common [list ${repo}/rtl/trig_fsm.v ${repo}/rtl/stage2_top.v]]
    }
    stage3_top {
        set srcs [concat $common [list \
            ${repo}/rtl/trig_fsm.v \
            ${repo}/rtl/cap_mem.v \
            ${repo}/rtl/stage3_top.v \
        ]]
    }
    stage4_top {
        set srcs [list \
            ${repo}/rtl/i2c_src.v \
            ${repo}/rtl/proto_i2c.v \
            ${repo}/rtl/proto_trig.v \
            ${repo}/rtl/smp_clk_div.v \
            ${repo}/rtl/trig_fsm.v \
            ${repo}/rtl/cap_mem.v \
            ${repo}/rtl/stage4_top.v \
        ]
    }
    default {
        set srcs [glob ${repo}/rtl/*.v]
    }
}

set xdc "${repo}/constraints/${top}.xdc"
if {![file exists $xdc]} { error "XDC NOT FOUND: $xdc" }

file mkdir $out

puts "===> READ SOURCES"
read_verilog $srcs
read_xdc $xdc

puts "===> SYNTHESIS"
synth_design -top $top -part $part
write_checkpoint -force ${out}/post_synth.dcp

puts "===> IMPLEMENTATION"
opt_design
place_design
route_design

puts "===> WRITE REPORTS"
write_checkpoint -force ${out}/post_route.dcp
report_timing_summary -file ${out}/timing_summary.rpt
report_utilization    -file ${out}/utilization.rpt
report_drc            -file ${out}/drc.rpt

puts "===> WRITE BITSTREAM"
write_bitstream -force ${out}/${top}.bit

puts "===> ALL DONE : ${out}/${top}.bit"
