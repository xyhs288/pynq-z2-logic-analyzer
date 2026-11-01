# =====================================================================
#  program.tcl —— 把 bitstream 下载到开发板
#
#  用法：
#    vivado -mode batch -source program.tcl -tclargs <顶层名>
#
#  前提：板子已插 micro USB；GUI 的 Hardware Manager 没有占着板子。
# =====================================================================

set here [file dirname [file normalize [info script]]]
set out [file join $here "out"]

if {$argc > 0} { set top [lindex $argv 0] } else { set top "loopback_top" }
set bit "${out}/${top}.bit"

if {![file exists $bit]} { error "BITSTREAM NOT FOUND: $bit" }
puts "===> BITSTREAM: ${bit}"

open_hw_manager
connect_hw_server
open_hw_target

set dev ""
foreach d [get_hw_devices] {
    if {[string match "xc7z020*" [get_property PART $d]]} { set dev $d }
}
if {$dev eq ""} { error "NO xc7z020 DEVICE FOUND" }
puts "===> TARGET DEVICE: ${dev}"

current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE ${bit} $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "===> PROGRAM DONE"
