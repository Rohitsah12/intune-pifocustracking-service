$ErrorActionPreference = "Continue"

$ServiceName = "PiFocusWindowService"
$AgentDir = "C:\Program Files\PiFocus\Agent"
$ProgramDataDir = "C:\ProgramData\PiFocus"

Write-Host "==== PiFocus Agent Uninstall Started ===="

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

# Kill helper silently
cmd.exe /c "taskkill /F /IM HelperService.exe /T >nul 2>&1"

# Delete service
cmd.exe /c "sc delete `"$ServiceName`" >nul 2>&1"
Start-Sleep 2

# Cleanup files
Remove-Item -Recurse -Force $AgentDir -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $ProgramDataDir -ErrorAction SilentlyContinue

# Cleanup registry
Remove-Item -Path "HKLM:\SOFTWARE\PiFocus" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "==== PiFocus Agent Removed ===="
exit 0
