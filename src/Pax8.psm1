# Pax8.psm1 - Pax8 partner API client. Relies on Write-Log being available in the session.
$script:Pax8 = @{
    Token=$null; Expiry=[datetime]::MinValue; BaseUrl=$null; TokenUrl=$null; Audience=$null; ClientId=$null; ClientSecret=$null
}
$script:Pax8ProductCache = $null

function Connect-Pax8 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret,
        [string]$TokenUrl = 'https://api.pax8.com/v1/token',
        [string]$BaseUrl  = 'https://api.pax8.com/v1',
        [string]$Audience = 'https://api.pax8.com'
    )
    $script:Pax8.ClientId     = $ClientId
    $script:Pax8.ClientSecret = $ClientSecret
    $script:Pax8.TokenUrl     = $TokenUrl
    $script:Pax8.BaseUrl      = $BaseUrl
    $script:Pax8.Audience     = $Audience
    $null = Get-Pax8Token
    Write-Log -Level INFO -Message 'Connected to Pax8 API.'
}

function Get-Pax8Token {
    [CmdletBinding()] param()
    if ($script:Pax8.Token -and (Get-Date) -lt $script:Pax8.Expiry.AddMinutes(-5)) { return $script:Pax8.Token }
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $script:Pax8.ClientId
        client_secret = $script:Pax8.ClientSecret
        audience      = $script:Pax8.Audience
    } | ConvertTo-Json
    $resp = Invoke-RestMethod -Method Post -Uri $script:Pax8.TokenUrl -ContentType 'application/json' -Body $body
    $script:Pax8.Token  = $resp.access_token
    $ttl = if ($resp.expires_in) { [int]$resp.expires_in } else { 3600 }
    $script:Pax8.Expiry = (Get-Date).AddSeconds($ttl)
    Write-Log -Level INFO -Message 'Pax8 access token acquired.' -Data @{ expiresInSeconds = $ttl }
    return $script:Pax8.Token
}

function Invoke-Pax8 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query,
        [object]$Body
    )
    $uri = $script:Pax8.BaseUrl.TrimEnd('/') + '/' + $Path.TrimStart('/')
    if ($Query -and $Query.Count) {
        $pairs = foreach ($k in $Query.Keys) {
            '{0}={1}' -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Query[$k])
        }
        $uri = $uri + '?' + ($pairs -join '&')
    }
    $headers  = @{ Authorization = "Bearer $(Get-Pax8Token)"; Accept = 'application/json' }
    $jsonBody = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 10 } else { $null }

    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Write-Log -Level INFO -Message ("Pax8 {0} {1}" -f $Method, $Path) -Data @{ query = $Query }
            if ($jsonBody) {
                return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -Body $jsonBody
            }
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
        } catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ($status -eq 429 -and $attempt -lt $maxAttempts) {
                $wait = [math]::Pow(2, $attempt)
                Write-Log -Level WARN -Message ("Pax8 rate limited (429); backing off {0}s." -f $wait)
                Start-Sleep -Seconds $wait
                continue
            }
            # Pax8 returns the actual failure reason (validation message, missing field, traceId) in the
            # HTTP response body, not the exception message. PowerShell 7 surfaces that body on
            # $_.ErrorDetails.Message; fall back to reading the response stream. Without this a 500/422
            # is impossible to diagnose. The order response body carries no secrets (the token is a header).
            $respBody = $null
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $respBody = $_.ErrorDetails.Message
            } elseif ($_.Exception.Response) {
                try { $respBody = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
            }
            Write-Log -Level ERROR -Message ("Pax8 {0} {1} failed ({2}): {3} | body: {4}" -f $Method, $Path, $status, $_.Exception.Message, $respBody) -Data @{ status = $status; responseBody = $respBody }
            throw
        }
    }
}

function Get-Pax8AllPages {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Query)
    $page = 0
    $all  = @()
    do {
        $q = @{}
        if ($Query) { $Query.GetEnumerator() | ForEach-Object { $q[$_.Key] = $_.Value } }
        $q['page'] = $page
        if (-not $q.ContainsKey('size')) { $q['size'] = 200 }
        $resp = Invoke-Pax8 -Method GET -Path $Path -Query $q
        if     ($null -ne $resp.PSObject.Properties['content']) { if ($resp.content) { $all += $resp.content } }
        elseif ($null -ne $resp.PSObject.Properties['value'])   { if ($resp.value)   { $all += $resp.value } }
        elseif ($resp) { $all += $resp }
        $totalPages = if ($resp.page -and $resp.page.totalPages) { [int]$resp.page.totalPages } else { 1 }
        $page++
    } while ($page -lt $totalPages)
    return $all
}

function Get-Pax8Company {
    [CmdletBinding()]
    param([string]$CompanyId, [string]$NameHint)
    if ($CompanyId) { return Invoke-Pax8 -Method GET -Path "companies/$CompanyId" }
    $companies = Get-Pax8AllPages -Path 'companies'
    if ($NameHint) {
        $match = $companies | Where-Object { $_.name -like "*$NameHint*" }
        if ($match) { return ($match | Select-Object -First 1) }
    }
    return $null
}

function Get-Pax8Subscriptions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CompanyId)
    return Get-Pax8AllPages -Path 'subscriptions' -Query @{ companyId = $CompanyId }
}

function Get-Pax8Products {
    [CmdletBinding()] param()
    if ($null -eq $script:Pax8ProductCache) {
        $script:Pax8ProductCache = Get-Pax8AllPages -Path 'products'
        Write-Log -Level INFO -Message ("Cached {0} Pax8 products." -f @($script:Pax8ProductCache).Count)
    }
    return $script:Pax8ProductCache
}

function Resolve-Pax8ProductId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NameHint)
    $products = Get-Pax8Products
    # Exclude non-commercial / special-pricing variants so we land on the standard commercial SKU.
    $excludePattern = 'Government|Governmental|GCC|Non-?Profit|Education|Student|Faculty|Charity|Trial|Promo'
    $cands = $products | Where-Object { $_.name -like "$NameHint*" -and $_.name -notmatch $excludePattern }
    if (-not $cands) { $cands = $products | Where-Object { $_.name -like "*$NameHint*" -and $_.name -notmatch $excludePattern } }
    if (-not $cands) {
        Write-Log -Level WARN -Message ("No Pax8 product matched '{0}'." -f $NameHint)
        return $null
    }
    # Prefer New Commerce Experience, then the shortest (closest to base) name.
    $best = $cands |
        Sort-Object @{ Expression = { if ($_.name -like '*New Commerce Experience*') { 0 } else { 1 } } }, @{ Expression = { $_.name.Length } } |
        Select-Object -First 1
    return $best
}

function Get-Pax8CommitmentTermId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProductId,
        [string]$BillingTerm = 'Annual'
    )
    $map = @{ 'Annual' = '1-Year'; 'Monthly' = 'Monthly'; '2-Year' = '2-Year'; '3-Year' = '3-Year' }
    $wantTerm = if ($map.ContainsKey($BillingTerm)) { $map[$BillingTerm] } else { $BillingTerm }
    $dep = Invoke-Pax8 -Method GET -Path "products/$ProductId/dependencies"
    $ct = $dep.commitmentDependencies | Where-Object { $_.term -eq $wantTerm } | Select-Object -First 1
    if ($ct) {
        Write-Log -Level INFO -Message ("Resolved commitment term '{0}' -> {1} for product {2}." -f $wantTerm, $ct.id, $ProductId)
        return $ct.id
    }
    # Log the terms Pax8 actually offers so a term-string mismatch (e.g. '1-Year' vs 'Annual') is visible
    # instead of silently omitting commitmentTermId, which can make an NCE order fail.
    $availableTerms = @($dep.commitmentDependencies | ForEach-Object { $_.term }) -join ', '
    Write-Log -Level WARN -Message ("No commitment term '{0}' found for product {1}. Terms offered: [{2}]." -f $wantTerm, $ProductId, $availableTerms)
    return $null
}

function Get-MicrosoftProvisioningDetails {
    # Provisioning details for Microsoft NCE orders. Core fields are always sent; per-tenant MCA
    # signatory and Microsoft contact values come from the tenant config's microsoftProvisioning block.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$TenantConfig,
        [Parameter(Mandatory)][string]$LocationMpnId
    )
    $ack = 'I understand, and acknowledge that I will have a 7 calendar day window to cancel my subscription, or make quantity decrements before I am no longer able to make these changes. Once a subscription is locked, I will be required fulfill my elected commitment term of my subscription.'
    $d = [System.Collections.Generic.List[object]]::new()
    $d.Add([ordered]@{ key = 'msCustExists'; values = @('Yes, the customer has and can log into their Microsoft account') })
    $d.Add([ordered]@{ key = 'msTenantId';   values = @($TenantConfig.msTenantId) })
    $d.Add([ordered]@{ key = 'msMPNidval';   values = @($LocationMpnId) })
    $d.Add([ordered]@{ key = 'microsoftCancelPolicyAcknowledgement'; values = @($ack) })
    $mp = $TenantConfig.microsoftProvisioning
    if ($mp) {
        foreach ($k in 'mca2020FirstName','mca2020LastName','mca2020Email','mca2020EffectiveDate','msftContactFirstName','msftContactLastName','msftContactEmail') {
            $v = $mp.$k
            if ($v) { $d.Add([ordered]@{ key = $k; values = @($v) }) }
        }
    }
    return $d.ToArray()
}

function Get-Pax8ErrorText {
    # Turns a caught ErrorRecord into one readable reason for logs, job output and alert emails.
    # Pax8 puts the real failure (validation message, missing field) in the HTTP response body, which
    # PowerShell 7 exposes on ErrorDetails.Message; the exception message alone is just "400 (Bad Request)".
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [int]$MaxLength = 1500
    )
    $parts = [System.Collections.Generic.List[string]]::new()
    $msg = $null
    if ($ErrorRecord -is [string]) { $msg = $ErrorRecord }
    elseif ($ErrorRecord.PSObject.Properties['Exception'] -and $ErrorRecord.Exception) { $msg = $ErrorRecord.Exception.Message }
    if ($msg) { $parts.Add([string]$msg) }

    $body = $null
    if ($ErrorRecord -isnot [string] -and $ErrorRecord.PSObject.Properties['ErrorDetails'] -and $ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = [string]$ErrorRecord.ErrorDetails.Message
    }
    if ($body) {
        $parsed = $null
        try { $parsed = $body | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
        if ($parsed) {
            $bits = [System.Collections.Generic.List[string]]::new()
            if ($parsed.PSObject.Properties['message'] -and $parsed.message) { $bits.Add([string]$parsed.message) }
            if ($parsed.PSObject.Properties['details'] -and $parsed.details) {
                foreach ($d in @($parsed.details)) {
                    if ($d -is [string]) { $bits.Add($d) }
                    elseif ($d.PSObject.Properties['message'] -and $d.message) { $bits.Add([string]$d.message) }
                }
            }
            if ($bits.Count) { $parts.Add('Pax8 said: ' + ($bits -join ' | ')) } else { $parts.Add('Pax8 response: ' + $body) }
        } else {
            $parts.Add('Response body: ' + $body)
        }
    }
    $text = ($parts -join ' || ')
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) + '...(truncated)' }
    return $text
}

function Get-Pax8OverageValue {
    # Exact answer string Pax8 expects for the Microsoft overage enablement question. Read from the
    # product's own provision-details so wording changes on Pax8's side cannot break the order; the
    # constants are only a fallback if that lookup fails.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProductId,
        [ValidateSet('Yes','No')][string]$Choice = 'No'
    )
    $fallback = if ($Choice -eq 'Yes') { 'Yes, my customer has an active Azure Plan subscription through Pax8 to account for any overage charges' } else { 'No, I do not wish to enable overage.' }
    try {
        $resp  = Invoke-Pax8 -Method GET -Path "products/$ProductId/provision-details"
        $items = if ($resp.PSObject.Properties['content']) { $resp.content } else { $resp }
        $def   = $items | Where-Object { $_.key -eq 'microsoftIncludeOverage' } | Select-Object -First 1
        if ($def -and $def.possibleValues) {
            $hit = $def.possibleValues | Where-Object { $_ -match ('^\s*' + $Choice + '\b') } | Select-Object -First 1
            if ($hit) { return [string]$hit }
        }
    } catch {
        Write-Log -Level WARN -Message ("Could not read provision-details for product {0}; using built-in overage wording. Detail: {1}" -f $ProductId, $_.Exception.Message)
    }
    return $fallback
}

function New-Pax8Order {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CompanyId,
        [Parameter(Mandatory)][string]$ProductId,
        [Parameter(Mandatory)][int]$Quantity,
        [string]$BillingTerm = 'Annual',
        [string]$CommitmentTermId,
        [int]$LineItemNumber = 1,
        [array]$ProvisioningDetails,
        [string]$OrderedByUserEmail,
        # Answer used ONLY if Pax8 rejects the order because this product requires the Microsoft overage
        # enablement question (e.g. Teams Phone Standard). There is deliberately NO default: Pax8 applies the
        # election to every overage-eligible product on the customer tenant and it is a billing decision, so it
        # must be set explicitly per tenant (TenantConfig microsoftProvisioning.includeOverage = 'Yes' or 'No').
        # If it is not supplied, the order fails and the reason is reported instead of guessing.
        [ValidateSet('Yes','No')][string]$OverageChoice,
        [switch]$IsMock
    )
    $lineItem = [ordered]@{ lineItemNumber = $LineItemNumber; productId = $ProductId; quantity = $Quantity; billingTerm = $BillingTerm }
    if ($CommitmentTermId) { $lineItem.commitmentTermId = $CommitmentTermId }
    if ($ProvisioningDetails) { $lineItem.provisioningDetails = $ProvisioningDetails }
    $body = [ordered]@{ companyId = $CompanyId; orderedBy = 'Pax8 Partner'; lineItems = @($lineItem) }
    if ($OrderedByUserEmail) { $body.orderedByUserEmail = $OrderedByUserEmail }
    $query = @{}
    if ($IsMock) { $query['isMock'] = 'true' }
    Write-Log -Level ACTION -Message ("Pax8 order product {0} qty {1} (mock={2})" -f $ProductId, $Quantity, [bool]$IsMock) -Data $body
    try {
        return Invoke-Pax8 -Method POST -Path 'orders' -Query $query -Body $body
    } catch {
        $failure = $_
        $reason  = Get-Pax8ErrorText -ErrorRecord $failure
        $alreadySent = $false
        foreach ($item in @($ProvisioningDetails)) { if ($item -and $item.key -eq 'microsoftIncludeOverage') { $alreadySent = $true } }
        # A rejected order creates nothing, so one retry cannot double-buy. Only retry for this one
        # specific, answerable reason; every other failure (and every product that already works) is untouched.
        if ($OverageChoice -and -not $alreadySent -and $reason -match 'overage enablement' -and $reason -match 'required') {
            $answer = Get-Pax8OverageValue -ProductId $ProductId -Choice $OverageChoice
            Write-Log -Level WARN -Message ("Pax8 requires the overage enablement answer for product {0}; retrying once with '{1}'." -f $ProductId, $answer)
            $retryDetails = [System.Collections.Generic.List[object]]::new()
            foreach ($item in @($ProvisioningDetails)) { if ($item) { $retryDetails.Add($item) } }
            $retryDetails.Add([ordered]@{ key = 'microsoftIncludeOverage'; values = @($answer) })
            $lineItem.provisioningDetails = $retryDetails.ToArray()
            $body.lineItems = @($lineItem)
            Write-Log -Level ACTION -Message ("Pax8 order RETRY product {0} qty {1} (mock={2}) with overage answer" -f $ProductId, $Quantity, [bool]$IsMock) -Data $body
            return Invoke-Pax8 -Method POST -Path 'orders' -Query $query -Body $body
        }
        throw
    }
}

function Search-Pax8Products {
    # Search the cached product list by a plain-text term.
    # Used by the onboarding wizard. Excludes non-commercial variants.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SearchTerm)
    $products = Get-Pax8Products
    $exclude  = 'Government|Governmental|GCC|Non-?Profit|Education|Student|Faculty|Charity|Trial|Promo'
    $term     = [regex]::Escape($SearchTerm.Trim())
    $results  = $products | Where-Object {
        $_.name -match "(?i)$term" -and $_.name -notmatch $exclude
    } | Sort-Object @{
        Expression = { if ($_.name -like '*New Commerce Experience*') { 0 } else { 1 } }
    }, @{
        Expression = { $_.name.Length }
    } | Select-Object -First 50
    Write-Log -Level INFO -Message ("Pax8 product search '{0}': {1} results" -f $SearchTerm, @($results).Count)
    return @($results)
}

function Set-Pax8SubscriptionQuantity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][int]$Quantity
    )
    # VERIFY exact shape against Pax8 docs/sandbox during testing before enabling live runs.
    $body = [ordered]@{ quantity = $Quantity }
    Write-Log -Level ACTION -Message ("Pax8 set subscription {0} quantity {1}" -f $SubscriptionId, $Quantity) -Data $body
    return Invoke-Pax8 -Method PUT -Path "subscriptions/$SubscriptionId" -Body $body
}

Export-ModuleMember -Function Connect-Pax8, Get-Pax8Token, Invoke-Pax8, Get-Pax8AllPages, Get-Pax8Company, Get-Pax8Subscriptions, Get-Pax8Products, Resolve-Pax8ProductId, Search-Pax8Products, Get-Pax8CommitmentTermId, Get-MicrosoftProvisioningDetails, New-Pax8Order, Set-Pax8SubscriptionQuantity, Get-Pax8ErrorText, Get-Pax8OverageValue
