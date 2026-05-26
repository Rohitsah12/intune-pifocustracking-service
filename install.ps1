$ErrorActionPreference = "Continue"

$ServiceName   = "PiFocusWindowService"
$Root          = $PSScriptRoot
$BinDir        = $Root
$InstallDir    = "C:\Program Files\PiFocus\Agent"
$ProgramDataDir= "C:\ProgramData\PiFocus"
$ServiceExe    = Join-Path $InstallDir "WindowService.exe"
$version       = "1.0.2"   # Update this value for each release

# ------------------------------
# Logging — set up FIRST so every step is captured
# ------------------------------
$LogDir  = "C:\ProgramData\PiFocus\Logs"
$LogFile = Join-Path $LogDir "Install.log"

if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry  = "$timestamp [$Level] $Message"
    Write-Host $logEntry
    Add-Content -Path $LogFile -Value $logEntry
}

Write-Log "==== PiFocus Agent Install Started (version $version) ===="
Write-Log "Binary source directory: $BinDir"



# ------------------------------
# Stop existing service
# ------------------------------
Write-Log "Stopping existing service..."
cmd.exe /c "sc stop $ServiceName" | Out-Null
Start-Sleep 3

# Try get PID
$pidLine = cmd.exe /c "sc queryex $ServiceName" | Select-String "PID"

if ($pidLine) {
    try {
        $servicePid = ($pidLine -split ":")[1].Trim()
        if ($servicePid -ne "0") {
            Write-Log "Force killing service PID $servicePid"
            taskkill /F /PID $servicePid /T | Out-Null
        }
    }
    catch {
        Write-Log "Could not parse service PID"
    }
}

# ------------------------------
# Stop helper (safe)
# ------------------------------
Write-Log "Stopping HelperService if running..."
$helperProc = Get-Process -Name "HelperService" -ErrorAction SilentlyContinue
if ($helperProc) {
    try {
        Stop-Process -Id $helperProc.Id -Force -ErrorAction Stop
        Write-Log "Stopped HelperService (PID $($helperProc.Id))"
    }
    catch {
        Write-Log "Failed to stop HelperService: $_"
    }
}
else {
    Write-Log "HelperService not running, continuing..."
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
        Write-Log "MISSING FILE: $path" "ERROR"
        exit 1
    }
}

# ------------------------------
# Copy binaries
# ------------------------------
Write-Log "Copying service + DLLs..."
Copy-Item (Join-Path $BinDir "WindowService.exe") $InstallDir -Force
Copy-Item (Join-Path $BinDir "libcrypto-3-x64.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "libssl-3-x64.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "sentry.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "crashpad_handler.exe") $InstallDir -Force
Copy-Item (Join-Path $BinDir "vcruntime140_1.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "sentry.h") $InstallDir -Force


Write-Log "Copying helper..."
Copy-Item (Join-Path $BinDir "HelperService.exe") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "libcrypto-3-x64.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "libssl-3-x64.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "sentry.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "crashpad_handler.exe") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "vcruntime140_1.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "sentry.h") $ProgramDataDir -Force
# ------------------------------
# Delete service if exists — wait until truly gone
# ------------------------------
Write-Log "Deleting existing service (if any)..."
cmd.exe /c "sc delete $ServiceName" | Out-Null

$waitSec = 0
while ($waitSec -lt 30) {
    $svcCheck = cmd.exe /c "sc query $ServiceName" 2>&1
    if ($svcCheck -match "1060") { break }   # 1060 = service does not exist
    Write-Log "Waiting for service deletion... ($waitSec s)"
    Start-Sleep 2
    $waitSec += 2
}

if ($waitSec -ge 30) {
    Write-Log "Service could not be deleted within 30 seconds. Aborting." "ERROR"
    exit 1
}

Write-Log "Service deleted (or was never present)."

# ------------------------------
# Create service
# ------------------------------
Write-Log "Creating Windows service..."

$binPath = '"' + $ServiceExe + ' --service"'

$createCmd = "sc create $ServiceName binPath= $binPath start= auto DisplayName= `"PiFocus Window Service`" obj= LocalSystem"

Write-Log "CREATE CMD: $createCmd"

$createResult = cmd.exe /c $createCmd
Write-Log "SC CREATE result: $createResult"

if ($createResult -notmatch "SUCCESS") {
    Write-Log "SERVICE CREATION FAILED" "ERROR"
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


Write-Log "Starting service..."
cmd.exe /c "sc start $ServiceName"

Write-Log "--------------------------------------------"
Write-Log "PiFocus Agent Versioning Started"
Write-Log "Target Version: $version"

# ------------------------------
# Write Version to Install Directory
# ------------------------------
try {
    $versionFilePath = Join-Path $InstallDir "version.txt"
    Write-Log "Writing version to file: $versionFilePath"

    $version | Set-Content -Path $versionFilePath -Force

    Write-Log "Version file written successfully."
}
catch {
    Write-Log "Failed to write version file. Error: $_" "ERROR"
    exit 1
}

# ------------------------------
# Write Version to Windows Registry (temporarily disabled)
# ------------------------------
# try {
#     $regPath = "HKLM:\SOFTWARE\PiFocus\Agent"
#     Write-Log "Ensuring registry path exists: $regPath"
#
#     if (!(Test-Path $regPath)) {
#         New-Item -Path $regPath -Force | Out-Null
#         Write-Log "Registry path created."
#     } else {
#         Write-Log "Registry path already exists."
#     }
#
#     Write-Log "Writing Version=$version to registry."
#     Set-ItemProperty -Path $regPath -Name "Version" -Value $version -Force
#
#     Write-Log "Writing InstallDir=$InstallDir to registry."
#     Set-ItemProperty -Path $regPath -Name "InstallDir" -Value $InstallDir -Force
#
#     Write-Log "Registry values written successfully."
# }
# catch {
#     Write-Log "Failed to write registry values. Error: $_" "ERROR"
#     exit 1
# }
#
# # Verify Registry Values
# try {
#     Write-Log "Verifying registry entries..."
#     $regValues = Get-ItemProperty -Path $regPath
#     Write-Log "Registry Version: $($regValues.Version)"
#     Write-Log "Registry InstallDir: $($regValues.InstallDir)"
# }
# catch {
#     Write-Log "Failed to verify registry values. Error: $_" "ERROR"
# }

Write-Log "PiFocus Agent Versioning Completed Successfully"
Write-Log "==== PiFocus Agent Installed Successfully ===="
