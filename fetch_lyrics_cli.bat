@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PYTHON_EXE="

where py >nul 2>nul
if not errorlevel 1 (
    py -3 --version >nul 2>nul
    if not errorlevel 1 (
        py -3 "%SCRIPT_DIR%lyrics_fetcher.py" %*
        goto :after_run
    )
)

where python >nul 2>nul
if not errorlevel 1 (
    python --version >nul 2>nul
    if not errorlevel 1 (
        python "%SCRIPT_DIR%lyrics_fetcher.py" %*
        goto :after_run
    )
)

if exist "C:\Users\PoMeng\AppData\Local\Programs\Python\Python313\python.exe" (
    set "PYTHON_EXE=C:\Users\PoMeng\AppData\Local\Programs\Python\Python313\python.exe"
    "%PYTHON_EXE%" "%SCRIPT_DIR%lyrics_fetcher.py" %*
    goto :after_run
)

echo.
echo [ERROR] KBlrc_fetcher CLI launcher could not find a usable Python interpreter.
echo Tried:
echo   1. py -3
echo   2. python
echo   3. C:\Users\PoMeng\AppData\Local\Programs\Python\Python313\python.exe
echo.
echo Please install Python or add it to PATH, then restart KBlrc_fetcher.
pause
exit /b 1

:after_run
if errorlevel 1 (
    echo.
    echo KBlrc_fetcher CLI command failed with exit code %errorlevel%.
    pause
)

endlocal
