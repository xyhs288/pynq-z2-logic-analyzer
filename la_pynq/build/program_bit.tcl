# =====================================================================
#  program_bit.tcl —— 通过 JTAG 下载任意 bitstream（绕过 PYNQ）
#
#  用途：当 PYNQ 加载 overlay 导致板子卡死时，用这个直接下载，
#        判断问题出在「PL 设计本身」还是「PYNQ 的加载流程」。
#          - JTAG 下载后板子还活着（SSH 能连）→ PL 设计没问题
#          - JTAG 下载后板子也死       → PL 设计有问题
#
#  用法：
#    vivado -mode batch -source program_bit.tcl -tclargs <path/to/x.bit>
# =====================================================================

set bitfile [lindex $argv 0]
if {$bitfile eq ""} {
    puts "!!! usage: -tclargs <bitfile>"
    exit 1
}
if {![file exists $bitfile]} {
    puts "!!! bitfile not found: $bitfile"
    exit 1
}
puts "===> BITFILE = $bitfile"

open_hw_manager
connect_hw_server -allow_non_jtag

set tgt ""
foreach t [get_hw_targets] {
    catch {
        open_hw_target $t
        set tgt $t
    }
    if {$tgt ne ""} { break }
}
if {$tgt eq ""} {
    puts "!!! no hw_target found (板子插着 micro USB 吗？)"
    exit 1
}
puts "===> TARGET = $tgt"

# Zynq 上会同时出现 xc7z020 和 arm_dap_0，必须挑 PART 匹配 xc7z020 的那个
set dev ""
foreach d [get_hw_devices] {
    set part "?"
    catch { set part [get_property PART $d] }
    puts "    device: $d  PART=$part"
    if {[string match "*xc7z020*" $part]} { set dev $d }
}
if {$dev eq ""} {
    puts "!!! no xc7z020 device found"
    exit 1
}
puts "===> DEVICE = $dev"

set_property PROGRAM.FILE $bitfile $dev
program_hw_devices $dev
puts "===> PROGRAM DONE"

catch { close_hw_target }
catch { disconnect_hw_server }
catch { close_hw_manager }
puts "===> DONE"
