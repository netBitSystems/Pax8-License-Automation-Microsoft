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
	appVersion = "v1.8 - dynamic downsizing at renewal"
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

type MicrosoftSkuFile struct {
	Skus []MicrosoftSku `json:"skus"`
}

type MicrosoftSku struct {
	DisplayName   string `json:"displayName"`
	SkuPartNumber string `json:"skuPartNumber"`
	SkuId         string `json:"skuId"`
}

type Pax8Product struct {
	Id   string `json:"id"`
	Name string `json:"name"`
}

type Pax8Company struct {
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
	InitialSeats        int    `json:"initialSeats,omitempty"`
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
	fmt.Printf("  %s[2]%s  Add SKUs to an existing client\n", cCyan, cReset)
	fmt.Printf("  %s[3]%s  Exit\n", cCyan, cReset)
	fmt.Println()
	choice := ask("  Enter choice")
	switch choice {
	case "1":
		runClientWizard()
	case "2":
		runAddSkusWizard()
	case "3":
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
	step("Pax8 company:")
	step("  Where to find: Pax8 portal → Companies tab → find the client")
	fmt.Printf("  %sSearching Pax8 companies...%s\n", cGray, cReset)
	companies, compErr := getAllPax8Companies(pax8Token)
	var pax8CompanyId, pax8Company string
	if compErr != nil || len(companies) == 0 {
		fail("Could not load companies from Pax8 — entering name manually.")
		pax8Company = ask("  Pax8 company name")
	} else {
		fmt.Printf("  %s%d companies loaded.%s\n", cGray, len(companies), cReset)
		for pax8CompanyId == "" {
			searchTerm := ask("  Search company name")
			matches := searchCompanies(companies, searchTerm)
			if len(matches) == 0 {
				fmt.Printf("  %sNo matches.%s Try a different term.\n", cRed, cReset)
				continue
			}
			limit := 10
			if len(matches) < limit {
				limit = len(matches)
			}
			fmt.Println()
			for i := 0; i < limit; i++ {
				fmt.Printf("  [%d] %s\n", i+1, matches[i].Name)
			}
			fmt.Printf("  [0] Search again\n\n")
			pickStr := ask("  Select number")
			n, parseErr := strconv.Atoi(pickStr)
			if parseErr == nil && n >= 1 && n <= limit {
				pax8CompanyId = matches[n-1].Id
				pax8Company = matches[n-1].Name
				fmt.Printf("  %s✓ %s  (%s)%s\n", cGreen, pax8Company, pax8CompanyId, cReset)
			}
		}
	}

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
		step("Not listed? After the catalog you can search the full Pax8 catalog to add custom SKUs.")
		fmt.Println()

		selected := selectLicensesFromCatalog(catalog)
		var products []Pax8Product
		loaded := true
		if len(selected) > 0 {
			fmt.Printf("\n  %s%d license(s) selected.%s\n", cGreen, len(selected), cReset)
			skuMap, products, loaded = matchToPax8Products(selected, pax8Token)
		} else {
			products, loaded = loadPax8Catalog(pax8Token)
		}
		if !loaded {
			return
		}
		skuMap = append(skuMap, addCustomPax8Skus(products, partNumberSet(skuMap))...)
		if len(skuMap) == 0 {
			fail("No licenses configured. At least one is required.")
			wait("Press Enter to return to menu")
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

		var loaded bool
		skuMap, _, loaded = matchToPax8Products(migrationList, pax8Token)
		if !loaded {
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
		Pax8CompanyId:       pax8CompanyId,
		Pax8CompanyNameHint: pax8Company,
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
	step("   Alert emails go to services@netbitsystemsllc.com on orders and errors.")
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

// ── Add SKUs to existing client ────────────────────────────────────────────
func runAddSkusWizard() {
	cls()
	bar("Add SKUs to Existing Client", "Add new license SKUs to a client that is already set up.")

	// ── Step 1: Select the client ─────────────────────────────────────────
	section("Step 1 of 4", "Select Client")
	config, srcPath, found := pickTenantConfig()
	if !found {
		wait("Press Enter to return to the main menu")
		return
	}
	fmt.Printf("\n  %s✓ Loaded %s (%s)%s\n", cGreen, config.DisplayName, config.TenantKey, cReset)

	// ── Step 2: Show currently configured SKUs ────────────────────────────
	section("Step 2 of 4", "Currently Configured SKUs")
	if len(config.SkuMap) == 0 {
		fmt.Printf("  %sNo SKUs configured yet.%s\n", cGray, cReset)
	} else {
		for _, e := range config.SkuMap {
			fmt.Printf("  %s•%s %s %s(%s)%s\n", cGreen, cReset, e.DisplayName, cGray, e.SkuPartNumber, cReset)
		}
	}

	// ── Step 3: Pax8 connection ───────────────────────────────────────────
	section("Step 3 of 4", "Pax8 Connection")
	pax8Token := connectPax8()

	// ── Step 4: Add SKUs from the Pax8 catalog ────────────────────────────
	section("Step 4 of 4", "Add SKUs from the Pax8 Catalog")
	fmt.Println()
	step("Search the live Pax8 catalog for the product(s) to add for this client.")
	products, loaded := loadPax8Catalog(pax8Token)
	if !loaded {
		return
	}

	newEntries := addCustomPax8Skus(products, partNumberSet(config.SkuMap))
	if len(newEntries) == 0 {
		fail("No SKUs added. Nothing to update.")
		wait("Press Enter to return to the main menu")
		return
	}

	// Merge new entries into the existing skuMap (replace on match, else append).
	for _, ne := range newEntries {
		replaced := false
		for i := range config.SkuMap {
			if strings.EqualFold(config.SkuMap[i].SkuPartNumber, ne.SkuPartNumber) {
				config.SkuMap[i] = ne
				replaced = true
				break
			}
		}
		if !replaced {
			config.SkuMap = append(config.SkuMap, ne)
		}
	}

	// Save the updated config locally and copy to clipboard.
	outPath := filepath.Join(root, "config", "tenants", config.TenantKey+".json")
	os.MkdirAll(filepath.Dir(outPath), 0755)
	data, _ := json.MarshalIndent(config, "", "  ")
	os.WriteFile(outPath, data, 0644)
	copyToClipboard(string(data))

	// ── Final instructions ────────────────────────────────────────────────
	bar("SKUs Added", "")
	fmt.Printf("  %s✓  Updated config saved: %s%s%s\n", cGreen, cCyan, outPath, cReset)
	if srcPath != "" && !strings.EqualFold(srcPath, outPath) {
		fmt.Printf("  %s   (loaded from %s)%s\n", cGray, srcPath, cReset)
	}
	fmt.Printf("  %s✓  Updated JSON copied to clipboard.%s\n\n", cGreen, cReset)

	fmt.Printf("  %sNewly added SKUs:%s\n", cWhite, cReset)
	for _, e := range newEntries {
		fmt.Printf("  %s•%s %s\n", cGreen, cReset, e.DisplayName)
	}
	fmt.Println()

	step("Update the client's Azure Automation TenantConfig variable:")
	fmt.Println()
	step("1. Azure portal → Automation Accounts → Pax8LicenseAutomation")
	step("2. Shared Resources → Variables → click TenantConfig → Edit value")
	step("3. Select all (Ctrl+A), delete, then paste from clipboard (Ctrl+V) → Save")
	fmt.Println()
	step("The next hourly run picks up the new SKUs. For a license still on Microsoft direct,")
	step("Pax8 ordering only begins once the direct subscription is cancelled.")
	fmt.Println()

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
// selectPax8Product runs the interactive search/select loop against the loaded
// Pax8 catalog. defaultTerm pre-fills the search (Enter accepts it). When
// allowCancel is true and there is no default term, an empty entry cancels and
// returns nil; otherwise the loop continues until a product is chosen.
func selectPax8Product(products []Pax8Product, defaultTerm string, allowCancel bool) *Pax8Product {
	for {
		prompt := "  Search term"
		if defaultTerm != "" {
			prompt = "  Search term (press Enter to use '" + defaultTerm + "')"
		} else if allowCancel {
			prompt = "  Search term (press Enter to cancel)"
		}
		searchTerm := ask(prompt)
		if searchTerm == "" {
			if defaultTerm != "" {
				searchTerm = defaultTerm
			} else if allowCancel {
				return nil
			} else {
				continue
			}
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
			fmt.Printf("  %s✓ %s%s\n", cGreen, p.Name, cReset)
			return &p
		}
	}
}

// loadPax8Catalog fetches the full live Pax8 product list with progress output.
func loadPax8Catalog(pax8Token string) ([]Pax8Product, bool) {
	fmt.Printf("  %sLoading Pax8 product catalog...%s\n\n", cGray, cReset)
	products, err := getAllPax8Products(pax8Token)
	if err != nil {
		fail("Could not load Pax8 products: " + err.Error())
		wait("Press Enter to return to menu")
		return nil, false
	}
	fmt.Printf("  %s%d products loaded.%s\n", cGray, len(products), cReset)
	return products, true
}

// matchToPax8Products maps each curated catalog entry to a Pax8 product. It returns
// the mapped entries, the loaded Pax8 catalog (for reuse), and whether the catalog
// loaded successfully.
func matchToPax8Products(entries []CatalogEntry, pax8Token string) ([]SkuMapEntry, []Pax8Product, bool) {
	bar("Pax8 Product Matching", "Match each license to the correct Pax8 product.")
	fmt.Println()
	step("Search the live Pax8 catalog and select the matching product for each license.")
	step("Prefer 'New Commerce' products when available — they match the current Microsoft CSP model.")
	products, loaded := loadPax8Catalog(pax8Token)
	if !loaded {
		return nil, nil, false
	}
	fmt.Println()

	var skuMap []SkuMapEntry
	for _, e := range entries {
		fmt.Printf("\n  %s── %s ──%s\n", cCyan, e.DisplayName, cReset)
		chosen := selectPax8Product(products, e.DisplayName, false)
		if chosen == nil {
			continue
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
	return skuMap, products, true
}

// addCustomPax8Skus lets the user search the live Pax8 catalog and add SKUs that are
// not in the curated catalog. The Pax8 product is what gets ordered; the Microsoft
// license (picked by friendly name) is what the sync engine counts in the tenant.
// taken holds the skuPartNumbers already configured (lowercased) and is updated here.
func addCustomPax8Skus(products []Pax8Product, taken map[string]bool) []SkuMapEntry {
	msSkus := loadMicrosoftSkus()
	var out []SkuMapEntry
	for {
		fmt.Println()
		if !askYN("Add a SKU by searching the full Pax8 catalog?") {
			break
		}
		fmt.Printf("\n  %s── Pax8 product (what gets ordered) ──%s\n", cCyan, cReset)
		chosen := selectPax8Product(products, "", true)
		if chosen == nil {
			continue
		}

		var partNum, skuId, defName string
		if len(msSkus) > 0 {
			fmt.Printf("\n  %s── Microsoft license (what the tool counts in the tenant) ──%s\n", cCyan, cReset)
			step("Pick the Microsoft license this product provisions (auto-searched from the Pax8 name).")
			ms := selectMicrosoftSku(msSkus, cleanProductName(chosen.Name))
			partNum, skuId, defName = ms.SkuPartNumber, ms.SkuId, ms.DisplayName
		} else {
			fmt.Println()
			fail("Microsoft license list unavailable; enter the skuPartNumber manually.")
			partNum = ask("  Microsoft skuPartNumber")
			skuId = ask("  Microsoft skuId (optional — press Enter to skip)")
			defName = chosen.Name
		}
		if partNum == "" {
			fail("Skipped — no Microsoft license identifier provided.")
			continue
		}
		if taken[strings.ToLower(partNum)] {
			fail("That Microsoft license is already configured for this client. Skipped.")
			continue
		}

		displayName := ask("  Display name (press Enter to use '" + defName + "')")
		if displayName == "" {
			displayName = defName
		}
		buf := promptInt("  Buffer seats — spare seats to keep available (default 2)", 2)
		maxS := promptInt("  Max seats cap — never order beyond this total (default 50)", 50)
		fmt.Println()
		step("If this license is brand new to the client (not in their Microsoft 365 yet), how many")
		step("seats should the first Pax8 order buy? Enter 0 if it's already in use (top-up only).")
		initSeats := promptInt("  Initial seats for a brand-new license (default 0)", 0)
		if initSeats > maxS {
			maxS = initSeats
			fmt.Printf("  %sMax seats raised to %d to fit the initial order.%s\n", cGray, maxS, cReset)
		}

		out = append(out, SkuMapEntry{
			SkuPartNumber:       partNum,
			SkuId:               skuId,
			DisplayName:         displayName,
			Pax8ProductId:       chosen.Id,
			Pax8ProductNameHint: chosen.Name,
			Buffer:              buf,
			MaxSeats:            maxS,
			InitialSeats:        initSeats,
		})
		taken[strings.ToLower(partNum)] = true
		fmt.Printf("  %s✓ Added %s%s\n", cGreen, displayName, cReset)
	}
	return out
}

// cleanProductName strips bracketed suffixes (e.g. "[New Commerce Experience]") so the
// Pax8 product name can seed the Microsoft license search.
func cleanProductName(name string) string {
	if i := strings.Index(name, "["); i > 0 {
		name = name[:i]
	}
	return strings.TrimSpace(name)
}

// searchMicrosoftSkus returns Microsoft licenses matching term by display name or code.
func searchMicrosoftSkus(skus []MicrosoftSku, term string) []MicrosoftSku {
	termRe := regexp.MustCompile(`(?i)` + regexp.QuoteMeta(term))
	var matches []MicrosoftSku
	for _, s := range skus {
		if termRe.MatchString(s.DisplayName) || termRe.MatchString(s.SkuPartNumber) {
			matches = append(matches, s)
		}
	}
	sort.Slice(matches, func(i, j int) bool {
		return len(matches[i].DisplayName) < len(matches[j].DisplayName)
	})
	if len(matches) > 50 {
		matches = matches[:50]
	}
	return matches
}

// selectMicrosoftSku finds a Microsoft license. It searches automatically using
// defaultTerm (derived from the Pax8 product name) and shows the matches to pick from,
// so no typing is needed in the common case. Picking [0] (or an empty default / no
// matches) prompts for a typed search term.
func selectMicrosoftSku(skus []MicrosoftSku, defaultTerm string) MicrosoftSku {
	term := strings.TrimSpace(defaultTerm)
	for {
		if term == "" {
			term = strings.TrimSpace(ask("  Search Microsoft license name"))
			if term == "" {
				continue
			}
		}
		results := searchMicrosoftSkus(skus, term)
		if len(results) == 0 {
			fmt.Printf("  %sNo Microsoft licenses match '%s'.%s Type part of the name.\n", cRed, term, cReset)
			term = ""
			continue
		}
		limit := 15
		if len(results) < limit {
			limit = len(results)
		}
		fmt.Printf("\n  %sMicrosoft licenses matching '%s':%s\n", cGray, term, cReset)
		for i := 0; i < limit; i++ {
			fmt.Printf("  [%d] %s  %s(%s)%s\n", i+1, results[i].DisplayName, cGray, results[i].SkuPartNumber, cReset)
		}
		fmt.Printf("  [0] Search by a different name\n\n")
		n, perr := strconv.Atoi(ask("  Select number"))
		if perr == nil && n >= 1 && n <= limit {
			s := results[n-1]
			fmt.Printf("  %s✓ %s%s\n", cGreen, s.DisplayName, cReset)
			return s
		}
		// 0 or invalid input: prompt for a typed search on the next pass.
		term = ""
	}
}

// partNumberSet returns the lowercased skuPartNumbers present in entries.
func partNumberSet(entries []SkuMapEntry) map[string]bool {
	m := map[string]bool{}
	for _, e := range entries {
		m[strings.ToLower(e.SkuPartNumber)] = true
	}
	return m
}

// promptInt asks for an integer, returning def when the input is blank or invalid.
func promptInt(prompt string, def int) int {
	if n, err := strconv.Atoi(ask(prompt)); err == nil {
		return n
	}
	return def
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

func getAllPax8Companies(token string) ([]Pax8Company, error) {
	var all []Pax8Company
	page := 0
	for {
		url := fmt.Sprintf("https://api.pax8.com/v1/companies?page=%d&size=200", page)
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
			Content []Pax8Company `json:"content"`
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

func searchCompanies(companies []Pax8Company, term string) []Pax8Company {
	termRe := regexp.MustCompile(`(?i)` + regexp.QuoteMeta(term))
	var matches []Pax8Company
	for _, c := range companies {
		if termRe.MatchString(c.Name) {
			matches = append(matches, c)
		}
	}
	sort.Slice(matches, func(i, j int) bool {
		return len(matches[i].Name) < len(matches[j].Name)
	})
	return matches
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

// loadMicrosoftSkus loads the Microsoft license reference (friendly name, skuPartNumber, skuId).
func loadMicrosoftSkus() []MicrosoftSku {
	path := filepath.Join(root, "config", "microsoft-skus.json")
	data, err := os.ReadFile(path)
	if err != nil {
		os.MkdirAll(filepath.Dir(path), 0755)
		resp, dlErr := http.Get("https://raw.githubusercontent.com/netBitSystems/Pax8-License-Automation-Microsoft/main/config/microsoft-skus.json")
		if dlErr != nil || resp.StatusCode != 200 {
			return nil
		}
		defer resp.Body.Close()
		data, _ = io.ReadAll(resp.Body)
		os.WriteFile(path, data, 0644)
	}
	var f MicrosoftSkuFile
	json.Unmarshal(data, &f)
	return f.Skus
}

// ── Tenant config selection (Add SKUs) ─────────────────────────────────────
// pickTenantConfig lets the user choose a local tenant config or paste one.
// Returns the config, its source path (empty when pasted), and whether selection succeeded.
func pickTenantConfig() (TenantConfig, string, bool) {
	paths := listLocalTenantConfigs()
	fmt.Println()
	if len(paths) > 0 {
		step("Local client configs found:")
		fmt.Println()
		for i, p := range paths {
			label := filepath.Base(p)
			if cfg, err := loadTenantConfig(p); err == nil && cfg.DisplayName != "" {
				label = fmt.Sprintf("%s  %s(%s)%s", cfg.DisplayName, cGray, filepath.Base(p), cReset)
			}
			fmt.Printf("  [%d] %s\n", i+1, label)
		}
		fmt.Printf("  [0] None of these — paste the TenantConfig JSON instead\n\n")
		for {
			pick := ask("  Select number")
			n, err := strconv.Atoi(pick)
			if err != nil {
				continue
			}
			if n == 0 {
				break
			}
			if n >= 1 && n <= len(paths) {
				cfg, lerr := loadTenantConfig(paths[n-1])
				if lerr != nil {
					fail("Could not read that config: " + lerr.Error())
					return TenantConfig{}, "", false
				}
				return cfg, paths[n-1], true
			}
		}
	} else {
		step("No local client configs found in config/tenants.")
	}
	cfg, parsedOK := readPastedTenantConfig()
	if !parsedOK {
		return TenantConfig{}, "", false
	}
	return cfg, "", true
}

// listLocalTenantConfigs returns paths to config/tenants/*.json, excluding the template.
func listLocalTenantConfigs() []string {
	dir := filepath.Join(root, "config", "tenants")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var paths []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(strings.ToLower(name), ".json") {
			continue
		}
		if strings.EqualFold(name, "_template.json") {
			continue
		}
		paths = append(paths, filepath.Join(dir, name))
	}
	sort.Strings(paths)
	return paths
}

func loadTenantConfig(path string) (TenantConfig, error) {
	var cfg TenantConfig
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	err = json.Unmarshal(data, &cfg)
	return cfg, err
}

// readPastedTenantConfig reads a multi-line JSON blob terminated by a line containing END.
func readPastedTenantConfig() (TenantConfig, bool) {
	var cfg TenantConfig
	fmt.Println()
	step("Paste the full TenantConfig JSON below.")
	step("After pasting, press Enter, then type END on its own line and press Enter:")
	fmt.Println()
	var sb strings.Builder
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "END" {
			break
		}
		sb.WriteString(line)
		sb.WriteString("\n")
	}
	if err := json.Unmarshal([]byte(sb.String()), &cfg); err != nil {
		fail("That JSON could not be parsed: " + err.Error())
		return cfg, false
	}
	if cfg.TenantKey == "" {
		fail("Pasted config is missing tenantKey — cannot continue.")
		return cfg, false
	}
	return cfg, true
}

// connectPax8 ensures a usable Pax8 token, prompting for credentials if needed.
func connectPax8() string {
	creds := loadCreds()
	if creds.Pax8ClientId != "" && creds.Pax8ClientSecret != "" {
		if tok, err := getPax8Token(creds.Pax8ClientId, creds.Pax8ClientSecret); err == nil {
			ok("Pax8 connected")
			return tok
		}
	}
	fmt.Println()
	step("Enter your Pax8 API credentials (Pax8 portal → Settings → Integrations → API Credentials).")
	fmt.Println()
	creds, token := promptForPax8Credentials(creds)
	saveCreds(creds)
	return token
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
