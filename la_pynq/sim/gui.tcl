# =====================================================================
#  gui.tcl - record the waveform and put it on screen (no exit!)
#
#  Called by run_wave.bat:
#     xsim <snapshot> -gui -tclbatch gui.tcl
#
#  stdout of a GUI session does not reach the log file, so progress is
#  also written to addwave_result.txt for diagnosis.
#
#  Keep this file ASCII-only: xsim echoes it into a GBK console.
# =====================================================================

set logf [open "addwave_result.txt" w]
puts $logf "start"

log_wave -recursive /*
puts $logf "log_wave ok"
flush $logf

run all
puts $logf "run all ok"
flush $logf

# Without this the viewer opens with an empty wave pane.
if {[catch {add_wave -recursive /*} err]} {
    puts $logf "ADD_WAVE_FAILED: $err"
} else {
    puts $logf "ADD_WAVE_OK"
}
flush $logf
close $logf
