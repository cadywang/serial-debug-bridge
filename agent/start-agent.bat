@echo off
REM ---------------------------------------------------------------------------
REM  Start the serial debug bridge agent on Windows  (CLIENT side).
REM  Edit the three settings below, then double-click this file or run it.
REM ---------------------------------------------------------------------------
setlocal
set PORT=COM3
set BAUD=115200
set TCPPORT=7801

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serial_agent.ps1" -Port %PORT% -Baud %BAUD% -TcpPort %TCPPORT%