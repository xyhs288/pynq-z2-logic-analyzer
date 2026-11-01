# =====================================================================
#  build_bd_clkmon.tcl —— 时钟停振检测设计的完整构建
#
#  一次性做完：建 BD -> 生成 .hwh -> 绕开 run 管理器做综合/实现 -> 出 bitstream
#
#  BD 结构：
#    ps7（FCLK0=100MHz，稳定）──> 这是 AXI 时钟，与 PHY 无关
#    ic（axi_interconnect 1x1）
#    clkmon（module reference）── s_axi 挂 FCLK，test_clk 接外部 H16
#    rst_0（proc_sys_reset，挂在 FCLK 上）
#
#  绕开 run 管理器的原因见 SKILL 坑 23：
#    run 管理器用子进程退出码判定成败，而 vivado.bat 退出码恒为 1。
# =====================================================================

set repo  "D:/Workbuddy_project/2026-09-16-19-24-33/la_pynq"
set out   "D:/vivado_project/la_clkmon"
set part  "xc7z020clg400-1"
set proj  "clkmon"

puts "===> CREATE PROJECT"
file delete -force $out
create_project -force $proj $out -part $part

# 注意：BD 工程必须用**自动**源管理，否则 create_bd_cell -type module -reference
# 找不到模块（报 BD 41-1690 / filemgmt 56-587）。source_mgmt_mode None 只适用于
# 纯 RTL 的工程流程。
set_property source_mgmt_mode All [current_project]

add_files -norecurse [list ${repo}/rtl/clkmon.v]
update_compile_order -fileset sources_1

puts "===> CREATE BD"
create_bd_design "sys"

puts "===> PS7"
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_M_AXI_GP1 {0} \
    CONFIG.PCW_USE_S_AXI_HP0 {0} \
    CONFIG.PCW_USE_S_AXI_HP1 {0} \
    CONFIG.PCW_USE_S_AXI_HP2 {0} \
    CONFIG.PCW_USE_S_AXI_HP3 {0} \
    CONFIG.PCW_USE_S_AXI_ACP {0} \
    CONFIG.PCW_USE_S_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_GP1 {0} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {0} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
] [get_bd_cells ps7]

puts "===> INTERCONNECT"
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect ic
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells ic]

puts "===> CLKMON (module reference)"
create_bd_cell -type module -reference clkmon clkmon_0

puts "===> RESET"
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0

puts "===> CONNECT"
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ic/M00_AXI]  [get_bd_intf_pins clkmon_0/S_AXI]

connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ic/ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ic/S00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ic/M00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins clkmon_0/s_axi_aclk]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst_0/slowest_sync_clk]

connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]      [get_bd_pins rst_0/ext_reset_in]
connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins ic/ARESETN]
connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins ic/S00_ARESETN]
connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins ic/M00_ARESETN]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn]   [get_bd_pins clkmon_0/s_axi_aresetn]

puts "===> EXTERNAL PORTS"
make_bd_intf_pins_external  [get_bd_intf_pins ps7/DDR]
make_bd_intf_pins_external  [get_bd_intf_pins ps7/FIXED_IO]
make_bd_pins_external       [get_bd_pins clkmon_0/test_clk]
make_bd_pins_external       [get_bd_pins clkmon_0/dbg_led]

set_property name sys_clk_125 [get_bd_ports test_clk_0]
set_property name dbg_led     [get_bd_ports dbg_led_0]
set_property CONFIG.FREQ_HZ {125000000} [get_bd_ports sys_clk_125]

puts "===> ADDRESS"
assign_bd_address

puts "===> VALIDATE"
validate_bd_design

puts "===> WRAPPER"
set bdfile [get_files sys.bd]
make_wrapper -files $bdfile -top
add_files -norecurse ${out}/${proj}.gen/sources_1/bd/sys/hdl/sys_wrapper.v
set_property top sys_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "===> XDC"
set xdc [open "${out}/pins.xdc" w]
puts $xdc "# 被测时钟：来自以太网 PHY 的 CLK125（手册 5 节）"
puts $xdc "set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} \[get_ports sys_clk_125\]"
puts $xdc "create_clock -period 8.000 -name sys_clk_125 \[get_ports sys_clk_125\]"
puts $xdc ""
puts $xdc "# 板载 LED（高电平点亮）"
foreach {i p} {0 R14 1 P14 2 N16 3 M14} {
    puts $xdc "set_property -dict {PACKAGE_PIN $p IOSTANDARD LVCMOS33} \[get_ports {dbg_led\[$i\]}\]"
}
close $xdc
add_files -fileset constrs_1 -norecurse "${out}/pins.xdc"

puts "===> GENERATE TARGETS"
generate_target all $bdfile

# ---------------------------------------------------------------------
# 注：generate_target all **不会**创建 OOC IP run，必须在 launch 时才被建出来。
#     这一步之后的报错可以忽略 —— run 状态会被误报（见 SKILL 坑 23）。
puts "===> LAUNCH (顺便把缺失的 OOC IP run 建出来)"
if {[catch {launch_runs impl_1 -to_step write_bitstream -jobs 4} e]} {
    puts "  (launch 返回：$e)"
}

set t0 [clock seconds]
set ipdir "${out}/${proj}.gen/sources_1/bd/sys/ip"
# 关键：不看 get_property STATUS（会被误报成 ERROR，见 SKILL 坑 23），
# 改成"IP dcp 数量连续 16 秒不再增加"就认为 OOC 综合结束。
set last -1
set stable 0
while {1} {
    set n [llength [glob -nocomplain ${ipdir}/*/*.dcp]]
    if {$n == $last} { incr stable } else { set stable 0 }
    set last $n
    if {$stable >= 4} { break }
    if {[clock seconds] - $t0 > 600} { puts "  !!! timeout"; break }
    after 4000
}
puts "  IP dcp 数量 = $last"

puts "===> SYNTH (direct)"
if {[catch {synth_design -top sys_wrapper -part $part} e]} {
    puts "  !!! synth failed: $e"; exit 1
}
puts "===> IMPL (direct)"
if {[catch { opt_design; place_design; route_design } e]} {
    puts "  !!! impl failed: $e"; exit 1
}
puts "===> WRITE BITSTREAM"
if {[catch { write_bitstream -force -file "${out}/clkmon.bit" } e]} {
    puts "  !!! bitstream failed: $e"; exit 1
}

file copy -force "${out}/${proj}.gen/sources_1/bd/sys/hw_handoff/sys.hwh" "${out}/clkmon.hwh"

puts "===> RESULT"
puts "  BIT : [expr {[file exists ${out}/clkmon.bit] ? "OK" : "MISSING"}]"
puts "  HWH : [expr {[file exists ${out}/clkmon.hwh] ? "OK" : "MISSING"}]"
puts "===> DONE"
