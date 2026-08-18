<#
=============================================================================
  PiFocus POC - Shared-PC user attribution watcher   (READ-ONLY, NO INSTALL)
=============================================================================
  What this proves:
    On a shared company PC, we can reliably detect which user is currently
    signed in (email/UPN) alongside the device's Intune Device ID. The two
    together let a future backend attribute activity per-user instead of
    per-device.

  What this does NOT do:
    - No changes to your system. No install. No admin required.
    - No Scheduled Task, no service, no registry writes anywhere.
    - No network calls. No backend POST. Just writes a local log file.

  How to run:
    Right-click Start-Watcher.ps1 -> Run with PowerShell
      (or from a PowerShell prompt in this folder: .\Start-Watcher.ps1)
    Leave the window running. Use the machine normally. When done, Ctrl+C.
    Then zip the .\logs\ folder and send it back.

  Log files (all inside .\logs\ next to this script):
    user-events.log   human-readable timeline
    snapshots.jsonl   machine-readable, one JSON object per line
    latest-user.json  the most recent snapshot, overwritten each change
    errors.log        only if the watcher hits an exception
=============================================================================
#>

$ErrorActionPreference = "Continue"

# ---- paths (relative to this script) ---------------------------------------
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$LogsDir   = Join-Path $ScriptDir "logs"
if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null }
$EventsLog = Join-Path $LogsDir "user-events.log"
$JsonLog   = Join-Path $LogsDir "snapshots.jsonl"
$LatestLog = Join-Path $LogsDir "latest-user.json"
$ErrorsLog = Join-Path $LogsDir "errors.log"

# ---- config ---------------------------------------------------------------
$PollSec       = 5
$HeartbeatSec  = 3600

# ---- P/Invoke: mirrors what WindowService main.cpp:793-889 does in C++ ----
if (-not ("Poc.Wts" -as [type])) {
    Add-Type -Namespace Poc -Name Wts -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint WTSGetActiveConsoleSessionId();
[System.Runtime.InteropServices.DllImport("wtsapi32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto, SetLastError=true)]
public static extern bool WTSQuerySessionInformation(System.IntPtr hServer, uint SessionId, int WTSInfoClass, out System.IntPtr ppBuffer, out uint pBytesReturned);
[System.Runtime.InteropServices.DllImport("wtsapi32.dll")]
public static extern void WTSFreeMemory(System.IntPtr pMemory);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
[System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError=true)]
public static extern bool OpenProcessToken(System.IntPtr ProcessHandle, uint DesiredAccess, out System.IntPtr TokenHandle);
[System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError=true)]
public static extern bool DuplicateTokenEx(System.IntPtr hExistingToken, uint dwDesiredAccess, System.IntPtr lpTokenAttributes, int ImpersonationLevel, int TokenType, out System.IntPtr phNewToken);
[System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool CreateProcessWithTokenW(System.IntPtr hToken, uint dwLogonFlags, string lpApplicationName, string lpCommandLine, uint dwCreationFlags, System.IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CreatePipe(out System.IntPtr hReadPipe, out System.IntPtr hWritePipe, ref SECURITY_ATTRIBUTES lpPipeAttributes, uint nSize);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetHandleInformation(System.IntPtr hObject, uint dwMask, uint dwFlags);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(System.IntPtr hObject);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern uint WaitForSingleObject(System.IntPtr hHandle, uint dwMilliseconds);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool ReadFile(System.IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, System.IntPtr lpOverlapped);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern uint GetProcessId(System.IntPtr Process);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct SECURITY_ATTRIBUTES { public uint nLength; public System.IntPtr lpSecurityDescriptor; public int bInheritHandle; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public struct STARTUPINFO {
    public uint cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public uint dwX; public uint dwY; public uint dwXSize; public uint dwYSize;
    public uint dwXCountChars; public uint dwYCountChars; public uint dwFillAttribute; public uint dwFlags;
    public ushort wShowWindow; public ushort cbReserved2; public System.IntPtr lpReserved2;
    public System.IntPtr hStdInput; public System.IntPtr hStdOutput; public System.IntPtr hStdError;
}
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct PROCESS_INFORMATION { public System.IntPtr hProcess; public System.IntPtr hThread; public uint dwProcessId; public uint dwThreadId; }
"@ -ErrorAction Stop
}
$WTS_INFO_UserName   = 5
$WTS_INFO_DomainName = 7

# ---- borrow a session user's token, then run whoami /upn as them ----------
# Solves the case where the watcher is running elevated as a DIFFERENT admin
# (e.g. shared PC where IT/support signed in with a WindowAdmin account to
# elevate, but the person actually using the machine is someone else).
# Mirrors the impersonation dance that WindowService/WebSocketManager.cpp uses
# in prod -- except that instead of WTSQueryUserToken (which needs SYSTEM),
# we borrow a token from an existing process running in the target session
# (which needs SeDebugPrivilege + SeImpersonatePrivilege, both of which
# elevated admins already have).
#
# Returns "" on any failure. Caller falls back to whatever it had before.
function Get-UpnByBorrowingSessionToken {
    param([uint32]$SessionId)

    if ($SessionId -eq 0xFFFFFFFF) { return "" }

    # Rights we need on the target process + token
    $PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    $TOKEN_DUPLICATE = 0x0002
    $TOKEN_QUERY     = 0x0008
    $TOKEN_ASSIGN_PRIMARY = 0x0001
    $MAXIMUM_ALLOWED = 0x02000000

    # Pick explorer.exe in the target session as our token donor -- it's
    # essentially always present in an interactive Windows session and it
    # runs as the signed-in user. Fall back to any process in the session
    # that isn't a system service.
    $donor = $null
    try {
        $procs = Get-CimInstance Win32_Process -Filter "SessionId=$SessionId" -ErrorAction SilentlyContinue
        $donor = $procs | Where-Object { $_.Name -ieq 'explorer.exe' } | Select-Object -First 1
        if (-not $donor) {
            $donor = $procs |
                Where-Object { $_.Name -notmatch '^(svchost|winlogon|lsass|csrss|dwm|fontdrvhost|smss|System)\.exe$' } |
                Select-Object -First 1
        }
    } catch {}
    if (-not $donor) { return "" }

    $hProc = [Poc.Wts]::OpenProcess($PROCESS_QUERY_LIMITED_INFORMATION, $false, [uint32]$donor.ProcessId)
    if ($hProc -eq [IntPtr]::Zero) { return "" }

    $hUserTok = [IntPtr]::Zero
    if (-not [Poc.Wts]::OpenProcessToken($hProc, ($TOKEN_DUPLICATE -bor $TOKEN_QUERY), [ref]$hUserTok)) {
        [void][Poc.Wts]::CloseHandle($hProc)
        return ""
    }
    [void][Poc.Wts]::CloseHandle($hProc)

    # Duplicate into a PRIMARY token so CreateProcessWithTokenW accepts it
    $hPrimary = [IntPtr]::Zero
    $SecurityImpersonation = 2
    $TokenPrimary = 1
    if (-not [Poc.Wts]::DuplicateTokenEx($hUserTok, $MAXIMUM_ALLOWED, [IntPtr]::Zero, $SecurityImpersonation, $TokenPrimary, [ref]$hPrimary)) {
        [void][Poc.Wts]::CloseHandle($hUserTok)
        return ""
    }
    [void][Poc.Wts]::CloseHandle($hUserTok)

    # Create an anonymous stdout pipe so we can capture whoami's output
    $sa = New-Object Poc.Wts+SECURITY_ATTRIBUTES
    $sa.nLength = [System.Runtime.InteropServices.Marshal]::SizeOf($sa)
    $sa.bInheritHandle = 1
    $sa.lpSecurityDescriptor = [IntPtr]::Zero
    $hReadPipe = [IntPtr]::Zero
    $hWritePipe = [IntPtr]::Zero
    if (-not [Poc.Wts]::CreatePipe([ref]$hReadPipe, [ref]$hWritePipe, [ref]$sa, 0)) {
        [void][Poc.Wts]::CloseHandle($hPrimary)
        return ""
    }
    # The read end must NOT be inherited by the child (avoids child holding
    # it open forever).
    [void][Poc.Wts]::SetHandleInformation($hReadPipe, 1 <# HANDLE_FLAG_INHERIT #>, 0)

    $si = New-Object Poc.Wts+STARTUPINFO
    $si.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($si)
    $si.dwFlags = 0x00000101  # STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW
    $si.wShowWindow = 0       # SW_HIDE
    $si.hStdOutput = $hWritePipe
    $si.hStdError  = $hWritePipe
    $si.hStdInput  = [IntPtr]::Zero
    $si.lpDesktop  = "winsta0\default"
    $pi = New-Object Poc.Wts+PROCESS_INFORMATION

    $LOGON_WITH_PROFILE = 1
    $CREATE_NO_WINDOW   = 0x08000000
    $whoami = Join-Path $env:SystemRoot 'System32\whoami.exe'
    $cmdline = "`"$whoami`" /upn"

    $ok = [Poc.Wts]::CreateProcessWithTokenW($hPrimary, $LOGON_WITH_PROFILE, $null, $cmdline, $CREATE_NO_WINDOW, [IntPtr]::Zero, $null, [ref]$si, [ref]$pi)
    [void][Poc.Wts]::CloseHandle($hPrimary)
    # Close our copy of the write end so ReadFile can hit EOF once the child exits.
    [void][Poc.Wts]::CloseHandle($hWritePipe)

    if (-not $ok) {
        [void][Poc.Wts]::CloseHandle($hReadPipe)
        return ""
    }

    # Read whoami's stdout until it closes
    $bytesList = New-Object System.Collections.Generic.List[byte]
    $buf = New-Object byte[] 512
    while ($true) {
        $read = 0
        $r = [Poc.Wts]::ReadFile($hReadPipe, $buf, [uint32]$buf.Length, [ref]$read, [IntPtr]::Zero)
        if (-not $r -or $read -eq 0) { break }
        for ($i = 0; $i -lt $read; $i++) { $bytesList.Add($buf[$i]) }
    }
    [void][Poc.Wts]::WaitForSingleObject($pi.hProcess, 3000)
    [void][Poc.Wts]::CloseHandle($pi.hThread)
    [void][Poc.Wts]::CloseHandle($pi.hProcess)
    [void][Poc.Wts]::CloseHandle($hReadPipe)

    if ($bytesList.Count -eq 0) { return "" }
    # whoami /upn outputs in the console codepage (typically OEM). Try UTF-8
    # first, then default codepage as a fallback -- UPNs are ASCII so it
    # rarely matters.
    $text = [System.Text.Encoding]::UTF8.GetString($bytesList.ToArray()).Trim()
    if (-not $text) { $text = [System.Text.Encoding]::Default.GetString($bytesList.ToArray()).Trim() }
    if ($text -match "@") { return $text }
    return ""
}

function Get-WtsString {
    param([uint32]$SessionId, [int]$InfoClass)
    $buf = [IntPtr]::Zero
    [uint32]$bytes = 0
    $ok = [Poc.Wts]::WTSQuerySessionInformation([IntPtr]::Zero, $SessionId, $InfoClass, [ref]$buf, [ref]$bytes)
    if (-not $ok -or $buf -eq [IntPtr]::Zero) { return $null }
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($buf)
    } finally {
        [Poc.Wts]::WTSFreeMemory($buf)
    }
}

# ---- bad-serial detector (mirrors DeviceTokenManager.cpp:320-332) ---------
# Exact list matches the C++ agent verbatim so the POC agrees with what the
# real service would decide. Any serial listed as "exact" is bad ONLY if the
# whole string equals it (so a real serial like "5CD410154Z" is not falsely
# flagged just because it contains "0"). Substrings are those where any
# occurrence anywhere in the serial marks it as a placeholder.
function Test-SerialUsable {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    $ll = $s.ToLower().Trim()
    $exact = @("unknown","n/a","none","default string","system serial number","not applicable","not specified","0","1234567890","oem","o.e.m")
    $substr = @("default string","to be filled")
    if ($exact -contains $ll) { return $false }
    foreach ($sub in $substr) { if ($ll.Contains($sub)) { return $false } }
    return $true
}

# ---- chassis type map (SMBIOS Table 3) ------------------------------------
function Get-ChassisTypeName {
    param([int]$Code)
    switch ($Code) {
        3  { "Desktop" }
        4  { "LowProfileDesktop" }
        5  { "PizzaBox" }
        6  { "MiniTower" }
        7  { "Tower" }
        8  { "Portable" }
        9  { "Laptop" }
        10 { "Notebook" }
        11 { "HandHeld" }
        14 { "SubNotebook" }
        30 { "Tablet" }
        31 { "Convertible" }
        32 { "Detachable" }
        default { "Other($Code)" }
    }
}
function Test-IsLaptopChassis { param([int]$Code) return ($Code -in 8,9,10,11,14,30,31,32) }

# ---- device fingerprint (refreshed on start + hourly) ---------------------
function Get-DeviceFingerprint {
    $bios = try { Get-CimInstance Win32_BIOS -ErrorAction Stop } catch { $null }
    $enc  = try { Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop } catch { $null }
    $bat  = try { Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue } catch { $null }

    $serial = if ($bios) { ($bios.SerialNumber -as [string]) } else { $null }
    if ($serial) { $serial = $serial.Trim() }
    $usable = Test-SerialUsable $serial

    $ctype  = if ($enc -and $enc.ChassisTypes) { [int]($enc.ChassisTypes[0]) } else { 0 }
    $ctname = Get-ChassisTypeName $ctype
    $isLap  = Test-IsLaptopChassis $ctype
    if (-not $isLap -and $bat) { $isLap = $true }  # battery is a strong hint
    $devType = if ($isLap) { "Laptop" } else { "PC" }

    # dsregcmd may be absent on very old Windows or not fully populated on
    # personal/workgroup devices - treat every field as optional.
    $intune=$null; $tenant=$null; $mdmUrl=$null; $aad="NO"; $dom="NO"
    try {
        $dsr = & dsregcmd /status 2>$null
        if ($dsr) {
            $m = $dsr | Select-String "^\s*DeviceId\s*:\s*(.+)$" | Select-Object -First 1
            if ($m) { $intune = $m.Matches.Groups[1].Value.Trim() }
            $m = $dsr | Select-String "^\s*TenantId\s*:\s*(.+)$" | Select-Object -First 1
            if ($m) { $tenant = $m.Matches.Groups[1].Value.Trim() }
            $m = $dsr | Select-String "^\s*MdmUrl\s*:\s*(.+)$" | Select-Object -First 1
            if ($m) { $mdmUrl = $m.Matches.Groups[1].Value.Trim() }
            $m = $dsr | Select-String "^\s*AzureAdJoined\s*:\s*(YES|NO)" | Select-Object -First 1
            if ($m) { $aad = $m.Matches.Groups[1].Value }
            $m = $dsr | Select-String "^\s*DomainJoined\s*:\s*(YES|NO)" | Select-Object -First 1
            if ($m) { $dom = $m.Matches.Groups[1].Value }
        }
    } catch {}
    $mdmYes   = -not [string]::IsNullOrWhiteSpace($mdmUrl)
    $personal = ($aad -eq "NO" -and $dom -eq "NO")

    [PSCustomObject]@{
        hostname         = $env:COMPUTERNAME
        type             = $devType
        biosSerial       = $serial
        biosSerialUsable = $usable
        intuneDeviceId   = $intune
        aadDeviceId      = $intune
        aadJoined        = ($aad -eq "YES")
        domainJoined     = ($dom -eq "YES")
        mdmEnrolled      = $mdmYes
        mdmUrl           = $mdmUrl
        tenantId         = $tenant
        chassisTypeCode  = $ctype
        chassisTypeName  = $ctname
        hasBattery       = ($bat -ne $null)
        personalDevice   = $personal
    }
}

# ---- active user snapshot -------------------------------------------------
function Get-ActiveUserSnapshot {
    $sid = [Poc.Wts]::WTSGetActiveConsoleSessionId()
    # 0xFFFFFFFF means "no active console session" (screen locked, no user logged in).
    # We compare against [uint32]::MaxValue rather than [uint32]0xFFFFFFFF because
    # PowerShell 5.1 parses the hex literal as Int32 first (-1) and then can't
    # cast to UInt32.
    if ($sid -eq [uint32]::MaxValue) {
        return [PSCustomObject]@{
            sessionId        = $null
            windowsUser      = "<none>"
            sid              = $null
            upn              = $null
            email            = $null
            emailSource      = "none (no console user)"
            sessionType      = "None"
            logonTime        = $null
            hasPiFocusToken  = $false
            piFocusTokenMask = $null
        }
    }
    $username = Get-WtsString $sid $WTS_INFO_UserName
    $domain   = Get-WtsString $sid $WTS_INFO_DomainName
    $winUser = "<unresolved>"
    if ($username) {
        if ($domain) { $winUser = "$domain\$username" } else { $winUser = $username }
    }

    # SID via NTAccount lookup
    $sidStr = $null
    if ($winUser -notmatch "unresolved|none") {
        try { $sidStr = (New-Object System.Security.Principal.NTAccount($winUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch {}
    }

    # UPN / email - try each source in order.
    #
    # Case A: watcher runs as the same user who is signed in (typical
    #         unelevated launch)  -> `whoami /upn` returns the right UPN.
    # Case B: watcher runs elevated as a DIFFERENT admin (shared-PC IT
    #         support scenario: signed in as Rohit, elevated as
    #         WindowAdmin) -> `whoami /upn` returns WindowAdmin's identity,
    #         which is not the person we care about. We fall back to
    #         Get-UpnByBorrowingSessionToken, which mirrors the
    #         impersonation dance WindowService/WebSocketManager.cpp does
    #         in prod: borrow explorer.exe's token from the active session
    #         and run whoami as that user.
    $upn = $null; $email = $null; $src = "none"
    $currentIdentity = "$env:USERDOMAIN\$env:USERNAME"
    $watcherMatchesActiveUser = ($winUser -eq $currentIdentity)

    if ($watcherMatchesActiveUser) {
        try {
            $up = & whoami /upn 2>$null
            if ($LASTEXITCODE -eq 0 -and $up) {
                $candidate = ($up | Select-Object -First 1).Trim()
                if ($candidate -and $candidate -match "@") {
                    $upn = $candidate; $email = $candidate; $src = "whoami /upn"
                }
            }
        } catch {}
    }

    # Fallback: borrow the active session's token and run whoami as them.
    # Works whether or not the watcher is elevated -- the P/Invoke calls
    # just no-op and return "" if we lack the privilege.
    if (-not $email) {
        try {
            $borrowed = Get-UpnByBorrowingSessionToken -SessionId ([uint32]$sid)
            if ($borrowed -and $borrowed -match "@") {
                $upn = $borrowed; $email = $borrowed; $src = "whoami /upn via borrowed session token"
            }
        } catch {}
    }

    if (-not $email) {
        try {
            $dsr = & dsregcmd /status 2>$null
            $m = $dsr | Select-String "^\s*UserEmail\s*:\s*(.+)$" | Select-Object -First 1
            if ($m) { $email = $m.Matches.Groups[1].Value.Trim(); $src = "dsregcmd UserEmail" }
            elseif (($m = $dsr | Select-String "^\s*UserAccountName\s*:\s*(.+)$" | Select-Object -First 1)) {
                $email = $m.Matches.Groups[1].Value.Trim()
                if (-not $upn) { $upn = $email }
                $src = "dsregcmd UserAccountName"
            }
        } catch {}
    }
    if (-not $email) {
        $email = $username
        $src = "windows account name (fallback)"
    }
    if (-not $upn) { $upn = "<none - workgroup or unknown>" }

    # Session type + logon time
    $sType = "Interactive"
    $lTime = $null
    try {
        $ls = Get-CimInstance Win32_LogonSession -ErrorAction SilentlyContinue |
              Where-Object { $_.LogonType -in 2,10 } |
              Select-Object -First 1
        if ($ls) {
            $sType = if ($ls.LogonType -eq 10) { "RemoteInteractive" } else { "Interactive" }
            $lTime = $ls.StartTime
        }
    } catch {}

    # PiFocus token presence (masked)
    $tokPresent = $false
    $tokFingerprint = $null
    if ($sidStr) {
        try {
            $p = Get-ItemProperty "Registry::HKEY_USERS\$sidStr\Software\PiFocus\Helper" -ErrorAction Stop
            if ($p.DeviceApiKey) {
                $tokPresent = $true
                $t = [string]$p.DeviceApiKey
                if ($t.Length -gt 8) {
                    $tokFingerprint = "{0}...{1} (len={2})" -f $t.Substring(0,4),$t.Substring($t.Length-4),$t.Length
                } else {
                    $tokFingerprint = "(short: len=$($t.Length))"
                }
            }
        } catch {}
    }

    [PSCustomObject]@{
        sessionId        = [int]$sid
        windowsUser      = $winUser
        sid              = $sidStr
        upn              = $upn
        email            = $email
        emailSource      = $src
        sessionType      = $sType
        logonTime        = if ($lTime) { $lTime.ToUniversalTime().ToString("o") } else { $null }
        hasPiFocusToken  = $tokPresent
        piFocusTokenMask = $tokFingerprint
    }
}

# ---- logging helpers ------------------------------------------------------
function TS { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

function Write-EventLine {
    param([string]$Tag, [string]$Msg)
    $line = "{0} [{1}]  {2}" -f (TS), $Tag.PadRight(6), $Msg
    Write-Host $line
    Add-Content -Path $EventsLog -Value $line -Encoding UTF8
}

function Write-Snapshot {
    param([PSCustomObject]$Device, [PSCustomObject]$User)
    $elev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $snap = [PSCustomObject]@{
        schemaVersion = 1
        timestamp     = TS
        device        = $Device
        activeUser    = $User
        watcherContext = [PSCustomObject]@{
            runningAs = "$env:USERDOMAIN\$env:USERNAME"
            processId = $PID
            elevated  = $elev
        }
    }
    $jsonCompact = ($snap | ConvertTo-Json -Depth 6 -Compress)
    Add-Content -Path $JsonLog -Value $jsonCompact -Encoding UTF8
    ($snap | ConvertTo-Json -Depth 6) | Out-File -FilePath $LatestLog -Encoding UTF8
}

# ---- main loop ------------------------------------------------------------
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$elevatedStr = if ($elevated) { "YES (can read all HKU hives)" } else { "no (that's OK for POC)" }

Write-Host ""
Write-Host "  PiFocus POC - Shared-PC user watcher" -ForegroundColor Cyan
Write-Host "  ------------------------------------" -ForegroundColor Cyan
Write-Host "  Logs folder : $LogsDir"
Write-Host "  Running as  : $env:USERDOMAIN\$env:USERNAME"
Write-Host "  Elevated    : $elevatedStr"
Write-Host "  Poll every  : $PollSec seconds"
Write-Host "  Ctrl+C      : stop the watcher (log flushes cleanly)"
Write-Host ""

Write-EventLine "START" ("watcher up (pid={0}, ctx={1}, hostname={2})" -f $PID, $env:USERNAME, $env:COMPUTERNAME)

try {
    $device = Get-DeviceFingerprint
    $usableStr = if ($device.biosSerialUsable) { "usable" } else { "placeholder" }
    $intuneStr = if ($device.intuneDeviceId)   { $device.intuneDeviceId } else { "null (personal device)" }
    $aadStr    = if ($device.aadJoined)        { "YES" } else { "NO" }
    Write-EventLine "DEVICE" ("type={0} bios='{1}'({2}) intuneDeviceId={3} aadJoined={4} chassis={5}({6})" -f $device.type, $device.biosSerial, $usableStr, $intuneStr, $aadStr, $device.chassisTypeName, $device.chassisTypeCode)

    # first user snapshot
    $user = Get-ActiveUserSnapshot
    $tokStr = if ($user.hasPiFocusToken) { "yes" } else { "no" }
    Write-EventLine "USER" ("session={0} user={1} sid={2} upn={3} email={4}(src={5}) piFocusToken={6}" -f $user.sessionId, $user.windowsUser, $user.sid, $user.upn, $user.email, $user.emailSource, $tokStr)
    Write-Snapshot $device $user

    $lastUser = $user.windowsUser
    $lastFingerprintTime = Get-Date
    $lastHeartbeat = Get-Date

    while ($true) {
        Start-Sleep -Seconds $PollSec
        $now = Get-Date

        # refresh device fingerprint hourly (in case Intune enrollment changes mid-session)
        if (($now - $lastFingerprintTime).TotalSeconds -gt 3600) {
            $device = Get-DeviceFingerprint
            $lastFingerprintTime = $now
        }

        try {
            $user = Get-ActiveUserSnapshot
        } catch {
            $err = "{0} [ERROR] user-snapshot failed: {1}" -f (TS), $_.Exception.Message
            Add-Content -Path $ErrorsLog -Value $err -Encoding UTF8
            continue
        }

        if ($user.windowsUser -ne $lastUser) {
            Write-EventLine "CHANGE" ("old={0} new={1}({2})" -f $lastUser, $user.windowsUser, $user.email)
            $tokStr = if ($user.hasPiFocusToken) { "yes" } else { "no" }
            Write-EventLine "USER" ("session={0} user={1} sid={2} upn={3} email={4}(src={5}) piFocusToken={6}" -f $user.sessionId, $user.windowsUser, $user.sid, $user.upn, $user.email, $user.emailSource, $tokStr)
            Write-Snapshot $device $user
            $lastUser = $user.windowsUser
            $lastHeartbeat = $now
        }
        elseif (($now - $lastHeartbeat).TotalSeconds -gt $HeartbeatSec) {
            Write-EventLine "BEAT" ("still user={0} (hourly heartbeat)" -f $user.windowsUser)
            Write-Snapshot $device $user
            $lastHeartbeat = $now
        }
    }
}
finally {
    Write-EventLine "STOP" "watcher exiting (Ctrl+C received or terminal closed)"
}
