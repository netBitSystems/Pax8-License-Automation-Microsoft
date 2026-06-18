<#
.SYNOPSIS
  Commits and pushes any local changes to GitHub.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$env:PATH = "C:\Program Files\Git\bin;" + $env:PATH

$changed = git -C $PSScriptRoot status --porcelain
if (-not $changed) {
    Write-Host "`n  Nothing to sync — no changes since last push." -ForegroundColor Green
    Write-Host ''
    Read-Host '  Press Enter to continue' | Out-Null
    exit 0
}

Write-Host ''
Write-Host '  Changes to push:' -ForegroundColor Cyan
git -C $PSScriptRoot status --short
Write-Host ''

$msg = (Read-Host '  Commit message (press Enter for "Update")').Trim()
if (-not $msg) { $msg = 'Update' }

git -C $PSScriptRoot add .
git -C $PSScriptRoot commit -m $msg
git -C $PSScriptRoot push

Write-Host ''
Write-Host '  Pushed to GitHub.' -ForegroundColor Green
Write-Host ''
Read-Host '  Press Enter to continue' | Out-Null
