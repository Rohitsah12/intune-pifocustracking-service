param(
    [ValidateSet('prod','stage')]
    [string]$Env
)

$ErrorActionPreference = "Continue"

# Same env-marker convention as install.ps1: read env.txt if the caller
# didn't pass -Env explicitly. Prevents an uninstall run from the stage
# staging folder from wiping out the prod install by accident.
if (-not $PSBoundParameters.ContainsKey('Env') -or [string]::IsNullOrWhiteSpace($Env)) {
    $envMarker = Join-Path $PSScriptRoot 'env.txt'
    if (Test-Path $envMarker) {
        $Env = (Get-Content $envMarker -Raw).Trim().ToLower()
    }
    if ([string]::IsNullOrWhiteSpace($Env)) { $Env = 'prod' }
}
if ($Env -ne 'prod' -and $Env -ne 'stage') {
    throw "uninstall.ps1: invalid env '$Env' (expected prod|stage; check env.txt)"
}

. (Join-Path $PSScriptRoot 'Env-Config.ps1')
$cfg = Get-PiFocusEnv -Env $Env

$ServiceName    = $cfg.ServiceName
$AgentDir       = $cfg.InstallDir
$ProgramDataDir = $cfg.ProgramDataDir
$HklmRoot       = $cfg.HklmRoot

Write-Host "==== PiFocus Agent Uninstall Started (env=$($cfg.EnvName)) ===="
Write-Host "Service:  $ServiceName"
Write-Host "AgentDir: $AgentDir"
Write-Host "PData:    $ProgramDataDir"
Write-Host "Registry: $HklmRoot"

# Try stop service
cmd.exe /c "sc stop `"$ServiceName`" >nul 2>&1"
Start-Sleep 3

# Try get PID
$pidLine = cmd.exe /c "sc queryex `"$ServiceName`"" | Select-String "PID"

if ($pidLine) {
    try {
        $servicePid = ($pidLine -split ":")[1].Trim()
        if ($servicePid -ne "0") {
            Write-Host "Force killing service PID $servicePid"
            cmd.exe /c "taskkill /F /PID $servicePid /T >nul 2>&1"
        }
    }
    catch {
        Write-Host "Could not parse PID"
    }
}

# Kill helper silently -- ONLY our env's helper (both prod and stage ship a
# binary called HelperService.exe; matching by image name would take out
# the other env by accident).
$OurHelperExe = Join-Path $ProgramDataDir 'HelperService.exe'
$helperProcs = Get-Process -Name "HelperService" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and ($_.Path -ieq $OurHelperExe) }
foreach ($hp in $helperProcs) {
    try {
        Stop-Process -Id $hp.Id -Force -ErrorAction Stop
        Write-Host "Stopped HelperService (PID $($hp.Id), path=$($hp.Path))"
    } catch {
        Write-Host "Failed to stop HelperService PID $($hp.Id): $_"
    }
}

# Delete service
cmd.exe /c "sc delete `"$ServiceName`" >nul 2>&1"
Start-Sleep 2

# Cleanup files
Remove-Item -Recurse -Force $AgentDir -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $ProgramDataDir -ErrorAction SilentlyContinue

# Cleanup registry
Remove-Item -Path $HklmRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "==== PiFocus Agent Removed (env=$($cfg.EnvName)) ===="
exit 0
