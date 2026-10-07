<#
.SYNOPSIS
  Pax8 license sync entry point. Runs the overhead/top-up/transition plan for one or all tenants.
.DESCRIPTION
  Dry-run by default. Real Pax8 orders require settings.dryRun=false AND -Execute AND
  (requireApproval=false). Microsoft Graph access is read-only. Works locally (device code) or
  in Azure Automation (managed identity). Pax8 credentials come from environment variables
  (PAX8_CLIENT_ID / PAX8_CLIENT_SECRET) or Automation variables (Pax8ClientId / Pax8ClientSecret).
#>
[CmdletBinding()]
param(
    [string]$ConfigRoot = (Join-Path $PSScriptRoot 'config'),
    [string]$TenantKey,
    [ValidateSet('TopUp','Transition','Both')][string]$Mode,
    [switch]$Execute,
    [switch]$MockExecute,
    [switch]$UseManagedIdentity,
    [switch]$UseDeviceCode
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\Logging.psm1')      -Force
Import-Module (Join-Path $PSScriptRoot 'src\Pax8.psm1')         -Force
Import-Module (Join-Path $PSScriptRoot 'src\Graph.psm1')        -Force
Import-Module (Join-Path $PSScriptRoot 'src\LicenseLogic.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\Notify.psm1')       -Force

$settings = Get-Content (Join-Path $ConfigRoot 'settings.json') -Raw | ConvertFrom-Json
if (-not $Mode) { $Mode = $settings.mode }
# MockExecute runs the full path live but forces isMock orders and bypasses the dry-run/approval gates.
$dryRun = if ($MockExecute) { $false } else { ([bool]$settings.dryRun) -or (-not $Execute) }

$tenantFiles =
    if ($TenantKey) { @(Join-Path $ConfigRoot ("tenants\{0}.json" -f $TenantKey)) }
    else { Get-ChildItem (Join-Path $ConfigRoot 'tenants') -Filter *.json | Select-Object -ExpandProperty FullName }

# --- Credentials: env var > local encrypted file (Set-Credentials.ps1) > Azure Automation variable ---
function _Plain([System.Security.SecureString]$s) { if ($s) { [System.Net.NetworkCredential]::new('', $s).Password } }
$credFile = Join-Path $ConfigRoot 'credentials.local.xml'
$local    = if (Test-Path $credFile) { Import-Clixml $credFile } else { $null }
$inAzure  = [bool](Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue)

$pax8ClientId = $env:PAX8_CLIENT_ID
$pax8Secret   = $env:PAX8_CLIENT_SECRET
if (-not $pax8ClientId -and $local)   { $pax8ClientId = $local.Pax8ClientId; $pax8Secret = _Plain $local.Pax8ClientSecret }
if (-not $pax8ClientId -and $inAzure) { $pax8ClientId = Get-AutomationVariable -Name 'Pax8ClientId'; $pax8Secret = Get-AutomationVariable -Name 'Pax8ClientSecret' }

$graphClientId  = if ($settings.graph.appClientId) { $settings.graph.appClientId } else { $env:GRAPH_CLIENT_ID }
$graphSecret    = $env:GRAPH_CLIENT_SECRET
$graphCertThumb = $settings.graph.certificateThumbprint
if (-not $graphClientId -and $local)   { $graphClientId = $local.GraphClientId; $graphSecret = _Plain $local.GraphClientSecret }
if (-not $graphClientId -and $inAzure) { $graphClientId = Get-AutomationVariable -Name 'GraphClientId'; try { $graphSecret = Get-AutomationVariable -Name 'GraphClientSecret' } catch { } }

foreach ($tf in $tenantFiles) {
    $tenant = Get-Content $tf -Raw | ConvertFrom-Json
    $logDir = $settings.logging.directory
    if ($logDir -and -not [System.IO.Path]::IsPathRooted($logDir)) { $logDir = Join-Path $PSScriptRoot $logDir }
    Initialize-LogContext -Directory $logDir -TenantKey $tenant.tenantKey | Out-Null
    Write-Log -Level INFO -Message ("=== {0} | mode {1} | dryRun {2} ===" -f $tenant.displayName, $Mode, $dryRun)

    $tid = $tenant.msTenantId
    try {
        if ($UseManagedIdentity) {
            Connect-GraphRead -UseManagedIdentity -ClientId $graphClientId | Out-Null
        } elseif ($graphClientId -and $graphCertThumb) {
            Connect-GraphRead -TenantId $tid -ClientId $graphClientId -CertificateThumbprint $graphCertThumb | Out-Null
        } elseif ($graphClientId -and $graphSecret) {
            Connect-GraphRead -TenantId $tid -ClientId $graphClientId -ClientSecret $graphSecret | Out-Null
        } elseif ($UseDeviceCode) {
            Connect-GraphRead -Scopes $settings.graph.scopes -UseDeviceCode | Out-Null
        } else {
            Connect-GraphRead -Scopes $settings.graph.scopes | Out-Null
        }
    } catch {
        Write-Log -Level ERROR -Message ("Graph auth failed for {0}. The app secret/cert likely expired or consent was removed. FIX: run Set-Credentials.ps1 (local) or update the GraphClientSecret Automation variable / Key Vault. See README 'Credentials and rotation'. Detail: {1}" -f $tenant.displayName, $_.Exception.Message)
        continue
    }

    if ($pax8ClientId) {
        try {
            Connect-Pax8 -ClientId $pax8ClientId -ClientSecret $pax8Secret -TokenUrl $settings.pax8.tokenUrl -BaseUrl $settings.pax8.baseUrl -Audience $settings.pax8.audience
        } catch {
            Write-Log -Level ERROR -Message ("Pax8 auth failed. The Pax8 client secret likely expired or is wrong. FIX: run Set-Credentials.ps1 (local) or update the Pax8ClientSecret Automation variable / Key Vault. See README 'Credentials and rotation'. Detail: {0}" -f $_.Exception.Message)
            $pax8ClientId = $null
        }
    } else {
        Write-Log -Level WARN -Message 'No Pax8 credentials found; producing read-only plan (Pax8 quantities treated as 0).'
    }

    $skuSummary = Get-TenantSkuSummary
    Write-Log -Level INFO -Message ("Graph returned {0} subscribed SKU(s)." -f @($skuSummary).Count) -Data @{ skus = @($skuSummary | ForEach-Object { @{ skuId = [string]$_.SkuId; skuPartNumber = [string]$_.SkuPartNumber; enabled = $_.Enabled; consumed = $_.Consumed } }) }
    $renewals   = Get-TenantSubscriptionRenewals

    $companyId = $tenant.pax8CompanyId
    $pax8Subs  = $null
    if ($pax8ClientId) {
        if (-not $companyId) {
            $co = Get-Pax8Company -NameHint $tenant.pax8CompanyNameHint
            if ($co) { $companyId = $co.id; Write-Log -Level INFO -Message ("Resolved Pax8 companyId {0}" -f $companyId) }
        }
        if ($companyId) { $pax8Subs = Get-Pax8Subscriptions -CompanyId $companyId }
    }

    $plan = New-LicensePlan -SkuSummary $skuSummary -TenantConfig $tenant -Settings $settings -Pax8Subscriptions $pax8Subs -Renewals $renewals
    $plan | Format-Table SkuPartNumber, Assigned, MsEnabled, Pax8Qty, Desired, DesiredPax8, Action, DeltaSeats, RenewDate -AutoSize | Out-String | Write-Output

    $err = 0
    # Real failure reasons (SKU, what was attempted, and what Pax8 said), shown in the alert email and job output.
    $failures   = [System.Collections.Generic.List[string]]::new()
    $failedSkus = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $plan) {
        Write-Log -Level DECISION -Message ("{0}: {1} ({2:+#;-#;0})" -f $p.SkuPartNumber, $p.Action, $p.DeltaSeats) -Data $p

        $doIt = $false
        if ($p.DeltaSeats -gt 0) {
            switch ($Mode) {
                'Both'       { $doIt = $p.Action -in 'topup','order' }
                'TopUp'      { $doIt = $p.Action -eq 'topup' }
                'Transition' { $doIt = $p.Action -eq 'order' }
            }
        } elseif ($p.DeltaSeats -lt 0 -and $p.Action -eq 'downsize') {
            # Downsizing only happens inside the renewal window; run it in Both and Transition, not TopUp.
            $doIt = $Mode -in 'Both','Transition'
        }
        if (-not $doIt) { continue }

        # Quantity the Pax8 subscription/order will hold after this run. Every action (topup, order,
        # downsize) drives the Pax8 quantity to DesiredPax8: the pool need minus what is already
        # covered off Pax8.
        $targetQty = $p.DesiredPax8

        if ($dryRun) {
            Write-Log -Level INFO -Message ("DRY-RUN: would {0} {1} by {2:+#;-#;0} to {3}" -f $p.Action, $p.SkuPartNumber, $p.DeltaSeats, $targetQty)
            continue
        }
        if ([bool]$settings.requireApproval -and -not $MockExecute) {
            Write-Log -Level WARN -Message ("APPROVAL REQUIRED: {0} {1} {2:+#;-#;0} not auto-executed" -f $p.Action, $p.SkuPartNumber, $p.DeltaSeats)
            continue
        }
        if (-not $pax8ClientId) {
            Write-Log -Level ERROR -Message 'Cannot execute without Pax8 credentials.'
            $err++
            $failedSkus.Add([string]$p.SkuPartNumber)
            $failures.Add(("{0}: {1} {2:+#;-#;0} NOT ATTEMPTED`n  Reason: no usable Pax8 credentials (Pax8 auth failed or the Pax8ClientId/Pax8ClientSecret variables are missing)." -f $p.SkuPartNumber, $p.Action, $p.DeltaSeats))
            continue
        }

        $useMock = $MockExecute -or [bool]$settings.pax8.useMockOrders
        try {
            if ($p.Action -in 'topup','downsize' -and $p.Pax8SubscriptionId) {
                $verb = if ($p.Action -eq 'downsize') { 'lower' } else { 'raise' }
                if ($MockExecute) {
                    Write-Log -Level INFO -Message ("MOCK-EXECUTE: would {0} {1} to {2} (no mock endpoint for quantity update; skipped)" -f $verb, $p.SkuPartNumber, $targetQty)
                } else {
                    Set-Pax8SubscriptionQuantity -SubscriptionId $p.Pax8SubscriptionId -Quantity $targetQty
                }
            } else {
                # Prefer the stored product ID from tenant config (set by the onboarding wizard).
                # Fall back to name-hint resolution for legacy configs.
                $prodId = if ($p.Pax8ProductId) { $p.Pax8ProductId } else {
                    $resolved = Resolve-Pax8ProductId -NameHint $p.Pax8ProductNameHint
                    if ($resolved) { $resolved.id } else { $null }
                }
                if ($prodId) {
                    $ctId = Get-Pax8CommitmentTermId -ProductId $prodId -BillingTerm $settings.billingTerm
                    $pd   = Get-MicrosoftProvisioningDetails -TenantConfig $tenant -LocationMpnId $settings.pax8.locationMpnId
                    # Some products (e.g. Teams Phone Standard) make Pax8 ask the Microsoft overage question. The answer
                    # applies to every overage-eligible product on the tenant and is a billing decision, so it is only
                    # sent when the tenant config sets microsoftProvisioning.includeOverage to 'Yes' or 'No'. It is used
                    # only if Pax8 rejects the order for that reason; with no setting the order fails with a clear hint.
                    $orderArgs = @{
                        CompanyId = $companyId; ProductId = $prodId; Quantity = $targetQty; BillingTerm = $settings.billingTerm
                        CommitmentTermId = $ctId; ProvisioningDetails = $pd; OrderedByUserEmail = $settings.pax8.orderedByUserEmail
                    }
                    $ovrSetting = if ($tenant.microsoftProvisioning) { [string]$tenant.microsoftProvisioning.includeOverage } else { '' }
                    if ($ovrSetting -match '^\s*(Yes|No)\s*$') { $orderArgs.OverageChoice = $Matches[1] }
                    New-Pax8Order @orderArgs -IsMock:$useMock
                } else {
                    Write-Log -Level ERROR -Message ("No Pax8 product ID for {0}; cannot order. Use the onboarding wizard to set pax8ProductId, or add a pax8ProductNameHint to the tenant config." -f $p.SkuPartNumber)
                    $err++
                    $failedSkus.Add([string]$p.SkuPartNumber)
                    $failures.Add(("{0}: {1} {2:+#;-#;0} NOT ATTEMPTED`n  Reason: no Pax8 product ID for this SKU. Set pax8ProductId in TenantConfig, or fix pax8ProductNameHint (currently '{3}')." -f $p.SkuPartNumber, $p.Action, $p.DeltaSeats, $p.Pax8ProductNameHint))
                }
            }
        } catch {
            $reason = Get-Pax8ErrorText -ErrorRecord $_
            if ($reason -match 'overage enablement' -and $reason -match 'required') {
                $reason += ' || ACTION NEEDED: this product requires an overage answer and none is configured. In the TenantConfig variable, add "includeOverage": "No" (no overage billing) or "Yes" (bill overage to the customer Azure Plan on Pax8) inside "microsoftProvisioning". Note Pax8 applies the choice to every overage-eligible product on this tenant.'
            }
            Write-Log -Level ERROR -Message ("Action failed for {0}: {1}" -f $p.SkuPartNumber, $reason)
            $err++
            $failedSkus.Add([string]$p.SkuPartNumber)
            $failures.Add(("{0}: {1} {2:+#;-#;0} FAILED (target Pax8 qty {3}, Pax8 product {4}, subscription {5})`n  Reason: {6}" -f $p.SkuPartNumber, $p.Action, $p.DeltaSeats, $targetQty, $(if ($p.Pax8ProductId) { $p.Pax8ProductId } else { '(resolved by name hint)' }), $(if ($p.Pax8SubscriptionId) { $p.Pax8SubscriptionId } else { 'none' }), $reason))
            # Also surface it in the Automation job output so it is visible without opening the email.
            Write-Output ("ERROR {0}: {1}" -f $p.SkuPartNumber, $reason)
        }
    }

    $actionable = @($plan | Where-Object { $_.DeltaSeats -ne 0 -and $_.Action -in 'topup','order','downsize' })
    if ($actionable.Count -or $err) {
        $runType = if ($dryRun) { 'DRY-RUN' } elseif ($MockExecute) { 'MOCK' } else { 'LIVE' }
        $lines = $actionable | ForEach-Object {
            '{0}: {1} {2:+#;-#;0} -> {3} (renew {4})' -f $_.SkuPartNumber, $_.Action, $_.DeltaSeats, $_.DesiredPax8, $_.RenewDate
        }
        $subject = 'Pax8 License Sync [{0}] {1} - {2} action(s), {3} error(s)' -f $runType, $tenant.displayName, $actionable.Count, $err
        if ($failedSkus.Count) { $subject += ' (failed: ' + ((@($failedSkus | Select-Object -Unique)) -join ', ') + ')' }
        $alertBody = "Tenant: {0}`nMode: {1}`nRun time (UTC): {2:u}`n`n{3}" -f $tenant.displayName, $runType, (Get-Date).ToUniversalTime(), ($lines -join "`n")
        if ($err) {
            $alertBody += "`n`n{0} error(s) this run." -f $err
            if ($failures.Count) { $alertBody += "`n`nWHAT FAILED:`n`n" + ($failures -join "`n`n") }
            else { $alertBody += ' No detail was captured; check the Automation job output.' }
        }
        # fromMailbox must be in the client's tenant — derive it from the tenant's default domain
        $alertConfig = [pscustomobject]@{
            method      = $settings.alert.method
            target      = $settings.alert.target
            fromMailbox = "netbit@$($tenant.defaultDomain)"
        }
        Send-LicenseAlert -AlertConfig $alertConfig -Subject $subject -Body $alertBody
    }

    Write-Log -Level INFO -Message 'Run complete.'
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
}
