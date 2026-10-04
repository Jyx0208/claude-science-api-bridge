@echo off
rem Double-click entry point for the Windows safe installer.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-safe.ps1" %*
pause
