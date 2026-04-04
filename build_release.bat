@echo off
setlocal enabledelayedexpansion

title Build Lyrics Fetcher Release

cd /d "%~dp0"

echo ==========================================
echo   Build Lyrics Fetcher Release Package
echo ==========================================
echo.

set "PY_CMD="
set "PY_FALLBACK=C:\Users\PoMeng\AppData\Local\Programs\Python\Python313\python.exe"

where py >nul 2>nul
if not errorlevel 1 (
    set "PY_CMD=py -3"
)

if not defined PY_CMD (
    where python >nul 2>nul
    if not errorlevel 1 (
        set "PY_CMD=python"
    )
)

if not defined PY_CMD (
    if exist "%PY_FALLBACK%" (
        set "PY_CMD="%PY_FALLBACK%""
    )
)

if not defined PY_CMD (
    echo [ERROR] Could not find a usable Python interpreter.
    echo.
    echo Tried:
    echo   1. py -3
    echo   2. python
    echo   3. %PY_FALLBACK%
    echo.
    echo Please install Python 3 or update PY_FALLBACK in this script.
    pause
    exit /b 1
)

echo [STEP] Using Python command: %PY_CMD%
echo.

echo [STEP] Checking Python...
call %PY_CMD% --version
if errorlevel 1 (
    echo [ERROR] Python 3 is not available.
    pause
    exit /b 1
)

echo.
echo [STEP] Installing / upgrading build dependencies...
call %PY_CMD% -m pip install --upgrade pip
if errorlevel 1 (
    echo [ERROR] Failed to upgrade pip.
    pause
    exit /b 1
)

call %PY_CMD% -m pip install -r requirements.txt
if errorlevel 1 (
    echo [ERROR] Failed to install requirements from requirements.txt.
    pause
    exit /b 1
)

call %PY_CMD% -m pip install --upgrade pyinstaller
if errorlevel 1 (
    echo [ERROR] Failed to install PyInstaller.
    pause
    exit /b 1
)

echo.
echo [STEP] Cleaning old build artifacts...
if exist build rmdir /s /q build
if exist dist rmdir /s /q dist
if exist LyricsFetcher.spec del /f /q LyricsFetcher.spec

echo.
echo [STEP] Building GUI executable with PyInstaller...
call %PY_CMD% -m PyInstaller ^
    --noconfirm ^
    --clean ^
    --windowed ^
    --onefile ^
    --name LyricsFetcher ^
    --collect-all mutagen ^
    --collect-all customtkinter ^
    --collect-all darkdetect ^
    lyrics_fetcher_gui.py

if errorlevel 1 (
    echo [ERROR] PyInstaller build failed.
    pause
    exit /b 1
)

echo.
echo [STEP] Preparing release folder...
if not exist release mkdir release
if exist release\LyricsFetcher rmdir /s /q release\LyricsFetcher
mkdir release\LyricsFetcher

copy /y dist\LyricsFetcher.exe release\LyricsFetcher\LyricsFetcher.exe >nul
if errorlevel 1 (
    echo [ERROR] Failed to copy built executable.
    pause
    exit /b 1
)

if exist README.md copy /y README.md release\LyricsFetcher\README.md >nul
if exist fetch_lyrics.bat copy /y fetch_lyrics.bat release\LyricsFetcher\fetch_lyrics.bat >nul
if exist fetch_lyrics_cli.bat copy /y fetch_lyrics_cli.bat release\LyricsFetcher\fetch_lyrics_cli.bat >nul

echo @echo off> release\LyricsFetcher\run_gui.bat
echo start "" "%%~dp0LyricsFetcher.exe">> release\LyricsFetcher\run_gui.bat

echo.
echo [STEP] Creating zip package (PowerShell)...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "if (Test-Path 'release\LyricsFetcher.zip') { Remove-Item 'release\LyricsFetcher.zip' -Force }; Compress-Archive -Path 'release\LyricsFetcher\*' -DestinationPath 'release\LyricsFetcher.zip' -Force"

if errorlevel 1 (
    echo [WARN] ZIP creation failed, but the unpacked release folder is ready:
    echo        %cd%\release\LyricsFetcher
    echo.
    echo [DONE] Build completed with warnings.
    pause
    exit /b 0
)

echo.
echo ==========================================
echo [DONE] Build completed successfully.
echo EXE:  %cd%\dist\LyricsFetcher.exe
echo DIR:  %cd%\release\LyricsFetcher
echo ZIP:  %cd%\release\LyricsFetcher.zip
echo ==========================================
echo.
pause
exit /b 0
