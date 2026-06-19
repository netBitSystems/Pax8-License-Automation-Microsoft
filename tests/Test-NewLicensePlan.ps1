# Test-NewLicensePlan.ps1
# Pure-logic test for src/LicenseLogic.psm1 New-LicensePlan. No API calls, no money.
# Verifies the initialSeats / brand-new-product behavior:
#   a) SKU present in tenant + Pax8 sub  -> normal top-up (assigned+buffer), initialSeats ignored
#   b) SKU absent + initialSeats>0       -> order the initial seats
#   c) SKU absent + initialSeats=0       -> skipped (not in plan)
#   d) SKU present + initialSeats set     -> initialSeats IGNORED, normal sizing
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\Logging.psm1')      -Force
Import-Module (Join-Path $root 'src\LicenseLogic.psm1') -Force

$settings = [pscustomobject]@{
    leadDays   = 14
    guardrails = [pscustomobject]@{ perRunMaxIncreasePerSku = 25; defaultBuffer = 2; defaultMaxSeats = 50 }
}

# Only EXISTING1 and EXISTING2 are present in the tenant.
$skuSummary = @(
    [pscustomobject]@{ SkuPartNumber = 'EXISTING1'; SkuId = 'guid-e1'; Enabled = 20; Consumed = 10 }
    [pscustomobject]@{ SkuPartNumber = 'EXISTING2'; SkuId = 'guid-e2'; Enabled = 8;  Consumed = 4  }
)

$pax8Subs = @(
    [pscustomobject]@{ id = 'sub-1'; productName = 'Existing One'; quantity = 5 }
    [pscustomobject]@{ id = 'sub-2'; productName = 'Existing Two'; quantity = 6 }
)

$tenant = [pscustomobject]@{
    greenfield = $false
    skuMap     = @(
        [pscustomobject]@{ skuPartNumber = 'EXISTING1'; pax8ProductNameHint = 'Existing One'; pax8ProductId = 'p1'; buffer = 2; maxSeats = 50; initialSeats = 0  }
        [pscustomobject]@{ skuPartNumber = 'NEWPROD';   pax8ProductNameHint = 'Brand New';    pax8ProductId = 'p3'; buffer = 2; maxSeats = 50; initialSeats = 3  }
        [pscustomobject]@{ skuPartNumber = 'NEWNOINIT'; pax8ProductNameHint = 'No Init';      pax8ProductId = 'p4'; buffer = 2; maxSeats = 50; initialSeats = 0  }
        [pscustomobject]@{ skuPartNumber = 'EXISTING2'; pax8ProductNameHint = 'Existing Two'; pax8ProductId = 'p2'; buffer = 2; maxSeats = 50; initialSeats = 99 }
    )
}

$plan = New-LicensePlan -SkuSummary $skuSummary -TenantConfig $tenant -Settings $settings -Pax8Subscriptions $pax8Subs -Renewals $null

$script:fail = 0
function Check([string]$name, [bool]$cond, [string]$detail) {
    if ($cond) { Write-Host "PASS: $name" -ForegroundColor Green }
    else { Write-Host "FAIL: $name -- $detail" -ForegroundColor Red; $script:fail++ }
}

$a = $plan | Where-Object { $_.SkuPartNumber -eq 'EXISTING1' }
Check 'a) existing -> topup'        ($a.Action -eq 'topup') "action=$($a.Action)"
Check 'a) existing desired=12'      ($a.Desired -eq 12)     "desired=$($a.Desired)"
Check 'a) existing delta=7'         ($a.DeltaSeats -eq 7)   "delta=$($a.DeltaSeats)"

$b = $plan | Where-Object { $_.SkuPartNumber -eq 'NEWPROD' }
Check 'b) new product in plan'      ($null -ne $b)          'missing'
Check 'b) new product -> order'     ($b.Action -eq 'order') "action=$($b.Action)"
Check 'b) new product desired=3'    ($b.Desired -eq 3)      "desired=$($b.Desired)"
Check 'b) new product delta=3'      ($b.DeltaSeats -eq 3)   "delta=$($b.DeltaSeats)"
Check 'b) new product assigned=0'   ($b.Assigned -eq 0)     "assigned=$($b.Assigned)"

$c = $plan | Where-Object { $_.SkuPartNumber -eq 'NEWNOINIT' }
Check 'c) no-initialSeats skipped'  ($null -eq $c)          'unexpectedly present'

$d = $plan | Where-Object { $_.SkuPartNumber -eq 'EXISTING2' }
Check 'd) existing ignores initialSeats (none)' ($d.Action -eq 'none') "action=$($d.Action)"
Check 'd) existing desired=6 not 99'             ($d.Desired -eq 6)     "desired=$($d.Desired)"

Write-Host ''
$plan | Format-Table SkuPartNumber, Assigned, Pax8Qty, Desired, Action, DeltaSeats -AutoSize | Out-String | Write-Host
if ($script:fail -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green; exit 0 }
else { Write-Host "$script:fail TEST(S) FAILED" -ForegroundColor Red; exit 1 }
