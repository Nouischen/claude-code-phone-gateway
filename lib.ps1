# Shared helpers for gateway.ps1 / doctor.ps1 / install.ps1 / link-memory.ps1.
# Dot-source this file. Pure Windows PowerShell 5.1, ASCII only.

function Resolve-FullPath([string]$path) {
    return [System.IO.Path]::GetFullPath($path).TrimEnd("\")
}

function Test-HomeDirectory([string]$path) {
    $profileRoot = Resolve-FullPath $env:USERPROFILE
    return ($path.TrimEnd("\") -ieq $profileRoot)
}

function Get-DesktopBundledClaude {
    # Claude Desktop ships its own claude.exe under %APPDATA%\Claude\claude-code\<version>\
    $root = Join-Path $env:APPDATA "Claude\claude-code"
    if (-not (Test-Path $root)) { return $null }
    $dirs = @(Get-ChildItem $root -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+' })
    if ($dirs.Count -eq 0) { return $null }
    $best = $dirs | Sort-Object { [version]($_.Name -replace '[^\d.].*$', '') } -Descending | Select-Object -First 1
    $exe = Join-Path $best.FullName "claude.exe"
    if (Test-Path $exe) { return $exe }
    return $null
}

function Find-ClaudePath([string]$explicit) {
    # Order: explicit path, native installer, PATH (exe then npm shim), Claude Desktop bundle.
    if ($explicit -ne "") {
        if (Test-Path $explicit) { return (Resolve-FullPath $explicit) }
        throw "ClaudePath not found: $explicit"
    }
    $native = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
    if (Test-Path $native) { return $native }
    foreach ($candidate in @("claude.exe", "claude.cmd")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd -and $cmd.Source) { return $cmd.Source }
    }
    $bundled = Get-DesktopBundledClaude
    if ($null -ne $bundled) { return $bundled }
    return $null
}

function Get-ClaudeVersion([string]$claudePath) {
    # Returns a [version] or $null. Output looks like "2.1.258 (Claude Code)".
    try {
        $out = & $claudePath --version 2>&1 | Out-String
        if ($out -match '(\d+)\.(\d+)\.(\d+)') { return [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3]) }
    } catch { }
    return $null
}

function Get-ProjectKey([string]$path) {
    # Claude Code names per-project folders under ~/.claude/projects by replacing every
    # non-alphanumeric character of the absolute path with "-". C:\Projects\x -> C--Projects-x
    $full = Resolve-FullPath $path
    return ($full -replace '[^A-Za-z0-9]', '-')
}

function Get-TrustKey([string]$path) {
    # ~/.claude.json keys projects with forward slashes: "C:/Projects/x"
    return ((Resolve-FullPath $path) -replace '\\', '/')
}

function Get-ClaudeConfigPath {
    return (Join-Path $env:USERPROFILE ".claude.json")
}

function Test-WorkspaceTrusted([string]$path) {
    $cfg = Get-ClaudeConfigPath
    if (-not (Test-Path $cfg)) { return $false }
    try {
        $obj = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { return $false }
    if ($null -eq $obj.projects) { return $false }
    $prop = $obj.projects.PSObject.Properties[(Get-TrustKey $path)]
    if ($null -eq $prop) { return $false }
    return [bool]$prop.Value.hasTrustDialogAccepted
}

function Set-WorkspaceTrust([string]$path, [string]$backupDir) {
    # Marks the folder as trusted in ~/.claude.json, the same flag the interactive
    # "Do you trust this folder?" prompt writes. Backs up first, validates the rewritten
    # JSON before replacing the file. Returns the backup path, or $null if nothing changed.
    $cfg = Get-ClaudeConfigPath
    if (-not (Test-Path $cfg)) { throw "$cfg not found. Run 'claude' once and sign in, then retry." }
    $obj = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $obj.projects) { $obj | Add-Member -NotePropertyName projects -NotePropertyValue ([pscustomobject]@{}) }
    $key = Get-TrustKey $path
    $existing = $obj.projects.PSObject.Properties[$key]
    if ($null -ne $existing) {
        if ($existing.Value.hasTrustDialogAccepted) { return $null }
        $existing.Value | Add-Member -NotePropertyName hasTrustDialogAccepted -NotePropertyValue $true -Force
    } else {
        $entry = [pscustomobject]@{
            allowedTools = @()
            mcpContextUris = @()
            mcpServers = [pscustomobject]@{}
            enabledMcpjsonServers = @()
            disabledMcpjsonServers = @()
            hasTrustDialogAccepted = $true
            hasClaudeMdExternalIncludesApproved = $false
            hasClaudeMdExternalIncludesWarningShown = $false
        }
        $obj.projects | Add-Member -NotePropertyName $key -NotePropertyValue $entry
    }
    if ($backupDir -eq "") { $backupDir = Join-Path $env:USERPROFILE ".claude\backups\claude-code-phone-gateway" }
    New-Item -ItemType Directory -Force $backupDir | Out-Null
    $backup = Join-Path $backupDir (".claude.json.bak-" + (Get-Date -Format "yyyy-MM-dd-HHmmss"))
    Copy-Item $cfg $backup
    $json = $obj | ConvertTo-Json -Depth 100
    $check = $json | ConvertFrom-Json
    $before = @($obj.PSObject.Properties).Count
    $after = @($check.PSObject.Properties).Count
    if ($before -ne $after) { throw "refusing to write ~/.claude.json: re-parse mismatch ($before vs $after keys). Original untouched; backup at $backup" }
    $tmp = "$cfg.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Force $tmp $cfg
    return $backup
}

function Get-ProcessTreeIds([int]$rootId) {
    # The root and all of its descendants, children before parents is not required for
    # Stop-Process -Force, but we still collect the whole tree first so nothing is orphaned.
    $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId)
    $ids = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($rootId)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($ids.Contains($current)) { continue }
        $ids.Add($current)
        foreach ($p in $all) { if ($p.ParentProcessId -eq $current -and -not $ids.Contains([int]$p.ProcessId)) { $queue.Enqueue([int]$p.ProcessId) } }
    }
    return $ids.ToArray()
}

function Stop-ProcessTreeById([int]$rootId) {
    # Kill root + descendants with Stop-Process. taskkill.exe is deliberately not used:
    # under $ErrorActionPreference = "Stop" a single child it cannot kill turns its stderr
    # into a terminating error and aborts the whole uninstall (seen in a test).
    if ($rootId -le 0) { return }
    $ids = Get-ProcessTreeIds $rootId
    foreach ($id in $ids) {
        if ($id -eq $PID) { continue }
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
}

function Get-StartupShortcutPath {
    $startup = [Environment]::GetFolderPath("Startup")
    return (Join-Path $startup "Claude Code Phone Gateway.lnk")
}

function Get-RunningGatewayProcesses {
    # Supervisors only: exclude one-shot "-Test" probes. The switch must be matched as its own
    # token; a plain "*-Test*" wildcard also matched names like "stranger-test" (found by a
    # reproduction test) and made -Uninstall report "0 process(es) stopped" while one kept running.
    # Match only a real supervisor launch: powershell.exe ... -File "<dir>\gateway.ps1" ...
    # A plain substring match also hit an unrelated PowerShell whose -Command text merely
    # mentioned gateway.ps1 (an agent's own shell), and killed it.
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -match '(^|\s)-File\s+"?[^"\s]*gateway\.ps1"?' -and
        $_.CommandLine -notmatch '(^|\s)-Test(\s|$)'
    })
}
