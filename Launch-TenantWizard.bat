@echo off
cd /d "%~dp0"
pwsh.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0New-TenantConfig.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo -------------------------------------------------------
    echo  The wizard encountered an error. See details above.
    echo  Common causes:
    echo    - Run Set-Credentials.ps1 first to store API keys
    echo    - Pax8 or Graph credentials have expired
    echo -------------------------------------------------------
    pause
)
