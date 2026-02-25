$ErrorActionPreference = "Continue"

$ServiceName = "PiFocusWindowService"

# Root = folder where install.ps1 lives
$Root = $PSScriptRoot

# Binaries live in same folder
$BinDir = $Root

$InstallDir = "C:\Program Files\PiFocus\Agent"
$ProgramDataDir = "C:\ProgramData\PiFocus"

$ServiceExe = Join-Path $InstallDir "WindowService.exe"

Write-Host "==== PiFocus Agent Install Started ===="
Write-Host "Binary source directory: $BinDir"



# ------------------------------
# Stop existing service
# ------------------------------
Write-Host "Stopping existing service..."
cmd.exe /c "sc stop $ServiceName" | Out-Null
Start-Sleep 3

# Try get PID
$pidLine = cmd.exe /c "sc queryex $ServiceName" | Select-String "PID"

if ($pidLine) {
    try {
        $servicePid = ($pidLine -split ":")[1].Trim()
        if ($servicePid -ne "0") {
            Write-Host "Force killing service PID $servicePid"
            taskkill /F /PID $servicePid /T | Out-Null
        }
    }
    catch {
        Write-Host "Could not parse service PID"
    }
}

# ------------------------------
# Stop helper (safe)
# ------------------------------
Write-Host "Stopping HelperService if running..."
# Use Get-Process to avoid noisy taskkill error when process not found
$helperProc = Get-Process -Name "HelperService" -ErrorAction SilentlyContinue
if ($helperProc) {
    try {
        Stop-Process -Id $helperProc.Id -Force -ErrorAction Stop
        Write-Host "Stopped HelperService (PID $($helperProc.Id))"
    }
    catch {
        Write-Host "Failed to stop HelperService: $_"
    }
}
else {
    Write-Host "HelperService not running, continuing..."
}

# ------------------------------
# Create directories
# ------------------------------
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path $ProgramDataDir -Force | Out-Null

# ------------------------------
# Validate binaries exist
# ------------------------------
$RequiredFiles = @(
    "WindowService.exe",
    "HelperService.exe",
    "libcrypto-3-x64.dll",
    "libssl-3-x64.dll",
    "sentry.dll",
    "crashpad_handler.exe",
    "vcruntime140_1.dll",
    "sentry.h"  
)

foreach ($file in $RequiredFiles) {
    $path = Join-Path $BinDir $file
    if (!(Test-Path $path)) {
        Write-Host "MISSING FILE: $path"
        exit 1
    }
}

# ------------------------------
# Copy binaries
# ------------------------------
Write-Host "Copying service + DLLs..."
Copy-Item (Join-Path $BinDir "WindowService.exe") $InstallDir -Force
Copy-Item (Join-Path $BinDir "libcrypto-3-x64.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "libssl-3-x64.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "sentry.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "crashpad_handler.exe") $InstallDir -Force
Copy-Item (Join-Path $BinDir "vcruntime140_1.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "sentry.h") $InstallDir -Force


Write-Host "Copying helper..."
Copy-Item (Join-Path $BinDir "HelperService.exe") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "libcrypto-3-x64.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "libssl-3-x64.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "sentry.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "crashpad_handler.exe") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "vcruntime140_1.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "sentry.h") $ProgramDataDir -Force
# ------------------------------
# Delete service if exists
# ------------------------------
cmd.exe /c "sc delete $ServiceName" | Out-Null
Start-Sleep 2

# ------------------------------
# Create service
# ------------------------------
Write-Host "Creating Windows service..."

$binPath = '"' + $ServiceExe + ' --service"'

$createCmd = "sc create $ServiceName binPath= $binPath start= auto DisplayName= `"PiFocus Window Service`" obj= LocalSystem"

Write-Host "CREATE CMD:"
Write-Host $createCmd

$createResult = cmd.exe /c $createCmd
Write-Host $createResult

if ($createResult -notmatch "SUCCESS") {
    Write-Host "SERVICE CREATION FAILED"
    exit 1
}

cmd.exe /c "sc description $ServiceName `"PiFocus background tracking service`"" | Out-Null
cmd.exe /c "sc privs $ServiceName SeTcbPrivilege/SeAssignPrimaryTokenPrivilege/SeIncreaseQuotaPrivilege"
cmd.exe /c "sc sidtype $ServiceName unrestricted"
cmd.exe /c "sc sdset $ServiceName D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;RPWPCR;;;AU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)"
cmd.exe /c "sc failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000" | Out-Null

# ------------------------------
# Verify + Start service
# ------------------------------
Start-Sleep 1


Write-Host "Starting service..."
cmd.exe /c "sc start $ServiceName"

Write-Host "==== PiFocus Agent Installed Successfully ===="
