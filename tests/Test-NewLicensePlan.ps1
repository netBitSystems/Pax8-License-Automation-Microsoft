# Test-NewLicensePlan.ps1
# Pure-logic test for src/LicenseLogic.psm1 New-LicensePlan. No API calls, no money.
#
# Pooled delta model: Pax8 only buys what the tenant does not already own off Pax8.
#   directSeats = max(0, MsEnabled - Pax8Qty)         (Microsoft direct / EA / trial seats)
#   desiredPax8 = clamp(desired - directSeats, 0, maxSeats)
#   delta       = desiredPax8 - Pax8Qty
#
# Scenario 1 (increases, no renewal needed):
#   a) in tenant, short, no Pax8 sub      -> order just the delta (buy 5 now, direct covers the rest)
#   b) in tenant, direct still covers need -> none (no double buy)
#   c) in tenant, direct fell off          -> topup the full delta, NOT capped per run
#   d) not in tenant + initialSeats>0      -> order initialSeats
#   e) not in tenant + initialSeats=0      -> skipped (absent)
#   f) Graph lag (Enabled < Pax8Qty)       -> clamp prevents a re-buy (none)
# Scenario 2 (downsize, needs renewals):
#   g) excess on Pax8 + renewal in window  -> downsize to desiredPax8 (keeps the pool whole)
#   h) excess on Pax8 + renewal not soon   -> none (hold until renewal)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\Logging.psm1')      -Force
Import-Module (Join-Path $root 'src\LicenseLogic.psm1') -Force

$settings = [pscustomobject]@{
    leadDays   = 14
    guardrails = [pscustomobject]@{ defaultBuffer = 2; defaultMaxSeats = 50 }
}

$script:fail = 0
function Check([string]$name, [bool]$cond, [string]$detail) {
    if ($cond) { Write-Host "PASS: $name" -ForegroundColor Green }
    else { Write-Host "FAIL: $name -- $detail" -ForegroundColor Red; $script:fail++ }
}

# -- Scenario 1: increases (pooled delta) -----------------------------------
# MsEnabled is the whole pool. Pax8 fills only the gap the other channels do not cover.
$skuSummary1 = @(
    [pscustomobject]@{ SkuPartNumber = 'BUYNOW';    SkuId = 'g-b'; Enabled = 20; Consumed = 20 }  # 20 direct, fully used
    [pscustomobject]@{ SkuPartNumber = 'STABLE';    SkuId = 'g-s'; Enabled = 25; Consumed = 20 }  # 20 direct + 5 Pax8
    [pscustomobject]@{ SkuPartNumber = 'FALLOFF';   SkuId = 'g-f'; Enabled = 5;  Consumed = 40 }  # direct gone, only 5 Pax8 left
    [pscustomobject]@{ SkuPartNumber = 'FRESHCLAMP';SkuId = 'g-c'; Enabled = 1;  Consumed = 1  }  # Graph lags a fresh Pax8 order
)
$pax8Subs1 = @(
    [pscustomobject]@{ id = 's-stable'; productName = 'Stable';  quantity = 5  }
    [pscustomobject]@{ id = 's-fall';   productName = 'Falloff'; quantity = 5  }
    [pscustomobject]@{ id = 's-fresh';  productName = 'Fresh';   quantity = 2  }
)
$tenant1 = [pscustomobject]@{
    greenfield = $false
    skuMap     = @(
        [pscustomobject]@{ skuPartNumber = 'BUYNOW';    pax8ProductNameHint = 'Buy Now'; pax8ProductId = 'p1'; buffer = 5; maxSeats = 50;  initialSeats = 0 }
        [pscustomobject]@{ skuPartNumber = 'STABLE';    pax8ProductNameHint = 'Stable';  pax8ProductId = 'p2'; buffer = 5; maxSeats = 50;  initialSeats = 0 }
        [pscustomobject]@{ skuPartNumber = 'FALLOFF';   pax8ProductNameHint = 'Falloff'; pax8ProductId = 'p3'; buffer = 5; maxSeats = 100; initialSeats = 0 }
        [pscustomobject]@{ skuPartNumber = 'NEWPROD';   pax8ProductNameHint = 'New One'; pax8ProductId = 'p4'; buffer = 2; maxSeats = 50;  initialSeats = 3 }
        [pscustomobject]@{ skuPartNumber = 'NEWNOINIT'; pax8ProductNameHint = 'No Init'; pax8ProductId = 'p5'; buffer = 2; maxSeats = 50;  initialSeats = 0 }
        [pscustomobject]@{ skuPartNumber = 'FRESHCLAMP';pax8ProductNameHint = 'Fresh';   pax8ProductId = 'p6'; buffer = 1; maxSeats = 50;  initialSeats = 0 }
    )
}
$plan1 = New-LicensePlan -SkuSummary $skuSummary1 -TenantConfig $tenant1 -Settings $settings -Pax8Subscriptions $pax8Subs1 -Renewals $null

$a = $plan1 | Where-Object { $_.SkuPartNumber -eq 'BUYNOW' }
Check 'a) short + no sub -> order'     ($a.Action -eq 'order')   "action=$($a.Action)"
Check 'a) order delta=+5 (the gap)'    ($a.DeltaSeats -eq 5)     "delta=$($a.DeltaSeats)"
Check 'a) desiredPax8=5 not 25'        ($a.DesiredPax8 -eq 5)    "desiredPax8=$($a.DesiredPax8)"
Check 'a) pool whole: direct+pax8=25'  (($a.DirectSeats + $a.DesiredPax8) -eq $a.Desired) "direct=$($a.DirectSeats) desiredPax8=$($a.DesiredPax8) desired=$($a.Desired)"

$b = $plan1 | Where-Object { $_.SkuPartNumber -eq 'STABLE' }
Check 'b) direct covers need -> none'  ($b.Action -eq 'none')    "action=$($b.Action)"
Check 'b) no double buy delta=0'       ($b.DeltaSeats -eq 0)     "delta=$($b.DeltaSeats)"

$c = $plan1 | Where-Object { $_.SkuPartNumber -eq 'FALLOFF' }
Check 'c) direct fell off -> topup'    ($c.Action -eq 'topup')   "action=$($c.Action)"
Check 'c) catch-up delta=+40 uncapped' ($c.DeltaSeats -eq 40)    "delta=$($c.DeltaSeats)"
Check 'c) desiredPax8=45'              ($c.DesiredPax8 -eq 45)   "desiredPax8=$($c.DesiredPax8)"

$d = $plan1 | Where-Object { $_.SkuPartNumber -eq 'NEWPROD' }
Check 'd) new product -> order'        ($d.Action -eq 'order')   "action=$($d.Action)"
Check 'd) new product delta=3'         ($d.DeltaSeats -eq 3)     "delta=$($d.DeltaSeats)"
Check 'd) new product assigned=0'      ($d.Assigned -eq 0)       "assigned=$($d.Assigned)"

$e = $plan1 | Where-Object { $_.SkuPartNumber -eq 'NEWNOINIT' }
Check 'e) no-initialSeats skipped'     ($null -eq $e)            'unexpectedly present'

$f = $plan1 | Where-Object { $_.SkuPartNumber -eq 'FRESHCLAMP' }
Check 'f) fresh-order clamp -> none'   ($f.Action -eq 'none')    "action=$($f.Action)"
Check 'f) clamp delta=0 (no re-buy)'   ($f.DeltaSeats -eq 0)     "delta=$($f.DeltaSeats)"
Check 'f) directSeats clamped to 0'    ($f.DirectSeats -eq 0)    "directSeats=$($f.DirectSeats)"

# -- Scenario 2: downsize at renewal ----------------------------------------
# Excess seats now all sit on Pax8 (direct gone). Reduce only inside the renewal window.
$dnow = Get-Date
$skuSummary2 = @(
    [pscustomobject]@{ SkuPartNumber = 'DOWNME'; SkuId = 'g-d'; Enabled = 20; Consumed = 10 }  # need 12, pool 20
    [pscustomobject]@{ SkuPartNumber = 'HOLD';   SkuId = 'g-h'; Enabled = 20; Consumed = 10 }  # need 12, pool 20
)
$pax8Subs2 = @(
    [pscustomobject]@{ id = 's-down'; productName = 'Down Me'; quantity = 20 }
    [pscustomobject]@{ id = 's-hold'; productName = 'Hold Me'; quantity = 20 }
)
$renewals2 = @(
    [pscustomobject]@{ skuPartNumber = 'DOWNME'; isTrial = $false; nextLifecycleDateTime = $dnow.AddDays(5).ToString('o')  }   # in window
    [pscustomobject]@{ skuPartNumber = 'HOLD';   isTrial = $false; nextLifecycleDateTime = $dnow.AddDays(60).ToString('o') }   # not in window
)
$tenant2 = [pscustomobject]@{
    greenfield = $false
    skuMap     = @(
        [pscustomobject]@{ skuPartNumber = 'DOWNME'; pax8ProductNameHint = 'Down Me'; pax8ProductId = 'pd1'; buffer = 2; maxSeats = 50; initialSeats = 0 }
        [pscustomobject]@{ skuPartNumber = 'HOLD';   pax8ProductNameHint = 'Hold Me'; pax8ProductId = 'pd2'; buffer = 2; maxSeats = 50; initialSeats = 0 }
    )
}
$plan2 = New-LicensePlan -SkuSummary $skuSummary2 -TenantConfig $tenant2 -Settings $settings -Pax8Subscriptions $pax8Subs2 -Renewals $renewals2

$g = $plan2 | Where-Object { $_.SkuPartNumber -eq 'DOWNME' }
Check 'g) excess + renewal -> downsize' ($g.Action -eq 'downsize')                "action=$($g.Action)"
Check 'g) downsize delta=-8'            ($g.DeltaSeats -eq -8)                    "delta=$($g.DeltaSeats)"
Check 'g) downsize target=12 (pool whole)' ($g.DesiredPax8 -eq 12)               "desiredPax8=$($g.DesiredPax8)"
Check 'g) target = assigned+buffer'     ($g.DesiredPax8 -eq ($g.Assigned + $g.Buffer)) "desiredPax8=$($g.DesiredPax8) need=$($g.Assigned + $g.Buffer)"

$h = $plan2 | Where-Object { $_.SkuPartNumber -eq 'HOLD' }
Check 'h) excess but not in window -> none' ($h.Action -eq 'none') "action=$($h.Action)"
Check 'h) hold delta=0'                     ($h.DeltaSeats -eq 0)  "delta=$($h.DeltaSeats)"

Write-Host ''
$plan1 | Format-Table SkuPartNumber, Assigned, MsEnabled, Pax8Qty, Desired, DirectSeats, DesiredPax8, Action, DeltaSeats -AutoSize | Out-String | Write-Host
$plan2 | Format-Table SkuPartNumber, Assigned, MsEnabled, Pax8Qty, Desired, DirectSeats, DesiredPax8, Action, DeltaSeats, RenewDate -AutoSize | Out-String | Write-Host
if ($script:fail -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green; exit 0 }
else { Write-Host "$script:fail TEST(S) FAILED" -ForegroundColor Red; exit 1 }
