# LicenseLogic.psm1 - pure decision logic. Produces a plan; never calls APIs itself.
function ConvertTo-SkuKey {
    # Normalize a SKU identifier (skuId or skuPartNumber) for reliable comparison. Strips Unicode
    # format/control (\p{C}) and separator/whitespace (\p{Z}) characters, then upper-cases. This
    # neutralizes stray zero-width spaces, non-breaking spaces, and trailing whitespace that can be
    # pasted into TenantConfig and silently break exact string matching.
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return ($Value -replace '[\p{C}\p{Z}]', '').ToUpperInvariant()
}

function New-LicensePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SkuSummary,
        [Parameter(Mandatory)]$TenantConfig,
        [Parameter(Mandatory)]$Settings,
        $Pax8Subscriptions,
        $Renewals
    )
    $now      = Get-Date
    $leadDays = [int]$Settings.leadDays
    $plan = @()

    foreach ($entry in $TenantConfig.skuMap) {
        # Match the tenant's Graph SKUs to this config entry. Prefer skuId (a stable GUID that is
        # byte-identical on both sides), then fall back to skuPartNumber for older configs that
        # predate skuId. Both comparisons are normalized so stray invisible/whitespace characters
        # (e.g. a zero-width space pasted into TenantConfig) cannot break the match.
        $entryId = if ($entry.skuId) { ConvertTo-SkuKey $entry.skuId } else { '' }
        $entryPn = ConvertTo-SkuKey $entry.skuPartNumber

        $sku = $null
        if ($entryId) {
            $sku = $SkuSummary | Where-Object { (ConvertTo-SkuKey $_.SkuId) -eq $entryId } | Select-Object -First 1
        }
        if (-not $sku -and $entryPn) {
            $sku = $SkuSummary | Where-Object { (ConvertTo-SkuKey $_.SkuPartNumber) -eq $entryPn } | Select-Object -First 1
        }

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
                Write-Log -Level WARN -Message ("SKU {0} (skuId {1}) not present in tenant and no initialSeats set; skipping." -f $entry.skuPartNumber, $entry.skuId)
                continue
            }
            # Not matched but initialSeats is set: bootstrap a first order. Log it, because a license
            # that actually exists but failed to match (skuId/skuPartNumber drift from Graph) also
            # lands here and would otherwise be sized from initialSeats and silently skip the buffer.
            Write-Log -Level INFO -Message ("SKU {0} (skuId {1}) not matched in tenant; bootstrapping {2} seat(s) from initialSeats. If this license already exists, verify skuId/skuPartNumber in TenantConfig matches Graph." -f $entry.skuPartNumber, $entry.skuId, $initialSeats)
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
                Where-Object {
                    -not $_.isTrial -and (
                        ($entryId -and $_.skuId -and (ConvertTo-SkuKey $_.skuId) -eq $entryId) -or
                        ($entryPn -and (ConvertTo-SkuKey $_.skuPartNumber) -eq $entryPn)
                    )
                } |
                Sort-Object { ($_.nextLifecycleDateTime -as [datetime]) } | Select-Object -First 1
            if ($r) {
                $nd = $r.nextLifecycleDateTime -as [datetime]
                if ($nd -and $nd.Year -lt 9000) {
                    $renewDate = $nd
                    if (($nd - $now).TotalDays -le $leadDays) { $renewSoon = $true }
                }
            }
        }

        # Pooled licenses: MsEnabled is the whole pool across channels. Seats already covered off
        # Pax8 (Microsoft direct, EA, trial) are MsEnabled - Pax8Qty, so Pax8 only needs to make up
        # the rest. That makes the buy a delta instead of the full desired. The max(0, ...) clamp
        # avoids an over-buy when Graph has not yet reflected a just-placed Pax8 order.
        $directSeats = [math]::Max(0, $msEnabled - $pax8Qty)
        $desiredPax8 = [math]::Max(0, [math]::Min($desired - $directSeats, $maxSeats))

        $action = 'none'
        $delta  = 0
        $reason = "Pax8 qty $pax8Qty matches needed $desiredPax8 (desired $desired; $directSeats covered off Pax8)"
        if ($pax8Qty -lt $desiredPax8) {
            # Short on Pax8: buy the delta now. No per-run cap; maxSeats already bounds desiredPax8.
            $delta = $desiredPax8 - $pax8Qty
            if ($pax8Sub) {
                $action = 'topup'
                $reason = "Pax8 short by $delta; raising $pax8Qty -> $desiredPax8 (desired $desired; $directSeats covered off Pax8)"
            } else {
                $action = 'order'
                $reason = "No Pax8 subscription yet; ordering $desiredPax8 (desired $desired; $directSeats covered off Pax8)"
            }
            if ($desiredPax8 -ge $maxSeats) { $reason += " (capped at maxSeats $maxSeats)" }
        } elseif ($pax8Qty -gt $desiredPax8) {
            # Excess on Pax8. Microsoft NCE annual terms only allow reductions at renewal, so only
            # downsize inside the lead window, only for an active Pax8 sub on a license present in
            # the tenant. desiredPax8 keeps the pool whole, so it is the floor.
            if ($inTenant -and $pax8Sub -and $renewSoon) {
                $delta  = $desiredPax8 - $pax8Qty
                $action = 'downsize'
                $reason = "Renewal $($renewDate.ToString('yyyy-MM-dd')) within $leadDays days; reducing Pax8 $pax8Qty -> $desiredPax8 (desired $desired; $directSeats covered off Pax8)"
            } elseif (-not $renewSoon) {
                $reason = "Pax8 qty $pax8Qty above needed $desiredPax8; holding until renewal window ($leadDays days)"
            } elseif (-not $pax8Sub) {
                $reason = "Pax8 qty $pax8Qty above needed $desiredPax8 but no active Pax8 subscription to reduce"
            } else {
                $reason = "Pax8 qty $pax8Qty above needed $desiredPax8 but license not present in tenant; not downsizing"
            }
        }

        $plan += [pscustomobject]@{
            SkuPartNumber       = $entry.skuPartNumber
            MsSkuId             = if ($sku) { [string]$sku.SkuId } else { '' }
            MsSkuPartNumber     = if ($sku) { [string]$sku.SkuPartNumber } else { '' }
            MatchedBy           = if (-not $sku) { 'none' } elseif ($entryId -and (ConvertTo-SkuKey $sku.SkuId) -eq $entryId) { 'skuId' } else { 'skuPartNumber' }
            Product             = $entry.pax8ProductNameHint
            MsEnabled           = $msEnabled
            Assigned            = $assigned
            Buffer              = $buffer
            MaxSeats            = $maxSeats
            Pax8Qty             = $pax8Qty
            Desired             = $desired
            DirectSeats         = $directSeats
            DesiredPax8         = $desiredPax8
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
