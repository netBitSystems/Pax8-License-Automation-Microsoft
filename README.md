# Pax8 License Automation

Keeps each client's Microsoft 365 license quantities on Pax8 matched to actual usage. Every hour it reads how many seats are assigned in the client's tenant, then raises the matching Pax8 subscription so a small spare buffer is always available. It can also stand up a brand-new license the client has never had, and then maintain it from there.

Microsoft Graph access is read only. Pax8 is the only place the tool ever writes. Assigning licenses to users stays a manual task in the Microsoft admin center.

## How it is deployed

One Azure Automation account per client. Everything specific to a client lives in a single Azure Automation variable named `TenantConfig`, which holds a JSON blob. This GitHub repo holds only generic code and reference data. No client details and no secrets are ever stored here.

An hourly runbook (`Start-Pax8LicenseSync.ps1`) downloads this repo on every run, injects that client's `TenantConfig`, and runs the sync. Because the code is pulled fresh each run, pushing to `main` updates every client deployment automatically. The repo is public, so the runbook needs no GitHub token.

## The setup tool: pax8tools.exe

Download `pax8tools.exe` from the Releases page and run it. It is a single Windows executable with a simple menu:

- `[1]` Set up a client: guided, start to finish.
- `[2]` Add SKUs to an existing client.
- `[3]` Exit.

### [1] Set up a client

Walks through, in order:

1. Pax8 API credentials (entered once and cached locally).
2. A Microsoft Entra app registration in the client's tenant: single tenant, with `Organization.Read.All`, `Directory.Read.All`, and `Mail.Send`.
3. The Azure Automation account: creating it, importing the two Microsoft Graph modules, creating the variables, pasting in the runbook, and linking an hourly schedule.
4. Client details: new vs existing client, Tenant ID, primary domain, and the Pax8 company (looked up live from Pax8).
5. License selection: pick the licenses to manage and match each to a Pax8 product.

It then writes the `TenantConfig` JSON, saves a local copy, and copies it to the clipboard. The last step is pasting that JSON into the client's `TenantConfig` Automation variable.

### [2] Add SKUs to an existing client

Pick the client (a local config, or paste the client's current `TenantConfig`), then for each license to add:

1. Search the live Pax8 catalog and choose the product to order.
2. Pick the matching Microsoft license by friendly name. The list is searched automatically from the Pax8 product name, so there are no SKU codes to type.
3. Set the spare-seat buffer, the maximum seat cap, and, for a brand-new license, how many seats the first order should buy.

It merges the new entries, saves the updated `TenantConfig`, and copies it to the clipboard to paste back into the Automation variable.

## How the hourly sync decides

For each license in the client's `skuMap`:

- It reads the assigned seat count from the tenant, matched by Microsoft `skuPartNumber`.
- Target seats = assigned + buffer, capped at `maxSeats`.
- If the Pax8 quantity is below target, it raises it: a top-up when a Pax8 subscription already exists, or a new order otherwise.
- Brand-new license: if the license is not in the tenant yet and `initialSeats` is set, it places that first order, then normal top-up takes over once the license shows up in the tenant. `initialSeats` is ignored for a license that already exists in the tenant.
- It never decreases quantities. Microsoft NCE annual terms only allow reductions at renewal.

## Safety controls

- `RunExecute = false` (Automation variable) stops all purchasing immediately.
- `RunMockExecute = true` runs the full live path but sends Pax8 orders with `isMock=true`, validating everything without spending. Use this for the first run.
- `config/settings.json` carries `dryRun`, `requireApproval`, and `pax8.useMockOrders` as additional brakes.
- `perRunMaxIncreasePerSku` caps how many seats can be added per SKU in one run, and each SKU has its own `maxSeats` cap.
- Pax8 allows cancelling a new NCE order within 7 days from the portal.

Recommended first run for any client: set `RunMockExecute = true`, confirm the plan in the run output, then switch to `RunExecute = true` and `RunMockExecute = false`.

## Credentials

Two credential pairs per deployment, both stored as encrypted Azure Automation variables and never in this repo:

- `Pax8ClientId` and `Pax8ClientSecret`: your Pax8 partner API credential (Pax8 portal, Integrations, API Credentials). The same credential works for every client.
- `GraphClientId` and `GraphClientSecret`: the Entra app registered in that client's tenant.

To rotate, create a new secret (Entra app or Pax8), update the matching Automation variable, then run once to confirm. The setup tool also caches the Pax8 credential locally in `config/credentials.json`, which is git-ignored.

## Notifications

The sync emails the configured alert address, sent via Graph `Mail.Send` from the client's own tenant, whenever it takes an action (top-up, transition, or order) or hits an error. Runs with nothing to do send no email.

## Azure Automation variables

Created by the setup tool. Secrets are marked encrypted.

- `GitHubOwnerRepo`, for example `netBitSystems/Pax8-License-Automation-Microsoft`
- `GitHubBranch`, optional, defaults to `main`
- `Pax8ClientId`, `Pax8ClientSecret` (encrypted)
- `GraphClientId`, `GraphClientSecret` (encrypted)
- `RunMode`, one of `TopUp`, `Transition`, or `Both`
- `RunExecute`, `true` to place real orders
- `RunMockExecute`, `true` to run the live path with mock orders
- `TenantConfig`, the client's JSON config

## Repository layout

- `tools/main.go`: source for `pax8tools.exe`.
- `Start-Pax8LicenseSync.ps1`: the Azure Automation runbook. Downloads this repo, injects `TenantConfig`, runs the sync.
- `Invoke-LicenseSync.ps1`: the sync engine entry point.
- `src/Pax8.psm1`: Pax8 API (token, companies, products, subscriptions, orders).
- `src/Graph.psm1`: Microsoft Graph, read only.
- `src/LicenseLogic.psm1`: the decision logic (top-up, transition, order, wait, and brand-new via `initialSeats`).
- `src/Notify.psm1`: email alerts.
- `src/Logging.psm1`: structured logging.
- `config/settings.json`: global settings and guardrails.
- `config/sku-catalog.json`: curated license list shown in the setup wizard.
- `config/microsoft-skus.json`: full Microsoft license reference for the friendly-name picker.
- `config/tenants/_template.json`: reference template. Real client configs are never committed; they live only in each client's `TenantConfig` variable.
- `tests/Test-NewLicensePlan.ps1`: unit test for the planner logic, with no API calls.

## Building pax8tools.exe

Go is required.

```
go build -C tools -o pax8tools.exe .
```

Then publish the binary on the GitHub Releases page.

## Contributors

Primary contributor: drumsey-netbit
