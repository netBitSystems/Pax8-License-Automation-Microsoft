<#
.SYNOPSIS
  Create a new tenant config file for Pax8 License Automation.
.DESCRIPTION
  Prompts for client name, tenant ID, domain, and Pax8 company name.
  Connects to Pax8 live so you can search and pick the real product for each license.
  Writes the finished JSON to config\tenants\<key>.json.
  Run with: pwsh D:\Pax8LicenseAutomation\New-TenantConfig.ps1
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot

Import-Module (Join-Path $scriptRoot 'src\Logging.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Pax8.psm1')    -Force

$settings    = Get-Content (Join-Path $scriptRoot 'config\settings.json')    -Raw | ConvertFrom-Json
$catalogData = Get-Content (Join-Path $scriptRoot 'config\sku-catalog.json') -Raw | ConvertFrom-Json
$catalog     = $catalogData.licenses

Initialize-LogContext -Directory (Join-Path $env:TEMP 'Pax8LicenseWizard') -TenantKey 'wizard' | Out-Null

# ---------- Load credentials ----------
function _Plain([System.Security.SecureString]$s) {
    if ($s) { [System.Net.NetworkCredential]::new('', $s).Password }
}
$pax8ClientId = $env:PAX8_CLIENT_ID
$pax8Secret   = $env:PAX8_CLIENT_SECRET
if (-not $pax8ClientId) {
    try {
        $local = Import-Clixml (Join-Path $scriptRoot 'config\credentials.local.xml')
        $pax8ClientId = $local.Pax8ClientId
        $pax8Secret   = _Plain $local.Pax8ClientSecret
    } catch { }
}
if (-not $pax8ClientId) {
    $pax8ClientId = Read-Host 'Pax8 Client ID'
    $pax8Secret   = Read-Host 'Pax8 Client Secret'
}

# ---------- Connect to Pax8 ----------
Write-Host "`nConnecting to Pax8..." -ForegroundColor Cyan
Connect-Pax8 -ClientId $pax8ClientId -ClientSecret $pax8Secret `
    -TokenUrl $settings.pax8.tokenUrl -BaseUrl $settings.pax8.baseUrl -Audience $settings.pax8.audience

Write-Host "Loading Pax8 product catalog (takes ~15 seconds the first time)..." -ForegroundColor Cyan
$null = Get-Pax8Products
Write-Host "Ready.`n" -ForegroundColor Green

# ---------- Client basics ----------
Write-Host "============================================================" -ForegroundColor Blue
Write-Host " STEP 1 OF 3 - CLIENT DETAILS" -ForegroundColor Blue
Write-Host "============================================================`n" -ForegroundColor Blue

$displayName = Read-Host "Client company name"
$tenantId    = Read-Host "Microsoft Tenant ID  (Azure portal > Entra ID > Overview)"
$domain      = Read-Host "Default domain       (e.g. acmecorp.com)"
$pax8Company = Read-Host "Pax8 company name    (as shown in Pax8)"

$tenantKey = ($displayName -replace '[^a-zA-Z0-9]', '').ToLower()
if ($tenantKey.Length -gt 20) { $tenantKey = $tenantKey.Substring(0, 20) }

$gf = Read-Host "Greenfield? No existing Microsoft subscriptions (y/N)"
$greenfield = $gf -match '^[Yy]'

Write-Host "`nTenant key : $tenantKey" -ForegroundColor DarkGray
Write-Host "MS contact : netbit@$domain (pre-filled)`n" -ForegroundColor DarkGray

# ---------- License selection ----------
Write-Host "============================================================" -ForegroundColor Blue
Write-Host " STEP 2 OF 3 - LICENSE SELECTION" -ForegroundColor Blue
Write-Host "============================================================" -ForegroundColor Blue
Write-Host "Type Y to include a license, or press Enter to skip.`n"

$selectedSkus = @()
$currentCategory = ''
foreach ($entry in $catalog) {
    if ($entry.category -ne $currentCategory) {
        $currentCategory = $entry.category
        Write-Host "`n  [ $currentCategory ]" -ForegroundColor Yellow
    }
    $ans = Read-Host "    $($entry.displayName)? (y/N)"
    if ($ans -match '^[Yy]') { $selectedSkus += $entry }
}

if ($selectedSkus.Count -eq 0) {
    Write-Host "`nNo licenses selected. Exiting." -ForegroundColor Red
    exit 0
}
Write-Host "`n$($selectedSkus.Count) license(s) selected.`n" -ForegroundColor Green

# ---------- Pax8 product matching ----------
Write-Host "============================================================" -ForegroundColor Blue
Write-Host " STEP 3 OF 3 - PAX8 PRODUCT MATCHING" -ForegroundColor Blue
Write-Host "============================================================" -ForegroundColor Blue
Write-Host "Search the live Pax8 catalog and pick the correct product for each license.`n"

$skuMap = @()
foreach ($entry in $selectedSkus) {
    Write-Host "`n--- $($entry.displayName) ---" -ForegroundColor Cyan

    $selectedProduct = $null
    while (-not $selectedProduct) {
        $searchTerm = Read-Host "  Search term (Enter = use '$($entry.displayName)')"
        if (-not $searchTerm.Trim()) { $searchTerm = $entry.displayName }

        $results = @(Search-Pax8Products -SearchTerm $searchTerm)
        if ($results.Count -eq 0) {
            Write-Host "  No results. Try a shorter search term." -ForegroundColor Red
            continue
        }

        Write-Host ""
        $limit = [Math]::Min($results.Count, 15)
        for ($i = 0; $i -lt $limit; $i++) {
            Write-Host "  [$($i+1)] $($results[$i].name)"
        }
        Write-Host "  [0] Search again"

        $pick = Read-Host "`n  Select number"
        $n = 0
        if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $results.Count) {
            $selectedProduct = $results[$n - 1]
            Write-Host "  OK: $($selectedProduct.name)" -ForegroundColor Green
        }
    }

    $b = Read-Host "  Buffer seats (spare to keep available, default $($entry.defaultBuffer))"
    $m = Read-Host "  Max seats cap (default $($entry.defaultMaxSeats))"
    $buffer   = if ($b -match '^\d+$') { [int]$b } else { $entry.defaultBuffer }
    $maxSeats = if ($m -match '^\d+$') { [int]$m } else { $entry.defaultMaxSeats }

    $skuMap += [ordered]@{
        skuPartNumber       = $entry.skuPartNumber
        skuId               = $entry.skuId
        displayName         = $entry.displayName
        pax8ProductId       = $selectedProduct.id
        pax8ProductNameHint = $selectedProduct.name
        buffer              = $buffer
        maxSeats            = $maxSeats
    }
}

# ---------- Write config ----------
$config = [ordered]@{
    tenantKey     = $tenantKey
    displayName   = $displayName
    msTenantId    = $tenantId
    defaultDomain = $domain
    greenfield    = $greenfield
    pax8CompanyId       = ''
    pax8CompanyNameHint = $pax8Company
    microsoftProvisioning = [ordered]@{
        mca2020FirstName     = 'Adam'
        mca2020LastName      = 'Burnaman'
        mca2020Email         = 'services@netbitsystemsllc.com'
        mca2020EffectiveDate = '2023-06-19'
        msftContactFirstName = 'Dylan'
        msftContactLastName  = 'Rumsey'
        msftContactEmail     = "netbit@$domain"
    }
    skuMap = $skuMap
    ignoreSkuPartNumbers = @(
        'DYN365_AI_SERVICE_INSIGHTS','FLOW_FREE','POWER_BI_STANDARD',
        'CCIBOTS_PRIVPREV_VIRAL','POWERAPPS_DEV','POWERAPPS_VIRAL',
        'WINDOWS_STORE','TEAMS_EXPLORATORY','Microsoft_Teams_Rooms_Basic',
        'Microsoft_Teams_Audio_Conferencing_select_dial_out',
        'Teams_Premium_(for_Departments)'
    )
}

$outPath = Join-Path $scriptRoot "config\tenants\$tenantKey.json"
$config | ConvertTo-Json -Depth 10 | Set-Content -Path $outPath -Encoding UTF8

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " DONE - Saved to: $outPath" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Next steps:"
Write-Host "  1. pwsh $scriptRoot\Test-Local.ps1   (verify the plan)"
Write-Host "  2. git commit + push to GitHub"
Write-Host ""
