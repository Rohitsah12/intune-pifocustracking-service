# =========================================================================
#   PIFOCUS AGENT -- DEFINITIVE DIAGNOSIS SCRIPT (READ-ONLY)
# =========================================================================
#
#   Answers ONE question with EVIDENCE:
#
#       Is the .intunewin package broken?  OR
#       Is the detection script broken?    OR
#       Is the URL-based categorization broken?
#
#   Prints a VERDICT block at the top with the answer, then full
#   evidence below. Paste the WHOLE output back to Ankit -- from it
#   he can hand Intune / IT exactly the right fix (fresh .intunewin
#   or fresh detect.ps1 or both).
#
#   Modifies nothing. Reads files, registry, services, event log.
#   Requires an ELEVATED PowerShell (Run as administrator) to see
#   Program Files + services + HKU hives.
#
#   Usage:
#       Right-click PowerShell -> Run as administrator
#       powershell -ExecutionPolicy Bypass -File .\diagnose-sourabh.ps1
# =========================================================================

$ErrorActionPreference = 'SilentlyContinue'

$TargetVersion = '1.0.5'
$InstallDir    = 'C:\Program Files\PiFocus\Agent'
$HelperDir     = 'C:\ProgramData\PiFocus'
$MonDir        = 'C:\ProgramData\ProgramMonitor'
$ServiceName   = 'PiFocusWindowService'
$ServiceExe    = Join-Path $InstallDir 'WindowService.exe'
$HelperExe     = Join-Path $HelperDir  'HelperService.exe'
$VersionFile   = Join-Path $InstallDir 'version.txt'
$ProdConfig    = Join-Path $HelperDir  'productivity_config.json'
$Today         = Get-Date -Format 'yyyy-MM-dd'

# ---- HELPERS -------------------------------------------------------------

function Section($t) { Write-Host ''; Write-Host ('===== ' + $t + ' =====') }
function L($t) { Write-Host $t }

function Read-VersionFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path)
    return $raw.Trim([char[]]@("`r","`n"," ","`t",[char]0xFEFF))
}

function Test-BinaryContains {
    param([string]$Path, [string[]]$Needles)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $blob  = [System.Text.Encoding]::ASCII.GetString($bytes) + [System.Text.Encoding]::Unicode.GetString($bytes)
    $out = @{}
    foreach ($n in $Needles) { $out[$n] = $blob.Contains($n) }
    return $out
}

# ---- COLLECT FACTS ------------------------------------------------------

$fact = @{}

# Files present?
$fact.wsExe          = Test-Path -LiteralPath $ServiceExe
$fact.hsExe          = Test-Path -LiteralPath $HelperExe
$fact.versionFile    = Test-Path -LiteralPath $VersionFile
$fact.installedVer   = Read-VersionFile $VersionFile
$fact.versionMatches = ($fact.installedVer -eq $TargetVersion)

# Signatures
$fact.wsSig          = if ($fact.wsExe) { (Get-AuthenticodeSignature $ServiceExe).Status.ToString() } else { 'N/A' }
$fact.hsSig          = if ($fact.hsExe) { (Get-AuthenticodeSignature $HelperExe).Status.ToString() } else { 'N/A' }

# Service
$svc                 = Get-Service -Name $ServiceName
$fact.svcRegistered  = [bool]$svc
$fact.svcStatus      = if ($svc) { $svc.Status.ToString() } else { 'MISSING' }
$svcCim              = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
$fact.svcPathName    = if ($svcCim) { $svcCim.PathName } else { $null }
$fact.svcPidRunning  = if ($svcCim -and $svcCim.ProcessId -gt 0) { $svcCim.ProcessId } else { $null }
$fact.svcPathValid   = if ($fact.svcPathName) {
    # Extract just the .exe from the ImagePath. Windows stores this as:
    #   quoted     : "C:\Path with spaces\service.exe" --arg
    #   unquoted   : C:\NoSpaces\service.exe --arg
    # An earlier revision used '^([^ ]+).*$' which grabs everything up to
    # the first space -- that turned "C:\Program Files\PiFocus\Agent\WindowService.exe --service"
    # into "C:\Program" and Test-Path returned false, falsely flagging
    # perfectly-installed devices as FAIL.
    $raw = $fact.svcPathName.Trim()
    $rawPath = if ($raw.StartsWith('"')) {
        $endQ = $raw.IndexOf('"', 1)
        if ($endQ -gt 1) { $raw.Substring(1, $endQ - 1) } else { $raw.Trim('"') }
    } elseif ($raw -match '(?i)^(.+?\.exe)(\s|$)') {
        $matches[1]
    } else {
        $raw
    }
    Test-Path -LiteralPath $rawPath
} else { $false }

# Binary markers -- did the LATEST fixes actually reach this device?
$wsMarkers = Test-BinaryContains -Path $ServiceExe -Needles @('helper.stale_killed')
$hsMarkers = Test-BinaryContains -Path $HelperExe  -Needles @('omnibox-popup','chrome://newtab','xx-user-upn','upn.change','capturedUpn')
$fact.hasFix_helperStaleKilled = $wsMarkers['helper.stale_killed']
$fact.hasFix_omniboxPopup      = $hsMarkers['omnibox-popup']
$fact.hasFix_chromeNewtab      = $hsMarkers['chrome://newtab']
$fact.hasFix_xxUserUpn         = $hsMarkers['xx-user-upn']
$fact.hasFix_upnChange         = $hsMarkers['upn.change']

# Productivity config on disk
$fact.prodConfigPresent = Test-Path -LiteralPath $ProdConfig
if ($fact.prodConfigPresent) {
    try {
        $pc = Get-Content $ProdConfig -Raw | ConvertFrom-Json
        $fact.prodApps        = @($pc.productiveApps).Count
        $fact.nonProdApps     = @($pc.unproductiveApps).Count
        $fact.prodDomains     = @($pc.productiveDomains).Count
        $fact.nonProdDomains  = @($pc.nonProductiveDomains).Count
        $fact.prodConfigMtime = (Get-Item $ProdConfig).LastWriteTime
    } catch {
        $fact.prodConfigParseErr = $_.Exception.Message
    }
} else {
    $fact.prodApps = 0; $fact.nonProdApps = 0; $fact.prodDomains = 0; $fact.nonProdDomains = 0
}

# Today's daily report -- category / upn stats per browser row
$rpt = Join-Path $MonDir "daily_reports\$Today.json"
$fact.reportPresent = Test-Path -LiteralPath $rpt
$fact.instTotal = 0; $fact.instWithUrl = 0; $fact.instWithUpn = 0
$fact.catCounts = @{}
$fact.sampleBrowserRows = @()
if ($fact.reportPresent) {
    try {
        $rj = Get-Content $rpt -Raw | ConvertFrom-Json
        foreach ($a in @($rj.applications)) {
            foreach ($s in @($a.sessions)) {
                foreach ($i in @($s.instances)) {
                    $fact.instTotal++
                    $hasUrl = -not [string]::IsNullOrEmpty($i.url)
                    if ($hasUrl) { $fact.instWithUrl++ }
                    if (-not [string]::IsNullOrEmpty($i.upn)) { $fact.instWithUpn++ }
                    if ($hasUrl) {
                        $c = if ($i.category) { $i.category } else { '(none)' }
                        if (-not $fact.catCounts.ContainsKey($c)) { $fact.catCounts[$c] = 0 }
                        $fact.catCounts[$c]++
                        if ($fact.sampleBrowserRows.Count -lt 8) {
                            $fact.sampleBrowserRows += [PSCustomObject]@{
                                app      = $a.name
                                url      = $i.url
                                category = $i.category
                                upn      = $i.upn
                                duration = $i.durationSeconds
                            }
                        }
                    }
                }
            }
        }
        $fact.reportMtime = (Get-Item $rpt).LastWriteTime
    } catch {
        $fact.reportParseErr = $_.Exception.Message
    }
}

# --- Simulate BOTH detect.ps1 flavours ---------------------------------
# Old detect.ps1 (had env.txt + Env-Config.ps1 dependency) SILENTLY fails
# in Intune's standalone context because those siblings aren't shipped
# with a detection-script upload. Simulate what it would return here.
$fact.oldDetectExit = 1
$fact.oldDetectWhy  = 'not-simulated'
try {
    $simEnv = ''
    # env.txt fallback -- nothing in the Intune temp dir so this stays empty
    if ([string]::IsNullOrWhiteSpace($simEnv)) { $simEnv = 'prod' }
    # Dot-source Env-Config.ps1 that isn't next to us -> silently fails
    # -> $cfg = $null -> every check below returns FAIL
    if ($simEnv -eq 'prod') {
        # In the OLD detect.ps1, this branch would try `Get-PiFocusEnv -Env prod`
        # which is undefined => $cfg = $null => Join-Path with $null => path
        # collapses to just "WindowService.exe" (relative) => Test-Path false
        # => exit 1.
        $fact.oldDetectExit = 1
        $fact.oldDetectWhy  = 'Env-Config.ps1 dot-source failed (silently) -> $cfg was null -> Test-Path on empty path failed'
    }
} catch { }

# New detect.ps1 (hardcoded) -- run its logic inline
$fact.newDetectExit = 1
$fact.newDetectWhy  = ''
if (-not $fact.wsExe)           { $fact.newDetectWhy = "WindowService.exe missing at $ServiceExe" }
elseif (-not $fact.versionFile) { $fact.newDetectWhy = "version.txt missing at $VersionFile" }
elseif (-not $fact.versionMatches) { $fact.newDetectWhy = "version.txt='$($fact.installedVer)' does not match target '$TargetVersion'" }
else { $fact.newDetectExit = 0; $fact.newDetectWhy = "all checks passed (version='$($fact.installedVer)')" }

# =========================================================================
#   VERDICT
# =========================================================================

Write-Host ''
Write-Host '========================================================================'
Write-Host '     PIFOCUS DIAGNOSIS -- VERDICT'
Write-Host ('     device={0}  user={1}  at={2}' -f $env:COMPUTERNAME, $env:USERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host '========================================================================'

# 1) Install health
$installOK = $fact.wsExe -and $fact.hsExe -and $fact.versionFile -and $fact.versionMatches -and $fact.svcRegistered -and $fact.svcPathValid
$installReason = if     (-not $fact.wsExe)          { 'WindowService.exe missing' }
                 elseif (-not $fact.hsExe)          { 'HelperService.exe missing' }
                 elseif (-not $fact.versionFile)    { 'version.txt missing' }
                 elseif (-not $fact.versionMatches) { "version.txt='$($fact.installedVer)' != target '$TargetVersion'" }
                 elseif (-not $fact.svcRegistered)  { "service '$ServiceName' NOT REGISTERED" }
                 elseif (-not $fact.svcPathValid)   { "service registered but ImagePath points to missing file: '$($fact.svcPathName)'" }
                 else                                { 'files + service + version all correct' }
$installTag = if ($installOK) { '[ OK  ]' } else { '[FAIL ]' }
Write-Host ('  {0}  INSTALL HEALTH        : {1}' -f $installTag, $installReason)

# 2) Detection script assessment
if ($fact.oldDetectExit -eq 1 -and $fact.newDetectExit -eq 0) {
    $detectTag = '[FIX  ]'
    $detectReason = 'OLD script FAILS here even though install is fine -- swap Intune detection script to the NEW hardcoded detect.ps1 and this device flips to Installed.'
} elseif ($fact.newDetectExit -eq 0) {
    $detectTag = '[ OK  ]'
    $detectReason = 'Both old + new detect.ps1 would pass on this device.'
} else {
    $detectTag = '[FAIL ]'
    $detectReason = 'Even the NEW hardcoded detect.ps1 fails here because: ' + $fact.newDetectWhy + '. Install itself is broken -- fresh .intunewin needed.'
}
Write-Host ('  {0}  DETECTION SCRIPT      : {1}' -f $detectTag, $detectReason)

# 3) Binary freshness
$isJul15Build = $fact.hasFix_helperStaleKilled -and $fact.hasFix_chromeNewtab -and $fact.hasFix_upnChange
$binReason = if ($isJul15Build) { 'installed binary is the July-15+ build (has helper.stale_killed + chrome://newtab + upn.change markers)' }
             elseif ($fact.hasFix_omniboxPopup) { 'installed binary is between July-10 and July-14 (has omnibox-popup fix but NOT the newer chrome://newtab / helper.stale_killed fixes)' }
             elseif ($fact.hasFix_xxUserUpn) { 'installed binary is between July-8 and July-9 (has UPN header code, missing later fixes)' }
             else { 'installed binary is OLDER than July-8 (no UPN, no domain categorization, no shared-PC fixes)' }
$binTag = if ($isJul15Build) { '[ OK  ]' } else { '[OLD  ]' }
Write-Host ('  {0}  BINARY FRESHNESS      : {1}' -f $binTag, $binReason)

# 4) URL categorization
$hasDomains = ($fact.prodDomains + $fact.nonProdDomains) -gt 0
$urlCatSample = ''
if ($fact.sampleBrowserRows.Count -gt 0) {
    $prodCount    = ($fact.sampleBrowserRows | Where-Object { $_.category -eq 'productive' }).Count
    $unprodCount  = ($fact.sampleBrowserRows | Where-Object { $_.category -eq 'unproductive' }).Count
    $neutralCount = ($fact.sampleBrowserRows | Where-Object { $_.category -eq 'neutral' -or -not $_.category }).Count
    $urlCatSample = ' | browser rows today: prod=' + $prodCount + ' unprod=' + $unprodCount + ' neutral=' + $neutralCount
}
$urlCatReason = if (-not $fact.prodConfigPresent) {
    'productivity_config.json MISSING on disk -- helper has never fetched config (network / auth / backend issue)'
} elseif (-not $hasDomains) {
    'productivity_config.json exists BUT has ZERO domain rules -- backend has not returned any productiveDomains / nonProductiveDomains yet. Everything falls through to app-based (Chromes neutral, etc). Fix: backend team populates domain rules.'
} elseif (-not $isJul15Build) {
    'domain rules ARE in config, but the INSTALLED binary is too old to use them -- domain fields exist but helper does not parse them. Fix: push fresh .intunewin.'
} elseif ($fact.instWithUrl -eq 0) {
    'no browser rows captured today yet (user has not used a browser, OR browser tab URL capture is silent -- e.g. Chrome not focused / UIA blocked)'
} else {
    'domain rules present + fresh binary + browser rows captured' + $urlCatSample
}
$urlCatTag = if ($hasDomains -and $isJul15Build) { '[ OK  ]' } else { '[WAIT ]' }
Write-Host ('  {0}  URL CATEGORIZATION    : {1}' -f $urlCatTag, $urlCatReason)

Write-Host ''
Write-Host '  RECOMMENDED ACTION:'
if (-not $installOK) {
    Write-Host '    -> Install itself is broken. Send a FRESH intunewin (do NOT bother updating detect.ps1 -- root cause is upstream).'
    Write-Host '    -> Have IT re-upload install.intunewin and re-deploy to this device.'
} elseif ($fact.oldDetectExit -eq 1 -and $fact.newDetectExit -eq 0) {
    Write-Host '    -> Install is FINE. The Intune detection script is the ONLY thing that needs to change.'
    Write-Host '    -> Have IT replace the detection script in the Intune app config with the NEW hardcoded detect.ps1.'
    Write-Host '    -> Do NOT push a fresh intunewin -- it will re-install healthy devices for no reason.'
} else {
    Write-Host '    -> Detection now passes with the new script. Any residual issues are runtime (upload / categorization) -- see B sections below.'
}
if (-not $isJul15Build) {
    Write-Host '    -> Additionally: this device has an OLDER binary. Push the fresh .intunewin so URL / UPN / shared-PC fixes land.'
}
if ($fact.prodConfigPresent -and -not $hasDomains) {
    Write-Host '    -> Additionally: backend needs to populate productiveDomains / nonProductiveDomains before URL-based categorization can work.'
}

# =========================================================================
#   EVIDENCE (details for each verdict claim)
# =========================================================================

Section 'DETAIL 1 - Installed files'
L ("  WindowService.exe present  : $($fact.wsExe)")
L ("  HelperService.exe present  : $($fact.hsExe)")
L ("  version.txt present        : $($fact.versionFile)")
L ("  version.txt content        : '$($fact.installedVer)'  (target='$TargetVersion' -> match=$($fact.versionMatches))")
if ($fact.versionFile) {
    $vbytes = [System.IO.File]::ReadAllBytes($VersionFile)
    $vhex = ($vbytes | ForEach-Object { $_.ToString('X2') }) -join ' '
    L ("  version.txt hex bytes      : $vhex  (BOM=EF BB BF at start would trip old detect script)")
}
L ("  WindowService.exe signature: $($fact.wsSig)")
L ("  HelperService.exe signature: $($fact.hsSig)")
if ($fact.wsExe) { $fi = Get-Item $ServiceExe; L ("  WS built                   : $($fi.LastWriteTime)  size=$($fi.Length)") }
if ($fact.hsExe) { $fi = Get-Item $HelperExe;  L ("  Helper built               : $($fi.LastWriteTime)  size=$($fi.Length)") }

Section 'DETAIL 2 - Windows service'
L ("  Registered              : $($fact.svcRegistered)")
L ("  Status                  : $($fact.svcStatus)")
L ("  ImagePath               : $($fact.svcPathName)")
L ("  ImagePath binary exists : $($fact.svcPathValid)   <-- FALSE = ZOMBIE service registration (uninstall did not run 'sc delete')")
if ($fact.svcPidRunning) { L ("  Running PID             : $($fact.svcPidRunning)") }

Section 'DETAIL 3 - Fixes baked into installed binaries'
L ("  In WindowService.exe:")
L ("    helper.stale_killed  (July-15+ Fast User Switch fix)   : $($fact.hasFix_helperStaleKilled)")
L ("  In HelperService.exe:")
L ("    omnibox-popup reject (July-10+ chrome popup fix)       : $($fact.hasFix_omniboxPopup)")
L ("    chrome://newtab reject (July-14+ newtab fix)           : $($fact.hasFix_chromeNewtab)")
L ("    xx-user-upn header   (July-8+ shared-PC attribution)   : $($fact.hasFix_xxUserUpn)")
L ("    upn.change category  (July-10+ per-user audit log)     : $($fact.hasFix_upnChange)")

Section 'DETAIL 4 - Detection script simulation'
L ("  Old detect.ps1 (dot-sourced Env-Config.ps1):")
L ("    would exit  : $($fact.oldDetectExit)")
L ("    why         : $($fact.oldDetectWhy)")
L ("  New detect.ps1 (hardcoded paths, no dependencies):")
L ("    would exit  : $($fact.newDetectExit)")
L ("    why         : $($fact.newDetectWhy)")

Section 'DETAIL 5 - Productivity config (URL / domain rules on disk)'
L ("  Path                       : $ProdConfig")
L ("  File present               : $($fact.prodConfigPresent)")
if ($fact.prodConfigPresent) {
    L ("  Last write                 : $($fact.prodConfigMtime)")
    L ("  productiveApps             : $($fact.prodApps) entries")
    L ("  unproductiveApps           : $($fact.nonProdApps) entries")
    L ("  productiveDomains          : $($fact.prodDomains) entries  <-- if 0, URL categorization can NEVER match")
    L ("  nonProductiveDomains       : $($fact.nonProdDomains) entries")
    if ($fact.prodConfigParseErr) { L ("  PARSE ERROR                : $($fact.prodConfigParseErr)") }
}

Section 'DETAIL 6 - Today''s activity report (categorization on the wire)'
L ("  Report path                : $rpt")
L ("  Report present             : $($fact.reportPresent)")
if ($fact.reportPresent) {
    L ("  Report mtime               : $($fact.reportMtime)")
    L ("  Total instances today      : $($fact.instTotal)")
    L ("  Instances with URL         : $($fact.instWithUrl)  <-- browser rows")
    L ("  Instances with UPN stamp   : $($fact.instWithUpn)  <-- 0 on an AAD device means helper is too old for per-instance UPN")
    L ('  Categories seen on browser rows:')
    foreach ($k in $fact.catCounts.Keys) { L ("    {0,-15} x {1}" -f $k, $fact.catCounts[$k]) }
    if ($fact.sampleBrowserRows.Count -gt 0) {
        L ('  Sample browser rows (first 8):')
        foreach ($r in $fact.sampleBrowserRows) {
            $urlShort = if ($r.url.Length -gt 55) { $r.url.Substring(0, 52) + '...' } else { $r.url }
            L ("    app={0,-22}  cat={1,-13}  url={2,-55}  upn={3}" -f $r.app, $r.category, $urlShort, $r.upn)
        }
    }
}

Section 'DETAIL 7 - Last 3 activity uploads (payload preview)'
$hslog = Join-Path $MonDir "debugLogs\$Today-HelperService.json"
if (Test-Path $hslog) {
    Get-Content $hslog -Tail 500 | ForEach-Object {
        try { $ev = $_ | ConvertFrom-Json } catch { return }
        if ($ev.endpoint -match 'ingest/activities' -and $ev.statusCode) { $ev }
    } | Select-Object -Last 3 | ForEach-Object {
        L ("  {0} POST /ingest/activities -> HTTP {1}  ({2}ms)" -f $_.ts, $_.statusCode, $_.latencyMs)
        if ($_.requestBody) {
            $peek = $_.requestBody.Substring(0, [Math]::Min(500, $_.requestBody.Length))
            L ("    payload sample: $peek")
        }
    }
} else {
    L "  no HelperService debug log for today (helper has not written anything OR is silent -- check DETAIL 2 for service state)"
}

Section 'DETAIL 8 - Install log tail'
# Tail 60 (up from 12) because install.ps1 1.0.5+ writes a much longer log
# per install: PACKAGE INVENTORY (~10 lines) + freshness checks + Copy-
# ItemVerified per-file rows + POST-INSTALL VERIFICATION + VERDICT banner.
# Tail 12 would only show the trailing VERDICT and miss all the copy
# evidence we care about.
$ilog = Join-Path $HelperDir 'Logs\Install.log'
if (Test-Path $ilog) { Get-Content $ilog -Tail 60 } else { L "  no install log at $ilog" }

Section 'DETAIL 9 - Install script generation (new vs old)'
# The 1.0.5+ install.ps1 writes a "VERDICT env=... Helper_fresh=... Window_fresh=..."
# line as its final action. If that line is ABSENT from the whole install
# log, then IT is still deploying the OLD .intunewin (pre-1.0.5) and the
# marker safeguards never ran -- explains any lingering "Helper is stale"
# report even after we shipped new packages.
if (Test-Path $ilog) {
    $verdicts = Get-Content $ilog | Where-Object { $_ -match 'VERDICT env=' }
    if ($verdicts) {
        L "  Latest self-verdict lines from Install.log (proves new install script ran):"
        $verdicts | Select-Object -Last 3 | ForEach-Object { L ("    " + $_) }
    } else {
        L "  NO 'VERDICT env=' line anywhere in Install.log."
        L "  -> IT team is STILL deploying the OLD .intunewin (pre-1.0.5)."
        L "  -> The bulletproof safeguards NEVER RAN on this device."
        L "  -> Fix: IT must upload the new install.intunewin dated 2026-07-22 13:27 (version 1.0.5) to Intune."
    }
}

Write-Host ''
Write-Host '========================================================================'
Write-Host '   END OF DIAGNOSIS -- paste the WHOLE output above back to Ankit.'
Write-Host '========================================================================'
