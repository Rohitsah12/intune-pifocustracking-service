# pf-tamper-test.ps1
#
# Run this AS THE STANDARD (non-admin) USER on the test device, AFTER an admin has
# installed the hardened package (.\install.ps1). It tries every route a user could
# use to stop/kill/delete the service + binaries, records the result of each, and
# proves the 5s watchdog respawns the helper. Send the produced evidence file back.
#
#   Right-click PowerShell (NORMAL, not admin) -> just run:  .\pf-tamper-test.ps1
#
# It auto-detects prod vs stage. No admin needed (that is the whole point).

$ErrorActionPreference = 'SilentlyContinue'

# --- detect which service/env is installed ---
$Svc = $null; $EnvName = $null; $ProgramData = $null; $ProgramMonitor = $null; $InstallDir = $null
if (Get-Service -Name 'PiFocusWindowService'      -EA SilentlyContinue) { $Svc='PiFocusWindowService';      $EnvName='prod';  $ProgramData='C:\ProgramData\PiFocus';      $ProgramMonitor='C:\ProgramData\ProgramMonitor';      $InstallDir='C:\Program Files\PiFocus\Agent' }
if (Get-Service -Name 'PiFocusWindowServiceStage' -EA SilentlyContinue) { $Svc='PiFocusWindowServiceStage'; $EnvName='stage'; $ProgramData='C:\ProgramData\PiFocusStage'; $ProgramMonitor='C:\ProgramData\ProgramMonitorStage'; $InstallDir='C:\Program Files\PiFocus\AgentStage' }
if (-not $Svc) { Write-Host "No PiFocus service found. Install the package first (as admin)."; return }

$Out = "$env:USERPROFILE\Desktop\pf-tamper-evidence.txt"
function W($t){ $t | Out-File -FilePath $Out -Append -Encoding utf8 }

"==== PiFocus tamper test ====" | Set-Content $Out -Encoding utf8
W ("time      : " + (Get-Date -Format o))
W ("user      : $env:USERNAME   computer: $env:COMPUTERNAME")
W ("service   : $Svc ($EnvName)")
W "--- am I admin? (expect NO for a valid test) ---"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
W ("  IsAdministrator = $isAdmin" + $(if($isAdmin){"   <-- WARNING: run as a NON-admin user for a real test"}else{""}))

W "`n--- live service SDDL (the AU ACE must be READ-ONLY: no RP/WP) ---"
W (cmd /c "sc sdshow $Svc" 2>&1)

W "`n[1] sc stop  (EXPECT: Access is denied / 5)"
W (cmd /c "sc stop $Svc" 2>&1)

W "`n[2] sc delete  (EXPECT: Access is denied)"
W (cmd /c "sc delete $Svc" 2>&1)

W "`n[3] taskkill WindowService.exe  (EXPECT: Access denied - SYSTEM process)"
W (cmd /c "taskkill /F /IM WindowService.exe" 2>&1)

W "`n[4] HelperService End-Task test (EXPECT: ends, then watchdog respawns a NEW pid within ~5s)"
$before = (Get-Process HelperService -EA SilentlyContinue | Select-Object -Expand Id) -join ','
W ("  Helper PID(s) BEFORE : $before")
W (cmd /c "taskkill /F /IM HelperService.exe" 2>&1)
Start-Sleep -Seconds 8
$after = (Get-Process HelperService -EA SilentlyContinue | Select-Object -Expand Id) -join ','
W ("  Helper PID(s) AFTER ~8s: $after   " + $(if($after -and $after -ne $before){"<-- RESPAWNED (good)"}elseif($after){"<-- still running"}else{"<-- NOT running (watchdog failed?)"}))

W "`n[5] delete helper binary  (EXPECT: Access denied)"
$hs = Join-Path $ProgramData 'HelperService.exe'
Remove-Item $hs -Force -EA SilentlyContinue
W ("  after delete attempt, HelperService.exe still present = " + (Test-Path $hs))

W "`n[6] delete WindowService binary  (EXPECT: Access denied)"
$ws = Join-Path $InstallDir 'WindowService.exe'
Remove-Item $ws -Force -EA SilentlyContinue
W ("  after delete attempt, WindowService.exe still present = " + (Test-Path $ws))

W "`n[7] service final state  (EXPECT: RUNNING)"
W ((cmd /c "sc query $Svc" 2>&1 | Select-String 'STATE') -join "`n")

# --- attach the WindowService runtime log tail (watchdog proof) ---
$d = Get-Date -Format 'yyyy-MM-dd'
$wsLog = Join-Path $ProgramMonitor "debugLogs\$d-WindowService.json"
W "`n--- WindowService log tail (watchdog / startHelperService lines) ---"
if (Test-Path $wsLog) {
    W ((Get-Content $wsLog -Tail 400 | Select-String 'Watchdog|startHelperService|state.apply' | Select-Object -Last 20) -join "`n")
} else { W "  (no WindowService log at $wsLog)" }

Write-Host ""
Write-Host "DONE. Evidence written to:  $Out"
Write-Host "Send that file back (plus the WindowService debugLogs json if asked)."
