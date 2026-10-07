# Test-OrderOverageRetry.ps1
# Offline test for src/Pax8.psm1: the overage-answer retry in New-Pax8Order and the Get-Pax8ErrorText helper.
# Invoke-Pax8 is replaced with a mock, so there are no API calls and no money.
#
#   1) Pax8 rejects an order for the missing overage field AND a choice is configured -> retried ONCE with that answer
#   2) OverageChoice 'Yes' -> the "Yes" wording is used
#   3) Product that needs nothing extra -> exactly one POST, no extra lookups (existing behavior unchanged)
#   4) Unrelated 400 -> not retried, error (and its response body) preserved for the caller
#   5) Overage key already supplied by the caller -> not retried
#   6) Pax8 keeps rejecting after the retry -> stops after one retry (no loop), still throws
#   7) Get-Pax8ErrorText turns the response body into readable text
#   8) NO choice configured -> never guesses: one POST, no lookup, fails with Pax8's reason intact
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function global:Write-Log { param($Level, $Message, $Data) }
Import-Module (Join-Path $root 'src\Pax8.psm1') -Force
$mod = Get-Module Pax8

$script:fail = 0
function Check([string]$name, [bool]$cond, [string]$detail) {
    if ($cond) { Write-Host "PASS: $name" -ForegroundColor Green }
    else { Write-Host "FAIL: $name -- $detail" -ForegroundColor Red; $script:fail++ }
}

function New-Failure([string]$json) {
    $er = [System.Management.Automation.ErrorRecord]::new(
        [System.Exception]::new('Response status code does not indicate success: 400 (Bad Request).'),
        'Pax8400', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
    $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($json)
    return $er
}

$global:OverageJson = '{"type":"BAD_REQUEST","message":null,"instance":"/public/v1/orders","status":400,"details":[{"message":"Errors with provisioningDetails"},{"message":"This Microsoft product is eligible for overage enablement. Would you like to allow your customer the flexibility to use these services in excess of what the standard plan entitles?: This field is required."}]}'
$global:OtherJson   = '{"type":"BAD_REQUEST","message":"Quantity must be greater than zero","status":400,"details":[]}'

# Replace Invoke-Pax8 inside the module with a mock
$mockBlock = {
    param([string]$Method, [string]$Path, [hashtable]$Query, [object]$Body)
    $global:Calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
    if ($Method -eq 'GET' -and $Path -like 'products/*/provision-details') {
        return [pscustomobject]@{ content = @([pscustomobject]@{
            key = 'microsoftIncludeOverage'
            possibleValues = @('No, I do not wish to enable overage.', 'Yes, my customer has an active Azure Plan subscription through Pax8 to account for any overage charges')
        }) }
    }
    if ($Method -eq 'POST' -and $Path -eq 'orders') {
        $has = $false
        foreach ($i in @($Body.lineItems[0].provisioningDetails)) { if ($i -and $i.key -eq 'microsoftIncludeOverage') { $has = $true } }
        switch ($global:Scenario) {
            'needsOverage'  { if (-not $has) { throw (New-Failure $global:OverageJson) } else { return [pscustomobject]@{ ok = $true } } }
            'ok'            { return [pscustomobject]@{ ok = $true } }
            'other400'      { throw (New-Failure $global:OtherJson) }
            'alwaysOverage' { throw (New-Failure $global:OverageJson) }
        }
    }
}
& $mod { param($b) Set-Item -Path Function:Invoke-Pax8 -Value $b } $mockBlock

function Run-Order([string]$scenario, [array]$pd, [string]$choice) {
    $global:Scenario = $scenario
    $global:Calls = [System.Collections.Generic.List[object]]::new()
    $res = [ordered]@{ Result = $null; Error = $null }
    $args2 = @{ CompanyId = 'co'; ProductId = 'prod-1'; Quantity = 3; ProvisioningDetails = $pd }
    if ($choice) { $args2.OverageChoice = $choice }
    try { $res.Result = New-Pax8Order @args2 } catch { $res.Error = $_ }
    $res.Posts = @($global:Calls | Where-Object { $_.Method -eq 'POST' }).Count
    $res.Gets  = @($global:Calls | Where-Object { $_.Method -eq 'GET' }).Count
    $res.LastPost = @($global:Calls | Where-Object { $_.Method -eq 'POST' })[-1]
    return [pscustomobject]$res
}
function Overage-Of($call) {
    foreach ($i in @($call.Body.lineItems[0].provisioningDetails)) { if ($i.key -eq 'microsoftIncludeOverage') { return [string]$i.values[0] } }
    return $null
}
$basePd = @([ordered]@{ key = 'msTenantId'; values = @('tenant-1') })

# 1) needs overage + choice 'No' configured -> retried once with 'No'
$r = Run-Order 'needsOverage' $basePd 'No'
Check '1) order succeeds after retry'          ($null -ne $r.Result -and $null -eq $r.Error) "error=$($r.Error)"
Check '1) exactly 2 POSTs (try + one retry)'   ($r.Posts -eq 2) "posts=$($r.Posts)"
Check '1) read the product wording once'       ($r.Gets -eq 1)  "gets=$($r.Gets)"
Check "1) retry answer starts with 'No,'"      ((Overage-Of $r.LastPost) -like 'No,*') "answer=$(Overage-Of $r.LastPost)"
$keys = @($r.LastPost.Body.lineItems[0].provisioningDetails | ForEach-Object { $_.key })
Check '1) original provisioning kept'          ($keys -contains 'msTenantId' -and $keys -contains 'microsoftIncludeOverage') "keys=$($keys -join ',')"

# 2) choice Yes
$r = Run-Order 'needsOverage' $basePd 'Yes'
Check "2) 'Yes' wording used"                  ((Overage-Of $r.LastPost) -like 'Yes,*') "answer=$(Overage-Of $r.LastPost)"

# 3) product needs nothing extra -> unchanged behavior
$r = Run-Order 'ok' $basePd $null
Check '3) one POST only'                       ($r.Posts -eq 1) "posts=$($r.Posts)"
Check '3) no extra lookups'                    ($r.Gets -eq 0)  "gets=$($r.Gets)"
Check '3) overage field NOT sent'              ($null -eq (Overage-Of $r.LastPost)) "answer=$(Overage-Of $r.LastPost)"

# 4) unrelated 400 -> not retried, response body preserved on the error
$r = Run-Order 'other400' $basePd $null
Check '4) unrelated 400 throws'                ($null -ne $r.Error) 'no error thrown'
Check '4) not retried'                         ($r.Posts -eq 1) "posts=$($r.Posts)"
Check '4) response body still on the error'    ($r.Error.ErrorDetails.Message -match 'Quantity must be greater than zero') "details=$($r.Error.ErrorDetails.Message)"

# 5) caller already supplied the field -> no retry
$pdWith = @($basePd) + @([ordered]@{ key = 'microsoftIncludeOverage'; values = @('whatever') })
$r = Run-Order 'alwaysOverage' $pdWith 'No'
Check '5) field already sent -> no retry'      ($r.Posts -eq 1 -and $null -ne $r.Error) "posts=$($r.Posts)"

# 6) still rejected after the retry -> exactly one retry, then throws
$r = Run-Order 'alwaysOverage' $basePd 'No'
Check '6) one retry only (no loop)'            ($r.Posts -eq 2) "posts=$($r.Posts)"
Check '6) still throws after the retry'        ($null -ne $r.Error) 'no error thrown'

# 8) overage required but NO choice configured -> never guesses
$r = Run-Order 'needsOverage' $basePd $null
Check '8) no choice -> order fails'            ($null -ne $r.Error -and $null -eq $r.Result) 'order unexpectedly succeeded'
Check '8) no retry, one POST'                  ($r.Posts -eq 1) "posts=$($r.Posts)"
Check '8) no lookup made'                      ($r.Gets -eq 0)  "gets=$($r.Gets)"
Check '8) Pax8 reason preserved on the error'  ($r.Error.ErrorDetails.Message -match 'This field is required') "details=$($r.Error.ErrorDetails.Message)"

# 7) readable error text
$t = Get-Pax8ErrorText -ErrorRecord (New-Failure $global:OverageJson)
Check '7) includes the HTTP status text'       ($t -match '400') $t
Check '7) includes Pax8 detail messages'       ($t -match 'Errors with provisioningDetails' -and $t -match 'This field is required') $t
$t2 = Get-Pax8ErrorText -ErrorRecord (New-Failure 'not json at all')
Check '7) non-JSON body is shown as text'      ($t2 -match 'Response body: not json at all') $t2
$t3 = Get-Pax8ErrorText -ErrorRecord 'plain string failure'
Check '7) plain string accepted'               ($t3 -eq 'plain string failure') $t3
$long = Get-Pax8ErrorText -ErrorRecord (New-Failure ('x' * 5000)) -MaxLength 300
Check '7) long text truncated'                 ($long.Length -le 320 -and $long -match 'truncated') "len=$($long.Length)"

Write-Host ''
if ($script:fail -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green; exit 0 }
else { Write-Host "$script:fail TEST(S) FAILED" -ForegroundColor Red; exit 1 }
