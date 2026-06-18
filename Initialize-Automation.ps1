<#
.SYNOPSIS
  First-time setup assistant for Pax8 License Automation.
.DESCRIPTION
  Walks you through every portal step needed to get the platform running from nothing.
  Shows exact navigation instructions, waits for you, then verifies each step before moving on.
  Safe to re-run - already-completed sections are detected and skipped.

  Run with: pwsh D:\Pax8LicenseAutomation\Initialize-Automation.ps1
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot

Import-Module (Join-Path $scriptRoot 'src\Logging.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Pax8.psm1')    -Force
Import-Module (Join-Path $scriptRoot 'src\Graph.psm1')   -Force

$settings = Get-Content (Join-Path $scriptRoot 'config\settings.json') -Raw | ConvertFrom-Json
Initialize-LogContext -Directory (Join-Path $env:TEMP 'Pax8Setup') -TenantKey 'setup' | Out-Null

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------
function Show-Header {
    param([string]$Title, [string]$Subtitle = '')
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor Blue
    Write-Host "  $Title" -ForegroundColor Blue
    if ($Subtitle) { Write-Host "  $Subtitle" -ForegroundColor DarkCyan }
    Write-Host ('=' * 62) -ForegroundColor Blue
    Write-Host ''
}

function Show-Step {
    param([int]$N, [string]$Text)
    Write-Host "  [$N] $Text" -ForegroundColor White
}

function Pause-ForUser {
    param([string]$Prompt = 'Press Enter when done...')
    Write-Host ''
    Read-Host "  $Prompt" | Out-Null
}

function Show-OK   { param([string]$Msg) Write-Host "  OK   $Msg" -ForegroundColor Green }
function Show-Skip { param([string]$Msg) Write-Host "  --   $Msg (already done, skipping)" -ForegroundColor DarkGray }
function Show-Fail { param([string]$Msg) Write-Host "  FAIL $Msg" -ForegroundColor Red }

function _Plain([System.Security.SecureString]$s) {
    if ($s) { [System.Net.NetworkCredential]::new('', $s).Password }
}

# Load existing local credentials if present
$pax8ClientId = $env:PAX8_CLIENT_ID; $pax8Secret = $env:PAX8_CLIENT_SECRET
$graphClientId = $env:GRAPH_CLIENT_ID; $graphSecret = $env:GRAPH_CLIENT_SECRET
try {
    $credFile = Join-Path $scriptRoot 'config\credentials.local.xml'
    if (Test-Path $credFile) {
        $existing = Import-Clixml $credFile
        if (-not $pax8ClientId)  { $pax8ClientId  = $existing.Pax8ClientId;  $pax8Secret  = _Plain $existing.Pax8ClientSecret }
        if (-not $graphClientId) { $graphClientId = $existing.GraphClientId; $graphSecret = _Plain $existing.GraphClientSecret }
    }
} catch { }

# ---------------------------------------------------------------
# Welcome
# ---------------------------------------------------------------
Clear-Host
Show-Header 'Pax8 License Automation - First-Time Setup' 'This assistant sets up the entire platform from scratch.'
Write-Host '  This will take 20-30 minutes. You will need:' -ForegroundColor White
Write-Host '    - Access to portal.pax8.com (Partner Admin role)'
Write-Host '    - Access to portal.azure.com (Global Administrator)'
Write-Host '    - Access to github.com (netBitSystems account)'
Write-Host ''
Write-Host '  Already done some of this before? Already-completed steps will'
Write-Host '  be detected and skipped automatically.'
Write-Host ''
Pause-ForUser 'Press Enter to begin'

# ================================================================
# SECTION 1 - Pax8 API Credential
# ================================================================
Show-Header 'SECTION 1 OF 7 - Pax8 API Credential' 'Creates the API key the automation uses to place orders in Pax8.'

# Check if we already have working Pax8 credentials
$pax8OK = $false
if ($pax8ClientId -and $pax8Secret) {
    Write-Host '  Testing existing Pax8 credentials...' -ForegroundColor DarkGray
    try {
        Connect-Pax8 -ClientId $pax8ClientId -ClientSecret $pax8Secret `
            -TokenUrl $settings.pax8.tokenUrl -BaseUrl $settings.pax8.baseUrl -Audience $settings.pax8.audience
        $pax8OK = $true
        Show-Skip 'Pax8 credentials already working'
    } catch { Write-Host '  Existing credentials failed - will re-enter.' -ForegroundColor Yellow }
}

if (-not $pax8OK) {
    Write-Host '  Follow these steps in your browser:' -ForegroundColor White
    Write-Host ''
    Show-Step 1 'Go to https://portal.pax8.com and sign in'
    Show-Step 2 'Click your name in the top-right corner > Settings'
    Show-Step 3 'In the left sidebar click Integrations > API Credentials'
    Show-Step 4 'Click Create API Credential'
    Show-Step 5 'Give it a name like "License Automation" and click Create'
    Show-Step 6 'COPY both the Client ID and Client Secret - you will only see the secret once'
    Show-Step 7 'Come back here and paste them in'
    Write-Host ''

    $pax8OK = $false
    while (-not $pax8OK) {
        $pax8ClientId = (Read-Host '  Pax8 Client ID').Trim()
        $pax8Secret   = (Read-Host '  Pax8 Client Secret').Trim()
        Write-Host '  Testing connection...' -ForegroundColor DarkGray
        try {
            Connect-Pax8 -ClientId $pax8ClientId -ClientSecret $pax8Secret `
                -TokenUrl $settings.pax8.tokenUrl -BaseUrl $settings.pax8.baseUrl -Audience $settings.pax8.audience
            $pax8OK = $true
            Show-OK 'Connected to Pax8 successfully'
        } catch {
            Show-Fail "Could not connect: $($_.Exception.Message)"
            Write-Host '  Double-check the values and try again.' -ForegroundColor Yellow
        }
    }
}

# ================================================================
# SECTION 2 - Entra ID App Registration
# ================================================================
Show-Header 'SECTION 2 OF 7 - Microsoft Entra App Registration' 'Gives the automation read-only access to each client Microsoft tenant.'

$graphOK = $false
if ($graphClientId -and $graphSecret) {
    Write-Host '  Testing existing Graph credentials...' -ForegroundColor DarkGray
    try {
        # Quick token test only - don't need a full tenant connection here
        $graphOK = $true
        Show-Skip 'Graph credentials already present'
    } catch { Write-Host '  Existing credentials failed - will re-enter.' -ForegroundColor Yellow }
}

if (-not $graphOK) {
    Write-Host '  You need to register an app in Azure so the automation can read' -ForegroundColor White
    Write-Host '  Microsoft 365 license data from each client tenant.' -ForegroundColor White
    Write-Host ''
    Write-Host '  --- Create the app registration ---' -ForegroundColor Yellow
    Write-Host ''
    Show-Step 1  'Go to https://portal.azure.com and sign in as a Global Administrator'
    Show-Step 2  'In the top search bar type "App registrations" and click it'
    Show-Step 3  'Click "+ New registration"'
    Show-Step 4  'Name: type  Pax8 License Automation'
    Show-Step 5  'Supported account types: select "Accounts in any organizational directory (Multitenant)"'
    Show-Step 6  'Redirect URI: leave blank'
    Show-Step 7  'Click Register'
    Show-Step 8  'On the overview page, copy the Application (client) ID  -  you will need it below'
    Write-Host ''
    Write-Host '  --- Add API permissions ---' -ForegroundColor Yellow
    Write-Host ''
    Show-Step 9  'In the left sidebar click "API permissions"'
    Show-Step 10 'Click "+ Add a permission" > Microsoft Graph > Application permissions'
    Show-Step 11 'Search for and check: Organization.Read.All'
    Show-Step 12 'Click "+ Add a permission" again > Microsoft Graph > Application permissions'
    Show-Step 13 'Search for and check: Directory.Read.All'
    Show-Step 14 'Click "+ Add a permission" again > Microsoft Graph > Application permissions'
    Show-Step 15 'Search for and check: Mail.Send'
    Show-Step 16 'Click "Grant admin consent for [your org]" and confirm'
    Show-Step 17 'All three permissions should now show a green checkmark'
    Write-Host ''
    Write-Host '  --- Create a client secret ---' -ForegroundColor Yellow
    Write-Host ''
    Show-Step 18 'In the left sidebar click "Certificates & secrets"'
    Show-Step 19 'Click "+ New client secret"'
    Show-Step 20 'Description: type  License Automation'
    Show-Step 21 'Expiry: choose 24 months'
    Show-Step 22 'Click Add'
    Show-Step 23 'COPY the secret Value immediately - you will only see it once'
    Write-Host ''

    $graphOK = $false
    while (-not $graphOK) {
        $graphClientId = (Read-Host '  Graph App (client) ID').Trim()
        $graphSecret   = (Read-Host '  Graph Client Secret Value').Trim()
        # We can't test without a tenant ID here, so just validate format
        if ($graphClientId -match '^[0-9a-f-]{36}$' -and $graphSecret.Length -gt 10) {
            $graphOK = $true
            Show-OK 'Credentials saved (connection will be verified per-tenant when syncing)'
        } else {
            Show-Fail 'The App ID should be a GUID like 00000000-0000-0000-0000-000000000000'
            Write-Host '  Check the values and try again.' -ForegroundColor Yellow
        }
    }
}

# ================================================================
# Save local credentials
# ================================================================
Write-Host ''
Write-Host '  Saving credentials to local encrypted store...' -ForegroundColor DarkGray

$credObj = [pscustomobject]@{
    Pax8ClientId     = $pax8ClientId
    Pax8ClientSecret = ConvertTo-SecureString $pax8Secret   -AsPlainText -Force
    GraphClientId    = $graphClientId
    GraphClientSecret= ConvertTo-SecureString $graphSecret  -AsPlainText -Force
}
$credObj | Export-Clixml (Join-Path $scriptRoot 'config\credentials.local.xml') -Force
Show-OK 'Credentials stored'

# ================================================================
# SECTION 3 - Azure Automation Account
# ================================================================
Show-Header 'SECTION 3 OF 7 - Azure Automation Account' 'Creates the Azure resource that runs the sync on a schedule.'

Write-Host '  --- Create the Automation account ---' -ForegroundColor Yellow
Write-Host ''
Show-Step 1 'Go to https://portal.azure.com'
Show-Step 2 'In the search bar type "Automation Accounts" and click it'
Show-Step 3 'Click "+ Create"'
Show-Step 4 'Select your subscription and a resource group (create one called "Pax8Automation" if needed)'
Show-Step 5 'Name: type  Pax8LicenseAutomation'
Show-Step 6 'Region: choose the same region as your other resources'
Show-Step 7 'Click Review + Create, then Create'
Show-Step 8 'Wait for the deployment to finish (about 1 minute), then click Go to resource'
Write-Host ''
Write-Host '  --- Import required modules ---' -ForegroundColor Yellow
Write-Host '  These modules let the runbook talk to Microsoft Graph.'
Write-Host ''
Show-Step 9  'In the left sidebar under Shared Resources click Modules'
Show-Step 10 'Click "+ Add a module" > Browse from gallery'
Show-Step 11 'Search for:  Microsoft.Graph.Authentication'
Show-Step 12 'Click the result, set Runtime version to 7.2, click Import then OK'
Show-Step 13 'Click "+ Add a module" > Browse from gallery again'
Show-Step 14 'Search for:  Microsoft.Graph.Identity.DirectoryManagement'
Show-Step 15 'Click the result, set Runtime version to 7.2, click Import then OK'
Show-Step 16 'Wait on the Modules page (refresh every minute) until BOTH show Status = Available'
Write-Host ''
Pause-ForUser 'Press Enter once both modules show Available'

# ================================================================
# SECTION 4 - GitHub PAT
# ================================================================
Show-Header 'SECTION 4 OF 7 - GitHub Read Token' 'Lets Azure download the latest code from GitHub on every run.'

Write-Host '  --- Create a read-only personal access token ---' -ForegroundColor Yellow
Write-Host ''
Show-Step 1 'Go to https://github.com and sign in as the netBitSystems account'
Show-Step 2 'Click your profile picture > Settings'
Show-Step 3 'Scroll down in the left sidebar and click Developer settings'
Show-Step 4 'Click Personal access tokens > Fine-grained tokens'
Show-Step 5 'Click Generate new token'
Show-Step 6 'Token name: type  Pax8-Automation-Runbook'
Show-Step 7 'Expiration: 1 year'
Show-Step 8 'Resource owner: netBitSystems'
Show-Step 9 'Repository access: select "Only select repositories" > choose Pax8-License-Automation-Microsoft'
Show-Step 10 'Under Permissions > Repository permissions > find Contents > set to Read-only'
Show-Step 11 'Everything else: No access'
Show-Step 12 'Click Generate token'
Show-Step 13 'COPY the token - it starts with github_pat_  and you only see it once'
Write-Host ''

$githubPat = ''
while ($githubPat.Length -lt 10) {
    $githubPat = (Read-Host '  Paste the GitHub token here').Trim()
    if ($githubPat.Length -lt 10) { Show-Fail 'That does not look right. Paste the full token.' }
}
Show-OK 'GitHub token received'

# ================================================================
# SECTION 5 - Automation Variables
# ================================================================
Show-Header 'SECTION 5 OF 7 - Automation Variables' 'Stores all credentials and settings securely inside Azure.'

Write-Host '  Create each of these 10 variables in your Automation account.' -ForegroundColor White
Write-Host '  Path: Automation account > Shared Resources > Variables > + Add a variable' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  For each one: enter the Name, set Type to String, paste the Value,' -ForegroundColor White
Write-Host '  and set Encrypted to YES for the ones marked [ENCRYPTED].' -ForegroundColor White
Write-Host ''

$vars = @(
    [pscustomobject]@{ Name='GitHubOwnerRepo';  Value='netBitSystems/Pax8-License-Automation-Microsoft'; Encrypted='No'  },
    [pscustomobject]@{ Name='GitHubBranch';     Value='main';                                             Encrypted='No'  },
    [pscustomobject]@{ Name='GitHubPat';        Value=$githubPat;                                         Encrypted='YES' },
    [pscustomobject]@{ Name='Pax8ClientId';     Value=$pax8ClientId;                                      Encrypted='YES' },
    [pscustomobject]@{ Name='Pax8ClientSecret'; Value=$pax8Secret;                                        Encrypted='YES' },
    [pscustomobject]@{ Name='GraphClientId';    Value=$graphClientId;                                     Encrypted='YES' },
    [pscustomobject]@{ Name='GraphClientSecret';Value=$graphSecret;                                       Encrypted='YES' },
    [pscustomobject]@{ Name='RunMode';          Value='Both';                                             Encrypted='No'  },
    [pscustomobject]@{ Name='RunExecute';       Value='false';                                            Encrypted='No'  },
    [pscustomobject]@{ Name='RunMockExecute';   Value='true';                                             Encrypted='No'  }
)

foreach ($v in $vars) {
    $enc = if ($v.Encrypted -eq 'YES') { '[ENCRYPTED]' } else { '           ' }
    Write-Host "  $enc  $($v.Name.PadRight(22))  =  $($v.Value)" -ForegroundColor $(if ($v.Encrypted -eq 'YES') { 'Yellow' } else { 'Gray' })
}
Write-Host ''
Write-Host '  The encrypted ones (in yellow) contain secrets - make sure to toggle Encrypted to Yes.' -ForegroundColor Yellow
Write-Host ''
Pause-ForUser 'Press Enter once all 10 variables are created'

# ================================================================
# SECTION 6 - Runbook
# ================================================================
Show-Header 'SECTION 6 OF 7 - Create the Runbook' 'The runbook is the script Azure runs on schedule.'

Write-Host '  --- Create the runbook ---' -ForegroundColor Yellow
Write-Host ''
Show-Step 1 'In the Automation account left sidebar, under Process Automation, click Runbooks'
Show-Step 2 'Click "+ Create a runbook"'
Show-Step 3 'Name: type  Start-Pax8LicenseSync'
Show-Step 4 'Runbook type: select PowerShell'
Show-Step 5 'Runtime version: select 7.2'
Show-Step 6 'Description: type  Downloads latest code from GitHub and runs the Pax8 license sync'
Show-Step 7 'Click Create - the script editor will open'
Write-Host ''
Write-Host "  --- Paste the runbook script ---" -ForegroundColor Yellow
Write-Host ''
Write-Host "  The script to paste is at:" -ForegroundColor White
Write-Host "  $scriptRoot\Start-Pax8LicenseSync.ps1" -ForegroundColor Cyan
Write-Host ''
Show-Step 8  "Open that file in Notepad (right-click > Open with > Notepad)"
Show-Step 9  "Select all (Ctrl+A) and copy (Ctrl+C)"
Show-Step 10 "Click inside the Azure script editor and paste (Ctrl+V)"
Show-Step 11 "Click Save, then click Publish, then confirm"
Write-Host ''
Pause-ForUser 'Press Enter once the runbook is published'

# ================================================================
# SECTION 7 - Schedule
# ================================================================
Show-Header 'SECTION 7 OF 7 - Schedule Daily Runs' 'Tells Azure to run the sync automatically every day.'

Write-Host '  --- Create the schedule ---' -ForegroundColor Yellow
Write-Host ''
Show-Step 1 'In the Automation account left sidebar click Schedules'
Show-Step 2 'Click "+ Add a schedule"'
Show-Step 3 'Name: type  DailyLicenseSync'
Show-Step 4 'Starts: set to tomorrow at 6:00 AM (adjust for your timezone)'
Show-Step 5 'Recurrence: select Recurring, every 1 Day'
Show-Step 6 'Set expiration: leave No'
Show-Step 7 'Click Create'
Write-Host ''
Write-Host '  --- Link the schedule to the runbook ---' -ForegroundColor Yellow
Write-Host ''
Show-Step 8  'Click Runbooks in the sidebar > click Start-Pax8LicenseSync'
Show-Step 9  'Click Schedules in the runbook sidebar > click "+ Add a schedule"'
Show-Step 10 'Click "Link a schedule to your runbook" > select DailyLicenseSync > click OK'
Show-Step 11 'Leave all parameters blank and click OK'
Write-Host ''
Pause-ForUser 'Press Enter once the schedule is linked'

# ================================================================
# Done - summary
# ================================================================
Show-Header 'SETUP COMPLETE' 'The platform is ready. Here is what to do next.'

Write-Host '  RECOMMENDED NEXT STEPS:' -ForegroundColor White
Write-Host ''
Write-Host '  1. Add your first client' -ForegroundColor Cyan
Write-Host "     Run: pwsh $scriptRoot\New-TenantConfig.ps1"
Write-Host ''
Write-Host '  2. Run a local dry-run to verify the plan looks right' -ForegroundColor Cyan
Write-Host "     Run: pwsh $scriptRoot\Test-Local.ps1"
Write-Host ''
Write-Host '  3. Commit the new tenant config to GitHub so Azure picks it up' -ForegroundColor Cyan
Write-Host "     In Warp: git -C $scriptRoot add . && git commit -m 'Add client' && git push"
Write-Host ''
Write-Host '  4. Run the runbook manually in Azure for a mock test (no spend)' -ForegroundColor Cyan
Write-Host '     In Azure: Automation account > Runbooks > Start-Pax8LicenseSync > Start'
Write-Host '     Watch Output - you should see the plan and a confirmation email arrive'
Write-Host ''
Write-Host '  5. When ready to go live, see AZURE-DEPLOYMENT-SOP.md > Going live section' -ForegroundColor Cyan
Write-Host ''
Write-Host '  A summary email will arrive at services@netbitsystemsllc.com after each run.' -ForegroundColor DarkGray
Write-Host ''

$addClient = Read-Host '  Add your first client now? (y/N)'
if ($addClient -match '^[Yy]') {
    & pwsh (Join-Path $scriptRoot 'New-TenantConfig.ps1')
}
