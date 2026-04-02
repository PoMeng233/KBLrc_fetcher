@echo off
setlocal enabledelayedexpansion

title Build Lyrics Fetcher Release

cd /d "%~dp0"

echo ==========================================
echo   Build Lyrics Fetcher Release Package
echo ==========================================
echo.

where py >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Python launcher "py" was not found.
    echo Please install Python 3 and make sure it is added to PATH.
    pause
    exit /b 1
)

echo [STEP] Checking Python...
py -3 --version
if errorlevel 1 (
    echo [ERROR] Python 3 is not available.
    pause
    exit /b 1
)

echo.
echo [STEP] Installing / upgrading build dependencies...
py -3 -m pip install --upgrade pip
if errorlevel 1 (
    echo [ERROR] Failed to upgrade pip.
    pause
    exit /b 1
)

py -3 -m pip install -r requirements.txt
if errorlevel 1 (
    echo [ERROR] Failed to install requirements from requirements.txt.
    pause
    exit /b 1
)

py -3 -m pip install --upgrade pyinstaller
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
py -3 -m PyInstaller ^
    --noconfirm ^
    --clean ^
    --windowed ^
    --onefile ^
    --name LyricsFetcher ^
    --collect-all mutagen ^
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
