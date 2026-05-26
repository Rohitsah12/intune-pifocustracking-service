# PiFocus Agent Detection Script - Version Aware
# Exits: 0 = correct version installed + running, 1 = not installed / wrong version / not running

$ErrorActionPreference = 'SilentlyContinue'

$ServiceName      = "PiFocusWindowService"
$ServiceExe       = "C:\Program Files\PiFocus\Agent\WindowService.exe"
$VersionFile      = "C:\Program Files\PiFocus\Agent\version.txt"
$TargetVersion    = "1.0.2"

Write-Host "=== PiFocus Agent Detection (target: $TargetVersion) ==="

# Check exe
if (-not (Test-Path $ServiceExe)) {
    Write-Host "FAIL: Executable missing"
    exit 1
}

# Check version.txt
if (-not (Test-Path $VersionFile)) {
    Write-Host "FAIL: version.txt missing"
    exit 1
}

$installedVersion = (Get-Content -Path $VersionFile -Raw).Trim()
Write-Host "Installed version: $installedVersion"

if ($installedVersion -ne $TargetVersion) {
    Write-Host "FAIL: Version mismatch (installed=$installedVersion, required=$TargetVersion)"
    exit 1
}

# Check service running
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "FAIL: Service not registered"
    exit 1
}

if ($svc.Status -ne 'Running') {
    Write-Host "FAIL: Service not running (Status=$($svc.Status))"
    exit 1
}

Write-Host "OK: Version $TargetVersion installed and running"
exit 0