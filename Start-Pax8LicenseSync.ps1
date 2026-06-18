<#
.SYNOPSIS
  Azure Automation runbook. Pulls the latest project from GitHub and runs the sync.
.DESCRIPTION
  This is the only file you import into Azure Automation as a runbook. It downloads the current project
  from GitHub on every run, so updating the automation is just a git commit.

  Required Automation Variables:
    GitHubOwnerRepo    'owner/repo' of the public project repo
    Pax8ClientId, Pax8ClientSecret, GraphClientId, GraphClientSecret   (mark secrets as encrypted)
  Optional Automation Variables:
    GitHubBranch       branch to pull (default 'main')
    RunMode            TopUp | Transition | Both (default Both)
    RunExecute         'true' to place real orders (otherwise dry-run)
    RunMockExecute     'true' to run the live path with isMock orders (no spend)

  Prerequisite modules (import once from the gallery into the Automation account, runtime 7.2):
    Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement
#>
[CmdletBinding()]
param(
    [string]$TenantKey,
    [ValidateSet('TopUp','Transition','Both')][string]$Mode,
    [switch]$Execute,
    [switch]$MockExecute
)
$ErrorActionPreference = 'Stop'

$ownerRepo = Get-AutomationVariable -Name 'GitHubOwnerRepo'
$branch    = try { Get-AutomationVariable -Name 'GitHubBranch' } catch { $null }
if (-not $branch) { $branch = 'main' }
if (-not $Mode)        { try { $Mode = Get-AutomationVariable -Name 'RunMode' } catch { } }
if (-not $Mode)        { $Mode = 'Both' }
if (-not $Execute)     { try { if ((Get-AutomationVariable -Name 'RunExecute')     -eq 'true') { $Execute = $true } }     catch { } }
if (-not $MockExecute) { try { if ((Get-AutomationVariable -Name 'RunMockExecute') -eq 'true') { $MockExecute = $true } } catch { } }

Write-Output ("Fetching {0}@{1} from GitHub..." -f $ownerRepo, $branch)
$work = Join-Path $env:TEMP ('pax8-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$zip = Join-Path $work 'repo.zip'
Invoke-WebRequest -Uri ("https://github.com/{0}/archive/refs/heads/{1}.zip" -f $ownerRepo, $branch) -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $work -Force

$proj = Get-ChildItem -Path $work -Directory | Select-Object -First 1
if (-not $proj) { throw "Repo download did not expand to a project folder under $work" }
$entry = Join-Path $proj.FullName 'Invoke-LicenseSync.ps1'
if (-not (Test-Path $entry)) { throw "Invoke-LicenseSync.ps1 not found in the repo download at $($proj.FullName)" }

Write-Output ("Running sync (Mode={0}, Execute={1}, MockExecute={2})..." -f $Mode, [bool]$Execute, [bool]$MockExecute)
$argz = @{ Mode = $Mode }
if ($TenantKey)   { $argz.TenantKey   = $TenantKey }
if ($Execute)     { $argz.Execute     = $true }
if ($MockExecute) { $argz.MockExecute = $true }
& $entry @argz

Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'Bootstrap complete.'
