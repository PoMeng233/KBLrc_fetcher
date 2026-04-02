@echo off
setlocal
py "%~dp0lyrics_fetcher_gui.py"
if errorlevel 1 pause
endlocal
