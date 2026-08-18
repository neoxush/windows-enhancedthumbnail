@echo off
REM ==========================================================================
REM  Launch.bat - THE only file you need to start the toolkit.
REM  Runs the environment check, then launches Live Preview (with the built-in
REM  Automate feature). All program files live in the app\ subfolder.
REM  Zero dependencies.
REM ==========================================================================
setlocal
set "PS1=%~dp0app\MacroTool.ps1"
set "LP=%~dp0app\LivePreview.ps1"

echo Checking environment...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" checkenv
if errorlevel 1 (
    echo.
    echo Environment check FAILED. Please resolve the issues above.
    echo.
    pause
    exit /b 1
)

echo.
echo Launching Live Preview + Automate...
start "" powershell -NoProfile -ExecutionPolicy Bypass -File "%LP%"
endlocal
