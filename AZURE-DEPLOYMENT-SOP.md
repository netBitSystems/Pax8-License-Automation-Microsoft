# Azure Automation Deployment and Update SOP

This document is written for someone with no coding background.
Follow each step in order. Do not skip steps.

How it works in plain terms: the code lives in a private GitHub repository. Every time Azure runs the
automation, it downloads the latest code from that repo and runs it. This means updating the automation
is as simple as saving a change to GitHub. Azure Automation handles the scheduling and the secrets.

## What you need before you start

Gather these four things. You will paste them into Azure during setup. Do not write them down anywhere
insecure.

1. **GitHub read-only token (PAT)** for the runbook. See "Create the GitHub token" below.
2. **Pax8 Client ID** and **Pax8 Client Secret** from the Pax8 partner portal API credentials.
3. **Graph Client Secret** for the app registration `3e87c3ee-db1c-4736-b16f-81ef51e3c1fa`
   (found in Azure portal > Azure Active Directory > App registrations > search that ID > Certificates & secrets).

---

## Step 1 — Create the GitHub token for the runbook

This is a read-only password that lets Azure download the code from GitHub. It cannot make any changes
to the repo.

1. Sign in to GitHub at https://github.com as the netBitSystems account.
2. Click your profile picture (top right) > **Settings**.
3. Scroll all the way down the left sidebar and click **Developer settings**.
4. Click **Personal access tokens** > **Fine-grained tokens**.
5. Click **Generate new token**.
6. Fill in:
   - **Token name**: `Pax8-Automation-Runbook`
   - **Expiration**: 1 year
   - **Resource owner**: `netBitSystems`
   - **Repository access**: select "Only select repositories" and choose `Pax8-License-Automation-Microsoft`
   - Under **Permissions**, expand **Repository permissions**, find **Contents**, set it to **Read-only**.
   - Leave everything else at "No access".
7. Click **Generate token**.
8. Copy the token value. It starts with `github_pat_`. You will only see it once.

---

## Step 2 — Open the Automation account in Azure

1. Go to https://portal.azure.com and sign in.
2. In the top search bar, type `Automation` and click **Automation Accounts**.
3. Find the Automation account used for this tool and click it.
   (If you do not see it, use the subscription filter at the top of the portal to select the correct subscription.)

All remaining steps happen inside this Automation account. Keep this page open.

---

## Step 3 — Import the two required modules

The automation needs two Microsoft-published code libraries. You import them once from a public gallery.

1. In the left sidebar of the Automation account, scroll to **Shared Resources** and click **Modules**.
2. Click **+ Add a module**.
3. Click **Browse from gallery**.
4. In the search box, type `Microsoft.Graph.Authentication` and press Enter.
5. Click the result named exactly `Microsoft.Graph.Authentication`.
6. Set **Runtime version** to `7.2`.
7. Click **Import** and then **OK**.
8. Repeat steps 2-7 for `Microsoft.Graph.Identity.DirectoryManagement`.
9. Wait on the Modules page, refreshing every minute or two, until both show **Status = Available**.
   This usually takes 3-5 minutes. Do not move on until both are Available.

---

## Step 4 — Create the Automation Variables

Variables are how Azure securely stores the credentials and settings the runbook needs.
You will create 10 variables. Some are encrypted (secrets) and some are plain text.

How to create each one:
1. In the left sidebar, under **Shared Resources**, click **Variables**.
2. Click **+ Add a variable**.
3. Fill in the Name, Type, Value, and Encrypted setting as listed below.
4. Click **Create**.
5. Repeat for each variable.

### Variables to create

| Name | Type | Value | Encrypted? |
|------|------|-------|------------|
| `GitHubOwnerRepo` | String | `netBitSystems/Pax8-License-Automation-Microsoft` | No |
| `GitHubBranch` | String | `main` | No |
| `GitHubPat` | String | _(paste the token from Step 1)_ | **Yes** |
| `Pax8ClientId` | String | _(your Pax8 client ID)_ | **Yes** |
| `Pax8ClientSecret` | String | _(your Pax8 client secret)_ | **Yes** |
| `GraphClientId` | String | `3e87c3ee-db1c-4736-b16f-81ef51e3c1fa` | **Yes** |
| `GraphClientSecret` | String | _(the Graph app secret value)_ | **Yes** |
| `RunMode` | String | `Both` | No |
| `RunExecute` | String | `false` | No |
| `RunMockExecute` | String | `true` | No |

Note: `RunMockExecute = true` means the first test run will validate everything without spending money.
You will change this later when you are ready to go live.

---

## Step 5 — Create the runbook

The runbook is the script Azure actually runs on schedule.

1. In the left sidebar, under **Process Automation**, click **Runbooks**.
2. Click **+ Create a runbook**.
3. Fill in:
   - **Name**: `Start-Pax8LicenseSync`
   - **Runbook type**: PowerShell
   - **Runtime version**: 7.2
   - **Description**: Pulls latest code from GitHub and runs the Pax8 license sync.
4. Click **Create**. The editor opens.
5. Open the file `D:\Pax8LicenseAutomation\Start-Pax8LicenseSync.ps1` in Notepad, select all the text
   (Ctrl+A), and copy it.
6. Click inside the editor in Azure and paste (Ctrl+V), replacing any placeholder text.
7. Click **Save**, then click **Publish**. Confirm when prompted.

---

## Step 6 — Run the first test (no money spent)

This test run reads real data from Microsoft and Pax8, builds the real license plan, and validates real
orders with Pax8 — but the `isMock=true` flag tells Pax8 not to actually charge anything.

1. Click **Runbooks** in the left sidebar and click `Start-Pax8LicenseSync`.
2. Click **Start**.
3. Leave all parameters blank and click **OK**.
4. Click **Output** in the tabs that appear. Refresh every 30 seconds.
5. You should see:
   - Lines describing the license plan for each SKU.
   - Lines showing `mock=True` orders for the SKUs due for transition.
   - `Alert email sent to services@netbitsystemsllc.com`.
6. Check that the email arrived at services@netbitsystemsllc.com.

If the run shows errors, check **All Logs** on the same page for details and refer to the
troubleshooting notes in `README.md`.

---

## Step 7 — Schedule daily runs

1. In the left sidebar, click **Schedules**, then **+ Add a schedule**.
2. Fill in:
   - **Name**: `DailyLicenseSync`
   - **Starts**: tomorrow at a time like 6:00 AM Central (adjust for your timezone).
   - **Recurrence**: Recurring, every 1 Day.
   - **Set expiration**: No.
3. Click **Create**.
4. Go back to the runbook (`Start-Pax8LicenseSync`).
5. Click **Schedules** (in the runbook's left sidebar) > **+ Add a schedule**.
6. Click **Link a schedule to your runbook**, select `DailyLicenseSync`, click **OK**.
7. Leave all parameters blank and click **OK**.

The runbook will now run automatically every day.

---

## Step 8 — Going live (placing real orders)

Do this only after the mock test in Step 6 looks correct and you are ready to actually purchase licenses
through Pax8.

**Part A — update the code** (done by the technical person):
Edit `config\settings.json` in the project on `D:\Pax8LicenseAutomation`, change:
- `dryRun` from `true` to `false`
- `requireApproval` from `true` to `false`
- `useMockOrders` from `true` to `false`

Then commit and push to GitHub (see "How updates work" below).

**Part B — flip the Azure switches** (done in the portal):
1. Go to the Automation account > **Shared Resources** > **Variables**.
2. Click `RunMockExecute` > **Edit** > change the value to `false` > **Save**.
3. Click `RunExecute` > **Edit** > change the value to `true` > **Save**.

The next scheduled run will place real orders for any SKUs inside the renewal window and send
a summary email.

**Tip:** If you want a warning before money is spent, keep `requireApproval=true` in settings.json.
The runbook will email what it would buy without buying it. To approve, flip it to `false` and push.

---

## How updates work (the routine SOP)

Because Azure downloads the latest code from GitHub on every run, updating the automation requires
no portal work at all. The technical person:

1. Makes changes to the project files on the local machine.
2. Runs `Test-Local.ps1` to verify the change locally.
3. Commits and pushes to GitHub.

Azure will use the new code on the next scheduled run automatically.

Specific update scenarios:
- **Change a buffer or seat limit**: edit the relevant file in `config\tenants\`, commit, push.
- **Rotate a credential**: update the matching Automation Variable in the portal (no code change).
- **Roll back a bad change**: revert the last commit and push. Azure uses the previous version immediately.
- **See what happened on a run**: Automation account > Runbooks > `Start-Pax8LicenseSync` > **Jobs**.
  Click any job to see its Output and All Logs. A summary email is also sent after every run.

---

## Adding a new client

The initial setup above is done once. Adding each new client requires no portal work.

1. Copy `config\tenants\_template.json` to a new file named after the client, e.g. `contoso.json`.
2. Fill in the client's details: `tenantKey`, `displayName`, `msTenantId`, `defaultDomain`,
   `pax8CompanyId` (or `pax8CompanyNameHint`), the `microsoftProvisioning` block, and the `skuMap`.
   Refer to an existing tenant file and the `_template.json` for field descriptions.
3. Run `Test-Local.ps1` to confirm the plan looks right for the new client.
4. Commit and push to GitHub.

The next scheduled Azure run will include the new client automatically.
