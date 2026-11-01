@echo off
REM =====================================================================
REM  run_wave.bat [testbench_module]
REM
REM  Example:
REM    run_wave.bat tb_trig_fsm
REM
REM  Runs the testbench in WAVE_MODE (scaled-down parameters so the
REM  waveform window is only a few microseconds wide), then produces:
REM    1. tb_xxx.wdb          Vivado waveform database
REM    2. tb_xxx_wave.png     waveform picture (for reading / reports)
REM    3. a separate xsim waveform viewer window
REM
REM  For a plain PASS/FAIL check with real parameters use run_sim.bat.
REM
REM  NOTE 1: keep this file pure ASCII. cmd.exe decodes .bat as GBK on a
REM          Chinese Windows, and UTF-8 Chinese comments get mangled into
REM          stray quote / ampersand characters that break every line.
REM  NOTE 2: no angle-bracket characters anywhere, not even inside REM
REM          lines. cmd processes redirection before running the command.
REM =====================================================================

setlocal
set "VBIN=D:\Xilinx\2025.2\Vivado\bin"
set "SIMDIR=%~dp0"
set "RTL=%SIMDIR%..\rtl"
set "PY=D:\PYthon\python.exe"

set "TB=%~1"
if "%TB%"=="" set "TB=tb_trig_fsm"

REM  "nogui" as 2nd arg = batch mode: use a separate snapshot name and
REM  skip the .wdb file, so it can run while a viewer window from an
REM  earlier run is still open (xsim locks its snapshot and .wdb).
set "SNAP=%TB%_wave"
set "WDBOPT=-wdb %TB%.wdb"
if /I "%~2"=="nogui" (
    set "SNAP=%TB%_wave_cli"
    set "WDBOPT="
)

cd /d "%SIMDIR%"

echo ============================================
echo  Waveform : %TB%   (WAVE_MODE)
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
if /I "%TB%"=="tb_loopback" (
    set "RTLFILES=%RTL%\test_gen.v %RTL%\smp_clk_div.v %RTL%\din_sync.v %RTL%\loopback_top.v"
)

REM --- pick the matching plotting script ---
set "PLOTPY=plot_wave.py"
set "PLOTARG=%TB%.csv %TB%_wave.png"
if /I "%TB%"=="tb_cap_mem" (
    set "PLOTPY=plot_cap_mem.py"
    set "PLOTARG="
)
if /I "%TB%"=="tb_stage3" (
    set "PLOTPY=plot_stage3.py"
    set "PLOTARG="
)
if /I "%TB%"=="tb_proto_uart" (
    set "PLOTPY=plot_proto_uart.py"
    set "PLOTARG="
)
if /I "%TB%"=="tb_proto_spi" (
    set "PLOTPY=plot_proto_spi.py"
    set "PLOTARG="
)
if /I "%TB%"=="tb_proto_i2c" (
    set "PLOTPY=plot_proto_i2c.py"
    set "PLOTARG="
)
if /I "%TB%"=="tb_proto_src" (
    set "PLOTPY=plot_proto_src.py"
    set "PLOTARG="
)
if /I "%TB%"=="tb_stage4" (
    set "PLOTPY=plot_stage4.py"
    set "PLOTARG="
)
if /I "%TB%"=="tb_timing_stats" (
    set "PLOTPY=plot_timing_stats.py"
    set "PLOTARG="
)

echo [1/4] compile   (with WAVE_MODE define)
call "%VBIN%\xvlog.bat" -d WAVE_MODE %RTLFILES% "%SIMDIR%%TB%.v"

echo [2/4] elaborate (with debug info)
call "%VBIN%\xelab.bat" %TB% -s %SNAP% -debug typical
if not exist "%SIMDIR%xsim.dir\%SNAP%\" goto fail

echo [3/4] simulate + record waveform database
call "%VBIN%\xsim.bat" %SNAP% -tclbatch wave.tcl %WDBOPT%

echo [4/4] render waveform PNG
"%PY%" %PLOTPY% %PLOTARG%

echo.
echo ============================================
echo   %SIMDIR%%TB%_wave.png     - waveform picture
echo   %SIMDIR%%TB%.wdb          - waveform database
echo ============================================

REM  "nogui" as 2nd arg: only produce the files, do not open the viewer.
if /I "%~2"=="nogui" goto end

echo  opening viewer (close its window to finish)...
call "%VBIN%\xsim.bat" %SNAP% -gui -tclbatch gui.tcl
goto end

:fail
echo.
echo *** COMPILE FAILED - see the messages above ***
pause

:end
endlocal
