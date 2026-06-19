# Test-NewLicensePlan.ps1
# Pure-logic test for src/LicenseLogic.psm1 New-LicensePlan. No API calls, no money.
# Verifies the initialSeats / brand-new-product behavior:
#   a) SKU present in tenant + Pax8 sub  -> normal top-up (assigned+buffer), initialSeats ignored
#   b) SKU absent + initialSeats>0       -> order the initial seats
#   c) SKU absent + initialSeats=0       -> skipped (not in plan)
#   d) SKU present + initialSeats set     -> initialSeats IGNORED, normal sizing
# Plus the dynamic-downsizing-at-renewal behavior (scenario 2):
#   e) Excess Pax8 qty + renewal in window -> downsize to assigned+buffer
#   f) Excess Pax8 qty + renewal NOT in window -> none (hold until renewal)
#   g) Large excess + renewal in window -> downsize capped at perRunMaxIncreasePerSku, stays >= floor
#   h) Pax8 qty already at floor + renewal in window -> none
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

# ── Scenario 2: dynamic downsizing at renewal ──────────────────────────────
# All four SKUs are present in the tenant and have an active Pax8 sub whose quantity is
# at or above the floor (assigned + buffer). Renewals drive whether a reduction is allowed.
$dnow = Get-Date
$skuSummary2 = @(
    [pscustomobject]@{ SkuPartNumber = 'DOWNME';  SkuId = 'g-d'; Enabled = 20; Consumed = 10 }  # floor 12
    [pscustomobject]@{ SkuPartNumber = 'HOLDME';  SkuId = 'g-h'; Enabled = 20; Consumed = 10 }  # floor 12
    [pscustomobject]@{ SkuPartNumber = 'BIGCUT';  SkuId = 'g-b'; Enabled = 40; Consumed = 5  }  # floor 7
    [pscustomobject]@{ SkuPartNumber = 'ATFLOOR'; SkuId = 'g-a'; Enabled = 12; Consumed = 10 }  # floor 12
)
$pax8Subs2 = @(
    [pscustomobject]@{ id = 'd-1'; productName = 'Down Me';  quantity = 20 }
    [pscustomobject]@{ id = 'd-2'; productName = 'Hold Me';  quantity = 20 }
    [pscustomobject]@{ id = 'd-3'; productName = 'Big Cut';  quantity = 40 }
    [pscustomobject]@{ id = 'd-4'; productName = 'At Floor'; quantity = 12 }
)
$renewals2 = @(
    [pscustomobject]@{ skuPartNumber = 'DOWNME';  isTrial = $false; nextLifecycleDateTime = $dnow.AddDays(5).ToString('o')  }  # in window
    [pscustomobject]@{ skuPartNumber = 'HOLDME';  isTrial = $false; nextLifecycleDateTime = $dnow.AddDays(60).ToString('o') }  # not in window
    [pscustomobject]@{ skuPartNumber = 'BIGCUT';  isTrial = $false; nextLifecycleDateTime = $dnow.AddDays(3).ToString('o')  }  # in window
    [pscustomobject]@{ skuPartNumber = 'ATFLOOR'; isTrial = $false; nextLifecycleDateTime = $dnow.AddDays(5).ToString('o')  }  # in window
)
$tenant2 = [pscustomobject]@{
    greenfield = $false
    skuMap     = @(
        [pscustomobject]@{ skuPartNumber = 'DOWNME';  pax8ProductNameHint = 'Down Me';  pax8ProductId = 'pd1'; buffer = 2; maxSeats = 50; initialSeats = 0 }
        [pscustomobject]@{ skuPartNumber = 'HOLDME';  pax8ProductNameHint = 'Hold Me';  pax8ProductId = 'pd2'; buffer = 2; maxSeats = 50; initialSeats = 0 }
        [pscustomobject]@{ skuPartNumber = 'BIGCUT';  pax8ProductNameHint = 'Big Cut';  pax8ProductId = 'pd3'; buffer = 2; maxSeats = 50; initialSeats = 0 }
        [pscustomobject]@{ skuPartNumber = 'ATFLOOR'; pax8ProductNameHint = 'At Floor'; pax8ProductId = 'pd4'; buffer = 2; maxSeats = 50; initialSeats = 0 }
    )
}
$plan2 = New-LicensePlan -SkuSummary $skuSummary2 -TenantConfig $tenant2 -Settings $settings -Pax8Subscriptions $pax8Subs2 -Renewals $renewals2

$e = $plan2 | Where-Object { $_.SkuPartNumber -eq 'DOWNME' }
Check 'e) excess + renewal -> downsize'   ($e.Action -eq 'downsize')                       "action=$($e.Action)"
Check 'e) downsize delta=-8'              ($e.DeltaSeats -eq -8)                           "delta=$($e.DeltaSeats)"
Check 'e) downsize target=floor 12'       (($e.Pax8Qty + $e.DeltaSeats) -eq 12)            "target=$($e.Pax8Qty + $e.DeltaSeats)"
Check 'e) never below assigned+buffer'    (($e.Pax8Qty + $e.DeltaSeats) -ge ($e.Assigned + $e.Buffer)) "target=$($e.Pax8Qty + $e.DeltaSeats) floor=$($e.Assigned + $e.Buffer)"

$f = $plan2 | Where-Object { $_.SkuPartNumber -eq 'HOLDME' }
Check 'f) excess but not in window -> none' ($f.Action -eq 'none')  "action=$($f.Action)"
Check 'f) hold delta=0'                     ($f.DeltaSeats -eq 0)   "delta=$($f.DeltaSeats)"

$g = $plan2 | Where-Object { $_.SkuPartNumber -eq 'BIGCUT' }
Check 'g) big excess -> downsize'         ($g.Action -eq 'downsize')                       "action=$($g.Action)"
Check 'g) downsize capped at -25'         ($g.DeltaSeats -eq -25)                          "delta=$($g.DeltaSeats)"
Check 'g) capped target stays >= floor'   (($g.Pax8Qty + $g.DeltaSeats) -ge ($g.Assigned + $g.Buffer)) "target=$($g.Pax8Qty + $g.DeltaSeats) floor=$($g.Assigned + $g.Buffer)"

$h = $plan2 | Where-Object { $_.SkuPartNumber -eq 'ATFLOOR' }
Check 'h) already at floor -> none'       ($h.Action -eq 'none')  "action=$($h.Action)"
Check 'h) at floor delta=0'               ($h.DeltaSeats -eq 0)   "delta=$($h.DeltaSeats)"

Write-Host ''
$plan  | Format-Table SkuPartNumber, Assigned, Pax8Qty, Desired, Action, DeltaSeats -AutoSize | Out-String | Write-Host
$plan2 | Format-Table SkuPartNumber, Assigned, Pax8Qty, Desired, Action, DeltaSeats, RenewDate -AutoSize | Out-String | Write-Host
if ($script:fail -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green; exit 0 }
else { Write-Host "$script:fail TEST(S) FAILED" -ForegroundColor Red; exit 1 }
