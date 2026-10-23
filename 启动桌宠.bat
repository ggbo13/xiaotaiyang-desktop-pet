@echo off
setlocal
cd /d "%~dp0"

rem 优先使用系统 PowerShell 5.1，保证音乐媒体会话兼容。
set "SHELL_EXE="
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "SHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined SHELL_EXE if exist "%~dp0pwsh.exe" set "SHELL_EXE=%~dp0pwsh.exe"
if not defined SHELL_EXE if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "SHELL_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined SHELL_EXE if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "SHELL_EXE=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"

if not defined SHELL_EXE (
  echo [XiaoTaiYang] Could not find PowerShell. Please install it and retry.
  pause
  exit /b 1
)

rem Launch hidden and detach so the console window does not linger.
start "" /b "%SHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0xiaotaiyang.ps1"

endlocal
