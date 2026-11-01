@echo off
REM Double-click to rebuild AND re-download (takes about 3 minutes).
REM Usage from cmd:  rebuild.bat  top_name

set "VIVADO=D:\Xilinx\2025.2\Vivado\bin\vivado.bat"
set "SCRIPTS=%~dp0"
set "TOP=%~1"
if "%TOP%"=="" set "TOP=stage2_top"

echo ============================================
echo  Rebuilding : %TOP%   (about 3 minutes)
echo ============================================
call "%VIVADO%" -mode batch -source "%SCRIPTS%build_nonproj.tcl" -tclargs %TOP%
if errorlevel 1 goto fail

echo.
echo ============================================
echo  Programming board
echo ============================================
call "%VIVADO%" -mode batch -source "%SCRIPTS%program.tcl" -tclargs %TOP%
goto end

:fail
echo BUILD FAILED - check the log above.

:end
echo.
echo Done. Press any key to close.
pause >nul
