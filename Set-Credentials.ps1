<#
.SYNOPSIS
  Store or update the Graph and Pax8 credentials used by the license automation.
.DESCRIPTION
  Prompts for the four credential values and saves them to config\credentials.local.xml,
  encrypted with Windows DPAPI so only this user on this machine can read them. Secrets are
  hidden as you type or paste. Re-run this any time a key changes or expires. To remove the
  stored credentials, delete config\credentials.local.xml.

  This is the LOCAL store. In Azure Automation, set the same names as Automation variables
  (GraphClientId, GraphClientSecret, Pax8ClientId, Pax8ClientSecret) instead.
#>
[CmdletBinding()]
param([string]$Path = (Join-Path $PSScriptRoot 'config\credentials.local.xml'))

Write-Host 'Enter credentials. Secret values are hidden and stored encrypted (DPAPI, this user + machine only).' -ForegroundColor Cyan
$graphId  = (Read-Host 'Graph app client_id (Application ID)').Trim()
$graphSec = Read-Host 'Graph app client SECRET value' -AsSecureString
$pax8Id   = (Read-Host 'Pax8 client_id').Trim()
$pax8Sec  = Read-Host 'Pax8 client SECRET value' -AsSecureString

[pscustomobject]@{
    GraphClientId     = $graphId
    GraphClientSecret = $graphSec
    Pax8ClientId      = $pax8Id
    Pax8ClientSecret  = $pax8Sec
    UpdatedUtc        = (Get-Date).ToUniversalTime().ToString('o')
} | Export-Clixml -Path $Path

Write-Host ("Saved encrypted credentials to {0}" -f $Path) -ForegroundColor Green
Write-Host 'Re-run this script any time to update them. See README section "Credentials and rotation".' -ForegroundColor Gray
