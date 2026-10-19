@echo off
REM ---------------------------------------------------------------------------
REM  Stop the serial debug bridge agent on Windows  (CLIENT side) and release
REM  the serial port, so another program (or a fresh agent) can open it.
REM  Leave PORT/TCPPORT empty to stop every serial_agent.ps1 on this machine.
REM  For scripts, call stop-agent.ps1 directly (this file pauses at the end).
REM ---------------------------------------------------------------------------
setlocal
set PORT=
set TCPPORT=

set ARGS=
if not "%PORT%"=="" set ARGS=%ARGS% -Port %PORT%
if not "%TCPPORT%"=="" set ARGS=%ARGS% -TcpPort %TCPPORT%

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-agent.ps1" %ARGS%
pause