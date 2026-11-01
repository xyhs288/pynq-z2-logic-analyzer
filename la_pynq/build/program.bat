@echo off
REM Double-click to re-download the bitstream to the board.
REM Usage from cmd:  program.bat  top_name

set "VIVADO=D:\Xilinx\2025.2\Vivado\bin\vivado.bat"
set "SCRIPTS=%~dp0"
set "TOP=%~1"
if "%TOP%"=="" set "TOP=stage2_top"

echo ============================================
echo  Re-programming board with : %TOP%
echo ============================================
call "%VIVADO%" -mode batch -source "%SCRIPTS%program.tcl" -tclargs %TOP%

echo.
echo Done. Press any key to close.
pause >nul
