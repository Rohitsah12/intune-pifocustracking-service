# PiFocus Business — Windows client sync behaviour

**Answers to the backend team's questionnaire.** Every claim below was read out of source and
independently re-verified; where the two passes disagreed, the correction is what you see here.
Line references are `file:line` so you can check anything yourself.

**Read section 0 first.** Your premise is right but incomplete, and two of the gaps change the design.

---

## 0. Before the answers — four things that change your design

### 0.1 The problem is worse than "the event is lost"

You wrote: *"Backend kehta hai paused, device tracking karta rehta hai."* Correct. But there are
three further holes, and a pure pull design only closes the first:

| # | Hole | Why a pull alone does not fix it |
|---|---|---|
| 1 | Socket event missed while off/asleep/offline | ✅ fixed by pulling |
| 2 | **The C++ agent has no HTTP path that can pull state at all** | It must be *built*. WindowService's only HTTP call in the entire codebase is `/user-devices/{serial}/machine-key` (`DeviceTokenManager.cpp:351`). |
| 3 | **The socket dies permanently after ~3.4 minutes offline** | 10 attempts, 5s→30s backoff (`WebSocketManager.cpp:168-170`). Only a *process restart* re-arms it. So the "go ask" hint stops arriving exactly in the scenario the redesign exists to fix. |
| 4 | **The client's default is "tracking ON"** | `TrackingManager()` initialises `m_trackingEnabled(true)` (`TrackingManager.cpp:9`) and `loadStateFromDisk()` returns `true` when the registry value is missing (`:351-355`). A failed pull on a fresh install, a re-image, or after uninstall **silently monitors a user an admin has paused.** |

### 0.2 A "current state pull" already half-exists — extend it, don't build new

- **`GET /user-devices/{serialNumber}/device-info`** already exists and is already serial-keyed
  (`deviceApi.ts:12-14`). Returns `{_id, serialNumber, isAgentInstalled}`. **This is exactly the
  route shape you are designing.** Adding fields here is far cheaper than a new route.
- **`GET /user/self`** (`loginApi.ts:133`) is the de-facto state pull *today*: it returns the whole
  user plus all devices, and the client filters `user.devices` by serialNumber **client-side**
  (`TrackingContext.tsx:297`).
- **`reconcileDeviceToBackend`** (`TrackingContext.tsx:183-238`) is already a working
  pull-and-converge loop. It is one-way (backend → device), refuses to act on unknown, and verifies
  after writing. Model the new contract on it.

### 0.3 The client cannot say "I don't know my state yet"

There is no tri-state anywhere. `m_trackingEnabled` is a `bool`; Electron's `isPaused` is
`useState(false)`. The **only** tri-state in the system is `getTrackingState()` returning `null`
for a *device* read (`pauseControl.ts:103-114`) — and the reconciler correctly refuses to act on it.
There is no "backend state unknown" concept at all. If your pull fails at startup, there is nothing
to fall back to and nothing that will later correct it.

### 0.4 There is no version, ETag or updatedAt anywhere

Grepped `version|revision|lastSync|updatedAt|etag` across `src/main`, `src/renderer/Context` and
both C++ trees — only build/app version strings. The `Device` interface (`loginApi.ts:4-18`) has
`isTrackingEnabled, mode, status, isActive, shouldDisplayDashboard` and **no version field**.
`TrackingManager::setTrackingEnabled` applies whatever it is handed with no idea whether the
instruction is older than what it already applied.

> ⚠️ Do **not** plan to reuse `TrackingChangedAt` as a version. It is a **local apply-time** stamp
> (`std::time(nullptr)`, `TrackingManager.cpp:161`), not the backend's change time.

---

## A. Windows agent (background service)

### A1 — Service, Scheduled Task, or user app? Before or after login?

**Three processes. One is a real service. There is no Scheduled Task anywhere** (grepped `schtasks`,
`Register-ScheduledTask`, `ITaskService`, `RunOnce` across all four repos — zero hits).

| | **WindowService.exe** | **HelperService.exe** | **piFocus Business** (Electron) |
|---|---|---|---|
| Type | Windows Service, `SERVICE_WIN32_OWN_PROCESS` (`main.cpp:1342`) | Ordinary process in the user's session | User-session app |
| Start | `start= auto` | Spawned by WindowService | Per-user `Run` key (`main.ts:208`) |
| Account | **LocalSystem, Session 0** | The interactive user, medium integrity | The interactive user |
| Before login? | **YES** | **NO — impossible** | NO |

- WindowService needs `--service` on its command line (`main.cpp:1238`); without it, it runs as a
  console app. `install.ps1:496` builds `binPath` accordingly.
- Privileges granted at install: `SeTcbPrivilege/SeAssignPrimaryTokenPrivilege/SeIncreaseQuotaPrivilege`
  (`install.ps1:511`) — exactly what `WTSQueryUserToken` + `CreateProcessAsUser` need.
- HelperService is launched via `WTSGetActiveConsoleSessionId` → `WTSQueryUserToken` →
  `DuplicateTokenEx` → `CreateEnvironmentBlock` → `CreateProcessAsUserW`
  (`main.cpp:940-1229`), from `C:\ProgramData\PiFocus\HelperService.exe --console`.
- **At the login screen:** WindowService runs; HelperService cannot start (`WTSQueryUserToken`
  returns `ERROR_NO_TOKEN`); a watchdog retries every 5s forever. **All collection lives in
  HelperService, so a powered-on device at the login screen produces zero activity data.**
- **At the lock screen:** the session token still exists, so HelperService **keeps running**.
- **Fast user switching:** WindowService kills the previous user's helper and spawns a new one in
  the newly active session (`main.cpp:735-753`, `:960-978`). Uploads change identity mid-day on a
  shared PC.

> **Correction to a common assumption:** the service is **not** created only by Intune. The Electron
> app installs the **identical service, same name, same path** — `serviceControl.ts:238` runs
> `sc create "PiFocusWindowService" … obj= LocalSystem`. See C3.

### A2 — What is fetched at startup, in order? Does collection start before it?

Host: `api.penpencil.co` / `stage-api.penpencil.co` (`Env.h:63/:17`).
Prefix on both: `/pi-os-backend/v1/pi-focus-business` (`Env.h:106`).

**WindowService — exactly ONE HTTP endpoint, and it is conditional:**
1. (local) read `HKLM TrackingEnabled` → apply pause event
2. (local) read `HKLM ElectronAppMode`
3. `ensureDeviceTokenExists()` → registry probe first; if absent, **sleeps 5s** waiting for Electron
   to write the token, then `GET /user-devices/{serial}/machine-key`
4. **Socket.IO connect — but NOT at startup.** Only when HelperService pushes `SET_DEVICE_TOKEN`
   over the named pipe (`main.cpp:2012, :2039-2044`).

**HelperService:**
1. (local) read device token from HKCU
2. (IPC) `GET_SERIAL_NUMBER` over the pipe
3. `GET /agent/configurations` — **conditional**, skipped entirely if the on-disk config is inside
   its TTL. **On a warm restart there is no startup backend call at all.**
4. (IPC) `SET_DEVICE_TOKEN` → this is what opens the WebSocket

#### ⚠️ Does collection start before the fetch? **Yes, in the failure case entirely.**

The whole config block is guarded by `if (!deviceToken.empty())` (`HelperService/main.cpp:1213`).
**If the token is empty — the normal state on a fresh device before Electron login, and for any
secondary user of a shared PC — the config fetch is skipped and the tracking loop starts immediately
with an empty ruleset.** Everything is then categorised `"neutral"`.

Categorisation happens at **upload-build** time, not capture time (`main.cpp:345`), so rows captured
before the config arrives still get whatever config is loaded when their batch is built — but any
batch already POSTed as `neutral` is never re-categorised.

#### What is NOT fetched at startup — `exists: no`
- **No backend fetch of tracking/pause state.** Read purely from the local registry.
- **No backend fetch of `mode`.** Same.
- **No last-sync / high-water-mark / cursor.** Grepped `lastSync`, `since=`, `cursor` — nothing.
- **No device registration handshake from either C++ process.**

### A3 — Where is each value stored? Does it survive reboot / upgrade?

| What | Location | Type | Reboot | Service upgrade | Full uninstall |
|---|---|---|---|---|---|
| Device token | `HKCU\Software\PiFocus\Helper` → `DeviceApiKey` | `REG_SZ`, plaintext `apiKeyId.secret` | ✅ | ✅ | ❌ **survives — leak** |
| Productivity config | `C:\ProgramData\PiFocus\productivity_config.json` | file | ✅ | ✅ | wiped |
| `mode` | `HKLM\SOFTWARE\PiFocus` → `ElectronAppMode` | `REG_SZ` `"alert"`/`"halt"` | ✅ | ✅ | wiped |
| Tracking flag | `HKLM\SOFTWARE\PiFocus` → `TrackingEnabled` | `REG_DWORD` 1/0 | ✅ | ✅ | wiped |
| Pause start | same key → `TrackingChangedAt` | `REG_QWORD`, **Unix epoch seconds** | ✅ | ✅ | wiped |

**The device token is per-USER, not per-machine.** WindowService runs as SYSTEM so it cannot use
HKCU; it resolves the active console user's SID and writes through `HKEY_USERS`
(`DeviceTokenManager.cpp:255-268`). **On a shared PC each Windows profile gets its own DeviceApiKey
— two different `apiKeyId`s can represent the same serial number.**

`install.ps1` makes **zero** registry changes and never deletes ProgramData, so an in-place upgrade
preserves everything. **But** if Intune runs `uninstall.ps1` first (supersedence / replace flow),
`uninstall.ps1:77` and `:80` wipe ProgramData and `HKLM\SOFTWARE\PiFocus`. Whether an "upgrade"
preserves state depends on the Intune assignment mode, not on the scripts.

> **After a wipe-and-reinstall the agent comes back tracking ENABLED and mode `alert`, with no
> reconciliation call.** An admin's pause is silently lost until the backend pushes again over the
> socket — which itself needs a logged-in user.

### A4 — WebSocket: URL, auth, reconnect, heartbeat

**Two independent sockets. Do not conflate them.**

**Socket A — the control channel. Owner: WindowService (LocalSystem).**
- prod `wss://pi-os-backend.penpencil.co/ws/` · stage `wss://pi-os-backend-stage.penpencil.co/ws/`
- namespace `/pi-focus/agent` (same on both envs)
- **Auth = URL query parameters**, not a header, not socket.io `auth`:
  `?token=<deviceToken>&upn=<upn>` (`WebSocketManager.cpp:180-185`). `upn` is **omitted entirely**
  (key absent, never empty) when unavailable — treat absent-UPN as normal, not an error.
- websocket transport only, no polling fallback.
- **Reconnect: 10 attempts, `min(5000 × 1.5ⁿ, 30000)`, no jitter ⇒ ~3.4 minutes total, then it gives
  up permanently.**
- Heartbeat: server-initiated Engine.IO ping/pong, **plus** an application `agent:heartbeat` every
  30s carrying `{upn}`. The UPN is re-read on every heartbeat so it follows a user switch.
- Subscribes to exactly ONE event: **`command`**, and ignores anything whose `from` != `"USER"`.
  Implemented types: `agent_mode_change`, `agent_tracking_toggle`. **Any other type is silently
  dropped with no ack and no log.**
- Emits only `agent:heartbeat`. (`sendCommandToUser` exists but has zero callers.)

**Socket B — cosmetic. Owner: Electron renderer.** `/pi-focus/public` on `api.penpencil.co`, auth =
**user JWT** in socket.io `auth`. Handles one payload (`url_category_request_updated`). **Exists only
while one dashboard section is expanded.**

> Two sockets can be connected at once for the same device, on **different hosts**, with **different
> auth**. A firewall rule allowing only `api.penpencil.co` silently kills all agent control while the
> UI keeps working.

#### Two hard gates that make a device permanently deaf
1. **OpenSSL.** `bool webSocketEnabled = hasOpenSSL;` (`main.cpp:1806`). Missing
   `libssl-3-x64.dll`/`libcrypto-3-x64.dll` ⇒ **no socket at all**, silently. HTTPS uploads still
   work, so the device looks alive in your ingest and is uncontrollable.
2. **The socket only opens on `SET_DEVICE_TOKEN` over the pipe**, and HelperService latches
   `deviceTokenSent = true` after the first success (`HelperService/main.cpp:1491`). **Nothing
   re-arms the socket short of a WindowService or HelperService process restart.**

### A5 — Polling: what, how often, and does the timer survive sleep?

**Headline: neither C++ process ever polls the backend for tracking/pause state.** The agent learns
about an admin pause *exclusively* from the socket. If that event is missed, nothing in C++ ever asks
again.

| # | Poller | Endpoint | Interval | Clock |
|---|---|---|---|---|
| P1 | WindowService token guard | `/user-devices/{sn}/machine-key` | 5 min; **HTTP only when the registry value is missing**; backoff 5→10→20→40→80→120 min | monotonic |
| P2 | WindowService WS heartbeat | — | 30s | monotonic |
| P3 | Helper watchdog | local | 5s | monotonic |
| P5 | Config refresh | `GET /agent/configurations` | **30 min check** wrapping a **1h wall-clock TTL** | mixed |
| P6 | Activity upload | `POST /agent/ingest/activities` | 120s | monotonic |
| P7 | Device status | `PATCH /agent/device-status` | 30s dwell debounce | monotonic |
| P11 | **Electron renderer — the only real state poll** | `GET /user/self` | 30s (15s on failure) | JS timer |
| P12 | Electron device-state poll | **named pipe, no network** | 5s | JS timer |
| P13 | Electron pause reminder | **named pipe, no network** | 60s prod / 15s stage | JS timer |

#### The sleep/wake answer you actually need

**Every C++ interval is `std::chrono::steady_clock` (monotonic).** Only three things use wall clock:
the config TTL, HelperService's sleep-gap detector, and the pause reminder.

**No timer ever does catch-up.** Every one is `if (now - last >= interval) { fire(); last = now; }`
— after an 8-hour gap you get exactly **one** firing, not 240 queued ones. Do not size capacity
expecting a Monday-morning thundering herd.

⚠️ **The config refresh has its two clocks nested the wrong way round.** The **outer** gate is
monotonic (30 min, `HelperService/main.cpp:1483`); the wall-clock TTL check lives **inside**
`EnsureFresh` (`ProductivityConfig.cpp:296`). So a wall-clock TTL expiry **can never trigger a fetch
on its own** — after a long sleep the device still waits a further 30 minutes of *awake* time.

> **On an Intune-only company device with no Electron app, a pause issued while the machine was
> asleep is NEVER picked up.** There is no poll, and the socket carries no state replay.

### A6 — Sleep/wake and network-availability handlers

| Process | Power | Session | Triggers a backend re-sync? |
|---|---|---|---|
| WindowService | **none** — `dwControlsAccepted = SERVICE_ACCEPT_STOP \| SERVICE_ACCEPT_SHUTDOWN` only | lock/unlock only | ❌ |
| HelperService | `PowerRegisterSuspendResumeNotification` + lid-switch | — | ❌ local bookkeeping only |
| Electron | `powerMonitor` lock/suspend/unlock/resume | — | ⚠️ **indirectly and conditionally** |

**Network availability detection: does not exist anywhere.** Grepped `INetworkListManager`,
`NLM_CONNECTIVITY`, `IsNetworkAlive`, `NotifyAddrChange`, `InternetGetConnectedState`,
`WlanRegisterNotification` in C++ and `navigator.onLine`, `'online'`, `'offline'` in Electron —
**all zero hits.** Connectivity is discovered only by a request failing, and the response is always
"try again on the next timer."

**The one accidental re-sync:** `powerMonitor.on('resume')` → `maybeShowStartupWindow('resume')`
(`main.ts:1399-1402`) → `createStartupWindow()` → mounts `TrackingProvider` → immediate `doSync()`
→ `GET /user/self` + reconcile. **Real, but conditional**: skipped if the dashboard is already
visible (`main.ts:885-888`), and if the window object still exists it only calls `.show()` with no
reload and no remount. Treat it as best-effort, and note it does not exist at all on an Intune-only
device.

HelperService's resume path (`main.cpp:1414-1449`) re-arms input hooks and fixes local session
accounting. It does **not** refetch config, force an upload, or touch the socket — even though
HelperService has a wall-vs-monotonic divergence detector (`main.cpp:1593-1635`) that logs
*"likely NTP / sleep / VM-resume"* and would be the perfect resync trigger. **The wiring is one line
and it is missing.**

### A7 — Config apply: replace or merge? Atomic? What on failure? ⚠️ *most important*

**FULL REPLACE, not merge.** `FetchFromApi` clears all four sets before repopulating
(`ProductivityConfig.cpp:736-739`). No merge, no delta, no tombstone.

#### 🔴 An empty or partial 200 is DESTRUCTIVE

The validation gates check only the **envelope**:
```cpp
if (!j.is_object() || !j.value("success", false))                      return false;  // :724
if (!j.contains("data") || !j["data"].is_object())                     return false;  // :727
if (!data.contains("productivityConfig") || !…is_object())             return false;  // :731
```
Once those pass, the clear at `:736` fires **unconditionally**, and the array reads that follow are
all guarded (`if (pc.contains(...) && …is_array())`). So `{"success":true,"data":{"productivityConfig":{}}}`
leaves every set **empty**, returns `true`, stamps the TTL as fresh and **persists the empty config
to disk**. Every app and domain silently becomes `"neutral"` for a full TTL.

Same for scalars: `s_autoScreenshotCapture = data.value("autoScreenshotCapture", false)` (`:783`).
**A response that merely OMITS the key disables screenshot capture fleet-wide.** Omission means "set
to the falsy default", never "unchanged".

**➡️ Return the complete state every time. Never patch-shaped, never partial.**

#### Failure branches — these all KEEP the old config (correct behaviour)
Connect/send/receive failure, timeout, non-2xx, empty body, bad JSON, `success:false`, missing
`data`/`productivityConfig` — all return **before** the clear, so memory and disk are preserved.

#### Atomicity: the config write is NOT atomic
`std::ofstream f(path, std::ios::trunc)` then `return true` **without checking the stream state**
(`ProductivityConfig.cpp:600-617`). No temp file, no `MoveFileEx`, no `ReplaceFile`. The Electron
writer is equally non-atomic (`fs.writeFileSync`). **Two processes truncate-write the same file with
no lock** — interleaving produces a torn file that HelperService reads as "no rules".

#### About the `autosave.rename_fail` storm in the field — it is NOT the config file
Those thousands of `MoveFileExA failed during atomic rename` lines come from
`AppUsageTracker::autoSave()` writing **`current_session.dat`** (the unsent activity buffer). That
path **is** atomic and **fails safe**: on rename failure the temp is deleted and the last good
snapshot survives (`AppUsageTracker.cpp:789-807`). The damage is **silent staleness**, not
corruption — and it directly causes duplicate uploads (see A9). The code tags likely AV/EDR
interference (`ERROR_SHARING_VIOLATION`, `ERROR_ACCESS_DENIED`, `ERROR_LOCK_VIOLATION`,
`ERROR_USER_MAPPED_FILE`); the `win32` field in each line carries the exact code.

### A8 — `mode` and `isTrackingEnabled`: what exactly stops?

**These are completely unrelated mechanisms. Do not model them as one switch.**

#### `mode` (`alert`/`halt`) — **purely cosmetic. Stops NOTHING.**
It hides the Electron app's own windows: matches windows whose title contains `piFocus Business`,
sets `WS_EX_TOOLWINDOW`, clears `WS_EX_APPWINDOW`, `ShowWindow(SW_HIDE)`. That is the entire effect.
**Screenshots, sampling, URL capture and every upload keep running at full rate.**
There is no other consumer of `mode` anywhere.

⚠️ Asymmetry worth knowing: a missing/malformed `mode` **silently defaults to `"alert"`**
(un-hides the window, `main.cpp:1830`), whereas a missing `enabled` on the tracking toggle is
**correctly rejected, not defaulted** (`main.cpp:1862-1881`).

#### `isTrackingEnabled` — the real kill switch, enforced in exactly ONE line
```cpp
// HelperService/main.cpp:1327
const bool isPaused = (WaitForSingleObject(g_pauseEvent, 0) == WAIT_OBJECT_0);
```
Everything below the `continue` at `:1377` is skipped.

| Subsystem | While paused |
|---|---|
| Window/title sampling, URL capture | **stops** |
| Screenshots (capture, upload-url, S3 PUT, mark-uploaded) | **stops** |
| `POST /agent/ingest/activities` | **stops** |
| `PATCH /agent/device-status` | **stops** |
| Icon upload, daily reports, autosave, config refresh | **stops** |
| Logged-time / active-second counters | **frozen** |
| **Pipe heartbeat to WindowService (3s)** | **KEEPS RUNNING** |
| **`agent:heartbeat` on the socket, with the user's UPN** | **KEEPS RUNNING** |
| **`WH_KEYBOARD_LL` / `WH_MOUSE_LL` hooks** | **stay installed, counters keep mutating** |

> **A paused device still heartbeats and still reports its UPN.** It shows as online-and-attributed
> while "paused". No key content is captured, but the hooks are live — that is a privacy question you
> should be able to answer if asked.

The three representations (in-memory bool, kernel event, registry) are written together under one
mutex. **Only the kernel event changes behaviour.** The registry is read **only at WindowService
construction** — editing it at runtime does nothing until a service restart.

### A9 — Offline buffering, flush, duplicates

**No database.** Grepped `sqlite|leveldb|rocksdb|lmdb` across both C++ trees — zero hits.
Activity data lives in an in-memory map, mirrored to `current_session.dat` every 10s.

- **Caps:** none on count, bytes or memory. The only bound is the day boundary.
- **Flush:** every 120s, **the whole backlog in one POST**. No batch-size limit, no compression, no
  backoff. An all-day offline device sends its entire day in **one** POST body.
- **Success = HTTP 2xx.** On failure nothing is marked and the same batch retries in 120s, forever.

#### 🔴 Idempotency: there is NONE

Grepped `idempot|uuid|clientEventId|eventId|requestId|batchId|nonce|sequenceNumber` — nothing on the
wire. The row is `{appName, tabName, icon?, url?, start, end, durationSeconds, systemStatus, category, upn?}`.
**No client id, no batch id, no sequence number.**

> `g_sentInstanceKeys` looks like a dedupe set but is **write-only dead code** — never read, never
> persisted.

**Your only dedupe key is `(deviceToken, appName, tabName, start, end)`.**
Do **not** include `category` or `systemStatus` — both are recomputed at send time and can differ
between the original and the retry of the *same* instance.

#### Duplicates are EXPECTED, not hypothetical
1. **Lost ack.** If you committed the rows and the 2xx never got back, `isSent` is never flipped and
   the identical rows re-POST 120s later.
2. **The `rename_fail` link.** After a successful POST the code flips `isSent = true` in memory and
   immediately persists it via `autoSave()`. **If that autosave hits the rename failure — which the
   field logs show happening thousands of times — the flags are not persisted, and on the next
   restart the agent re-uploads data you already have.**

#### Where data is permanently LOST
- **IST midnight:** `m_usageData.clear()` (`AppUsageTracker.cpp:620`) drops every instance
  **regardless of `isSent`**. Anything backlogged because the device was offline is gone.
- **Restart across midnight:** the autosave file is discarded wholesale (`:999-1008`).
- **Graceful stop:** no final flush POST.
- **Quarantine:** >24h instance, >20 (app,tab) tuples on one startTime, or >24h cumulative day —
  all mark rows `isSent = true` **without sending them**. Permanently invisible to you.

**Screenshots are different and better:** a genuine 2-day durable disk queue with a state machine
(`captured → upload_url_received → uploaded → marked`) and a server-issued `screenshotId` that **is**
idempotent for the PUT and mark steps. Caveat: a lost `/agent/upload-url` response orphans a
screenshotId server-side and the client mints a new one.

**`daily_reports\*.json` is NEVER uploaded by any process.** Do not plan a sync contract around it.

---

## B. Windows Electron app

### B1 — Direct or through the agent? Who wins on conflict?

**Directly.** Electron has its own HTTPS stack and never proxies through the agent; the agent never
proxies for Electron. Their only contact is local (named pipe + registry + a shared JSON file).

**Renderer** (user JWT, `Authorization: Bearer` + `xx-org-id`): `/auth/login`, **`/user/self`**,
`/user-devices/register-personal`, `/user-devices/{sn}/machine-key`, `/user-devices/{sn}/key`,
**`PATCH /user-devices/device/{id}/tracking`**, `/user-devices/{sn}/device-info`,
`PATCH /user-devices/update/{id}`, `/user-devices/assets`, `/url-category-requests/*`,
`/report/employee-report`, `/configurations`, `{otaBaseUrl}/check`.

**Main process — three outbound calls:** `POST /auth/refresh-token`, the GA4 Measurement Protocol,
and the **OTA installer download** via `electron-dl` (`main.ts:1180-1186`).

**The `/agent/*` namespace is exclusively the C++ agent's. Electron never calls it.**

#### Precedence, exactly as implemented (`reconcileDeviceToBackend`, `TrackingContext.tsx:183-238`)
1. **Backend is authority, always.** Strictly one-way device ← backend. It never writes device state up.
2. **No versioning, no timestamp arbitration.** Purely "whatever `/user/self` said on this poll wins".
3. **Unknown is not a value.** If the pipe read returns `null`, it returns without acting —
   *"acting on a guess is how we'd pause a device nobody asked to pause."*
4. **It yields to the user** if a click is in flight.
5. **It verifies** after pushing, and logs "Drift repair did not stick". It does not retry; the next poll does.

**Local user click order:** PATCH the backend **first**, then the pipe. If the PATCH throws, the
device is never touched.

#### 🔴 The one path where the client overrides the admin
`TrackingContext.tsx:315-338` — "stale pause" auto-resume. If localStorage `tracking_pause_date` is
from a previous calendar day **and the backend says paused**, the client PATCHes
`isTrackingEnabled=true` — **resuming the device on your server** — then resumes locally. This fires
**before** the reconciler is consulted. And because `staleChecked` is a ref scoped to each provider
instance, it can fire **once per window (2–3 concurrent contradicting PATCHes)**, not once per session.

**A pull design in which the client can push a contradicting write is not a pull design.** This needs
to be removed or gated server-side.

#### Two genuine last-writer-wins races
- **Device API key** — Electron, WindowService **and HelperService** all GET the machine-key endpoint
  and all write the same `HKCU\…\DeviceApiKey`. No timestamps, no CAS. Design is "first writer wins,
  second defers"; if you ever rotate a key, whichever side notices first overwrites.
- **`productivity_config.json`** — Electron writes it from `GET /configurations` (user JWT);
  HelperService writes it from `GET /agent/configurations` (device token). Same file, no lock, no
  version. They also disagree on default `ttlSec` (Electron **6h**, Helper **1h**). **Electron's
  write also strips `autoScreenshotCapture` / `autoScreenshotCaptureInterval` entirely**, so
  auto-screenshots silently stop after the dashboard opens.

### B2 — What auth does Electron use?

**The logged-in user's JWT** for every call it makes. It also *handles* the device token, but only as
a courier — it fetches it and writes it to the registry for the C++ services. It never authenticates
its own calls with it.

| What | Where | Protection |
|---|---|---|
| access/refresh token | `%APPDATA%\pi-focus-business-app\auth-tokens.json` (electron-store) | AES with a **hardcoded key literal in the shipped bundle** — obfuscation, not encryption |
| user profile object | renderer `localStorage` key `pifocus_auth_state` | plaintext |
| device API key | `HKCU\Software\PiFocus\Helper\DeviceApiKey` | **plaintext `REG_SZ`** |
| serial number | `HKCU\Software\PiFocus\Device\SerialNumber` | plaintext |

> Do not describe the refresh token as "encrypted at rest" in any security document.
> Also: the token store name is **not** environment-prefixed, so a stage and a prod build on the same
> machine share one `auth-tokens.json` and stomp each other's sessions.

**Refresh-failure classification matters to you:** a response with **no HTTP status** (network/DNS)
is treated as transient and tokens are **kept**; a **4xx is authoritative and wipes the session**.
A backend returning 500 on refresh will not log users out; a 401/403 will.

### B3 — Electron closed, only the agent running: who receives and applies changes?

**The control socket is owned by WindowService, not Electron.** Closing the app does **not** stop
mode or tracking commands from reaching and being applied.

- Backend → Socket A (WindowService) → applies to registry + kernel event → HelperService obeys.
  **Electron is not in the path at all.**
- The 30s `/user/self` reconcile stops — which is fine, because with Electron closed there is only
  one writer and no drift is generated.

**The inverse is worth stating:** Electron open, agent not running ⇒ **no** backend command can land,
pipe reads return `null` = UNKNOWN, and the reconciler deliberately does nothing.

> **The device NEVER acknowledges a command.** `ack_resp` is declared and never written; the designed
> `agent:tracking_state` emit specified in `PAUSE-RESUME-FLOW.md:73` **was never built**. You cannot
> currently distinguish "laptop was off", "applied", and "tried and the registry write failed" —
> and `setTrackingEnabled` **can** genuinely fail and return false.

### B4 — On startup, does Electron read from the agent or call the API?

**Both, in a specific order — and for tracking state the backend API wins.**

Main process: `bootstrapBackgroundStuff()` is **not awaited** (`main.ts:1005`), so windows open and
start polling while the service may still be installing. **Any reasoning that assumes "app open ⇒
agent reachable" is wrong for the first ~5–30 seconds.**

Renderer: `DeviceProvider` → `AuthProvider` (device key, `/user/self`) → `TrackingProvider`
(`doSync` immediately, then 15s/30s chain).

| Source | Winner |
|---|---|
| Tracking state | **Backend**, unconditionally — resolves within ~30s. Except the stale-pause auto-resume. |
| Pipe returns `null` | **Neither.** Silence is never read as "running". |
| Serial number | **Electron's own cache** (HKCU → `wmic bios` → `wmic csproduct uuid`), falling back to the agent's daily-report file. |
| Auth | cached-then-verified; a transient failure keeps the cached session |

> ⚠️ **Electron resolves the serial independently of the agent and never uses the service's
> `GET_SERIAL_NUMBER` pipe command, even though the service implements it.** WindowService resolves
> BIOS → Intune EntDMID → MachineGuid; Electron resolves registry cache → `wmic bios` → `wmic
> csproduct uuid`. **On any machine where BIOS returns a placeholder these produce different values**,
> and the `/user/self` device match then fails with "this device is not registered in your account"
> and no other symptom. `wmic` is also deprecated and already absent on some Windows 11 builds.

**On autostart the main dashboard window is never created** — only the startup + widget windows. So
`/configurations` and the url-category socket never run in that session.

---

## C. Between the agent and the app

### C1 — What is the IPC mechanism?

**Four channels, not one:**

1. **Named pipe** `\\.\pipe\PiFocusIPC` (stage: `…IPCStage`). `PIPE_TYPE_MESSAGE`, framing =
   **uint32-LE length prefix + JSON body**, each `WriteFile` a discrete message.
   Commands: `GET_SERIAL_NUMBER`, `GET_LOCK_STATE`, `GET_TRACKING_STATE`, `SET_TRACKING_ENABLED`,
   `SET_DEVICE_TOKEN`, plus the helper's 3-second heartbeat.
   **Electron implements only two of these** — `SET_TRACKING_ENABLED` and `GET_TRACKING_STATE`.
2. **Kernel events** — `Global\PiFocusPauseEvent` (manual-reset; **signaled = paused**) and
   `Global\PiFocusModeChanged`.
3. **Registry** — `HKLM\SOFTWARE\PiFocus` (`TrackingEnabled`, `TrackingChangedAt`, `ElectronAppMode`)
   and `HKCU\…\Helper\DeviceApiKey`.
4. **Shared files** — `productivity_config.json`, `daily_reports\*.json`, `current_session.dat`.

### C2 — Who owns the shared state?

**`TrackingManager` is the single mutation chokepoint** — `setTrackingEnabled` under `m_stateMutex`,
moving the kernel event and the registry together. Exactly three callers: the constructor replay, the
socket handler, and the pipe handler. A repo-wide grep for `SetEvent`/`ResetEvent` on the pause event
and `RegSetValueEx("TrackingEnabled")` returns **only** TrackingManager.

**But two paths bypass it:**

1. 🔴 **The PowerShell fallback.** When `pipeUnsupported` latches, `setTracking` falls through to
   `EventWaitHandle::OpenExisting(...).Set()/.Reset()` (`pauseControl.ts:46-52`). That moves live
   behaviour **without writing the registry** — so the service constructor replays the stale registry
   value on next start and **reverts whatever was applied.**
   Worse: `pipeUnsupported` is a **module-level latch** set by a single EPIPE/ECONNRESET/timeout, and
   `resetPipeSupport()` is exported but **never called anywhere**. **One transient pipe error disables
   the apply path — and the entire drift-repair mechanism — for the whole app session.**
2. **The stale-pause auto-resume** (see B1) writes to *your* database.

### C3 — One installer or separate? Does an update reset state?

**Separate, and they collide.**

| | Company (Intune) | Personal (Electron) |
|---|---|---|
| Trigger | `detect.ps1` compares `C:\Program Files\PiFocus\Agent\version.txt` to a **hardcoded** `$TargetVersion` | App launch bootstrap + in-app OTA |
| Installs | `sc delete` + `sc create`, copies binaries, writes version.txt | `sc create` / delete+recreate, **same service name, same path** |

**Local state survives an in-place Intune upgrade** (`install.ps1` makes zero registry changes and
never deletes ProgramData). It does **not** survive an uninstall-then-install supersedence.

#### 🔴 The two topologies fight over the same service
The Electron app manages a service with the **same name** (`PiFocusWindowService`) at the **same
path** as `install.ps1`. On a dual-topology machine its bootstrap will stop the Intune-deployed
service and replace the binary with its own bundled copy — **and the app bundle ships
`version.txt = 1.0.3` while the Intune package writes `1.0.6`.**

> *We have just fixed this on the client side:* the app now detects a service whose ImagePath lives
> under `C:\Program Files\PiFocus\Agent` and reports it `external-managed`, refusing to modify it.
> Intune remains the owner on company devices.

#### There are SIX version identities, and the two you receive are not the local ones
| Identity | Value on a current device | Who sees it |
|---|---|---|
| `C:\Program Files\PiFocus\Agent\version.txt` | `1.0.5` | `detect.ps1` |
| `C:\ProgramData\PiFocus\service-installed-version.txt` | `1.0.3` | Electron bootstrap |
| app bundle `resources\binaries\version.txt` | `1.0.3` | Electron bootstrap |
| repo root `version.txt` | `1.0.6` | not deployed |
| **`xx-agent-version` HTTP header** | from `PF_INSTALL_DIR\version.txt` | **you, on every HelperService call** |
| **`report["agentVersion"]`** | compile-time constant **`"1.0.1"`** | **you, in every activity report** |

⚠️ **`agentVersion` in the uploaded report is a hardcoded `"1.0.1"` that tracks nothing.** If you are
using it for fleet version reporting, it is meaningless. Use the `xx-agent-version` header.

The binaries' Win32 file-version resource is also `1.0.1.1` on every build, so **the binary cannot
identify itself** — only `version.txt` or content markers can.

---

## D. Ops

### D1 — Fleet size and per-device request volume

**Fleet size is not answerable from source** — no device cap, licence count or registry exists
anywhere. **Please supply this from Intune/IT.** What the code *can* tell you:

**Per active device, per hour, to your API:**

| Endpoint | Steady state | Ceiling |
|---|---|---|
| `POST /agent/ingest/activities` | ≤30 (skipped when the batch is empty) | 30 |
| `PATCH /agent/device-status` | 20–60 | 120 |
| `GET /agent/configurations` | ~1 | 120 (device that has *never* loaded it retries every 30s) |
| Screenshots (`upload-url` + `mark-uploaded`) | 2 @ 60-min default | 120 + 60 S3 PUTs @ 1-min |
| `GET /user-devices/{sn}/machine-key` | 0 | 120 (permanently-rejected token) |
| **`agent:heartbeat` WS frames** | **120** | 120 |

- **Steady state: ~55–95 HTTPS req/device/hour + 1 long-lived WebSocket.**
- **Pathological ceiling: ~510 HTTPS req/device/hour.**
- **Idle/locked: ~1–2 HTTPS + 120 WS frames.**

**The WebSocket is the real capacity driver** — one concurrent connection per powered-on device,
held open indefinitely. It requires **both** OpenSSL present **and** the helper having delivered a
token, so a device with no interactive user never opens one.

**You control two of these rates yourself:** `ttlSec` in the config response, and
`autoScreenshotCaptureInterval`. There is no client-side floor on either.

#### 🔴 No client handles 429 or Retry-After
Zero hits across all three trees. In Electron a 429 falls through every interceptor branch to a
**user-visible `toast.error('Something went wrong. Please try again.')`** — fired from up to three
windows. In HelperService a 429 is just "failed send", and the same batch retries in 120s.

**Corollary: never return 4xx/5xx to mean "no change" — return 200 with the current state.**
And do not rely on 304 / `If-None-Match`: there is no conditional-request logic anywhere.

⚠️ **Poll multiplier:** `TrackingProvider` is mounted **three times** (widget, startup, main
dashboard), each with its own 30s `/user/self` chain and its own 5s pipe poll. That is
**6 `GET /user/self` per minute per logged-in session**, not 2. Also, no `BrowserWindow` sets
`backgroundThrottling: false`, so the effective rate in hidden windows is throttled by Chromium and
is **unmeasured** — treat 5s/30s as code constants, not observed behaviour.

### D2 — Where do logs go? Is anything sent to the backend?

**Three separate systems.**

| System | Path | Retention |
|---|---|---|
| C++ services (NDJSON, one object per line) | `C:\ProgramData\ProgramMonitor\debugLogs\<date>-{Window,Helper}Service.json` | **14 days, pruned only at service start** |
| Electron | `%APPDATA%\pi-focus-business-app\app.log` | **none by time** — rotates at 5 MB to one `.old` |
| Install | `C:\ProgramData\PiFocus\Logs\Install.log` | **none at all**, grows forever |

Size caps: 100 MB/file/day, past which **INFO and WARN are silently dropped** and only ERROR/CRASH
are written. A gap in INFO volume is a size-cap artefact — look for the `logger.rotate` line.

**Sent to the backend — three paths with very different defaults:**
- `POST /agent/log` — **completely ungated**, fires in both prod and stage. From WindowService
  (LocalSystem) it usually arrives with **no `xx-device-token` header**, because `CrashLogApi` reads
  the token from HKCU and LocalSystem's HKCU is the SYSTEM profile. **If you require that header,
  WindowService crash reports are being silently rejected right now.**
- **GlitchTip/Sentry — the two services have OPPOSITE defaults.** WindowService is **off by default**
  (needs `HKLM\…\EnableCrashReporting=1`); **HelperService is ON by default with no registry
  kill-switch.** If anyone tells you "crash reporting is off in prod", that is true only of
  WindowService.
- **Electron sends nothing to you.** Zero hits for sentry/crashReporter/error-report. The only remote
  trace of an Electron error is a Google Analytics event — which goes to Google, not you.

**Native crashes (access violation, stack overflow) are NOT sent to `/agent/log`** — only a local
`crash.fatal` line. And that last-chance filter exists in **WindowService only**; HelperService has
no `SetUnhandledExceptionFilter` and no `set_terminate`. **Backend-side crash counts systematically
under-report the worst crash class.**

#### 🔴 Sensitive data in the local logs — honest answer
- **A live device API token is in plaintext on disk.** The machine-key response body is exactly
  `{data:{apiKeyId, secret}}` and is logged verbatim on the **success** path in both services
  (`DeviceTokenManager.cpp:476`, `ActivityUploader.cpp:162`). Two lines later the code carefully logs
  only the *lengths* — the intent was clearly the opposite.
- **Full browsing URLs, every window title, and the user's UPN (work email)** — the whole activities
  POST body is logged verbatim, 32 KB cap.
- **No ACL hardening.** The directory is created with `CreateDirectoryA(base, NULL)` and `install.ps1`
  contains no `icacls`/`Set-Acl`. **Any standard non-admin user on the machine can read another
  user's browsing history, window titles, UPN and a live device token.**
- Every HelperService call also sends the Windows username, computer name, serial and MachineGuid as
  headers.

> Treat every support bundle collected from a field device as containing exfiltrable credentials, and
> consider whether stolen device tokens need revocation.

### D3 — Timestamps: local or UTC? Clock drift?

**Neither.** Every timestamp the C++ agents upload is a **hardcoded IST (+05:30)** wall-clock string:
`formatISO8601` adds `IST_OFFSET_SECONDS = 19800`, converts with `gmtime_s` (not `localtime`), and
appends the literal `"+05:30"`. Format: `2026-08-14T15:04:05+05:30` — no milliseconds.

Because `std::time(nullptr)` is UTC epoch and `gmtime_s` is used, **the device's timezone setting is
irrelevant** — a laptop in London and one in Delhi both emit correct, comparable `+05:30` timestamps.
The offset label is honest, so a standards-compliant parser converts it correctly. **Only the
device's absolute clock matters.**

Exceptions to know about:
- **Debug-log `ts` fields are UTC-`Z` with milliseconds** — do not compare them naively with the rest.
- `TrackingChangedAt` is a raw UTC epoch **seconds** `REG_QWORD` (not ms, not FILETIME).
- **Electron uses the device's LOCAL timezone** (`new Date().getFullYear()/getMonth()/getDate()`) and
  then reads a daily-report file the C++ helper named with the **IST** date. **On any non-IST device
  these disagree for part of every day** and the UI reads the wrong file.

**Clock-drift handling — what does NOT exist:** no server-time sync, no reading of the HTTP `Date`
header, no skew correction, no monotonic sequence numbers on uploaded records. **You must sanity-check
`start`/`end` server-side; nothing on the device will do it for you, and no field on the wire tells
you the device thought its clock was suspect.**

**What does exist:** a wall-vs-monotonic **clock-jump detector** (±300s) that logs `clock.jump` and
closes the open session at the *pre-jump* time — so an NTP correction mid-session produces a visible
gap or overlap, not a smooth line. Plus the integrity guards that **drop** data rather than fix it.

**Midnight rollover is IST-based.** Sleep/shutdown across midnight is split exactly at IST midnight,
so **expect legitimate rows stamped `T00:00:00+05:30`** — they are not corruption.

---

## E. What we need from the new endpoint

Ordered by how badly it breaks without them.

1. **Reachable with `xx-device-token` and keyed by `serialNumber`.** A user-JWT-only endpoint is
   useless on company devices — they ship only the two C++ binaries and have no JWT. The header name
   is already established. **Ship both auths on the same route.**
2. **Extend `GET /user-devices/{serialNumber}/device-info`** rather than minting a new route.
3. **Return the COMPLETE state every time. Never partial.** Non-negotiable given A7: a missing field
   wipes productivity rules and disables screenshots, and persists the wipe to disk. If a field is
   genuinely unset, send it explicitly with its intended value.
4. **One response must carry all of:** `isTrackingEnabled`, `mode`, `shouldDisplayDashboard`,
   `isActive`/deprovisioned, `productivityConfig{productiveApps, unproductiveApps` *(accept the
   `nonProductiveApps` alias)*`, productiveDomains, nonProductiveDomains}`, `autoScreenshotCapture`,
   `autoScreenshotCaptureInterval`. Today these arrive over **three unrelated channels**.
5. **Emit a server-issued monotonic `stateVersion` (int64) and require it on apply.** The client will
   need a new persisted `lastAppliedStateVersion`. Do **not** expect `TrackingChangedAt` to serve.
6. **All timestamps as UTC epoch integers, never formatted strings** — see D3.
7. **GET must be idempotent, side-effect-free and tolerate N-fold duplicate pulls** (3 windows +
   the service + retries). **Do not treat a pull as a heartbeat**; liveness has its own channels.
   Also make `PATCH /user-devices/device/{id}/tracking` idempotent — up to three windows can fire the
   same stale-pause auto-resume simultaneously.
8. **Document a 429 + Retry-After contract — and assume the client ignores both today.**
9. **Define the 401 behaviour.** `ProductivityConfig::FetchFromApi` has **no 401 branch** — an
   expired-but-present device token **permanently kills the only existing pull loop**. Either make
   the token long-lived on this route or specify the refresh handshake.
10. **Include an explicit deprovisioned state, distinct from 404 and from "paused".** Today a device
    missing from the account yields UI status `no-device` while the agents keep tracking and
    uploading. The client needs a positive instruction to stop.
11. **Ship a companion apply-ack** — `agent:tracking_state` (already specified in
    `PAUSE-RESUME-FLOW.md:73`, never built) or a POST of `{stateVersion, applied, error}`. Without it
    you cannot distinguish "laptop off" from "applied" from "write failed" — the same blind spot,
    just moved.
12. **Emit the socket hint on the user's own PATCH too**, not only on admin changes. And design so a
    permanently-missed hint is survivable: **the pull timer must be primary, the hint strictly an
    optimisation.**

### Hosts to pin in the contract
```
REST prefix   /pi-os-backend/v1/pi-focus-business      (both envs)
API host      api.penpencil.co  |  stage-api.penpencil.co
WS            wss://pi-os-backend.penpencil.co/ws/
              wss://pi-os-backend-stage.penpencil.co/ws/
WS namespace  /pi-focus/agent
```
⚠️ **`src/main/env.ts:36` has a conflicting stage WS host** (`stage-pi-os-backend.penpencil.co` vs
the C++ `pi-os-backend-stage.penpencil.co`). It is currently **dead code** — which is the only reason
stage is not already broken. If the new hint channel is wired through it, stage breaks silently.
Also note Electron's renderer CSP `connect-src` allows only the api/stage-api origins.

---

## F. Client-side work this implies (ours, not yours)

So you can see what has to land on our side before the contract is usable:

- [ ] **Build an HTTP state-pull path in the C++ agent** — none exists today.
- [ ] Persist `lastAppliedStateVersion`; reject older versions at the `TrackingManager` chokepoint.
- [ ] **Introduce a real "unknown" state** so a failed pull doesn't fail open to tracking-ON.
- [ ] Re-arm the socket after the 10 reconnect attempts are exhausted.
- [ ] Call `resetPipeSupport()` — or drop the latch — so one EPIPE stops disabling drift repair.
- [ ] **Remove the stale-pause auto-resume**, or gate it server-side.
- [ ] Trigger a re-sync on resume/unlock **in the service**, not just accidentally via an Electron window.
- [ ] Move the config TTL check outside the 30-minute monotonic gate.
- [ ] Add `SERVICE_ACCEPT_POWEREVENT` so WindowService can even be told the machine woke.
- [ ] Coordinate the three `TrackingProvider` instances into one poller.
- [ ] Add an idempotency key to activity rows.
- [ ] Emit sync-health telemetry — today there is **no** event for a successful sync or staleness, so
      "this device has not pulled in N days" is undetectable from the client side.
- [ ] Stop logging the raw machine-key response body.

---

## Appendix — verification notes

Produced by reading source across four repositories, then re-verifying every claim in a second
adversarial pass. Corrections applied from that pass include: the service is installed by **both**
Intune and Electron (not Intune only); `powerMonitor.resume` **does** cause an indirect re-sync
under two conditions; the Electron main process makes **three** outbound calls, not two;
HelperService is a **third** writer of the device API key; the stale-pause auto-resume fires **per
window**, not per session; `/key` (not `/machine-key`) is the default Electron bootstrap path; and
there are **six** version identities, two of which you receive.

Where a question could not be answered from source it is marked as such — **D1 fleet size is the only
one**, and it needs an answer from IT.

Companion document: `PAUSE-RESUME-FLOW.md` in this repo already specifies the missing report-back
arrow, the boot-time fail-open table, and the authority rules. Its line 6 says *"Backend changes
required: none"* — **that is now false.** Please read it alongside this.
