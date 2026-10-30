<#
    PiFocus Agent - Intune Remediations: REMEDIATION script
    ===========================================================================
    Runs as-is on every device. There is nothing to configure: it finds the
    PiFocus agent installed on the device and repairs only what is broken.
    A healthy device is left exactly as it is; a device without PiFocus is
    not touched at all.

    Exit 0 = the service is Running at the end. Exit 1 = could not fix (see log).

    What it does, in order:
      1. Stays hands-off while install.ps1 / uninstall.ps1 is running
         (or Install.log was written in the last 15 min).
      2. StartMode -> Auto (what install.ps1 sets).
      3. Re-arms SCM recovery exactly as install.ps1 does
         (reset= 86400 actions= restart/5000/restart/10000/restart/30000) and
         adds failureflag 1, so an error stop is restarted too.
      4. Waits out a Start/Stop Pending state; kills the process if it is hung.
      5. Starts the service if it is not Running. Kills any leftover
         WindowService.exe first (a start that timed out, event 7009, can leave
         one holding the IPC pipe name). Retries once.
      6. If the service is Running but the console user has had no helper for
         10+ minutes (re-checked after 60 s), restarts the service: its main
         loop is wedged.
      7. Confirms the service stays up for 20 s and that a helper shows up in
         the console user's session.

    It does NOT touch:
      - HelperService.exe. An orphaned helper re-opens the pipe on every call
        (PipeClient::transact), so it reconnects by itself once the service is
        back, and the service adopts a helper already running in the active
        session (isHelperServiceRunning).
      - Pause state. The service re-applies HKLM\SOFTWARE\PiFocus\TrackingEnabled
        on start (PAUSE-RESUME-FLOW.md, flow 4), so a paused user stays paused.
      - A missing service registration. install.ps1 owns service creation and
        its binary-freshness checks; reinstall the app instead.

    Log: Remediation.log next to Install.log (C:\ProgramData\PiFocus\Logs\).

    Intune settings:
      Run this script using the logged-on credentials : No  (runs as SYSTEM;
                                                             the service SDDL
                                                             only lets SYSTEM and
                                                             Administrators start it)
      Enforce script signature check                  : No  (unless you sign it)
      Run script in 64-bit PowerShell                 : Yes
#>

# --- Re-launch in 64-bit PowerShell if Intune started us as 32-bit ----------
if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') {
    $ps64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps64) {
        & $ps64 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
}

$HelperGraceMinutes  = 10   # service AND user session must be this old before a missing helper counts
$InstallQuietMinutes = 15   # stay hands-off while install.ps1 has written its log this recently

# Same recovery policy install.ps1 applies after it creates the service.
$RecoveryResetSec = '86400'
$RecoveryActions  = 'restart/5000/restart/10000/restart/30000'

$LogFile = $null   # set per agent in Repair-Agent

# --- Shared functions (identical copy in Detect-PiFocusAgent.ps1) -----------

function Get-PiFocusAgents {
    # Every name in Env-Config.ps1 is the base name plus one suffix: ''
    # for the production build, 'Stage' for the staging build
    # (PiFocusWindowService<sfx>, C:\Program Files\PiFocus\Agent<sfx>,
    # C:\ProgramData\PiFocus<sfx>, C:\ProgramData\ProgramMonitor<sfx>).
    # The suffix is read off the services and folders that actually exist, so
    # nothing is configured and a production device only ever has its
    # production agent checked.
    $suffixes = @()
    $services = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'PiFocusWindowService%'" -ErrorAction SilentlyContinue
    foreach ($s in @($services)) {
        if ($s) { $suffixes += $s.Name.Substring('PiFocusWindowService'.Length) }
    }
    # Binaries present but service gone (deleted by hand, or an aborted
    # install.ps1): still report it. Only the two install folders install.ps1
    # creates count, so a copied backup folder is never mistaken for an agent.
    foreach ($dir in @('Agent', 'AgentStage')) {
        if (Test-Path -LiteralPath (Join-Path "C:\Program Files\PiFocus\$dir" 'WindowService.exe')) {
            $suffixes += $dir.Substring('Agent'.Length)
        }
    }
    foreach ($sfx in @($suffixes | Sort-Object -Unique)) {
        $envName = 'production'
        if ($sfx) { $envName = $sfx.ToLower() }
        $installDir = 'C:\Program Files\PiFocus\Agent' + $sfx
        $dataDir    = 'C:\ProgramData\PiFocus' + $sfx
        [pscustomobject]@{
            Env         = $envName
            ServiceName = 'PiFocusWindowService' + $sfx
            ServiceExe  = Join-Path $installDir 'WindowService.exe'
            HelperExe   = Join-Path $dataDir 'HelperService.exe'
            InstallLog  = Join-Path $dataDir 'Logs\Install.log'
            LogFile     = Join-Path $dataDir 'Logs\Remediation.log'
            DebugLogDir = 'C:\ProgramData\ProgramMonitor' + $sfx + '\debugLogs'
        }
    }
}

function Get-AgentService($Agent) {
    Get-CimInstance -ClassName Win32_Service -Filter "Name='$($Agent.ServiceName)'" -ErrorAction SilentlyContinue
}

function Get-InstallerActivity($Agent) {
    # install.ps1 stops, disables and DELETES the service before it copies the
    # binaries, then recreates it. Starting the service inside that window is
    # the new-WindowService / stale-HelperService race the installer guards
    # against, so never touch anything while an install is running.
    if (Test-Path -LiteralPath $Agent.InstallLog) {
        $age = ((Get-Date) - (Get-Item -LiteralPath $Agent.InstallLog).LastWriteTime).TotalMinutes
        if ($age -lt $InstallQuietMinutes) { return ('Install.log written {0:N0} min ago' -f $age) }
    }
    $shells = Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue
    foreach ($p in @($shells)) {
        if ($p -and $p.CommandLine -match '(?i)(^|[\\/"''\s])(un)?install\.ps1') {
            return "install/uninstall script running (PID $($p.ProcessId))"
        }
    }
    return $null
}

function Get-RecoveryState($Agent) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($Agent.ServiceName)"
    $p = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    $actionsOk = $false
    if ($p -and $p.FailureActions) {
        # SERVICE_FAILURE_ACTIONS as SCM stores it: 5-DWORD header
        # (resetPeriod, rebootMsg, command, cActions, lpsaActions) followed by
        # cActions x { type, delayMs }. type 1 = SC_ACTION_RESTART.
        $fa = [byte[]]$p.FailureActions
        if ($fa.Length -ge 28 -and
            [BitConverter]::ToUInt32($fa, 12) -ge 1 -and
            [BitConverter]::ToUInt32($fa, 20) -eq 1) {
            $actionsOk = $true
        }
    }
    $flagOk = [bool]($p -and $p.FailureActionsOnNonCrashFailures -eq 1)
    [pscustomobject]@{ ActionsOk = $actionsOk; NonCrashFlagOk = $flagOk }
}

function Get-ConsoleUser {
    # The user on the physical console and the session their desktop runs in.
    $user = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ([string]::IsNullOrWhiteSpace($user)) { return $null }
    $shells = @(Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue |
                Where-Object { $_.SessionId -ne 0 })
    $mine = @($shells | Where-Object { $_.UserName -ieq $user })
    if ($mine.Count -eq 0 -and $shells.Count -eq 1) { $mine = $shells }
    if ($mine.Count -eq 0) { return $null }
    $oldest = $mine | Sort-Object StartTime | Select-Object -First 1
    [pscustomobject]@{
        User        = $user
        SessionId   = $oldest.SessionId
        SessionMins = ((Get-Date) - $oldest.StartTime).TotalMinutes
    }
}

function Get-OurHelper($Agent, [int]$SessionId = -1) {
    # Path match only: production and staging both ship a HelperService.exe.
    # Win32_Process, not Get-Process: Process.Path is empty for 64-bit processes
    # when PowerShell runs as 32-bit, which is how IME runs install.ps1 (its
    # "Our HelperService not running" line followed by "file in use" x5).
    @(Get-CimInstance -ClassName Win32_Process -Filter "Name='HelperService.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.ExecutablePath -and ($_.ExecutablePath -ieq $Agent.HelperExe) -and
        ($SessionId -lt 0 -or $_.SessionId -eq $SessionId)
      })
}

function Get-HelperProblem($Agent) {
    # Returns a description when the service is Running but the console user
    # has had no helper for longer than the grace period, otherwise $null.
    $s = Get-AgentService $Agent
    if (-not $s -or $s.State -ne 'Running' -or -not $s.ProcessId) { return $null }
    $proc = Get-Process -Id $s.ProcessId -ErrorAction SilentlyContinue
    if (-not $proc -or ((Get-Date) - $proc.StartTime).TotalMinutes -lt $HelperGraceMinutes) { return $null }
    $cu = Get-ConsoleUser
    if (-not $cu -or $cu.SessionMins -lt $HelperGraceMinutes) { return $null }
    if ((Get-OurHelper -Agent $Agent -SessionId $cu.SessionId).Count -gt 0) { return $null }
    return "no HelperService.exe in $($cu.User) session $($cu.SessionId) (service main loop wedged)"
}

function Get-ServiceLogAgeHours($Agent) {
    $f = Get-ChildItem -LiteralPath $Agent.DebugLogDir -Filter '*-WindowService.json' -File -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return [math]::Round(((Get-Date) - $f.LastWriteTime).TotalHours, 1) }
    return $null
}

# --- Remediation-only functions ----------------------------------------------

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    if (-not $script:LogFile) { return }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding ASCII -ErrorAction Stop } catch { }
}

function Initialize-Log {
    $dir = Split-Path -Parent $script:LogFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ((Test-Path -LiteralPath $script:LogFile) -and (Get-Item -LiteralPath $script:LogFile).Length -gt 1MB) {
        Move-Item -LiteralPath $script:LogFile -Destination ($script:LogFile + '.old') -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Sc {
    # 'sc' is an alias for Set-Content in PowerShell - always call sc.exe.
    $out  = & sc.exe @args 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Log ('sc.exe {0} -> exit {1}: {2}' -f ($args -join ' '), $code, ($out.Trim() -replace '\s+', ' '))
    return $code
}

function New-Result([bool]$Ok, [string]$Message) {
    [pscustomobject]@{ Ok = $Ok; Message = $Message }
}

function Wait-ServiceState($Agent, [string[]]$Want, [int]$TimeoutSec) {
    # Polls until State is one of $Want. When waiting for Running only, gives up
    # early if the service sits in Stopped for 15 s (start failed or crashed).
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $stoppedSince = $null
    do {
        $s = Get-AgentService $Agent
        if (-not $s) { return $null }
        if ($Want -contains $s.State) { return $s }
        if ($s.State -eq 'Stopped' -and -not ($Want -contains 'Stopped')) {
            if (-not $stoppedSince) { $stoppedSince = Get-Date }
            elseif (((Get-Date) - $stoppedSince).TotalSeconds -ge 15) { return $s }
        } else {
            $stoppedSince = $null
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return (Get-AgentService $Agent)
}

function Stop-ServiceProcess($Agent, [string]$Why) {
    # Only processes running THIS agent's binary path (production and staging
    # both ship a WindowService.exe).
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='WindowService.exe'" -ErrorAction SilentlyContinue |
                     Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $Agent.ServiceExe) })) {
        Write-Log "Killing WindowService.exe pid $($p.ProcessId) ($Why)" 'WARN'
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Start-AgentService($Agent) {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $s = Get-AgentService $Agent
        if ($s.State -eq 'Stopped') {
            # SCM says Stopped, so any WindowService.exe still alive is a leftover
            # and would keep the pipe name from the new instance.
            Stop-ServiceProcess $Agent 'leftover process while service is Stopped'
            Start-Sleep -Seconds 2
            [void](Invoke-Sc start $Agent.ServiceName)
        }
        $s = Wait-ServiceState $Agent @('Running') 90
        if ($s -and $s.State -eq 'Running') { return $s }
        Write-Log ('Start attempt {0} failed: state={1} exitCode={2}' -f $attempt, $s.State, $s.ExitCode) 'WARN'
        Stop-ServiceProcess $Agent 'stuck starting'
        Start-Sleep -Seconds 3
        [void](Wait-ServiceState $Agent @('Stopped', 'Running') 30)
    }
    return (Get-AgentService $Agent)
}

function Stop-AgentService($Agent) {
    [void](Invoke-Sc stop $Agent.ServiceName)
    $s = Wait-ServiceState $Agent @('Stopped') 60
    if ($s -and $s.State -ne 'Stopped') {
        Stop-ServiceProcess $Agent 'did not stop within 60s'
        Start-Sleep -Seconds 3   # let SCM notice the exit before we read the state again
        # A kill counts as a crash, so SCM recovery may bring it straight back:
        # accept either state, Start-AgentService handles both.
        $s = Wait-ServiceState $Agent @('Stopped', 'Running') 30
    }
    return $s
}

function Repair-Agent($Agent) {
    $script:LogFile = $Agent.LogFile
    $summary = New-Object System.Collections.Generic.List[string]
    try {
        Initialize-Log
        Write-Log "===== Remediation start (env=$($Agent.Env), service=$($Agent.ServiceName), computer=$env:COMPUTERNAME) ====="

        $busy = Get-InstallerActivity $Agent
        if ($busy) {
            Write-Log "Skipped: $busy"
            return (New-Result $true "SKIPPED: $busy")
        }

        $svc = Get-AgentService $Agent
        if (-not $svc) {
            Write-Log ("Service $($Agent.ServiceName) is not registered but $($Agent.ServiceExe) exists. Not recreating it here: " +
                       'install.ps1 owns service creation and its binary-freshness checks. Reinstall the PiFocus app.') 'ERROR'
            return (New-Result $false "FAILED: service $($Agent.ServiceName) not registered - reinstall the PiFocus app")
        }

        $beforeShort = "was $($svc.State), exitCode $($svc.ExitCode)"
        Write-Log "Before: state=$($svc.State) startMode=$($svc.StartMode) exitCode=$($svc.ExitCode) pid=$($svc.ProcessId)"
        $logAge = Get-ServiceLogAgeHours $Agent
        if ($null -ne $logAge) { Write-Log "Newest WindowService log is ${logAge}h old" }
        $orphans = Get-OurHelper -Agent $Agent
        if ($orphans.Count -gt 0) {
            Write-Log ('Helper running: ' + (($orphans | ForEach-Object { "pid $($_.ProcessId) session $($_.SessionId)" }) -join ', '))
        }

        # 1. Start mode back to Auto.
        if ($svc.StartMode -ne 'Auto') {
            [void](Invoke-Sc config $Agent.ServiceName 'start=' 'auto')
            $summary.Add("startMode $($svc.StartMode) -> Auto")
        }

        # 2. Recovery: install.ps1's actions, plus the flag install.ps1 never sets.
        $rec = Get-RecoveryState $Agent
        if (-not $rec.ActionsOk) {
            [void](Invoke-Sc failure $Agent.ServiceName 'reset=' $RecoveryResetSec 'actions=' $RecoveryActions)
            $summary.Add('restart actions re-armed')
        }
        if (-not $rec.NonCrashFlagOk) {
            [void](Invoke-Sc failureflag $Agent.ServiceName '1')
            $summary.Add('recovery flag set')
        }

        # 3. Let a pending state settle; kill it if it is hung.
        if (@('Running', 'Stopped') -notcontains $svc.State) {
            Write-Log "Service is '$($svc.State)'; waiting up to 60s for it to settle"
            $svc = Wait-ServiceState $Agent @('Running', 'Stopped') 60
            if ($svc -and @('Running', 'Stopped') -notcontains $svc.State) {
                Stop-ServiceProcess $Agent "hung in '$($svc.State)'"
                Start-Sleep -Seconds 3
                $svc = Wait-ServiceState $Agent @('Stopped', 'Running') 30
            }
        }

        # 4. Start it, or restart it if its main loop is wedged.
        $acted = $false
        if ($svc -and $svc.State -eq 'Running') {
            $problem = Get-HelperProblem $Agent
            if ($problem) {
                Write-Log "$problem - re-checking in 60s before restarting"
                Start-Sleep -Seconds 60
                $problem = Get-HelperProblem $Agent
            }
            if ($problem) {
                Write-Log "Still $problem - restarting the service" 'WARN'
                [void](Stop-AgentService $Agent)
                $svc = Start-AgentService $Agent
                $summary.Add('restarted wedged service (helper was missing)')
                $acted = $true
            }
        } else {
            $svc = Start-AgentService $Agent
            $summary.Add("started service ($beforeShort)")
            $acted = $true
        }

        # 5. Make sure it stays up and the helper is there.
        if ($acted -and $svc -and $svc.State -eq 'Running') {
            $firstPid = $svc.ProcessId
            Start-Sleep -Seconds 20
            $svc = Get-AgentService $Agent
            if (-not $svc -or $svc.State -ne 'Running' -or $svc.ProcessId -ne $firstPid) {
                Write-Log "Service did not stay up (pid $firstPid -> $($svc.ProcessId), state=$($svc.State)); one more start" 'WARN'
                $svc = Start-AgentService $Agent
            }

            $cu = Get-ConsoleUser
            if ($cu) {
                $h = @()
                $deadline = (Get-Date).AddSeconds(120)
                do {
                    $h = Get-OurHelper -Agent $Agent -SessionId $cu.SessionId
                    if ($h.Count -gt 0) { break }
                    Start-Sleep -Seconds 5
                } while ((Get-Date) -lt $deadline)
                if ($h.Count -gt 0) {
                    $summary.Add("helper pid $($h[0].ProcessId) in $($cu.User) session $($cu.SessionId)")
                } else {
                    Write-Log "No helper in $($cu.User) session $($cu.SessionId) after 120s; the service keeps retrying" 'WARN'
                    $summary.Add('helper not seen yet')
                }
            } else {
                $summary.Add('no console user; helper starts at next logon')
            }
        }

        # 6. Result.
        $final = Get-AgentService $Agent
        Write-Log "After: state=$($final.State) startMode=$($final.StartMode) exitCode=$($final.ExitCode) pid=$($final.ProcessId)"
        if ($final -and $final.State -eq 'Running') {
            $msg = 'OK: nothing needed fixing'
            if ($summary.Count -gt 0) { $msg = 'FIXED: ' + ($summary -join '; ') }
            Write-Log $msg
            return (New-Result $true $msg)
        }
        $msg = "FAILED: service still '$($final.State)' (exitCode $($final.ExitCode)) after remediation; see $($Agent.LogFile)"
        Write-Log $msg 'ERROR'
        return (New-Result $false $msg)
    }
    catch {
        Write-Log "Unhandled error: $($_.Exception.Message)" 'ERROR'
        return (New-Result $false "FAILED: $($_.Exception.Message)")
    }
}

# --- Remediation ---------------------------------------------------------------
$exitCode = 0
$parts = @()
try {
    $agents = @(Get-PiFocusAgents)
    if ($agents.Count -eq 0) {
        Write-Output 'OK: PiFocus agent is not installed - nothing to do'
        exit 0
    }
    foreach ($a in $agents) {
        $r = @(Repair-Agent $a)[-1]
        $parts += "[$($a.Env)] $($r.Message)"
        if (-not $r.Ok) { $exitCode = 1 }
    }
}
catch {
    $parts += "FAILED: $($_.Exception.Message)"
    $exitCode = 1
}
$msg = $parts -join ' || '
Write-Output $msg.Substring(0, [Math]::Min(2000, $msg.Length))
exit $exitCode
