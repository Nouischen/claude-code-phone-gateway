<#
.SYNOPSIS
  Optional: make sessions started from your phone share the same Claude Code memory as
  the project you normally work in.

.DESCRIPTION
  Claude Code's auto-memory is per project folder (~/.claude/projects/<key>/memory).
  Sessions the gateway starts run in WorkDir, so by default they get an empty memory.
  This script replaces WorkDir's memory folder with a directory junction that points at
  another project's memory folder. Same files, two entry points, no copies.
  Refuses to run if WorkDir already has memory files (so nothing is lost).

.PARAMETER WorkDir
  The gateway work folder. Default: the repo folder.
.PARAMETER ShareFrom
  The project folder whose memory you want to share. Default: your user profile folder,
  which is where Claude Desktop puts sessions opened without a project.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\link-memory.ps1 -ShareFrom C:\Users\me
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\link-memory.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$WorkDir = "",
    [string]$ShareFrom = $env:USERPROFILE,
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here "lib.ps1")

$dir = if ($WorkDir -eq "") { $here } else { $WorkDir }
$projectsRoot = Join-Path $env:USERPROFILE ".claude\projects"
$target = Join-Path $projectsRoot ((Get-ProjectKey $dir) + "\memory")
$source = Join-Path $projectsRoot ((Get-ProjectKey $ShareFrom) + "\memory")

function Test-Junction([string]$path) {
    if (-not (Test-Path $path)) { return $false }
    $item = Get-Item $path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

if ($Remove) {
    if (Test-Junction $target) {
        # rmdir on a junction removes the link only, never the target's files
        & cmd.exe /d /c ('rmdir "{0}"' -f $target) | Out-Null
        Write-Host "removed junction $target (shared files untouched)"
    } else {
        Write-Host "no junction at $target"
    }
    exit 0
}

if (-not (Test-Path $source)) {
    Write-Host "No memory folder to share yet: $source" -ForegroundColor Yellow
    Write-Host "Claude Code creates it the first time it saves a memory for that project. Nothing done."
    exit 1
}
if (Test-Junction $target) {
    Write-Host "already linked: $target"
    exit 0
}
if (Test-Path $target) {
    $count = @(Get-ChildItem $target -Force -Recurse -File).Count
    if ($count -gt 0) {
        Write-Host "WorkDir already has $count memory file(s) at $target" -ForegroundColor Red
        Write-Host "Merge them into $source by hand, delete the folder, then run this again. Nothing done."
        exit 1
    }
    Remove-Item $target -Force
}
New-Item -ItemType Directory -Force (Split-Path -Parent $target) | Out-Null
& cmd.exe /d /c ('mklink /J "{0}" "{1}"' -f $target, $source) | Out-Null
if (-not (Test-Junction $target)) { throw "mklink failed for $target" }
$n = @(Get-ChildItem $target -File).Count
Write-Host "linked: $target -> $source ($n file(s) visible through the link)" -ForegroundColor Green
