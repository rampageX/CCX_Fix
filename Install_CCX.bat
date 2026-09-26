@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CCX_ENABLE_SYSTEM_SEARCH=0"
set "CCX_CORE=%~dp0CCX_Core.ps1"
if not exist "%CCX_CORE%" (
  echo CCX_Core.ps1 missing.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CCX_CORE%"
set "CCX_RC=%errorlevel%"
echo.
if not "%CCX_RC%"=="0" echo Exit code: %CCX_RC%
pause
exit /b %CCX_RC%
