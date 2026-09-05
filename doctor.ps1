<#
.SYNOPSIS
  Checks whether this PC can run the Claude Code phone gateway, and says exactly what to fix.

.DESCRIPTION
  Every check prints PASS / WARN / FAIL with a one-line fix. The last check is a live probe:
  it starts "claude remote-control" once (hidden), waits for the environment URL, then stops it.
  That probe is the only reliable way to know Remote Control works for your account.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1 -WorkDir C:\Projects\gateway -NoProbe
#>
[CmdletBinding()]
param(
    [string]$WorkDir = "",
    [string]$ClaudePath = "",
    [switch]$NoProbe,
    [int]$ProbeTimeoutSeconds = 90
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here "lib.ps1")

$script:Failures = 0
$script:Warnings = 0

function Write-Check([string]$status, [string]$title, [string]$detail) {
    switch ($status) {
        "PASS" { $color = "Green" }
        "WARN" { $color = "Yellow"; $script:Warnings++ }
        "FAIL" { $color = "Red"; $script:Failures++ }
        default { $color = "Gray" }
    }
    Write-Host ("[{0}] {1}" -f $status, $title) -ForegroundColor $color
    if ($detail -ne "") { Write-Host ("       {0}" -f $detail) }
}

Write-Host ""
Write-Host "Claude Code phone gateway - doctor" -ForegroundColor Cyan
Write-Host ""

# 1. OS + PowerShell
$os = [Environment]::OSVersion.Version
if ($os.Major -ge 10) { Write-Check "PASS" "Windows $($os.Major) build $($os.Build)" "" }
else { Write-Check "FAIL" "Windows $($os)" "Windows 10 or 11 is required." }

if ($PSVersionTable.PSVersion -ge [version]"5.1") { Write-Check "PASS" "PowerShell $($PSVersionTable.PSVersion)" "" }
else { Write-Check "FAIL" "PowerShell $($PSVersionTable.PSVersion)" "Windows PowerShell 5.1 or newer is required (built into Windows 10/11)." }

# 2. claude binary
$claude = $null
try { $claude = Find-ClaudePath $ClaudePath } catch { Write-Check "FAIL" "claude path" $_.Exception.Message }
if ($null -eq $claude) {
    Write-Check "FAIL" "Claude Code not found" "Install it: https://code.claude.com/docs/en/setup  (or pass -ClaudePath)"
} else {
    $ver = Get-ClaudeVersion $claude
    if ($null -eq $ver) {
        Write-Check "WARN" "Claude Code found but 'claude --version' failed" $claude
    } elseif ($ver -lt [version]"2.1.51") {
        Write-Check "FAIL" "Claude Code $ver is too old" "Server mode needs 2.1.51+. Update: 'claude update' or reinstall. Path: $claude"
    } else {
        Write-Check "PASS" "Claude Code $ver" $claude
    }
}

# 3. login (subscription)
$cfg = Get-ClaudeConfigPath
$loggedIn = $false
if (Test-Path $cfg) {
    try {
        $obj = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $obj.PSObject.Properties["oauthAccount"]) { $loggedIn = $true }
    } catch { }
}
if (-not $loggedIn -and (Test-Path (Join-Path $env:USERPROFILE ".claude\.credentials.json"))) { $loggedIn = $true }
if ($loggedIn) { Write-Check "PASS" "claude.ai login found" "" }
else { Write-Check "FAIL" "No claude.ai login" "Run 'claude', then '/login' with your Pro/Max/Team account. Remote Control does not work with API keys." }

# 4. environment variables that break Remote Control auth
$apiKey = [Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY")
if ($null -ne $apiKey -and $apiKey -ne "") {
    Write-Check "WARN" "ANTHROPIC_API_KEY is set in your environment" "The gateway strips it for the server process, so this is fine for the gateway. Just know that 'claude' in your own terminal will use API-key auth."
} else {
    Write-Check "PASS" "No ANTHROPIC_API_KEY in environment" ""
}
foreach ($v in @("CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX")) {
    $val = [Environment]::GetEnvironmentVariable($v)
    if ($null -ne $val -and $val -ne "") { Write-Check "WARN" "$v is set" "Remote Control needs claude.ai auth. The gateway strips this variable for the server process." }
}

# 5. work directory
$dir = if ($WorkDir -eq "") { $here } else { $WorkDir }
$dirFull = $null
try { $dirFull = Resolve-FullPath $dir } catch { }
if ($null -eq $dirFull -or -not (Test-Path $dirFull)) {
    Write-Check "FAIL" "WorkDir does not exist: $dir" "Create it or pass -WorkDir <existing folder>."
} elseif (Test-HomeDirectory $dirFull) {
    Write-Check "FAIL" "WorkDir is your user profile root ($dirFull)" "Claude refuses to serve the home directory. Use a subfolder, e.g. $env:USERPROFILE\claude-gateway"
} else {
    Write-Check "PASS" "WorkDir $dirFull" "New phone sessions will start in this folder."
    if (Test-WorkspaceTrusted $dirFull) { Write-Check "PASS" "WorkDir is trusted in ~/.claude.json" "" }
    else { Write-Check "WARN" "WorkDir is not yet trusted" "install.ps1 seeds the trust flag. Without it the server exits with 'Workspace not trusted'." }
}

# 6. already running?
$running = Get-RunningGatewayProcesses
if ($running.Count -gt 0) {
    Write-Check "INFO" "A gateway is already running (pid $($running[0].ProcessId))" "Logs: <WorkDir>\logs\gateway.log"
}
if (Test-Path (Get-StartupShortcutPath)) { Write-Check "INFO" "Startup shortcut present" (Get-StartupShortcutPath) }
else { Write-Check "INFO" "No startup shortcut yet" "install.ps1 creates it." }

# 7. live probe
if ($NoProbe) {
    Write-Check "INFO" "Live probe skipped (-NoProbe)" ""
} elseif ($script:Failures -gt 0) {
    Write-Check "INFO" "Live probe skipped because of the failures above" ""
} elseif ($running.Count -gt 0 -and $running[0].CommandLine -like "*$dirFull*") {
    Write-Check "INFO" "Live probe skipped: a gateway already serves this WorkDir" "Check <WorkDir>\logs\gateway.log for a 'connected:' line."
} elseif (-not (Test-WorkspaceTrusted $dirFull)) {
    Write-Check "INFO" "Live probe skipped: WorkDir not trusted yet" "Run install.ps1; it seeds trust and probes."
} else {
    Write-Host ""
    Write-Host "Starting a live probe (up to $ProbeTimeoutSeconds s)..." -ForegroundColor Cyan
    $gw = Join-Path $here "gateway.ps1"
    $probeArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $gw, "-Test", "-Name", "doctor-probe", "-WorkDir", $dirFull, "-TestTimeoutSeconds", $ProbeTimeoutSeconds)
    if ($ClaudePath -ne "") { $probeArgs += @("-ClaudePath", $ClaudePath) }
    & powershell.exe @probeArgs
    if ($LASTEXITCODE -eq 0) { Write-Check "PASS" "Live probe: remote-control server connected" "" }
    else { Write-Check "FAIL" "Live probe failed (see the server output above)" "" }
}

Write-Host ""
if ($script:Failures -eq 0) {
    Write-Host ("Result: ready. {0} warning(s)." -f $script:Warnings) -ForegroundColor Green
    Write-Host "Next: powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1"
    exit 0
} else {
    Write-Host ("Result: {0} problem(s) to fix first." -f $script:Failures) -ForegroundColor Red
    exit 1
}
