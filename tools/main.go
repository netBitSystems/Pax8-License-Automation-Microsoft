// pax8tools - Pax8 License Automation CLI
// Builds to a single standalone Windows executable with no runtime dependencies.
// go build -o ../pax8tools.exe .
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
	cReset  = "\033[0m"
	cBlue   = "\033[34m"
	cCyan   = "\033[36m"
	cGreen  = "\033[32m"
	cRed    = "\033[31m"
	cYellow = "\033[33m"
	cGray   = "\033[90m"
	cWhite  = "\033[97m"
	cBold   = "\033[1m"
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
	GitHubPat         string `json:"githubPat"`
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
	TenantKey              string       `json:"tenantKey"`
	DisplayName            string       `json:"displayName"`
	MsTenantId             string       `json:"msTenantId"`
	DefaultDomain          string       `json:"defaultDomain"`
	Greenfield             bool         `json:"greenfield"`
	Pax8CompanyId          string       `json:"pax8CompanyId"`
	Pax8CompanyNameHint    string       `json:"pax8CompanyNameHint"`
	MicrosoftProvisioning  Provisioning `json:"microsoftProvisioning"`
	SkuMap                 []SkuMapEntry `json:"skuMap"`
	IgnoreSkuPartNumbers   []string     `json:"ignoreSkuPartNumbers"`
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
	fmt.Println()
	fmt.Printf("  %s[1]%s  First-time setup\n", cCyan, cReset)
	fmt.Printf("  %s[2]%s  Add a new client\n", cCyan, cReset)
	fmt.Printf("  %s[3]%s  Verify it's working\n", cCyan, cReset)
	fmt.Printf("  %s[4]%s  Exit\n", cCyan, cReset)
	fmt.Println()
	choice := ask("  Enter choice")
	switch choice {
	case "1":
		runSetup()
	case "2":
		runAddClient()
	case "3":
		runPwsh("Test-Local.ps1", false)
	case "4":
		os.Exit(0)
	}
}

// ── Setup wizard ──────────────────────────────────────────────────────────
func runSetup() {
	cls()
	bar("First-Time Setup", "Connects this tool to Pax8, Microsoft, and GitHub.")
	fmt.Printf("\n  You need admin access to portal.pax8.com, portal.azure.com, and github.com.\n")
	fmt.Printf("  Takes about 20 minutes. Safe to re-run — completed steps are skipped.\n\n")
	wait("Press Enter to start")

	creds := loadCreds()

	// ── 1. Pax8 ──
	section("1 / 3", "Pax8 API Credential")
	pax8Token := ""
	if creds.Pax8ClientId != "" && creds.Pax8ClientSecret != "" {
		tok, err := getPax8Token(creds.Pax8ClientId, creds.Pax8ClientSecret)
		if err == nil {
			pax8Token = tok
			ok("Pax8 already connected — skipped")
		}
	}
	if pax8Token == "" {
		step("Go to:  " + cCyan + "https://portal.pax8.com" + cReset)
		step("Integrations > Overview > API keys generated > Add API Credential")
		step("Enter a client name and click Add. Copy the Client ID and Client Secret.")
		fmt.Println()
		for pax8Token == "" {
			creds.Pax8ClientId = ask("  Client ID")
			creds.Pax8ClientSecret = ask("  Client Secret")
			tok, err := getPax8Token(creds.Pax8ClientId, creds.Pax8ClientSecret)
			if err == nil {
				pax8Token = tok
				ok("Connected to Pax8")
			} else {
				fail("Connection failed: " + err.Error())
			}
		}
	}

	// ── 2. Entra ──
	section("2 / 3", "Microsoft Entra App Registration")
	guidRe := regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	if creds.GraphClientId != "" && guidRe.MatchString(creds.GraphClientId) && len(creds.GraphClientSecret) > 10 {
		ok("Graph credentials already on file — skipped")
	} else {
		step("Go to:  " + cCyan + "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/CreateApplicationBlade" + cReset)
		fmt.Println()
		step("  Name:           Pax8 License Automation")
		step("  Account type:   Accounts in this organizational directory only (Single tenant)")
		step("  Redirect URI:   leave blank  →  click Register")
		fmt.Println()
		step("API permissions > Add > Microsoft Graph > Application permissions:")
		step("  Organization.Read.All   Directory.Read.All   Mail.Send")
		step("Then click Grant admin consent.")
		fmt.Println()
		step("Certificates & secrets > New client secret > 24 months > Add")
		step("Copy the VALUE column (NOT the Secret ID) — click the copy icon next to the value.")
		fmt.Println()
		step("Then click Overview in the left sidebar to get the Application (client) ID.")
		fmt.Println()
		for !(guidRe.MatchString(creds.GraphClientId) && len(creds.GraphClientSecret) > 10) {
			creds.GraphClientId = ask("  Application (client) ID  (from the Overview page)")
			creds.GraphClientSecret = ask("  Client Secret Value      (the VALUE column, not the Secret ID)")
			if !(guidRe.MatchString(creds.GraphClientId) && len(creds.GraphClientSecret) > 10) {
				fail("App ID must be a GUID and secret must be at least 10 characters.")
			}
		}
		ok("Graph credentials saved")
	}

	saveCreds(creds)
	ok("Credentials saved to " + credPath())

	// ── 3. Azure Automation ──
	section("3 / 3", "Azure Automation")

	fmt.Printf("\n  %sStep A — Create Automation account + import modules%s\n\n", cWhite, cReset)
	step("Go to:  " + cCyan + "https://portal.azure.com/#create/Microsoft.AutomationAccount" + cReset)
	step("  Name: Pax8LicenseAutomation    PowerShell runtime: 7.2")
	step("Once created: Shared Resources > Modules > Add from gallery (runtime 7.2):")
	step("  Microsoft.Graph.Authentication")
	step("  Microsoft.Graph.Identity.DirectoryManagement")
	step("Wait until both show Status = Available.")
	fmt.Println()
	wait("Press Enter once both modules show Available")

	fmt.Printf("\n  %sStep B — Create Automation Variables%s\n", cWhite, cReset)
	fmt.Printf("  %sShared Resources > Variables > Add a variable (Type = String)%s\n", cGray, cReset)
	fmt.Printf("  %s9 variables total. Variables marked [ENC] must have Encrypted toggled ON.%s\n\n", cGray, cReset)

	vars := []struct{ name, value string; enc bool }{
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
	for _, v := range vars {
		tag := "     "
		col := cGray
		if v.enc {
			tag = "[ENC]"
			col = cYellow
		}
		fmt.Printf("  %s%s  %-24s %s%s\n", col, tag, v.name, v.value, cReset)
	}
	fmt.Println()
	wait("Press Enter once all 9 variables are created")

	fmt.Printf("\n  %sStep C — Create the runbook%s\n\n", cWhite, cReset)
	step("Process Automation > Runbooks > Create a runbook")
	step("  Name: Start-Pax8LicenseSync    Type: PowerShell    Runtime: 7.2")
	step("Open this file in Notepad and paste its contents into the editor:")
	fmt.Printf("  %s%s%s\n", cCyan, filepath.Join(root, "Start-Pax8LicenseSync.ps1"), cReset)
	step("Save, then Publish.")
	fmt.Println()
	wait("Press Enter once the runbook is published")

	fmt.Printf("\n  %sStep D — Schedule daily runs%s\n\n", cWhite, cReset)
	step("Schedules > Add a schedule")
	step("  Name: DailyLicenseSync    Recurring: every 1 Day    No expiration")
	step("Runbooks > Start-Pax8LicenseSync > Schedules > Add > link DailyLicenseSync")
	fmt.Println()
	wait("Press Enter once the schedule is linked")

	bar("Setup complete", "")
	fmt.Println()
	fmt.Printf("  Next:  add a client → %s[2]%s in the menu\n", cCyan, cReset)
	fmt.Printf("         dry-run test → %s[3]%s in the menu\n", cCyan, cReset)
	fmt.Printf("         mock test in Azure → Runbooks > Start-Pax8LicenseSync > Start\n")
	fmt.Println()
	if askYN("Add first client now?") {
		runAddClient()
	}
}

// ── Add client ─────────────────────────────────────────────────────────────
func runAddClient() {
	cls()
	bar("Add New Client", "")

	creds := loadCreds()
	if creds.Pax8ClientId == "" {
		fail("Run setup first (option 1) to configure credentials.")
		wait("Press Enter")
		return
	}

	fmt.Println()
	displayName := ask("  Client company name")
	tenantId := ask("  Microsoft Tenant ID")
	domain := ask("  Default domain (e.g. acmecorp.com)")
	pax8Company := ask("  Pax8 company name (as shown in Pax8)")

	// Build tenant key
	tenantKey := regexp.MustCompile(`[^a-z0-9]`).ReplaceAllString(strings.ToLower(displayName), "")
	if len(tenantKey) > 20 {
		tenantKey = tenantKey[:20]
	}

	greenfield := askYN("Greenfield? (no existing Microsoft subscriptions)")

	fmt.Printf("\n  %sTenant key: %s%s\n\n", cGray, tenantKey, cReset)

	// License selection
	bar("License Selection", "Type Y to include, Enter to skip.")
	catalog := loadCatalog()
	if len(catalog) == 0 {
		fail("Could not load sku-catalog.json")
		wait("Press Enter")
		return
	}

	selected := []CatalogEntry{}
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
	if len(selected) == 0 {
		fail("No licenses selected.")
		wait("Press Enter")
		return
	}
	fmt.Printf("\n  %s%d license(s) selected.%s\n", cGreen, len(selected), cReset)

	// Pax8 product matching
	bar("Pax8 Product Matching", "Search the live Pax8 catalog for each license.")
	fmt.Printf("  %sLoading Pax8 products...%s\n\n", cGray, cReset)

	pax8Token, err := getPax8Token(creds.Pax8ClientId, creds.Pax8ClientSecret)
	if err != nil {
		fail("Pax8 connection failed: " + err.Error())
		wait("Press Enter")
		return
	}

	products, err := getAllPax8Products(pax8Token)
	if err != nil {
		fail("Could not load Pax8 products: " + err.Error())
		wait("Press Enter")
		return
	}
	fmt.Printf("  %s%d products loaded.%s\n\n", cGray, len(products), cReset)

	skuMap := []SkuMapEntry{}
	for _, e := range selected {
		fmt.Printf("\n  %s── %s ──%s\n", cCyan, e.DisplayName, cReset)
		var chosenProduct *Pax8Product
		for chosenProduct == nil {
			searchTerm := ask("  Search term (Enter = '" + e.DisplayName + "')")
			if searchTerm == "" {
				searchTerm = e.DisplayName
			}
			results := searchProducts(products, searchTerm)
			if len(results) == 0 {
				fmt.Printf("  %sNo results.%s Try a different term.\n", cRed, cReset)
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
				chosenProduct = &p
				fmt.Printf("  %sOK: %s%s\n", cGreen, chosenProduct.Name, cReset)
			}
		}

		bufStr := ask(fmt.Sprintf("  Buffer seats (default %d)", e.DefaultBuffer))
		maxStr := ask(fmt.Sprintf("  Max seats cap (default %d)", e.DefaultMaxSeats))
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
			Pax8ProductId:       chosenProduct.Id,
			Pax8ProductNameHint: chosenProduct.Name,
			Buffer:              buf,
			MaxSeats:            maxS,
		})
	}

	// Build and write config
	config := TenantConfig{
		TenantKey:           tenantKey,
		DisplayName:         displayName,
		MsTenantId:          tenantId,
		DefaultDomain:       domain,
		Greenfield:          greenfield,
		Pax8CompanyId:       "",
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
	data, _ := json.MarshalIndent(config, "", "  ")
	os.WriteFile(outPath, data, 0644)

	fmt.Printf("\n  %sSaved to: %s%s%s\n", cGreen, cCyan, outPath, cReset)
	fmt.Printf("  Next: run a dry-run test (%s[3]%s) then sync to GitHub (%s[5]%s).\n\n", cCyan, cReset, cCyan, cReset)
	wait("Press Enter")
}

// ── Sync to GitHub ─────────────────────────────────────────────────────────
func runSync() {
	cls()
	bar("Sync to GitHub", "")
	gitPath := findGit()
	if gitPath == "" {
		fail("git not found. Install Git for Windows and try again.")
		wait("Press Enter")
		return
	}
	out, _ := runGit(gitPath, "status", "--porcelain")
	if strings.TrimSpace(out) == "" {
		ok("Nothing to sync — no changes since last push.")
		wait("Press Enter")
		return
	}
	fmt.Printf("\n  %sChanges:%s\n", cCyan, cReset)
	statusOut, _ := runGit(gitPath, "status", "--short")
	for _, line := range strings.Split(strings.TrimSpace(statusOut), "\n") {
		fmt.Println("  " + line)
	}
	fmt.Println()
	msg := ask("  Commit message (Enter = 'Update')")
	if msg == "" {
		msg = "Update"
	}
	runGit(gitPath, "add", ".")
	runGit(gitPath, "commit", "-m", msg)
	output, err := runGit(gitPath, "push")
	if err != nil {
		fail("Push failed: " + output)
	} else {
		ok("Pushed to GitHub.")
	}
	fmt.Println()
	wait("Press Enter")
}

// ── Run PowerShell script ──────────────────────────────────────────────────
func runPwsh(script string, silent bool) {
	scriptPath := filepath.Join(root, script)
	cmd := exec.Command("pwsh.exe", "-ExecutionPolicy", "Bypass", "-NoProfile", "-File", scriptPath)

	// Inject credentials as env vars so PowerShell can read them
	creds := loadCreds()
	cmd.Env = append(os.Environ(),
		"PAX8_CLIENT_ID="+creds.Pax8ClientId,
		"PAX8_CLIENT_SECRET="+creds.Pax8ClientSecret,
		"GRAPH_CLIENT_ID="+creds.GraphClientId,
		"GRAPH_CLIENT_SECRET="+creds.GraphClientSecret,
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	cmd.Run()
	if !silent {
		wait("Press Enter")
	}
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
	data, err := os.ReadFile(filepath.Join(root, "config", "sku-catalog.json"))
	if err != nil {
		return nil
	}
	var cf CatalogFile
	json.Unmarshal(data, &cf)
	return cf.Licenses
}

// ── Git ────────────────────────────────────────────────────────────────────
func findGit() string {
	for _, p := range []string{`C:\Program Files\Git\bin\git.exe`, `C:\Program Files\Git\cmd\git.exe`} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	if path, err := exec.LookPath("git"); err == nil {
		return path
	}
	return ""
}

func runGit(gitPath string, args ...string) (string, error) {
	cmd := exec.Command(gitPath, args...)
	cmd.Dir = root
	out, err := cmd.CombinedOutput()
	return string(out), err
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
	fmt.Printf("%s%s── %s ─── %s%s\n\n", cBlue, cBold, num, title, cReset)
}

func step(text string)        { fmt.Printf("  %s%s\n", text, cReset) }
func ok(text string)          { fmt.Printf("  %s✓  %s%s\n", cGreen, text, cReset) }
func fail(text string)        { fmt.Printf("  %s✗  %s%s\n", cRed, text, cReset) }

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
