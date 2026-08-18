@echo off
REM ==========================================================================
REM  console.bat - alternative UI (MacroTool HTA console, automation only)
REM  Use launcher.bat for the main Live Preview + Automate experience.
REM  Verifies the environment, then opens the HTA console. No dependencies.
REM ==========================================================================
setlocal
set "PS1=%~dp0MacroTool.ps1"
set "HTA=%~dp0MacroTool.hta"

echo Checking environment...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" checkenv
if errorlevel 1 (
    echo.
    echo Environment check FAILED. The console will not be launched.
    echo Please resolve the issues above and try again.
    echo.
    pause
    exit /b 1
)

echo.
echo Launching MacroTool console...
start "" mshta.exe "%HTA%"
endlocal
