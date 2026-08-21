param(
    [ValidateSet('prod','stage')]
    [string]$Env = 'prod',

    [string]$SolutionDir = 'C:\PiBusiness5\PiBusiness\PiBusiness_Solution\PiBusiness_Solution',

    # Skip the MSBuild step (reuse existing binaries in x64\Release[-Stage]\).
    [switch]$SkipBuild,

    # Skip the .zip of the staging folder. Off by default: producing a
    # zip is the whole point of this one-liner (hand it to a tester and
    # they run install.ps1 after extracting). Pass -NoZip to suppress.
    [switch]$NoZip,

    # Skip the IntuneWinAppUtil step. Off by default (we still produce
    # the .intunewin so Intune deploys can use it), but useful when the
    # tool isn't present or you only want the raw folder + zip.
    [switch]$NoIntune
)

# Build-Package.ps1
#
# Produces a per-env deployable package. Single command from source to
# shareable artifact.
#
#   .\Build-Package.ps1 -Env stage
#     -> _package_<version>_stage\               (raw folder, run install.ps1)
#     -> _package_<version>_stage.zip            (share with testers)
#     -> dist_intunewin\PiFocusAgent-<v>-stage.intunewin  (Intune deploy)
#
# What it does:
#   1. (unless -SkipBuild) invokes MSBuild for the matching solution config.
#   2. Copies the freshly-built C++ binaries + the runtime redist DLLs +
#      install.ps1/detect.ps1/uninstall.ps1/Env-Config.ps1 into a staging
#      folder next to this script.
#   3. Zips the staging folder (unless -Zip:$false).
#   4. (unless -NoIntune) invokes IntuneWinAppUtil to wrap the folder
#      into an .intunewin and renames to include env + version.

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Env-Config.ps1')
$cfg = Get-PiFocusEnv -Env $Env

$msbuildConfig = if ($Env -eq 'stage') { 'Release-Stage' } else { 'Release' }
$binOutDir     = Join-Path $SolutionDir "x64\$msbuildConfig"

$versionFile = Join-Path $PSScriptRoot 'version.txt'
if (-not (Test-Path $versionFile)) {
    throw "version.txt missing at $versionFile"
}
$version = (Get-Content $versionFile -Raw).Trim()

Write-Host "==== Build-Package.ps1 (env=$($cfg.EnvName) version=$version) ===="

# --- 1. Build C++ solution ---------------------------------------------------
if (-not $SkipBuild) {
    $msbuild = "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\amd64\MSBuild.exe"
    if (-not (Test-Path $msbuild)) {
        $msbuild = 'MSBuild.exe'
    }
    Write-Host "Building solution (Configuration=$msbuildConfig)..."
    & $msbuild (Join-Path $SolutionDir 'PiBusiness_Solution.sln') `
        -m `
        -p:Configuration=$msbuildConfig `
        -p:Platform=x64 `
        -v:m `
        -nologo
    if ($LASTEXITCODE -ne 0) {
        throw "MSBuild failed (Configuration=$msbuildConfig)"
    }
}

foreach ($required in @('WindowService.exe','HelperService.exe','libcrypto-3-x64.dll','libssl-3-x64.dll')) {
    $p = Join-Path $binOutDir $required
    if (-not (Test-Path $p)) { throw "Build output missing: $p" }
}

# --- 1b. Freshness sanity check on the C++ output ---------------------------
# Guards against the exact class of bug Drashti / Jahanvi laptops showed in
# the field: WindowService.exe was fresh but HelperService.exe alongside it
# was the June-3 build, and no earlier tooling caught it -- install.ps1
# happily deployed the mismatch. Now: read the build output as bytes, look
# for known fix-marker strings, refuse to package if any are missing.
function Test-BinaryHasNeedles {
    param([string]$Path, [string[]]$Needles)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $blob  = [System.Text.Encoding]::ASCII.GetString($bytes) + [System.Text.Encoding]::Unicode.GetString($bytes)
    foreach ($n in $Needles) {
        if ($blob.Contains($n)) { return $true }
    }
    return $false
}

$srcHelper = Join-Path $binOutDir 'HelperService.exe'
$srcWindow = Join-Path $binOutDir 'WindowService.exe'
$hsMarkers = @('upn.change')             # July-10+ per-user audit
$wsMarkers = @('helper.stale_killed')    # July-15+ Fast User Switch fix
# Pause/resume state-sync fix. Without it an app-initiated pause never reaches
# the registry, so the next service restart silently reverts the user -- a
# paused user gets tracked again without being told. See PAUSE-RESUME-FLOW.md.
$wsPauseSyncMarkers = @('SET_TRACKING_ENABLED')
# Control-plane sync (this release): WindowService talks to GET /agent/state and
# HelperService relays the ingest stateVersion / handles POWER_RESUME. Guards
# against packaging an old binary that predates the convergence work.
$wsControlPlaneMarkers = @('/agent/state')
$hsControlPlaneMarkers = @('state.version_hint')
$hsFresh   = Test-BinaryHasNeedles -Path $srcHelper -Needles $hsMarkers
$wsFresh   = Test-BinaryHasNeedles -Path $srcWindow -Needles $wsMarkers
$wsPauseSyncFresh = Test-BinaryHasNeedles -Path $srcWindow -Needles $wsPauseSyncMarkers
$wsCpFresh = Test-BinaryHasNeedles -Path $srcWindow -Needles $wsControlPlaneMarkers
$hsCpFresh = Test-BinaryHasNeedles -Path $srcHelper -Needles $hsControlPlaneMarkers
$hsInfo    = Get-Item $srcHelper
$wsInfo    = Get-Item $srcWindow
Write-Host ""
Write-Host "---- Source freshness check ($binOutDir) ----"
Write-Host ("  HelperService.exe  mtime={0:yyyy-MM-dd HH:mm:ss}  size={1}  hasMarker={2}" -f $hsInfo.LastWriteTime, $hsInfo.Length, $hsFresh)
Write-Host ("  WindowService.exe  mtime={0:yyyy-MM-dd HH:mm:ss}  size={1}  hasMarker={2}" -f $wsInfo.LastWriteTime, $wsInfo.Length, $wsFresh)
if (-not $hsFresh) {
    throw "REFUSING TO PACKAGE: $srcHelper is missing the '$($hsMarkers -join '/')' marker. This means the C++ source folder points at an OLD HelperService.exe. Fix the build output first, then re-run."
}
if (-not $wsFresh) {
    throw "REFUSING TO PACKAGE: $srcWindow is missing the '$($wsMarkers -join '/')' marker. This means the C++ source folder points at an OLD WindowService.exe. Fix the build output first, then re-run."
}
if (-not $wsPauseSyncFresh) {
    throw "REFUSING TO PACKAGE: $srcWindow is missing the '$($wsPauseSyncMarkers -join '/')' marker, so it predates the pause/resume state-sync fix. On that build an app-initiated pause never reaches the registry and the next service restart SILENTLY REVERTS the user. Rebuild WindowService from current source, then re-run. See PAUSE-RESUME-FLOW.md."
}
if (-not $wsCpFresh) {
    throw "REFUSING TO PACKAGE: $srcWindow is missing the '$($wsControlPlaneMarkers -join '/')' marker, so it predates the control-plane sync (GET /agent/state convergence). Rebuild WindowService from current source, then re-run."
}
if (-not $hsCpFresh) {
    throw "REFUSING TO PACKAGE: $srcHelper is missing the '$($hsControlPlaneMarkers -join '/')' marker, so it predates the ingest stateVersion piggyback / version-driven config refresh. Rebuild HelperService from current source, then re-run."
}
Write-Host ("  WindowService.exe  hasPauseSyncMarker={0}  hasControlPlaneMarker={1}" -f $wsPauseSyncFresh, $wsCpFresh)
Write-Host ("  HelperService.exe  hasControlPlaneMarker={0}" -f $hsCpFresh)
Write-Host "  -> both binaries carry the expected fix-markers. Proceeding to package."
Write-Host ""

# --- 2. Assemble staging folder ---------------------------------------------
$stagingRoot = Join-Path $PSScriptRoot "_package_${version}_$($cfg.EnvName)"
if (Test-Path $stagingRoot) { Remove-Item -Recurse -Force $stagingRoot }
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

# C++ output from Release / Release-Stage
Copy-Item (Join-Path $binOutDir 'WindowService.exe') $stagingRoot
Copy-Item (Join-Path $binOutDir 'HelperService.exe') $stagingRoot
Copy-Item (Join-Path $binOutDir 'libcrypto-3-x64.dll') $stagingRoot
Copy-Item (Join-Path $binOutDir 'libssl-3-x64.dll') $stagingRoot

# sentry.dll + crashpad_handler.exe + sentry.h ship from the checked-in
# working folder (they come from the sentry-native prebuilt tarball, not
# from MSBuild).
foreach ($f in @('sentry.dll','crashpad_handler.exe','sentry.h','msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')) {
    $src = Join-Path $PSScriptRoot $f
    if (-not (Test-Path $src)) { throw "Bundled dependency missing: $src" }
    Copy-Item $src $stagingRoot
}

# Install / detect / uninstall / env-config
Copy-Item (Join-Path $PSScriptRoot 'Env-Config.ps1') $stagingRoot
Copy-Item (Join-Path $PSScriptRoot 'install.ps1')    $stagingRoot
Copy-Item (Join-Path $PSScriptRoot 'detect.ps1')     $stagingRoot
Copy-Item (Join-Path $PSScriptRoot 'uninstall.ps1')  $stagingRoot
Copy-Item (Join-Path $PSScriptRoot 'version.txt')    $stagingRoot

# --- 2b. Stamp the version from version.txt into the STAGED scripts ----------
# version.txt is the single source of truth. install.ps1 ($version) and
# detect.ps1 ($TargetVersion) each carry their own copy of the number, and
# they MUST equal version.txt or Intune breaks:
#   * detect < version.txt  -> after install writes the new version.txt, detect
#     never matches, so Intune re-runs install.ps1 on EVERY sync forever.
#   * detect stuck at an OLD number while binaries changed but version.txt did
#     NOT -> detection passes, Intune never redeploys, the binary change never
#     reaches the device (the exact "helper never updated" class of bug).
# Rather than trust three hand-edited literals to stay in sync, rewrite the two
# staged copies from $version here and FAIL LOUDLY if the expected pattern is
# not found (source format drifted). The source files are left untouched.
# Line-based (not regex-replacement) so the '$' in the new line is never
# mis-read as a .NET substitution token. -match only TESTS; the new line is
# assigned literally.
function Set-StagedVersion {
    param([string]$File, [string]$LinePattern, [string]$NewLine)
    if (-not (Test-Path $File)) { throw "Set-StagedVersion: staged file missing: $File" }
    $lines = @(Get-Content -LiteralPath $File)
    $matched = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $LinePattern) { $lines[$i] = $NewLine; $matched = $true; break }
    }
    if (-not $matched) {
        throw "Set-StagedVersion: pattern '$LinePattern' not found in $File -- the version line changed shape; update Build-Package.ps1."
    }
    Set-Content -LiteralPath $File -Value $lines -Encoding UTF8
    Write-Host "  stamped version=$version into $(Split-Path $File -Leaf)"
}
Write-Host "Stamping version=$version into staged install.ps1 + detect.ps1 (source of truth: version.txt)..."
Set-StagedVersion -File (Join-Path $stagingRoot 'install.ps1') `
    -LinePattern '^\s*\$version\s*=\s*"' `
    -NewLine ('$version        = "' + $version + '"   # Auto-stamped from version.txt by Build-Package.ps1')
Set-StagedVersion -File (Join-Path $stagingRoot 'detect.ps1') `
    -LinePattern "^\s*\`$TargetVersion\s*=\s*'" `
    -NewLine ("`$TargetVersion = '" + $version + "'")
# Prove the two staged scripts now agree with version.txt.
$stampedInstall = (Get-Content (Join-Path $stagingRoot 'install.ps1') -Raw)
$stampedDetect  = (Get-Content (Join-Path $stagingRoot 'detect.ps1')  -Raw)
if ($stampedInstall -notmatch [regex]::Escape('"' + $version + '"')) {
    throw "install.ps1 version stamp verification failed (expected $version)"
}
if ($stampedDetect -notmatch [regex]::Escape("'" + $version + "'")) {
    throw "detect.ps1 version stamp verification failed (expected $version)"
}
Write-Host "  verified: install.ps1 + detect.ps1 both carry version $version"

# env.txt marker so a direct `.\install.ps1` inside this staging folder
# (or later, inside the extracted .intunewin on a device) defaults to the
# correct env without the operator having to remember -Env.
$cfg.EnvName | Set-Content -Path (Join-Path $stagingRoot 'env.txt') -Encoding ASCII

# --- 3. Zip the staging folder for hand-off testing --------------------------
# The zip lands next to the folder (same parent) so recipients get one
# file to download / share. Extracting it gives them the raw staging
# folder back, and they run `.\install.ps1` inside -- env.txt marker
# means they don't need to remember -Env prod|stage.
$zipPath = $null
if (-not $NoZip) {
    $zipPath = Join-Path $PSScriptRoot "_package_${version}_$($cfg.EnvName).zip"
    if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
    Write-Host "Zipping staging folder -> $zipPath"
    # Use System.IO.Compression.ZipFile.CreateFromDirectory instead of
    # Compress-Archive: the latter grabs each file with an exclusive
    # share mode and blows up when another process (usually the caller's
    # IDE, editing install.ps1 etc.) has any file in the staging folder
    # open. ZipFile.CreateFromDirectory opens with FileShare.Read and
    # copes with editor handles cleanly.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingRoot,
        $zipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $true   # include the top folder inside the archive
    )
}

# --- 4. (optional) Invoke IntuneWinAppUtil ----------------------------------
#
# NOTE (2026-07-15): earlier revisions of this script registered a small
# 'run-install.ps1' wrapper as the setup file and then renamed the
# tool's output from run-install.intunewin -> PiFocusAgent-<v>-<env>.intunewin.
# Intune's Company-Portal upload validator rejected the resulting file with
# "File format is not recognized" (browser console error was
# "MsPortalFx.Base.Diagnostics.ErrorReporter ... File format is not recognized").
# The known-working 1.0.3 recipe that the ops team validated was:
#     .\IntuneWinAppUtil.exe -c . -s install.ps1 -o ..\IntunePackages
# So we now match that shape: install.ps1 direct as the setup file, the
# tool writes install.intunewin, then we produce a SIDE-BY-SIDE renamed
# copy (leaving the tool's original file untouched) in case renaming turns
# out to also matter for the Intune UI validator.
$intuneOut         = $null   # tool's original (install.intunewin) -- preferred upload
$intuneOutRenamed  = $null   # side-by-side copy renamed with version + env
if (-not $NoIntune) {
    $intuneTool = Join-Path $PSScriptRoot 'IntuneWinAppUtil.exe'
    if (-not (Test-Path $intuneTool)) {
        Write-Host "IntuneWinAppUtil.exe not found next to this script -- skipping .intunewin step."
        Write-Host "(pass -NoIntune to silence this, or drop IntuneWinAppUtil.exe here)"
    }
    else {
        $distDir = Join-Path $PSScriptRoot 'dist_intunewin'
        if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }

        # Match the ops team's known-working command shape exactly:
        # cd into the staging folder, pass '.' as -c, install.ps1 as -s,
        # no -q flag. install.ps1 defaults to the right env because
        # env.txt lives next to it (Build-Package writes it above).
        Write-Host "Invoking IntuneWinAppUtil (matching known-working 1.0.3 recipe)..."
        # Delete any pre-existing output up front. Without this the tool
        # hits an interactive Y/N prompt ("output file already exists")
        # and hangs / errors when run non-interactively -- stdin is EOF
        # so the tool errors out and leaves the OLD file in place.
        $preExisting = Join-Path $distDir 'install.intunewin'
        if (Test-Path $preExisting) {
            Write-Host "  Removing prior $preExisting"
            Remove-Item -Force $preExisting
        }
        Push-Location $stagingRoot
        try {
            & $intuneTool -c '.' -s 'install.ps1' -o $distDir
        } finally {
            Pop-Location
        }

        $producedName = 'install.intunewin'   # tool names output after the setup file
        $produced     = Join-Path $distDir $producedName
        if (-not (Test-Path $produced)) { throw "IntuneWinAppUtil did not produce $produced" }
        $intuneOut = $produced

        # Also drop a versioned COPY (not a rename) next to it, so the
        # ops team has both files: the tool's original (safest to upload)
        # AND a versioned copy (for archival / tracking).
        $renamed = Join-Path $distDir "PiFocusAgent-$version-$($cfg.EnvName).intunewin"
        if (Test-Path $renamed) { Remove-Item -Force $renamed }
        Copy-Item $produced $renamed
        $intuneOutRenamed = $renamed
    }
}

# --- 5. Verify the staged files (last check before we hand the artifact off) -
# The pre-package check already validated $binOutDir. Now re-verify the
# copies that actually landed in the staging folder -- if Copy-Item earlier
# in the script picked up a stale sibling from disk somehow, we catch it
# here before the .intunewin ships.
$stagedHelper = Join-Path $stagingRoot 'HelperService.exe'
$stagedWindow = Join-Path $stagingRoot 'WindowService.exe'
$stagedHsFresh = Test-BinaryHasNeedles -Path $stagedHelper -Needles $hsMarkers
$stagedWsFresh = Test-BinaryHasNeedles -Path $stagedWindow -Needles $wsMarkers
$stagedWsPauseSyncFresh = Test-BinaryHasNeedles -Path $stagedWindow -Needles $wsPauseSyncMarkers
$stagedWsCpFresh = Test-BinaryHasNeedles -Path $stagedWindow -Needles $wsControlPlaneMarkers
$stagedHsCpFresh = Test-BinaryHasNeedles -Path $stagedHelper -Needles $hsControlPlaneMarkers
$stagedHsInfo  = Get-Item $stagedHelper
$stagedWsInfo  = Get-Item $stagedWindow
if (-not $stagedHsFresh -or -not $stagedWsFresh -or -not $stagedWsPauseSyncFresh -or -not $stagedWsCpFresh -or -not $stagedHsCpFresh) {
    throw "STAGED FILES ARE STALE (Helper marker=$stagedHsFresh, Window marker=$stagedWsFresh, Window pause-sync marker=$stagedWsPauseSyncFresh, Window control-plane=$stagedWsCpFresh, Helper control-plane=$stagedHsCpFresh). Something replaced the built binaries between build and staging. Investigate before shipping."
}

# --- 6. Summary --------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================="
Write-Host "  BUILD-PACKAGE COMPLETE  (env=$($cfg.EnvName), version=$version)"
Write-Host "===================================================================="
Write-Host "  Raw staging folder : $stagingRoot"
if ($zipPath)          { Write-Host "  Shareable ZIP      : $zipPath  <-- send this to testers" }
if ($intuneOut)        { Write-Host "  Intune package     : $intuneOut  <-- upload THIS to Intune (tool's original filename)" }
if ($intuneOutRenamed) { Write-Host "  Intune (versioned) : $intuneOutRenamed  (archival copy with version + env in name)" }
Write-Host ""
Write-Host "  VERDICT -- what is inside the package:"
Write-Host ("    HelperService.exe  mtime={0:yyyy-MM-dd HH:mm:ss}  size={1}  markers OK: {2}" -f $stagedHsInfo.LastWriteTime, $stagedHsInfo.Length, $stagedHsFresh)
Write-Host ("    WindowService.exe  mtime={0:yyyy-MM-dd HH:mm:ss}  size={1}  markers OK: {2}" -f $stagedWsInfo.LastWriteTime, $stagedWsInfo.Length, $stagedWsFresh)
Write-Host "    -> SAFE TO UPLOAD to Intune. Both binaries have the July-15+ fixes."
Write-Host ""
Write-Host "  Recipient recipe:"
Write-Host "    1. extract the zip"
Write-Host "    2. right-click PowerShell -> Run as administrator"
Write-Host "    3. cd into the extracted folder"
Write-Host "    4. .\install.ps1                   (env.txt auto-selects $($cfg.EnvName))"
Write-Host "===================================================================="
