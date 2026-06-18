# Deploying Pax8 License Automation

Two ways to run this on a schedule. Both run the same code and config and differ only in where they run
and how credentials are stored.

## Before you deploy
1. Dry-run looks right: `pwsh .\Test-Local.ps1`
2. Live path validates with no spend: `pwsh .\Invoke-LiveTest.ps1`
   (real Graph and Pax8 reads, real plan, isMock orders, nothing purchased)
3. Decide the gates in `config\settings.json`:
   - `dryRun`: true keeps it report-only. Set false to allow real orders.
   - `requireApproval`: true logs intended orders without placing them. Set false to auto-place.
   - `pax8.useMockOrders`: true validates orders via isMock even when executing. Set false for real orders.
   - `leadDays`, per-SKU `buffer` and `maxSeats`, `perRunMaxIncreasePerSku`.

## Option A (simplest): Windows Scheduled Task
Runs the scripts as-is on an always-on Windows machine using the encrypted credential store.
1. On the target machine, sign in as the service account that will run the task.
2. Run `Set-Credentials.ps1` as THAT account. The encrypted store is bound to the user and machine that
   created it.
3. Register the task (defaults to a safe daily dry-run at 02:00):
   `pwsh .\Deploy-ScheduledTask.ps1`
   When you are ready for real orders, set `settings.json` (`dryRun=false`, `requireApproval=false`,
   `useMockOrders=false`) and register with `pwsh .\Deploy-ScheduledTask.ps1 -Execute`.
4. If the task cannot read the credential store under S4U logon, re-register it to run with the account
   password, or set `PAX8_*` and `GRAPH_*` values as machine environment variables for that account.

## Option B (scalable): Azure Automation
Serverless and best for many tenants. Requires repackaging because Automation has no local file system.
1. Create an Automation account on the PowerShell 7.2 runtime.
2. Import the Graph submodules as Automation modules: `Microsoft.Graph.Authentication` and
   `Microsoft.Graph.Identity.DirectoryManagement`.
3. Package `src\*.psm1` as one module asset (zip the `src` folder) and import it.
4. Store credentials as encrypted Automation variables: `GraphClientId`, `GraphClientSecret`,
   `Pax8ClientId`, `Pax8ClientSecret`. The runbook already reads these via `Get-AutomationVariable`.
   - Alternatively, if the Automation account lives in the customer tenant, grant its managed identity
     `Organization.Read.All` and `Directory.Read.All` and run with `-UseManagedIdentity`.
5. Make the config available: embed the settings and tenant JSON in the runbook, store them as
   Automation variables, or read them from a storage account. The runbook needs the tenant values
   (`msTenantId`, `pax8CompanyId`, `skuMap`, `microsoftProvisioning`) and settings (`locationMpnId`,
   buffers, gates).
6. Create the runbook from `Invoke-LicenseSync.ps1`, set parameters, and attach a schedule. Native
   Automation schedules are hourly minimum; use offset schedules for a tighter cadence.

## Credentials and rotation
See README section "Credentials and rotation". Local uses `Set-Credentials.ps1` (DPAPI); Azure uses the
named Automation variables. When a key expires, the run logs exactly which one to replace.

## Order notifications
Orders placed by the automation go through the same Pax8 order pipeline as manual orders, so your usual
Pax8 confirmation and provisioning emails should arrive. Set `pax8.orderedByUserEmail` in `settings.json`
so orders are attributed to you and you are included on the notification. For independent alerting,
configure the `alert` block in `settings.json` so the tool notifies you on every purchase and error.
