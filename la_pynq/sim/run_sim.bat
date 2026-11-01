@echo off
REM =====================================================================
REM  run_sim.bat [testbench_module]
REM
REM  Example:
REM    run_sim.bat tb_trig_fsm
REM
REM  Compiles the testbench with the RTL it needs, elaborates, runs to
REM  completion, and prints the self-check PASS/FAIL result in the log.
REM  Real parameters, no waveform recording - fast, small.
REM
REM  To actually see waveforms use run_wave.bat instead.
REM
REM  NOTE: keep this file pure ASCII. cmd.exe decodes .bat as GBK on a
REM        Chinese Windows, and UTF-8 Chinese comments get mangled into
REM        stray quote / ampersand characters that break every line.
REM =====================================================================

setlocal
set "VBIN=D:\Xilinx\2025.2\Vivado\bin"
set "SIMDIR=%~dp0"
set "RTL=%SIMDIR%..\rtl"

set "TB=%~1"
if "%TB%"=="" set "TB=tb_trig_fsm"

cd /d "%SIMDIR%"

echo ============================================
echo  Simulating : %TB%   (real parameters, PASS/FAIL only)
echo ============================================

REM --- pick the RTL files this testbench needs ---
if /I "%TB%"=="tb_trig_fsm" (
    set "RTLFILES=%RTL%\trig_fsm.v"
)
if /I "%TB%"=="tb_cap_mem" (
    set "RTLFILES=%RTL%\cap_mem.v"
)
if /I "%TB%"=="tb_stage3" (
    set "RTLFILES=%RTL%\test_gen.v %RTL%\smp_clk_div.v %RTL%\din_sync.v %RTL%\trig_fsm.v %RTL%\cap_mem.v %RTL%\stage3_top.v"
)
if /I "%TB%"=="tb_proto_uart" (
    set "RTLFILES=%RTL%\uart_tx.v %RTL%\proto_uart.v"
)
if /I "%TB%"=="tb_proto_spi" (
    set "RTLFILES=%RTL%\proto_spi.v"
)
if /I "%TB%"=="tb_proto_i2c" (
    set "RTLFILES=%RTL%\proto_i2c.v"
)
if /I "%TB%"=="tb_proto_src" (
    set "RTLFILES=%RTL%\spi_src.v %RTL%\proto_spi.v %RTL%\i2c_src.v %RTL%\proto_i2c.v"
)
if /I "%TB%"=="tb_stage4" (
    set "RTLFILES=%RTL%\i2c_src.v %RTL%\proto_i2c.v %RTL%\proto_trig.v %RTL%\smp_clk_div.v %RTL%\trig_fsm.v %RTL%\cap_mem.v %RTL%\stage4_top.v"
)
if /I "%TB%"=="tb_timing_stats" (
    set "RTLFILES=%RTL%\timing_stats.v"
)
if /I "%TB%"=="tb_axi_regs" (
    set "RTLFILES=%RTL%\axi_regs.v"
)
if /I "%TB%"=="tb_la_top" (
    set "RTLFILES=%RTL%\din_sync.v %RTL%\smp_clk_div.v %RTL%\cap_mem.v %RTL%\trig_fsm.v %RTL%\proto_uart.v %RTL%\proto_spi.v %RTL%\proto_i2c.v %RTL%\proto_trig.v %RTL%\timing_stats.v %RTL%\axi_regs.v %RTL%\test_gen.v %RTL%\i2c_src.v %RTL%\uart_tx.v %RTL%\la_top.v"
)
if /I "%TB%"=="tb_loopback" (
    set "RTLFILES=%RTL%\test_gen.v %RTL%\smp_clk_div.v %RTL%\din_sync.v %RTL%\loopback_top.v"
)

REM NOTE: the exit code of Vivado's .bat wrappers is unreliable
REM       (xelab.bat returns non-zero even on success), so we do not
REM       test errorlevel here - judge by the tool's own messages.
call "%VBIN%\xvlog.bat" %RTLFILES% "%SIMDIR%%TB%.v"
call "%VBIN%\xelab.bat" %TB% -s %TB%_sim
call "%VBIN%\xsim.bat" %TB%_sim -runall

echo.
echo ============================================
echo  Simulation finished - check RESULT above.
echo ============================================
pause
endlocal
