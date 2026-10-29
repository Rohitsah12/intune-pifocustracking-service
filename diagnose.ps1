<#
==============================================================================
 PiFocus Agent - One-Shot Diagnostics  (READ-ONLY, STANDALONE, PROD-ONLY)
==============================================================================
 Zero dependencies. Zero parameters. Just download this ONE file and run.
 Every path/name below is hardcoded to production. Works identically for
 both install topologies:
   - Intune install     (C:\Program Files\PiFocus\Agent + Windows service)
   - Electron desktop   (%LOCALAPPDATA%\Programs\pi-focus-business-app)
 If a section's paths do not exist on the device, that section shows INFO
 and moves on -- no crash, no missing-dependency error.

 Run as: ADMIN PowerShell, while the AFFECTED USER is logged in.
   Right-click PowerShell -> "Run as administrator", then:
     powershell -ExecutionPolicy Bypass -File .\diagnose.ps1

 What it answers: "Why is no activity data reaching the backend (0 hrs)?"
 It walks the whole data path and prints a single ROOT-CAUSE verdict.

 It modifies NOTHING. It only reads files, registry, services, event log.
==============================================================================
#>

#------------------------------------------------------------------- constants
# Hardcoded PROD values. If you ever need to diagnose staging, this is the
# wrong tool -- staging has its own suffix ("Stage") on every path/service
# name and this script won't find any of it. That is intentional: the
# 99% case is "prod device, something is wrong, tell me why", and every
# extra param (or Env-Config.ps1 dependency) has burned us in the field
# when the recipient's Downloads folder didn't have the sibling file.
$AgentDir     = 'C:\Program Files\PiFocus\Agent'
$AgentExe     = Join-Path $AgentDir "WindowService.exe"
$VersionFile  = Join-Path $AgentDir "version.txt"
$HelperDir    = 'C:\ProgramData\PiFocus'
$HelperExe    = Join-Path $HelperDir "HelperService.exe"
$InstallLog   = 'C:\ProgramData\PiFocus\Logs\Install.log'
$DebugLogDir  = 'C:\ProgramData\ProgramMonitor\debugLogs'
$ReportsDir   = 'C:\ProgramData\ProgramMonitor\daily_reports'
$SentryDir    = 'C:\ProgramData\PiFocus\Agent\sentry\windowservice'
$ServiceName  = 'PiFocusWindowService'
$BackendHost  = 'api.penpencil.co'
# Where the diagnostic uploads ITS OWN report. Kept on STAGE deliberately so
# diagnostic reports land in the stage backend (the §6 connectivity probe still
# targets $BackendHost = PROD, i.e. where the AGENT actually sends its data --
# do NOT point the probe at stage or a prod device can read as "unreachable").
$DiagUploadHost = 'stage-api.penpencil.co'
$ActivitiesEP = "ingest/activities"
$HklmRoot     = 'HKLM:\SOFTWARE\PiFocus'
$HkcuHelper   = 'Software\PiFocus\Helper'
$PauseEvent   = 'Global\PiFocusPauseEvent'

$AgentSiblingDlls = @("libcrypto-3-x64.dll","libssl-3-x64.dll","sentry.dll","crashpad_handler.exe","vcruntime140_1.dll")
$CrtDlls          = @("MSVCP140.dll","VCRUNTIME140.dll","VCRUNTIME140_1.dll")

# Electron app paths - filled in after we know the active user (Section 0)
$ElectronAppLog    = $null
$ElectronBinDir    = $null
$ElectronUserTemp  = $null

#------------------------------------------------------------------- reporting
$script:ReportLines = New-Object System.Collections.Generic.List[string]
$script:Findings     = @{}   # flags used by the final verdict

function Line { param([string]$Text,[string]$Color="Gray")
    Write-Host $Text -ForegroundColor $Color
    $script:ReportLines.Add($Text)
}
function Section { param([string]$Title)
    Line ""
    Line ("=" * 78) "DarkCyan"
    Line ("  $Title") "Cyan"
    Line ("=" * 78) "DarkCyan"
}
function Check {
    param([string]$Name,[ValidateSet("PASS","WARN","FAIL","INFO")]$Status,[string]$Detail="")
    $tag = switch ($Status) { "PASS"{"[ PASS ]"} "WARN"{"[ WARN ]"} "FAIL"{"[ FAIL ]"} "INFO"{"[ INFO ]"} }
    $col = switch ($Status) { "PASS"{"Green"} "WARN"{"Yellow"} "FAIL"{"Red"} "INFO"{"Gray"} }
    $pad = $Name.PadRight(46)
    Line ("{0} {1} {2}" -f $tag,$pad,$Detail) $col
}

#----------------------------------------------------------------- small utils
function Test-Tcp { param($HostName,$Port,$TimeoutMs=4000)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($HostName,$Port,$null,$null)
        $ok  = $iar.AsyncWaitHandle.WaitOne($TimeoutMs,$false)
        if ($ok -and $c.Connected) { $c.EndConnect($iar); $c.Close(); return $true }
        $c.Close(); return $false
    } catch { return $false }
}
function Mask { param($s)
    if ([string]::IsNullOrEmpty($s)) { return "<empty>" }
    if ($s.Length -le 8) { return ("*" * $s.Length) }
    return ($s.Substring(0,4) + "..." + $s.Substring($s.Length-4) + "  (len=$($s.Length))")
}
# Read the last N lines of a JSON-lines log and return parsed objects (best-effort)
function Read-NdjsonTail { param($Path,$Tail=4000)
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $Path)) { return $out }
    try {
        $lines = Get-Content -Path $Path -Tail $Tail -ErrorAction Stop
        foreach ($ln in $lines) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            try { $out.Add(($ln | ConvertFrom-Json)) } catch {}
        }
    } catch {}
    return $out
}

#============================================================================ 0
Section "0. ENVIRONMENT"
$now = Get-Date
Line ("Run time      : {0}" -f $now)
Line ("Computer      : {0}" -f $env:COMPUTERNAME)
try { $os = Get-CimInstance Win32_OperatingSystem; Line ("OS            : {0} (Build {1})" -f $os.Caption,$os.BuildNumber) } catch {}
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([System.Security.Principal.WindowsPrincipal]$me).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
Line ("Running as    : {0}" -f $me.Name)
if ($elevated) { Check "Elevated (admin)" "PASS" } else { Check "Elevated (admin)" "FAIL" "Re-run in an ADMIN PowerShell - many checks need it" }

# Active console user (the person being tracked)
$ConsoleUser = $null; $ConsoleSid = $null; $ConsoleSession = $null
try { $ConsoleUser = (Get-CimInstance Win32_ComputerSystem).UserName } catch {}
if (-not $ConsoleUser) {
    try {
        $exp = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
        if ($exp) { $o = Invoke-CimMethod -InputObject $exp -MethodName GetOwner; $ConsoleUser = "$($o.Domain)\$($o.User)" }
    } catch {}
}
try { $ConsoleSession = (Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId } catch {}
if ($ConsoleUser) {
    try { $ConsoleSid = (New-Object System.Security.Principal.NTAccount($ConsoleUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch {}
    Check "Active console user" "INFO" ("{0}  (session {1}, SID {2})" -f $ConsoleUser,$ConsoleSession,$ConsoleSid)
} else {
    Check "Active console user" "WARN" "No interactive user detected - token & helper-session checks limited"
}

# Resolve the affected user's profile path, then pin the Electron paths to it
$UserProfilePath = $null
if ($ConsoleSid) {
    try { $UserProfilePath = (Get-CimInstance Win32_UserProfile -Filter "SID='$ConsoleSid'" -ErrorAction Stop).LocalPath } catch {}
}
if (-not $UserProfilePath -and $ConsoleUser) {
    $shortName = ($ConsoleUser -split "\\")[-1]
    $cand = Join-Path $env:SystemDrive ("Users\" + $shortName)
    if (Test-Path $cand) { $UserProfilePath = $cand }
}
if ($UserProfilePath) {
    $ElectronAppLog   = Join-Path $UserProfilePath "AppData\Roaming\pi-focus-business-app\app.log"
    $ElectronBinDir   = Join-Path $UserProfilePath "AppData\Local\Programs\pi-focus-business-app\resources\binaries"
    $ElectronAppExe   = Join-Path $UserProfilePath "AppData\Local\Programs\pi-focus-business-app\piFocus Business.exe"
    $ElectronUserData = Join-Path $UserProfilePath "AppData\Roaming\pi-focus-business-app"
    $ElectronUserTemp = Join-Path $UserProfilePath "AppData\Local\Temp"
    Check "User profile" "INFO" $UserProfilePath
} else {
    Check "User profile" "WARN" "could not resolve - Electron app log/binaries cannot be located"
}

# ------------ TEMP-profile detection ---------------------------------------
# If Windows loaded a temporary profile at logon (real profile corrupted / stuck
# / locked by another session), every per-user check below is a FALSE NEGATIVE
# because the user's real HKCU, AppData, Run key, etc. are not on this session.
# Flag it LOUDLY so IT doesn't chase 20 phantom problems.
$Findings.TempProfile = $false
$tempReason = $null
if ($UserProfilePath -and $UserProfilePath -match "\((?i:Temp)\)\s*$|\\TEMP(\.[^\\]+)?$") {
    $Findings.TempProfile = $true; $tempReason = "profile path suffix '(Temp)'"
}
if ($ConsoleSid) {
    try {
        $up = Get-CimInstance Win32_UserProfile -Filter "SID='$ConsoleSid'" -ErrorAction Stop
        # Win32_UserProfile.Status bitmask: 1=Temporary, 8=Corrupted
        if ($up.Status -band 1) { $Findings.TempProfile = $true; $tempReason = "Win32_UserProfile.Status has TEMPORARY bit set" }
        if ($up.Status -band 8) { $Findings.TempProfile = $true; $tempReason = "Win32_UserProfile.Status has CORRUPTED bit set" }
    } catch {}
}
if ($Findings.TempProfile) {
    Check "TEMP profile detected" "FAIL" ("This session is on a Windows TEMPORARY profile ($tempReason). EVERY per-user check below (Electron app, token, autolaunch, app.log, HKCU) reflects the empty temp profile - NOT the user's real state. FIX the profile first (sign out + reboot; if still Temp, check Event Viewer -> User Profile Service, and HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\<SID> for a .bak entry) then re-run this script.")
} else {
    Check "TEMP profile detected" "PASS" "real profile loaded"
}

# ------------ BIOS serial (Win32_BIOS is Win11-24H2+-proof, wmic isn't) -----
try {
    $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
    $serial = ($bios.SerialNumber -as [string])
    if ($serial) { $serial = $serial.Trim() }
    if ([string]::IsNullOrWhiteSpace($serial) -or $serial -match "^(?i:default string|to be filled by o\.e\.m|to be filled|none|na|n/a|unknown|system serial number|0)$") {
        Check "BIOS serial number" "WARN" ("'{0}' (placeholder - backend may reject or dedupe under a UUID-style fallback)" -f $bios.SerialNumber)
    } else {
        Check "BIOS serial number" "PASS" $serial
    }
} catch { Check "BIOS serial number" "INFO" "could not query Win32_BIOS" }

# ------------ Intune / AzureAD enrollment - answers "is this device managed?"
try {
    $dsr = & dsregcmd /status 2>$null
    $azAd = if ($m = ($dsr | Select-String "^\s*AzureAdJoined\s*:\s*(YES|NO)").Matches) { $m.Groups[1].Value } else { "" }
    $dom  = if ($m = ($dsr | Select-String "^\s*DomainJoined\s*:\s*(YES|NO)").Matches)   { $m.Groups[1].Value } else { "" }
    $mdm  = if ($m = ($dsr | Select-String "^\s*MdmUrl\s*:\s*(.+)$").Matches)             { $m.Groups[1].Value.Trim() } else { "" }
    $mdmYes = -not [string]::IsNullOrWhiteSpace($mdm)
    $joinType = if ($azAd -eq "YES") { "AzureAD-joined" } elseif ($dom -eq "YES") { "AD-joined" } else { "Workgroup (personal device)" }
    $Findings.IntuneEnrolled = $mdmYes
    $Findings.PersonalDevice = ($azAd -ne "YES" -and $dom -ne "YES")
    if ($mdmYes) { Check "Device enrollment" "PASS" ("{0} + MDM-enrolled ({1})" -f $joinType,$mdm) }
    else         { Check "Device enrollment" "INFO" ("{0}, no MDM enrollment - Intune push not possible, expect Electron install topology" -f $joinType) }
} catch { Check "Device enrollment" "INFO" "dsregcmd not available" }

# ------------ DEVICE IDENTITY the agent sends to /machine-key ---------------
# THE crux for "no token / machine-key fails". WindowService (SystemMonitor::
# getSerialNumber) resolves ONE id and puts it in GET /user-devices/<ID>/machine-key.
# Resolution order:  1) BIOS serial (if usable)  2) Intune EntDMID  3) MachineGuid.
# The backend maps devices by EntDMID -- so if EntDMID is NOT found here, the agent
# falls through to MachineGuid, the backend can't match it, and token fetch fails
# ("JSON parse failed on machine-key response") -> no token -> 0 hrs.
$idBiosUsable = -not ([string]::IsNullOrWhiteSpace($serial) -or $serial -match "^(?i:default string|to be filled by o\.e\.m|to be filled|none|na|n/a|unknown|system serial number|0)$")

# EntDMID -- read EXACTLY like C++ FetchIntuneDMID(): first enrolment whose
# DMClient\MS DM Server has a non-empty EntDMID (REG_SZ).
$entDmid = $null; $entEnrolls = 0; $entWithId = 0
try {
    foreach ($ek in (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop)) {
        $dmp = Join-Path $ek.PSPath 'DMClient\MS DM Server'
        if (Test-Path $dmp) {
            $entEnrolls++
            $v = (Get-ItemProperty $dmp -Name EntDMID -ErrorAction SilentlyContinue).EntDMID
            if (-not [string]::IsNullOrWhiteSpace($v)) { $entWithId++; if (-not $entDmid) { $entDmid = "$v".ToUpper() } }
        }
    }
} catch {}
# DeviceClientId (for reference / diagnostics-upload identity)
$devClientId = $null
try {
    $enr = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Enrollments\*' -ErrorAction SilentlyContinue |
           Where-Object { $_.ProviderID -eq 'MS DM Server' -and $_.DeviceClientId } | Select-Object -First 1
    if ($enr) { $devClientId = "$($enr.DeviceClientId)" }
} catch {}
$machineGuid = $null
try { $machineGuid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction SilentlyContinue).MachineGuid } catch {}

# Mirror the agent's chain to show what it WILL send
$resolvedId = $null; $resolvedSrc = $null
if     ($idBiosUsable) { $resolvedId = $serial;      $resolvedSrc = 'BIOS serial' }
elseif ($entDmid)      { $resolvedId = $entDmid;     $resolvedSrc = 'EntDMID' }
elseif ($machineGuid)  { $resolvedId = $machineGuid; $resolvedSrc = 'MachineGuid (LAST resort)' }

$Findings.EntDmidMissing    = (-not $idBiosUsable -and -not $entDmid)
$Findings.IdentityFallbackMachineGuid = ($resolvedSrc -eq 'MachineGuid (LAST resort)')

$entSt = if ($idBiosUsable) { 'INFO' } elseif ($entDmid) { 'PASS' } else { 'FAIL' }
Check "Intune EntDMID (agent fallback ID)" $entSt $(
    if ($idBiosUsable)  { "serial usable -> EntDMID not needed" }
    elseif ($entDmid)   { "{0}  ({1}/{2} MS-DM-Server enrolment(s) carry EntDMID)" -f $entDmid,$entWithId,$entEnrolls }
    else                { "NOT FOUND ({0} MS-DM-Server enrolment(s), 0 with EntDMID) -> agent falls back to MachineGuid, which the backend CANNOT map -> no token" -f $entEnrolls } )
if ($devClientId) { Check "Intune DeviceClientId (reference)" "INFO" $devClientId }
$resSt = if ($Findings.IdentityFallbackMachineGuid) { 'WARN' } elseif ($resolvedId) { 'PASS' } else { 'FAIL' }
Check "Resolved identity -> machine-key" $resSt $(
    if ($resolvedId) { "{0}   [source: {1}]   agent calls GET /user-devices/{0}/machine-key" -f $resolvedId,$resolvedSrc }
    else             { "could not resolve any identity (no serial, no EntDMID, no MachineGuid)" } )

#============================================================================ 1
Section "1. INSTALLATION INTEGRITY"
$Findings.AgentExe = Test-Path $AgentExe
if ($Findings.AgentExe) {
    $fi = Get-Item $AgentExe
    $fv = $fi.VersionInfo.FileVersion
    Check "WindowService.exe present" "PASS" ("ver={0}  size={1}KB  modified={2}" -f $fv,[int]($fi.Length/1KB),$fi.LastWriteTime)
} else { Check "WindowService.exe present" "FAIL" $AgentExe }

$Findings.HelperExe = Test-Path $HelperExe
if ($Findings.HelperExe) {
    $hi = Get-Item $HelperExe
    Check "HelperService.exe present" "PASS" ("ver={0}  size={1}KB  modified={2}" -f $hi.VersionInfo.FileVersion,[int]($hi.Length/1KB),$hi.LastWriteTime)
} else { Check "HelperService.exe present" "FAIL" $HelperExe }

if (Test-Path $VersionFile) {
    $vtxt = (Get-Content $VersionFile -Raw).Trim()
    Check "version.txt" "INFO" $vtxt
} else { Check "version.txt" "WARN" "missing (detection rule will fail this device)" }

# bundled sibling DLLs
$missingSib = @()
foreach ($d in $AgentSiblingDlls) { if (-not (Test-Path (Join-Path $AgentDir $d))) { $missingSib += $d } }
if ($missingSib.Count -eq 0) { Check "Bundled DLLs (Agent dir)" "PASS" ($AgentSiblingDlls -join ", ") }
else { Check "Bundled DLLs (Agent dir)" "FAIL" ("MISSING: " + ($missingSib -join ", ")) }

# VC++ runtime (the classic Error 1067 cause) - present if in System32 OR beside exe
$sys32 = Join-Path $env:WINDIR "System32"
$crtMissing = @()
foreach ($d in $CrtDlls) {
    $inSys  = Test-Path (Join-Path $sys32 $d)
    $inApp  = Test-Path (Join-Path $AgentDir $d)
    if (-not ($inSys -or $inApp)) { $crtMissing += $d }
}
$Findings.CrtMissing = $crtMissing
if ($crtMissing.Count -eq 0) { Check "VC++ runtime (MSVCP140/VCRUNTIME140)" "PASS" "resolvable" }
else { Check "VC++ runtime (MSVCP140/VCRUNTIME140)" "FAIL" ("NOT FOUND in System32 or app dir: " + ($crtMissing -join ", ") + "  => service load fails with 0xC0000135 / Error 1067") }
# VC++ redist registry marker - and verify the version is recent enough.
# Binaries built with VS 2022 (toolset 14.30+) MUST be paired with a redist
# at >= 14.30; older redist (e.g. v14.11 from VS 2017 RTW) causes the
# bundled vcruntime140_1.dll to skew against System32's MSVCP140.dll and
# the service dies with 0xC0000005 ACCESS_VIOLATION inside MSVCP140.
try {
    $rt = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" -ErrorAction Stop
    $vStr = ($rt.Version -replace '^v','').Trim()
    $parts = $vStr.Split('.')
    if ($parts.Length -ge 2) {
        $rnum = [int]$parts[0] * 100 + [int]$parts[1]
        if ($rnum -lt 1430) {
            $Findings.RedistTooOld = $true
            Check "VC++ 2015-2022 x64 redist" "FAIL" ("Installed v{0} -- TOO OLD (need >= 14.30). System32 MSVCP140 will ABI-skew against the bundled VCRUNTIME140_1 -> ACCESS_VIOLATION at startup. Install https://aka.ms/vs/17/release/vc_redist.x64.exe, OR redeploy the build that bundles msvcp140.dll + vcruntime140.dll app-locally." -f $vStr)
        } else {
            Check "VC++ 2015-2022 x64 redist" "PASS" ("v{0} (>= 14.30 OK)" -f $vStr)
        }
    } else {
        Check "VC++ 2015-2022 x64 redist" "WARN" ("v{0} cannot be parsed" -f $vStr)
    }
} catch { Check "VC++ 2015-2022 x64 redist" "WARN" "redist registry key not found - relying on app-local bundled DLLs" }

# Electron-bundled binaries (the app uses a DIFFERENT install topology than install.ps1
# - it points the service at the in-app exe instead of C:\Program Files\PiFocus\Agent)
$Findings.ElectronInstalled = $false
if ($ElectronBinDir -and (Test-Path $ElectronBinDir)) {
    $Findings.ElectronInstalled = $true
    $ews = Join-Path $ElectronBinDir "WindowService.exe"
    $ehs = Join-Path $ElectronBinDir "HelperService.exe"
    if (Test-Path $ews) {
        $i = Get-Item $ews
        Check "Electron-bundled WindowService.exe" "PASS" ("ver={0}  modified={1}" -f $i.VersionInfo.FileVersion,$i.LastWriteTime)
    } else { Check "Electron-bundled WindowService.exe" "WARN" "missing under resources\binaries" }
    if (Test-Path $ehs) { Check "Electron-bundled HelperService.exe" "PASS" } else { Check "Electron-bundled HelperService.exe" "WARN" "missing" }
} elseif ($ElectronBinDir) {
    Check "Electron app bundle" "INFO" "$ElectronBinDir not found - app may not be installed on this device"
}

#============================================================================ 1b
Section "1b. ELECTRON DESKTOP APP (piFocus Business)"
if (-not $ElectronAppExe) {
    Check "Electron app" "INFO" "user profile not resolved - skipping"
} else {
    if (Test-Path $ElectronAppExe) {
        $ai = Get-Item $ElectronAppExe
        $Findings.ElectronAppInstalled = $true
        Check "Desktop app installed" "PASS" ("ver={0}  modified={1}" -f $ai.VersionInfo.FileVersion,$ai.LastWriteTime)
    } else {
        Check "Desktop app installed" "FAIL" ("missing: {0}  - the PiFocus app itself is not installed on this profile" -f $ElectronAppExe)
    }

    # Process running
    $procs = @(Get-Process -Name "piFocus Business" -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        $Findings.ElectronAppRunning = $true
        $sids = ($procs | ForEach-Object { "PID $($_.Id) session $($_.SessionId)" }) -join ", "
        $st = if ($procs.Count -gt 1) { "WARN" } else { "PASS" }
        $note = if ($procs.Count -gt 1) { "  (>1 process = multi-instance / restart loop)" } else { "" }
        Check "Desktop app process" $st ("$sids$note")
    } else {
        Check "Desktop app process" "WARN" "not running right now (token may go stale, autolaunch may have been disabled)"
    }

    # Auto-launch registry key (HKCU\...\Run)
    try {
        $runKey = "Registry::HKEY_USERS\$ConsoleSid\Software\Microsoft\Windows\CurrentVersion\Run"
        if (-not $ConsoleSid -or -not (Test-Path $runKey)) { $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" }
        $runVals = Get-ItemProperty $runKey -ErrorAction Stop
        $piRun = $runVals.PSObject.Properties | Where-Object { $_.Value -match "pi-focus-business|piFocus" }
        if ($piRun) {
            Check "Auto-launch registered" "PASS" ("{0} = {1}" -f $piRun.Name, ($piRun.Value | Out-String).Trim())
        } else {
            Check "Auto-launch registered" "WARN" "no PiFocus value under HKCU\...\Run - app won't auto-start at login"
        }
    } catch { Check "Auto-launch registered" "INFO" "could not read Run key ($($_.Exception.Message))" }

    # User-data dir
    if ($ElectronUserData -and (Test-Path $ElectronUserData)) {
        $sz = 0
        try { $sz = [int]((Get-ChildItem $ElectronUserData -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1KB) } catch {}
        Check "User-data dir" "PASS" ("$ElectronUserData  ({0}KB)" -f $sz)
    } elseif ($ElectronUserData) {
        Check "User-data dir" "WARN" "$ElectronUserData missing - app never finished first launch on this profile"
    }

    # Chromium crash dumps (Electron writes minidumps here when the app itself crashes)
    $crashDirs = @()
    if ($ElectronUserData) {
        foreach ($sub in @("Crashpad\reports","Crash Reports\reports","Crashpad\completed")) {
            $p = Join-Path $ElectronUserData $sub
            if (Test-Path $p) { $crashDirs += $p }
        }
    }
    if ($crashDirs.Count -gt 0) {
        foreach ($cd in $crashDirs) {
            $dmp = @(Get-ChildItem $cd -Filter "*.dmp" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5)
            if ($dmp.Count -gt 0) {
                $Findings.ElectronCrashes = $true
                Check "Electron Chromium crash dumps" "FAIL" ("{0} dump(s) in {1}; newest @ {2}" -f $dmp.Count,$cd,$dmp[0].LastWriteTime)
            } else { Check "Electron Chromium crash dumps" "PASS" ("none in {0}" -f $cd) }
        }
    } else { Check "Electron Chromium crash dumps" "INFO" "no Crashpad dir (no crashes recorded, or app never launched)" }
}

# ------------ Detected deployment topology --------------------------------
# Prints the ONE thing the Intune team wants to see first: which install
# topology this device is actually using, cross-referenced with whether the
# device is even MDM-enrolled. Catches "Electron app on a company machine
# that should have been Intune-only" and "no PiFocus at all on a device
# that should have been assigned the Intune app".
$topo =
    if     ($Findings.AgentExe -and $Findings.ElectronAppInstalled) { "BOTH (Intune install + Electron app both present)" }
    elseif ($Findings.AgentExe)                                      { "Intune-only" }
    elseif ($Findings.ElectronAppInstalled)                          { "Electron-only" }
    else                                                             { "NONE - PiFocus is not installed on this device" }
$Findings.Topology = $topo
$expected = if ($Findings.IntuneEnrolled) { "Intune" } elseif ($Findings.PersonalDevice) { "Electron" } else { "either" }
$mismatch = ($Findings.IntuneEnrolled -and $topo -eq "Electron-only") -or ($Findings.PersonalDevice -and $topo -eq "Intune-only")
$st = if ($topo -like "NONE*") { "FAIL" } elseif ($topo -like "BOTH*" -or $mismatch) { "WARN" } else { "PASS" }
$note = if ($mismatch) { "  <-- MISMATCH: device enrollment expects $expected topology" } else { "" }
Check "Detected deployment topology" $st ($topo + $note)

#============================================================================ 2
Section "2. WINDOWS SERVICE ($ServiceName)"
$svc = $null
try { $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop } catch {}
$Findings.SvcRunning = $false
if (-not $svc) {
    Check "Service registered" "FAIL" "Not found - install did not create the service"
} else {
    Check "Service registered" "PASS" ("State={0}  StartMode={1}  Account={2}  PID={3}" -f $svc.State,$svc.StartMode,$svc.StartName,$svc.ProcessId)
    if ($svc.State -eq "Running") { $Findings.SvcRunning = $true; Check "Service running" "PASS" }
    else { Check "Service running" "FAIL" ("State={0}  ExitCode={1}" -f $svc.State,$svc.ExitCode) }
    if ($svc.StartMode -ne "Auto") { Check "Start type" "WARN" ("expected Auto, got {0}" -f $svc.StartMode) }
    if ($svc.PathName -notmatch "--service") { Check "ImagePath has --service" "WARN" $svc.PathName }
    else { Check "ImagePath" "INFO" $svc.PathName }

    # ZOMBIE-service detection - a common failure mode we've seen in the field:
    # an old Electron install created the service pointing at its per-user
    # binary, then the app was uninstalled but the uninstaller did NOT run
    # 'sc delete $ServiceName'. The service registration remains and
    # points at a deleted .exe. Every start attempt logs Event 7000, no data
    # flows, and everything else in the diagnose looks superficially OK.
    if ($svc.PathName -match '^\s*"([^"]+\.exe)"' -or $svc.PathName -match '^\s*(\S+\.exe)') {
        $svcExe = $matches[1]
        if ($svcExe -and -not (Test-Path $svcExe)) {
            $Findings.StaleImagePath = $true
            Check "Service binary on disk" "FAIL" ("$svcExe -- DELETED. The service registration is a ZOMBIE, points at a binary that no longer exists. This is why the service cannot start. FIX: 'sc.exe delete $ServiceName' as admin, then reinstall the current package (Intune install.ps1 or Electron app).")
        } elseif ($svcExe) {
            Check "Service binary on disk" "PASS" ("exists at $svcExe")
        }
    }
}

# restart-loop counters written by the service itself
try {
    $pf = Get-ItemProperty $HklmRoot -ErrorAction Stop
    if ($null -ne $pf.WS_FastRestartCount) {
        $rc = [int]$pf.WS_FastRestartCount
        $lastStart = if ($pf.WS_LastStartUnix) { (Get-Date "1970-01-01Z").AddSeconds([int]$pf.WS_LastStartUnix).ToLocalTime() } else { "?" }
        $Findings.RestartLoop = ($rc -ge 5)
        if ($rc -ge 5) { Check "Restart-loop counter" "FAIL" ("WS_FastRestartCount={0} (>=5 = crash loop) lastStart={1}" -f $rc,$lastStart) }
        elseif ($rc -gt 0) { Check "Restart-loop counter" "WARN" ("WS_FastRestartCount={0} lastStart={1}" -f $rc,$lastStart) }
        else { Check "Restart-loop counter" "PASS" ("0  lastStart={0}" -f $lastStart) }
    }
    if ($null -ne $pf.DisableCrashReporting) { Check "DisableCrashReporting flag" "INFO" $pf.DisableCrashReporting }
} catch {}

# SCM + Application Error events (last 3 days)
Line ""
Line "  -- Service Control Manager / crash events (last 3 days) --" "DarkGray"
$since = (Get-Date).AddDays(-3)
# SCM Win32-error decoder (used below for Event 7000)
$ScmWin32Decode = @{
    2    = "ERROR_FILE_NOT_FOUND -- ImagePath points to a deleted binary (zombie service)"
    3    = "ERROR_PATH_NOT_FOUND -- the folder containing the exe is gone"
    5    = "ERROR_ACCESS_DENIED -- LocalSystem cannot read/exec the binary (NTFS ACL, AV lock)"
    1053 = "ERROR_SERVICE_REQUEST_TIMEOUT -- process didn't report RUNNING in time"
    1056 = "ERROR_SERVICE_ALREADY_RUNNING"
    1058 = "ERROR_SERVICE_DISABLED"
    1067 = "ERROR_PROCESS_ABORTED -- process died (missing DLL / CRT skew / native crash)"
    1068 = "ERROR_SERVICE_DEPENDENCY_FAIL"
    1069 = "ERROR_SERVICE_LOGON_FAILED"
    1083 = "ERROR_SERVICE_NOT_IN_EXE -- StartServiceCtrlDispatcher never called"
}
try {
    $scm = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Service Control Manager'; StartTime=$since} -ErrorAction Stop |
           Where-Object { $_.Message -match $ServiceName -or $_.Message -match "PiFocus" } | Select-Object -First 12
    if ($scm) {
        foreach ($e in $scm) {
            # keep the full message (all non-empty lines joined) instead of truncating at the first newline
            $lines = @($e.Message -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $head  = if ($lines.Count -gt 0) { $lines[0] } else { "" }
            $tail  = if ($lines.Count -gt 1) { ($lines[1..($lines.Count-1)] -join "  |  ") } else { "" }
            Line ("    {0}  Id={1}  {2}" -f $e.TimeCreated, $e.Id, $head)
            if ($tail) { Line ("        {0}" -f $tail) "DarkGray" }
            # Event 7000 / 7024: Properties[1] is the Win32 error code (or, for 7024, the service-specific exit)
            if ($e.Id -in 7000,7024 -and $e.Properties.Count -ge 2) {
                $code = $null
                try { $code = [int]$e.Properties[1].Value } catch {}
                if ($code -and $ScmWin32Decode.ContainsKey($code)) {
                    Line ("        --> Win32 error {0}: {1}" -f $code, $ScmWin32Decode[$code]) "Yellow"
                    if ($code -eq 2) { $Findings.StaleImagePath = $true }
                    if ($code -eq 1067) { $Findings.CrashOnStart = $true }
                    if ($code -eq 5) { $Findings.AclBlock = $true }
                }
            }
        }
    } else { Line "    (no SCM events mention the service)" "DarkGray" }
} catch { Line "    (could not read System log: $($_.Exception.Message))" "DarkGray" }
$ExitDecode = @{
    "c0000005" = "ACCESS_VIOLATION (in-code crash, bad pointer)"
    "c0000094" = "INTEGER_DIVIDE_BY_ZERO"
    "c0000135" = "DLL_NOT_FOUND (missing import DLL - the classic 1067 cause)"
    "c0000139" = "ENTRYPOINT_NOT_FOUND (DLL version mismatch - imported function gone)"
    "c0000142" = "DLL_INIT_FAILED (a DLL's DllMain returned FALSE)"
    "c000007b" = "INVALID_IMAGE_FORMAT (architecture mismatch / corrupt PE)"
    "c0000374" = "HEAP_CORRUPTION"
    "c0000409" = "STACK_BUFFER_OVERRUN (/GS) - usually std::terminate"
    "c0000417" = "INVALID_CRUNTIME_PARAMETER"
    "c0150002" = "SXS_ACTIVATION_FAILED (manifest / SxS dependency)"
    "c00000fd" = "STACK_OVERFLOW"
}
try {
    $ae = Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$since; Id=1000,1001} -ErrorAction Stop |
          Where-Object { $_.Message -match "WindowService|HelperService|PiFocus" } | Select-Object -First 8
    if ($ae) {
        $Findings.AppCrash = $true
        foreach ($e in $ae) {
            $msg = ($e.Message -split "`n")[0].Trim()
            # find any matching exit code and tag it
            $tag = ""
            foreach ($code in $ExitDecode.Keys) {
                if ($e.Message -match $code) {
                    $tag = " [$code = $($ExitDecode[$code])]"
                    if ($code -eq "c0000135") { $Findings.DllLoadCrash = $true }
                    if ($code -eq "c000007b") { $Findings.ArchMismatch = $true }
                    if ($code -eq "c0000005") { $Findings.InCodeCrash = $true }
                    if ($code -eq "c0000139") { $Findings.DllEntryPointMissing = $true }
                    if ($code -eq "c0150002") { $Findings.SxsFail = $true }
                    break
                }
            }
            Line ("    {0}  Id={1}  {2}{3}" -f $e.TimeCreated,$e.Id,$msg,$tag) "Red"
        }
    } else { Line "    (no Application Error/WER events for PiFocus binaries)" "DarkGray" }
} catch {}

#============================================================================ 2b
Section "2b. SERVICE START FAILURE SAFETY NET (1067 / 1053 / load failures)"

# --- Decode the SCM-tracked ExitCode plainly ---
$WinErrMap = @{
    1053 = "ERROR_SERVICE_REQUEST_TIMEOUT - didn't report RUNNING within wait hint"
    1056 = "ERROR_SERVICE_ALREADY_RUNNING"
    1058 = "ERROR_SERVICE_DISABLED"
    1064 = "ERROR_EXCEPTION_IN_SERVICE"
    1066 = "ERROR_SERVICE_SPECIFIC_ERROR"
    1067 = "ERROR_PROCESS_ABORTED - process terminated unexpectedly (load-time DLL / native crash / std::terminate)"
    1068 = "ERROR_SERVICE_DEPENDENCY_FAIL"
    1069 = "ERROR_SERVICE_LOGON_FAILED (account / 'Log on as a service' right)"
    1075 = "ERROR_SERVICE_DEPENDENCY_DELETED"
    1077 = "ERROR_SERVICE_NEVER_STARTED (no attempt since boot - benign)"
    1083 = "ERROR_SERVICE_NOT_IN_EXE - StartServiceCtrlDispatcher never called (--service flag missing?)"
}
if ($svc) {
    $ec  = [int64]$svc.ExitCode
    $sse = [int64]$svc.ServiceSpecificExitCode
    if ($ec -ne 0 -and $ec -ne 1077) {
        $hex = "0x{0:X8}" -f $ec
        $decoded = if ($WinErrMap.ContainsKey([int]$ec)) { $WinErrMap[[int]$ec] } else { "<no decode>" }
        if ($ec -eq 1066 -and $sse -ne 0) { $decoded += (" -- service-specific code 0x{0:X}" -f $sse) }
        Check "Last service ExitCode (decoded)" "FAIL" ("{0} ({1}) - {2}" -f $ec,$hex,$decoded)
        if ($ec -eq 1067) { $Findings.ExitCode1067 = $true }
        if ($ec -eq 1083) { $Findings.MissingServiceFlag = $true }
    } else {
        Check "Last service ExitCode" "PASS" ("{0}" -f $ec)
    }
}

# --- Image File Execution Options (debugger / GFlags hijack) ---
foreach ($exeName in @("WindowService.exe","HelperService.exe")) {
    $imgKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exeName"
    if (Test-Path $imgKey) {
        try {
            $ifeo = Get-ItemProperty $imgKey -ErrorAction Stop
            $bad = @()
            if ($ifeo.Debugger)   { $bad += "Debugger='$($ifeo.Debugger)'" }
            if ($ifeo.GlobalFlag) { $bad += ("GlobalFlag=0x{0:X}" -f $ifeo.GlobalFlag) }
            if ($bad.Count -gt 0) { $Findings.IfeoHijack = $true; Check "IFEO key on $exeName" "FAIL" ($bad -join ", ") }
            else                  { Check "IFEO key on $exeName" "WARN" "key present but no debugger/GFlag" }
        } catch { Check "IFEO key on $exeName" "INFO" "key present but unreadable" }
    } else { Check "IFEO key on $exeName" "PASS" "absent" }
}

# --- PE header: confirm WindowService.exe is x64 (matches OS) ---
function Get-PEMachine { param($Path)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $peOff = $br.ReadInt32()
        $fs.Position = $peOff
        $sig = $br.ReadUInt32()                  # 0x00004550 = "PE\0\0"
        if ($sig -ne 0x4550) { $br.Close(); $fs.Close(); return "<not PE>" }
        $machine = $br.ReadUInt16()
        $br.Close(); $fs.Close()
        switch ($machine) {
            0x8664 { "x64" }
            0x014C { "x86" }
            0xAA64 { "ARM64" }
            default { "0x{0:X4}" -f $machine }
        }
    } catch { return "<read fail>" }
}
if ($Findings.AgentExe) {
    $mach   = Get-PEMachine $AgentExe
    $osArch = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).OSArchitecture
    $is64   = ($osArch -match "64")
    $ok     = ($mach -eq "x64" -and $is64) -or ($mach -eq "x86")   # x86 still runs on x64
    if (-not $ok) { $Findings.ArchMismatch = $true }
    $st = if ($ok) { "PASS" } else { "FAIL" }
    Check "WindowService.exe architecture" $st ("PE={0}, OS={1}" -f $mach,$osArch)
}

# --- Authenticode signature (WDAC / Code Integrity policies block unsigned) ---
if ($Findings.AgentExe) {
    try {
        $sig = Get-AuthenticodeSignature -FilePath $AgentExe -ErrorAction Stop
        $sub = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "<none>" }
        $st = switch ($sig.Status) { "Valid" {"PASS"} "NotSigned" {"WARN"} default {"WARN"} }
        Check "WindowService.exe signature" $st ("{0} | {1}" -f $sig.Status,$sub)
    } catch { Check "WindowService.exe signature" "INFO" $_.Exception.Message }
}

# --- ACL: SYSTEM must be able to Read+Execute the binary ---
if ($Findings.AgentExe) {
    try {
        $acl = Get-Acl -Path $AgentExe -ErrorAction Stop
        $sysAllow = $acl.Access | Where-Object {
            $_.IdentityReference -match "SYSTEM|S-1-5-18|BUILTIN\\Administrators|S-1-5-32-544" -and
            $_.AccessControlType -eq "Allow" -and
            ($_.FileSystemRights -match "FullControl|Modify|ReadAndExecute|Read")
        }
        if ($sysAllow) { Check "ACL grants SYSTEM read+execute" "PASS" }
        else { $Findings.AclBlock = $true; Check "ACL grants SYSTEM read+execute" "FAIL" "no Allow ACE for SYSTEM/Administrators - service start will hit access denied" }
    } catch { Check "ACL grants SYSTEM read+execute" "INFO" $_.Exception.Message }
}

# --- Defender threat history mentioning our binaries (AV quarantine cases) ---
try {
    if (Get-Command Get-MpThreatDetection -ErrorAction SilentlyContinue) {
        $threats = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.Resources -match "WindowService\.exe|HelperService\.exe|PiFocus|pi-focus-business" })
        if ($threats.Count -gt 0) {
            $Findings.DefenderQuarantine = $true
            $last = $threats | Sort-Object InitialDetectionTime -Descending | Select-Object -First 1
            Check "Defender threats vs PiFocus binaries" "FAIL" ("{0} detection(s); last @ {1}" -f $threats.Count,$last.InitialDetectionTime)
        } else { Check "Defender threats vs PiFocus binaries" "PASS" "none" }
    } else { Check "Defender threats vs PiFocus binaries" "INFO" "Get-MpThreatDetection not available (no Defender PS module)" }
} catch { Check "Defender threats vs PiFocus binaries" "INFO" $_.Exception.Message }

# --- ASR rule count (block-mode rules can stop launches) ---
try {
    $mp = Get-MpPreference -ErrorAction Stop
    if ($mp.AttackSurfaceReductionRules_Ids) {
        $cnt = ($mp.AttackSurfaceReductionRules_Ids | Measure-Object).Count
        Check "ASR rules configured" "INFO" ("$cnt rule(s) - if a Block rule fires, check Event log 'Microsoft-Windows-Windows Defender/Operational'")
    } else { Check "ASR rules configured" "PASS" "none" }
} catch {}

# --- Service dependencies (1068 cause) ---
if ($svc -and $svc.PSObject.Properties['Name'] -and $svc.PathName) {
    try {
        $dep = (Get-Service $ServiceName -ErrorAction Stop).ServicesDependedOn
        if ($dep -and $dep.Count -gt 0) {
            $unhealthy = @($dep | Where-Object { $_.Status -ne "Running" })
            if ($unhealthy.Count -gt 0) {
                $Findings.DepFail = $true
                Check "Service dependencies" "FAIL" ("not running: " + (($unhealthy | ForEach-Object { $_.Name }) -join ", "))
            } else { Check "Service dependencies" "PASS" (($dep | ForEach-Object { $_.Name }) -join ", ") }
        } else { Check "Service dependencies" "PASS" "none" }
    } catch { Check "Service dependencies" "INFO" $_.Exception.Message }
}

#============================================================================ 2c
Section "2c. WINDOWS ERROR REPORTING (WER) crashes for PiFocus binaries"
# WER records every native crash by LocalSystem services into ProgramData\...\WER\.
# This is gold when debugLogs is missing (== service crashed before our logger
# could even init - e.g. CRT version skew or a static initializer).
$WerRoots = @(
    "C:\ProgramData\Microsoft\Windows\WER\ReportQueue",
    "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
)
function Read-WerReport { param($Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $offset = 0
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $offset = 2 }
        $text = [System.Text.Encoding]::Unicode.GetString($bytes, $offset, $bytes.Length - $offset)
        $h = @{}
        foreach ($ln in ($text -split "[`r`n]+")) {
            if ($ln -match "^([^=]+)=(.*)$") { $h[$matches[1].Trim()] = $matches[2].Trim() }
        }
        # Build a Sig.Name -> Sig.Value lookup. The Sig[N] INDEX is not stable
        # across Windows builds, but the Name strings are - so we look up by
        # name (e.g. "Exception Code") and avoid the swapped-output bug.
        $byName = @{}
        for ($i = 0; $i -lt 40; $i++) {
            $nk = "Sig[$i].Name"; $vk = "Sig[$i].Value"
            if ($h.ContainsKey($nk) -and $h.ContainsKey($vk)) { $byName[$h[$nk]] = $h[$vk] }
        }
        return @{ Raw = $h; ByName = $byName }
    } catch { return $null }
}

$werHits = @()
foreach ($root in $WerRoots) {
    if (-not (Test-Path $root)) { continue }
    foreach ($pat in @("AppCrash_WindowService*","AppCrash_HelperService*")) {
        $dirs = @(Get-ChildItem $root -Filter $pat -Directory -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) {
            $wer = Get-ChildItem $d.FullName -Filter "*.wer" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $wer) { continue }
            $r = Read-WerReport $wer.FullName
            if ($r) {
                $bn = $r.ByName
                $werHits += [PSCustomObject]@{
                    Mtime    = $wer.LastWriteTime
                    App      = $bn["Application Name"]
                    AppVer   = $bn["Application Version"]
                    FaultMod = $bn["Fault Module Name"]
                    FaultVer = $bn["Fault Module Version"]
                    ExCode   = $bn["Exception Code"]
                    ExOff    = $bn["Exception Offset"]
                    Path     = $d.FullName
                }
            }
        }
    }
}

if ($werHits.Count -eq 0) {
    Check "WER reports for PiFocus binaries" "PASS" "none in ReportQueue/ReportArchive"
} else {
    $Findings.WerCrashCount = $werHits.Count
    Check "WER crash reports found" "FAIL" ("{0} report(s) for PiFocus binaries - service has been dying at the CRT/loader level" -f $werHits.Count)

    # Group by fault signature (same module+version+code+offset = same crash)
    $groups = $werHits | Group-Object FaultMod,FaultVer,ExCode,ExOff | Sort-Object Count -Descending
    Line ""
    Line "  -- Top crash signatures (most-recent timestamp shown) --" "DarkGray"
    foreach ($g in ($groups | Select-Object -First 5)) {
        $first   = $g.Group[0]
        $newest  = ($g.Group | Sort-Object Mtime -Descending)[0].Mtime
        Line ("    [{0}x] App={1} v{2}  ->  Fault: {3} v{4}  (Code=0x{5}  Offset=0x{6})  newest={7}" -f $g.Count,$first.App,$first.AppVer,$first.FaultMod,$first.FaultVer,$first.ExCode,$first.ExOff,$newest) "Red"

        # SMOKING-GUN detector: faulting module is the CRT and it's < 14.30 -> redist mismatch
        if ($first.FaultMod -match "MSVCP140\.dll|VCRUNTIME140\.dll|VCRUNTIME140_1\.dll") {
            $faultNum = 0
            if ($first.FaultVer -match "^(\d+)\.(\d+)") { $faultNum = [int]$matches[1] * 100 + [int]$matches[2] }
            if ($faultNum -gt 0 -and $faultNum -lt 1430) {
                $Findings.WerCrtMismatch = $true
                Line ("        ^^ SMOKING GUN: fault is INSIDE a CRT DLL older than 14.30 - VC++ runtime SKEW. The new build's bundled CRT trio fixes this; OR install the latest vc_redist.x64.exe.") "Red"
            } elseif ($first.ExCode -eq "c0000005") {
                Line ("        Note: ACCESS_VIOLATION inside a CRT DLL even at a modern version usually still means CRT version skew (mixed bundled vs system) - check that ALL THREE of msvcp140 / vcruntime140 / vcruntime140_1 come from the same toolset.") "Yellow"
            }
        } elseif ($first.FaultMod -match "sentry\.dll|crashpad") {
            Line ("        Note: fault is inside sentry/crashpad - matches the init-crash-reporter phase issue.") "Yellow"
        }
    }
}

#============================================================================ 3
Section "3. HELPER PROCESS (must run in the user's session, not 0)"
$helpers = @(Get-Process -Name "HelperService" -ErrorAction SilentlyContinue)
$Findings.HelperInUserSession = $false
if ($helpers.Count -eq 0) {
    Check "HelperService.exe running" "FAIL" "no HelperService process found"
} else {
    foreach ($h in $helpers) {
        $inUser = ($null -ne $ConsoleSession -and $h.SessionId -eq $ConsoleSession)
        if ($inUser) { $Findings.HelperInUserSession = $true }
        $st = if ($h.SessionId -eq 0) { "WARN" } elseif ($inUser) { "PASS" } else { "WARN" }
        Check ("HelperService PID {0}" -f $h.Id) $st ("session={0}{1}" -f $h.SessionId, $(if($h.SessionId -eq 0){" (SESSION 0 - cannot see the user's desktop)"}elseif($inUser){" (active user session)"}else{" (not the active session)"}))
    }
    if (-not $Findings.HelperInUserSession) { Check "Helper in active user session" "FAIL" "helper is not in the logged-in user's session -> no window/activity capture" }
}

#============================================================================ 4
Section ("4. DEVICE TOKEN / AUTH  (HKCU\{0}\DeviceApiKey)" -f $HkcuHelper)
$token = $null
$tokenSrc = $null
$tokenBinary = $false
if ($ConsoleSid) {
    try {
        $p = Get-ItemProperty ("Registry::HKEY_USERS\{0}\{1}" -f $ConsoleSid, $HkcuHelper) -ErrorAction Stop
        if ($p.DeviceApiKey) { $tokenBinary = ($p.DeviceApiKey -is [byte[]]); $token = [string]$p.DeviceApiKey; $tokenSrc = ("HKU\{0}\{1}" -f $ConsoleSid, $HkcuHelper) }
    } catch {}
}
if (-not $token) {
    try {
        $p = Get-ItemProperty ("HKCU:\{0}" -f $HkcuHelper) -ErrorAction Stop
        if ($p.DeviceApiKey) { $tokenBinary = ($p.DeviceApiKey -is [byte[]]); $token = [string]$p.DeviceApiKey; $tokenSrc = ("HKCU\{0}" -f $HkcuHelper) }
    } catch {}
}
$Findings.TokenPresent = [bool]$token
if ($token) {
    if ($tokenBinary) {
        # F-01: token stored as REG_BINARY (DPAPI-encrypted at rest). At rest it is an
        # opaque blob (the decrypted value is apiKeyId.secret); a '.' check on the raw
        # bytes is meaningless, so do NOT flag "malformed". See F-01 block for length.
        Check "Device token present" "PASS" ("REG_BINARY / DPAPI-encrypted at rest (F-01)  [{0}]" -f $tokenSrc)
    } else {
        $looksJwt = $token.Contains(".")
        Check "Device token present" "PASS" ("{0}  [{1}]" -f (Mask $token),$tokenSrc)
        if (-not $looksJwt) { Check "Token format" "WARN" "plaintext (REG_SZ) with no '.' separator - may be malformed (expected apiKeyId.secret)" }
    }
} else {
    Check "Device token present" "FAIL" "DeviceApiKey not set -> uploads will be unauthenticated. User likely has NOT logged into the PiFocus desktop app."
}

#============================================================================ 5
Section "5. TRACKING / PAUSE STATE"
$trackVal = $null
try { $pf2 = Get-ItemProperty $HklmRoot -ErrorAction Stop; $trackVal = $pf2.TrackingEnabled } catch {}
$Findings.Paused = $false
if ($null -eq $trackVal) { Check "HKLM TrackingEnabled" "INFO" "not set (defaults to ENABLED)" }
elseif ([int]$trackVal -eq 1) { Check "HKLM TrackingEnabled" "PASS" "1 = tracking ENABLED" }
else { $Findings.Paused = $true; Check "HKLM TrackingEnabled" "FAIL" "0 = tracking PAUSED -> no data will be collected" }

# best-effort: read the live pause event (signaled = paused)
try {
    if (-not ("PiFocusEvt" -as [type])) {
        Add-Type -Namespace PiFocus -Name Evt -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr OpenEvent(uint dwDesiredAccess, bool bInheritHandle, string lpName);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint WaitForSingleObject(System.IntPtr hHandle, uint dwMilliseconds);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool CloseHandle(System.IntPtr hObject);
"@ -ErrorAction Stop
    }
    $h = [PiFocus.Evt]::OpenEvent(0x00100000, $false, $PauseEvent)  # SYNCHRONIZE
    if ($h -ne [IntPtr]::Zero) {
        $w = [PiFocus.Evt]::WaitForSingleObject($h, 0)   # 0 = signaled (paused), 258 = non-signaled (active)
        [void][PiFocus.Evt]::CloseHandle($h)
        if ($w -eq 0) { $Findings.Paused = $true; Check "Live pause event" "FAIL" "Global\PiFocusPauseEvent is SIGNALED = tracking PAUSED right now" }
        else { Check "Live pause event" "PASS" "not signaled = tracking active" }
    } else { Check "Live pause event" "INFO" "event not present (service may not be running)" }
} catch { Check "Live pause event" "INFO" "could not query ($($_.Exception.Message))" }

#============================================================================ 6
Section "6. BACKEND CONNECTIVITY ($BackendHost)"
$dnsOk=$false; $tcpOk=$false; $httpsOk=$false
try { $ips = [System.Net.Dns]::GetHostAddresses($BackendHost); if ($ips) { $dnsOk=$true; Check "DNS resolve" "PASS" (($ips | ForEach-Object { $_.IPAddressToString }) -join ", ") } }
catch { Check "DNS resolve" "FAIL" $_.Exception.Message }
if ($dnsOk) {
    $tcpOk = Test-Tcp $BackendHost 443
    if ($tcpOk) { Check "TCP 443 reachable" "PASS" } else { Check "TCP 443 reachable" "FAIL" "blocked by firewall/network" }
}
if ($tcpOk) {
    try {
        $resp = Invoke-WebRequest -Uri ("https://{0}" -f $BackendHost) -Method Head -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop
        $httpsOk=$true; Check "HTTPS/TLS handshake" "PASS" ("HTTP {0}" -f [int]$resp.StatusCode)
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $httpsOk=$true; Check "HTTPS/TLS handshake" "PASS" ("server responded HTTP {0} (reachable)" -f [int]$_.Exception.Response.StatusCode) }
        else { Check "HTTPS/TLS handshake" "FAIL" $_.Exception.Message }
    } catch { Check "HTTPS/TLS handshake" "WARN" $_.Exception.Message }
}
$Findings.BackendReachable = $httpsOk
# Services use WinHTTP, whose proxy is SEPARATE from IE/WinINET
try {
    $p = (netsh winhttp show proxy) 2>$null
    $pl = ($p | Where-Object { $_ -match "Proxy Server|Direct access|Proxy" } | Select-Object -First 3) -join " | "
    if ($p -match "Direct access") { Check "WinHTTP proxy" "PASS" "Direct access (no proxy)" }
    else { Check "WinHTTP proxy" "INFO" $pl }
} catch {}

#============================================================================ 7
Section "7. RUNTIME LOGS  ($DebugLogDir)"
$script:Notable = New-Object System.Collections.Generic.List[string]
if (-not (Test-Path $DebugLogDir)) {
    Check "debugLogs folder" "FAIL" "$DebugLogDir missing -> services have never run / wrong data path"
} else {
    foreach ($svcName in @("WindowService","HelperService")) {
        $files = @(Get-ChildItem $DebugLogDir -Filter "*-$svcName.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2)
        if ($files.Count -eq 0) { Check "$svcName log" "WARN" "no log files (service may have never started)"; continue }
        $newest = $files[0]
        $ageHrs = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalHours,1)
        $fresh = if ($ageHrs -le 24) { "PASS" } else { "WARN" }
        Check "$svcName log freshness" $fresh ("newest={0}  ({1}h ago)" -f $newest.Name,$ageHrs)

        $events = New-Object System.Collections.Generic.List[object]
        foreach ($f in $files) { foreach ($o in (Read-NdjsonTail $f.FullName 5000)) { $events.Add($o) } }

        $errs = @($events | Where-Object { $_.level -eq "ERROR" -or $_.level -eq "CRASH" })
        Line ("    {0}: parsed {1} events, {2} ERROR/CRASH" -f $svcName,$events.Count,$errs.Count) "DarkGray"

        # latest crash
        $crash = $events | Where-Object { $_.category -eq "crash.fatal" } | Select-Object -Last 1
        if ($crash) {
            $Findings.CrashFatal = $true
            $d = $crash.data
            Line ("    CRASH.FATAL @ {0}: {1} in {2} (phase={3})" -f $crash.ts, $d.exceptionName, $d.faultModule, $d.phase) "Red"
        }
        # restart-loop / running lifecycle
        $rl = $events | Where-Object { $_.category -eq "service.lifecycle" -and $_.message -match "restart loop|1053|WITHOUT a stop" } | Select-Object -Last 1
        if ($rl) { Line ("    LIFECYCLE @ {0}: {1}" -f $rl.ts,$rl.message) "Yellow" }

        # show last few ERROR/CRASH
        foreach ($e in ($errs | Select-Object -Last 6)) {
            Line ("    [{0}] {1} | {2} | {3}" -f $e.level,$e.ts,$e.category,$e.message) "DarkYellow"
        }

        # tally intermittent/historical signatures so they are visible even
        # when the CURRENT snapshot is healthy
        $cf = @($events | Where-Object { $_.category -eq "crash.fatal" })
        if ($cf.Count -gt 0) { $script:Notable.Add(("{0}: {1} native crash(es); last @ {2} ({3})" -f $svcName,$cf.Count,$cf[-1].ts,$cf[-1].data.exceptionName)) }
        $tw = @($events | Where-Object { ($_.category -eq "token.registry_write" -or $_.category -eq "token.write") -and ($_.level -eq "ERROR") })
        if ($tw.Count -gt 0) { $script:Notable.Add(("{0}: {1} token-write failure(s); last @ {2} ('{3}')" -f $svcName,$tw.Count,$tw[-1].ts,$tw[-1].message)) }
        $emptySid = @($events | Where-Object { $_.message -match "empty SID" -or $_.message -match "WTSQueryUserToken failed" })
        if ($emptySid.Count -gt 0) { $script:Notable.Add(("{0}: {1} 'no active user session' event(s) (WTSQueryUserToken/empty SID) - token cannot be written while no one is logged on" -f $svcName,$emptySid.Count)) }
        $ws = @($events | Where-Object { $_.category -match "^websocket" -and $_.level -ne "INFO" })
        if ($ws.Count -gt 0) { $script:Notable.Add(("{0}: {1} websocket disconnect/fail event(s)" -f $svcName,$ws.Count)) }
        $pf = @($events | Where-Object { $_.category -eq "pipe.fail" -or $_.category -eq "pipe.request_fail" -or $_.category -eq "pipe.data_fail" })
        if ($pf.Count -gt 0) { $script:Notable.Add(("{0}: {1} named-pipe failure(s) (service<->helper IPC)" -f $svcName,$pf.Count)) }
    }

    # --- THE money question: was data actually uploaded? ---
    Line ""
    Line "  -- Activity upload status (api -> /agent/ingest/activities) --" "DarkGray"
    $hsFiles = @(Get-ChildItem $DebugLogDir -Filter "*-HelperService.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2)
    $apiEvents = New-Object System.Collections.Generic.List[object]
    foreach ($f in $hsFiles) { foreach ($o in (Read-NdjsonTail $f.FullName 6000)) { if ($o.category -eq "api" -or $o.category -eq "api.transport_fail") { $apiEvents.Add($o) } } }
    $uploads = @($apiEvents | Where-Object { $_.endpoint -match $ActivitiesEP -or $_.message -match $ActivitiesEP })
    $transportFails = @($apiEvents | Where-Object { $_.category -eq "api.transport_fail" })
    if ($uploads.Count -gt 0) {
        $last = $uploads | Select-Object -Last 1
        $code = $last.statusCode
        $st = if ($code -ge 200 -and $code -lt 300) { "PASS" } elseif ($code -eq 401 -or $code -eq 403) { "FAIL" } else { "WARN" }
        $Findings.LastUploadCode = [int]$code
        Check "Last activities upload" $st ("HTTP {0} @ {1}" -f $code,$last.ts)
        if ($code -eq 401 -or $code -eq 403) { $Findings.AuthRejected = $true }
        if ($code -ge 500) { $Findings.BackendError = $true }
    } else {
        Check "Last activities upload" "WARN" "no upload attempts found in recent helper logs"
    }
    if ($transportFails.Count -gt 0) {
        $Findings.TransportFail = $true
        $tf = $transportFails | Select-Object -Last 1
        Check "Network transport failures" "FAIL" ("{0} fails; last @ {1} win32={2}" -f $transportFails.Count,$tf.ts,$tf.data.win32)
    }

    # --- Token provisioning (WindowService machine-key) -- WHY the token is missing ---
    # On a company (Intune) device there is NO desktop-app login, so the device
    # token arrives ONLY via WindowService: GET /user-devices/<id>/machine-key, then
    # WindowService DPAPI-encrypts it into HKU\<active-user-SID>\Software\PiFocus\Helper.
    # Three independent failure points, each surfaced from the WindowService log:
    #   (1) identity resolved to MachineGuid/Unknown -- BIOS + EntDMID both failed  [serial.result]
    #   (2) the machine-key GET itself failed                                       [token.fetch ERROR]
    #   (3) the GET succeeded but the token could NOT be persisted (no active user  [token.registry_write / token.sid]
    #       session / DPAPI) -- "fetched but not written".
    Line ""
    Line "  -- Token provisioning (WindowService machine-key) --" "DarkGray"
    # These are read from the WindowService LOG (a rolling history), so any error here may
    # be OLD. Section 4 already read the LIVE registry into $Findings.TokenPresent. If a
    # token IS present now, historical fetch/write/check errors are reframed as HISTORICAL
    # (INFO) instead of FAIL, so the report never contradicts itself (token present in
    # section 4 but "NOT present" here). If NO token is present, they stay as the FAIL.
    $tokLiveOk = [bool]$Findings.TokenPresent
    $wfTok = @(Get-ChildItem $DebugLogDir -Filter "*-WindowService.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2)
    $wvTok = New-Object System.Collections.Generic.List[object]
    foreach ($f in $wfTok) { foreach ($o in (Read-NdjsonTail $f.FullName 6000)) { $wvTok.Add($o) } }

    # (1) identity the agent ACTUALLY resolved at runtime (serial.result: BIOS/EntDMID/MachineGuid/Unknown)
    $serRes = $wvTok | Where-Object { $_.category -eq 'serial.result' } | Select-Object -Last 1
    if ($serRes) {
        $src = "$($serRes.data.source)"
        $Findings.AgentIdSource = $src
        $Findings.IdentityIsMachineGuid = ($src -eq 'MachineGuid')
        $sSt = if ($src -eq 'MachineGuid' -or [string]::IsNullOrWhiteSpace($src)) { 'WARN' } else { 'INFO' }
        Check "Agent resolved identity (runtime)" $sSt ("source={0}  value={1}{2}" -f $src,$serRes.data.value,$(if ($src -eq 'MachineGuid') { "  <-- BIOS + EntDMID both failed; backend maps by EntDMID so MachineGuid will NOT match" } else { "" }))
    }

    # (2) machine-key GET outcome (token.fetch ERROR)
    $tokFetchErr = @($wvTok | Where-Object { $_.category -eq 'token.fetch' -and $_.level -eq 'ERROR' })
    if ($tokFetchErr.Count -gt 0) {
        $Findings.MachineKeyFailed = $true
        $ltf = $tokFetchErr | Select-Object -Last 1
        $mkKind =
            if     ($ltf.message -match 'JSON parse')                   { $Findings.MkJsonFail = $true;  'backend returned NON-JSON (device not found / not mapped, or server error)' }
            elseif ($ltf.message -match 'HTTP send|send/receive')       { $Findings.MkHttpFail = $true;  'HTTP send/receive failed (network / proxy / TLS on this device)' }
            elseif ($ltf.message -match 'Empty response')               { $Findings.MkEmpty = $true;     'empty response body from machine-key' }
            elseif ($ltf.message -match 'placeholder|bad.?serial|Refus') { $Findings.MkBadSerial = $true; 'refused: placeholder serial AND EntDMID fallback failed' }
            else                                                         { "$($ltf.message)" }
        if ($tokLiveOk) {
            Check "machine-key GET (token.fetch)" "INFO" ("{0} earlier failure(s); last @ {1} -> {2}  (HISTORICAL - a token IS present now, see section 4)" -f $tokFetchErr.Count,$ltf.ts,$mkKind)
        } else {
            Check "machine-key GET (token.fetch)" "FAIL" ("{0} failure(s); last @ {1} -> {2}" -f $tokFetchErr.Count,$ltf.ts,$mkKind)
        }
    } else {
        Check "machine-key GET (token.fetch)" "INFO" "no token.fetch errors in recent WindowService log"
    }

    # (3) token WRITE outcome -- GET may have succeeded but persist failed (no active session / DPAPI)
    $tokWriteErr = @($wvTok | Where-Object { ($_.category -eq 'token.registry_write' -or $_.category -eq 'token.sid') -and $_.level -eq 'ERROR' })
    if ($tokWriteErr.Count -gt 0) {
        $lw = $tokWriteErr | Select-Object -Last 1
        if ($lw.message -match 'empty SID|no active console|CryptProtectData|impersonat') { $Findings.TokenWriteNoSession = $true }
        if ($tokLiveOk) {
            Check "machine-key token WRITE" "INFO" ("{0} earlier write issue(s); last: {1}  (HISTORICAL - token IS persisted now, see section 4)" -f $tokWriteErr.Count,$lw.message)
        } else {
            Check "machine-key token WRITE" "WARN" ("{0} write issue(s); last: {1} -> token NOT persisted (WindowService needs an active console user session to DPAPI-seal it)" -f $tokWriteErr.Count,$lw.message)
        }
    }

    # WindowService's own present/absent verdict (token.check). This comes from the LOG, so
    # it can be stale. Reconcile against the LIVE registry read in section 4: if the token
    # is present now but an older log line said "NOT present", surface it as HISTORICAL,
    # never as a FAIL that contradicts section 4.
    $tokChk = $wvTok | Where-Object { $_.category -eq 'token.check' } | Select-Object -Last 1
    if ($tokChk) {
        $logSaysAbsent = ($tokChk.message -match 'NOT present')
        if ($tokLiveOk -and $logSaysAbsent) {
            Check "WindowService token-registry check" "INFO" ("last LOG verdict (@{0}): '{1}' - HISTORICAL; the token IS present in the live registry now (see section 4)" -f $tokChk.ts,$tokChk.message)
        } else {
            Check "WindowService token-registry check" $(if ($logSaysAbsent) { 'FAIL' } else { 'PASS' }) ("{0}" -f $tokChk.message)
        }
    }
}

# daily_reports = locally produced data
Section "7b. LOCAL DATA (daily_reports)"
if (-not (Test-Path $ReportsDir)) { Check "daily_reports folder" "WARN" "$ReportsDir missing - no local data produced yet" }
else {
    $allRep = @(Get-ChildItem $ReportsDir -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($allRep.Count -eq 0) { Check "daily_reports content" "WARN" "no report files - tracking likely not running" }
    else {
        $r = $allRep[0]
        $Findings.LocalDataExists = ($r.Length -gt 50)
        $st = if ($r.Length -gt 50) { "PASS" } else { "WARN" }
        Check "Latest daily report" $st ("{0}  size={1}B  modified={2}" -f $r.Name,$r.Length,$r.LastWriteTime)

        # Gap detection: which of the last 14 calendar days have NO report file?
        # Reports are named "YYYY-MM-DD.json". Weekends/leave are fine, but a
        # missing weekday between two present days = service crashed that day.
        $havingSet = @{}
        foreach ($f in $allRep) { $havingSet[$f.Name] = $true }
        $today = Get-Date
        $missing = @()
        for ($i = 0; $i -lt 14; $i++) {
            $d = $today.AddDays(-$i).ToString("yyyy-MM-dd")
            if (-not $havingSet.ContainsKey("$d.json")) { $missing += $d }
        }
        if ($missing.Count -eq 0) {
            Check "Report continuity (last 14 days)" "PASS" "no gaps"
        } else {
            # weekends are expected; call out only if a gap looks like a weekday
            $weekdayGaps = @($missing | Where-Object {
                $dow = [DateTime]::Parse($_).DayOfWeek
                $dow -ne 'Saturday' -and $dow -ne 'Sunday'
            })
            $st = if ($weekdayGaps.Count -gt 0) { "WARN" } else { "INFO" }
            $note = if ($weekdayGaps.Count -gt 0) { "  (weekday gaps in bold: " + ($weekdayGaps -join ", ") + ")" } else { "  (weekend/holiday only)" }
            Check "Report continuity (last 14 days)" $st ("missing: {0}{1}" -f ($missing -join ", "),$note)
        }
    }
}

# install log tail
if (Test-Path $InstallLog) {
    Section "7c. INSTALL LOG (tail)"
    # Tail 80 (up from 25) because the 1.0.5+ install.ps1 writes a much
    # longer per-install block: PACKAGE INVENTORY (~10 lines) + freshness
    # checks + Copy-ItemVerified per-file rows + POST-INSTALL VERIFICATION
    # + VERDICT banner. Tail 25 would truncate everything before the final
    # verdict and we'd lose the copy evidence.
    foreach ($ln in (Get-Content $InstallLog -Tail 80 -ErrorAction SilentlyContinue)) {
        $c = if ($ln -match "\[ERROR\]") { "Red" } else { "DarkGray" }
        Line ("    $ln") $c
    }

    # Install-script generation check: 1.0.5+ install.ps1 always writes a
    # "VERDICT env=... version=... Helper_fresh=... Window_fresh=..." line
    # as its final action. If that line is ABSENT from the entire log, IT
    # is still deploying the pre-1.0.5 .intunewin and the new safeguards
    # (source marker preflight, Copy-ItemVerified, post-install marker
    # check, verdict banner) never ran on this device. This is the exact
    # failure mode that left Drashti / Jahanvi with a stale June-3 Helper.
    $verdictLines = @(Get-Content $InstallLog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'VERDICT env=' })
    if ($verdictLines.Count -gt 0) {
        $Findings.NewInstallScriptRan = $true
        $latest = $verdictLines[-1]
        Check "New install script generation (1.0.5+)" "PASS" ("saw: " + $latest.Trim())
        # If any verdict shows Helper_fresh=False, that means the marker
        # check tripped -- stale binary somehow reached the device.
        if ($latest -match 'Helper_fresh=False|Window_fresh=False') {
            $Findings.StaleBinaryOnDevice = $true
            Check "Post-install marker verification" "FAIL" "install.ps1 detected a STALE binary on disk. See PACKAGE INVENTORY lines above."
        }
    } else {
        $Findings.OldInstallScriptStillDeployed = $true
        Check "New install script generation (1.0.5+)" "FAIL" "no 'VERDICT env=' line anywhere in Install.log -- IT is still deploying the pre-1.0.5 .intunewin. New marker-safeguards never ran on this device. FIX: IT must upload the new install.intunewin (version 1.0.5) to Intune, replacing the currently-deployed package."
    }
}

# Intune Management Extension log - the gold standard for "did Intune try to
# push PiFocus to this device, and if so what happened?" Only relevant on
# MDM-enrolled devices; ignored on personal ones.
if ($Findings.IntuneEnrolled) {
    $imeLogDir = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
    if (Test-Path $imeLogDir) {
        $imeLogs = @(Get-ChildItem $imeLogDir -Filter "IntuneManagementExtension*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)
        if ($imeLogs.Count -gt 0) {
            Section "7c2. INTUNE MANAGEMENT EXTENSION LOG (PiFocus mentions)"
            $piLines = @()
            foreach ($log in $imeLogs) {
                try {
                    $lines = Get-Content $log.FullName -Tail 5000 -ErrorAction SilentlyContinue
                    $piLines += ($lines | Where-Object { $_ -match "PiFocus|piFocus|pi-focus" })
                } catch {}
            }
            if ($piLines.Count -gt 0) {
                Line ("    {0} PiFocus-mentioning lines across the last {1} IME log file(s)" -f $piLines.Count,$imeLogs.Count) "DarkGray"
                # Show the last 20 lines - if the install failed, the error is here
                foreach ($ln in ($piLines | Select-Object -Last 20)) {
                    $short = if ($ln.Length -gt 280) { $ln.Substring(0,280) + "..." } else { $ln }
                    $c = if ($ln -match "\bError\b|Failed|Failure|0x[0-9a-fA-F]{8}") { "Red" }
                         elseif ($ln -match "\bSuccess\b|Installed successfully|Detection succeeded") { "Green" }
                         else { "DarkGray" }
                    Line ("    $short") $c
                }
                # count outcomes
                $errCount  = @($piLines | Where-Object { $_ -match "\bError\b|Failed|Failure" }).Count
                $succCount = @($piLines | Where-Object { $_ -match "Installed successfully|Detection succeeded|installation successful" }).Count
                if ($errCount -gt 0)  { $Findings.IntuneInstallFailed = $true; Check "Intune IME: PiFocus install errors" "FAIL" ("$errCount error-line(s) in IME log - Intune tried to install PiFocus and it failed. See lines above.") }
                if ($succCount -gt 0) { Check "Intune IME: PiFocus install successes" "PASS" ("$succCount success-line(s) - Intune has installed PiFocus at some point on this device") }
            } else {
                Check "Intune IME: PiFocus mentions" "WARN" "no PiFocus mentions in the last 3 IME log files. Either this device is not in the PiFocus assignment group, OR the assignment reached it before these log files were rotated in. Check MEM console for this device's app assignment status."
            }
        }
    }
}

# Electron app log - catches the OTHER install path:
# user cancelled UAC, wmic missing, service install failure, multi-instance loop.
if ($ElectronAppLog -and (Test-Path $ElectronAppLog)) {
    Section "7d. ELECTRON APP LOG  ($ElectronAppLog)"
    $tail = Get-Content $ElectronAppLog -Tail 400 -ErrorAction SilentlyContinue

    # signature counts
    $sigUac      = @($tail | Where-Object { $_ -match "User did not grant permission" })
    $sigInstFail = @($tail | Where-Object { $_ -match "installService failed|Service installation failed|failed to initialize background services" })
    $sigWmic     = @($tail | Where-Object { $_ -match "'wmic' is not recognized" })
    $sigNoSerial = @($tail | Where-Object { $_ -match "Failed to get serial number|No serial number found" })
    $sigMulti    = @($tail | Where-Object { $_ -match "Got single instance lock: false|Another instance is running" })
    $sigNoSvc    = @($tail | Where-Object { $_ -match "service state.*exists: false" })
    $sigDailyMiss= @($tail | Where-Object { $_ -match "\[dailyReport\] File does not exist" })
    $sigAsarFail = @($tail | Where-Object { $_ -match "ERR_FAILED.*app\.asar|Failed to load URL.*app\.asar" })
    $sigOauth    = @($tail | Where-Object { $_ -match "accounts\.google\.com|Google OAuth|OAuth flow|webContents" })
    $sigNoRefresh= @($tail | Where-Object { $_ -match "No refresh token available" })
    $sigEperm    = @($tail | Where-Object { $_ -match "operation not permitted, copyfile|EPERM.*copyfile|helper install failed" })
    $sigVersion  = $tail | Where-Object { $_ -match "\[App\] Electron version|pi-focus-business-app/" } | Select-Object -First 1
    $sigVersion  = [string]$sigVersion

    if ($sigVersion)              {                                          Check "Electron: app version line" "INFO" ($sigVersion.Substring(0,[Math]::Min(160,$sigVersion.Length))) }
    if ($sigUac.Count -gt 0)      { $Findings.UacCancelled = $true;          Check "Electron: UAC elevation cancelled by user" "FAIL" ("seen {0}x in tail - service was never installed" -f $sigUac.Count) }
    if ($sigInstFail.Count -gt 0) { $Findings.ElectronInstallFailed = $true; Check "Electron: service install failed" "FAIL" ("seen {0}x" -f $sigInstFail.Count) }
    if ($sigWmic.Count -gt 0)     { $Findings.WmicMissing = $true;           Check "Electron: 'wmic' not recognized" "WARN" "Win11 24H2+ removes wmic - device serial number cannot be read, backend cannot identify this device" }
    if ($sigNoSerial.Count -gt 0) {                                          Check "Electron: serial number not obtained" "WARN" ("seen {0}x" -f $sigNoSerial.Count) }
    if ($sigAsarFail.Count -gt 0) { $Findings.AsarLoadFail = $true;          Check "Electron: asar load failed (ERR_FAILED)" "FAIL" ("seen {0}x - app.asar could not be loaded by the renderer. Most likely Defender/AV quarantined it, or the install is corrupted." -f $sigAsarFail.Count) }
    if ($sigOauth.Count -gt 0)    {                                          Check "Electron: OAuth/login activity present" "INFO" ("seen {0}x in app.log" -f $sigOauth.Count) }
    if ($sigMulti.Count -gt 0)    {                                          Check "Electron: multi-instance restart loop" "WARN" ("seen {0}x - app keeps relaunching and re-prompting UAC" -f $sigMulti.Count) }
    if ($sigNoSvc.Count -gt 0)    {                                          Check "Electron: service state = not installed" "INFO" ("seen {0}x" -f $sigNoSvc.Count) }
    if ($sigDailyMiss.Count -gt 0){                                          Check "Electron: daily_reports missing (UI side)" "INFO" ("seen {0}x - app cannot find local data" -f $sigDailyMiss.Count) }
    if ($sigNoRefresh.Count -gt 0){                                          Check "Electron: no refresh token" "WARN" ("seen {0}x - user never completed sign-in (or tokens cleared) -> app cannot mint the device key" -f $sigNoRefresh.Count) }
    if ($sigEperm.Count -gt 0)    {                                          Check "Electron: helper copy EPERM (hardened dir)" "INFO" ("seen {0}x - C:\ProgramData\PiFocus files are SYSTEM-owned (Intune-hardened); Electron defers to an elevated copy. Harmless unless elevation was declined. On a company device the Electron app should be removed (Remove-PiFocusElectronApp.ps1)." -f $sigEperm.Count) }

    # last 15 error/warning lines from the app
    Line ""
    Line "  -- last error/warn lines from Electron app.log --" "DarkGray"
    $errLines = @($tail | Where-Object { $_ -match "\[error\]|\[warn\]" } | Select-Object -Last 12)
    foreach ($ln in $errLines) {
        $c = if ($ln -match "\[error\]") { "Red" } else { "Yellow" }
        Line ("    " + $ln.Substring(0,[Math]::Min($ln.Length,260))) $c
    }
} elseif ($ElectronAppLog) {
    Section "7d. ELECTRON APP LOG"
    Check "Electron app.log" "INFO" "$ElectronAppLog not found - app may not have been launched on this profile"
}

# Per-install batch logs the Electron app writes to %TEMP%
if ($ElectronUserTemp -and (Test-Path $ElectronUserTemp)) {
    $batchLogs = @(Get-ChildItem $ElectronUserTemp -Filter "pifocus_service_*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)
    if ($batchLogs.Count -gt 0) {
        Section ("7e. SERVICE-INSTALL BATCH LOGS  (most recent {0})" -f $batchLogs.Count)
        foreach ($b in $batchLogs) {
            Line ("  --- {0}  ({1}) ---" -f $b.Name,$b.LastWriteTime) "DarkGray"
            $bt = Get-Content $b.FullName -Tail 20 -ErrorAction SilentlyContinue
            foreach ($ln in $bt) {
                $c = if ($ln -match "FAIL|error|Error code") { "Red" } elseif ($ln -match "SUCCESS|Complete") { "Green" } else { "DarkGray" }
                Line ("    " + $ln) $c
            }
        }
    }
}

#============================================================================ 7f
Section "1.0.8 / 1.1.0 RELEASE VERIFICATION -- LOCK FIX + FUS + DYNAMIC IDLE + VERSION-REPORT + SECURITY (F-01)"
# Self-contained verifier for the 1.0.8 service / 1.1.8 electron release:
#   (a) the stuck-Inactive LOCK-STATE fix, and
#   (b) security remediations F-01/F-02/F-03/F-09 (F-01 = device-token
#       encryption-at-rest is the one directly observable on a device).
# Everything here is READ-ONLY and degrades to INFO when a path/pipe/registry
# value is absent. Reuses the topology already resolved above ($AgentExe /
# $HelperExe for Intune, $ElectronBinDir for Electron). NEVER prints the token.
$ExpectedSvcVer = [version]"1.0.8"
$ExpectedAppVer = [version]"1.1.8"
# 1.1.0 = the build that adds: the fast-user-switch stuck-lock fix (served-session
# UNLOCK always clears), the dynamic idle threshold (idleThresholdSeconds from the
# backend), and agent-version reporting (PATCH /agent/device-version). Service >= 1.1.0
# is the proxy for "has the FUS stuck-Inactive fix".
$ExpectedSvcVer110 = [version]"1.1.0"

# -- helpers (local to this section) ---------------------------------------
function Convert-ToVersionOrNull { param($s)
    if ([string]::IsNullOrWhiteSpace([string]$s)) { return $null }
    $m = [regex]::Match(([string]$s).Trim(), '\d+(\.\d+){1,3}')
    if (-not $m.Success) { return $null }
    try { return [version]$m.Value } catch { return $null }
}
# Fast ASCII-substring scan of a binary. Latin1 (cp28591) maps byte==codepoint,
# so an ASCII needle matches via .NET String.IndexOf without a slow per-byte
# PowerShell loop. Returns $true/$false, or $null if the file can't be read.
function Test-BinaryHasString { param([string]$Path,[string]$Needle)
    try {
        if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $hay = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
        return ($hay.IndexOf($Needle, [System.StringComparison]::Ordinal) -ge 0)
    } catch { return $null }
}
# Live lock-state query over the PROD named pipe (length-prefixed UTF-8 JSON).
# Write: 4-byte LE uint32 length + {"type":"GET_LOCK_STATE"}.
# Read : 4-byte LE uint32 length + that many bytes of {"locked":<bool>,"ok":true}.
function Get-PiFocusLockState { param([int]$TimeoutMs = 3000)
    $pipe = $null
    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.','PiFocusIPC',[System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect($TimeoutMs)
        $req = [System.Text.Encoding]::UTF8.GetBytes('{"type":"GET_LOCK_STATE"}')
        $lp  = [System.BitConverter]::GetBytes([uint32]$req.Length)
        if (-not [System.BitConverter]::IsLittleEndian) { [Array]::Reverse($lp) }
        $pipe.Write($lp,0,4); $pipe.Write($req,0,$req.Length); $pipe.Flush()
        $hdr = New-Object byte[] 4; $got = 0
        while ($got -lt 4) { $n = $pipe.Read($hdr,$got,4-$got); if ($n -le 0) { break }; $got += $n }
        if ($got -lt 4) { return @{ ok=$false; error="no/short length header" } }
        if (-not [System.BitConverter]::IsLittleEndian) { [Array]::Reverse($hdr) }
        $len = [int][System.BitConverter]::ToUInt32($hdr,0)
        if ($len -le 0 -or $len -gt 65536) { return @{ ok=$false; error="implausible length $len" } }
        $buf = New-Object byte[] $len; $got = 0
        while ($got -lt $len) { $n = $pipe.Read($buf,$got,$len-$got); if ($n -le 0) { break }; $got += $n }
        $json = [System.Text.Encoding]::UTF8.GetString($buf,0,$got)
        $obj = $null; try { $obj = $json | ConvertFrom-Json } catch {}
        return @{ ok=$true; json=$json; obj=$obj }
    } catch {
        return @{ ok=$false; error=$_.Exception.Message }
    } finally {
        if ($pipe) { try { $pipe.Dispose() } catch {} }
    }
}

# -- resolve the service binary THIS device actually runs (both topologies) --
$RelSvcExe = $null
if ($svc -and $svc.PathName) {
    if ($svc.PathName -match '^\s*"([^"]+\.exe)"' -or $svc.PathName -match '^\s*(\S+\.exe)') { $RelSvcExe = $matches[1] }
}
if (-not $RelSvcExe -or -not (Test-Path -LiteralPath $RelSvcExe)) {
    if ($Findings.AgentExe) { $RelSvcExe = $AgentExe }
    elseif ($ElectronBinDir) { $ec = Join-Path $ElectronBinDir 'WindowService.exe'; if (Test-Path -LiteralPath $ec) { $RelSvcExe = $ec } }
}
if ($RelSvcExe) { Check "Resolved service binary" "INFO" $RelSvcExe }
else { Check "Resolved service binary" "INFO" "no WindowService.exe located in either topology - dependent checks show INFO" }

# -- (1) version gate: service >= 1.0.8 -------------------------------------
$svcVer = $null
if ($RelSvcExe -and (Test-Path -LiteralPath $RelSvcExe)) {
    try { $svcVer = Convert-ToVersionOrNull ((Get-Item -LiteralPath $RelSvcExe).VersionInfo.FileVersion) } catch {}
}
if ($svcVer) {
    if ($svcVer -ge $ExpectedSvcVer) { Check "Service version >= 1.0.8" "PASS" ("FileVersion={0} (>= {1})" -f $svcVer,$ExpectedSvcVer) }
    else { $Findings.SvcVersionOld = $true; Check "Service version >= 1.0.8" "WARN" ("FileVersion={0} < {1} -- MISSING the stuck-Inactive lock fix AND security F-01/F-02/F-03/F-09. Redeploy 1.0.8." -f $svcVer,$ExpectedSvcVer) }
} else { Check "Service version >= 1.0.8" "INFO" "could not read WindowService.exe FileVersion" }
# version.txt (Intune topology writes it next to the exe)
$vtxtVer = $null
if (Test-Path -LiteralPath $VersionFile) { try { $vtxtVer = Convert-ToVersionOrNull ((Get-Content -LiteralPath $VersionFile -Raw)) } catch {} }
if ($vtxtVer) {
    if ($vtxtVer -ge $ExpectedSvcVer) { Check "version.txt >= 1.0.8" "PASS" ("{0}" -f $vtxtVer) }
    else { $Findings.SvcVersionOld = $true; Check "version.txt >= 1.0.8" "WARN" ("{0} < {1}" -f $vtxtVer,$ExpectedSvcVer) }
}

# -- (2) lock-fix compile markers in WindowService.exe ----------------------
if ($RelSvcExe -and (Test-Path -LiteralPath $RelSvcExe)) {
    $hasLock = Test-BinaryHasString $RelSvcExe 'lock.reconcile'
    $hasFus  = Test-BinaryHasString $RelSvcExe 'helper.stale_killed'
    if     ($hasLock -eq $true)  { Check "Marker 'lock.reconcile' in binary" "PASS" "lock-state fix compiled in" }
    elseif ($hasLock -eq $false) { $Findings.LockFixMissing = $true; Check "Marker 'lock.reconcile' in binary" "WARN" "ABSENT -- this WindowService.exe predates the lock-state fix (pre-1.0.8)" }
    else   { Check "Marker 'lock.reconcile' in binary" "INFO" "could not scan binary" }
    if     ($hasFus -eq $true)  { Check "Marker 'helper.stale_killed' in binary" "PASS" "fast-user-switch handling compiled in" }
    elseif ($hasFus -eq $false) { Check "Marker 'helper.stale_killed' in binary" "WARN" "ABSENT -- fast-user-switch stale-helper handling not present (old build)" }
    else   { Check "Marker 'helper.stale_killed' in binary" "INFO" "could not scan binary" }
} else { Check "Lock-fix compile markers" "INFO" "WindowService.exe not located - skipping marker scan" }

# -- (2b) 1.1.0 feature presence -------------------------------------------
# Service >= 1.1.0 carries the fast-user-switch stuck-lock fix (the served
# session's own UNLOCK always clears, even with a stale foreign lock latch).
# The dynamic-idle + version-report strings live in HelperService.exe.
if ($svcVer) {
    if ($svcVer -ge $ExpectedSvcVer110) { Check "1.1.0 fast-user-switch lock fix" "PASS" ("service {0} >= 1.1.0 -- FUS served-session UNLOCK fix present" -f $svcVer) }
    else { Check "1.1.0 fast-user-switch lock fix" "INFO" ("service {0} < 1.1.0 -- FUS stuck-lock relies ONLY on the ~3-cycle reconcile (can stick under FUS churn). Redeploy 1.1.0 for the instant-clear fix." -f $svcVer) }
}
$HelperScan = $null
if ($Findings.AgentExe -and $HelperExe -and (Test-Path -LiteralPath $HelperExe)) { $HelperScan = $HelperExe }
elseif ($ElectronBinDir) { $eh = Join-Path $ElectronBinDir 'HelperService.exe'; if (Test-Path -LiteralPath $eh) { $HelperScan = $eh } }
if ($HelperScan) {
    $hasIdle = Test-BinaryHasString $HelperScan 'idleThresholdSeconds'
    $hasDevVer = Test-BinaryHasString $HelperScan '/agent/device-version'
    if     ($hasIdle -eq $true)  { Check "1.1.0 dynamic idle threshold" "PASS" "helper reads backend idleThresholdSeconds (dynamic AFK)" }
    elseif ($hasIdle -eq $false) { Check "1.1.0 dynamic idle threshold" "INFO" "ABSENT -- helper predates dynamic idle (hardcoded gate)" }
    if     ($hasDevVer -eq $true)  { Check "1.1.0 agent-version report" "PASS" "helper PATCHes /agent/device-version (version reaches backend device record)" }
    elseif ($hasDevVer -eq $false) { Check "1.1.0 agent-version report" "INFO" "ABSENT -- helper predates device-version reporting" }
} else { Check "1.1.0 helper feature markers" "INFO" "HelperService.exe not located - skipping idle/device-version scan" }

# -- (3) LIVE lock state over the named pipe (GET_LOCK_STATE) ----------------
$lock = Get-PiFocusLockState 3000
if ($lock.ok -and $null -ne $lock.obj) {
    if ([bool]$lock.obj.locked) {
        $Findings.LockReportedLocked = $true
        Check "Live lock state (pipe GET_LOCK_STATE)" "WARN" ("service reports locked=TRUE. If the user is actively working, this is the stuck-Inactive bug (1.0.8 self-heals via lock.reconcile - see log scan below). raw={0}" -f $lock.json)
    } else { Check "Live lock state (pipe GET_LOCK_STATE)" "PASS" ("locked=false (active). raw={0}" -f $lock.json) }
} else {
    Check "Live lock state (pipe GET_LOCK_STATE)" "INFO" ("pipe query unavailable ({0}). Service may be stopped, or a build that predates GET_LOCK_STATE." -f $lock.error)
}

# -- (4) lock.reconcile / self-heal evidence in the WindowService log --------
if (Test-Path -LiteralPath $DebugLogDir) {
    $wf = @(Get-ChildItem $DebugLogDir -Filter "*-WindowService.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2)
    if ($wf.Count -gt 0) {
        $wev = New-Object System.Collections.Generic.List[object]
        foreach ($f in $wf) { foreach ($o in (Read-NdjsonTail $f.FullName 6000)) { $wev.Add($o) } }
        $rec  = @($wev | Where-Object { $_.category -eq 'lock.reconcile' })
        $seed = @($rec | Where-Object { $_.message -match 'startup seed' })
        $heal = @($rec | Where-Object { $_.message -match 'healing to (unlocked|locked)|self-heal' })
        if ($rec.Count -gt 0) {
            Check "lock.reconcile log entries" "INFO" ("{0} entr(y/ies): {1} startup-seed, {2} self-heal" -f $rec.Count,$seed.Count,$heal.Count)
            $lastHeal = $heal | Select-Object -Last 1
            if ($lastHeal) { Line ("    last self-heal @ {0}: {1}" -f $lastHeal.ts,$lastHeal.message) "DarkGray" }
        } else { Check "lock.reconcile log entries" "INFO" "none in recent WindowService log (fix may not have needed to act, or build predates it)" }
    } else { Check "lock.reconcile log entries" "INFO" "no WindowService.json logs present" }
} else { Check "lock.reconcile log entries" "INFO" "$DebugLogDir missing" }

# -- (4b) Fast-user-switch stuck-lock fingerprints (the fleet "inactive" cause) --
# On a shared PC, a fast-user-switch latches the OUTGOING user's LOCK and then
# FILTERS the INCOMING served user's UNLOCK -> the active user stays "locked" ->
# 0% active -> Inactive. Two log fingerprints: FUS churn + the explicit
# "dropped/filtered UNLOCK" reconcile incident.
if (Test-Path -LiteralPath $DebugLogDir) {
    $wf2 = @(Get-ChildItem $DebugLogDir -Filter "*-WindowService.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2)
    if ($wf2.Count -gt 0) {
        $wev2 = New-Object System.Collections.Generic.List[object]
        foreach ($f in $wf2) { foreach ($o in (Read-NdjsonTail $f.FullName 6000)) { $wev2.Add($o) } }
        $fus = @($wev2 | Where-Object { "$($_.message)" -match 'Fast User Switch|fast-user-switch' })
        $dropUnlock = @($wev2 | Where-Object { "$($_.message)" -match 'dropped/filtered UNLOCK|stuck-Inactive incident' })
        if ($fus.Count -gt 0) { $Findings.IsSharedPC = $true; Check "Fast-user-switch activity" "WARN" ("{0} FUS event(s) -- SHARED PC; FUS is the stuck-lock trigger" -f $fus.Count) }
        else { Check "Fast-user-switch activity" "INFO" "no FUS events recently (single-user, or none in window)" }
        if ($dropUnlock.Count -gt 0) {
            $Findings.FusDroppedUnlock = $true
            $ld = $dropUnlock | Select-Object -Last 1
            Check "FUS dropped/filtered UNLOCK" "WARN" ("{0} incident(s); last @ {1} -- served user's UNLOCK was filtered (stuck-Inactive). 1.1.0 clears this instantly; <1.1.0 waits on the reconcile." -f $dropUnlock.Count,$ld.ts)
        }
    }
}

# -- (4c) LIVE per-session lock state (multi-user / shared PC) ----------------
# Every logged-in session: user, connect-state, and REAL lock flag
# (WTSQuerySessionInformation WTSSessionInfoEx; SessionFlags at offset 16 -- the
# union is 8-byte aligned, so offset 12 is SessionState, NOT the flag). The session
# the agent SERVES should be the Active console one and UNLOCKED while the user works.
try {
    $sig = @"
using System;using System.Runtime.InteropServices;
public static class PFLk {
 [StructLayout(LayoutKind.Sequential)] public struct SI{ public uint Id; public IntPtr Name; public int State; }
 [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
 [DllImport("wtsapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool WTSEnumerateSessionsW(IntPtr h,int r,int v,out IntPtr p,out int c);
 [DllImport("wtsapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool WTSQuerySessionInformationW(IntPtr h,uint s,int cls,out IntPtr b,out uint n);
 [DllImport("wtsapi32.dll")] public static extern void WTSFreeMemory(IntPtr p);
 static string[] ST=new string[]{"Active","Connected","ConnectQuery","Shadow","Disconnected","Idle","Listen","Reset","Down","Init"};
 public static string R(){
  uint con=WTSGetActiveConsoleSessionId(); string o="console session="+con;
  IntPtr p; int c; if(!WTSEnumerateSessionsW(IntPtr.Zero,0,1,out p,out c)) return o+" (enum failed)";
  int sz=Marshal.SizeOf(typeof(SI));
  for(int i=0;i<c;i++){ SI si=(SI)Marshal.PtrToStructure(new IntPtr(p.ToInt64()+i*sz),typeof(SI)); if(si.Id==0) continue;
   string u=""; IntPtr b; uint n;
   if(WTSQuerySessionInformationW(IntPtr.Zero,si.Id,5,out b,out n)&&b!=IntPtr.Zero){u=Marshal.PtrToStringUni(b);WTSFreeMemory(b);}
   string lk="?"; if(WTSQuerySessionInformationW(IntPtr.Zero,si.Id,25,out b,out n)&&b!=IntPtr.Zero){int f=Marshal.ReadInt32(b,16);WTSFreeMemory(b);lk=(f==0?"LOCKED":f==1?"UNLOCKED":"UNKNOWN");}
   string st=(si.State>=0&&si.State<ST.Length)?ST[si.State]:si.State.ToString();
   o+=String.Format("\n    sid={0} user='{1}' state={2} lock={3}{4}",si.Id,u,st,lk,(si.Id==con?" <-CONSOLE":"")); }
  WTSFreeMemory(p); return o; } }
"@
    if (-not ('PFLk' -as [type])) { Add-Type -TypeDefinition $sig -Language CSharp -ErrorAction Stop }
    $sess = [PFLk]::R()
    $sessHead = ($sess -split "`n")[0]
    Check "Live per-session lock state" "INFO" $sessHead
    foreach ($ln in ($sess -split "`n")) { if ($ln -match 'sid=') { Line $ln "DarkGray" } }
} catch { Check "Live per-session lock state" "INFO" ("probe unavailable: {0}" -f $_.Exception.Message) }

# -- (4d) dynamic idle threshold this device is using (from the config cache) --
$cfgCache = 'C:\ProgramData\PiFocus\productivity_config.json'
if (Test-Path -LiteralPath $cfgCache) {
    try {
        $pc = Get-Content -LiteralPath $cfgCache -Raw | ConvertFrom-Json
        if ($null -ne $pc.idleThresholdSeconds) { Check "Dynamic idle threshold (cached)" "INFO" ("{0}s ({1:N0} min) -- from backend /agent/configurations" -f $pc.idleThresholdSeconds,($pc.idleThresholdSeconds/60.0)) }
        else { Check "Dynamic idle threshold (cached)" "INFO" "idleThresholdSeconds not cached (pre-1.1.0 helper or config not fetched yet) -> 900s default" }
    } catch { Check "Dynamic idle threshold (cached)" "INFO" "config cache unreadable" }
}

# daily_reports CONTENT analysis -- the KEY signal for "user shows Inactive
# even though uploads succeed". Two independent signatures:
#   (a) metrics:      near-zero totalActive + large totalIdle
#   (b) applications: the "None" pseudo-app (Idle / Windows Locked / Sleep-
#                     Standby) dominates while REAL apps captured almost no
#                     time  -> capture-only-idle / stuck-Inactive.
# Uses ONLY app-level name + totalSeconds; NEVER reads session identifiers /
# window titles / urls (those are PII). Sets $Findings.InactiveOnly, which the
# section-8 verdict uses to attribute an all-Idle day to a LOCAL cause rather
# than misfiling it as a backend/mapping issue.
if (Test-Path -LiteralPath $ReportsDir) {
    $rp = @(Get-ChildItem $ReportsDir -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($rp.Count -gt 0) {
        try {
            $rep = Get-Content -LiteralPath $rp[0].FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            $act = 0; $idle = 0
            if ($rep.metrics) {
                if ($null -ne $rep.metrics.totalActiveSeconds) { $act  = [int]$rep.metrics.totalActiveSeconds }
                if ($null -ne $rep.metrics.totalIdleSeconds)   { $idle = [int]$rep.metrics.totalIdleSeconds }
            }
            # app-level split: name == "None" is the idle/locked/standby pseudo-app
            $noneSec = 0; $realSec = 0; $realApps = 0
            foreach ($a in @($rep.applications)) {
                $sec = 0; if ($null -ne $a.totalSeconds) { $sec = [int]$a.totalSeconds }
                if ("$($a.name)" -eq 'None') { $noneSec += $sec }
                elseif ($sec -gt 0) { $realSec += $sec; $realApps++ }
            }
            $den = $act + $idle
            $activePct = if ($den -gt 0) { [math]::Round(100.0 * $act / $den) } else { 0 }
            # INACTIVE-ONLY = almost no REAL activity captured, yet plenty of idle/None.
            $Findings.InactiveOnly = ( ($act -le 60 -and $idle -gt 300) -or ($realSec -lt 120 -and $noneSec -gt 600) )
            $st = if ($Findings.InactiveOnly) { "WARN" } else { "INFO" }
            $sig = if ($Findings.InactiveOnly) { "  <-- INACTIVE-ONLY: real-app capture ~0 while idle/None dominates (stuck-lock / old build / user genuinely away -> see verdict)" } else { "" }
            Check "Latest daily_reports metrics" $st ("{0}: active={1}s idle={2}s ({3}% active) | real-apps={4} (activeAppSecs={5}s) idle/None={6}s{7}" -f `
                $rp[0].Name,$act,$idle,$activePct,$realApps,$realSec,$noneSec,$sig)
        } catch { Check "Latest daily_reports metrics" "INFO" ("could not parse {0}" -f $rp[0].Name) }
    } else { Check "Latest daily_reports metrics" "INFO" "no daily_reports json files" }
} else { Check "Latest daily_reports metrics" "INFO" "$ReportsDir missing" }

# -- (5) F-01: device-token encryption at rest (TYPE ONLY, never the value) --
$tokRaw = $null
if ($ConsoleSid) {
    try { $tp = Get-ItemProperty ("Registry::HKEY_USERS\{0}\{1}" -f $ConsoleSid,$HkcuHelper) -ErrorAction Stop; if ($null -ne $tp.DeviceApiKey) { $tokRaw = $tp.DeviceApiKey } } catch {}
}
if ($null -eq $tokRaw) {
    try { $tp = Get-ItemProperty ("HKCU:\{0}" -f $HkcuHelper) -ErrorAction Stop; if ($null -ne $tp.DeviceApiKey) { $tokRaw = $tp.DeviceApiKey } } catch {}
}
if ($null -eq $tokRaw) {
    Check "F-01 device-token encrypted at rest" "INFO" "DeviceApiKey not present (user not signed in) - cannot assess"
} elseif ($tokRaw -is [byte[]]) {
    Check "F-01 device-token encrypted at rest" "PASS" ("REG_BINARY / DPAPI-encrypted (F-01 present). length={0} bytes (value hidden)" -f $tokRaw.Length)
} else {
    $Findings.TokenPlaintext = $true
    Check "F-01 device-token encrypted at rest" "WARN" ("REG_SZ PLAINTEXT (pre-F-01 build -- security regression). length={0} chars (value hidden). A REG_SZ alongside a running fixed helper can also indicate the deviceKeyStore plaintext/encrypted flap." -f ([string]$tokRaw).Length)
}

# -- (6) Electron 1.1.8 SHA freshness vs service-build.json manifest ---------
$manPath = if ($ElectronBinDir) { Join-Path $ElectronBinDir 'service-build.json' } else { $null }
if ($manPath -and (Test-Path -LiteralPath $manPath)) {
    try {
        $man = Get-Content -LiteralPath $manPath -Raw -ErrorAction Stop | ConvertFrom-Json
        Check "service-build.json manifest" "INFO" ("serviceVersion={0} env={1}" -f $man.serviceVersion,$man.env)
        $manV = Convert-ToVersionOrNull $man.serviceVersion
        if ($manV -and $manV -lt $ExpectedSvcVer) { $Findings.SvcVersionOld = $true; Check "Manifest serviceVersion >= 1.0.8" "WARN" ("{0} < {1}" -f $manV,$ExpectedSvcVer) }
        elseif ($manV) { Check "Manifest serviceVersion >= 1.0.8" "PASS" ("{0}" -f $manV) }
        foreach ($exe in @('WindowService.exe','HelperService.exe')) {
            $onDisk = Join-Path $ElectronBinDir $exe
            $entry = $null; if ($man.files) { $entry = $man.files.$exe }
            if (-not $entry -or -not $entry.sha256) { Check "Freshness: $exe" "INFO" "no sha256 in manifest"; continue }
            if (-not (Test-Path -LiteralPath $onDisk)) { Check "Freshness: $exe" "WARN" "listed in manifest but missing on disk"; continue }
            try {
                $diskHash = (Get-FileHash -LiteralPath $onDisk -Algorithm SHA256 -ErrorAction Stop).Hash
                $manHash  = [string]$entry.sha256
                if ($diskHash -ieq $manHash) { Check "Freshness: $exe" "PASS" "SHA256 matches manifest (app deployed the shipped binary)" }
                else {
                    $Findings.ShaStale = $true
                    Check "Freshness: $exe" "WARN" ("SHA256 MISMATCH vs manifest -> stale / failed redeploy. disk={0}.. manifest={1}.." -f $diskHash.Substring(0,[Math]::Min(12,$diskHash.Length)),$manHash.Substring(0,[Math]::Min(12,$manHash.Length)))
                }
            } catch { Check "Freshness: $exe" "INFO" ("could not hash on-disk exe: {0}" -f $_.Exception.Message) }
        }
    } catch { Check "service-build.json manifest" "INFO" ("present but unparseable: {0}" -f $_.Exception.Message) }
} else {
    Check "Electron service-build.json manifest" "INFO" "not found (Intune topology, or app not installed) - SHA freshness N/A"
}
# Electron app version (report + gate against 1.1.8)
if ($ElectronAppExe -and (Test-Path -LiteralPath $ElectronAppExe)) {
    $appVer = $null
    try { $appVer = Convert-ToVersionOrNull ((Get-Item -LiteralPath $ElectronAppExe).VersionInfo.FileVersion) } catch {}
    if ($appVer) {
        if ($appVer -ge $ExpectedAppVer) { Check "Electron app version >= 1.1.8" "PASS" ("{0}" -f $appVer) }
        else { Check "Electron app version >= 1.1.8" "WARN" ("{0} < {1} -- older desktop app; update to 1.1.8" -f $appVer,$ExpectedAppVer) }
    } else { Check "Electron app version >= 1.1.8" "INFO" "could not read app FileVersion" }
}

# -- (7) Authenticode signature of the running service exe -------------------
if ($RelSvcExe -and (Test-Path -LiteralPath $RelSvcExe)) {
    try {
        $sg = Get-AuthenticodeSignature -FilePath $RelSvcExe -ErrorAction Stop
        $subj = if ($sg.SignerCertificate) { $sg.SignerCertificate.Subject } else { "<none>" }
        $cn = ""; if ($subj -match 'CN=("?)([^,"]+)\1') { $cn = $matches[2].Trim() }
        if     ($sg.Status -eq 'Valid' -and $cn -match 'PHYSICSWALLAH') { Check "Service binary signature" "PASS" ("Valid | {0}" -f $cn) }
        elseif ($sg.Status -eq 'Valid')     { Check "Service binary signature" "WARN" ("Valid but signer='{0}' (expected 'PHYSICSWALLAH LIMITED')" -f $cn) }
        elseif ($sg.Status -eq 'NotSigned') { Check "Service binary signature" "WARN" "NOT SIGNED - not an official PhysicsWallah build (or tampered)" }
        else   { Check "Service binary signature" "WARN" ("{0} | {1}" -f $sg.Status,$subj) }
    } catch { Check "Service binary signature" "INFO" $_.Exception.Message }
}

#============================================================================ 8
Section "8. ROOT-CAUSE VERDICT"
$verdict = New-Object System.Collections.Generic.List[string]
$luc = if ($Findings.LastUploadCode) { [int]$Findings.LastUploadCode } else { 0 }

# TOP PRIORITY: if we're on a TEMP Windows profile, nothing below matters -
# every per-user finding is a false negative. Send IT to fix the profile first.
if ($Findings.TempProfile) {
    $verdict.Add("TEMPORARY WINDOWS PROFILE - this session is on an empty temp profile, so EVERY per-user 'FAIL' above (Electron app, token, autolaunch, app.log, HKCU) is a false negative. The user's real profile is not loaded, so we cannot tell what state her actual install is in. FIX: sign her out + reboot. If Windows still loads a temp profile, check Event Viewer -> User Profile Service, and look for a '<SID>.bak' entry under HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList that needs to be renamed back. Re-run this script after she is on her real profile.")
}
# NEXT PRIORITY: zombie service registration - service is registered but its
# ImagePath points to a deleted binary. Common after Electron app uninstall
# without 'sc delete'. Would have caught Pradip's case immediately.
elseif ($Findings.StaleImagePath) {
    $verdict.Add("ZOMBIE SERVICE REGISTRATION - $ServiceName is registered but its ImagePath points to a binary that no longer exists (section 2 flagged 'Service binary on disk: FAIL', or SCM Event 7000 returned Win32 error 2). This is what happens when the Electron app is uninstalled without also running 'sc delete $ServiceName'. FIX: 'sc.exe stop $ServiceName; sc.exe delete $ServiceName' as admin, then push the current Intune package OR reinstall the current Electron app. The install script will create a fresh service pointing at the correct binary.")
}
elseif (-not $svc) {
    if ($Findings.UacCancelled -or $Findings.ElectronInstallFailed) {
        $verdict.Add("UAC ELEVATION DECLINED: the user clicked 'No'/'Cancel' on the PiFocus app's UAC prompt, so the Windows service was never created (section 7d shows 'User did not grant permission'). Until the service is installed, nothing is captured -> 0 hrs. FIX: open the PiFocus desktop app and click 'Yes' on the UAC prompt. If the user keeps closing it, they need to accept it once - the app cannot install the service without admin elevation.")
    } elseif (-not $Findings.AgentExe -and -not $Findings.ElectronInstalled) {
        $verdict.Add("NOT INSTALLED AT ALL: neither the Intune path (C:\Program Files\PiFocus\Agent) nor the Electron app bundle (%LOCALAPPDATA%\Programs\pi-focus-business-app) is present. The PiFocus agent has never been deployed on this device.")
    } else {
        $verdict.Add("INSTALL INCOMPLETE: binaries are on disk but the Windows service is not registered. 'sc create' was never run successfully. Re-run install.ps1 (Intune) or relaunch the PiFocus app and accept the UAC prompt (Electron).")
    }
}
elseif (-not $Findings.SvcRunning) {
    if ($Findings.WerCrtMismatch -or $Findings.RedistTooOld) {
        $verdict.Add("VC++ RUNTIME MISMATCH -> Error 1067 / ACCESS_VIOLATION inside MSVCP140 or VCRUNTIME140. The device has CRT DLLs (System32) older than the toolset that built our binary (14.30+). Section 2c shows the fault module and version; section 1 shows the installed redist version. FIX (immediate, fastest): install https://aka.ms/vs/17/release/vc_redist.x64.exe and 'sc start $ServiceName'. FIX (permanent): the latest install.ps1 bundles msvcp140.dll + vcruntime140.dll next to WindowService.exe so the device's redist version stops mattering - redeploy that build.")
    } elseif ($Findings.IfeoHijack) {
        $verdict.Add("SERVICE CANNOT START: Image File Execution Options key on WindowService.exe has a Debugger/GlobalFlag set (section 2b). Remove it: 'reg delete HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WindowService.exe /f'.")
    } elseif ($Findings.ArchMismatch) {
        $verdict.Add("SERVICE CANNOT START -> 0xC000007B INVALID_IMAGE_FORMAT. Binary architecture does not match the OS (32-bit binary on x64 OS, or corrupt PE). Reinstall with the correct package.")
    } elseif ($Findings.DefenderQuarantine) {
        $verdict.Add("SERVICE CANNOT START: Windows Defender has flagged/quarantined a PiFocus binary (section 2b). Restore from quarantine and add a Defender exclusion for C:\\Program Files\\PiFocus\\Agent\\ and C:\\ProgramData\\PiFocus\\.")
    } elseif ($Findings.AclBlock) {
        $verdict.Add("SERVICE CANNOT START: NTFS ACL on WindowService.exe does not grant SYSTEM read+execute (section 2b). Re-install or run 'icacls' to restore default permissions.")
    } elseif ($Findings.CrtMissing -and $Findings.CrtMissing.Count -gt 0) {
        $verdict.Add("SERVICE CANNOT START -> Error 1067. Missing VC++ runtime DLL(s): " + ($Findings.CrtMissing -join ", ") + ". The process dies at load (0xC0000135). FIX: install 'Microsoft Visual C++ 2015-2022 Redistributable (x64)', or bundle msvcp140.dll + vcruntime140.dll next to WindowService.exe (you ship only vcruntime140_1.dll today).")
    } elseif ($Findings.DllLoadCrash) {
        $verdict.Add("SERVICE CANNOT START -> Error 1067. Application Error 0xC0000135 (a required DLL is missing). Most likely the VC++ runtime (msvcp140.dll / vcruntime140.dll). Same fix as the CRT case above.")
    } elseif ($Findings.DllEntryPointMissing) {
        $verdict.Add("SERVICE CANNOT START -> Error 1067 via 0xC0000139 ENTRYPOINT_NOT_FOUND. A DLL is present but the wrong VERSION (an imported function is gone). Most likely a CRT or sentry DLL mismatch.")
    } elseif ($Findings.SxsFail) {
        $verdict.Add("SERVICE CANNOT START -> 0xC0150002 SxS activation failure. A side-by-side manifest dependency is missing or wrong. Reinstall the VC++ redistributable.")
    } elseif ($Findings.MissingServiceFlag) {
        $verdict.Add("SERVICE CANNOT START -> Error 1083. ImagePath does not pass '--service' so the binary runs in console mode and never calls StartServiceCtrlDispatcher. Recreate the service with the correct binPath.")
    } elseif ($Findings.DepFail) {
        $verdict.Add("SERVICE CANNOT START -> Error 1068. A dependency service is not running (section 2b lists which).")
    } elseif ($Findings.ExitCode1067 -or $Findings.CrashFatal -or $Findings.InCodeCrash -or $Findings.RestartLoop) {
        $verdict.Add("SERVICE IS CRASH-LOOPING (Error 1067 from a native crash, NOT a DLL load issue). Section 7 shows the crash.fatal line (faulting module + phase). For this codebase the prime suspect is the sentry/crashpad init path (phase=init-crash-reporter). Pull C:\\ProgramData\\ProgramMonitor\\debugLogs\\*-WindowService.json for the exact stack.")
    } else {
        $verdict.Add("SERVICE NOT RUNNING - cause not obvious from automated checks. Review the SCM events in section 2, the decoded ExitCode in section 2b, and the WindowService log in section 7.")
    }
}
elseif (-not $Findings.HelperInUserSession) {
    $verdict.Add("HELPERSERVICE NOT IN THE USER SESSION: WindowService is up but the helper that actually captures windows/activity is not running in the logged-in user's session (CreateProcessAsUser failure, wrong/locked session, or AV blocking the helper). No activity is captured -> 0 hrs. Check 'helper.launch' entries in the WindowService log.")
}
elseif (-not $Findings.TokenPresent) {
    if ($Findings.AgentExe -and $Findings.IntuneEnrolled -and -not $Findings.ElectronAppInstalled) {
        # Company / Intune device: NO desktop-app login by design. The token is
        # provisioned by WindowService via machine-key, so token-missing here is
        # a provisioning failure, NOT "install the app".
        $idLine = if ($resolvedId) { " Agent identity for machine-key = $resolvedId [source: $resolvedSrc]." } else { "" }
        if ($Findings.TokenWriteNoSession) {
            $verdict.Add("TOKEN FETCHED BUT NOT PERSISTED (Intune company device): the machine-key call worked, but WindowService could not write/DPAPI-seal the token because there was no active console user session at the time (token.registry_write / token.sid errors in section 7).$idLine FIX: this self-heals once a user logs in -- WindowService re-checks every ~5 min and writes the token into the logged-in user's hive. If it persists, confirm a user actually logs into this device.")
        } elseif ($Findings.EntDmidMissing -or $Findings.IdentityIsMachineGuid) {
            $verdict.Add("TOKEN NOT PROVISIONED (Intune company device): BIOS serial is a placeholder and no Intune EntDMID was resolved, so the agent falls back to MachineGuid -- which the backend (which maps by EntDMID) cannot match -> GET /user-devices/<id>/machine-key never yields a token -> no auth -> 0 hrs.$idLine FIX: this device's Intune enrolment is not exposing EntDMID under HKLM\SOFTWARE\Microsoft\Enrollments\<id>\DMClient\MS DM Server (re-check enrolment), OR map this device by MachineGuid on the backend.")
        } elseif ($Findings.MkJsonFail) {
            $verdict.Add("TOKEN NOT PROVISIONED (Intune company device): the agent resolved its identity (EntDMID) and called machine-key, but the backend returned a NON-JSON response (device not found / not mapped, or a server error) -> no token -> 0 hrs.$idLine This is a BACKEND / device-mapping issue, NOT a client bug. FIX: backend confirm this EntDMID is registered/mapped in user-devices and that /machine-key returns valid JSON for it. Escalate with the identity above + this device's computer name.")
        } elseif ($Findings.MkHttpFail) {
            $verdict.Add("TOKEN NOT PROVISIONED (Intune company device): the machine-key HTTP call itself failed (network / proxy / TLS), so the token was never fetched.$idLine FIX: check this device's connectivity to $BackendHost (section 6 - WinHTTP proxy/VPN/DNS).")
        } else {
            $verdict.Add("TOKEN NOT PROVISIONED (Intune company device): no device token yet. This is a company device with no desktop app (correct) -- login is NOT the fix; the token must come from the WindowService machine-key call.$idLine See the 'Token provisioning' block in section 7 and the WindowService log; escalate with the resolved identity above.")
        }
    } elseif ($Findings.AsarLoadFail) {
        $verdict.Add("DEVICE TOKEN MISSING + APP UI BROKEN: HKCU\$HkcuHelper\DeviceApiKey is absent AND the Electron app cannot load app.asar (ERR_FAILED in section 7d). The user can't complete login because the UI never renders. Almost always Defender/AV quarantine of the asar or a corrupted install. FIX: add a Defender exclusion for %LOCALAPPDATA%\Programs\pi-focus-business-app\ and reinstall the PiFocus app.")
    } elseif (-not $Findings.ElectronAppInstalled) {
        $verdict.Add("DEVICE TOKEN MISSING + APP NOT INSTALLED: the PiFocus desktop app .exe is not present on this user profile. The user has no way to sign in -> no token -> no upload auth. FIX: install the PiFocus desktop app.")
    } elseif (-not $Findings.ElectronAppRunning) {
        $verdict.Add("DEVICE TOKEN MISSING + APP NOT RUNNING: the token registry value is absent and the PiFocus app is not currently running. FIX: open the PiFocus app, complete sign-in, and verify auto-launch (section 1b).")
    } else {
        $verdict.Add("DEVICE TOKEN MISSING: HKCU\$HkcuHelper\DeviceApiKey is not set even though the app is running. The user has not finished login. FIX: have the user click 'Sign in with Google' inside the PiFocus app.")
    }
}
elseif ($Findings.Paused) {
    $verdict.Add("TRACKING IS PAUSED: $HklmRoot\TrackingEnabled=0 and/or the $PauseEvent event is signaled. No data is collected until tracking is resumed from the app.")
}
elseif (-not $Findings.BackendReachable) {
    $verdict.Add("BACKEND UNREACHABLE RIGHT NOW: this device cannot reach https://$BackendHost (DNS/firewall/proxy). Note the service uses WinHTTP, whose proxy is separate from the browser - see section 6. Data is collected locally but cannot upload -> 0 hrs.")
}
elseif ($Findings.AuthRejected) {
    $verdict.Add("AUTH REJECTED: the last activities upload returned HTTP $($Findings.LastUploadCode) (token invalid/expired). FIX: have the user re-login in the PiFocus app to refresh the token.")
}
elseif ($Findings.BackendError) {
    $verdict.Add("BACKEND ERROR: the last activities upload returned HTTP $($Findings.LastUploadCode) (5xx). Local capture + auth look fine - escalate to the backend team with this device's serial and the timestamp.")
}
elseif ($luc -ge 200 -and $luc -lt 300) {
    if ($Findings.InactiveOnly) {
        # Uploads succeed, but this device logged almost only Idle/None today.
        # That is a LOCAL cause, NOT a backend/mapping issue -- attribute it.
        if ($Findings.LockReportedLocked) {
            $verdict.Add("UPLOADING FINE, BUT SHOWS INACTIVE -> STUCK LOCK STATE. Uploads return HTTP $luc, yet this device captured almost no real activity today (see '1.0.8 RELEASE VERIFICATION' daily_reports line: real-app seconds ~0, idle/None dominant) AND the live pipe reports lock state = LOCKED. If the user is actually working, this IS the stuck-Inactive bug. FIX: on 1.0.8 the lock.reconcile self-heal clears it within ~1 min; if it persists on 1.0.8, collect $DebugLogDir\*-WindowService.json and grep 'lock.reconcile'. If the service is < 1.0.8, redeploy 1.0.8 / 1.1.8.")
        } elseif ($Findings.SvcVersionOld -or $Findings.LockFixMissing) {
            $verdict.Add("UPLOADING FINE, BUT SHOWS INACTIVE -> OLD BUILD MISSING THE LOCK FIX. Uploads return HTTP $luc, but real-app capture is ~0 (idle/None dominant) and this WindowService is < 1.0.8 (no 'lock.reconcile' marker). Pre-1.0.8 builds can latch Inactive after a lock/unlock or fast-user-switch and never recover -> the user shows Inactive while working. FIX: redeploy 1.0.8 (Intune) / 1.1.8 (Electron).")
        } else {
            $verdict.Add("UPLOADING FINE, BUT SHOWS INACTIVE (LOCAL, not backend). Uploads return HTTP $luc and the service/helper/token look healthy, yet this device logged almost only Idle/None today (real-app seconds ~0). TWO possibilities: (1) the user was genuinely away from the keyboard, or (2) capture is stuck Inactive. Disambiguate on THIS device: is the live lock state LOCKED (section 7f)? were there any 'lock.reconcile' self-heals? is the helper truly in the user's session (section 3)? If the user WAS working, collect $DebugLogDir\*-WindowService.json + *-HelperService.json and escalate with those (do NOT file this as a backend/mapping issue).")
        }
    } else {
        $msg = "DATA IS REACHING THE BACKEND (last activities upload HTTP $luc) WITH real activity captured locally. If the dashboard still shows 0 hrs for this user, it is NOT a capture/upload failure on this device - escalate to backend/reporting with the device serial, the active user ($ConsoleUser), and the last-upload timestamp (likely a user/device mapping or time-window issue)."
        if ($Findings.TransportFail) { $msg += "  (Heads-up: intermittent upload failures were also seen historically - see the intermittent-issues list below - but current uploads succeed.)" }
        $verdict.Add($msg)
    }
}
elseif ($Findings.TransportFail) {
    $verdict.Add("INTERMITTENT NETWORK UPLOADS: the backend is reachable now, but the service's WinHTTP uploads have been failing at times (api.transport_fail). win32=12007 means DNS name-not-resolved - flaky DNS/VPN/proxy on this device. Data buffers locally and should catch up when the network is stable; if 0 hrs persists, investigate this device's DNS/VPN.")
}
else {
    $verdict.Add("No single current smoking gun. Review every [FAIL]/[WARN] above and the intermittent-issues list below. Best next step: collect $DebugLogDir\ and $InstallLog from this device.")
}

foreach ($v in $verdict) { Line ""; Line (">>> " + $v) "White" }

# Install-script-generation warnings surface AFTER the primary verdict --
# they can be a root cause on their own (stale Helper on disk breaks URL
# categorization and per-instance UPN attribution even when everything
# above looks fine), OR they can be secondary context for another verdict
# (e.g. the primary said "backend unreachable now" but this line tells
# you why prior uploads had no UPN stamp).
if ($Findings.OldInstallScriptStillDeployed) {
    Line ""
    Line (">>> DEPLOYMENT LAG: this device is still running the pre-1.0.5 install script (no 'VERDICT env=' line in Install.log). The old script used plain Copy-Item with no lock/size verification, so a partial-install (fresh WindowService.exe + stale June-3 HelperService.exe) reports 'Installed Successfully' with no error. Ask IT to upload the new install.intunewin (version 1.0.5) to Intune. Every device that re-installs will then get PACKAGE INVENTORY logging, marker preflight, Copy-ItemVerified, and a VERDICT banner in Install.log.") "Yellow"
}
if ($Findings.StaleBinaryOnDevice) {
    Line ""
    Line (">>> STALE BINARY DETECTED: the new install.ps1's post-install marker check on this device reported Helper_fresh=False (or Window_fresh=False). Something between Copy-ItemVerified success and the final marker check restored an old binary -- most likely AV / EDR / sync tool intercepting %ProgramData%\PiFocus\HelperService.exe. Check Defender, any file-sync agents, and any group-policy that restores files in that folder.") "Yellow"
}

# Always-relevant warning: wmic gone on Win11 24H2+ means the Electron app
# cannot read the BIOS serial. Even when everything else is fine, this can
# cause the backend to drop / misattribute this device's uploads.
if ($Findings.WmicMissing) {
    Line ""
    Line (">>> ALSO: wmic.exe is missing on this Windows build (24H2+ removes it). The PiFocus desktop app uses 'wmic bios get serialnumber' to identify this device - it fails silently and the device may upload without a serial, which the backend can drop. Code fix: replace the wmic call with PowerShell '(Get-CimInstance Win32_BIOS).SerialNumber'.") "Yellow"
}
if ($Findings.AsarLoadFail -and $Findings.TokenPresent) {
    Line ""
    Line (">>> ALSO: 'ERR_FAILED loading app.asar' seen in section 7d even though the token is present. The app UI breaks intermittently - users may report 'I can't open the app'. Add a Defender exclusion for %LOCALAPPDATA%\Programs\pi-focus-business-app\.") "Yellow"
}
if ($Findings.ElectronCrashes) {
    Line ""
    Line (">>> ALSO: Chromium crash dumps were found in the Electron app's Crashpad dir (section 1b). The desktop app itself has been crashing. Collect %APPDATA%\pi-focus-business-app\Crashpad\reports\ for the team.") "Yellow"
}

# --- 1.0.8 release-verification callouts (lock fix + security F-01 + freshness) ---
# Surfaced after the primary verdict: each can be a standalone reason a device
# is misbehaving (stuck Inactive, plaintext token, stale binary) even when the
# main data-path checks above look fine.
if ($Findings.SvcVersionOld -or $Findings.LockFixMissing) {
    Line ""
    Line (">>> ALSO: OLD SERVICE BUILD (< 1.0.8). This device is missing the stuck-Inactive LOCK-STATE fix and the F-01/F-02/F-03/F-09 security remediations (see the '1.0.8 RELEASE VERIFICATION' section: version/marker below 1.0.8). Redeploy 1.0.8 (Intune package) or 1.1.8 (Electron app). Until then users can show Inactive while actually working.") "Yellow"
}
if ($Findings.LockReportedLocked) {
    Line ""
    Line (">>> ALSO: the service currently reports lock state = LOCKED (live pipe GET_LOCK_STATE). If the user is actually at their desk working, this is the stuck-Inactive symptom. On 1.0.8 the lock.reconcile self-heal should clear it within a minute; if it persists on 1.0.8, capture C:\ProgramData\ProgramMonitor\debugLogs\*-WindowService.json and grep 'lock.reconcile'.") "Yellow"
}
if ($Findings.TokenPlaintext) {
    Line ""
    Line (">>> ALSO: DEVICE TOKEN STORED AS PLAINTEXT (REG_SZ) under HKCU\$HkcuHelper\DeviceApiKey. That is the pre-F-01 storage format (F-01 stores it DPAPI-encrypted as REG_BINARY). Either an old helper is running, or the Electron deviceKeyStore overwrote the encrypted value with plaintext. Update to the 1.0.8 service / 1.1.8 app so the token is re-written encrypted. (The value itself was NOT printed.)") "Yellow"
}
if ($Findings.ShaStale) {
    Line ""
    Line (">>> ALSO: SERVICE BINARY IS STALE vs the Electron manifest (service-build.json SHA256 mismatch). The app shipped one binary but a different/older WindowService.exe or HelperService.exe is on disk - a failed or partial redeploy. Reinstall/repair the PiFocus desktop app so it re-lays the shipped binaries, then confirm the SHA matches.") "Yellow"
}

# Intermittent / historical issues - shown regardless of the primary verdict,
# because the same device often has several transient problems over time.
if ($script:Notable -and $script:Notable.Count -gt 0) {
    Line ""
    Line "  Intermittent / historical issues seen in the logs (may not be active now):" "Yellow"
    foreach ($n in $script:Notable) { Line ("    - " + $n) "Yellow" }
}

#---------------------------------------------------------------- save report
# IT team asked for a predictable, per-machine location AND a STABLE filename
# instead of the user's Desktop with a timestamped filename. Reasoning:
#   - Desktop can be OneDrive-redirected (C:\Users\<u>\OneDrive\Desktop\...)
#     so collection scripts can't guess the path.
#   - Timestamped filenames (PiFocusDiag_<HOST>_20260728-121233.logs) mean
#     IT's fleet-wide log collector can't hardcode the path to fetch.
#
# Fix: single fixed filename `PiFocusDiag.logs`. Each run OVERWRITES the last.
# Timestamp + hostname are already stamped INSIDE the report body (see
# Section 0 "Run time" + "Computer" and the verdict block header), so the
# report is still self-identifying without the collector needing to guess
# the path.
#
# Fallback chain, first that succeeds wins:
#   1. C:\pifocus\                          (preferred; needs admin to CREATE
#                                            the folder the first time, but not
#                                            to write to it after)
#   2. C:\ProgramData\pifocus\              (any user can create + write here)
#   3. User's Desktop                       (last resort - always writable)
#   4. %TEMP%                               (very last resort)
Line ""
$outName = 'PiFocusDiag.logs'   # STABLE name -- overwrites each run for reliable collection

$candidates = @(
    'C:\pifocus',
    'C:\ProgramData\pifocus',
    [Environment]::GetFolderPath('Desktop'),
    $env:TEMP
)

$outPath = $null
foreach ($dir in $candidates) {
    if ([string]::IsNullOrWhiteSpace($dir)) { continue }
    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $candidate = Join-Path $dir $outName
        # Out-File overwrites by default -- exactly what we want. The previous
        # run's report is intentionally not kept (IT collection grabs the
        # freshest run every time). Add -Force so a read-only leftover file
        # from a prior version doesn't block the write.
        $script:ReportLines | Out-File -FilePath $candidate -Encoding utf8 -Force -ErrorAction Stop
        $outPath = $candidate
        break
    } catch {
        # Try next candidate silently -- fallbacks exist for exactly this case
        continue
    }
}

if ($outPath) {
    Write-Host ""
    Write-Host ("Full report saved to: {0}" -f $outPath) -ForegroundColor Green
    Write-Host "Please send that file back to the PiFocus team." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Could not write report file to ANY location (C:\pifocus, C:\ProgramData\pifocus, Desktop, %TEMP%). Copy the console output above manually." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Backend upload of the report (diagnostics ingest -- 3-call contract).
# Intune cannot read a file back off the device, so we ALSO push the same
# report to the backend. No auth (the script runs as SYSTEM and has none).
#   1) POST /diagnostics/upload-url  -> reportId + fileKey + presigned uploadUrl + mimeType
#   2) PUT the file to uploadUrl     -> Content-Type MUST equal mimeType (text/plain; S3 signs it)
#   3) POST /diagnostics/{id}/uploaded -> flips the row PENDING -> UPLOADED
# The SERVER picks the key -- one per run, so two diagnoses never overwrite and
# there is no duplicate-key retry. IT reads a device's runs back with
# GET /diagnostics?identifier=<serial-or-intuneDmId>. Entirely best-effort:
# any failure appends one line and the script finishes normally; the local
# file stays the primary artefact.
#
# NOTE: uploads to STAGE ($DiagUploadHost) by deliberate choice; the section-6
# connectivity probe still targets PROD (where the AGENT sends its data).
# ---------------------------------------------------------------------------
if (-not $outPath) {
    Write-Host ""
    Write-Host "[WARN] No local report file was written, so there is nothing to upload. Copy the console output above manually." -ForegroundColor Yellow
} else {
    # Resolve identity BEFORE the try, so a WMI/registry failure shows as itself,
    # not as an upload error. Send the SAME identifier the enrolment writes into
    # the portal's device document: the BIOS serial on some machines, the Intune
    # DM id on others. Send both when both exist -- the backend matches on either;
    # at least one is required.
    $serial = $null
    try { $sn = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber; if ($sn) { $serial = "$sn".Trim() } } catch {}
    if ([string]::IsNullOrWhiteSpace($serial)) { $serial = $null }

    # Intune DM id = DeviceClientId of the "MS DM Server" enrolment (a GUID). This
    # is what the portal keys managed PCs on; NOT EntDMID. Guard hard so a missing
    # value never becomes an empty object in the JSON body.
    $dmId = $null
    try {
        $enr = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Enrollments\*' -ErrorAction SilentlyContinue |
               Where-Object { $_.ProviderID -eq 'MS DM Server' -and $_.DeviceClientId }
        if ($enr) { $dmId = "$((@($enr)[0]).DeviceClientId)".Trim() }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($dmId)) { $dmId = $null }

    # agentVersion (optional) = the running service binary's FileVersion.
    $agentVersion = $null
    try { if ($RelSvcExe -and (Test-Path -LiteralPath $RelSvcExe)) { $agentVersion = (Get-Item -LiteralPath $RelSvcExe).VersionInfo.FileVersion } } catch {}

    # Surface exactly what will be sent + what IT queries back with. (The serial
    # is already shown in section 0; the DM id is a device GUID, not a secret.)
    Write-Host ""
    Write-Host ("  Diagnostics upload identity:  serialNumber={0}  intuneDmId={1}" -f `
        $(if ($serial) { $serial } else { '(none)' }), $(if ($dmId) { $dmId } else { '(none - not Intune-enrolled)' })) -ForegroundColor Cyan

    if (-not $serial -and -not $dmId) {
        Write-Host "[WARN] No BIOS serial and no Intune DM id on this device -- the backend needs at least one to file the report, so upload was skipped. The local file is still valid." -ForegroundColor Yellow
    } else {
        try {
            # Old boxes default below TLS 1.2; the backend/S3 endpoints require it.
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

            $diagBase = "https://$DiagUploadHost/pi-os-backend/v1/pi-focus-business/diagnostics"
            $size     = (Get-Item -LiteralPath $outPath).Length

            # Body carries ONLY the identifiers we actually have (never an empty
            # object -- that fails the backend's type check).
            $slot = @{
                deviceName = $env:COMPUTERNAME
                fileSize   = [int]$size
                capturedAt = (Get-Date).ToUniversalTime().ToString('o')
            }
            if ($serial)       { $slot.serialNumber = $serial }
            if ($dmId)         { $slot.intuneDmId   = $dmId }
            if ($agentVersion) { $slot.agentVersion = "$agentVersion" }

            # STEP 1 -- ask for an upload slot.
            $ticket = Invoke-RestMethod -Method Post -Uri "$diagBase/upload-url" `
                -ContentType 'application/json' -Body ($slot | ConvertTo-Json -Compress) `
                -TimeoutSec 60 -ErrorAction Stop
            # Response is wrapped: { data: { reportId, uploadUrl, mimeType, fileKey, ... }, success }.
            # Fall back to a flat body in case the shape ever changes.
            $td = if ($ticket.data) { $ticket.data } else { $ticket }
            if ([string]::IsNullOrWhiteSpace($td.uploadUrl) -or [string]::IsNullOrWhiteSpace($td.reportId)) {
                throw 'upload-url response missing uploadUrl / reportId'
            }
            $ctype = if ($td.mimeType) { "$($td.mimeType)" } else { 'text/plain' }

            # STEP 2 -- PUT the raw file. -InFile (NOT -Body) keeps the bytes verbatim
            # so the count matches fileSize; Content-Type MUST equal mimeType (S3 signs
            # it, a mismatch is a 403). Silence the PS 5.1 progress bar; restore after.
            $prevProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Method Put -Uri $td.uploadUrl -InFile $outPath `
                    -ContentType $ctype -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop | Out-Null
            } finally {
                $ProgressPreference = $prevProgress
            }

            # STEP 3 -- confirm (PENDING -> UPLOADED). NO body: the backend reads the
            # object's real size from S3 itself. Call it only after the PUT returned
            # 200; if the PUT never landed this answers 400 and the row stays PENDING.
            Invoke-RestMethod -Method Post -Uri ("{0}/{1}/uploaded" -f $diagBase, $td.reportId) `
                -TimeoutSec 60 -ErrorAction Stop | Out-Null

            $idUsed = if ($serial) { $serial } else { $dmId }
            $script:ReportLines += "Diagnostics uploaded: reportId=$($td.reportId) key=$($td.fileKey)"
            Write-Host ""
            Write-Host "==============================================================================" -ForegroundColor Green
            Write-Host ("  Report uploaded to the backend (reportId {0})." -f $td.reportId) -ForegroundColor Green
            Write-Host ("  IT reads it back:  GET /pi-os-backend/v1/pi-focus-business/diagnostics?identifier={0}" -f $idUsed) -ForegroundColor Green
            Write-Host "  (needs the read:diagnostics permission; newest run first, each row carries its downloadUrl)" -ForegroundColor Green
            Write-Host "==============================================================================" -ForegroundColor Green
        }
        catch {
            $script:ReportLines += "Diagnostics upload failed: $($_.Exception.Message)"
            Write-Host ""
            Write-Host ("[WARN] Backend upload failed: {0}. The local report at {1} is still valid -- send that instead." -f $_.Exception.Message, $outPath) -ForegroundColor Yellow
        }
    }
}

# Tell IT exactly which folders to zip-and-attach for deeper investigation.
# Existence-tested so the list only shows paths actually present on this device.
Write-Host ""
Write-Host "If the PiFocus team asks for more, please also zip and attach these (whichever exist):" -ForegroundColor Cyan
$ToCollect = @(
    $InstallLog,
    $DebugLogDir,
    $ReportsDir,
    "C:\ProgramData\Microsoft\Windows\WER\ReportArchive\",
    "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\"
)
if ($ElectronAppLog)   { $ToCollect += $ElectronAppLog }
if ($ElectronUserData) {
    $ToCollect += (Join-Path $ElectronUserData "Crashpad\reports\")
    $ToCollect += (Join-Path $ElectronUserData "Crash Reports\reports\")
}
if ($ElectronUserTemp) { $ToCollect += (Join-Path $ElectronUserTemp "pifocus_service_*.log") }
foreach ($p in $ToCollect) {
    $exists = $false
    try {
        if ($p -match "\*") { $exists = $null -ne (Get-ChildItem $p -ErrorAction SilentlyContinue) }
        else                { $exists = Test-Path $p }
    } catch {}
    $mark = if ($exists) { "[exists]" } else { "[absent]" }
    $color = if ($exists) { "Gray" } else { "DarkGray" }
    Write-Host ("  $mark  $p") -ForegroundColor $color
}
