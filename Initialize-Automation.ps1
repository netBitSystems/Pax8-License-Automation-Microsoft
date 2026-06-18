<#
.SYNOPSIS
  First-time setup for Pax8 License Automation.
  Run with: pwsh -ExecutionPolicy Bypass -File Initialize-Automation.ps1
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot

Import-Module (Join-Path $scriptRoot 'src\Logging.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Pax8.psm1')    -Force

$settings = Get-Content (Join-Path $scriptRoot 'config\settings.json') -Raw | ConvertFrom-Json
Initialize-LogContext -Directory (Join-Path $env:TEMP 'Pax8Setup') -TenantKey 'setup' | Out-Null

function _Plain([System.Security.SecureString]$s) {
    if ($s) { [System.Net.NetworkCredential]::new('', $s).Password }
}

function Step {
    param([string]$Text)
    Write-Host "  $Text" -ForegroundColor White
}

function Done  { Write-Host "  OK: $args" -ForegroundColor Green }
function Fail  { Write-Host "  ERROR: $args" -ForegroundColor Red }
function Info  { Write-Host "  $args" -ForegroundColor DarkGray }
function Url   { Write-Host "  $args" -ForegroundColor Cyan }
function Title {
    param([string]$T, [string]$Sub = '')
    Write-Host ''
    Write-Host ('─' * 62) -ForegroundColor Blue
    Write-Host "  $T" -ForegroundColor White
    if ($Sub) { Write-Host "  $Sub" -ForegroundColor DarkGray }
    Write-Host ('─' * 62) -ForegroundColor Blue
    Write-Host ''
}

# Load any existing credentials
$pax8Id = $env:PAX8_CLIENT_ID; $pax8Sec = $env:PAX8_CLIENT_SECRET
$graphId = $env:GRAPH_CLIENT_ID; $graphSec = $env:GRAPH_CLIENT_SECRET
try {
    $cf = Join-Path $scriptRoot 'config\credentials.local.xml'
    if (Test-Path $cf) {
        $x = Import-Clixml $cf
        if (-not $pax8Id)  { $pax8Id  = $x.Pax8ClientId;  $pax8Sec  = _Plain $x.Pax8ClientSecret }
        if (-not $graphId) { $graphId = $x.GraphClientId; $graphSec = _Plain $x.GraphClientSecret }
    }
} catch { }

Clear-Host
Title 'Pax8 License Automation — Setup' 'Connects this tool to Pax8, Microsoft, and GitHub.'
Write-Host '  You need admin access to:'
Write-Host '    portal.pax8.com    portal.azure.com    github.com'
Write-Host ''
Write-Host '  Estimated time: 20 minutes. Safe to re-run if interrupted.'
Write-Host ''
Read-Host '  Press Enter to start' | Out-Null

# ==============================================================
# 1. PAX8 API CREDENTIAL
# ==============================================================
Title '1 / 4  —  Pax8 API Credential'

$pax8OK = $false
if ($pax8Id -and $pax8Sec) {
    try {
        Connect-Pax8 -ClientId $pax8Id -ClientSecret $pax8Sec `
            -TokenUrl $settings.pax8.tokenUrl -BaseUrl $settings.pax8.baseUrl -Audience $settings.pax8.audience
        $pax8OK = $true
        Done 'Pax8 already connected — skipping'
    } catch { }
}

if (-not $pax8OK) {
    Step 'In Pax8 portal, go to:'
    Url  'https://portal.pax8.com'
    Step 'Your name (top right) > Settings > Integrations > API Credentials > Create API Credential'
    Step 'Name it anything. Copy the Client ID and Client Secret.'
    Write-Host ''

    while (-not $pax8OK) {
        $pax8Id  = (Read-Host '  Client ID').Trim()
        $pax8Sec = (Read-Host '  Client Secret').Trim()
        try {
            Connect-Pax8 -ClientId $pax8Id -ClientSecret $pax8Sec `
                -TokenUrl $settings.pax8.tokenUrl -BaseUrl $settings.pax8.baseUrl -Audience $settings.pax8.audience
            $pax8OK = $true
            Done 'Connected to Pax8'
        } catch {
            Fail "Connection failed: $($_.Exception.Message)"
            Write-Host '  Try again.' -ForegroundColor Yellow
        }
    }
}

# ==============================================================
# 2. ENTRA ID APP REGISTRATION
# ==============================================================
Title '2 / 4  —  Microsoft Entra App Registration'

$graphOK = $false
if ($graphId -and $graphSec -and ($graphId -match '^[0-9a-f-]{36}$')) {
    $graphOK = $true
    Done 'Graph credentials already on file — skipping'
}

if (-not $graphOK) {
    Step 'Go to Azure portal > App registrations > New registration:'
    Url  'https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/CreateApplicationBlade'
    Write-Host ''
    Step '  Name:              Pax8 License Automation'
    Step '  Supported types:   Accounts in any organizational directory (Multitenant)'
    Step '  Redirect URI:      leave blank'
    Step '  Click Register'
    Write-Host ''
    Step 'API permissions > Add a permission > Microsoft Graph > Application permissions:'
    Step '  Organization.Read.All    Directory.Read.All    Mail.Send'
    Step 'Then click Grant admin consent.'
    Write-Host ''
    Step 'Certificates & secrets > New client secret > set expiry to 24 months > Add.'
    Step 'Copy the secret VALUE (not the ID). You only see it once.'
    Write-Host ''

    while (-not $graphOK) {
        $graphId  = (Read-Host '  Application (client) ID').Trim()
        $graphSec = (Read-Host '  Client Secret Value').Trim()
        if ($graphId -match '^[0-9a-f-]{36}$' -and $graphSec.Length -gt 10) {
            $graphOK = $true
            Done 'Credentials accepted'
        } else {
            Fail 'App ID must be a GUID. Secret must be at least 10 characters. Try again.'
        }
    }
}

# Save credentials locally
$credObj = [pscustomobject]@{
    Pax8ClientId      = $pax8Id
    Pax8ClientSecret  = ConvertTo-SecureString $pax8Sec  -AsPlainText -Force
    GraphClientId     = $graphId
    GraphClientSecret = ConvertTo-SecureString $graphSec -AsPlainText -Force
}
$credObj | Export-Clixml (Join-Path $scriptRoot 'config\credentials.local.xml') -Force
Done 'Credentials saved to local encrypted store'

# ==============================================================
# 3. GITHUB PAT
# ==============================================================
Title '3 / 4  —  GitHub Read Token'

Step 'Go to GitHub > Settings > Developer settings > Personal access tokens > Fine-grained tokens'
Url  'https://github.com/settings/personal-access-tokens'
Write-Host ''
Step '  Token name:         Pax8-Automation-Runbook'
Step '  Resource owner:     netBitSystems'
Step '  Repository access:  Only Pax8-License-Automation-Microsoft'
Step '  Contents permission: Read-only    (everything else: No access)'
Write-Host ''

$githubPat = ''
while ($githubPat.Length -lt 10) {
    $githubPat = (Read-Host '  Paste token').Trim()
    if ($githubPat.Length -lt 10) { Fail 'Too short — paste the full token.' }
}
Done 'Token received'

# ==============================================================
# 4. AZURE AUTOMATION
# ==============================================================
Title '4 / 4  —  Azure Automation'

# --- 4a. Account + modules ---
Write-Host '  Step A: Create the Automation account and import modules' -ForegroundColor White
Write-Host ''
Step 'Azure portal > Automation Accounts > Create'
Url  'https://portal.azure.com/#create/Microsoft.AutomationAccount'
Write-Host ''
Step '  Name: Pax8LicenseAutomation    Runtime: PowerShell 7.2'
Step '  Create it, then once it opens go to Shared Resources > Modules.'
Step '  Add module from gallery (runtime 7.2) for each of these — wait for both to show Available:'
Step '    Microsoft.Graph.Authentication'
Step '    Microsoft.Graph.Identity.DirectoryManagement'
Write-Host ''
Read-Host '  Press Enter once both modules show Available' | Out-Null

# --- 4b. Variables ---
Write-Host ''
Write-Host '  Step B: Create Automation Variables' -ForegroundColor White
Write-Host '  Shared Resources > Variables > Add a variable (Type = String)' -ForegroundColor DarkGray
Write-Host '  Variables marked [ENC] must have Encrypted toggled ON.' -ForegroundColor DarkGray
Write-Host ''

$vars = @(
    [pscustomobject]@{ Name='GitHubOwnerRepo';   Value='netBitSystems/Pax8-License-Automation-Microsoft'; E=$false },
    [pscustomobject]@{ Name='GitHubBranch';      Value='main';              E=$false },
    [pscustomobject]@{ Name='GitHubPat';         Value=$githubPat;          E=$true  },
    [pscustomobject]@{ Name='Pax8ClientId';      Value=$pax8Id;             E=$true  },
    [pscustomobject]@{ Name='Pax8ClientSecret';  Value=$pax8Sec;            E=$true  },
    [pscustomobject]@{ Name='GraphClientId';     Value=$graphId;            E=$true  },
    [pscustomobject]@{ Name='GraphClientSecret'; Value=$graphSec;           E=$true  },
    [pscustomobject]@{ Name='RunMode';           Value='Both';              E=$false },
    [pscustomobject]@{ Name='RunExecute';        Value='false';             E=$false },
    [pscustomobject]@{ Name='RunMockExecute';    Value='true';              E=$false }
)
foreach ($v in $vars) {
    $tag   = if ($v.E) { '[ENC]' } else { '     ' }
    $color = if ($v.E) { 'Yellow' } else { 'Gray' }
    Write-Host ("  $tag  {0,-24} {1}" -f $v.Name, $v.Value) -ForegroundColor $color
}
Write-Host ''
Read-Host '  Press Enter once all 10 variables are created' | Out-Null

# --- 4c. Runbook ---
Write-Host ''
Write-Host '  Step C: Create the runbook' -ForegroundColor White
Write-Host ''
Step 'Process Automation > Runbooks > Create a runbook'
Step '  Name: Start-Pax8LicenseSync    Type: PowerShell    Runtime: 7.2'
Step 'Once the editor opens, open this file in Notepad and paste the contents:'
Url  "$scriptRoot\Start-Pax8LicenseSync.ps1"
Step 'Save, then Publish.'
Write-Host ''
Read-Host '  Press Enter once the runbook is published' | Out-Null

# --- 4d. Schedule ---
Write-Host ''
Write-Host '  Step D: Schedule daily runs' -ForegroundColor White
Write-Host ''
Step 'Schedules > Add a schedule'
Step '  Name: DailyLicenseSync    Recurring: every 1 Day    No expiration'
Step 'Then: Runbooks > Start-Pax8LicenseSync > Schedules > Add a schedule > link DailyLicenseSync'
Write-Host ''
Read-Host '  Press Enter once the schedule is linked' | Out-Null

# ==============================================================
# Done
# ==============================================================
Title 'Setup complete'

Write-Host '  Next steps:'
Write-Host ''
Write-Host '  1. Add a client           → option [2] in the menu'
Write-Host "  2. Local dry-run test     → option [3] in the menu"
Write-Host '  3. Mock test in Azure     → Runbooks > Start-Pax8LicenseSync > Start'
Write-Host '     (watch Output, confirm the email arrives at services@netbitsystemsllc.com)'
Write-Host '  4. Go live                → see AZURE-DEPLOYMENT-SOP.md'
Write-Host ''

$next = Read-Host '  Add first client now? (Y/n)'
if ($next -notmatch '^[Nn]') {
    & pwsh -ExecutionPolicy Bypass -NoProfile -File (Join-Path $scriptRoot 'New-TenantConfig.ps1')
}
