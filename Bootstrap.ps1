<#
.SYNOPSIS
  Installs Pax8 License Automation on this machine.
.DESCRIPTION
  Downloads the project from GitHub, extracts it, creates a desktop shortcut,
  and launches the setup assistant.

  Run this once on any machine you want to operate from.
  You do not need git or any other tools pre-installed.

  Usage:
    powershell -ExecutionPolicy Bypass -File Bootstrap.ps1

  Or paste this into PowerShell:
    irm https://raw.githubusercontent.com/netBitSystems/Pax8-License-Automation-Microsoft/main/Bootstrap.ps1 | iex
#>
[CmdletBinding()] param(
    [string]$InstallPath = 'D:\Pax8LicenseAutomation'
)
$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '  Pax8 License Automation - Installer' -ForegroundColor Blue
Write-Host '  =====================================' -ForegroundColor Blue
Write-Host ''

# ---- Download repo ----
$zipUrl  = 'https://github.com/netBitSystems/Pax8-License-Automation-Microsoft/archive/refs/heads/main.zip'
$tmpZip  = Join-Path $env:TEMP 'pax8-install.zip'
$tmpDir  = Join-Path $env:TEMP 'pax8-install'

Write-Host '  Downloading...' -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing
} catch {
    Write-Host "  ERROR: Could not download. Check your internet connection." -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)"
    Read-Host "`n  Press Enter to exit"
    exit 1
}

# ---- Extract ----
Write-Host '  Extracting...' -ForegroundColor Cyan
if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
$extracted = Get-ChildItem $tmpDir -Directory | Select-Object -First 1
if (-not $extracted) {
    Write-Host '  ERROR: Could not extract the downloaded file.' -ForegroundColor Red
    Read-Host "`n  Press Enter to exit"
    exit 1
}

# ---- Install ----
Write-Host "  Installing to $InstallPath..." -ForegroundColor Cyan
if (Test-Path $InstallPath) {
    # Preserve existing tenant configs and credentials
    $backupTenants = Join-Path $env:TEMP 'pax8-tenants-backup'
    $tenantSrc     = Join-Path $InstallPath 'config\tenants'
    $credSrc       = Join-Path $InstallPath 'config\credentials.local.xml'
    if (Test-Path $tenantSrc) { Copy-Item $tenantSrc $backupTenants -Recurse -Force }
    $hadCreds = Test-Path $credSrc
    if ($hadCreds) { Copy-Item $credSrc "$env:TEMP\pax8-creds-backup.xml" -Force }
}

Copy-Item $extracted.FullName $InstallPath -Recurse -Force

# Restore preserved files
if ((Test-Path (Join-Path $env:TEMP 'pax8-tenants-backup'))) {
    Copy-Item "$env:TEMP\pax8-tenants-backup\*" (Join-Path $InstallPath 'config\tenants') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\pax8-tenants-backup" -Recurse -Force
}
if ((Test-Path "$env:TEMP\pax8-creds-backup.xml")) {
    Copy-Item "$env:TEMP\pax8-creds-backup.xml" (Join-Path $InstallPath 'config\credentials.local.xml') -Force
    Remove-Item "$env:TEMP\pax8-creds-backup.xml" -Force
}

# Clean up temp files
Remove-Item $tmpZip -ErrorAction SilentlyContinue
Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

# ---- Desktop shortcut ----
$desktopPath = [System.Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath 'Pax8 License Automation.lnk'
try {
    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut($shortcutPath)
    $sc.TargetPath      = Join-Path $InstallPath 'Launch-Pax8Tools.bat'
    $sc.WorkingDirectory = $InstallPath
    $sc.Description     = 'Pax8 License Automation Tools'
    $sc.Save()
    Write-Host '  Shortcut created on desktop.' -ForegroundColor Green
} catch {
    Write-Host '  Could not create desktop shortcut (non-fatal).' -ForegroundColor Yellow
}

# ---- Done ----
Write-Host ''
Write-Host '  Installed to: ' -ForegroundColor Green -NoNewline
Write-Host $InstallPath -ForegroundColor Cyan
Write-Host ''
Write-Host '  Next: run the setup assistant to connect to Pax8, Azure, and GitHub.' -ForegroundColor White
Write-Host ''

$launch = Read-Host '  Launch setup now? (Y/n)'
if ($launch -notmatch '^[Nn]') {
    & pwsh -ExecutionPolicy Bypass -NoProfile -File (Join-Path $InstallPath 'Initialize-Automation.ps1')
}
