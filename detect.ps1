# PiFocus Agent - Intune Detection Script (v1.0.6, PROD)
# ===========================================================================
# Exit 0 => Intune considers the app INSTALLED (correct version present).
# Exit 1 (or any output when checking custom) => Intune considers it MISSING.
#
# INTENTIONALLY MINIMAL:
#   - No parameters. No env-awareness. No dot-sourcing. No fallback logic.
#     Intune runs detection scripts STANDALONE from a temp folder that has
#     no sibling files -- any external dependency (env.txt, Env-Config.ps1)
#     silently fails and the script mis-reports.
#   - No service-state check. Whether the service is Running/Stopped at
#     the moment of detection is a RUNTIME state, not an INSTALL state.
#     If we check "-Status Running" and the service happens to be stopped
#     when Intune polls (crash-loop, admin manually stopped, boot-time
#     race), Intune concludes "not installed" and triggers a redeploy --
#     which is worse than the transient stopped state.
#   - Just: does the versioned executable + version file exist, and does
#     the version match? If yes => installed. Everything else is out of
#     scope for the DETECTION script (use the DIAGNOSIS script for
#     runtime health).
# ===========================================================================

$TargetVersion = '1.0.6'
$InstallDir    = 'C:\Program Files\PiFocus\Agent'
$ServiceExe    = Join-Path $InstallDir 'WindowService.exe'
$VersionFile   = Join-Path $InstallDir 'version.txt'

# --- 1. Executable present? ------------------------------------------------
if (-not (Test-Path -LiteralPath $ServiceExe)) {
    Write-Host "NOT INSTALLED: $ServiceExe missing"
    exit 1
}

# --- 2. version.txt present? -----------------------------------------------
if (-not (Test-Path -LiteralPath $VersionFile)) {
    Write-Host "NOT INSTALLED: $VersionFile missing"
    exit 1
}

# --- 3. version matches target? --------------------------------------------
# Read the file, strip any BOM / CR / LF / whitespace on either end. We do
# NOT trust Get-Content -Raw's TrimEnd -- version.txt sometimes ends with
# CRLF and sometimes just LF depending on which build machine wrote it.
$raw = [System.IO.File]::ReadAllText($VersionFile)
$installedVersion = $raw.Trim([char[]]@("`r","`n"," ","`t",[char]0xFEFF))

if ($installedVersion -ne $TargetVersion) {
    Write-Host "NOT INSTALLED: version.txt='$installedVersion' does not match target '$TargetVersion'"
    exit 1
}

# --- 4. INSTALLED (Intune expects any STDOUT for a positive detection) -----
Write-Host "INSTALLED: PiFocus Agent version $installedVersion"
exit 0
