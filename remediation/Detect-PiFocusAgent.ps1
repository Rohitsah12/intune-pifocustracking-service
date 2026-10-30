<#
    PiFocus Agent - Intune Remediations: DETECTION script
    ===========================================================================
    Runs as-is on every device. There is nothing to configure: it finds the
    PiFocus agent installed on the device and checks it. Devices without
    PiFocus exit 0 and are left alone.

    Exit 1 = a problem was found -> Intune runs Remediate-PiFocusAgent.ps1
    Exit 0 = healthy, not installed, or an install is in progress

    READ-ONLY. Changes nothing on the device.

    Why the app's own detect.ps1 cannot be used as this detection script:
    it only checks that the right version.txt is on disk and, by design,
    ignores whether the service is running. A device whose service has been
    stopped for 11 days still reports INSTALLED (exit 0), so Intune would
    never run the fix.

    What it checks (taken from WindowService/main.cpp, HelperService/main.cpp
    and install.ps1):

      1. The PiFocus service is registered, StartMode = Auto, State = Running.
         When the service is down the helper keeps running on its own, its
         GET_LOCK_STATE pipe call fails, and it keeps the LAST lock state it saw
         (HelperService/main.cpp ~2399). If that was "locked", every minute is
         booked as None / Windows Locked -> the user shows 0% active.

      2. SCM recovery is fully armed: restart actions present AND
         FailureActionsOnNonCrashFailures = 1. install.ps1 sets the actions but
         never the flag, so when the worker thread dies on an exception and
         reports SERVICE_STOPPED with an error code (main.cpp ~3100), Windows
         does NOT restart it. An install.ps1 run that aborts after
         "sc config start= disabled" also leaves the service disabled with
         recovery cleared.

      3. If a user is at the console, the agent's own HelperService.exe is
         running in that user's session. The service's helper watchdog
         respawns a missing helper within seconds, so a helper missing for
         10+ minutes means the service main loop is wedged even though SCM
         still says Running.

    Intune settings:
      Run this script using the logged-on credentials : No  (runs as SYSTEM)
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

# --- Shared functions (identical copy in Remediate-PiFocusAgent.ps1) --------

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

# --- Detection-only functions --------------------------------------------------

function Test-Agent($Agent) {
    $issues = New-Object System.Collections.Generic.List[string]
    $notes  = New-Object System.Collections.Generic.List[string]
    $result = [pscustomobject]@{ Issues = $issues; Notes = $notes }

    $busy = Get-InstallerActivity $Agent
    if ($busy) { $notes.Add("skipped this run, $busy"); return $result }

    $svc = Get-AgentService $Agent
    if (-not $svc) {
        $issues.Add("$($Agent.ServiceExe) exists but service $($Agent.ServiceName) is not registered - reinstall the PiFocus app")
        return $result
    }

    if ($svc.StartMode -ne 'Auto') { $issues.Add("startMode=$($svc.StartMode)") }

    if ($svc.State -ne 'Running') {
        $issues.Add("state=$($svc.State) exitCode=$($svc.ExitCode)")
        $logAge = Get-ServiceLogAgeHours $Agent
        if ($null -ne $logAge) { $notes.Add("newest service log ${logAge}h old") }
        $orphans = Get-OurHelper -Agent $Agent
        if ($orphans.Count -gt 0) {
            $notes.Add("helper pid $($orphans[0].ProcessId) running without the service (user recorded as idle)")
        }
    }

    $rec = Get-RecoveryState $Agent
    if (-not $rec.ActionsOk)      { $issues.Add('SCM restart actions missing') }
    if (-not $rec.NonCrashFlagOk) { $issues.Add('SCM recovery flag off (error stops are never restarted)') }

    $helperProblem = Get-HelperProblem $Agent
    if ($helperProblem) { $issues.Add($helperProblem) }

    if ($svc.State -eq 'Running' -and $svc.ProcessId) {
        $proc = Get-Process -Id $svc.ProcessId -ErrorAction SilentlyContinue
        if ($proc) { $notes.Add(('service pid {0} up {1:N1}h' -f $svc.ProcessId, ((Get-Date) - $proc.StartTime).TotalHours)) }
        $helpers = Get-OurHelper -Agent $Agent
        if ($helpers.Count -gt 0) { $notes.Add("helper pid $($helpers[0].ProcessId) session $($helpers[0].SessionId)") }
    }
    return $result
}

# --- Detection ---------------------------------------------------------------
try {
    $agents = @(Get-PiFocusAgents)
    if ($agents.Count -eq 0) {
        Write-Output 'OK: PiFocus agent is not installed on this device'
        exit 0
    }

    $parts = @()
    $found = $false
    foreach ($a in $agents) {
        $r = @(Test-Agent $a)[-1]
        $tail = ''
        if ($r.Notes.Count -gt 0) { $tail = ' | ' + ($r.Notes -join '; ') }
        if ($r.Issues.Count -gt 0) {
            $found = $true
            $parts += "ISSUE [$($a.Env)]: " + ($r.Issues -join '; ') + $tail
        } else {
            $parts += "OK [$($a.Env)]" + $tail
        }
    }

    $msg = $parts -join ' || '
    Write-Output $msg.Substring(0, [Math]::Min(2000, $msg.Length))
    if ($found) { exit 1 }
    exit 0
}
catch {
    # A broken check must never trigger a service restart.
    Write-Output "OK (detection error, nothing changed): $($_.Exception.Message)"
    exit 0
}
