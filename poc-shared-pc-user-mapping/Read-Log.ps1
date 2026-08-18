<#
=============================================================================
  Read-Log.ps1  -  pretty-print a collected POC log
=============================================================================
  Usage:
    From this folder, after collecting a log:
      .\Read-Log.ps1
    Or point at a specific logs folder:
      .\Read-Log.ps1 -LogsDir "C:\path\to\logs"
  What it does:
    Reads user-events.log + snapshots.jsonl and prints:
      - watcher session boundaries ([START] / [STOP] pairs)
      - distinct users seen (with first-seen + last-seen timestamps)
      - session changes
      - device summary
      - any errors
      - JSONL validation (parse every line, report bad ones)
  Safe to run on any machine (including mine when you send me the log).
=============================================================================
#>

param(
    [string]$LogsDir = $null
)

if (-not $LogsDir) {
    $ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
    $LogsDir = Join-Path $ScriptDir "logs"
}

$EventsLog = Join-Path $LogsDir "user-events.log"
$JsonLog   = Join-Path $LogsDir "snapshots.jsonl"
$LatestLog = Join-Path $LogsDir "latest-user.json"
$ErrorsLog = Join-Path $LogsDir "errors.log"

Write-Host ""
Write-Host "  Read-Log  -  reviewing $LogsDir" -ForegroundColor Cyan
Write-Host "  ============================================================"
Write-Host ""

if (-not (Test-Path $LogsDir)) {
    Write-Host "  Logs folder does not exist: $LogsDir" -ForegroundColor Red
    Write-Host "  Did you run Start-Watcher.ps1 first?"
    return
}

# --- events log --------------------------------------------------------
if (-not (Test-Path $EventsLog)) {
    Write-Host "  user-events.log is missing" -ForegroundColor Yellow
} else {
    $events = @(Get-Content -Path $EventsLog -Encoding UTF8 -ErrorAction SilentlyContinue)
    Write-Host ("  user-events.log      : {0} lines" -f $events.Count)

    $starts   = @($events | Where-Object { $_ -match "\[START " })
    $stops    = @($events | Where-Object { $_ -match "\[STOP " })
    $changes  = @($events | Where-Object { $_ -match "\[CHANGE" })
    $devices  = @($events | Where-Object { $_ -match "\[DEVICE" })
    $users    = @($events | Where-Object { $_ -match "\[USER  " })
    $beats    = @($events | Where-Object { $_ -match "\[BEAT  " })
    $errsIn   = @($events | Where-Object { $_ -match "\[ERROR " })

    Write-Host ("    starts              : {0}" -f $starts.Count)
    Write-Host ("    stops               : {0}" -f $stops.Count)
    Write-Host ("    device snapshots    : {0}" -f $devices.Count)
    Write-Host ("    user snapshots      : {0}" -f $users.Count)
    Write-Host ("    session changes     : {0}" -f $changes.Count)
    Write-Host ("    hourly heartbeats   : {0}" -f $beats.Count)
    Write-Host ("    errors (event log)  : {0}" -f $errsIn.Count) -ForegroundColor $(if ($errsIn.Count -gt 0) { "Red" } else { "Green" })
}

Write-Host ""

# --- JSONL snapshots ---------------------------------------------------
$distinct = @{}
$deviceInfo = $null
$badLines = 0

if (-not (Test-Path $JsonLog)) {
    Write-Host "  snapshots.jsonl is missing" -ForegroundColor Yellow
} else {
    $jl = @(Get-Content -Path $JsonLog -Encoding UTF8 -ErrorAction SilentlyContinue)
    Write-Host ("  snapshots.jsonl      : {0} lines" -f $jl.Count)
    $parsedCount = 0
    foreach ($ln in $jl) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        try {
            $obj = $ln | ConvertFrom-Json -ErrorAction Stop
            $parsedCount++
            if (-not $deviceInfo -and $obj.device) { $deviceInfo = $obj.device }
            if ($obj.activeUser -and $obj.activeUser.email) {
                $email = [string]$obj.activeUser.email
                $ts = [string]$obj.timestamp
                if (-not $distinct.ContainsKey($email)) {
                    $distinct[$email] = [PSCustomObject]@{
                        WindowsUser = $obj.activeUser.windowsUser
                        Upn         = $obj.activeUser.upn
                        Sid         = $obj.activeUser.sid
                        FirstSeen   = $ts
                        LastSeen    = $ts
                        Snapshots   = 1
                    }
                } else {
                    $distinct[$email].LastSeen = $ts
                    $distinct[$email].Snapshots++
                }
            }
        } catch {
            $badLines++
        }
    }
    Write-Host ("    parsed successfully : {0}" -f $parsedCount) -ForegroundColor Green
    if ($badLines -gt 0) {
        Write-Host ("    bad lines           : {0}" -f $badLines) -ForegroundColor Red
    }
}

Write-Host ""

# --- device summary ----------------------------------------------------
if ($deviceInfo) {
    Write-Host "  DEVICE" -ForegroundColor Cyan
    $usable = if ($deviceInfo.biosSerialUsable) { "usable" } else { "placeholder" }
    Write-Host ("    hostname            : {0}" -f $deviceInfo.hostname)
    Write-Host ("    type                : {0}" -f $deviceInfo.type)
    Write-Host ("    biosSerial          : '{0}' ({1})" -f $deviceInfo.biosSerial, $usable)
    Write-Host ("    intuneDeviceId      : {0}" -f $(if ($deviceInfo.intuneDeviceId) { $deviceInfo.intuneDeviceId } else { "null (personal device)" }))
    Write-Host ("    aadJoined           : {0}" -f $deviceInfo.aadJoined)
    Write-Host ("    mdmEnrolled         : {0}" -f $deviceInfo.mdmEnrolled)
    Write-Host ("    chassisType         : {0} ({1})" -f $deviceInfo.chassisTypeName, $deviceInfo.chassisTypeCode)
    Write-Host ""
}

# --- distinct users ----------------------------------------------------
if ($distinct.Count -gt 0) {
    Write-Host "  DISTINCT USERS SEEN ($($distinct.Count))" -ForegroundColor Cyan
    foreach ($k in $distinct.Keys) {
        $u = $distinct[$k]
        Write-Host ("    {0}" -f $k) -ForegroundColor White
        Write-Host ("      windows account : {0}" -f $u.WindowsUser)
        Write-Host ("      UPN             : {0}" -f $u.Upn)
        Write-Host ("      SID             : {0}" -f $u.Sid)
        Write-Host ("      first seen      : {0}" -f $u.FirstSeen)
        Write-Host ("      last  seen      : {0}" -f $u.LastSeen)
        Write-Host ("      snapshot count  : {0}" -f $u.Snapshots)
        Write-Host ""
    }
} else {
    Write-Host "  DISTINCT USERS SEEN : 0" -ForegroundColor Yellow
    Write-Host "    No user snapshots found - watcher may not have run long enough."
    Write-Host ""
}

# --- errors log --------------------------------------------------------
if (Test-Path $ErrorsLog) {
    $errs = @(Get-Content -Path $ErrorsLog -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($errs.Count -gt 0) {
        Write-Host "  ERRORS ($($errs.Count) lines in errors.log)" -ForegroundColor Red
        foreach ($e in ($errs | Select-Object -Last 10)) {
            Write-Host ("    $e") -ForegroundColor DarkRed
        }
        Write-Host ""
    }
}

# --- verdict -----------------------------------------------------------
Write-Host "  VERDICT" -ForegroundColor Cyan
if ($distinct.Count -eq 0) {
    Write-Host "    Watcher captured no user snapshots - inconclusive." -ForegroundColor Yellow
}
elseif ($distinct.Count -eq 1) {
    Write-Host "    Watcher saw a single user throughout the run." -ForegroundColor Green
    Write-Host "    Expected on a laptop or a PC with only one active user."
    Write-Host "    For the shared-PC test, we need >= 2 distinct users."
}
else {
    Write-Host "    $($distinct.Count) distinct users seen." -ForegroundColor Green
    Write-Host "    POC succeeds - we can distinguish who was on the PC at what time by email."
}
Write-Host ""
