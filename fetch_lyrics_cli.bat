@echo off
setlocal

set SCRIPT_DIR=%~dp0
py "%SCRIPT_DIR%lyrics_fetcher.py" %*

if errorlevel 1 (
    echo.
    echo Command failed with exit code %errorlevel%.
    pause
)

endlocal
