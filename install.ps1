<#
.SYNOPSIS
  Installs (or removes) the Claude Code phone gateway: trust the work folder, probe once,
  add a hidden Startup entry, and start it now.

.DESCRIPTION
  What it changes on your PC, and nothing else:
    1. ~/.claude.json  - marks WorkDir as trusted (backup written first).
    2. <repo>\start-gateway.cmd - the exact command line the Startup entry runs.
    3. Startup folder  - "Claude Code Phone Gateway.lnk" (wscript.exe run-hidden.vbs start-gateway.cmd).
  No admin rights, no services, no scheduled tasks, no registry edits.

.PARAMETER Name
  Session name shown in the Claude app. Default: computer name.
.PARAMETER WorkDir
  Folder new phone sessions start in. Default: the repo folder. Must not be your profile root.
.PARAMETER Uninstall
  Remove the Startup entry and stop the running gateway. Logs and the trust flag are left alone.
.PARAMETER NoStart
  Install but do not start the gateway now.
.PARAMETER SkipProbe
  Do not run the live probe before installing (not recommended).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Name "Home PC" -WorkDir C:\Projects\gateway
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Name = $env:COMPUTERNAME,
    [string]$WorkDir = "",
    [string]$ClaudePath = "",
    [switch]$Uninstall,
    [switch]$NoStart,
    [switch]$SkipProbe
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here "lib.ps1")

$shortcut = Get-StartupShortcutPath
$launcherCmd = Join-Path $here "start-gateway.cmd"
$vbs = Join-Path $here "run-hidden.vbs"

function Stop-RunningGateway([string]$onlyForDir) {
    $procs = Get-RunningGatewayProcesses
    if ($onlyForDir -ne "") { $procs = @($procs | Where-Object { $_.CommandLine -like "*$onlyForDir*" }) }
    foreach ($p in $procs) {
        Write-Host "stopping gateway pid $($p.ProcessId)"
        & taskkill.exe /T /F /PID $p.ProcessId 2>&1 | Out-Null
    }
    return $procs.Count
}

if ($Uninstall) {
    $n = Stop-RunningGateway ""
    if (Test-Path $shortcut) { Remove-Item $shortcut -Force; Write-Host "removed $shortcut" }
    if (Test-Path $launcherCmd) { Remove-Item $launcherCmd -Force; Write-Host "removed $launcherCmd" }
    Write-Host "Uninstalled ($n process(es) stopped). Logs and the trust entry in ~/.claude.json were left in place."
    exit 0
}

# ---- resolve inputs
$dir = if ($WorkDir -eq "") { $here } else { $WorkDir }
$dirFull = Resolve-FullPath $dir
if (-not (Test-Path $dirFull)) { throw "WorkDir does not exist: $dirFull" }
if (Test-HomeDirectory $dirFull) { throw "WorkDir is your user profile root. Claude refuses to serve it. Use a subfolder, e.g. $env:USERPROFILE\claude-gateway" }
$claude = Find-ClaudePath $ClaudePath
if ($null -eq $claude) { throw "claude not found. Install Claude Code first: https://code.claude.com/docs/en/setup" }

Write-Host ""
Write-Host "Claude Code phone gateway - install" -ForegroundColor Cyan
Write-Host ("  session name : {0}" -f $Name)
Write-Host ("  work folder  : {0}" -f $dirFull)
Write-Host ("  claude       : {0}" -f $claude)
Write-Host ""

# ---- 1. trust
if (Test-WorkspaceTrusted $dirFull) {
    Write-Host "[1/4] work folder already trusted"
} else {
    $backup = Set-WorkspaceTrust $dirFull ""
    Write-Host "[1/4] work folder marked trusted in ~/.claude.json (backup: $backup)"
}

# ---- 2. probe
if ($SkipProbe) {
    Write-Host "[2/4] live probe skipped"
} else {
    $already = @(Get-RunningGatewayProcesses | Where-Object { $_.CommandLine -like "*$dirFull*" })
    if ($already.Count -gt 0) {
        Write-Host "[2/4] live probe skipped: a gateway already serves this folder (pid $($already[0].ProcessId)); it will be restarted"
    } else {
        Write-Host "[2/4] live probe: starting claude remote-control once..."
        $probeArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $here "gateway.ps1"), "-Test", "-Name", "install-probe", "-WorkDir", $dirFull)
        if ($ClaudePath -ne "") { $probeArgs += @("-ClaudePath", $ClaudePath) }
        & powershell.exe @probeArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Host "Install stopped: the server could not connect. Fix the error shown above and run install.ps1 again." -ForegroundColor Red
            exit 1
        }
    }
}

# ---- 3. launcher + startup shortcut
$psLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Name "{1}" -WorkDir "{2}"' -f (Join-Path $here "gateway.ps1"), $Name, $dirFull
if ($ClaudePath -ne "") { $psLine += (' -ClaudePath "{0}"' -f $claude) }
$cmdText = "@echo off`r`n" + $psLine + "`r`n"
[System.IO.File]::WriteAllText($launcherCmd, $cmdText, [System.Text.Encoding]::ASCII)

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($shortcut)
$lnk.TargetPath = Join-Path $env:SystemRoot "System32\wscript.exe"
$lnk.Arguments = ('"{0}" "{1}"' -f $vbs, $launcherCmd)
$lnk.WorkingDirectory = $here
$lnk.Description = "Keeps claude remote-control running so your phone can open local Claude Code sessions"
$lnk.Save()
Write-Host "[3/4] startup entry created: $shortcut"

# ---- 4. start now
if ($NoStart) {
    Write-Host "[4/4] not started (-NoStart). It will start at your next logon, or run start-gateway.cmd."
} else {
    [void](Stop-RunningGateway $dirFull)
    Start-Process -FilePath $lnk.TargetPath -ArgumentList $lnk.Arguments -WorkingDirectory $here -WindowStyle Hidden
    $log = Join-Path $dirFull "logs\gateway.log"
    $deadline = (Get-Date).AddSeconds(90)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if ((Test-Path $log) -and ((Get-Content $log -Tail 5) -join "`n") -match "connected: (https://\S+)") { $ok = $true; $url = $Matches[1]; break }
    }
    if ($ok) { Write-Host "[4/4] gateway running and connected: $url" -ForegroundColor Green }
    else { Write-Host "[4/4] gateway started but no 'connected:' line yet. Check $log" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "Done. On your phone: Claude app > Code > pick this computer under Devices > choose the folder" -ForegroundColor Cyan
Write-Host ("      '{0}' > New session. It runs here, with your files." -f $dirFull)
Write-Host "Logs: $dirFull\logs   Uninstall: install.ps1 -Uninstall"
