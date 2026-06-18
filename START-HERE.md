# Pax8 License Automation — Start Here

If you are new to this tool, read this first. Everything else can wait.

## How to launch the tools

Double-click **`Launch-Pax8Tools.bat`** in this folder.

That opens a menu with numbered options. You run everything from there.
You do not need to understand PowerShell, git, or Azure to use this.

---

## Which workflow applies to you?

### Setting up for the first time (never done this before)

Choose option **[1] First-time setup** from the menu.

The setup assistant will walk you through every step in your browser —
creating the Pax8 API credential, registering the app in Microsoft Entra,
creating the Azure Automation account, setting up the variables, creating
the runbook, and linking the schedule.

**Before you start, make sure you have:**
- Admin access to portal.pax8.com (Partner Admin role)
- Global Administrator access to portal.azure.com
- Access to github.com as the netBitSystems account
- About 20-30 minutes

The assistant shows numbered portal steps, waits for you to complete them,
then verifies before moving on. You can re-run it at any time if you get
interrupted — already-completed steps are skipped.

---

### Adding a new client (platform already set up)

Choose option **[2] Add a new client** from the menu.

The script will ask you:
1. The client's company name
2. Their Microsoft Tenant ID (found in Azure portal > Entra ID > Overview)
3. Their default domain (e.g. acmecorp.com)
4. Their company name as it appears in Pax8

It then walks you through picking the right Pax8 product for each license.
When it finishes, it saves a config file. You then commit and push to GitHub
and Azure picks it up on the next scheduled run.

**Before adding a client:**
- Make sure the client has a GDAP relationship with NetBit in the Partner Center
- Have their Microsoft Tenant ID ready (Azure portal > Entra ID > Overview)
- Know their company name in Pax8

---

## What the automation actually does

Once running, the automation checks every client tenant daily and:

1. Reads how many licenses are assigned in Microsoft 365 (read-only)
2. Reads what is currently on Pax8 for that client
3. Decides if anything needs to be ordered or topped up
4. Sends a summary email to services@netbitsystemsllc.com

Nothing is purchased until you explicitly go live (see `AZURE-DEPLOYMENT-SOP.md`).
By default it runs in dry-run mode and only reports what it would do.

---

## When something goes wrong

- **A sync run failed**: Automation account > Runbooks > Start-Pax8LicenseSync > Jobs.
  Click the failed job to see the full output. A summary email is also sent.
- **An API key expired**: Run option [1] from the menu to update credentials, or
  update the matching Automation Variable directly in Azure portal.
- **Need to add a license type that is not in the catalog**: Edit
  `config/sku-catalog.json`, add the entry, commit and push.
- **Need to change a buffer or seat limit**: Edit `config/tenants/<client>.json`,
  commit and push. Azure uses the new value on the next run.

---

## Files in this folder

| File | What it does |
|---|---|
| `Launch-Pax8Tools.bat` | Menu launcher — start here |
| `Initialize-Automation.ps1` | First-time setup assistant |
| `New-TenantConfig.ps1` | Add a new client |
| `Test-Local.ps1` | Run a local dry-run (no changes) |
| `Invoke-LiveTest.ps1` | Live test with mock orders (no spend) |
| `config/tenants/` | One JSON file per managed client |
| `config/sku-catalog.json` | List of known Microsoft 365 licenses |
| `AZURE-DEPLOYMENT-SOP.md` | Detailed Azure portal walkthrough (reference) |
| `README.md` | Technical overview |
