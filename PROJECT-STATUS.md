# Pax8 License Automation — Project Status and Handoff

Context document so a new agent or session can pick up where we left off. No secrets are stored here.

## TL;DR
Built and validated locally in dry-run and live-mock (nothing purchased). Not yet deployed to Azure and
not yet placing real orders. Next step is the Azure deploy in `AZURE-DEPLOYMENT-SOP.md`, then a post-deploy
mock test, then going live.

## Goal
A reusable, multi-tenant tool that:
1. Reports license overhead (purchased vs assigned vs idle, with renewal dates).
2. Keeps seats available by topping up from Pax8 as technicians assign licenses the normal per-user way.
3. Replaces direct-billed Microsoft subscriptions with right-sized Pax8 ones as each renews.
All subscriptions stay annual. No group-based licensing. The Microsoft side is read-only; every write goes
to Pax8. The point is to move license billing to Pax8 so the company earns the reseller margin.

## Key facts (Riceland Healthcare)
- MS tenant: `ricelandhealthcare.com`, tenantId `84324bf7-8acd-43a9-b9a4-e657afdff264`
- Pax8 company id: `597142b6-cdee-460f-b0bc-e3847157b9b3` (Pax8 is already the primary solution provider;
  GDAP = SUCCESS; reseller relationship and MCA already established)
- Partner Location MPN / PLA id: `6107056`
- Graph app registration (in Riceland tenant) client id: `3e87c3ee-db1c-4736-b16f-81ef51e3c1fa`,
  permissions `Organization.Read.All`, `Directory.Read.All`, `Mail.Send` (all admin-consented)
- MCA signatory: Adam Burnaman / services@netbitsystemsllc.com (accepted 2023-06-19).
  Microsoft contact: Dylan Rumsey / netbit@ricelandhealthcare.com
- Azure subscription: `81959d5a-4931-4c77-b612-d30c1d9181eb`; an Azure Automation account is created.
  Deployment model chosen: GitHub-backed runbook.
- Notifications: emailed to services@netbitsystemsllc.com, sent via Graph as netbit@ricelandhealthcare.com.
- SECRETS ARE NOT IN THIS FILE. The Pax8 and Graph client secrets live in the encrypted local store
  (`config\credentials.local.xml`, created by `Set-Credentials.ps1`, DPAPI, bound to this user+machine)
  and, in Azure, in encrypted Automation Variables.

## The estate (all currently DIRECT; nothing on Pax8 yet)
Paid SKUs, purchased/assigned: Business Standard 391/391; Business Basic 500/181 (~319 idle);
Exchange Online P1 358/183 (~175 idle); Exchange Online P2 31/25; Copilot 9/9; plus singletons
(M365 E5 no Teams, Teams Enterprise, Teams Premium, Teams Rooms Pro, Power BI Premium Per User,
Power Apps Premium, Visio Plan 2). Renewals are staggered across 2026 and 2027. Free/viral/trial SKUs
are ignored. Full snapshots: `C:\Users\drumsey.admin\M365-License-Tools\overhead-*.csv` and
`subscribed-skus-*.csv`.

## How it works
- Reads SKUs and renewals from Graph (app auth, read-only), reads Pax8 subscriptions, builds a per-SKU plan.
- Actions: `topup` (raise an existing Pax8 subscription to assigned+buffer), `transition` (order the
  matching Pax8 product when a direct sub is within `leadDays` of renewal), `wait`, `none`. Capped by
  per-SKU `maxSeats` and `perRunMaxIncreasePerSku`.
- Safety gates in `config\settings.json`: `dryRun` (default true), `requireApproval` (default true),
  `pax8.useMockOrders` (default true). The `-MockExecute` mode forces isMock and bypasses gates for safe
  live testing (real reads, real plan, validated orders, no spend).
- Multi-tenant: one JSON per tenant in `config\tenants`. Adding a tenant is adding a file.

## Project files (D:\Pax8LicenseAutomation)
- `config\settings.json` — gates, guardrails, Pax8/Graph endpoints, MPN, orderedByUserEmail, alert config
- `config\tenants\riceland.json` — tenant id, Pax8 company id, SKU map (per-SKU buffer/maxSeats),
  `microsoftProvisioning` (MCA signatory + MS contact), ignore list
- `src\Logging.psm1` — structured JSONL logging (with temp fallback for the Azure sandbox)
- `src\Pax8.psm1` — Pax8 API: token, companies, products, pricing, dependencies (commitment terms),
  subscriptions, orders (isMock), provisioning-details builder, product resolver
- `src\Graph.psm1` — read-only Graph (app secret / managed identity / device code)
- `src\LicenseLogic.psm1` — the plan logic
- `src\Notify.psm1` — email (Graph sendMail) and Teams alerts
- `Invoke-LicenseSync.ps1` — the engine and Azure runbook target (`-Mode`, `-Execute`, `-MockExecute`,
  `-UseManagedIdentity`, `-UseDeviceCode`)
- `Test-Local.ps1` — dry-run wrapper
- `Invoke-LiveTest.ps1` — live test with isMock (no spend)
- `Set-Credentials.ps1` — store Graph + Pax8 creds encrypted (DPAPI)
- `Deploy-ScheduledTask.ps1` — Windows Scheduled Task deploy (the non-Azure alternative)
- `Start-Pax8LicenseSync.ps1` — Azure Automation runbook: pulls the repo from GitHub, runs the sync
- `README.md` — overview, safety model, credentials and rotation, add-a-tenant
- `DEPLOY.md` — scheduled task and Azure overview
- `AZURE-DEPLOYMENT-SOP.md` — full GitHub-backed Azure deploy + the routine update SOP
- Early read-only inventory/overhead tools live separately at `C:\Users\drumsey.admin\M365-License-Tools`
  (`Get-TenantLicenseInventory.ps1`, `Get-LicenseOverheadReport.ps1`, CSV/log snapshots)

## Pax8 API specifics learned
- Token: `POST https://api.pax8.com/v1/token`, audience `https://api.pax8.com`, client_credentials, 24h.
- Order: `POST /v1/orders` with `?isMock=true` validates without purchasing. An NCE order needs:
  the commercial `[New Commerce Experience]` product id (resolver excludes Government/GCC/Nonprofit/
  Education/Student/Faculty/Trial/Promo), a `commitmentTermId` from `GET /products/{id}/dependencies`
  (Annual maps to the `1-Year` term), `lineItemNumber`, `billingTerm` Annual, `quantity`, and
  `provisioningDetails` (`msCustExists`=Yes, `msTenantId`, `msMPNidval`=6107056,
  `microsoftCancelPolicyAcknowledgement`, plus MCA signatory and MS contact from tenant config).
- Pricing: `GET /products/{id}/pricing`. Provisioning fields: `GET /products/{id}/provision-details`.
- Top-up (raise quantity on an existing subscription) uses `Set-Pax8SubscriptionQuantity`
  (`PUT /subscriptions/{id}`). This is NOT yet live-verified because there is no isMock for it and
  Riceland has zero Pax8 subscriptions yet. It is flagged VERIFY in `src\Pax8.psm1`.

## Tested and passing
- Overhead report (read-only).
- Dry-run plan via `Test-Local.ps1` (correct topup / transition / wait / cap, buffer math).
- Graph app-only auth with no device code.
- isMock order for Teams Premium, and a full live `-MockExecute` run that validated isMock orders for all
  three transition SKUs (Teams Premium, Teams Rooms Pro, Power Apps), nothing purchased.
- Email alert delivered to services@netbitsystemsllc.com (after `Mail.Send` was added).
- All scripts and modules parse; all JSON valid.

## Remaining / next steps
1. Deploy to Azure following `AZURE-DEPLOYMENT-SOP.md`: push the repo, create a read-only GitHub PAT,
   import the two Graph modules into the Automation account, create the encrypted Automation Variables,
   paste `Start-Pax8LicenseSync.ps1` as the runbook, and link a daily schedule.
2. Post-deploy test: run the runbook with `RunMockExecute=true` and confirm the plan, isMock orders, and
   the email all happen from Azure with no spend.
3. Go live: set `settings.json` to `dryRun=false`, `requireApproval=false`, `useMockOrders=false`, and the
   Variables to `RunMockExecute=false`, `RunExecute=true`.
4. Live-verify the top-up path once Riceland has at least one real Pax8 subscription.
5. Optional: initialize the git repo and first commit (offered, not yet done).

## How to run locally
- Store/refresh credentials: `pwsh D:\Pax8LicenseAutomation\Set-Credentials.ps1`
- Dry-run (report only): `pwsh D:\Pax8LicenseAutomation\Test-Local.ps1`
- Live test, isMock, no spend: `pwsh D:\Pax8LicenseAutomation\Invoke-LiveTest.ps1`
- Overhead snapshot: `pwsh C:\Users\drumsey.admin\M365-License-Tools\Get-LicenseOverheadReport.ps1`

## Key decisions
Annual term only (no monthly). No group-based licensing; technicians keep assigning per-user. Renewal-driven
transition plus a buffer-based top-up. Multi-tenant and config-driven. Microsoft side read-only; all writes
go to Pax8. Notifications go to services@netbitsystemsllc.com. GitHub-backed Azure deployment so updates are
a git commit.
