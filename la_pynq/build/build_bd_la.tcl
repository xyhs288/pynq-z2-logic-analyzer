# =====================================================================
#  build_bd_la.tcl —— 整机集成：PS7 + AXI Interconnect + la_top
#
#  🔴 时钟必须用 ps7/FCLK_CLK0，**不能**用外部引脚 H16（2026-10-13 用两块板的
#     断电重启换来的教训）：
#        H16 的 CLK125 来自以太网 PHY，PL 未配置时这条通路根本不存在。
#        而 Zynq 的 M_AXI_GP0_ACLK 要求"在 PS 启动早期就有效"（PS 的 GP 口
#        时钟由 PL 侧提供）。把它接到一个"PL 配置后才有"的时钟上，
#        PS 的 AXI 互连从启动起就处于异常状态 —— 表现是 PYNQ 一加载 overlay
#        整个系统就卡死，SSH 都断，只能断电。
#        clkmon 那次能跑通，正是因为它用的就是 FCLK_CLK0。
#      => AXI 与采样共用 FCLK_CLK0（100MHz），全设计单时钟域。
#      => 采样率 = 100MHz / DIV（软件侧的 DIV 按 100MHz 换算）。
#
#  绕开 run 管理器的原因见 SKILL 坑 23。
# =====================================================================

set repo "D:/Workbuddy_project/2026-09-16-19-24-33/la_pynq"
set out  "D:/vivado_project/la_sys"
set part "xc7z020clg400-1"
set proj "la_sys"

puts "===> CREATE PROJECT"
file delete -force $out
create_project -force $proj $out -part $part
# BD 工程必须用自动源管理（坑 26）
set_property source_mgmt_mode All [current_project]

puts "===> ADD RTL"
set rtl [list \
    ${repo}/rtl/la_top_axi_wrap.v \
    ${repo}/rtl/la_top.v \
    ${repo}/rtl/axi_regs.v \
    ${repo}/rtl/din_sync.v \
    ${repo}/rtl/smp_clk_div.v \
    ${repo}/rtl/cap_mem.v \
    ${repo}/rtl/trig_fsm.v \
    ${repo}/rtl/proto_uart.v \
    ${repo}/rtl/proto_spi.v \
    ${repo}/rtl/proto_i2c.v \
    ${repo}/rtl/proto_trig.v \
    ${repo}/rtl/timing_stats.v \
    ${repo}/rtl/test_gen.v \
    ${repo}/rtl/i2c_src.v \
    ${repo}/rtl/uart_tx.v \
]
add_files -norecurse $rtl
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

puts "===> LA_TOP (module reference)"
create_bd_cell -type module -reference la_top_axi_wrap la_top_axi_wrap_0

# module reference 自动推断出的 AXI 接口，FREQ_HZ 默认按 100MHz 猜，
# 和实际时钟对不上会报 BD 41-237，这里显式改掉。
set_property CONFIG.FREQ_HZ {125000000} [get_bd_intf_pins la_top_axi_wrap_0/S_AXI]

puts "===> RESET（proc_sys_reset：等 FCLK 锁定后才释放，与 clkmon 的成功结构一致）"
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0

puts "===> CONNECT AXI"
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ic/M00_AXI]  [get_bd_intf_pins la_top_axi_wrap_0/S_AXI]

puts "===> CLOCK = ps7/FCLK_CLK0 (100MHz) 驱动全部 AXI 与采样逻辑"
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ic/ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ic/S00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ic/M00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins la_top_axi_wrap_0/s_axi_aclk]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst_0/slowest_sync_clk]

connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins ic/ARESETN]
connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins ic/S00_ARESETN]
connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins ic/M00_ARESETN]

puts "===> EXTERNAL PORTS"
make_bd_intf_pins_external [get_bd_intf_pins ps7/DDR]
make_bd_intf_pins_external [get_bd_intf_pins ps7/FIXED_IO]
make_bd_pins_external      [get_bd_pins la_top_axi_wrap_0/btn0]
make_bd_pins_external      [get_bd_pins la_top_axi_wrap_0/ch_in]
make_bd_pins_external      [get_bd_pins la_top_axi_wrap_0/led]
make_bd_pins_external      [get_bd_pins la_top_axi_wrap_0/sig_out]

set_property name btn0  [get_bd_ports btn0_0]
set_property name ch_in [get_bd_ports ch_in_0]
set_property name led   [get_bd_ports led_0]
set_property name sig_out [get_bd_ports sig_out_0]

puts "===> ADDRESS"
assign_bd_address

puts "===> VALIDATE"
validate_bd_design

# ---- 安全检查：AXI 接口必须关联到时钟，否则会挂死 PS ----
# 症状见 la_top_axi_wrap.v 文件头：BD 41-2265 / IP_Flow 19-3158 一出现，
# 协议转换器时钟就接不上，PS 一读就永久等待，整颗芯片卡死只能断电。
set assoc ""
catch { set assoc [get_property CONFIG.ASSOCIATED_BUSIF \
                     [get_bd_pins la_top_axi_wrap_0/s_axi_aclk]] }
puts "  检查 s_axi_aclk 的 ASSOCIATED_BUSIF = '$assoc'"
if {[string first "S_AXI" [string toupper $assoc]] < 0} {
    puts "  !!! 时钟未关联到 S_AXI —— 中止构建（跑下去会挂死 PS，需要断电）"
    exit 1
}
puts "  OK - AXI 时钟关联正常"

puts "===> WRAPPER"
set bdfile [get_files sys.bd]
make_wrapper -files $bdfile -top
add_files -norecurse ${out}/${proj}.gen/sources_1/bd/sys/hdl/sys_wrapper.v
set_property top sys_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "===> XDC（只约束外部引脚；时钟由 PS FCLK_CLK0 提供，BD 自动生成时钟约束）"
# 注意：注释用 ASCII。Vivado 的 Tcl 写文件时不带 BOM，中文在后续读取时
# 会变成乱码（不影响功能，但难看且容易误读）。
set xdc [open "${out}/pins.xdc" w]
puts $xdc "# BTN0 (active high when pressed)"
puts $xdc "set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} \[get_ports btn0\]"
puts $xdc ""
puts $xdc "# Pmod A : 8 probe inputs"
set idx 0
foreach p {Y18 Y19 Y16 Y17 U18 U19 W18 W19} {
    puts $xdc "set_property -dict {PACKAGE_PIN $p IOSTANDARD LVCMOS33} \[get_ports {ch_in\[$idx\]}\]"
    incr idx
}
puts $xdc ""
puts $xdc "# On-board LEDs (active high)"
set idx 0
foreach p {R14 P14 N16 M14} {
    puts $xdc "set_property -dict {PACKAGE_PIN $p IOSTANDARD LVCMOS33} \[get_ports {led\[$idx\]}\]"
    incr idx
}
puts $xdc ""
puts $xdc "# Pmod B : 8 signal outputs (jumper wire back to Pmod A)"
set idx 0
foreach p {W14 Y14 T11 T10 V16 W16 V12 W13} {
    puts $xdc "set_property -dict {PACKAGE_PIN $p IOSTANDARD LVCMOS33} \[get_ports {sig_out\[$idx\]}\]"
    incr idx
}
close $xdc
add_files -fileset constrs_1 -norecurse "${out}/pins.xdc"

puts "===> GENERATE TARGETS"
generate_target all $bdfile

# ---------------------------------------------------------------------
puts "===> LAUNCH (顺便把缺失的 OOC IP run 建出来)"
if {[catch {launch_runs impl_1 -to_step write_bitstream -jobs 4} e]} {
    puts "  (launch 返回：$e)"
}

set t0 [clock seconds]
set ipdir "${out}/${proj}.gen/sources_1/bd/sys/ip"
set runbase "${out}/${proj}.runs"
# 判据用 **run 目录里的完成标记文件**，最可靠：
#   - get_property STATUS 会被误报成 ERROR（坑 23）
#   - 只看 dcp 数量会在"第一个 dcp 还没出现"时误判为稳定
#   - 顶层 synth_1/impl_1 会永远停在 Not started
while {1} {
    set dirs [glob -nocomplain ${runbase}/sys_*_synth_1]
    if {[llength $dirs] > 0} {
        set alldone 1
        foreach d $dirs {
            if {[llength [glob -nocomplain ${d}/__synthesis_is_complete__]] == 0} {
                set alldone 0
            }
        }
        if {$alldone} { break }
    }
    if {[clock seconds] - $t0 > 600} {
        # 超时基本都意味着某个 OOC run 综合失败了（例如漏加源文件）。
        # 这里把失败 run 的日志尾部打出来，否则只能看到一句 timeout，白等十分钟。
        puts "  !!! timeout"
        foreach d [glob -nocomplain ${runbase}/sys_*_synth_1] {
            if {[llength [glob -nocomplain ${d}/__synthesis_is_complete__]] == 0} {
                puts "  --- incomplete run: [file tail $d] ---"
                set lg "${d}/runme.log"
                if {[file exists $lg]} {
                    set fh [open $lg r]
                    set lines [split [read $fh] "\n"]
                    close $fh
                    set n [llength $lines]
                    set from 0
                    if {$n > 25} { set from [expr {$n - 25}] }
                    foreach ln [lrange $lines $from end] { puts "    $ln" }
                }
            }
        }
        exit 1
    }
    after 4000
}
puts "  OOC run 数 = [llength [glob -nocomplain ${runbase}/sys_*_synth_1]]"
puts "  IP dcp 数量 = [llength [glob -nocomplain ${ipdir}/*/*.dcp]]"

puts "===> SYNTH (direct)"
if {[catch {synth_design -top sys_wrapper -part $part} e]} {
    puts "  !!! synth failed: $e"; exit 1
}
puts "===> IMPL (direct)"
if {[catch { opt_design; place_design; route_design } e]} {
    puts "  !!! impl failed: $e"; exit 1
}
puts "===> TIMING / UTIL"
catch { report_timing_summary -no_detailed_paths -file "${out}/la_sys_timing.rpt" }
catch { report_utilization -file "${out}/la_sys_util.rpt" }

puts "===> WRITE BITSTREAM"
if {[catch { write_bitstream -force -file "${out}/la_sys.bit" } e]} {
    puts "  !!! bitstream failed: $e"; exit 1
}

file copy -force "${out}/${proj}.gen/sources_1/bd/sys/hw_handoff/sys.hwh" "${out}/la_sys.hwh"

puts "===> RESULT"
puts "  BIT : [expr {[file exists ${out}/la_sys.bit] ? "OK" : "MISSING"}]"
puts "  HWH : [expr {[file exists ${out}/la_sys.hwh] ? "OK" : "MISSING"}]"
puts "===> DONE"
