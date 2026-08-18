# setup-stage-service.ps1
#
# Installs the locally-built STAGE agent as a real Windows service so the
# destructive pause/resume tests (service-restart persistence, helper watchdog)
# can run. Those are the tests that actually prove the silent-revert bug is
# dead, and they need a service that can be stopped and started.
#
# The stage build uses a COMPLETELY separate namespace from production --
# different service name, install dir, pipe, event and registry root -- so this
# does not touch PiFocusWindowService or your live tracking data.
#
#   Run from an ELEVATED PowerShell:
#     .\setup-stage-service.ps1
#
#   Then (normal or elevated shell):
#     $env:PIFOCUS_ENV = 'stage'
#     node run-tests.js --include-destructive
#
#   Tear down when finished:
#     .\teardown-stage-service.ps1

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

$BuildDir    = 'C:\PiBusiness5\PiBusiness\PiBusiness_Solution\PiBusiness_Solution\x64\Release-Stage'
$ProdAgentDir = 'C:\Program Files\PiFocus\Agent'          # source of the shared runtime DLLs
$InstallDir  = 'C:\Program Files\PiFocus\AgentStage'
$HelperDir   = 'C:\ProgramData\PiFocusStage'
$ServiceName = 'PiFocusWindowServiceStage'
$DisplayName = 'PiFocus Window Service (Staging)'

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }

Say "`n=== PiFocus STAGE service setup ===`n" 'Cyan'

# ---- 1. Verify the build actually contains the pause/resume fix -------------
# Same marker check install.ps1 does. Installing a pre-fix binary would make
# every test pass or fail for the wrong reason.
$srcWindow = Join-Path $BuildDir 'WindowService.exe'
$srcHelper = Join-Path $BuildDir 'HelperService.exe'

foreach ($f in @($srcWindow, $srcHelper)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Say "MISSING: $f" 'Red'
        Say "Build the Release-Stage configuration first." 'Red'
        exit 1
    }
}

$bytes = [System.IO.File]::ReadAllBytes($srcWindow)
$blob  = [System.Text.Encoding]::ASCII.GetString($bytes) + [System.Text.Encoding]::Unicode.GetString($bytes)
if (-not $blob.Contains('SET_TRACKING_ENABLED')) {
    Say "REFUSING: WindowService.exe predates the pause/resume state-sync fix." 'Red'
    Say "Rebuild the Release-Stage configuration and re-run." 'Red'
    exit 1
}
Say "  build contains SET_TRACKING_ENABLED  OK" 'Green'

# ---- 2. Remove any previous stage service ----------------------------------
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Say "  removing existing $ServiceName..."
    if ($existing.Status -ne 'Stopped') {
        & sc.exe stop $ServiceName | Out-Null
        Start-Sleep -Seconds 4
    }
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

Get-Process -Name 'HelperService','WindowService' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like '*Stage*' } |
    ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }

# ---- 3. Lay down the binaries ----------------------------------------------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $HelperDir  | Out-Null

Copy-Item $srcWindow -Destination $InstallDir -Force
Copy-Item (Join-Path $BuildDir '*.dll') -Destination $InstallDir -Force -ErrorAction SilentlyContinue

# The stage build output has only the OpenSSL DLLs; sentry + the VC++ runtime
# come from the installed prod agent directory.
foreach ($dep in @('sentry.dll','msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll','crashpad_handler.exe')) {
    $src = Join-Path $ProdAgentDir $dep
    if (Test-Path -LiteralPath $src) {
        Copy-Item $src -Destination $InstallDir -Force
    } else {
        Say "  WARNING: $dep not found in $ProdAgentDir" 'Yellow'
    }
}

# WindowService looks for the helper at <PF_PROGRAMDATA_DIR>\HelperService.exe
# and explicitly ignores a helper running from a different env's path.
Copy-Item $srcHelper -Destination $HelperDir -Force
foreach ($dep in @('sentry.dll','msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll','libcrypto-3-x64.dll','libssl-3-x64.dll','crashpad_handler.exe')) {
    $src = Join-Path $InstallDir $dep
    if (Test-Path -LiteralPath $src) { Copy-Item $src -Destination $HelperDir -Force }
}

Say "  binaries staged" 'Green'
Say "    $InstallDir"
Say "    $HelperDir"

# ---- 4. Create the service --------------------------------------------------
# Use New-Service, NOT `sc.exe create`. sc.exe wants `binPath= "<path>" --service`
# and Windows PowerShell 5.1 mangles the embedded quotes when it builds the
# native command line, which produces ERROR_INVALID_COMMAND_LINE (1639).
# New-Service builds the registry entry itself and quotes the path correctly.
$binPath = '"{0}\WindowService.exe" --service' -f $InstallDir

try {
    # StartupType Manual (not Automatic) on purpose: a test service must not
    # come back by itself after a reboot. Defaults to LocalSystem.
    New-Service -Name $ServiceName `
                -BinaryPathName $binPath `
                -DisplayName $DisplayName `
                -Description 'PiFocus staging agent - TEST ONLY, safe to delete' `
                -StartupType Manual `
                -ErrorAction Stop | Out-Null
}
catch {
    Say "New-Service failed: $($_.Exception.Message)" 'Red'
    Say "binPath was: $binPath" 'Yellow'
    exit 1
}

Say "  service created (StartupType=Manual, LocalSystem)" 'Green'

# Confirm what actually landed in the registry — a silently wrong ImagePath is
# the usual reason a service exists but instantly fails to start.
$imagePath = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
Say "  ImagePath: $imagePath" 'DarkGray'

try {
    Start-Service -Name $ServiceName -ErrorAction Stop
} catch {
    Say "  Start-Service failed: $($_.Exception.Message)" 'Red'
}
Start-Sleep -Seconds 6

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Say "  service RUNNING" 'Green'
} else {
    Say "  service did not reach Running (status: $($svc.Status))" 'Yellow'
    Say "  most likely a missing runtime DLL next to WindowService.exe." 'Yellow'
    Say "  check:  Get-EventLog -LogName Application -Newest 20 | Format-List" 'Yellow'
    exit 1
}

# Prove the pipe is actually answering before handing off to the tests, so a
# broken install fails here rather than as a confusing preflight error.
Say "`n  verifying the pipe responds..."
Push-Location $PSScriptRoot
$env:PIFOCUS_ENV = 'stage'
& node -e "require('./lib/pipe').getTrackingState().then(r => { console.log('  GET_TRACKING_STATE ->', JSON.stringify(r)); process.exit(r.ok ? 0 : 1); })"
$pipeOk = ($LASTEXITCODE -eq 0)
Pop-Location

if (-not $pipeOk) {
    Say "  pipe did not answer - the tests will not be able to run" 'Red'
    exit 1
}
Say "  pipe OK" 'Green'

Say "`nNow run the tests:" 'Cyan'
Say "  `$env:PIFOCUS_ENV = 'stage'"
Say "  node run-tests.js --include-destructive"
Say "`nWhen finished:" 'Cyan'
Say "  .\teardown-stage-service.ps1`n"
