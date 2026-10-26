@echo off
REM startup.bat — Double-click launcher for desktop Ollama
REM Runs startup.ps1 from this script's directory

REM PowerShell 7 only (AGENTS.md); pwsh.exe must be on PATH.
pwsh -ExecutionPolicy Bypass -File "%~dp0startup.ps1"
pause
