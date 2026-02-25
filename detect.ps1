# PiFocus Agent Detection Script
# Exits with:
# 0 = installed and running
# 1 = not installed (exe missing or service not registered)
# 2 = service registered but not running

$ErrorActionPreference = 'SilentlyContinue'

$ServiceName = "PiFocusWindowService"
$ServiceExe = "C:\Program Files\PiFocus\Agent\WindowService.exe"

Write-Host "=== PiFocus Agent Detection ==="
Write-Host "Checking service executable: $ServiceExe"

$exeExists = Test-Path $ServiceExe
if ($exeExists) {
    Write-Host "- Executable: FOUND"
}
else {
    Write-Host "- Executable: MISSING"
}

Write-Host "Checking Windows service: $ServiceName"
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if (-not $svc) {
    Write-Host "- Service: NOT REGISTERED"
    if (-not $exeExists) {
        Write-Host "SUMMARY: Agent appears uninstalled (no exe, no service)."
    }
    else {
        Write-Host "SUMMARY: Service executable exists but service is not registered."
    }
    exit 1
}

Write-Host "- Service: REGISTERED"
Write-Host "- Status: $($svc.Status)"

if ($svc.Status -eq 'Running') {
    Write-Host "SUMMARY: Agent is installed and running."
    exit 0
}
else {
    Write-Host "SUMMARY: Service is registered but not running."
    # Try to get more info from WMI (best-effort)
    try {
        $w = Get-WmiObject -Class Win32_Service -Filter ("Name='$ServiceName'")
        if ($w) {
            Write-Host "- StartMode: $($w.StartMode)"
            Write-Host "- State: $($w.State)"
            Write-Host "- ExitCode: $($w.ExitCode)"
            Write-Host "- ServiceSpecificExitCode: $($w.ServiceSpecificExitCode)"
        }
    }
    catch {
        Write-Host "(Could not query additional service details: $_)"
    }

    exit 2
}
