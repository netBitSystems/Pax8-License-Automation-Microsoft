# Graph.psm1 - read-only Microsoft Graph access. Relies on Write-Log being available in the session.
function Connect-GraphRead {
    [CmdletBinding()]
    param(
        [string[]]$Scopes = @('Organization.Read.All','Directory.Read.All'),
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$CertificateThumbprint,
        [switch]$UseManagedIdentity,
        [switch]$UseDeviceCode
    )
    foreach ($m in 'Microsoft.Graph.Authentication','Microsoft.Graph.Identity.DirectoryManagement') {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Install-Module $m -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
        }
        Import-Module $m -ErrorAction Stop
    }
    if ($UseManagedIdentity) {
        if ($ClientId) { Connect-MgGraph -Identity -ClientId $ClientId -NoWelcome } else { Connect-MgGraph -Identity -NoWelcome }
        $mode = 'ManagedIdentity'
    } elseif ($ClientId -and $TenantId -and $CertificateThumbprint) {
        Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome
        $mode = 'AppCertificate'
    } elseif ($ClientId -and $TenantId -and $ClientSecret) {
        $sec  = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
        $cred = [System.Management.Automation.PSCredential]::new($ClientId, $sec)
        # -ClientSecretCredential already carries the client id as its user name; do not also pass -ClientId.
        Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $cred -NoWelcome
        $mode = 'AppSecret'
    } elseif ($UseDeviceCode) {
        Connect-MgGraph -Scopes $Scopes -UseDeviceAuthentication -NoWelcome
        $mode = 'DeviceCode'
    } else {
        Connect-MgGraph -Scopes $Scopes -NoWelcome
        $mode = 'Interactive'
    }
    $ctx = Get-MgContext
    Write-Log -Level INFO -Message ("Connected to Graph ({0}) as {1}" -f $mode, $ctx.Account) -Data @{ tenantId = $ctx.TenantId; authMode = $mode }
    return $ctx
}

function Get-TenantSkuSummary {
    [CmdletBinding()] param()
    Get-MgSubscribedSku -All | ForEach-Object {
        [pscustomobject]@{
            SkuId         = $_.SkuId
            SkuPartNumber = $_.SkuPartNumber
            Enabled       = [int]$_.PrepaidUnits.Enabled
            Consumed      = [int]$_.ConsumedUnits
        }
    }
}

function Get-TenantSubscriptionRenewals {
    [CmdletBinding()] param()
    $resp = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/beta/directory/subscriptions'
    return $resp.value
}

Export-ModuleMember -Function Connect-GraphRead, Get-TenantSkuSummary, Get-TenantSubscriptionRenewals
