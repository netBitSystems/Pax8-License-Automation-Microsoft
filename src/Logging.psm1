# Logging.psm1 - structured logging used by every other module.
$script:LogFile = $null
$script:RunId   = $null

function Initialize-LogContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$TenantKey
    )
    try {
        if (-not (Test-Path $Directory)) { New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null }
    } catch {
        # Configured path is not writable (e.g. the Azure Automation sandbox); fall back to temp.
        $Directory = Join-Path $env:TEMP 'Pax8LicenseAutomation-logs'
        if (-not (Test-Path $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    }
    $script:RunId   = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $TenantKey
    $script:LogFile = Join-Path $Directory ("licensesync-{0}.jsonl" -f $script:RunId)
    return $script:LogFile
}

function Write-Log {
    [CmdletBinding()]
    param(
        [ValidateSet('INFO','WARN','ERROR','ACTION','DECISION')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message,
        [object]$Data
    )
    $entry = [ordered]@{
        ts      = (Get-Date).ToString('o')
        runId   = $script:RunId
        level   = $Level
        message = $Message
    }
    if ($PSBoundParameters.ContainsKey('Data') -and $null -ne $Data) { $entry.data = $Data }
    $json = $entry | ConvertTo-Json -Depth 8 -Compress
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $json -Encoding UTF8 }
    $color = switch ($Level) {
        'ERROR'    { 'Red' }
        'WARN'     { 'Yellow' }
        'ACTION'   { 'Cyan' }
        'DECISION' { 'Green' }
        default    { 'Gray' }
    }
    Write-Host ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
}

Export-ModuleMember -Function Initialize-LogContext, Write-Log
