@echo off
:menu
cls
echo.
echo  ============================================================
echo   Pax8 License Automation
echo  ============================================================
echo.
echo   [1] First-time setup         (new install - start here)
echo   [2] Add a new client
echo   [3] Run local dry-run test   (no changes, report only)
echo   [4] Run live mock test       (real data, no spend)
echo   [5] Sync to GitHub
echo   [6] Open project folder
echo   [7] Exit
echo.
set /p choice=  Enter a number: 

if "%choice%"=="1" goto setup
if "%choice%"=="2" goto addclient
if "%choice%"=="3" goto dryrun
if "%choice%"=="4" goto mocktest
if "%choice%"=="5" goto sync
if "%choice%"=="6" goto openfolder
if "%choice%"=="7" goto end
goto menu

:setup
pwsh.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Initialize-Automation.ps1"
if %ERRORLEVEL% NEQ 0 pause
goto menu

:addclient
pwsh.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0New-TenantConfig.ps1"
if %ERRORLEVEL% NEQ 0 pause
goto menu

:dryrun
pwsh.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Test-Local.ps1"
pause
goto menu

:mocktest
pwsh.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Invoke-LiveTest.ps1"
pause
goto menu

:sync
pwsh.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Sync-ToGitHub.ps1"
goto menu

:openfolder
explorer "%~dp0"
goto menu

:end
