# PiFocus — Pause / Resume Flow

**Status:** design, awaiting approval before implementation
**Scope:** pause/resume state correctness across backend, WindowService, HelperService and the Electron app
**Applies to:** company devices (Intune, service only) **and** personal devices (Electron + service)
**Backend changes required:** **none**

---

## 1. Why this document exists

Pause/resume today can end up in a state where the backend, the service and the app disagree, and the user is silently tracked (or silently not tracked) without knowing.

Three confirmed facts from the source:

1. **The Electron app never updates the registry.** It signals the Windows event directly via PowerShell (`src/main/pauseControl.ts:22-44`). The registry value `HKLM\SOFTWARE\PiFocus\TrackingEnabled` is written *only* inside `TrackingManager::saveStateToDisk()` (`TrackingManager.cpp:165`), which is only reachable from `setTrackingEnabled()` (`:142`), which has exactly two callers — the service constructor (`:15`) and the backend socket handler (`main.cpp:1829`). **Electron reaches neither.**

2. **WindowService never watches the pause event.** The only handle it opens is leaked and unused at `main.cpp:1717-1718`. HelperService is the sole consumer (`HelperService\main.cpp:1327`).

3. **The backend never learns whether a command landed.** `agent_tracking_toggle` (`main.cpp:1824-1844`) acknowledges nothing on success or failure. `hasAck`/`ack_resp` exist at `WebSocketManager.cpp:368-372` and are unused. `isTrackingEnabled()` is dead code.

### What this does to real users on the next reboot

The service constructor replays the stored registry value onto the live event at every start. Because Electron never wrote that value, it is stale:

| Situation | Registry holds | Result after reboot |
|---|---|---|
| User paused from the app; the machine never received a backend toggle, so the value is **absent** | defaults to `1` (`TrackingManager.cpp:248`) | Event is reset → **tracking silently RESUMES.** The user thinks they are paused and is being monitored. This is the default outcome on a fresh machine. |
| User resumed from the app after an earlier admin pause | `0` | Event is set → **tracking silently RE-PAUSES.** Data quietly stops flowing. These are the "my tracking randomly stopped" reports. |

---

## 2. The contract

These five values are **one logical state**. Any code path that changes one must change all of them, or explicitly converge them.

| Meaning | Backend `isTrackingEnabled` | Registry `HKLM\SOFTWARE\PiFocus\TrackingEnabled` | Event `Global\PiFocusPauseEvent` | HelperService | Electron UI |
|---|---|---|---|---|---|
| **Paused** | `false` | `0` | **signaled** | heartbeat only, no tracking | Paused / Inactive |
| **Running** | `true` | `1` | **non-signaled** | tracking normally | Active |

> Stage builds use the parallel names `Global\PiFocusPauseEventStage`, `HKLM\SOFTWARE\PiFocusStage`, `\\.\pipe\PiFocusIPCStage` (`Env.h:35-36`). Anything hardcoding the prod names is a silent no-op on stage.

### Authority rules

1. **The backend holds the desired state.** If the backend and the device disagree, the device converges to the backend.
2. **`TrackingManager` is the only component allowed to mutate pause state on the device.** It is the single point where the event and the registry move together. Nothing else may call `SetEvent`/`ResetEvent` on the pause event, and nothing else may write `TrackingEnabled`.
3. **Local user actions write up before they write down.** Electron PATCHes the backend first and only touches the device if that succeeded. *(Already the behaviour at `TrackingContext.tsx:350-351` — unchanged.)*
4. **The registry is the boot-time truth.** On service start the stored value is replayed onto the event. This is correct **once rule 2 holds**, because the registry then records every decision ever made.

> ### Why the constructor must NOT read the live event
> HelperService creates the pause event with `CreateEventA(NULL, TRUE, FALSE, ...)` (`HelperService\main.cpp:2865`) — i.e. **non-signaled** — and it commonly wins the startup race against WindowService. If the constructor read the live event and treated it as truth, every reboot would read "running" and **silently resume every paused device**. Registry wins at boot; backend wins at reconcile.

---

## 3. The one structural change

```
BEFORE  (two writers, only one correct)

  Electron ──PowerShell SetEvent──▶  Event  ──▶ HelperService
                                       ✗  registry never written  ← THE BUG

  Backend  ──socket──▶ TrackingManager ──▶ Event + Registry        ✓
```

```
AFTER  (one writer, always consistent)

  Electron ──named pipe───┐
                          ├──▶  TrackingManager  ──┬──▶ Event ──▶ HelperService
  Backend  ──socket───────┘   (single chokepoint)  ├──▶ Registry
                                                   ├──▶ ack + agent:tracking_state ──▶ Backend
                                                   └──▶ readable via pipe ──▶ Electron UI
```

### Why the named pipe, and why it needs no security work

WindowService already runs a pipe server at `\\.\pipe\PiFocusIPC` (`Env.h:81`). Three things make this the cheap, correct transport:

- Its DACL already grants `Everyone: GENERIC_ALL` with a Low integrity label (`PipeServer.cpp:18-25`), so a normal medium-integrity Electron process connects **with no UAC prompt and no security-descriptor change**.
- The command dispatch lambda at `main.cpp:1849` already captures `trackingManager` by reference — **zero plumbing**.
- `PF_PIPE_NAME` already exists and is environment-aware at `src/main/env.ts:32`. It is currently a dead constant that nothing imports; Electron has never spoken to this pipe.

### New pipe commands

Wire format is already fixed by `PipeServer.cpp:82-95`: **`uint32` little-endian byte count, then that many bytes of JSON.** Not newline-delimited. 1 MB cap.

> **Two things a client MUST get right** — both were found by the test suite, and both looked exactly like "the service doesn't support this command":
>
> 1. **Write the header and the body as two separate writes.** The pipe is `PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE`, so every `WriteFile` becomes its own discrete message. The server's `ReadFrame` does `ReadExact(&len, 4)` then `ReadExact(body, len)` — two reads expecting two messages. A single concatenated write makes the server's 4-byte read return `ERROR_MORE_DATA`, `ReadExact` returns false, and the connection is dropped with "Failed to read request frame", which surfaces to the client as `EPIPE`.
> 2. **Retry on `ENOENT`.** See the pipe-instance note below.

| Request | Response |
|---|---|
| `{"type":"SET_TRACKING_ENABLED","enabled":false}` | `{"ok":true,"enabled":false}` |
| `{"type":"GET_TRACKING_STATE"}` | `{"ok":true,"enabled":true}` |

`SET_TRACKING_ENABLED` calls `trackingManager->setTrackingEnabled(enabled)`, which already performs `SetEvent`/`ResetEvent` (lines 116/128) **and** `saveStateToDisk()` (line 142) in a single call — exactly the invariant that is broken today.

**Both commands must return a non-empty JSON string on every path, including parse failure.** `PipeServer.cpp:184` skips writing the response frame when the handler returns `""`, which leaves the client blocked until the server disconnects. Do not repeat the existing `SET_DEVICE_TOKEN` bug where an empty token falls through to `return "";` at `main.cpp:1958`.

### Pipe instance recycling — fixed as part of this change

`PipeServer::listenLoop` used to `DisconnectNamedPipe` + `CloseHandle` and only *then* create the next instance. In that window the pipe name has **zero instances**, so a client connecting at that moment gets `ENOENT` — the name genuinely does not exist. It also declared `nMaxInstances = 4` while only ever creating one, so the 4 was meaningless.

HelperService mostly got away with this: it talks every few seconds and retries. The Electron app does not — it now polls device state every 5s from up to three windows, on top of the helper's traffic and the reconciler. The load test hit it immediately (7 of 8 concurrent clients failed).

Two-part fix:
- **Server:** always create the replacement instance *before* tearing the current one down, plus `PIPE_UNLIMITED_INSTANCES`. Concurrent clients now queue on a live name.
- **Client:** retry on `ENOENT` with a short backoff, in both the Electron client and the test harness. This is the standard named-pipe client contract — it is what `WaitNamedPipe` exists for — and it protects against any residual race.

Both were needed: with only the client retry, 32-way concurrency still failed; with both, 9,126 operations over 90 seconds ran with zero failures.

---

## 4. Flows

### Flow 1 — user pauses in the Electron app *(personal device)*

```
1. Electron   PATCH /user-devices/device/{id}/tracking  { isTrackingEnabled: false }
              └─ if this fails: STOP. Show the error. Do NOT touch the device.
2. Electron   pipe → SET_TRACKING_ENABLED { enabled: false }
3. Service    TrackingManager.setTrackingEnabled(false)
              ├─ SetEvent(pause event)        → signaled
              └─ saveStateToDisk()            → HKLM TrackingEnabled = 0
4. Helper     next loop tick (≤ 1s) sees the event signaled → stops tracking, heartbeat only
5. Electron   applyPause() → localStorage, then broadcast → every window shows Paused
```

**End state:** backend `false`, registry `0`, event signaled, helper stopped, UI Paused. ✅

**If the service is an older build without the pipe command:** fall back to the current PowerShell event poke so the user is never blocked, tag the result `via: 'powershell'`, and log it. That path leaves the registry stale — a *degraded* mode that exists only until the service rollout completes. The log line is how we find machines still on it.

### Flow 2 — user resumes in the Electron app

Mirror image: PATCH `true` → pipe `SET_TRACKING_ENABLED { enabled: true }` → `ResetEvent` + registry `1` → helper resumes → `applyResume()` clears localStorage → broadcast.

### Flow 3 — admin pauses/resumes from the backend *(works on **company AND personal** devices)*

This is the socket path. It lives in WindowService, which is installed on Intune company laptops too.

```
1. Backend    socket.io emit on /pi-focus/agent, event "command":
              { from:"USER", type:"agent_tracking_toggle",
                senderId:"…", payload:{ enabled:false } }

2. Service    WebSocketManager unwraps → TrackingManager.setTrackingEnabled(false)
              ├─ SetEvent + registry 0        (the same chokepoint as Flow 1)
              └─ ack / agent:tracking_state   (optional, see Flow 7)

3. Helper     next tick → stops tracking

4a. COMPANY device  → done. No Electron exists. Registry, event and backend all agree.

4b. PERSONAL device → the app reflects it two independent ways:
      • pipe poll GET_TRACKING_STATE every 5s   → UI flips within ~5s        (new, fast path)
      • doSync reads device.isTrackingEnabled   → within 15-30s              (already exists)
```

**Three bugs in the current socket handler must be fixed here**, or backend-initiated pause stays unreliable:

1. **`main.cpp:1827` reads `payloadJson.value("enabled", true)`.** A payload missing `enabled` — or one where `payload` was not an object, leaving `payloadJson` as `"{}"` (`WebSocketManager.cpp:389`) — **resumes tracking**. A malformed pause command turns monitoring *on*. Reject a missing or non-boolean `enabled`; never default.
2. **A wrong JSON type silently drops the command.** `"enabled": "false"` (string) or `0` (int) raises a `type_error`, is swallowed at `main.cpp:1840`, logged only via `OutputDebugStringA` (invisible for a service), and the backend never finds out. Accept `true/false`, `0/1` and `"true"/"false"` defensively, and log rejections through `DebugLogger` so they appear in `debugLogs`.
3. **`payload` is flattened.** `WebSocketManager.cpp:405-415` keeps only string/int/double/bool leaves — nested objects and arrays are silently dropped. `payload` must stay flat.

### Flow 4 — service restart / machine reboot

```
TrackingManager constructor
  ├─ openOrCreatePauseEvent()    OpenEvent first; Create with the permissive SDDL if absent
  ├─ loadStateFromDisk()         HKLM first, HKCU fallback, default ENABLED if neither
  └─ setTrackingEnabled(saved)   forces the event to match the persisted decision
```

**This logic is already correct and stays unchanged.** Once rule 2 holds, the registry records every decision, so replaying it is right. The reboot-revert bug disappears not by changing the constructor but by making Electron stop bypassing it.

Three hardening fixes while in this area:

- `loadStateFromDisk` passes `NULL` for the value-type out-parameter (lines 217, 236). A `REG_SZ` `"0"` would be copied as byte `0x30` and read as **enabled**. Validate `type == REG_DWORD`, as `main.cpp:131-134` already does elsewhere.
- It omits `KEY_WOW64_64KEY` (which `main.cpp:128/154` passes), so a 32-bit writer lands in `Wow6432Node` and is invisible to the service.
- `saveStateToDisk` never checks the return of `RegSetValueExA` (lines 165, 186) yet returns `true` at line 171. A silent registry write failure is exactly the drift this change exists to prevent.

### Flow 5 — HelperService restart

Helper re-opens the event and obeys whatever it finds. `CreateEventA` on an existing name *opens* it and ignores the initial-state argument, so a helper restart cannot clobber the state. **No logic change needed.**

**One fix:** when the helper creates the event first (`HelperService\main.cpp:2865`) it passes `NULL` security attributes, producing a default DACL of creator + SYSTEM + Administrators. On those machines a standard user gets `ACCESS_DENIED` opening the event — which is why pause silently fails for some users today. Use the same permissive SDDL that `TrackingManager.cpp:50-57` already builds. The pipe path makes this less critical, but the PowerShell fallback still depends on it.

### Flow 6 — the reconciler *(this is what guarantees the requirement)*

> **backend paused → app shows paused → registry `0`
> backend resumed → app shows resumed → registry `1`**

On every `doSync` (already running every 15-30s, `TrackingContext.tsx:269-293`) and at app startup:

```
backendPaused = !device.isTrackingEnabled           already computed at TrackingContext.tsx:223
devicePaused  = !(pipe GET_TRACKING_STATE).enabled

if (backendPaused !== devicePaused) {
    log the drift
    pipe → SET_TRACKING_ENABLED { enabled: !backendPaused }    // backend wins — rule 1
    re-read to confirm; if still mismatched, surface an error in the UI
}

UI renders from backendPaused
```

Because this runs continuously it repairs drift from **any** cause — a missed socket emit, a failed registry write, an older build that got poked via PowerShell, a hand-edited registry value. On personal devices this is what makes the contract self-healing.

**Do not run the reconciler while a local pause/resume is in flight**, or it will fight the user's own click. Gate it behind the existing in-flight / `isButtonReady` state.

### Flow 7 — reporting device truth back to the backend *(OPTIONAL — safe to skip)*

Today the backend is a write-only commander and cannot tell whether anything landed. Two purely additive, device-side changes. **Neither is required for the contract, and neither needs any backend work** — both are inert until the backend chooses to listen:

- **Populate `ack_resp` when `hasAck` is true** (`WebSocketManager.cpp:368-372`). If the backend never uses acks this is a no-op, exactly as today. The moment it opts into `emitWithAck` it gets confirmation for free.
- **Emit `agent:tracking_state { enabled, source, serialNumber }`** on `/pi-focus/agent` after every successful transition, whatever the source. Socket.io silently drops an event with no listener, so this is free and safe.

Until the backend consumes these, backend state is *intent* and device state is *reality* — and **Flow 6 keeps them together with no backend involvement at all.**

---

## 5. Does this need a backend change? **No.**

Everything runs on backend APIs that already exist and are already in use.

| What the flow uses | Status |
|---|---|
| `PATCH /user-devices/device/{id}/tracking { isTrackingEnabled }` | **Already exists**, already called by the app (`agentApi.ts:55-62`) |
| `GET /user/self` → `device.isTrackingEnabled` | **Already exists**, already read every 15-30s (`TrackingContext.tsx:203-223`) |
| socket.io `command` / `agent_tracking_toggle` | **Already exists**, the backend already emits it — the device just handles it correctly now |

Both required directions are satisfied with existing endpoints:

- **User pauses in the app** → existing PATCH informs the backend → new pipe call informs the service → registry `0`.
- **Admin pauses in the backend** → existing socket emit reaches the service → registry `0`; independently, the app's reconciler reads the existing `/user/self` and converges the device. Two paths, both already present.

The only part that genuinely needs backend work is the deferred **Phase 2** below — which is exactly why it is separate.

---

## 6. What changes, file by file

### C++ — `C:\PiBusiness5\PiBusiness\PiBusiness_Solution\PiBusiness_Solution\`

| File | Change |
|---|---|
| `WindowService\main.cpp` | Add `SET_TRACKING_ENABLED` + `GET_TRACKING_STATE` to the dispatch chain (`:1858-1874`), never returning `""`. **Gate the `onDataReceived` heartbeat update (`:1969-1975`) by message type** — mandatory, see the warning below. Fix the `agent_tracking_toggle` default and type handling (`:1824-1844`). Optionally ack + emit `agent:tracking_state`. |
| `WindowService\TrackingManager.cpp/.h` | `m_trackingEnabled` → `std::atomic<bool>`; mutex around `setTrackingEnabled` (now reachable from both the socket thread and the pipe thread while touching a kernel object *and* the registry). Wire up the existing dead `isTrackingEnabled()` for the pipe getter. `REG_DWORD` validation, `KEY_WOW64_64KEY`, check `RegSetValueExA`. **Constructor logic unchanged.** |
| `WindowService\WebSocketManager.cpp` | *(optional)* populate `ack_resp` in the `command` listener. |
| `HelperService\main.cpp` | `:2865` — create the pause event with the permissive SDDL from `TrackingManager.cpp:50-57` instead of `NULL` security attributes. |

> ### ⚠ Mandatory companion fix — the helper watchdog
> `PipeServer.cpp:180` fires `m_callback` for **every** frame, including duplex requests. `main.cpp:1969-1975` uses that callback to refresh `lastHeartbeatMonotonic`. Today only HelperService speaks on this pipe, so it is harmless. **The moment Electron becomes a pipe client, its traffic masquerades as HelperService liveness and suppresses the 30-second helper watchdog** (`:1762-1763`) — a dead helper would never be detected or restarted. This must ship in the same change as the new pipe commands.

### Electron — `C:\pi-focus-business-electron\`

| File | Change |
|---|---|
| `src/main/trackingPipe.ts` *(new)* | The app's first pipe client. `net.connect(PF_PIPE_NAME)` — a Windows pipe path is a valid `net.connect` target, no native dependency. `uint32`-LE length prefix + JSON both ways, **3-second timeout**, and treat a broken pipe as *unsupported* (an older service falls through to `return "";` and writes no response frame). Cache "unsupported" for the session. Reference implementation: `HelperService\PipeClient.cpp:14-155`. |
| `src/main/pauseControl.ts` | `setTracking(enabled)` tries the pipe, falls back to the existing PowerShell poke, returns `{ success, via: 'pipe' \| 'powershell' }` so logs and diagnostics show which path ran. Add `-NoProfile -NonInteractive -ExecutionPolicy Bypass`, `windowsHide`, `timeout` to `runPowerShell` (`:10-20`). |
| `src/main/main.ts` | New `tracking:get-state` IPC backed by `trackingPipe.getTrackingState()`. Existing handlers at `:806-811` keep their names and signatures. |
| `src/main/preload.ts` + `src/renderer/preload.d.ts` | Expose `getState()` on the existing `pauseApi` bridge (`preload.ts:65-68`). These two files are hand-maintained in sync — missing the `.d.ts` is a compile break. |
| `src/renderer/Context/TrackingContext.tsx` | The Flow 6 reconciler inside `doSync` after `backendPaused` (`:223`), gated so it never runs during a local pause/resume. Plus a 5s `GET_TRACKING_STATE` poll so backend-initiated changes reflect in ~5s instead of up to 30s. |

---

## 7. Rollout order

1. **This document approved.** ← nothing starts before this
2. C++ changes → rebuild → codesign → **bump version** → stage `.intunewin`
3. Electron: `trackingPipe.ts` + pipe-first `pauseControl.ts`; verify the registry flips on every pause/resume
4. Electron: Flow 6 reconciler + 5s state poll
5. *(optional)* ack + `agent:tracking_state`
6. Stage soak → prod

**Roll the service out before the app.** New service + old app is safe. Old service + new app degrades to the PowerShell fallback rather than breaking. Neither combination regresses.

---

## 8. Verification

After each of these, **all four must agree**: `reg query "HKLM\SOFTWARE\PiFocus" /v TrackingEnabled`, the event state, the Electron UI, and the backend's `isTrackingEnabled`.

| # | Test | Expected |
|---|---|---|
| 1 | Pause in the app | Registry **0** within a second. Resume → **1**. *(Today it never changes — the headline fix.)* |
| 2 | Pause in the app → reboot | Still paused. *(Today it silently resumes.)* |
| 3 | Admin pause → resume in the app → reboot | Still resumed. *(Today it silently re-pauses.)* |
| 4 | Admin pause from backend, **personal device** | Registry 0, helper stops, UI flips to Paused within ~5s |
| 5 | Admin pause from backend, **company device** (no Electron) | Registry 0, helper stops, `debugLogs` shows `tracking.paused` |
| 6 | Admin resume from backend | Registry 1, helper resumes, UI Active |
| 7 | **Drift repair** — manually `SetEvent` while backend says running | Reconciler restores it within one `doSync` and logs the drift. Repeat with a hand-edited registry value. |
| 8 | New app + **old** service | Fallback fires, log records `via=powershell`, pause still works |
| 9 | **Old** app + new service | PowerShell poke still works; restart replays the registry as before; no regression |
| 10 | **Watchdog regression (critical)** — kill `HelperService.exe`, then click pause/resume repeatedly | WindowService still detects the dead helper within 30s and restarts it |
| 11 | `agent_tracking_toggle` with `payload` missing `enabled` | Rejected and logged — **not** treated as resume |
| 12 | `"enabled": "false"` as a string | Accepted defensively or rejected and logged — never silently dropped |
| 13 | Standard (non-admin) user, helper created the event | Pause/resume works via the pipe with no UAC prompt |
| 14 | Backend PATCH fails (network off) | App shows an error and does **not** change the device; registry and event unchanged |
| 15 | Registry value type | Written as `REG_DWORD`. Do not hand-edit with `reg add /t REG_SZ` when testing (see Flow 4). |

---

## 9. Deferred — Phase 2 (socket offline). **The only part needing backend work.**

If the backend flips `isTrackingEnabled` while the device's socket is disconnected, the emit is lost.

- **Personal devices are already covered** by Flow 6 — the app pulls the existing `/user/self` every 15-30s and converges the device, socket or no socket. **No backend change.**
- **Company devices are not.** No Electron, and WindowService only learns of changes via the socket. Two options to design later, both needing a backend contract:
  - **(a)** the backend re-asserts tracking state on socket reconnect, or
  - **(b)** tracking state rides along on a call HelperService already makes (it hits `/agent/configurations` and PATCHes `/agent/device-status`) and is handed to WindowService over the pipe.

The hook point is already designed in: `TrackingManager` is the single mutation chokepoint, so a reconnect-reconcile is one extra caller, not a redesign.

---

## 10. Related work, not in this change

**Next up after this ships:** the 30-minute paused reminder — a small always-on-top corner card that does not steal focus, offering *Resume tracking* / *Keep paused*, with the timer owned by the Electron main process and a 1-minute cadence on stage builds. It depends on this work, because the reminder must never tell users something the device state contradicts.

**Adjacent issues found while investigating — logged, not fixed here:**

- `main.ts:767-770` — `device-key:set` / `device-key:clear` do not `await` the registry write and return `true` regardless, so a caller that writes the token then immediately signals the service can race the write.
- `serialNumberStore.ts:33,50` uses `wmic`, **deprecated and removed by default on recent Windows 11 builds**. Once the pipe client exists, the service's existing `GET_SERIAL_NUMBER` command is a strictly more reliable source.
- `WebSocketManager::sendCommandToUser()` (`:306`) is never called, and its payload conversion is a `// TODO` stub.
- `docs/architecture.md:444` claims state is persisted to **both** HKLM and HKCU. Wrong — they are alternatives, and the HKCU branch is dead in production: the service runs as LocalSystem so HKLM always succeeds, and `HKEY_CURRENT_USER` for LocalSystem resolves to `HKU\S-1-5-18`, not the logged-in user.
- `TECHNICAL_DOCUMENTATION.md:1266` claims pause signals travel via named pipe. Wrong today — it becomes true after this change.
