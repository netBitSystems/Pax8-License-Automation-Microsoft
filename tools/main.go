// pax8tools - Pax8 License Automation CLI
// Builds to a single standalone Windows executable with no runtime dependencies.
// go build -C D:\Pax8LicenseAutomation\tools -o D:\Pax8LicenseAutomation\pax8tools.exe .
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

// ── ANSI colors ────────────────────────────────────────────────────────────
const (
	appVersion = "v1.3 - guided client setup"
	cReset     = "\033[0m"
	cBlue      = "\033[34m"
	cCyan      = "\033[36m"
	cGreen     = "\033[32m"
	cRed       = "\033[31m"
	cYellow    = "\033[33m"
	cGray      = "\033[90m"
	cWhite     = "\033[97m"
	cBold      = "\033[1m"
)

// ── Globals ────────────────────────────────────────────────────────────────
var (
	root    string
	scanner *bufio.Scanner
)

// ── Data types ─────────────────────────────────────────────────────────────
type Credentials struct {
	Pax8ClientId      string `json:"pax8ClientId"`
	Pax8ClientSecret  string `json:"pax8ClientSecret"`
	GraphClientId     string `json:"graphClientId"`
	GraphClientSecret string `json:"graphClientSecret"`
}

type CatalogFile struct {
	Licenses []CatalogEntry `json:"licenses"`
}

type CatalogEntry struct {
	Category        string `json:"category"`
	DisplayName     string `json:"displayName"`
	SkuPartNumber   string `json:"skuPartNumber"`
	SkuId           string `json:"skuId"`
	DefaultBuffer   int    `json:"defaultBuffer"`
	DefaultMaxSeats int    `json:"defaultMaxSeats"`
}

type Pax8Product struct {
	Id   string `json:"id"`
	Name string `json:"name"`
}

type SkuMapEntry struct {
	SkuPartNumber       string `json:"skuPartNumber"`
	SkuId               string `json:"skuId"`
	DisplayName         string `json:"displayName"`
	Pax8ProductId       string `json:"pax8ProductId"`
	Pax8ProductNameHint string `json:"pax8ProductNameHint"`
	Buffer              int    `json:"buffer"`
	MaxSeats            int    `json:"maxSeats"`
}

type Provisioning struct {
	Mca2020FirstName     string `json:"mca2020FirstName"`
	Mca2020LastName      string `json:"mca2020LastName"`
	Mca2020Email         string `json:"mca2020Email"`
	Mca2020EffectiveDate string `json:"mca2020EffectiveDate"`
	MsftContactFirstName string `json:"msftContactFirstName"`
	MsftContactLastName  string `json:"msftContactLastName"`
	MsftContactEmail     string `json:"msftContactEmail"`
}

type TenantConfig struct {
	TenantKey             string        `json:"tenantKey"`
	DisplayName           string        `json:"displayName"`
	MsTenantId            string        `json:"msTenantId"`
	DefaultDomain         string        `json:"defaultDomain"`
	Greenfield            bool          `json:"greenfield"`
	Pax8CompanyId         string        `json:"pax8CompanyId"`
	Pax8CompanyNameHint   string        `json:"pax8CompanyNameHint"`
	AlertEmail            string        `json:"alertEmail"`
	MicrosoftProvisioning Provisioning  `json:"microsoftProvisioning"`
	SkuMap                []SkuMapEntry `json:"skuMap"`
	IgnoreSkuPartNumbers  []string      `json:"ignoreSkuPartNumbers"`
}

// ── Entry point ────────────────────────────────────────────────────────────
func main() {
	enableANSI()
	exe, _ := os.Executable()
	root = filepath.Dir(exe)
	scanner = bufio.NewScanner(os.Stdin)
	for {
		showMenu()
	}
}

// ── Menu ───────────────────────────────────────────────────────────────────
func showMenu() {
	cls()
	bar("Pax8 License Automation", "")
	fmt.Printf("  %s%s%s\n\n", cGray, appVersion, cReset)
	fmt.Println()
	fmt.Printf("  %s[1]%s  Set up a client\n", cCyan, cReset)
	fmt.Printf("  %s[2]%s  Exit\n", cCyan, cReset)
	fmt.Println()
	choice := ask("  Enter choice")
	switch choice {
	case "1":
		runClientWizard()
	case "2":
		os.Exit(0)
	}
}

// ── Client setup wizard ────────────────────────────────────────────────────
func runClientWizard() {
	cls()
	bar("Client Setup", "Sets up Pax8 license management for one client, start to finish.")

	// ── Step 1: Pax8 credentials ──────────────────────────────────────────
	section("Step 1 of 5", "Pax8 API Credentials")
	creds := loadCreds()
	pax8Token := ""
	if creds.Pax8ClientId != "" && creds.Pax8ClientSecret != "" {
		tok, err := getPax8Token(creds.Pax8ClientId, creds.Pax8ClientSecret)
		if err == nil {
			pax8Token = tok
			ok("Pax8 already connected — skipped")
		}
	}
	if pax8Token == "" {
		fmt.Println()
		step("You need a Pax8 API credential to search the live product catalog.")
		step("How to create one:")
		step("  1. Go to: " + cCyan + "https://portal.pax8.com" + cReset)
		step("  2. Click your name in the top-right corner → Settings")
		step("  3. Go to Integrations → API Credentials")
		step("  4. Click Add API Credential, enter any name, click Add")
		step("  5. Copy the Client ID and Client Secret shown immediately after creation")
		fmt.Println()
		creds, pax8Token = promptForPax8Credentials(creds)
		saveCreds(creds)
	}

	// ── Step 2: Graph credentials ─────────────────────────────────────────
	section("Step 2 of 5", "Microsoft Entra App Registration")
	guidRe := regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	if creds.GraphClientId != "" && guidRe.MatchString(creds.GraphClientId) && len(creds.GraphClientSecret) > 10 {
		ok("Graph credentials already on file — skipped")
	} else {
		fmt.Println()
		step("This app reads Microsoft 365 license data from the client's tenant.")
		step("You need one app registration per client tenant. How to create it:")
		fmt.Println()
		step("  1. Sign in to the CLIENT'S Azure tenant, then go to:")
		step("     " + cCyan + "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/CreateApplicationBlade" + cReset)
		fmt.Println()
		step("  2. Fill in:")
		step("       Name:            Pax8 License Automation")
		step("       Supported types: Accounts in this organizational directory only (Single tenant)")
		step("       Redirect URI:    leave blank")
		step("     Click Register")
		fmt.Println()
		step("  3. Go to API permissions → Add a permission → Microsoft Graph → Application permissions")
		step("     Add ALL THREE of these:")
		step("       Organization.Read.All")
		step("       Directory.Read.All")
		step("       Mail.Send")
		step("     Then click Grant admin consent for [tenant name] → Yes")
		fmt.Println()
		step("  4. Go to Certificates & secrets → New client secret")
		step("     Description: anything | Expires: 24 months → click Add")
		fmt.Printf("     %s%s⚠  Copy the VALUE column immediately — it disappears after you navigate away%s\n", cBold, cYellow, cReset)
		step("     (Do NOT copy the Secret ID — only the Value to the left of it)")
		fmt.Println()
		step("  5. Click Overview in the left sidebar")
		step("     The Application (client) ID is the GUID shown near the top")
		fmt.Println()
		for !(guidRe.MatchString(creds.GraphClientId) && len(creds.GraphClientSecret) > 10) {
			creds.GraphClientId = ask("  Application (client) ID  [app Overview page]")
			creds.GraphClientSecret = ask("  Client Secret Value      [VALUE column, NOT the Secret ID]")
			if !(guidRe.MatchString(creds.GraphClientId) && len(creds.GraphClientSecret) > 10) {
				fail("App ID must be a GUID. Secret must be at least 10 characters.")
			}
		}
		ok("Graph credentials saved")
		saveCreds(creds)
	}

	// ── Step 3: Azure Automation infrastructure ───────────────────────────
	section("Step 3 of 5", "Azure Automation Infrastructure")
	if !askYN("Have you already set up the Azure Automation account and runbook for this tool?") {
		runAzureSetup(creds)
	} else {
		ok("Azure infrastructure already in place — skipped")
	}

	// ── Step 4: Client details ────────────────────────────────────────────
	section("Step 4 of 5", "Client Details")
	fmt.Println()

	step("Is this client brand new to Pax8 with no existing Microsoft subscriptions,")
	step("or are they currently purchasing licenses directly from Microsoft?")
	fmt.Println()
	fmt.Printf("  %s[1]%s  New client — no existing Microsoft subscriptions (greenfield)\n", cCyan, cReset)
	fmt.Printf("  %s[2]%s  Existing client — currently has Microsoft direct licenses to migrate\n", cCyan, cReset)
	fmt.Println()
	clientType := ""
	for clientType != "1" && clientType != "2" {
		clientType = ask("  Enter choice")
	}
	greenfield := clientType == "1"

	fmt.Println()
	step("Client company name:")
	step("  The name you use internally to refer to this client")
	displayName := ask("  Company name")

	fmt.Println()
	step("Microsoft Tenant ID:")
	step("  Where to find: Azure portal → Entra ID → Overview → Basic Information → Tenant ID")
	step("  Looks like: 00000000-0000-0000-0000-000000000000")
	tenantId := ask("  Tenant ID")

	fmt.Println()
	step("Primary domain:")
	step("  Where to find: Azure portal → Entra ID → Overview → Basic Information → Primary domain")
	step("  Use the custom domain if they have one (e.g. contoso.com), otherwise the .onmicrosoft.com domain")
	domain := ask("  Primary domain")

	fmt.Println()
	step("Pax8 company name:")
	step("  Where to find: Pax8 portal → Companies tab → find the client → copy the name exactly as shown")
	pax8Company := ask("  Pax8 company name")

	fmt.Println()
	step("Alert notification email:")
	step("  Who receives license sync reports and error alerts for this client")
	step("  (Alerts are sent via the Mail.Send mailbox you granted in Step 2 — usually your support inbox)")
	alertEmail := ask("  Alert email")

	tenantKey := regexp.MustCompile(`[^a-z0-9]`).ReplaceAllString(strings.ToLower(displayName), "")
	if len(tenantKey) > 20 {
		tenantKey = tenantKey[:20]
	}
	fmt.Printf("\n  %sTenant key: %s%s\n", cGray, tenantKey, cReset)

	// ── Step 5: License selection ─────────────────────────────────────────
	catalog := loadCatalog()
	if len(catalog) == 0 {
		fail("Could not load sku-catalog.json. Check your internet connection.")
		wait("Press Enter to return to menu")
		return
	}

	var skuMap []SkuMapEntry
	var migrationList []CatalogEntry

	if greenfield {
		section("Step 5 of 5", "License Selection")
		fmt.Println()
		step("Select the licenses this client will use. The automation maintains a buffer of spare")
		step("seats and automatically tops up via Pax8 when assignments get close to the limit.")
		fmt.Println()

		selected := selectLicensesFromCatalog(catalog)
		if len(selected) == 0 {
			fail("No licenses selected. At least one license is required.")
			wait("Press Enter to return to menu")
			return
		}
		fmt.Printf("\n  %s%d license(s) selected.%s\n", cGreen, len(selected), cReset)

		skuMap = matchToPax8Products(selected, pax8Token)
		if skuMap == nil {
			return
		}

	} else {
		section("Step 5 of 5", "Existing Licenses — Identify and Map to Pax8")
		fmt.Println()
		step("Select every license the client currently purchases directly through Microsoft.")
		step("These will be moved to Pax8 management. Do NOT cancel the direct subscriptions")
		step("yet — you will get cancellation instructions at the end.")
		fmt.Println()

		migrationList = selectLicensesFromCatalog(catalog)
		if len(migrationList) == 0 {
			fail("No licenses selected. At least one license is required.")
			wait("Press Enter to return to menu")
			return
		}
		fmt.Printf("\n  %s%d license(s) selected for migration.%s\n", cGreen, len(migrationList), cReset)
		fmt.Println()

		// Cancellation warning block
		fmt.Printf("  %s%s┌─ IMPORTANT: Microsoft Direct Cancellation Required ──────────────%s\n", cBold, cYellow, cReset)
		for _, e := range migrationList {
			fmt.Printf("  %s│  • %s%s\n", cYellow, e.DisplayName, cReset)
		}
		fmt.Printf("  %s│%s\n", cYellow, cReset)
		fmt.Printf("  %s│  After setup, once Pax8 has provisioned the replacement subscriptions,%s\n", cYellow, cReset)
		fmt.Printf("  %s│  cancel these Microsoft direct subscriptions:%s\n", cYellow, cReset)
		fmt.Printf("  %s│    Microsoft 365 admin center → Billing → Your products%s\n", cYellow, cReset)
		fmt.Printf("  %s│    Select each subscription → Cancel subscription%s\n", cYellow, cReset)
		fmt.Printf("  %s│%s\n", cYellow, cReset)
		fmt.Printf("  %s│  DO NOT cancel until you can see the Pax8 licenses assigned in the tenant.%s\n", cYellow, cReset)
		fmt.Printf("  %s└──────────────────────────────────────────────────────────────────%s\n", cYellow, cReset)
		fmt.Println()
		wait("Press Enter to continue to Pax8 product matching")

		skuMap = matchToPax8Products(migrationList, pax8Token)
		if skuMap == nil {
			return
		}
	}

	// ── Build and save TenantConfig ───────────────────────────────────────
	config := TenantConfig{
		TenantKey:           tenantKey,
		DisplayName:         displayName,
		MsTenantId:          tenantId,
		DefaultDomain:       domain,
		Greenfield:          greenfield,
		Pax8CompanyId:       "",
		Pax8CompanyNameHint: pax8Company,
		AlertEmail:          alertEmail,
		MicrosoftProvisioning: Provisioning{
			Mca2020FirstName:     "Adam",
			Mca2020LastName:      "Burnaman",
			Mca2020Email:         "services@netbitsystemsllc.com",
			Mca2020EffectiveDate: "2023-06-19",
			MsftContactFirstName: "Dylan",
			MsftContactLastName:  "Rumsey",
			MsftContactEmail:     "netbit@" + domain,
		},
		SkuMap: skuMap,
		IgnoreSkuPartNumbers: []string{
			"DYN365_AI_SERVICE_INSIGHTS", "FLOW_FREE", "POWER_BI_STANDARD",
			"CCIBOTS_PRIVPREV_VIRAL", "POWERAPPS_DEV", "POWERAPPS_VIRAL",
			"WINDOWS_STORE", "TEAMS_EXPLORATORY", "Microsoft_Teams_Rooms_Basic",
			"Microsoft_Teams_Audio_Conferencing_select_dial_out",
			"Teams_Premium_(for_Departments)",
		},
	}

	outPath := filepath.Join(root, "config", "tenants", tenantKey+".json")
	os.MkdirAll(filepath.Dir(outPath), 0755)
	data, _ := json.MarshalIndent(config, "", "  ")
	os.WriteFile(outPath, data, 0644)
	copyToClipboard(string(data))

	// ── Final instructions ────────────────────────────────────────────────
	bar("Setup Complete", "")
	fmt.Printf("  %s✓  Config saved: %s%s%s\n", cGreen, cCyan, outPath, cReset)
	fmt.Printf("  %s✓  JSON copied to clipboard.%s\n\n", cGreen, cReset)

	step("Last step — paste the TenantConfig into Azure Automation:")
	fmt.Println()
	step("1. Open the client's Azure Automation account:")
	step("   Azure portal → Automation Accounts → Pax8LicenseAutomation")
	step("2. Left sidebar → Shared Resources → Variables → + Add a variable")
	fmt.Println()
	fmt.Printf("   Name:      %sTenantConfig%s\n", cWhite, cReset)
	fmt.Println("   Type:      String")
	fmt.Println("   Value:     paste from clipboard (Ctrl+V)")
	fmt.Println("   Encrypted: No  →  click Create")
	fmt.Println()
	step("   If TenantConfig already exists: click the variable name → Edit value → replace → Save")
	fmt.Println()
	step("3. To confirm it's working:")
	step("   Process Automation → Runbooks → Start-Pax8LicenseSync → Start")
	step("   After it finishes, click Output to see the full sync log.")
	fmt.Printf("   Alerts go to %s%s%s when orders are placed or errors occur.\n", cCyan, alertEmail, cReset)
	fmt.Println()

	if !greenfield && len(migrationList) > 0 {
		fmt.Printf("  %s%s⚠  Don't forget — cancel these Microsoft direct subscriptions once Pax8 is confirmed active:%s\n", cBold, cYellow, cReset)
		for _, e := range migrationList {
			fmt.Printf("  %s   • %s%s\n", cYellow, e.DisplayName, cReset)
		}
		fmt.Println()
	}

	wait("Press Enter to return to the main menu")
}

// ── Azure Automation setup ─────────────────────────────────────────────────
func runAzureSetup(creds Credentials) {
	fmt.Println()

	// Step A: Automation account
	fmt.Printf("  %sStep A — Create the Azure Automation account%s\n\n", cWhite, cReset)
	step("Go to: " + cCyan + "https://portal.azure.com/#create/Microsoft.AutomationAccount" + cReset)
	step("Fill in ONLY these fields — leave everything else as the default:")
	fmt.Println()
	step("  Subscription:   Your subscription")
	step("                  (Where to find: Azure portal → Subscriptions, or the top of any resource blade)")
	step("  Resource Group: Your resource group, or create a new one named Pax8Automation")
	step("                  (Where to find: Azure portal → Resource groups)")
	step("  Account Name:   Pax8LicenseAutomation")
	step("  Region:         Central US")
	fmt.Println()
	step("  Advanced tab:   System assigned")
	step("  Networking tab: Public access")
	fmt.Println()
	step("Click Review + Create → Create. When deployment finishes, click Go to resource.")
	fmt.Println()
	wait("Press Enter once the account is open in the portal")

	// Step B: Modules
	fmt.Printf("\n  %sStep B — Import required PowerShell modules%s\n\n", cWhite, cReset)
	fmt.Printf("  %sDownloading module files...%s\n", cGray, cReset)
	modDir := root
	modules := []struct{ name, url string }{
		{"Microsoft.Graph.Authentication", "https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication"},
		{"Microsoft.Graph.Identity.DirectoryManagement", "https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Identity.DirectoryManagement"},
	}
	allDownloaded := true
	for _, m := range modules {
		dst := filepath.Join(modDir, m.name+".zip")
		if _, err := os.Stat(dst); err == nil {
			fmt.Printf("  %s✓  %s already downloaded%s\n", cGray, m.name, cReset)
			continue
		}
		resp, err := http.Get(m.url)
		if err != nil || resp.StatusCode != 200 {
			fail("Could not download " + m.name + " — check your internet connection.")
			allDownloaded = false
			continue
		}
		f, _ := os.Create(dst)
		io.Copy(f, resp.Body)
		f.Close()
		resp.Body.Close()
		ok(m.name + " downloaded")
	}
	if allDownloaded {
		fmt.Println()
		step("If you see 'Switch to Old Experience' at the top of the page, click it.")
		step("(Module upload only works in the old portal experience)")
		fmt.Println()
		step("Left sidebar → Shared Resources → Modules → + Add a module")
		step("Do this ONCE for EACH file below:")
		step("  1. Click Upload a file")
		step("  2. Browse to the file shown below")
		step("  3. Set Runtime version to 7.2")
		step("  4. Click Import")
		step("  5. Wait until Status shows Available before importing the next file")
		fmt.Println()
		for _, m := range modules {
			fmt.Printf("  %s%s%s\n", cCyan, filepath.Join(modDir, m.name+".zip"), cReset)
		}
		fmt.Println()
		step("Refresh the Modules list every 30 seconds until both show Status = Available.")
	}
	fmt.Println()
	wait("Press Enter once both modules show Status = Available")

	// Step C: Variables
	fmt.Printf("\n  %sStep C — Create Automation Variables%s\n\n", cWhite, cReset)
	step("Left sidebar → Shared Resources → Variables → + Add a variable")
	step("For each: Type = String. Set Encrypted exactly as shown. Click Create after each one.")
	fmt.Println()

	vars := []struct {
		name, value string
		enc         bool
	}{
		{"GitHubOwnerRepo", "netBitSystems/Pax8-License-Automation-Microsoft", false},
		{"GitHubBranch", "main", false},
		{"Pax8ClientId", creds.Pax8ClientId, true},
		{"Pax8ClientSecret", creds.Pax8ClientSecret, true},
		{"GraphClientId", creds.GraphClientId, true},
		{"GraphClientSecret", creds.GraphClientSecret, true},
		{"RunMode", "Both", false},
		{"RunExecute", "false", false},
		{"RunMockExecute", "true", false},
	}
	for i, v := range vars {
		encLabel := "No"
		if v.enc {
			encLabel = cYellow + "YES — toggle Encrypted ON" + cReset
		}
		fmt.Printf("  %s── Variable %d of %d %s\n", cBlue, i+1, len(vars), cReset)
		fmt.Printf("  Name:      %s%s%s\n", cWhite, v.name, cReset)
		fmt.Printf("  Value:     %s%s%s\n", cCyan, v.value, cReset)
		fmt.Printf("  Encrypted: %s\n\n", encLabel)
	}
	wait("Press Enter once all 9 variables are created")

	// Step D: Runbook
	fmt.Printf("\n  %sStep D — Create the runbook%s\n\n", cWhite, cReset)
	runbookPath := filepath.Join(root, "Start-Pax8LicenseSync.ps1")
	if _, err := os.Stat(runbookPath); err != nil {
		fmt.Printf("  %sDownloading runbook script...%s\n", cGray, cReset)
		rbResp, rbErr := http.Get("https://raw.githubusercontent.com/netBitSystems/Pax8-License-Automation-Microsoft/main/Start-Pax8LicenseSync.ps1")
		if rbErr == nil && rbResp.StatusCode == 200 {
			rbFile, _ := os.Create(runbookPath)
			io.Copy(rbFile, rbResp.Body)
			rbFile.Close()
			rbResp.Body.Close()
			ok("Runbook script downloaded")
		} else {
			fail("Could not download runbook script — check your internet connection.")
		}
	} else {
		ok("Runbook script already present")
	}
	fmt.Println()
	step("Process Automation → Runbooks → Create a runbook")
	step("  Name:         Start-Pax8LicenseSync")
	step("  Runbook type: PowerShell")
	step("  Runtime:      7.2")
	step("Click Create. When the editor opens:")
	fmt.Println()
	step("  1. Open this file in Notepad (right-click → Open with → Notepad):")
	fmt.Printf("     %s%s%s\n", cCyan, runbookPath, cReset)
	step("  2. Select all (Ctrl+A), copy (Ctrl+C)")
	step("  3. Click inside the Azure editor and paste (Ctrl+V)")
	step("  4. Click Save → Publish → confirm")
	fmt.Println()
	wait("Press Enter once the runbook is published")

	// Step E: Schedule
	fmt.Printf("\n  %sStep E — Set up hourly schedule%s\n\n", cWhite, cReset)
	step("On the runbook page, click Link to schedule → + Add a schedule")
	fmt.Println()
	step("Fill in the New Schedule form:")
	step("  Name:        HourlyLicenseSync")
	step("  Starts:      leave as-is")
	step("  Time zone:   leave as-is")
	step("  Recurrence:  select Recurring")
	step("  Recur every: 1 Hour")
	step("  Expiration:  No")
	step("Click Create. Then click the schedule name to select it, then click OK.")
	fmt.Println()
	wait("Press Enter once the schedule is linked")

	ok("Azure Automation infrastructure is ready")
	fmt.Println()
}

// ── License selection from catalog ────────────────────────────────────────
func selectLicensesFromCatalog(catalog []CatalogEntry) []CatalogEntry {
	var selected []CatalogEntry
	lastCat := ""
	for _, e := range catalog {
		if e.Category != lastCat {
			lastCat = e.Category
			fmt.Printf("\n  %s[ %s ]%s\n", cYellow, e.Category, cReset)
		}
		if askYN("    " + e.DisplayName) {
			selected = append(selected, e)
		}
	}
	return selected
}

// ── Pax8 product matching ──────────────────────────────────────────────────
func matchToPax8Products(entries []CatalogEntry, pax8Token string) []SkuMapEntry {
	bar("Pax8 Product Matching", "Match each license to the correct Pax8 product.")
	fmt.Println()
	step("Search the live Pax8 catalog and select the matching product for each license.")
	step("Prefer 'New Commerce' products when available — they match the current Microsoft CSP model.")
	fmt.Printf("  %sLoading Pax8 product catalog...%s\n\n", cGray, cReset)

	products, err := getAllPax8Products(pax8Token)
	if err != nil {
		fail("Could not load Pax8 products: " + err.Error())
		wait("Press Enter to return to menu")
		return nil
	}
	fmt.Printf("  %s%d products loaded.%s\n\n", cGray, len(products), cReset)

	var skuMap []SkuMapEntry
	for _, e := range entries {
		fmt.Printf("\n  %s── %s ──%s\n", cCyan, e.DisplayName, cReset)
		var chosen *Pax8Product
		for chosen == nil {
			searchTerm := ask("  Search term (press Enter to use '" + e.DisplayName + "')")
			if searchTerm == "" {
				searchTerm = e.DisplayName
			}
			results := searchProducts(products, searchTerm)
			if len(results) == 0 {
				fmt.Printf("  %sNo results.%s Try a shorter or different term.\n", cRed, cReset)
				continue
			}
			limit := 15
			if len(results) < limit {
				limit = len(results)
			}
			fmt.Println()
			for i := 0; i < limit; i++ {
				fmt.Printf("  [%d] %s\n", i+1, results[i].Name)
			}
			fmt.Printf("  [0] Search again\n\n")
			pickStr := ask("  Select number")
			n, parseErr := strconv.Atoi(pickStr)
			if parseErr == nil && n >= 1 && n <= limit {
				p := results[n-1]
				chosen = &p
				fmt.Printf("  %s✓ %s%s\n", cGreen, chosen.Name, cReset)
			}
		}

		bufStr := ask(fmt.Sprintf("  Buffer seats — spare seats to keep available at all times (default %d)", e.DefaultBuffer))
		maxStr := ask(fmt.Sprintf("  Max seats cap — never order beyond this total (default %d)", e.DefaultMaxSeats))
		buf := e.DefaultBuffer
		maxS := e.DefaultMaxSeats
		if n, err := strconv.Atoi(bufStr); err == nil {
			buf = n
		}
		if n, err := strconv.Atoi(maxStr); err == nil {
			maxS = n
		}

		skuMap = append(skuMap, SkuMapEntry{
			SkuPartNumber:       e.SkuPartNumber,
			SkuId:               e.SkuId,
			DisplayName:         e.DisplayName,
			Pax8ProductId:       chosen.Id,
			Pax8ProductNameHint: chosen.Name,
			Buffer:              buf,
			MaxSeats:            maxS,
		})
	}
	return skuMap
}

// ── Pax8 API ───────────────────────────────────────────────────────────────
func getPax8Token(clientId, clientSecret string) (string, error) {
	body := map[string]string{
		"grant_type":    "client_credentials",
		"client_id":     clientId,
		"client_secret": clientSecret,
		"audience":      "https://api.pax8.com",
	}
	data, _ := json.Marshal(body)
	resp, err := http.Post("https://api.pax8.com/v1/token", "application/json", bytes.NewReader(data))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	json.NewDecoder(resp.Body).Decode(&tok)
	if tok.AccessToken == "" {
		return "", fmt.Errorf("no access token in response")
	}
	return tok.AccessToken, nil
}

func promptForPax8Credentials(creds Credentials) (Credentials, string) {
	for {
		creds.Pax8ClientId = ask("  Client ID")
		creds.Pax8ClientSecret = ask("  Client Secret")
		token, err := getPax8Token(creds.Pax8ClientId, creds.Pax8ClientSecret)
		if err == nil {
			ok("Connected to Pax8")
			return creds, token
		}
		fail("Connection failed: " + err.Error())
		fmt.Println("  Check the values and try again.")
	}
}

func getAllPax8Products(token string) ([]Pax8Product, error) {
	var all []Pax8Product
	page := 0
	for {
		url := fmt.Sprintf("https://api.pax8.com/v1/products?page=%d&size=200", page)
		req, _ := http.NewRequest("GET", url, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Accept", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return nil, err
		}
		bodyBytes, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		var pr struct {
			Content []Pax8Product `json:"content"`
			Page    struct {
				TotalPages int `json:"totalPages"`
			} `json:"page"`
		}
		json.Unmarshal(bodyBytes, &pr)
		all = append(all, pr.Content...)
		if page >= pr.Page.TotalPages-1 || pr.Page.TotalPages == 0 {
			break
		}
		page++
	}
	return all, nil
}

func searchProducts(products []Pax8Product, term string) []Pax8Product {
	exclude := regexp.MustCompile(`(?i)Government|GCC|Non.?Profit|Education|Student|Faculty|Charity|Trial|Promo`)
	termRe := regexp.MustCompile(`(?i)` + regexp.QuoteMeta(term))
	var matches []Pax8Product
	for _, p := range products {
		if termRe.MatchString(p.Name) && !exclude.MatchString(p.Name) {
			matches = append(matches, p)
		}
	}
	sort.Slice(matches, func(i, j int) bool {
		iNCE := strings.Contains(matches[i].Name, "New Commerce")
		jNCE := strings.Contains(matches[j].Name, "New Commerce")
		if iNCE != jNCE {
			return iNCE
		}
		return len(matches[i].Name) < len(matches[j].Name)
	})
	if len(matches) > 50 {
		matches = matches[:50]
	}
	return matches
}

// ── Credentials ────────────────────────────────────────────────────────────
func credPath() string {
	return filepath.Join(root, "config", "credentials.json")
}

func loadCreds() Credentials {
	data, err := os.ReadFile(credPath())
	if err != nil {
		return Credentials{}
	}
	var c Credentials
	json.Unmarshal(data, &c)
	return c
}

func saveCreds(c Credentials) {
	data, _ := json.MarshalIndent(c, "", "  ")
	os.WriteFile(credPath(), data, 0600)
}

// ── Catalog ────────────────────────────────────────────────────────────────
func loadCatalog() []CatalogEntry {
	catalogPath := filepath.Join(root, "config", "sku-catalog.json")
	data, err := os.ReadFile(catalogPath)
	if err != nil {
		os.MkdirAll(filepath.Dir(catalogPath), 0755)
		resp, dlErr := http.Get("https://raw.githubusercontent.com/netBitSystems/Pax8-License-Automation-Microsoft/main/config/sku-catalog.json")
		if dlErr != nil || resp.StatusCode != 200 {
			return nil
		}
		defer resp.Body.Close()
		data, _ = io.ReadAll(resp.Body)
		os.WriteFile(catalogPath, data, 0644)
	}
	var cf CatalogFile
	json.Unmarshal(data, &cf)
	return cf.Licenses
}

// ── UI helpers ─────────────────────────────────────────────────────────────
func bar(title, sub string) {
	fmt.Println()
	fmt.Printf("%s%s%s\n", cBlue, strings.Repeat("─", 62), cReset)
	fmt.Printf("%s  %s%s\n", cBold+cWhite, title, cReset)
	if sub != "" {
		fmt.Printf("%s  %s%s\n", cGray, sub, cReset)
	}
	fmt.Printf("%s%s%s\n", cBlue, strings.Repeat("─", 62), cReset)
	fmt.Println()
}

func section(num, title string) {
	fmt.Println()
	fmt.Printf("%s%s── %s — %s%s\n\n", cBlue, cBold, num, title, cReset)
}

func step(text string) { fmt.Printf("  %s%s\n", text, cReset) }
func ok(text string)   { fmt.Printf("  %s✓  %s%s\n", cGreen, text, cReset) }
func fail(text string) { fmt.Printf("  %s✗  %s%s\n", cRed, text, cReset) }

func ask(prompt string) string {
	fmt.Printf("%s: ", prompt)
	if scanner.Scan() {
		return strings.TrimSpace(scanner.Text())
	}
	return ""
}

func askYN(prompt string) bool {
	r := ask("  " + prompt + " (y/N)")
	return strings.HasPrefix(strings.ToLower(r), "y")
}

func wait(prompt string) {
	fmt.Println()
	ask("  " + prompt)
}

func copyToClipboard(text string) {
	cmd := exec.Command("clip")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}
	io.WriteString(stdin, text)
	stdin.Close()
	cmd.Wait()
}

func cls() {
	cmd := exec.Command("cmd", "/c", "cls")
	cmd.Stdout = os.Stdout
	cmd.Run()
}

// ── Enable ANSI on Windows ─────────────────────────────────────────────────
func enableANSI() {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	setConsoleMode := kernel32.NewProc("SetConsoleMode")
	getConsoleMode := kernel32.NewProc("GetConsoleMode")
	h, _ := syscall.GetStdHandle(syscall.STD_OUTPUT_HANDLE)
	var mode uint32
	getConsoleMode.Call(uintptr(h), uintptr(unsafe.Pointer(&mode)))
	setConsoleMode.Call(uintptr(h), uintptr(mode|0x0004)) // ENABLE_VIRTUAL_TERMINAL_PROCESSING
}
