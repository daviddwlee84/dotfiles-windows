@echo off
rem External CLI adapter. First-party PowerShell callers use the .ps1 directly.
pwsh.exe -NoLogo -NoProfile -File "%~dp0dotfiles-editor.ps1" %*
exit /b %ERRORLEVEL%
