@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PYTHON_EXE="
set "DEFAULT_PYTHON=C:\Users\PoMeng\AppData\Local\Programs\Python\Python313\python.exe"

where py >nul 2>nul
if not errorlevel 1 (
    py "%SCRIPT_DIR%lyrics_fetcher_gui.py"
    goto :end
)

where python >nul 2>nul
if not errorlevel 1 (
    python "%SCRIPT_DIR%lyrics_fetcher_gui.py"
    goto :end
)

if exist "%DEFAULT_PYTHON%" (
    "%DEFAULT_PYTHON%" "%SCRIPT_DIR%lyrics_fetcher_gui.py"
    goto :end
)

echo [ERROR] Python was not found in PATH, and the fallback path does not exist.
echo.
echo Tried:
echo   1. py
echo   2. python
echo   3. %DEFAULT_PYTHON%
echo.
echo Please install Python or update this launcher with the correct Python path.
pause

:end
if errorlevel 1 pause
endlocal
