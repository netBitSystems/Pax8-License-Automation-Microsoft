<#
.SYNOPSIS
  GUI wizard to create a new tenant configuration file for Pax8 License Automation.
.DESCRIPTION
  Four-page Windows Forms wizard:
    Page 1 - Client details (name, tenant ID, Pax8 company, MCA signatory, MS contact)
    Page 2 - License selection (manual catalog picker or load from Microsoft Graph)
    Page 3 - Pax8 product matching (live search dialog per license)
    Page 4 - JSON review and save
  Requires Pax8 credentials stored via Set-Credentials.ps1.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- Imports ----------
Import-Module (Join-Path $scriptRoot 'src\Logging.psm1')  -Force
Import-Module (Join-Path $scriptRoot 'src\Pax8.psm1')     -Force
Import-Module (Join-Path $scriptRoot 'src\Graph.psm1')    -Force

$settings    = Get-Content (Join-Path $scriptRoot 'config\settings.json')    -Raw | ConvertFrom-Json
$catalogData = Get-Content (Join-Path $scriptRoot 'config\sku-catalog.json') -Raw | ConvertFrom-Json
$catalog     = $catalogData.licenses

# Log to temp so the wizard doesn't require the project log dir to exist yet
Initialize-LogContext -Directory (Join-Path $env:TEMP 'Pax8LicenseWizard') -TenantKey 'wizard' | Out-Null

# ---------- Credentials ----------
function _Plain([System.Security.SecureString]$s) {
    if ($s) { [System.Net.NetworkCredential]::new('', $s).Password }
}

# Try env vars first, then the encrypted local store (may fail if run as a different user)
$pax8ClientId  = $env:PAX8_CLIENT_ID
$pax8Secret    = $env:PAX8_CLIENT_SECRET
$graphClientId = $env:GRAPH_CLIENT_ID
$graphSecret   = $env:GRAPH_CLIENT_SECRET

if (-not $pax8ClientId) {
    try {
        $credFile = Join-Path $scriptRoot 'config\credentials.local.xml'
        if (Test-Path $credFile) {
            $local = Import-Clixml $credFile
            $pax8ClientId  = $local.Pax8ClientId
            $pax8Secret    = _Plain $local.Pax8ClientSecret
            $graphClientId = $local.GraphClientId
            $graphSecret   = _Plain $local.GraphClientSecret
        }
    } catch {
        # DPAPI-encrypted file is not readable by this user account — will prompt below
    }
}

# If credentials still missing, show a credential entry dialog
if (-not $pax8ClientId) {
    $cdlg = New-Object System.Windows.Forms.Form
    $cdlg.Text = 'Pax8 License Automation - Enter API Credentials'
    $cdlg.Size = New-Object System.Drawing.Size(520, 400)
    $cdlg.StartPosition = 'CenterScreen'
    $cdlg.FormBorderStyle = 'FixedDialog'
    $cdlg.MaximizeBox = $false
    $cdlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $cHdr = New-Object System.Windows.Forms.Panel
    $cHdr.Dock = 'Top'; $cHdr.Height = 52
    $cHdr.BackColor = [System.Drawing.Color]::FromArgb(0, 102, 180)
    $cHdrLbl = New-Object System.Windows.Forms.Label
    $cHdrLbl.Text = 'API Credentials'
    $cHdrLbl.ForeColor = [System.Drawing.Color]::White
    $cHdrLbl.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $cHdrLbl.Location = New-Object System.Drawing.Point(14, 14)
    $cHdrLbl.AutoSize = $true
    $cHdr.Controls.Add($cHdrLbl)
    $cdlg.Controls.Add($cHdr)

    $cBody = New-Object System.Windows.Forms.Panel
    $cBody.Location = New-Object System.Drawing.Point(20, 62)
    $cBody.Size = New-Object System.Drawing.Size(470, 270)
    $cdlg.Controls.Add($cBody)

    $cNote = New-Object System.Windows.Forms.Label
    $cNote.Text = 'Enter your Pax8 API credentials. Graph credentials are optional and only needed to auto-load licenses for an existing client.'
    $cNote.Location = New-Object System.Drawing.Point(0, 0)
    $cNote.Size = New-Object System.Drawing.Size(470, 36)
    $cNote.ForeColor = [System.Drawing.Color]::DimGray
    $cBody.Controls.Add($cNote)

    function cLbl($text, $y) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Location = New-Object System.Drawing.Point(0, $y)
        $l.Size = New-Object System.Drawing.Size(160, 20)
        $cBody.Controls.Add($l)
    }
    function cTxt($y, [switch]$Password) {
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point(165, ($y - 2))
        $t.Size = New-Object System.Drawing.Size(300, 25)
        if ($Password) { $t.UseSystemPasswordChar = $true }
        $cBody.Controls.Add($t); return $t
    }

    cLbl 'Pax8 Client ID *'     48
    cLbl 'Pax8 Client Secret *' 80
    cLbl 'Graph Client ID'      122
    cLbl 'Graph Client Secret'  154
    $cPax8Id  = cTxt 46
    $cPax8Sec = cTxt 78  -Password
    $cGrphId  = cTxt 120
    $cGrphSec = cTxt 152 -Password

    $cSep = New-Object System.Windows.Forms.Label
    $cSep.Location = New-Object System.Drawing.Point(0, 102); $cSep.Size = New-Object System.Drawing.Size(470, 1)
    $cSep.BackColor = [System.Drawing.Color]::LightGray
    $cBody.Controls.Add($cSep)

    $cReq = New-Object System.Windows.Forms.Label
    $cReq.Text = '* Required   |   Pax8: portal.pax8.com > Integrations > API Credentials'
    $cReq.Location = New-Object System.Drawing.Point(0, 196)
    $cReq.Size = New-Object System.Drawing.Size(470, 18)
    $cReq.ForeColor = [System.Drawing.Color]::Gray
    $cBody.Controls.Add($cReq)

    $cOk = New-Object System.Windows.Forms.Button
    $cOk.Text = 'Connect'; $cOk.Size = New-Object System.Drawing.Size(90, 30)
    $cOk.Location = New-Object System.Drawing.Point(300, 340)
    $cOk.BackColor = [System.Drawing.Color]::FromArgb(0, 102, 180)
    $cOk.ForeColor = [System.Drawing.Color]::White
    $cOk.FlatStyle = 'Flat'
    $cOk.DialogResult = 'OK'
    $cdlg.Controls.Add($cOk)

    $cCancel = New-Object System.Windows.Forms.Button
    $cCancel.Text = 'Cancel'; $cCancel.Size = New-Object System.Drawing.Size(90, 30)
    $cCancel.Location = New-Object System.Drawing.Point(400, 340)
    $cCancel.DialogResult = 'Cancel'
    $cdlg.Controls.Add($cCancel)

    $cdlg.AcceptButton = $cOk
    $cdlg.CancelButton = $cCancel

    $cOk.Add_Click({
        if (-not $cPax8Id.Text.Trim() -or -not $cPax8Sec.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show('Pax8 Client ID and Secret are required.', 'Required', 'OK', 'Warning') | Out-Null
            $cdlg.DialogResult = 'None'
        }
    })

    if ($cdlg.ShowDialog() -ne 'OK') { exit 0 }

    $pax8ClientId  = $cPax8Id.Text.Trim()
    $pax8Secret    = $cPax8Sec.Text.Trim()
    $graphClientId = $cGrphId.Text.Trim()
    $graphSecret   = $cGrphSec.Text.Trim()
    $cdlg.Dispose()
}

# ---------- Connect to Pax8 ----------
try {
    Connect-Pax8 -ClientId $pax8ClientId -ClientSecret $pax8Secret `
        -TokenUrl $settings.pax8.tokenUrl -BaseUrl $settings.pax8.baseUrl -Audience $settings.pax8.audience
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Failed to connect to Pax8:`n$($_.Exception.Message)",
        "Pax8 Connection Failed", 'OK', 'Error') | Out-Null
    exit 1
}

# ---------- Pre-warm product cache ----------
$splash = New-Object System.Windows.Forms.Form
$splash.Text = 'Pax8 License Automation'
$splash.Size = New-Object System.Drawing.Size(400, 100)
$splash.StartPosition = 'CenterScreen'
$splash.FormBorderStyle = 'FixedToolWindow'
$splash.ControlBox = $false
$splashLbl = New-Object System.Windows.Forms.Label
$splashLbl.Text = 'Loading Pax8 product catalog, please wait...'
$splashLbl.Dock = 'Fill'
$splashLbl.TextAlign = 'MiddleCenter'
$splashLbl.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$splash.Controls.Add($splashLbl)
$splash.Show(); $splash.Refresh()
try { $null = Get-Pax8Products } catch { }
$splash.Close(); $splash.Dispose()

# =====================================================================
# Wizard state
# =====================================================================
$script:currentPage  = 0
$script:pax8Sel      = @{}   # row-index -> @{ id; name }
$script:selectedSkus = @()   # ordered array of catalog-entry objects for selected licenses

# =====================================================================
# Product search dialog
# =====================================================================
function Show-ProductSearchDialog {
    param([string]$InitialSearch = '')

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Find Pax8 Product'
    $dlg.Size = New-Object System.Drawing.Size(660, 510)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = 'Search (type product name and press Enter or click Search):'
    $lblSearch.Location = New-Object System.Drawing.Point(10, 12)
    $lblSearch.Size = New-Object System.Drawing.Size(630, 20)

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(10, 36)
    $txtSearch.Size = New-Object System.Drawing.Size(510, 25)
    $txtSearch.Text = $InitialSearch

    $btnSearch = New-Object System.Windows.Forms.Button
    $btnSearch.Text = 'Search'
    $btnSearch.Location = New-Object System.Drawing.Point(530, 34)
    $btnSearch.Size = New-Object System.Drawing.Size(100, 28)

    $lstResults = New-Object System.Windows.Forms.ListBox
    $lstResults.Location = New-Object System.Drawing.Point(10, 72)
    $lstResults.Size = New-Object System.Drawing.Size(620, 360)
    $lstResults.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lstResults.HorizontalScrollbar = $true

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = 'Double-click a product or select one and click OK.'
    $lblHint.Location = New-Object System.Drawing.Point(10, 440)
    $lblHint.Size = New-Object System.Drawing.Size(420, 18)
    $lblHint.ForeColor = [System.Drawing.Color]::Gray

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'OK'
    $btnOk.Location = New-Object System.Drawing.Point(450, 436)
    $btnOk.Size = New-Object System.Drawing.Size(80, 28)
    $btnOk.DialogResult = 'OK'
    $btnOk.Enabled = $false

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(540, 436)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 28)
    $btnCancel.DialogResult = 'Cancel'

    $dlg.Controls.AddRange(@($lblSearch, $txtSearch, $btnSearch, $lstResults, $lblHint, $btnOk, $btnCancel))
    $dlg.AcceptButton = $btnSearch
    $dlg.CancelButton = $btnCancel

    $script:dlgResults = @()

    $doSearch = {
        $term = $txtSearch.Text.Trim()
        if ($term.Length -lt 2) {
            [System.Windows.Forms.MessageBox]::Show("Enter at least 2 characters.", "Search", 'OK', 'Information') | Out-Null
            return
        }
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try { $script:dlgResults = @(Search-Pax8Products -SearchTerm $term) } catch { $script:dlgResults = @() }
        $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
        $lstResults.Items.Clear()
        $btnOk.Enabled = $false
        if ($script:dlgResults.Count -eq 0) {
            $lstResults.Items.Add('No results. Try a shorter or different search term.')
        } else {
            foreach ($r in $script:dlgResults) { $lstResults.Items.Add($r.name) }
        }
    }

    $btnSearch.Add_Click($doSearch)

    $lstResults.Add_SelectedIndexChanged({
        $btnOk.Enabled = ($lstResults.SelectedIndex -ge 0 -and $script:dlgResults.Count -gt 0 -and
                          $lstResults.SelectedIndex -lt $script:dlgResults.Count)
    })

    $lstResults.Add_DoubleClick({
        if ($lstResults.SelectedIndex -ge 0 -and $script:dlgResults.Count -gt 0) {
            $dlg.DialogResult = 'OK'; $dlg.Close()
        }
    })

    if ($InitialSearch.Length -ge 2) { $dlg.Add_Shown({ & $doSearch }) }

    $result = $dlg.ShowDialog()
    $dlg.Dispose()

    if ($result -eq 'OK' -and $lstResults.SelectedIndex -ge 0 -and
        $lstResults.SelectedIndex -lt $script:dlgResults.Count) {
        return $script:dlgResults[$lstResults.SelectedIndex]
    }
    return $null
}

# =====================================================================
# Main form
# =====================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Pax8 License Automation — New Client Setup'
$form.Size = New-Object System.Drawing.Size(860, 720)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# ----- Header -----
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = 'Top'
$pnlHeader.Height = 62
$pnlHeader.BackColor = [System.Drawing.Color]::FromArgb(0, 102, 180)
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object System.Drawing.Point(15, 8)
$lblTitle.AutoSize = $true
$pnlHeader.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(190, 220, 255)
$lblSub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$lblSub.Location = New-Object System.Drawing.Point(16, 36)
$lblSub.AutoSize = $true
$pnlHeader.Controls.Add($lblSub)

# ----- Footer -----
$pnlFooter = New-Object System.Windows.Forms.Panel
$pnlFooter.Dock = 'Bottom'
$pnlFooter.Height = 52
$pnlFooter.BackColor = [System.Drawing.Color]::WhiteSmoke
$form.Controls.Add($pnlFooter)

$pnlFooterLine = New-Object System.Windows.Forms.Label
$pnlFooterLine.Dock = 'Top'
$pnlFooterLine.Height = 1
$pnlFooterLine.BackColor = [System.Drawing.Color]::LightGray
$pnlFooter.Controls.Add($pnlFooterLine)

$btnNext = New-Object System.Windows.Forms.Button
$btnNext.Text = 'Next >'
$btnNext.Size = New-Object System.Drawing.Size(95, 32)
$btnNext.Location = New-Object System.Drawing.Point(745, 10)
$btnNext.BackColor = [System.Drawing.Color]::FromArgb(0, 102, 180)
$btnNext.ForeColor = [System.Drawing.Color]::White
$btnNext.FlatStyle = 'Flat'
$pnlFooter.Controls.Add($btnNext)

$btnBack = New-Object System.Windows.Forms.Button
$btnBack.Text = '< Back'
$btnBack.Size = New-Object System.Drawing.Size(95, 32)
$btnBack.Location = New-Object System.Drawing.Point(640, 10)
$btnBack.Enabled = $false
$pnlFooter.Controls.Add($btnBack)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(10, 16)
$lblStatus.Size = New-Object System.Drawing.Size(540, 20)
$lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
$lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$pnlFooter.Controls.Add($lblStatus)

# ----- Content panel -----
$pnlContent = New-Object System.Windows.Forms.Panel
$pnlContent.Dock = 'Fill'
$form.Controls.Add($pnlContent)

# =====================================================================
# PAGE 1 — Client Details
# =====================================================================
$pg1 = New-Object System.Windows.Forms.Panel
$pg1.Dock = 'Fill'
$pnlContent.Controls.Add($pg1)

$pg1scroll = New-Object System.Windows.Forms.Panel
$pg1scroll.AutoScroll = $true
$pg1scroll.Dock = 'Fill'
$pg1.Controls.Add($pg1scroll)

$pg1inner = New-Object System.Windows.Forms.Panel
$pg1inner.Location = New-Object System.Drawing.Point(20, 10)
$pg1inner.Size = New-Object System.Drawing.Size(780, 680)
$pg1scroll.Controls.Add($pg1inner)

function Add-Label { param($Parent, $Text, $X, $Y, $W = 190, [switch]$Bold)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, ($Y + 4))
    $l.Size = New-Object System.Drawing.Size($W, 20)
    if ($Bold) { $l.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold) }
    $Parent.Controls.Add($l)
}
function Add-TextBox { param($Parent, $X, $Y, $W = 340)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Size = New-Object System.Drawing.Size($W, 25)
    $Parent.Controls.Add($t)
    return $t
}
function Add-Divider { param($Parent, $Y)
    $d = New-Object System.Windows.Forms.Label
    $d.Location = New-Object System.Drawing.Point(0, $Y)
    $d.Size = New-Object System.Drawing.Size(760, 1)
    $d.BackColor = [System.Drawing.Color]::FromArgb(0, 102, 180)
    $Parent.Controls.Add($d)
}

Add-Label  $pg1inner 'Client Information'  0  0  -Bold
Add-Divider $pg1inner 22
Add-Label  $pg1inner 'Display Name *'          0  30
Add-Label  $pg1inner 'Tenant Key *'             0  62  190
Add-Label  $pg1inner '  (short ID, no spaces)'  190  66  180
Add-Label  $pg1inner 'Microsoft Tenant ID *'    0  94
Add-Label  $pg1inner 'Default Domain *'         0  126
$txtName   = Add-TextBox $pg1inner 200 28
$txtKey    = Add-TextBox $pg1inner 200 60
$txtTid    = Add-TextBox $pg1inner 200 92
$txtDomain = Add-TextBox $pg1inner 200 124

# Auto-generate tenant key from display name
$txtName.Add_TextChanged({
    if ($txtKey.Tag -ne 'manual') {
        $safe = ($txtName.Text -replace '[^a-zA-Z0-9]', '').ToLower()
        if ($safe.Length -gt 20) { $safe = $safe.Substring(0, 20) }
        $txtKey.Text = $safe
        $txtKey.Tag = 'auto'
    }
})
$txtKey.Add_TextChanged({ if ($txtKey.Focused) { $txtKey.Tag = 'manual' } })

Add-Label  $pg1inner 'Pax8'                          0  162  -Bold
Add-Divider $pg1inner 184
Add-Label  $pg1inner 'Pax8 Company ID (GUID)'        0  192
Add-Label  $pg1inner 'Pax8 Company Name'             0  224
Add-Label  $pg1inner '  (used if ID is blank)'       190  228  200
$txtPax8Id   = Add-TextBox $pg1inner 200 190
$txtPax8Name = Add-TextBox $pg1inner 200 222

$chkGreenfield = New-Object System.Windows.Forms.CheckBox
$chkGreenfield.Text = 'Greenfield — new client with no existing Microsoft subscriptions (automation will order all configured licenses immediately)'
$chkGreenfield.Location = New-Object System.Drawing.Point(0, 258)
$chkGreenfield.Size = New-Object System.Drawing.Size(760, 22)
$pg1inner.Controls.Add($chkGreenfield)

Add-Label  $pg1inner 'MCA Signatory'             0  292  -Bold
Add-Divider $pg1inner 314
Add-Label  $pg1inner 'First Name *'              0  322
Add-Label  $pg1inner 'Last Name *'               0  354
Add-Label  $pg1inner 'Email *'                   0  386
Add-Label  $pg1inner 'Effective Date *'          0  418
Add-Label  $pg1inner '  (YYYY-MM-DD)'            190  422  170
$txtMcaFirst = Add-TextBox $pg1inner 200 320
$txtMcaLast  = Add-TextBox $pg1inner 200 352
$txtMcaEmail = Add-TextBox $pg1inner 200 384
$txtMcaDate  = Add-TextBox $pg1inner 200 416 180

Add-Label  $pg1inner 'Microsoft Contact'         0  454  -Bold
Add-Divider $pg1inner 476
Add-Label  $pg1inner 'First Name *'              0  484
Add-Label  $pg1inner 'Last Name *'               0  516
Add-Label  $pg1inner 'Email *'                   0  548
$txtMsFirst = Add-TextBox $pg1inner 200 482
$txtMsLast  = Add-TextBox $pg1inner 200 514
$txtMsEmail = Add-TextBox $pg1inner 200 546

$lblReqNote = New-Object System.Windows.Forms.Label
$lblReqNote.Text = '* Required'
$lblReqNote.Location = New-Object System.Drawing.Point(0, 590)
$lblReqNote.AutoSize = $true
$lblReqNote.ForeColor = [System.Drawing.Color]::Gray
$pg1inner.Controls.Add($lblReqNote)

# =====================================================================
# PAGE 2 — License Selection
# =====================================================================
$pg2 = New-Object System.Windows.Forms.Panel
$pg2.Dock = 'Fill'
$pg2.Visible = $false
$pnlContent.Controls.Add($pg2)

$rdoNew = New-Object System.Windows.Forms.RadioButton
$rdoNew.Text = 'New client — select licenses manually from the catalog below'
$rdoNew.Location = New-Object System.Drawing.Point(20, 14)
$rdoNew.Size = New-Object System.Drawing.Size(760, 22)
$rdoNew.Checked = $true
$pg2.Controls.Add($rdoNew)

$rdoExisting = New-Object System.Windows.Forms.RadioButton
$rdoExisting.Text = 'Existing client — load current licenses from Microsoft Graph and pre-select matches'
$rdoExisting.Location = New-Object System.Drawing.Point(20, 40)
$rdoExisting.Size = New-Object System.Drawing.Size(760, 22)
$pg2.Controls.Add($rdoExisting)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = 'Load from Microsoft'
$btnLoad.Location = New-Object System.Drawing.Point(20, 68)
$btnLoad.Size = New-Object System.Drawing.Size(165, 28)
$btnLoad.Enabled = $false
$pg2.Controls.Add($btnLoad)

$lblLoadStatus = New-Object System.Windows.Forms.Label
$lblLoadStatus.Location = New-Object System.Drawing.Point(195, 74)
$lblLoadStatus.Size = New-Object System.Drawing.Size(560, 18)
$lblLoadStatus.ForeColor = [System.Drawing.Color]::Gray
$pg2.Controls.Add($lblLoadStatus)

$rdoExisting.Add_CheckedChanged({ $btnLoad.Enabled = $rdoExisting.Checked })

$lblPickHint = New-Object System.Windows.Forms.Label
$lblPickHint.Text = 'Check each license you want to manage for this client:'
$lblPickHint.Location = New-Object System.Drawing.Point(20, 104)
$lblPickHint.AutoSize = $true
$lblPickHint.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$pg2.Controls.Add($lblPickHint)

$lvLicenses = New-Object System.Windows.Forms.ListView
$lvLicenses.Location = New-Object System.Drawing.Point(20, 126)
$lvLicenses.Size = New-Object System.Drawing.Size(800, 440)
$lvLicenses.View = 'Details'
$lvLicenses.CheckBoxes = $true
$lvLicenses.FullRowSelect = $true
$lvLicenses.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$lvLicenses.Columns.Add('License Name', 430) | Out-Null
$lvLicenses.Columns.Add('Category', 210) | Out-Null
$pg2.Controls.Add($lvLicenses)

# Populate from catalog, grouped
$script:lvGroups = @{}
foreach ($entry in $catalog) {
    if (-not $script:lvGroups.ContainsKey($entry.category)) {
        $grp = New-Object System.Windows.Forms.ListViewGroup($entry.category, $entry.category)
        $lvLicenses.Groups.Add($grp) | Out-Null
        $script:lvGroups[$entry.category] = $grp
    }
    $item = New-Object System.Windows.Forms.ListViewItem($entry.displayName)
    $item.SubItems.Add($entry.category) | Out-Null
    $item.Group = $script:lvGroups[$entry.category]
    $item.Tag = $entry
    $lvLicenses.Items.Add($item) | Out-Null
}

$script:uncatGroup = New-Object System.Windows.Forms.ListViewGroup('Discovered (not in catalog)', 'Discovered (not in catalog)')
$lvLicenses.Groups.Add($script:uncatGroup) | Out-Null

# Load from Graph handler
$btnLoad.Add_Click({
    if (-not $graphClientId) {
        [System.Windows.Forms.MessageBox]::Show("Graph credentials not found. Run Set-Credentials.ps1.", "Missing Credentials", 'OK', 'Warning') | Out-Null
        return
    }
    $tenantId = $txtTid.Text.Trim()
    if (-not $tenantId) {
        [System.Windows.Forms.MessageBox]::Show("Enter the Microsoft Tenant ID on Page 1 first.", "Tenant ID Required", 'OK', 'Warning') | Out-Null
        return
    }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $lblLoadStatus.ForeColor = [System.Drawing.Color]::Gray
    $lblLoadStatus.Text = 'Connecting to Microsoft Graph...'
    $form.Refresh()
    try {
        Connect-GraphRead -TenantId $tenantId -ClientId $graphClientId -ClientSecret $graphSecret | Out-Null
        $skus = Get-TenantSkuSummary

        # Reset
        foreach ($item in $lvLicenses.Items) { $item.Checked = $false }
        @($lvLicenses.Items | Where-Object { $_.Group -eq $script:uncatGroup }) | ForEach-Object { $lvLicenses.Items.Remove($_) }

        $matched = 0; $unmatched = 0
        foreach ($sku in $skus) {
            $found = $lvLicenses.Items | Where-Object { $_.Tag -and $_.Tag.skuPartNumber -eq $sku.SkuPartNumber } | Select-Object -First 1
            if ($found) {
                $found.Checked = $true; $matched++
            } else {
                $unknownEntry = [pscustomobject]@{
                    category='Discovered (not in catalog)'; skuPartNumber=$sku.SkuPartNumber
                    skuId=$sku.SkuId; displayName=$sku.SkuPartNumber; defaultBuffer=2; defaultMaxSeats=100
                }
                $item2 = New-Object System.Windows.Forms.ListViewItem($sku.SkuPartNumber)
                $item2.SubItems.Add('Discovered') | Out-Null
                $item2.Group = $script:uncatGroup
                $item2.Tag = $unknownEntry
                $item2.Checked = $true
                $lvLicenses.Items.Add($item2) | Out-Null
                $unmatched++
            }
        }
        $lblLoadStatus.ForeColor = [System.Drawing.Color]::DarkGreen
        $lblLoadStatus.Text = "$matched catalog matches found.  $unmatched uncatalogued SKUs added at bottom (review before continuing)."
    } catch {
        $lblLoadStatus.ForeColor = [System.Drawing.Color]::Firebrick
        $lblLoadStatus.Text = "Graph error: $($_.Exception.Message)"
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
})

# =====================================================================
# PAGE 3 — Pax8 Product Matching
# =====================================================================
$pg3 = New-Object System.Windows.Forms.Panel
$pg3.Dock = 'Fill'
$pg3.Visible = $false
$pnlContent.Controls.Add($pg3)

$lblP3hint = New-Object System.Windows.Forms.Label
$lblP3hint.Text = "Click Find for each license to search the live Pax8 product catalog and pick the correct product. Buffer = spare seats kept available above current usage."
$lblP3hint.Location = New-Object System.Drawing.Point(20, 10)
$lblP3hint.Size = New-Object System.Drawing.Size(800, 34)
$pg3.Controls.Add($lblP3hint)

$dgv = New-Object System.Windows.Forms.DataGridView
$dgv.Location = New-Object System.Drawing.Point(20, 50)
$dgv.Size = New-Object System.Drawing.Size(800, 530)
$dgv.AllowUserToAddRows = $false
$dgv.AllowUserToDeleteRows = $false
$dgv.RowHeadersVisible = $false
$dgv.SelectionMode = 'FullRowSelect'
$dgv.MultiSelect = $false
$dgv.AutoSizeRowsMode = 'AllCells'
$dgv.ColumnHeadersHeightSizeMode = 'AutoSize'
$dgv.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$dgv.BackgroundColor = [System.Drawing.Color]::White
$dgv.GridColor = [System.Drawing.Color]::LightGray
$dgv.BorderStyle = 'Fixed3D'
$dgv.RowTemplate.Height = 26

$dgvCols = @(
    @{ Name='LicenseName'; Header='License';      Width=210; RO=$true  },
    @{ Name='Status';      Header='Status';       Width=85;  RO=$true  },
    @{ Name='Pax8Product'; Header='Pax8 Product'; Width=275; RO=$true  },
    @{ Name='Buffer';      Header='Buffer';       Width=60;  RO=$false },
    @{ Name='MaxSeats';    Header='Max Seats';    Width=80;  RO=$false }
)
foreach ($c in $dgvCols) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $c.Name; $col.HeaderText = $c.Header; $col.Width = $c.Width; $col.ReadOnly = $c.RO
    if ($c.Name -eq 'Pax8Product') { $col.DefaultCellStyle.WrapMode = 'True' }
    $dgv.Columns.Add($col) | Out-Null
}
$btnCol = New-Object System.Windows.Forms.DataGridViewButtonColumn
$btnCol.Name = 'FindBtn'; $btnCol.HeaderText = ''; $btnCol.Text = 'Find...'
$btnCol.UseColumnTextForButtonValue = $true; $btnCol.Width = 65
$dgv.Columns.Add($btnCol) | Out-Null

$pg3.Controls.Add($dgv)

$dgv.Add_CellClick({
    param($s, $e)
    if ($e.ColumnIndex -ne $dgv.Columns['FindBtn'].Index -or $e.RowIndex -lt 0) { return }
    $row = $dgv.Rows[$e.RowIndex]
    $searchTerm = ($row.Cells['LicenseName'].Value -replace '\s*\(.*\)\s*$', '').Trim()
    $product = Show-ProductSearchDialog -InitialSearch $searchTerm
    if ($product) {
        $row.Cells['Pax8Product'].Value = $product.name
        $row.Cells['Status'].Value = 'Matched'
        $row.Cells['Status'].Style.ForeColor = [System.Drawing.Color]::DarkGreen
        $script:pax8Sel[$e.RowIndex] = @{ id = $product.id; name = $product.name }
    }
})

# =====================================================================
# PAGE 4 — Review & Save
# =====================================================================
$pg4 = New-Object System.Windows.Forms.Panel
$pg4.Dock = 'Fill'
$pg4.Visible = $false
$pnlContent.Controls.Add($pg4)

$lblP4hint = New-Object System.Windows.Forms.Label
$lblP4hint.Text = 'Review the configuration below, then click Save to write the tenant file.'
$lblP4hint.Location = New-Object System.Drawing.Point(20, 10)
$lblP4hint.AutoSize = $true
$pg4.Controls.Add($lblP4hint)

$lblSavePath = New-Object System.Windows.Forms.Label
$lblSavePath.Location = New-Object System.Drawing.Point(20, 32)
$lblSavePath.Size = New-Object System.Drawing.Size(800, 20)
$lblSavePath.ForeColor = [System.Drawing.Color]::DimGray
$pg4.Controls.Add($lblSavePath)

$rtbJson = New-Object System.Windows.Forms.RichTextBox
$rtbJson.Location = New-Object System.Drawing.Point(20, 58)
$rtbJson.Size = New-Object System.Drawing.Size(800, 510)
$rtbJson.ReadOnly = $true
$rtbJson.ScrollBars = 'Both'
$rtbJson.WordWrap = $false
$rtbJson.BackColor = [System.Drawing.Color]::FromArgb(248, 248, 248)
try { $rtbJson.Font = New-Object System.Drawing.Font('Consolas', 9) } catch { }
$pg4.Controls.Add($rtbJson)

# =====================================================================
# Build tenant config object
# =====================================================================
function Build-Config {
    $skuMap = @()
    for ($i = 0; $i -lt $script:selectedSkus.Count; $i++) {
        $entry = $script:selectedSkus[$i]
        $sel   = $script:pax8Sel[$i]
        $buf   = 2; try { $buf = [int]$dgv.Rows[$i].Cells['Buffer'].Value   } catch {}
        $max   = 100; try { $max = [int]$dgv.Rows[$i].Cells['MaxSeats'].Value } catch {}
        $skuMap += [ordered]@{
            skuPartNumber       = $entry.skuPartNumber
            skuId               = $entry.skuId
            displayName         = $entry.displayName
            pax8ProductId       = $sel.id
            pax8ProductNameHint = $sel.name
            buffer              = $buf
            maxSeats            = $max
        }
    }
    return [ordered]@{
        tenantKey    = $txtKey.Text.Trim()
        displayName  = $txtName.Text.Trim()
        msTenantId   = $txtTid.Text.Trim()
        defaultDomain= $txtDomain.Text.Trim()
        greenfield   = [bool]$chkGreenfield.Checked
        pax8CompanyId       = $txtPax8Id.Text.Trim()
        pax8CompanyNameHint = $txtPax8Name.Text.Trim()
        microsoftProvisioning = [ordered]@{
            mca2020FirstName     = $txtMcaFirst.Text.Trim()
            mca2020LastName      = $txtMcaLast.Text.Trim()
            mca2020Email         = $txtMcaEmail.Text.Trim()
            mca2020EffectiveDate = $txtMcaDate.Text.Trim()
            msftContactFirstName = $txtMsFirst.Text.Trim()
            msftContactLastName  = $txtMsLast.Text.Trim()
            msftContactEmail     = $txtMsEmail.Text.Trim()
        }
        skuMap = $skuMap
        ignoreSkuPartNumbers = @(
            'DYN365_AI_SERVICE_INSIGHTS','FLOW_FREE','POWER_BI_STANDARD',
            'CCIBOTS_PRIVPREV_VIRAL','POWERAPPS_DEV','POWERAPPS_VIRAL',
            'WINDOWS_STORE','TEAMS_EXPLORATORY','Microsoft_Teams_Rooms_Basic',
            'Microsoft_Teams_Audio_Conferencing_select_dial_out',
            'Teams_Premium_(for_Departments)'
        )
    }
}

# =====================================================================
# Validation helpers
# =====================================================================
function Assert-Page1 {
    if (-not $txtName.Text.Trim())     { $lblStatus.Text = 'Display Name is required.';              return $false }
    if (-not $txtKey.Text.Trim())      { $lblStatus.Text = 'Tenant Key is required.';                return $false }
    if ($txtKey.Text -match '\s')      { $lblStatus.Text = 'Tenant Key cannot contain spaces.';      return $false }
    if (-not $txtTid.Text.Trim())      { $lblStatus.Text = 'Microsoft Tenant ID is required.';       return $false }
    if (-not $txtDomain.Text.Trim())   { $lblStatus.Text = 'Default Domain is required.';            return $false }
    if (-not $txtPax8Id.Text.Trim() -and -not $txtPax8Name.Text.Trim()) {
        $lblStatus.Text = 'Enter a Pax8 Company ID or Pax8 Company Name.'; return $false
    }
    foreach ($f in @($txtMcaFirst,$txtMcaLast,$txtMcaEmail,$txtMcaDate)) {
        if (-not $f.Text.Trim()) { $lblStatus.Text = 'All MCA Signatory fields are required.'; return $false }
    }
    foreach ($f in @($txtMsFirst,$txtMsLast,$txtMsEmail)) {
        if (-not $f.Text.Trim()) { $lblStatus.Text = 'All Microsoft Contact fields are required.'; return $false }
    }
    return $true
}

function Assert-Page2 {
    $checked = @($lvLicenses.Items | Where-Object { $_.Checked })
    if ($checked.Count -eq 0) { $lblStatus.Text = 'Select at least one license.'; return $false }
    return $true
}

function Assert-Page3 {
    for ($i = 0; $i -lt $dgv.Rows.Count; $i++) {
        if (-not $script:pax8Sel.ContainsKey($i)) {
            $lblStatus.Text = "No Pax8 product selected for: $($dgv.Rows[$i].Cells['LicenseName'].Value)"
            return $false
        }
        $b = 0; $m = 0
        if (-not [int]::TryParse([string]$dgv.Rows[$i].Cells['Buffer'].Value,   [ref]$b) -or $b -lt 0) {
            $lblStatus.Text = "Buffer for '$($dgv.Rows[$i].Cells['LicenseName'].Value)' must be 0 or more."; return $false
        }
        if (-not [int]::TryParse([string]$dgv.Rows[$i].Cells['MaxSeats'].Value, [ref]$m) -or $m -lt 1) {
            $lblStatus.Text = "Max Seats for '$($dgv.Rows[$i].Cells['LicenseName'].Value)' must be at least 1."; return $false
        }
    }
    return $true
}

# =====================================================================
# Page transitions
# =====================================================================
$pageList     = @($pg1, $pg2, $pg3, $pg4)
$pageTitles   = @('Step 1 of 4 — Client Details', 'Step 2 of 4 — License Selection', 'Step 3 of 4 — Pax8 Product Matching', 'Step 4 of 4 — Review & Save')
$pageSubs     = @(
    'Enter the client name, tenant ID, Pax8 company, and contact details.',
    'Select the Microsoft 365 licenses to manage for this client.',
    'Match each license to its Pax8 product using the live catalog search.',
    'Review the generated configuration and save the tenant file.'
)

function Go-Page {
    param([int]$idx)
    for ($i = 0; $i -lt $pageList.Count; $i++) { $pageList[$i].Visible = ($i -eq $idx) }
    $lblTitle.Text = $pageTitles[$idx]
    $lblSub.Text   = $pageSubs[$idx]
    $btnBack.Enabled = ($idx -gt 0)
    $btnNext.Text    = if ($idx -eq ($pageList.Count - 1)) { 'Save' } else { 'Next >' }
    $lblStatus.Text  = ''
    $script:currentPage = $idx
}

$btnNext.Add_Click({
    $lblStatus.Text = ''
    switch ($script:currentPage) {

        0 {
            if (-not (Assert-Page1)) { return }
            Go-Page 1
        }

        1 {
            if (-not (Assert-Page2)) { return }
            # Populate page 3 grid from selected items
            $dgv.Rows.Clear()
            $script:pax8Sel = @{}
            $script:selectedSkus = @($lvLicenses.Items | Where-Object { $_.Checked } | ForEach-Object { $_.Tag })
            foreach ($entry in $script:selectedSkus) {
                $rowIdx = $dgv.Rows.Add()
                $dgv.Rows[$rowIdx].Cells['LicenseName'].Value = $entry.displayName
                $dgv.Rows[$rowIdx].Cells['Status'].Value      = 'Not matched'
                $dgv.Rows[$rowIdx].Cells['Status'].Style.ForeColor = [System.Drawing.Color]::Firebrick
                $dgv.Rows[$rowIdx].Cells['Pax8Product'].Value = ''
                $dgv.Rows[$rowIdx].Cells['Buffer'].Value      = $entry.defaultBuffer
                $dgv.Rows[$rowIdx].Cells['MaxSeats'].Value    = $entry.defaultMaxSeats
            }
            Go-Page 2
        }

        2 {
            if (-not (Assert-Page3)) { return }
            # Populate review page
            $config = Build-Config
            $rtbJson.Text = ($config | ConvertTo-Json -Depth 10)
            $savePath = Join-Path $scriptRoot "config\tenants\$($txtKey.Text.Trim()).json"
            $lblSavePath.Text = "Will save to: $savePath"
            Go-Page 3
        }

        3 {
            $config   = Build-Config
            $savePath = Join-Path $scriptRoot "config\tenants\$($txtKey.Text.Trim()).json"
            try {
                $config | ConvertTo-Json -Depth 10 | Set-Content -Path $savePath -Encoding UTF8
                [System.Windows.Forms.MessageBox]::Show(
                    "Saved to:`n$savePath`n`nNext steps:`n1. Run Test-Local.ps1 to verify the plan.`n2. Commit and push to GitHub.",
                    "Client Saved", 'OK', 'Information') | Out-Null
                $form.Close()
            } catch {
                $lblStatus.Text = "Save failed: $($_.Exception.Message)"
            }
        }
    }
})

$btnBack.Add_Click({
    if ($script:currentPage -gt 0) { Go-Page ($script:currentPage - 1) }
})

# =====================================================================
# Launch
# =====================================================================
Go-Page 0
[void]$form.ShowDialog()
