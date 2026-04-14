# PiFocus Agent Detection Script - Version Aware
# Exits: 0 = correct version installed + running, 1 = not installed / wrong version / not running

$ErrorActionPreference = 'SilentlyContinue'

$ServiceName   = "PiFocusWindowService"
$ServiceExe    = "C:\Program Files\PiFocus\Agent\WindowService.exe"
$TargetVersion = "1.0.0"   
$RegPath       = "HKLM:\SOFTWARE\PiFocus\Agent"

Write-Host "=== PiFocus Agent Detection (target: $TargetVersion) ==="

# Check exe
if (-not (Test-Path $ServiceExe)) {
    Write-Host "FAIL: Executable missing"
    exit 1
}

# Check registry version
$installedVersion = (Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue).Version
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