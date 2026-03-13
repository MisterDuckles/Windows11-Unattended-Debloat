@echo off
setlocal

set LOG=%WINDIR%\Panther\debloat.log
echo %date% %time%  SetupComplete gestart>>"%LOG%"

powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden -File "%WINDIR%\Setup\Scripts\launcher.ps1" >>"%LOG%" 2>&1
set EXITCODE=%ERRORLEVEL%

echo %date% %time%  SetupComplete klaar (exitcode %EXITCODE%)>>"%LOG%"

endlocal
exit /b 0
