<#
.SYNOPSIS
  Register a Windows Scheduled Task that runs the license sync on a daily schedule.
.DESCRIPTION
  Simplest production deploy. Runs Invoke-LicenseSync.ps1 under PowerShell 7 as the current user, so it
  can read the encrypted credential store created by Set-Credentials.ps1. Defaults to a safe dry-run.
  Add -Execute to place orders (still subject to the gates in config\settings.json).
.NOTES
  The encrypted credential store is bound to the user and machine that created it. Run Set-Credentials.ps1
  as the SAME account this task runs as. If DPAPI decryption fails under S4U logon, re-register with the
  account password (LogonType Password) or use machine environment variables for the credentials.
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'Pax8 License Sync',
    [string]$TimeOfDay = '02:00',
    [ValidateSet('TopUp','Transition','Both')][string]$Mode = 'Both',
    [string]$TenantKey,
    [switch]$Execute
)

$pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
$script   = Join-Path $PSScriptRoot 'Invoke-LicenseSync.ps1'
if (-not (Test-Path $script)) { throw "Cannot find $script" }

$argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode {1}' -f $script, $Mode
if ($TenantKey) { $argLine += " -TenantKey $TenantKey" }
if ($Execute)   { $argLine += ' -Execute' }

$me        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action    = New-ScheduledTaskAction -Execute $pwshPath -Argument $argLine
$trigger   = New-ScheduledTaskTrigger -Daily -At $TimeOfDay
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType S4U -RunLevel Highest
$set       = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $set -Force | Out-Null

Write-Host ("Registered '{0}' to run daily at {1}." -f $TaskName, $TimeOfDay) -ForegroundColor Green
Write-Host ("Command: {0} {1}" -f $pwshPath, $argLine) -ForegroundColor Gray
Write-Host ("Runs as: {0}  (run Set-Credentials.ps1 as this account)" -f $me) -ForegroundColor Gray
if (-not $Execute) { Write-Host "Mode is dry-run (no orders). Re-run with -Execute after setting the gates in settings.json." -ForegroundColor Yellow }
