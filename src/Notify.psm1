# Notify.psm1 - run notifications. Email uses Microsoft Graph sendMail; Teams uses an incoming webhook.
# Relies on Write-Log and (for email) an active Microsoft Graph connection.
function Send-LicenseAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AlertConfig,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body
    )
    if (-not $AlertConfig -or -not $AlertConfig.method -or $AlertConfig.method -eq 'none') { return }
    if (-not $AlertConfig.target) { Write-Log -Level WARN -Message 'alert.target not set; skipping notification.'; return }

    switch ($AlertConfig.method) {
        'email' {
            $from = $AlertConfig.fromMailbox
            if (-not $from) { Write-Log -Level WARN -Message 'alert.fromMailbox not set; cannot send email alert.'; return }
            $payload = @{
                message = @{
                    subject      = $Subject
                    body         = @{ contentType = 'Text'; content = $Body }
                    toRecipients = @(@{ emailAddress = @{ address = $AlertConfig.target } })
                }
                saveToSentItems = $false
            }
            try {
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$from/sendMail" -Body ($payload | ConvertTo-Json -Depth 10) | Out-Null
                Write-Log -Level INFO -Message ("Alert email sent to {0}." -f $AlertConfig.target)
            } catch {
                Write-Log -Level WARN -Message ("Email alert failed. The Graph app needs Mail.Send (application) granted and consented, and '{0}' must be a real mailbox. Detail: {1}" -f $from, $_.Exception.Message)
            }
        }
        'teams' {
            try {
                Invoke-RestMethod -Method POST -Uri $AlertConfig.target -ContentType 'application/json' -Body (@{ text = ("{0}`n`n{1}" -f $Subject, $Body) } | ConvertTo-Json) | Out-Null
                Write-Log -Level INFO -Message 'Alert posted to Teams webhook.'
            } catch {
                Write-Log -Level WARN -Message ("Teams alert failed: {0}" -f $_.Exception.Message)
            }
        }
        default { Write-Log -Level WARN -Message ("Unknown alert.method '{0}'." -f $AlertConfig.method) }
    }
}

Export-ModuleMember -Function Send-LicenseAlert
