# Pax8 License Automation

**New here? Open `START-HERE.md` first. It covers the full setup and add-client workflows in plain English.**

Reusable, multi-tenant automation that manages Microsoft 365 licensing through Pax8. One deployment
covers any number of clients. The Microsoft side is read-only. Every seat change is a write to Pax8
only. License assignment to users stays manual in the admin center.

## What it does
1. **Overhead report**: per SKU, seats purchased vs assigned vs idle, plus a renewal schedule.
2. **Dynamic top-up**: keeps a configured spare-seat buffer per SKU by raising the Pax8 quantity when
   technicians assign licenses the normal way. No group-based licensing.
3. **Renewal-driven ordering**: when a SKU is not yet on Pax8 and its renewal window opens, orders the
   right-sized Pax8 subscription automatically. Same Microsoft SKU ID, so no user reassignment needed.

## Safety model (graduated)
The tooling is designed so you cannot accidentally spend:
- `dryRun: true` (default): reads everything and logs the exact actions it *would* take. No Pax8 writes.
- `dryRun: false` + `pax8.useMockOrders: true`: sends orders with `isMock=true`, which validates the
  order against Pax8 without creating anything or billing.
- `dryRun: false` + `pax8.useMockOrders: false`: places real orders.
Guardrails apply at every stage: per-SKU `maxSeats` cap and `perRunMaxIncreasePerSku` ceiling, and
`requireApproval` can hold real orders for manual confirmation. Decreases are never automated, since
Microsoft NCE annual terms only allow reductions at renewal.

## Layout
```
<project root>
  README.md
  config\
    settings.json            Global defaults, guardrails, Pax8 + Graph + logging settings
    tenants\
      _template.json         Blank template - copy this to add a new client
      <clientname>.json      One file per client (this is all you add for a new client)
  src\
    Pax8.psm1                Pax8 API: token, companies, products, subscriptions, orders
    Graph.psm1               Microsoft Graph read-only (managed identity or app secret)
    LicenseLogic.psm1        Top-up and ordering decision logic + guardrails
    Logging.psm1             Structured logging used by everything
  Invoke-LicenseSync.ps1     Entry point (runbook and local). Dry-run by default.
  Test-Local.ps1             Local test wrapper (dry-run, mock orders)
  logs\                      Per-run transcripts and structured action logs
```

## Adding a new client
Copy `config\tenants\_template.json` to a new file named after the client (e.g. `contoso.json`) and fill in:
- `tenantKey` (short ID, no spaces, matches the filename without .json)
- `displayName`, `msTenantId`, `defaultDomain`
- `pax8CompanyId` (or leave blank and set `pax8CompanyNameHint`; the tool resolves the ID from Pax8)
- `microsoftProvisioning`: MCA signatory and Microsoft contact for that client
- `skuMap`: one entry per paid SKU with its Microsoft `skuPartNumber` and `skuId`, a Pax8 product name
  hint, a `buffer` (spare seats to keep available), and a `maxSeats` cap
- `ignoreSkuPartNumbers`: free/viral/trial SKUs to skip
No code changes. The same runbook iterates every file in the tenants folder.

## Prerequisites
- Pax8 API credentials: Pax8 portal > Integrations > API credentials > Create API credential
  (Partner Admin role). One credential covers every customer company.
- Microsoft Graph read access: a single tenant can use the Azure Automation managed identity granted
  `Organization.Read.All` and `Directory.Read.All`. Multi-tenant uses a multi-tenant app over the Pax8
  partner relationship (confirmed before that step).
- Secrets are stored in an encrypted Automation variable or Key Vault, never in code.

## Local testing
Run `Set-Credentials.ps1` once to store the Graph and Pax8 credentials (encrypted), then run
`Test-Local.ps1`. It connects to Graph with unattended app auth (no device code) and runs with
`dryRun` on, so it validates the plan and order shapes without spending.

## Credentials and rotation
Four values drive the tool: `GraphClientId` / `GraphClientSecret` (the Entra app registration) and
`Pax8ClientId` / `Pax8ClientSecret` (Pax8 Integrations > API credentials). Use the secret VALUE, not
the secret's ID.
Where they live:
- Local: an encrypted file `config\credentials.local.xml` created by `Set-Credentials.ps1` (DPAPI,
  readable only by the user and machine that created it). Do not commit it.
- Azure Automation: Automation account > Variables named `GraphClientId`, `GraphClientSecret`,
  `Pax8ClientId`, `Pax8ClientSecret` (secrets marked encrypted), or Key Vault. The Automation managed
  identity can replace the Graph app entirely.
To update or rotate them (the steps for when you have forgotten all of this):
1. Get a fresh secret. Graph: Entra > App registrations > Pax8 License Automation > Certificates &
   secrets > New client secret. Pax8: Pax8 > Integrations > API credentials > new credential.
2. Store it where the tool reads it. Local: run `Set-Credentials.ps1` and paste the new values.
   Azure Automation: update the matching Variable or Key Vault secret.
3. Re-run a dry-run to confirm it connects.
If a run logs `Graph auth failed` or `Pax8 auth failed`, a secret expired. Do steps 1 to 3.

## Manual step (by design)
For SKUs being moved onto Pax8 for the first time, turning off auto-renew on the existing Microsoft
subscription is done by an admin in M365 admin center > Billing > Your products. The tool flags which
subscriptions are in the renewal window but does not cancel or modify any Microsoft subscriptions itself.
