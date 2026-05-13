@echo off
REM Speech2Text — One-Click Launcher (Windows)
REM Double-click this file to install/update and launch Speech2Text.
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0launch.ps1" %*
if %ERRORLEVEL% NEQ 0 pause
