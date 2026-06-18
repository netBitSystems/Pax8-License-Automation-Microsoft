<#
.SYNOPSIS
  Live end-to-end test against the real tenant and Pax8 using mock orders. Spends nothing.
.DESCRIPTION
  Runs the full runbook for one tenant with -MockExecute:
    - real Microsoft Graph reads (app auth) and real Pax8 reads
    - the real plan (topup / transition / wait / cap)
    - real calls to the Pax8 order endpoint with isMock=true (validated, nothing purchased)
    - top-ups are simulated, because Pax8 has no mock endpoint for a quantity change
  Requires the credential store created by Set-Credentials.ps1.
#>
[CmdletBinding()]
param([string]$TenantKey = 'riceland')

& (Join-Path $PSScriptRoot 'Invoke-LicenseSync.ps1') -TenantKey $TenantKey -Mode Both -MockExecute
Write-Host "`nLive mock test complete. Real reads and a real plan ran, orders were validated with isMock, and nothing was purchased. See the JSON log under .\logs." -ForegroundColor Green
