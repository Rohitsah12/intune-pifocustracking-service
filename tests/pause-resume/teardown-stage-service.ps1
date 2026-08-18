# teardown-stage-service.ps1
#
# Removes everything setup-stage-service.ps1 created. Run from an ELEVATED
# PowerShell when you are done testing.
#
# Touches ONLY the stage namespace. Production (PiFocusWindowService,
# C:\Program Files\PiFocus\Agent, HKLM\SOFTWARE\PiFocus) is never referenced.

#Requires -RunAsAdministrator

$ErrorActionPreference = 'SilentlyContinue'

$InstallDir  = 'C:\Program Files\PiFocus\AgentStage'
$HelperDir   = 'C:\ProgramData\PiFocusStage'
$ServiceName = 'PiFocusWindowServiceStage'
$HklmRoot    = 'HKLM:\SOFTWARE\PiFocusStage'

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }

Say "`n=== PiFocus STAGE service teardown ===`n" 'Cyan'

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne 'Stopped') {
        & sc.exe stop $ServiceName | Out-Null
        Start-Sleep -Seconds 4
    }
    & sc.exe delete $ServiceName | Out-Null
    Say "  service deleted" 'Green'
} else {
    Say "  service not present"
}

Get-Process -Name 'HelperService','WindowService' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like '*Stage*' } |
    ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        Say "  killed stage process pid=$($_.Id)" 'Green'
    }

Start-Sleep -Seconds 2

# Remove the mock-socket redirect if the socket tests left it behind.
if (Get-ItemProperty -Path $HklmRoot -Name 'TestWsUrl' -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -Path $HklmRoot -Name 'TestWsUrl' -Force
    Say "  removed TestWsUrl redirect" 'Green'
}

foreach ($dir in @($InstallDir, $HelperDir)) {
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $dir) {
            Say "  could not fully remove $dir (a file may still be locked)" 'Yellow'
        } else {
            Say "  removed $dir" 'Green'
        }
    }
}

Say "`nStage artifacts removed. Production untouched." 'Cyan'
Say "Verify prod is healthy:  node check-state.js`n"
