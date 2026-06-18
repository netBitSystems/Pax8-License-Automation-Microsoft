# Azure Automation Deployment and Update SOP

This runs the license automation as a scheduled Azure Automation runbook. The runbook
`Start-Pax8LicenseSync.ps1` pulls the latest project from a private GitHub repo on every run, so
updating the automation is a git commit. Secrets live in encrypted Automation Variables, never in the repo.

Reference for this environment: Subscription `81959d5a-4931-4c77-b612-d30c1d9181eb`, alerts to
services@netbitsystemsllc.com, Graph app already has read-only scopes plus `Mail.Send`.

## One-time setup
### 1. Put the project in a private GitHub repo
From `D:\Pax8LicenseAutomation`:
```
git init
git add .
git commit -m "Initial Pax8 license automation"
```
Create a PRIVATE repo on GitHub and push to it. `.gitignore` already excludes
`config\credentials.local.xml` and the logs, so no secrets are committed.

### 2. Create a GitHub token for the runbook
GitHub > Settings > Developer settings > Personal access tokens. Create a token with read access to
that repo (a classic token with the `repo` scope works). Copy the value.

### 3. Import the Graph modules into the Automation account
Automation account > Shared Resources > Modules > Add a module > Browse from gallery, runtime version
7.2, import:
- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Identity.DirectoryManagement`
Wait until both show Status = Available.

### 4. Create the Automation Variables
Automation account > Shared Resources > Variables. Create:
- `GitHubOwnerRepo`  = `owner/repo` (your repo)            [not encrypted]
- `GitHubBranch`     = `main`                               [not encrypted]
- `GitHubPat`        = the token from step 2                [ENCRYPTED]
- `Pax8ClientId`     = your Pax8 client id                  [ENCRYPTED]
- `Pax8ClientSecret` = your Pax8 client secret              [ENCRYPTED]
- `GraphClientId`    = `3e87c3ee-db1c-4736-b16f-81ef51e3c1fa` [ENCRYPTED]
- `GraphClientSecret`= the Graph app secret value           [ENCRYPTED]
- `RunMode`          = `Both`                               [not encrypted]
- `RunExecute`       = `false`                              [not encrypted]
- `RunMockExecute`   = `true`  (for the first test; set to `false` later) [not encrypted]

### 5. Create the runbook
Automation account > Process Automation > Runbooks > Create a runbook:
- Name `Start-Pax8LicenseSync`, type PowerShell, runtime 7.2.
- Paste the contents of `Start-Pax8LicenseSync.ps1`, then Save and Publish.

## Post-deploy test (no spend)
1. With `RunMockExecute = true`, open the runbook and click Start.
2. Watch the Output pane. You should see the plan table, three `mock=True` orders for the transition
   SKUs, and `Alert email sent to services@netbitsystemsllc.com`.
3. Confirm the email arrives. This proves the deployed runbook reads the repo, authenticates to Graph
   and Pax8, validates orders with isMock, and notifies, all from Azure with nothing purchased.

## Schedule it
Automation account > Schedules > add a daily schedule, then on the runbook use Link to schedule.
Native schedules are hourly minimum; the buffer makes a daily run more than enough.

## Going live (real orders)
When you are ready to actually purchase:
1. In the repo, edit `config\settings.json`: `dryRun=false`, `requireApproval=false`,
   `useMockOrders=false`. Commit and push.
2. Set Automation Variables `RunMockExecute=false` and `RunExecute=true`.
3. The next scheduled run places real orders for SKUs inside the renewal window, and emails the summary.
Tip: leave `requireApproval=true` if you want the runbook to email what it WOULD buy without buying,
so you can approve by then flipping it.

## Updating the automation (the routine SOP)
- Change config or logic (buffers, lead time, SKU map, add a tenant, code fixes): edit locally, then
  `git commit` and `git push`. The next run uses it automatically. Nothing to re-import.
- Add a tenant: add `config\tenants\<name>.json`, commit, push.
- Rotate a credential: update the matching Automation Variable (`Pax8ClientSecret`, `GraphClientSecret`,
  or `GitHubPat`). No code change.
- Change the run mode or go-live state: edit the `RunMode` / `RunExecute` / `RunMockExecute` Variables.
- Roll back: `git revert` the bad commit and push, or point `GitHubBranch` at a known-good tag.
- See what happened: the runbook's Output and All Logs in Azure, plus the email summary each run.
