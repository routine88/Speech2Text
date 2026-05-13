@echo off
REM Speech2Text — One-Click Launcher (Windows)
REM Double-click this file to install/update and launch Speech2Text.
REM The sentinel below tells launch.ps1 that this wrapper will keep the
REM window open, so the .ps1 does not have to add its own pause.
set "S2T_LAUNCHED_FROM_BAT=1"
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0launch.ps1" %*
set "RC=%ERRORLEVEL%"
set "S2T_LAUNCHED_FROM_BAT="
REM Pause on any non-success exit so the user can read errors before the
REM window closes. The success path execs the GUI and returns its exit code,
REM so a clean exit (0) skips the pause.
if not "%RC%"=="0" pause
exit /b %RC%
