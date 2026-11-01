# =====================================================================
#  _bd_retry.tcl —— 绕开 run 管理器完成 block design 的综合/实现
#
#  已确认的两个问题（Vivado 2025.2 + 本机 Windows）：
#    1) run 管理器用子进程退出码判定成败，而 vivado.bat 退出码恒为 1
#       -> 成功的 run 被记成 ERROR。
#    2) wait_on_run 会提前返回，脚本一退出就把仍在跑的子进程杀掉
#       （症状：标记文件停在 __synthesis_is_running__）。
#
#  本脚本的做法：reset -> launch -> **按 DCP 文件存在与否轮询**，不信任
#  get_property STATUS；IP 全部落地后，用直接命令做综合/实现/出 bitstream。
# =====================================================================

set here [file dirname [file normalize [info script]]]
set proj [file join $here "out" "bdtest.xpr"]
set top  "sys_wrapper"
set part "xc7z020clg400-1"
set out  [file join $here "out"]
set bd   [file join $out "bdtest.gen" "sources_1" "bd" "sys"]

open_project $proj

# ---------------------------------------------------------------------
puts "===> IP RUNS"
set ipruns [get_runs -quiet -filter {NAME =~ "*_synth_1*"}]
foreach r $ipruns { puts "  [get_property NAME $r]" }

puts "===> RESET"
foreach r $ipruns { catch { reset_run $r } }

puts "===> LAUNCH"
launch_runs $ipruns -jobs 4

# ---------------------------------------------------------------------
# 轮询：等三个 IP 的 DCP 全部落地
puts "===> WAIT FOR DCPs"
set wants [list \
    "${bd}/ip/sys_ps7_0/sys_ps7_0.dcp" \
    "${bd}/ip/sys_gpio_0/sys_gpio_0.dcp" \
    "${bd}/ip/sys_ic_imp_auto_pc_0/sys_ic_imp_auto_pc_0.dcp" \
]
set t0 [clock seconds]
set ok 0
while {1} {
    set ok 1
    foreach f $wants { if {![file exists $f]} { set ok 0 } }
    if {$ok} { break }
    if {[clock seconds] - $t0 > 480} { puts "  !!! timeout"; break }
    after 5000
}
foreach f $wants { puts "  [expr {[file exists $f] ? "OK " : "MISS"}] $f" }
if {!$ok} { puts "  ABORT"; exit 1 }

puts "===> SYNTH (direct)"
if {[catch {synth_design -top $top -part $part} e]} {
    puts "  !!! synth failed: $e"; exit 1
}

puts "===> IMPL (direct)"
if {[catch { opt_design; place_design; route_design } e]} {
    puts "  !!! impl failed: $e"; exit 1
}

puts "===> WRITE BITSTREAM"
if {[catch { write_bitstream -force -file "${out}/test_axi.bit" } e]} {
    puts "  !!! write_bitstream failed: $e"; exit 1
}

set hwh "${bd}/hw_handoff/sys.hwh"
file copy -force $hwh "${out}/test_axi.hwh"

puts "===> RESULT"
puts "  BIT : [expr {[file exists ${out}/test_axi.bit] ? "OK" : "MISSING"}]"
puts "  HWH : [expr {[file exists ${out}/test_axi.hwh] ? "OK" : "MISSING"}]"
puts "===> DONE"
