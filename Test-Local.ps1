<#
.SYNOPSIS
  Local dry-run test for the license sync. Unattended app auth (no device code); spends nothing.
.DESCRIPTION
  Set credentials as environment variables first (these stay out of the scripts and logs):
    $env:GRAPH_CLIENT_ID     = '<entra app client id>'
    $env:GRAPH_CLIENT_SECRET = '<entra app client secret>'
    $env:PAX8_CLIENT_ID      = '<pax8 client id>'
    $env:PAX8_CLIENT_SECRET  = '<pax8 client secret>'
  Graph uses app-only auth against the tenant's msTenantId. Without Pax8 creds the plan still
  runs read-only and treats Pax8 quantities as 0.
#>
[CmdletBinding()]
param([string]$TenantKey = 'riceland')

# Uses unattended app auth when GRAPH_CLIENT_ID / GRAPH_CLIENT_SECRET are set (no device code).
& (Join-Path $PSScriptRoot 'Invoke-LicenseSync.ps1') -TenantKey $TenantKey -Mode Both
Write-Host "`nDry-run complete. Review the table above and the JSON log under .\logs." -ForegroundColor Green
