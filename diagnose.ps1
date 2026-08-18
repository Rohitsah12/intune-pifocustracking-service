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
if ($ConsoleSid) {
    try {
        $p = Get-ItemProperty ("Registry::HKEY_USERS\{0}\{1}" -f $ConsoleSid, $HkcuHelper) -ErrorAction Stop
        if ($p.DeviceApiKey) { $token = [string]$p.DeviceApiKey; $tokenSrc = ("HKU\{0}\{1}" -f $ConsoleSid, $HkcuHelper) }
    } catch {}
}
if (-not $token) {
    try {
        $p = Get-ItemProperty ("HKCU:\{0}" -f $HkcuHelper) -ErrorAction Stop
        if ($p.DeviceApiKey) { $token = [string]$p.DeviceApiKey; $tokenSrc = ("HKCU\{0}" -f $HkcuHelper) }
    } catch {}
}
$Findings.TokenPresent = [bool]$token
if ($token) {
    $looksJwt = $token.Contains(".")
    Check "Device token present" "PASS" ("{0}  [{1}]" -f (Mask $token),$tokenSrc)
    if (-not $looksJwt) { Check "Token format" "WARN" "no '.' separator - may be malformed" }
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
    if ($Findings.AsarLoadFail) {
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
    $msg = "DATA IS REACHING THE BACKEND (last activities upload HTTP $luc). If the dashboard still shows 0 hrs for this user, it is NOT a capture/upload failure on this device - escalate to backend/reporting with the device serial, the active user ($ConsoleUser), and the last-upload timestamp (likely a user/device mapping or time-window issue)."
    if ($Findings.TransportFail) { $msg += "  (Heads-up: intermittent upload failures were also seen historically - see the intermittent-issues list below - but current uploads succeed.)" }
    $verdict.Add($msg)
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
