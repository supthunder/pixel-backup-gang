@echo off
setlocal DisableDelayedExpansion
set "PIXELBACKUP_PICKER=%~dp0Select-PixelFolder.ps1"
set "PIXELBACKUP_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PIXELBACKUP_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PIXELBACKUP_PS%" -NoLogo -NoProfile -NonInteractive -Command ^
    "$ErrorActionPreference = 'Stop';" ^
    "$arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy RemoteSigned -File ' + [char]34 + $env:PIXELBACKUP_PICKER + [char]34;" ^
    "$process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru;" ^
    "exit $process.ExitCode"
if errorlevel 1 (
    echo PixelBackup could not finish. Check the Windows message or run Select-PixelFolder.ps1 in an elevated Windows PowerShell window for details.
    pause
    exit /b 1
)
