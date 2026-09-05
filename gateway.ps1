<#
.SYNOPSIS
  Keeps "claude remote-control" (server mode) alive on this Windows PC so the
  Claude mobile app / claude.ai/code can open NEW local Claude Code sessions here.

.DESCRIPTION
  Claude Code's server mode ("claude remote-control") is the official way to let your
  phone start sessions on your own machine. Two things make it a poor daemon on its own:
    - it exits by design after roughly 10 minutes without network, and
    - nothing restarts it after a reboot.
  This script is a small supervisor: start the server hidden, capture its output to a
  log, restart it with backoff when it exits, and write an alert file when it keeps
  dying quickly (for example because of a silent auth problem).

  Pure Windows PowerShell 5.1. No Python, no Node, no admin rights, no extra modules.

.PARAMETER Name
  Session name shown in the Claude app for the pre-created session. Default: computer name.
.PARAMETER WorkDir
  Folder the server runs in. New phone sessions use it as their working directory.
  Must NOT be your user profile root (Claude refuses to serve the home directory).
  Default: the folder containing this script.
.PARAMETER ClaudePath
  Full path to claude.exe / claude.cmd. Default: auto-detect (native install, PATH,
  then the copy bundled with Claude Desktop).
.PARAMETER LogDir
  Where gateway.log, server.log, gateway.lock and ALERT-gateway.txt live. Default: <WorkDir>\logs
.PARAMETER Test
  Start the server once, wait for the "environment=" URL, print it, stop, exit 0.
  Exit 1 with the server's own output if it never connects. Used by doctor.ps1 and install.ps1.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\gateway.ps1 -Test
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\gateway.ps1 -Name "Home PC" -WorkDir C:\Projects\gateway
#>
[CmdletBinding()]
param(
    [string]$Name = $env:COMPUTERNAME,
    [string]$WorkDir = "",
    [string]$ClaudePath = "",
    [string]$LogDir = "",
    [switch]$Test,
    [int]$TestTimeoutSeconds = 90,
    [int]$MinBackoffSeconds = 30,
    [int]$MaxBackoffSeconds = 600,
    [int]$HealthySeconds = 120,
    [int]$AlertAfterFailures = 3,
    [int]$GatewayLogMaxBytes = 524288,
    [int]$ServerLogMaxBytes = 2097152
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"
$script:Esc = [char]27

# ---------------------------------------------------------------- helpers

function Get-ScriptDirectory {
    return Split-Path -Parent $PSCommandPath
}

. (Join-Path (Get-ScriptDirectory) "lib.ps1")

function Remove-AnsiCodes([string]$text) {
    if ($null -eq $text) { return "" }
    $e = $script:Esc
    $t = $text -replace ("{0}\]8;;[^{0}\a]*(?:\a|{0}\\)" -f [regex]::Escape($e)), ""   # OSC 8 hyperlinks
    $t = $t -replace ("{0}\[[0-9;?]*[A-Za-z]" -f [regex]::Escape($e)), ""             # CSI sequences
    return $t
}

function Test-ShuttingDown {
    # GetSystemMetrics(SM_SHUTTINGDOWN=0x2000) is non-zero while Windows is shutting down or logging off.
    try {
        if (-not ("PhoneGateway.Native" -as [type])) {
            Add-Type -Namespace PhoneGateway -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetSystemMetrics(int nIndex);
'@
        }
        return ([PhoneGateway.Native]::GetSystemMetrics(0x2000) -ne 0)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------- logging

function Rotate-File([string]$path, [int]$maxBytes) {
    if (-not (Test-Path $path)) { return }
    if ((Get-Item $path).Length -lt $maxBytes) { return }
    $old = "$path.1"
    if (Test-Path $old) { Remove-Item $old -Force }
    Move-Item $path $old -Force
}

function Write-Log([string]$message) {
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $message
    Rotate-File $script:GatewayLog $GatewayLogMaxBytes
    Add-Content -Path $script:GatewayLog -Value $line -Encoding UTF8
    if ($Test) { Write-Host $line }
}

function Open-ServerLog {
    Rotate-File $script:ServerLog $ServerLogMaxBytes
    $stream = New-Object System.IO.FileStream($script:ServerLog, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true
    return $writer
}

function Write-Alert([string]$message) {
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $message
    Add-Content -Path $script:AlertFile -Value $line -Encoding UTF8
}

# ---------------------------------------------------------------- single instance

function Get-LockOwnerPid {
    if (-not (Test-Path $script:LockFile)) { return $null }
    $text = (Get-Content $script:LockFile -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $text) { return $null }
    $text = $text.Trim()
    $parsed = 0
    if ([int]::TryParse($text, [ref]$parsed)) { return $parsed }
    return $null
}

function Test-GatewayProcess([int]$processId) {
    # true only if the PID is alive AND is a PowerShell running gateway.ps1 (PID reuse guard)
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop
        if ($null -eq $p) { return $false }
        return ($p.CommandLine -like "*gateway.ps1*")
    } catch {
        return $true   # cannot tell: assume alive rather than start a second gateway
    }
}

function Lock-Gateway {
    $owner = Get-LockOwnerPid
    if ($null -ne $owner -and $owner -ne $PID) {
        if (Test-GatewayProcess $owner) {
            throw "another gateway is already running (pid $owner). Lock: $($script:LockFile)"
        }
        Write-Log "stale lock (pid $owner) reclaimed"
    }
    Set-Content -Path $script:LockFile -Value $PID -Encoding ASCII
}

function Unlock-Gateway {
    $owner = Get-LockOwnerPid
    if ($owner -eq $PID) { Remove-Item $script:LockFile -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- server process

function Stop-ProcessTree([int]$processId) {
    if ($processId -le 0) { return }
    if (Test-ShuttingDown) {
        Write-Log "windows is shutting down; leaving pid $processId to the OS (killing during shutdown can hang the shutdown screen)"
        return
    }
    try { Stop-ProcessTreeById $processId } catch { }
}

function New-ServerProcess {
    # Always go through cmd.exe: it runs both claude.exe and the npm claude.cmd shim,
    # and "2>&1" merges stderr so a single reader never deadlocks.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/d /c ""{0}" remote-control --name "{1}" 2>&1"' -f $script:Claude, $Name
    $psi.WorkingDirectory = $script:WorkDirFull
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardInput = $true
    foreach ($key in @($psi.EnvironmentVariables.Keys)) {
        $upper = $key.ToUpperInvariant()
        # Remote Control only accepts claude.ai subscription auth. An inherited
        # ANTHROPIC_API_KEY makes claude pick API-key auth and exit immediately (rc=1, silently).
        if ($upper.StartsWith("ANTHROPIC_") -or $upper -eq "CLAUDE_CODE_USE_BEDROCK" -or $upper -eq "CLAUDE_CODE_USE_VERTEX") {
            [void]$psi.EnvironmentVariables.Remove($key)
        }
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    return $proc
}

function Invoke-ServerRun([Nullable[datetime]]$deadline) {
    # Runs the server once. Returns a hashtable: Seconds, ExitCode, EnvUrl, Tail (last lines, ANSI stripped).
    $started = Get-Date
    $writer = Open-ServerLog
    $proc = $null
    $envUrl = $null
    $tail = New-Object System.Collections.Generic.List[string]
    try {
        $proc = New-ServerProcess
        $script:ChildPid = $proc.Id
        Write-Log ("server started pid={0} name='{1}' dir='{2}'" -f $proc.Id, $Name, $script:WorkDirFull)
        $reader = $proc.StandardOutput
        $pending = $null
        $stop = $false
        while (-not $stop) {
            if ($null -eq $pending) { $pending = $reader.ReadLineAsync() }
            $ready = $false
            try { $ready = $pending.Wait(1000) } catch { break }   # stream closed underneath us: treat as EOF
            if ($ready) {
                $line = $pending.Result
                $pending = $null
                if ($null -eq $line) { break }          # EOF: process closed its output
                $writer.WriteLine($line)
                if ($writer.BaseStream.Length -gt $ServerLogMaxBytes) {
                    $writer.Close(); $writer = Open-ServerLog
                }
                $clean = (Remove-AnsiCodes $line).Trim()
                if ($clean -ne "") {
                    $tail.Add($clean)
                    if ($tail.Count -gt 40) { $tail.RemoveAt(0) }
                }
                if ($null -eq $envUrl -and $clean -match 'https://claude\.ai/code\?environment=\S+') {
                    $envUrl = $Matches[0]
                    Write-Log "connected: $envUrl"
                    if ($Test) { $stop = $true }
                }
            } else {
                if ($null -ne $deadline -and (Get-Date) -gt $deadline) { Write-Log "test timeout reached"; $stop = $true }
                if (Test-ShuttingDown) { Write-Log "shutdown detected"; $stop = $true }
            }
        }
        if (-not $proc.HasExited) {
            Stop-ProcessTree $proc.Id
            try { [void]$proc.WaitForExit(15000) } catch { }
        } else {
            $proc.WaitForExit()
        }
        $rc = $null
        try { $rc = $proc.ExitCode } catch { }
        $seconds = [int]((Get-Date) - $started).TotalSeconds
        if ($Test -and $null -ne $envUrl) {
            Write-Log ("probe done; server stopped on purpose after {0}s" -f $seconds)
        } else {
            Write-Log ("server exited rc={0} after {1}s" -f $rc, $seconds)
        }
        return @{ Seconds = $seconds; ExitCode = $rc; EnvUrl = $envUrl; Tail = $tail.ToArray() }
    } finally {
        $script:ChildPid = 0
        if ($null -ne $writer) { try { $writer.Close() } catch { } }
    }
}

# ---------------------------------------------------------------- main

function Initialize-Gateway {
    $here = Get-ScriptDirectory
    $dir = if ($WorkDir -eq "") { $here } else { $WorkDir }
    $script:WorkDirFull = Resolve-FullPath $dir
    if (-not (Test-Path $script:WorkDirFull)) { throw "WorkDir does not exist: $($script:WorkDirFull)" }
    if (Test-HomeDirectory $script:WorkDirFull) {
        throw "WorkDir is your user profile root. Claude refuses to serve the home directory (trust is never saved there). Use a subfolder, e.g. $env:USERPROFILE\claude-gateway"
    }
    $script:Claude = Find-ClaudePath $ClaudePath
    if ($null -eq $script:Claude) {
        throw "claude not found. Install Claude Code (https://code.claude.com/docs/en/setup) or pass -ClaudePath."
    }
    $logs = if ($LogDir -eq "") { Join-Path $script:WorkDirFull "logs" } else { $LogDir }
    $script:LogDirFull = Resolve-FullPath $logs
    New-Item -ItemType Directory -Force $script:LogDirFull | Out-Null
    $script:GatewayLog = Join-Path $script:LogDirFull "gateway.log"
    $script:ServerLog = Join-Path $script:LogDirFull "server.log"
    $script:LockFile = Join-Path $script:LogDirFull "gateway.lock"
    $script:AlertFile = Join-Path $script:LogDirFull "ALERT-gateway.txt"
    $script:ChildPid = 0
}

function Invoke-TestMode {
    Write-Log ("test mode: claude='{0}'" -f $script:Claude)
    $deadline = (Get-Date).AddSeconds($TestTimeoutSeconds)
    $result = Invoke-ServerRun $deadline
    if ($null -ne $result.EnvUrl) {
        Write-Host ""
        Write-Host "OK  remote-control server connected."
        Write-Host "    environment: $($result.EnvUrl)"
        Write-Host "    (a stopped test run leaves this environment listed on claude.ai; it is harmless)"
        return 0
    }
    Write-Host ""
    Write-Host "FAIL  the server did not connect within $TestTimeoutSeconds s. Its output:"
    foreach ($l in $result.Tail) { Write-Host "    | $l" }
    if ($result.Tail -join "`n" -match "not trusted") {
        Write-Host "    -> run .\install.ps1 (seeds workspace trust) or run 'claude' once inside the WorkDir and accept the trust prompt."
    }
    if ($result.Tail -join "`n" -match "subscription|API-key|API key") {
        Write-Host "    -> Remote Control needs a claude.ai subscription login (run 'claude' then /login). API keys are not accepted."
    }
    return 1
}

function Invoke-SupervisorLoop {
    Lock-Gateway
    Write-Log ("gateway started pid={0} claude='{1}' logs='{2}'" -f $PID, $script:Claude, $script:LogDirFull)
    $backoff = $MinBackoffSeconds
    $failures = 0
    $alerted = $false
    try {
        while ($true) {
            $result = Invoke-ServerRun $null
            if (Test-ShuttingDown) { Write-Log "exiting for shutdown"; break }
            if ($result.Seconds -ge $HealthySeconds) {
                $backoff = $MinBackoffSeconds
                $failures = 0
                if ($alerted) { Write-Alert "recovered: server ran $($result.Seconds)s"; $alerted = $false }
            } else {
                $failures++
                $backoff = [Math]::Min($backoff * 2, $MaxBackoffSeconds)
                if ($failures -ge $AlertAfterFailures -and -not $alerted) {
                    $last = if ($result.Tail.Count -gt 0) { $result.Tail[-1] } else { "(no output)" }
                    Write-Alert ("server exited {0} times in a row within {1}s. last output: {2}. see {3}" -f $failures, $HealthySeconds, $last, $script:ServerLog)
                    Write-Log "ALERT written: $($script:AlertFile)"
                    $alerted = $true
                }
            }
            Write-Log "restarting in ${backoff}s"
            $slept = 0
            while ($slept -lt $backoff) {
                Start-Sleep -Seconds 5
                $slept += 5
                if (Test-ShuttingDown) { break }
            }
            if (Test-ShuttingDown) { Write-Log "exiting for shutdown"; break }
        }
    } finally {
        if ($script:ChildPid -gt 0) { Stop-ProcessTree $script:ChildPid }
        Unlock-Gateway
        Write-Log "gateway stopped"
    }
}

try {
    Initialize-Gateway
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 2
}

if ($Test) {
    exit (Invoke-TestMode)
}

try {
    Invoke-SupervisorLoop
} catch {
    try { Write-Log "fatal: $($_.Exception.Message)" } catch { }
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 3
}
