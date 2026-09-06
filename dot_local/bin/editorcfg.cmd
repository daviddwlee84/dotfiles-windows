@echo off
pwsh.exe -NoLogo -NoProfile -File "%~dp0editorcfg.ps1" %*
exit /b %ERRORLEVEL%
