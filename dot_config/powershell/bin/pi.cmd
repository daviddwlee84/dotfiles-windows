@echo off
rem Trusted interactive cmd.exe shim. Batch files cannot preserve arbitrary
rem programmatic argv; automation should invoke pia-pi.ps1 with an argument array.
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0pia-pi.ps1" %*
exit /b %ERRORLEVEL%
