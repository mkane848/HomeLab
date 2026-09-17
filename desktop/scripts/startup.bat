@echo off
REM startup.bat — Double-click launcher for desktop Ollama
REM Runs startup.ps1 from this script's directory

powershell -ExecutionPolicy Bypass -File "%~dp0startup.ps1"
pause
