param(
    [ValidateSet('prod','stage')]
    [string]$Env
)

$ErrorActionPreference = "Continue"

# Auto-unblock every .ps1 next to us BEFORE we dot-source anything.
#
# Field bug (Manvi's laptop, 2026-07-29): user ran `Unblock-File install.ps1`
# after downloading + extracting the ZIP, then ran `.\install.ps1`. The
# script started fine, but the moment it dot-sourced Env-Config.ps1 (below)
# PowerShell refused with "cannot be loaded because it is not digitally
# signed" -- Env-Config.ps1 still had its downloaded-from-internet Zone.
# Identifier marker. $cfg ended up null, every $cfg.XXX below became null,
# and Copy-Item with an empty destination silently rewrote files in place
# ("Cannot overwrite ... with itself") while the install log claimed
# progress. 50+ error lines, unhelpful state on disk.
#
# We can't unblock the script currently loading (that would be too late
# for us), but every SIBLING file we're about to touch we can unblock now.
try {
    Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue } catch { }
        }
} catch { }

# If the caller did not pass -Env, look for a sibling env.txt marker file.
# Build-Package.ps1 writes it into each staging folder so a direct run of
# the copied install.ps1 (i.e. "cd _package_..._stage; .\install.ps1")
# picks up the right env WITHOUT the caller having to remember the flag.
# Fallback if nothing is found: prod, matching historical behavior.
if (-not $PSBoundParameters.ContainsKey('Env') -or [string]::IsNullOrWhiteSpace($Env)) {
    $envMarker = Join-Path $PSScriptRoot 'env.txt'
    if (Test-Path $envMarker) {
        $Env = (Get-Content $envMarker -Raw).Trim().ToLower()
    }
    if ([string]::IsNullOrWhiteSpace($Env)) { $Env = 'prod' }
}
if ($Env -ne 'prod' -and $Env -ne 'stage') {
    throw "install.ps1: invalid env '$Env' (expected prod|stage; check env.txt)"
}

# Env-Config.ps1 is the single source of truth for prod vs stage names/paths.
. (Join-Path $PSScriptRoot 'Env-Config.ps1')
$cfg = Get-PiFocusEnv -Env $Env

# Hard-fail fast if Env-Config didn't produce a config -- otherwise every
# $cfg.XXX below is null and we spew 50 cascading "parameter cannot be null"
# errors while quietly corrupting the install. Better to stop clean here.
if (-not $cfg -or [string]::IsNullOrWhiteSpace($cfg.InstallDir) -or [string]::IsNullOrWhiteSpace($cfg.ProgramDataDir)) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "FATAL: Env-Config.ps1 did not load successfully." -ForegroundColor Red
    Write-Host "The most common cause is that Env-Config.ps1 is still marked as" -ForegroundColor Red
    Write-Host "'downloaded from the internet' and PowerShell refuses to load it." -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    Write-Host "Run this ONE command, then re-run install.ps1:" -ForegroundColor Yellow
    Write-Host "  Get-ChildItem `"$PSScriptRoot`" -Filter '*.ps1' | Unblock-File" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Red
    exit 1
}

$ServiceName    = $cfg.ServiceName
$Root           = $PSScriptRoot
$BinDir         = $Root
$InstallDir     = $cfg.InstallDir
$ProgramDataDir = $cfg.ProgramDataDir
$ServiceExe     = Join-Path $InstallDir "WindowService.exe"
$version        = "1.0.6"   # Update this value for each release

# ------------------------------
# Logging - set up FIRST so every step is captured
# ------------------------------
$LogDir  = $cfg.LogDir
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

Write-Log "==== PiFocus Agent Install Started (env=$($cfg.EnvName) version=$version) ===="
Write-Log "Binary source directory: $BinDir"
Write-Log "Target service:  $ServiceName"
Write-Log "Install dir:     $InstallDir"
Write-Log "ProgramData dir: $ProgramDataDir"

# ------------------------------
# Helpers used later for source + post-install marker verification
# ------------------------------
# Loads the file and searches BOTH ASCII and UTF-16LE representations
# (C++ string literals in the .exe may be either). Returns $true if any
# needle is present.
function Test-BinaryHasNeedles {
    param([string]$Path, [string[]]$Needles)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $blob  = [System.Text.Encoding]::ASCII.GetString($bytes) + [System.Text.Encoding]::Unicode.GetString($bytes)
    } catch {
        Write-Log "Test-BinaryHasNeedles: failed to read $Path : $_" "ERROR"
        return $false
    }
    foreach ($n in $Needles) {
        if ($blob.Contains($n)) { return $true }
    }
    return $false
}

# Markers proving the binary was built on or after the given date.
# These are literal strings compiled into the C++ source.
#   * upn.change           -- HelperService, July-10+ (per-user audit)
#   * chrome://newtab      -- HelperService, July-14+ (newtab filter)
#   * helper.stale_killed  -- WindowService, July-15+ (Fast User Switch fix)
#   * SET_TRACKING_ENABLED -- WindowService, pause/resume state-sync fix.
#         Its ABSENCE means this build still lets an app-initiated pause
#         bypass the registry, so the next service restart silently reverts
#         the user. See PAUSE-RESUME-FLOW.md. Refuse to deploy without it.
$HelperFreshnessMarkers = @('upn.change')
$WindowFreshnessMarkers = @('helper.stale_killed')
$WindowPauseSyncMarkers = @('SET_TRACKING_ENABLED')

# ------------------------------
# Preflight: log EXACTLY what we're about to install, and REFUSE to
# proceed if the source binaries are older than the fixes we shipped.
# ------------------------------
# Field bug (Drashti / Jahanvi laptops): the .intunewin that Intune
# deployed on 2026-07-16 had a FRESH WindowService.exe but a June-3
# HelperService.exe alongside it. install.ps1 copied both, the old
# Copy-Item silently succeeded (no lock, just wrong source), and the
# install log ended in "Successfully" -- with a stale helper that
# had none of the URL / UPN fixes. The install log gave us zero
# signal that anything was wrong.
#
# Two safeguards below make that class of bug impossible from now on:
#   1. Log the source file mtime + size for every required file so
#      the install log itself proves what was in the package.
#   2. Read the source HelperService.exe and WindowService.exe and
#      REQUIRE that specific fix-markers are present. If absent, the
#      packager shipped a stale binary -- abort loudly here rather
#      than deploy a broken helper that will look "installed" but
#      never categorize URLs.
Write-Log "----------------------------------------------------------------"
Write-Log "PACKAGE INVENTORY (what this install is about to deploy):"
foreach ($f in @('WindowService.exe','HelperService.exe','libcrypto-3-x64.dll','libssl-3-x64.dll','sentry.dll','crashpad_handler.exe','msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll','sentry.h')) {
    $sp = Join-Path $BinDir $f
    if (Test-Path -LiteralPath $sp) {
        $fi = Get-Item -LiteralPath $sp
        Write-Log ("  {0,-24} src mtime={1:yyyy-MM-dd HH:mm:ss}  size={2}" -f $f, $fi.LastWriteTime, $fi.Length)
    } else {
        Write-Log ("  {0,-24} MISSING from package" -f $f) "ERROR"
    }
}

$srcHelper = Join-Path $BinDir 'HelperService.exe'
$srcWindow = Join-Path $BinDir 'WindowService.exe'
$srcHelperFresh = Test-BinaryHasNeedles -Path $srcHelper -Needles $HelperFreshnessMarkers
$srcWindowFresh = Test-BinaryHasNeedles -Path $srcWindow -Needles $WindowFreshnessMarkers
$srcWindowPauseSync = Test-BinaryHasNeedles -Path $srcWindow -Needles $WindowPauseSyncMarkers
Write-Log ("PACKAGE FRESHNESS CHECK: src HelperService.exe contains marker '{0}' -> {1}" -f ($HelperFreshnessMarkers -join '/'), $srcHelperFresh)
Write-Log ("PACKAGE FRESHNESS CHECK: src WindowService.exe contains marker '{0}' -> {1}" -f ($WindowFreshnessMarkers -join '/'), $srcWindowFresh)
Write-Log ("PACKAGE FRESHNESS CHECK: src WindowService.exe contains marker '{0}' -> {1}" -f ($WindowPauseSyncMarkers -join '/'), $srcWindowPauseSync)
if (-not $srcWindowPauseSync) {
    Write-Log "================================================================" "ERROR"
    Write-Log "REFUSING TO INSTALL: WindowService.exe predates the pause/resume" "ERROR"
    Write-Log "state-sync fix (marker '$($WindowPauseSyncMarkers -join '/')' not found)." "ERROR"
    Write-Log "" "ERROR"
    Write-Log "On this build an app-initiated pause never reaches the registry," "ERROR"
    Write-Log "so the next service restart SILENTLY REVERTS the user's choice -" "ERROR"
    Write-Log "a paused user gets tracked again without being told." "ERROR"
    Write-Log "" "ERROR"
    Write-Log "Rebuild WindowService from current source and repackage." "ERROR"
    Write-Log "See PAUSE-RESUME-FLOW.md." "ERROR"
    Write-Log "================================================================" "ERROR"
    exit 1
}
if (-not $srcHelperFresh) {
    Write-Log "================================================================" "ERROR"
    Write-Log "ABORTING INSTALL -- PACKAGED HelperService.exe IS STALE" "ERROR"
    Write-Log "The HelperService.exe inside this .intunewin does not contain the" "ERROR"
    Write-Log "expected fix-marker ($($HelperFreshnessMarkers -join '/'))." "ERROR"
    Write-Log "This means whoever built the package included an OLD helper." "ERROR"
    Write-Log "Rebuild the .intunewin from a source folder that has the July-10+" "ERROR"
    Write-Log "HelperService.exe, then re-upload to Intune." "ERROR"
    Write-Log "================================================================" "ERROR"
    exit 1
}
if (-not $srcWindowFresh) {
    Write-Log "================================================================" "ERROR"
    Write-Log "ABORTING INSTALL -- PACKAGED WindowService.exe IS STALE" "ERROR"
    Write-Log "Expected marker missing: $($WindowFreshnessMarkers -join '/')" "ERROR"
    Write-Log "Rebuild the .intunewin from a July-15+ WindowService.exe source." "ERROR"
    Write-Log "================================================================" "ERROR"
    exit 1
}
Write-Log "PACKAGE FRESHNESS CHECK PASSED -- both binaries carry the expected fix-markers."
Write-Log "----------------------------------------------------------------"


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
# Stop helper (safe) -- ONLY our env's helper
# ------------------------------
# Both prod and stage ship a binary called HelperService.exe. If we stop
# every process by name, a prod install kills the stage helper (and vice
# versa) and the other env silently loses uploads until its service happens
# to respawn. Filter by full image path.
$OurHelperExe = Join-Path $ProgramDataDir 'HelperService.exe'
Write-Log "Stopping HelperService if running (only $OurHelperExe)..."
$helperProcs = Get-Process -Name "HelperService" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and ($_.Path -ieq $OurHelperExe) }
if ($helperProcs) {
    foreach ($hp in $helperProcs) {
        try {
            Stop-Process -Id $hp.Id -Force -ErrorAction Stop
            Write-Log "Stopped HelperService (PID $($hp.Id), path=$($hp.Path))"
        }
        catch {
            Write-Log "Failed to stop HelperService PID $($hp.Id): $_"
        }
    }
}
else {
    Write-Log "Our HelperService not running, continuing..."
}

# ------------------------------
# Safe-copy helper -- lock-aware, size-verified, with retries
# ------------------------------
# Fixes the "partial upgrade" bug seen in the field (Jahanvi's laptop
# had a fresh WindowService.exe but the June-3 HelperService.exe still
# on disk because Copy-Item failed silently when the destination file
# was locked by a not-yet-fully-terminated HelperService process).
# WindowService.exe hits the same class of bug when the SCM's stop
# request is acknowledged before the process actually releases its
# executable's file handle. Retry up to 12x with 500ms sleep, then
# verify the destination file length matches the source. Fail loudly.
function Copy-ItemVerified {
    param(
        [Parameter(Mandatory=$true)][string]$Src,
        [Parameter(Mandatory=$true)][string]$DestDir
    )
    if (-not (Test-Path $Src)) { Write-Log "MISSING SOURCE: $Src" "ERROR"; return $false }
    $srcInfo  = Get-Item $Src
    $destFile = Join-Path $DestDir $srcInfo.Name

    # If a stale copy exists and something (usually HelperService that has
    # not fully died yet) holds a handle on it, Copy-Item -Force errors
    # with UnauthorizedAccessException. Try to force it out of the way
    # first: kill any process whose Path == destFile, then rename the
    # old file so the copy always writes fresh.
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            # Kill any process still holding the destination binary open.
            # Only fires if the process's full image path exactly matches
            # -- won't touch the other env's helper.
            $holders = Get-Process -EA SilentlyContinue |
                       Where-Object { $_.Path -and ($_.Path -ieq $destFile) }
            foreach ($h in $holders) {
                Write-Log "Copy-ItemVerified: killing stale holder PID $($h.Id) of $destFile"
                Stop-Process -Id $h.Id -Force -EA SilentlyContinue
            }

            # Escalation: after retry 6, the path-matched kill above is not
            # finding anything, yet the copy still fails. That happens when
            # a helper is running from a DIFFERENT path (old install layout,
            # or spawned by an install script from before the layout was
            # nailed down). taskkill /F /IM reaches ALL sessions system-wide
            # and doesn't require the path to match, so it stops any stray
            # HelperService.exe regardless of where it was launched from.
            # This intentionally BREAKS prod/stage isolation for this one
            # window -- correctness of the install outranks isolation when
            # the alternative is silently leaving a stale binary behind.
            if ($attempt -ge 6 -and $srcInfo.Name -ieq 'HelperService.exe') {
                Write-Log "Copy-ItemVerified: retry $attempt reached -- escalating to system-wide taskkill /F /IM HelperService.exe"
                cmd.exe /c "taskkill /F /IM HelperService.exe /T" 2>&1 | Out-Null
                Start-Sleep -Milliseconds 800
            }
            if ($attempt -ge 6 -and $srcInfo.Name -ieq 'WindowService.exe') {
                Write-Log "Copy-ItemVerified: retry $attempt reached -- escalating to system-wide taskkill /F /IM WindowService.exe"
                cmd.exe /c "taskkill /F /IM WindowService.exe /T" 2>&1 | Out-Null
                Start-Sleep -Milliseconds 800
            }

            Copy-Item -LiteralPath $Src -Destination $destFile -Force -EA Stop
            # Post-copy verification: size must match source exactly. If a
            # concurrent write raced with us, or an AV interceptor rewrote
            # the file, the sizes will differ and we'll retry.
            $destInfo = Get-Item $destFile -EA Stop
            if ($destInfo.Length -eq $srcInfo.Length) {
                Write-Log ("Copy-ItemVerified: {0} OK  src mtime={1:yyyy-MM-dd HH:mm:ss} size={2}  ->  dst mtime={3:yyyy-MM-dd HH:mm:ss} size={4} (attempt {5})" -f $srcInfo.Name, $srcInfo.LastWriteTime, $srcInfo.Length, $destInfo.LastWriteTime, $destInfo.Length, $attempt)
                return $true
            } else {
                Write-Log "Copy-ItemVerified: $($srcInfo.Name) size mismatch (src=$($srcInfo.Length) dst=$($destInfo.Length)) attempt $attempt/12"
            }
        } catch {
            Write-Log "Copy-ItemVerified: $($srcInfo.Name) failed (attempt $attempt/12): $_"
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Log "Copy-ItemVerified: GAVE UP on $($srcInfo.Name) after 12 attempts -- installed binary may be STALE" "ERROR"
    return $false
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
    "msvcp140.dll",
    "vcruntime140.dll",
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
# Use Copy-ItemVerified for the TWO service .exe files -- these are the
# ones that get locked mid-install (see comment on the helper function
# for context on the Jahanvi laptop bug). Everything else is DLLs /
# runtime files that don't get held open by our own processes long
# enough to cause a copy race.
Write-Log "Copying service + DLLs to $InstallDir..."
if (-not (Copy-ItemVerified -Src (Join-Path $BinDir "WindowService.exe") -DestDir $InstallDir)) {
    Write-Log "ABORTING: could not replace WindowService.exe" "ERROR"
    exit 1
}
Copy-Item (Join-Path $BinDir "libcrypto-3-x64.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "libssl-3-x64.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "sentry.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "crashpad_handler.exe") $InstallDir -Force
# Full app-local CRT trio - independent of whatever VC++ Redistributable
# version is installed system-wide. Avoids the MSVCP140 14.11 ABI skew that
# crashed WindowService.exe on devices with the 2017 redist.
Copy-Item (Join-Path $BinDir "msvcp140.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "vcruntime140.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "vcruntime140_1.dll") $InstallDir -Force
Copy-Item (Join-Path $BinDir "sentry.h") $InstallDir -Force


Write-Log "Copying helper to $ProgramDataDir..."
if (-not (Copy-ItemVerified -Src (Join-Path $BinDir "HelperService.exe") -DestDir $ProgramDataDir)) {
    Write-Log "ABORTING: could not replace HelperService.exe -- device would be left with stale helper" "ERROR"
    exit 1
}
Copy-Item (Join-Path $BinDir "libcrypto-3-x64.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "libssl-3-x64.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "sentry.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "crashpad_handler.exe") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "msvcp140.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "vcruntime140.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "vcruntime140_1.dll") $ProgramDataDir -Force
Copy-Item (Join-Path $BinDir "sentry.h") $ProgramDataDir -Force

# ------------------------------
# Post-install verification: the files on disk MUST be fresh
# ------------------------------
# The preflight check upstream verified the SOURCE binaries carry the
# fix-markers. This block verifies the DESTINATION binaries carry them
# too -- i.e. the copy actually landed. If anything (AV, permission
# quirk, race with a helper we didn't kill) left an old binary on disk
# and Copy-ItemVerified didn't catch it, this makes the failure visible
# in the install log AND fails the Intune install so the device shows
# "Failed" rather than "Installed" with a broken helper.
Write-Log "----------------------------------------------------------------"
Write-Log "POST-INSTALL VERIFICATION:"
$installedHelper = Join-Path $ProgramDataDir 'HelperService.exe'
$installedWindow = Join-Path $InstallDir    'WindowService.exe'
if (Test-Path -LiteralPath $installedHelper) {
    $fi = Get-Item -LiteralPath $installedHelper
    Write-Log ("  installed HelperService.exe mtime={0:yyyy-MM-dd HH:mm:ss} size={1}" -f $fi.LastWriteTime, $fi.Length)
} else {
    Write-Log "  installed HelperService.exe MISSING at $installedHelper" "ERROR"
    exit 1
}
if (Test-Path -LiteralPath $installedWindow) {
    $fi = Get-Item -LiteralPath $installedWindow
    Write-Log ("  installed WindowService.exe mtime={0:yyyy-MM-dd HH:mm:ss} size={1}" -f $fi.LastWriteTime, $fi.Length)
} else {
    Write-Log "  installed WindowService.exe MISSING at $installedWindow" "ERROR"
    exit 1
}
$dstHelperFresh = Test-BinaryHasNeedles -Path $installedHelper -Needles $HelperFreshnessMarkers
$dstWindowFresh = Test-BinaryHasNeedles -Path $installedWindow -Needles $WindowFreshnessMarkers
$dstWindowPauseSync = Test-BinaryHasNeedles -Path $installedWindow -Needles $WindowPauseSyncMarkers
Write-Log ("  installed Helper has marker '{0}': {1}" -f ($HelperFreshnessMarkers -join '/'), $dstHelperFresh)
Write-Log ("  installed Window has marker '{0}': {1}" -f ($WindowFreshnessMarkers -join '/'), $dstWindowFresh)
Write-Log ("  installed Window has marker '{0}': {1}" -f ($WindowPauseSyncMarkers -join '/'), $dstWindowPauseSync)
if (-not $dstWindowPauseSync) {
    Write-Log "================================================================" "ERROR"
    Write-Log "POST-INSTALL VERIFY FAILED: installed WindowService.exe is missing" "ERROR"
    Write-Log "the pause/resume state-sync marker. A stale binary is on disk." "ERROR"
    Write-Log "================================================================" "ERROR"
    exit 1
}
if (-not $dstHelperFresh) {
    Write-Log "================================================================" "ERROR"
    Write-Log "POST-INSTALL VERIFICATION FAILED -- installed Helper is STALE" "ERROR"
    Write-Log "This should never happen after Copy-ItemVerified succeeded." "ERROR"
    Write-Log "Something between the copy and now (AV, sync tool, another" "ERROR"
    Write-Log "installer) restored an old file. Install marked FAILED so the" "ERROR"
    Write-Log "device shows as Not Installed in Intune and gets retried." "ERROR"
    Write-Log "================================================================" "ERROR"
    exit 1
}
if (-not $dstWindowFresh) {
    Write-Log "================================================================" "ERROR"
    Write-Log "POST-INSTALL VERIFICATION FAILED -- installed Window is STALE" "ERROR"
    Write-Log "================================================================" "ERROR"
    exit 1
}
Write-Log "POST-INSTALL VERIFICATION PASSED -- both installed binaries are fresh."
Write-Log "----------------------------------------------------------------"

# ------------------------------
# Delete service if exists - wait until truly gone
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

$createCmd = "sc create $ServiceName binPath= $binPath start= auto DisplayName= `"$($cfg.ServiceDisplayName)`" obj= LocalSystem"

Write-Log "CREATE CMD: $createCmd"

$createResult = cmd.exe /c $createCmd
Write-Log "SC CREATE result: $createResult"

if ($createResult -notmatch "SUCCESS") {
    Write-Log "SERVICE CREATION FAILED" "ERROR"
    exit 1
}

cmd.exe /c "sc description $ServiceName `"$($cfg.ServiceDescription)`"" | Out-Null
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

Write-Log "PiFocus Agent Versioning Completed Successfully"

# Final verdict banner -- the last thing in the install log is a
# self-contained pass/fail summary. If this line is present with all
# markers True, the device is CONCLUSIVELY on the fresh binaries. If
# any marker is False (or this banner is missing), something upstream
# failed silently and the install log will show it.
Write-Log "================================================================"
Write-Log "==== PiFocus Agent Installed Successfully ===="
Write-Log ("VERDICT env={0} version={1} Helper_fresh={2} Window_fresh={3}" -f $cfg.EnvName, $version, $dstHelperFresh, $dstWindowFresh)
Write-Log "================================================================"
