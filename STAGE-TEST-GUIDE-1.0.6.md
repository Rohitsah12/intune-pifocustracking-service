# PiFocus Control-Plane Sync — Stage Test Guide (v1.0.6)

Backend stage is live. This guide covers installing the **stage** services + Electron app
and testing every control-plane behaviour end-to-end against `stage-api.penpencil.co`.

> Stage installs **side-by-side** with prod — different service name, folders, registry,
> API host. Testing stage will NOT touch a prod install on the same machine.

| | Stage | (prod, untouched) |
|---|---|---|
| Service | `PiFocusWindowServiceStage` | `PiFocusWindowService` |
| Install dir | `C:\Program Files\PiFocus\AgentStage` | `...\Agent` |
| ProgramData | `C:\ProgramData\PiFocusStage` | `...\PiFocus` |
| Logs/reports | `C:\ProgramData\ProgramMonitorStage` | `...\ProgramMonitor` |
| Registry | `HKLM\SOFTWARE\PiFocusStage` | `...\PiFocus` |
| API / WS | `stage-api.penpencil.co` / `stage-pi-os-backend.penpencil.co` | `api…` / `pi-os-backend…` |

---

## 0. Artifacts built (this session)

**Services (Intune-style) — `...\PiFocusBusinessTrackingService\`:**
- `_package_1.0.6_stage.zip`  ← extract + run `install.ps1` (manual install)
- `_package_1.0.6_stage\`      ← same, unzipped
- `dist_intunewin\PiFocusAgent-1.0.6-stage.intunewin`  ← upload to Intune

**Electron app — `C:\pi-focus-business-electron\release\build-stage\`:**
- `piFocus Business Staging Setup 1.1.6.exe`  (app v1.1.6; bundles service build v1.0.6)

Both carry verified control-plane markers (`/agent/state` in WindowService, `state.version_hint`
in HelperService) — Build-Package refuses to ship a binary that predates this work.

---

## 1. Pre-requisites (on the stage backend / admin panel)

1. A **test device** identity + a **user** assigned to it on stage (so `/agent/state` returns
   an assigned device, not 401).
2. Admin access to toggle, on stage, for that device: **tracking on/off**, **mode alert/halt**,
   **productivity config** (apps/domains/blockedWebsites/benchmarks), and **assign/unassign user**.
3. The device's **device token** must reach the machine. On the services-only path the token is
   fetched by the service; on the Electron path you log in through the app.

---

## 2. Install

### Option A — Services only (company-device / Intune topology)
1. Copy `_package_1.0.6_stage.zip` to the test machine, extract.
2. **Right-click PowerShell → Run as Administrator.**
3. `cd` into the extracted `_package_1.0.6_stage` folder.
4. `.\install.ps1`   *(env.txt auto-selects stage; it force-stops, replaces binaries, recreates + starts the service)*
5. Confirm the tail of `C:\ProgramData\PiFocusStage\Logs\Install.log` ends with:
   `==== PiFocus Agent Installed Successfully ====` and `VERDICT env=stage … Helper_fresh=True Window_fresh=True`.

### Option B — Electron app (personal-device topology)
1. Run `C:\pi-focus-business-electron\release\build-stage\piFocus Business Staging Setup 1.1.6.exe`.
   *(unsigned — SmartScreen may warn; "More info → Run anyway")*
2. Launch **piFocus Business Staging**, log in with the stage test account.
3. The app installs/updates the stage services itself and pushes the device token over the pipe.

> On this dual test device you can run **either** path. Both deliver the *same* stage binaries.
> If both are ever present, they share the one stage service — that's expected.

### Verify the service is up
```powershell
sc query PiFocusWindowServiceStage        # STATE should be RUNNING
Get-Process WindowService,HelperService | ft Name,Id,Path
```

---

## 3. Where to watch (logs)

**Runtime JSON logs** (one file per service per day):
```
C:\ProgramData\ProgramMonitorStage\debugLogs\<YYYY-MM-DD>-WindowService.json
C:\ProgramData\ProgramMonitorStage\debugLogs\<YYYY-MM-DD>-HelperService.json
```
Live-tail + filter to control-plane lines (PowerShell):
```powershell
$d = Get-Date -Format 'yyyy-MM-dd'
Get-Content "C:\ProgramData\ProgramMonitorStage\debugLogs\$d-WindowService.json" -Wait `
  | Select-String 'state\.|websocket\.|tracking\.'
```
```powershell
Get-Content "C:\ProgramData\ProgramMonitorStage\debugLogs\$d-HelperService.json" -Wait `
  | Select-String 'state\.|power\.|tracking\.'
```

**Other useful paths:**
- Install log: `C:\ProgramData\PiFocusStage\Logs\Install.log`
- Config cache: `C:\ProgramData\PiFocusStage\productivity_config.json`
- Activity/session files: `C:\ProgramData\ProgramMonitorStage\daily_reports\<date>.json`
- Held control-plane version (WindowService): `HKLM\SOFTWARE\PiFocusStage` value `StateVersion`
- Tracking state (registry): `HKLM\SOFTWARE\PiFocusStage` value `TrackingEnabled`
- `ProductivityConfig` fetch chatter is `OutputDebugString` → view with Sysinternals **DebugView**
  (run elevated, enable *Capture Global Win32*).

**Log tags (grep these in the JSON):**
| Tag (category) | Meaning |
|---|---|
| `state.apply` | applied/kept desired state — look at `phase`: `boot` / `poll` / `event` |
| `state.trigger` | a refresh was requested — reason: `reconnect` / `resume` / `ingest-version` / `ingest-401` |
| `state.fetch` | the actual GET /agent/state (status + body) |
| `websocket.token_rotate` | socket rebuilt with a fresh handshake token (reassign) |
| `tracking.toggle` / `tracking.pipe_set` | tracking flipped via WS command / Electron pipe |
| `state.version_hint` (Helper) | ingest carried a new stateVersion → nudged WindowService |
| `state.ingest401` (Helper) | ingest returned 401 → nudged WindowService to reconcile |
| `power.transition` (Helper) | suspend / resume detected |

---

## 4. Sanity check — boot convergence (items 1, 5)

1. Fresh install / `Restart-Service PiFocusWindowServiceStage`.
2. In the WindowService log expect one `state.apply` with `phase=boot`:
   - assigned + tracking on → `"applied desired state at boot"` tracking=enabled, plus a stored `StateVersion` in the registry.
   - if the admin **paused** the device before boot → `"applied desired state"` tracking=paused, and HelperService records nothing.
   - if unreachable → `"keeping last-known (registry) tracking state"` (never fails closed).

---

## 5. Control-plane test matrix

> For each: do the **backend action**, then watch the two logs for the **evidence**.

| # | Feature (item) | Backend action | Expected on device | Log evidence |
|---|---|---|---|---|
| 1 | **Boot apply** (1/5) | Pause device, then restart service | HelperService goes heartbeat-only, no new `daily_reports` rows | WS `state.apply phase=boot` tracking=paused |
| 2 | **Live pause (WS)** | Pause device (socket up) | Tracking stops within ~1s | WS `tracking.toggle … pause`; Helper `tracking.paused` |
| 3 | **Live resume (WS)** | Resume device (socket up) | Recording resumes | WS `tracking.toggle … resume`; Helper `tracking.resumed` |
| 4 | **Paused poll** (4) | While **paused**, just watch | Every ~240 s (±jitter) a self-poll fires | WS `state.fetch` GET /agent/state + `state.apply phase=poll`, recurring while paused |
| 5 | **Resume reaches a paused device w/o WS** (4) | Block WS host in firewall → pause → resume on backend | Resume still lands within one poll interval | WS `state.apply phase=poll` tracking=enabled (no `tracking.toggle`) |
| 6 | **Reconnect refetch** (3a) | Kill network ~30 s (or restart backend) so socket drops, change mode while down, restore | On reconnect it reconciles the missed change | WS `state.trigger …reconnect` → `state.apply phase=event` |
| 7 | **Resume refetch** (3c) | Sleep laptop → pause/mode-change on backend → wake | Converges on wake | Helper `power.transition …resume`; WS `state.trigger …resume` → `state.apply phase=event` |
| 8 | **Reassign token** (3b) | Unassign then re-assign the device (new token) | Socket rebuilds with the new token; state refetched | WS `websocket.token_rotate` then `state.apply phase=event` |
| 9 | **Unassign = 401 stop** (7) | Unassign the device (active, socket may already be failing) | Tracking pauses; recording **and** uploads stop | Helper `state.ingest401` → WS `state.trigger …ingest-401` → `state.apply … unassigned` tracking=paused |
| 10 | **Ingest stateVersion piggyback** (2) | Change anything that bumps stateVersion | Next ingest (~120 s) nudges a refetch | Helper `state.version_hint`; WS `state.trigger …ingest-version` → `state.apply phase=event` |
| 11 | **Mode change** (5) | Set mode alert ↔ halt | Electron windows get alert/halt treatment | WS `state.apply` mode=halt/alert |
| 12 | **Config on version change** (10/11) | Change productive/non-productive apps or domains | New categorisation applies **promptly** (not after 1 h) | `productivity_config.json` updates; DebugView shows `EnsureFreshForVersion … fetching`; categories in new `daily_reports` rows change |
| 13 | **blockedWebsites + benchmarks captured** (11) | Add a `blockedWebsites` entry + set benchmark times | Values land in the config cache | `productivity_config.json` now has `blockedWebsites`, `activeBenchmarkingTime`, `productiveBenchmarkingTime` (enforcement is a later feature — this just captures them) |

**Timing notes**
- Ingest runs every **120 s**; paused poll every **~240 s ± jitter**; WS heartbeat every 30 s.
- With the socket up, pause/resume/mode arrive over WS almost instantly — the poll/ingest paths
  (rows 4, 5, 10) are the *safety nets* and are what's genuinely new; row 5 (WS blocked) is the
  cleanest proof the poll delivers resume on its own.

---

## 6. Electron-specific checks (items 12, 13)

- **ttlSec removed (12):** in the app, trigger a config write (login / config refresh), then open
  `C:\ProgramData\PiFocusStage\productivity_config.json` → it must have **no `ttlSec`** key, and any
  service-written keys (`blockedWebsites`, `configVersion`, benchmarks) must be **preserved** (the
  writer now merges instead of overwriting).
- **PATCH-first self-pause (13):** in the app, pause tracking. Order must be **backend PATCH first,
  then local**: the stage backend device state flips to paused, and because the PATCH lands first the
  next `/agent/state` fetch agrees (no fight/flip-back). Confirm the device shows paused on the admin
  panel and the app doesn't bounce back to "running".

---

## 7. Cleanup / uninstall (stage only)

From the extracted package folder, elevated:
```powershell
.\uninstall.ps1            # removes PiFocusWindowServiceStage + stage dirs only
```
Prod (if installed) is untouched.

---

## 8. Quick "is the new code even in?" one-liner
```powershell
$ws = "C:\Program Files\PiFocus\AgentStage\WindowService.exe"
$b = [IO.File]::ReadAllBytes($ws); $s=[Text.Encoding]::ASCII.GetString($b)+[Text.Encoding]::Unicode.GetString($b)
'/agent/state','state.apply','POWER_RESUME' | % { "{0,-16} {1}" -f $_, $s.Contains($_) }
```
All three `True` ⇒ the installed WindowService has the control-plane build.
