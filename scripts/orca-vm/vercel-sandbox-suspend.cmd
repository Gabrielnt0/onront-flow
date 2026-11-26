@echo off
setlocal
if defined WSLENV (set "WSLENV=%WSLENV%;GH_TOKEN:VERCEL_TOKEN") else (set "WSLENV=GH_TOKEN:VERCEL_TOKEN")
bash ./scripts/orca-vm/vercel-sandbox-suspend.sh %*
exit /b %ERRORLEVEL%
