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

        $buffer       = if ($null -ne $entry.buffer)       { [int]$entry.buffer }       else { [int]$Settings.guardrails.defaultBuffer }
        $maxSeats     = if ($null -ne $entry.maxSeats)     { [int]$entry.maxSeats }     else { [int]$Settings.guardrails.defaultMaxSeats }
        $initialSeats = if ($null -ne $entry.initialSeats) { [int]$entry.initialSeats } else { 0 }
        $inTenant     = [bool]$sku

        if ($inTenant) {
            # License already exists in the tenant: size from real usage. initialSeats is ignored.
            $assigned  = [int]$sku.Consumed
            $msEnabled = [int]$sku.Enabled
            $desired   = [math]::Min($assigned + $buffer, $maxSeats)
        } else {
            # License is not in the tenant. Only act if an initial purchase quantity is configured;
            # otherwise there is no usage signal to size an order from, so skip as before.
            if ($initialSeats -le 0) {
                Write-Log -Level WARN -Message ("SKU {0} not present in tenant and no initialSeats set; skipping." -f $entry.skuPartNumber)
                continue
            }
            $assigned  = 0
            $msEnabled = 0
            $desired   = [math]::Min($initialSeats, $maxSeats)
        }

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
            } elseif (-not $inTenant) {
                $action = 'order'
                $reason = "New product not yet in tenant; placing initial order of $desired seats"
            } elseif ($renewSoon) {
                $action = 'transition'
                $reason = "Renewal date $($renewDate.ToString('yyyy-MM-dd')); order $desired seats on Pax8"
            } elseif ([bool]$TenantConfig.greenfield) {
                $action = 'order'
                $reason = "Greenfield: no existing Pax8 subscription; ordering $desired seats"
            } else {
                $action = 'wait'
                $reason = "No active Pax8 subscription; renewal not within $leadDays days"
            }
            if (($pax8Qty + $delta) -ge $maxSeats) { $reason += " (capped at maxSeats $maxSeats)" }
        } elseif ($pax8Qty -gt $desired) {
            # Excess Pax8 seats. Microsoft NCE annual terms only allow reductions at renewal, so
            # downsize only inside the lead window, only for an active Pax8 sub on a license that
            # is present in the tenant, and never below assigned + buffer. The per-run decrease
            # mirrors the perRunMaxIncreasePerSku cap used for increases.
            $floor = $assigned + $buffer
            if ($inTenant -and $pax8Sub -and $renewSoon -and ($pax8Qty -gt $floor)) {
                $reduce = [math]::Min($pax8Qty - $floor, $perRunMax)
                $delta  = -1 * $reduce
                $action = 'downsize'
                $reason = "Renewal $($renewDate.ToString('yyyy-MM-dd')) within $leadDays days; reduce Pax8 qty $pax8Qty -> $($pax8Qty - $reduce) (floor assigned $assigned + buffer $buffer)"
            } elseif (-not $renewSoon) {
                $reason = "Pax8 qty $pax8Qty above desired $desired; holding until renewal window ($leadDays days)"
            } elseif (-not $pax8Sub) {
                $reason = "Pax8 qty $pax8Qty above desired $desired but no active Pax8 subscription to reduce"
            } elseif (-not $inTenant) {
                $reason = "Pax8 qty $pax8Qty above desired $desired but license not present in tenant; not downsizing"
            } else {
                $reason = "Pax8 qty $pax8Qty already at floor (assigned $assigned + buffer $buffer); no downsize"
            }
        }

        $plan += [pscustomobject]@{
            SkuPartNumber       = $entry.skuPartNumber
            Product             = $entry.pax8ProductNameHint
            MsEnabled           = $msEnabled
            Assigned            = $assigned
            Buffer              = $buffer
            MaxSeats            = $maxSeats
            Pax8Qty             = $pax8Qty
            Desired             = $desired
            Action              = $action
            DeltaSeats          = $delta
            RenewDate           = if ($renewDate) { $renewDate.ToString('yyyy-MM-dd') } else { '' }
            Pax8ProductId       = if ($entry.pax8ProductId) { $entry.pax8ProductId } else { '' }
            Pax8ProductNameHint = $entry.pax8ProductNameHint
            Pax8SubscriptionId  = if ($pax8Sub) { $pax8Sub.id } else { '' }
            Reason              = $reason
        }
    }
    return $plan
}

Export-ModuleMember -Function New-LicensePlan
