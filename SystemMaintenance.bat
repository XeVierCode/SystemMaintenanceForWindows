@echo off
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb runAs"
    exit /b
)
powershell.exe -ExecutionPolicy Bypass -File "%~dp0Core.ps1"
