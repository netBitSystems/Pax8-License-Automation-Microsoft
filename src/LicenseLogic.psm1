# LicenseLogic.psm1 - pure decision logic. Produces a plan; never calls APIs itself.
function New-LicensePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SkuSummary,
        [Parameter(Mandatory)]$TenantConfig,
        [Parameter(Mandatory)]$Settings,
        $Pax8Subscriptions,
        $Renewals
    )
    $now       = Get-Date
    $leadDays  = [int]$Settings.leadDays
    $perRunMax = [int]$Settings.guardrails.perRunMaxIncreasePerSku
    $plan = @()

    foreach ($entry in $TenantConfig.skuMap) {
        $sku = $SkuSummary | Where-Object { $_.SkuPartNumber -eq $entry.skuPartNumber } | Select-Object -First 1
        if (-not $sku) {
            Write-Log -Level WARN -Message ("SKU {0} not present in tenant; skipping." -f $entry.skuPartNumber)
            continue
        }

        $buffer   = if ($null -ne $entry.buffer)   { [int]$entry.buffer }   else { [int]$Settings.guardrails.defaultBuffer }
        $maxSeats = if ($null -ne $entry.maxSeats) { [int]$entry.maxSeats } else { [int]$Settings.guardrails.defaultMaxSeats }
        $assigned = [int]$sku.Consumed
        $desired  = [math]::Min($assigned + $buffer, $maxSeats)

        # Current Pax8 quantity for this product, matched by product name hint.
        $pax8Qty = 0
        $pax8Sub = $null
        if ($Pax8Subscriptions) {
            $pax8Sub = $Pax8Subscriptions |
                Where-Object { $_.productName -eq $entry.pax8ProductNameHint -or $_.productName -like "*$($entry.pax8ProductNameHint)*" } |
                Select-Object -First 1
            if ($pax8Sub) { $pax8Qty = [int]$pax8Sub.quantity }
        }

        # Nearest non-trial renewal for this SKU, and whether it is inside the lead window.
        $renewSoon = $false
        $renewDate = $null
        if ($Renewals) {
            $r = $Renewals |
                Where-Object { $_.skuPartNumber -eq $entry.skuPartNumber -and -not $_.isTrial } |
                Sort-Object { ($_.nextLifecycleDateTime -as [datetime]) } | Select-Object -First 1
            if ($r) {
                $nd = $r.nextLifecycleDateTime -as [datetime]
                if ($nd -and $nd.Year -lt 9000) {
                    $renewDate = $nd
                    if (($nd - $now).TotalDays -le $leadDays) { $renewSoon = $true }
                }
            }
        }

        $action = 'none'
        $delta  = 0
        $reason = "Pax8 qty $pax8Qty already covers desired $desired"
        if ($pax8Qty -lt $desired) {
            $needed = $desired - $pax8Qty
            if ($needed -gt $perRunMax) { $needed = $perRunMax }
            $delta = $needed
            if ($pax8Sub) {
                $action = 'topup'
                $reason = "Pax8 qty $pax8Qty below desired $desired (assigned $assigned + buffer $buffer)"
            } elseif ($renewSoon) {
                $action = 'transition'
                $reason = "Direct renews $($renewDate.ToString('yyyy-MM-dd')); order $desired on Pax8"
            } else {
                $action = 'wait'
                $reason = "Not on Pax8 yet; direct renewal not within $leadDays days"
            }
            if (($pax8Qty + $delta) -ge $maxSeats) { $reason += " (capped at maxSeats $maxSeats)" }
        }

        $plan += [pscustomobject]@{
            SkuPartNumber       = $entry.skuPartNumber
            Product             = $entry.pax8ProductNameHint
            MsEnabled           = [int]$sku.Enabled
            Assigned            = $assigned
            Buffer              = $buffer
            MaxSeats            = $maxSeats
            Pax8Qty             = $pax8Qty
            Desired             = $desired
            Action              = $action
            DeltaSeats          = $delta
            RenewDate           = if ($renewDate) { $renewDate.ToString('yyyy-MM-dd') } else { '' }
            Pax8ProductNameHint = $entry.pax8ProductNameHint
            Pax8SubscriptionId  = if ($pax8Sub) { $pax8Sub.id } else { '' }
            Reason              = $reason
        }
    }
    return $plan
}

Export-ModuleMember -Function New-LicensePlan
