# PiFocus Agent — Intune Proactive Remediation

A **detect + remediate** script pair that keeps the PiFocus Windows service actually
*running* on company devices. It is deployed through **Intune → Devices → Remediations**
(Proactive Remediations), separately from the Win32 app in the repo root — no app
repackage or version bump is needed to ship or update it.

## Why this exists
The Win32 app's own `detect.ps1` only checks that the right `version.txt` is on disk; by
design it ignores whether the service is running. So a device whose service has been
stopped (or whose main loop is wedged) for days still reports *installed*, and Intune never
fixes it — meanwhile the helper keeps the last lock state it saw and the user books **0%
active / inactive**. This pair closes that gap.

| File | Role | Changes the device? |
|---|---|---|
| `Detect-PiFocusAgent.ps1` | Read-only health check. Exit **1** = problem found (Intune then runs remediate); exit **0** = healthy, not installed, or an install is in progress. | No |
| `Remediate-PiFocusAgent.ps1` | Repairs only what's broken; a healthy device is left untouched. Exit **0** = service Running at the end. | Yes |

## What it checks / fixes
1. **StartMode → Auto** (what `install.ps1` sets).
2. **SCM recovery re-armed** to exactly `install.ps1`'s policy — `reset= 86400
   actions= restart/5000/restart/10000/restart/30000` — **plus `failureflag 1`**, which
   `install.ps1` never sets, so an *error* stop (not just a crash) is also restarted.
3. **Service not Running** → starts it (kills a leftover `WindowService.exe` holding the
   pipe first; retries once).
4. **Service Running but wedged** → if the console user has had no `HelperService.exe` for
   10+ min (re-checked after 60 s), restarts the service.

It deliberately does **not** touch `HelperService.exe` (it reconnects itself), the pause
state (`HKLM\SOFTWARE\PiFocus\TrackingEnabled` is re-applied on start), or a missing service
registration (that's `install.ps1`'s job — reinstall the app instead).

Both **prod** and **stage** agents are discovered and handled automatically from the
services/folders that exist; nothing is hard-configured.

## Deploy in Intune
**Devices → Remediations → Create script package**
- **Detection script file:** `Detect-PiFocusAgent.ps1`
- **Remediation script file:** `Remediate-PiFocusAgent.ps1`
- **Run this script using the logged-on credentials:** **No** (runs as SYSTEM — the service
  SDDL only lets SYSTEM/Administrators start it)
- **Enforce script signature check:** No (unless you sign them)
- **Run script in 64-bit PowerShell:** **Yes**
- **Assignment → Schedule:** **Hourly** (the intended cadence)
- Assign to the device group that has the PiFocus app.

## Logs
Each run appends to `C:\ProgramData\PiFocus\Logs\Remediation.log` (next to `Install.log`;
`…\PiFocusStage\Logs\` for stage), rotated at 1 MB. Detection output also shows in the
Intune remediation report per device.

## Follow-up worth doing at the source
`install.ps1` arms the restart *actions* (line ~586) but never sets
`FailureActionsOnNonCrashFailures`, so every fresh install relies on this remediation to set
the flag on its first run. Adding `cmd.exe /c "sc failureflag $ServiceName 1"` right after
the `sc failure …` line would close that at install time (needs a package rebuild + version
bump to ship). The remediation covers it fleet-wide in the meantime.
