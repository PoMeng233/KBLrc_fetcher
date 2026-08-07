@echo off
setlocal enabledelayedexpansion

title Build KBlrc_fetcher Release

cd /d "%~dp0"

set "PYTHON_EXE="
set "APP_NAME=KBlrc_fetcher"
set "SPEC_FILE=%APP_NAME%.spec"
set "DIST_EXE=dist\%APP_NAME%.exe"
set "RELEASE_DIR=release\%APP_NAME%"
set "ZIP_NAME=%APP_NAME%.zip"

echo ==========================================
echo   Build %APP_NAME% Release Package
echo ==========================================
echo.

echo [STEP] Detecting Python...
where py >nul 2>nul
if not errorlevel 1 (
    py -3 --version >nul 2>nul
    if not errorlevel 1 (
        set "PYTHON_EXE=py -3"
        goto :python_ok
    )
)

where python >nul 2>nul
if not errorlevel 1 (
    python --version >nul 2>nul
    if not errorlevel 1 (
        set "PYTHON_EXE=python"
        goto :python_ok
    )
)

if exist "C:\Users\PoMeng\AppData\Local\Programs\Python\Python313\python.exe" (
    set "PYTHON_EXE=C:\Users\PoMeng\AppData\Local\Programs\Python\Python313\python.exe"
    goto :python_ok
)

echo [ERROR] Python was not found.
echo Tried: py -3, python, and fallback path.
pause
exit /b 1

:python_ok
echo [INFO] Using Python: %PYTHON_EXE%
echo.

echo [STEP] Installing dependencies...
%PYTHON_EXE% -m pip install --upgrade pip
if errorlevel 1 (
    echo [ERROR] Failed to upgrade pip.
    pause
    exit /b 1
)

if exist requirements.txt (
    %PYTHON_EXE% -m pip install -r requirements.txt
    if errorlevel 1 (
        echo [ERROR] Failed to install requirements.
        pause
        exit /b 1
    )
)

echo [STEP] Ensuring PyInstaller is installed...
%PYTHON_EXE% -m pip install --upgrade pyinstaller
if errorlevel 1 (
    echo [ERROR] Failed to install PyInstaller.
    pause
    exit /b 1
)
echo.

echo [STEP] Cleaning previous build artifacts...
if exist build rmdir /s /q build
if exist dist rmdir /s /q dist
if exist "%SPEC_FILE%" del /f /q "%SPEC_FILE%"
echo.

echo [STEP] Building executable...
%PYTHON_EXE% -m PyInstaller ^
    --noconfirm ^
    --clean ^
    --windowed ^
    --onefile ^
    --name %APP_NAME% ^
    --collect-all mutagen ^
    --collect-all customtkinter ^
    --collect-all darkdetect ^
    lyrics_fetcher_gui.py

if errorlevel 1 (
    echo [ERROR] Build failed.
    pause
    exit /b 1
)
echo.

if not exist "%DIST_EXE%" (
    echo [ERROR] Built executable not found: %DIST_EXE%
    pause
    exit /b 1
)

echo [STEP] Preparing release folder...
if not exist release mkdir release
if exist "%RELEASE_DIR%" rmdir /s /q "%RELEASE_DIR%"
mkdir "%RELEASE_DIR%"

copy /y "%DIST_EXE%" "%RELEASE_DIR%\%APP_NAME%.exe" >nul
if errorlevel 1 (
    echo [ERROR] Failed to copy built executable.
    pause
    exit /b 1
)

if exist README.md copy /y README.md "%RELEASE_DIR%\README.md" >nul
if exist fetch_lyrics.bat copy /y fetch_lyrics.bat "%RELEASE_DIR%\fetch_lyrics.bat" >nul
if exist fetch_lyrics_cli.bat copy /y fetch_lyrics_cli.bat "%RELEASE_DIR%\fetch_lyrics_cli.bat" >nul

echo @echo off> "%RELEASE_DIR%\run_gui.bat"
echo start "" "%%~dp0%APP_NAME%.exe">> "%RELEASE_DIR%\run_gui.bat"

echo [STEP] Creating zip archive...
if exist "release\%ZIP_NAME%" del /f /q "release\%ZIP_NAME%"

powershell -NoProfile -Command ^
    "Compress-Archive -Path '%RELEASE_DIR%\*' -DestinationPath 'release\%ZIP_NAME%' -Force" >nul 2>nul

if errorlevel 1 (
    echo [WARN] Failed to create ZIP with PowerShell. You can package manually.
) else (
    echo [INFO] ZIP created: release\%ZIP_NAME%
)

echo.
echo ==========================================
echo   Build completed successfully
echo ==========================================
echo Executable: %DIST_EXE%
echo Release dir: %RELEASE_DIR%
echo Zip package: release\%ZIP_NAME%
echo.
pause
endlocal
