# PiFocus — 30-Minute Pause Reminder

**Status:** design, awaiting approval before implementation
**Depends on:** [`PAUSE-RESUME-FLOW.md`](./PAUSE-RESUME-FLOW.md) — the reminder must never contradict actual device state
**Backend changes required:** **none**

---

## 1. What the stakeholder asked for

When a user has had tracking paused for 30 minutes, show them a popup saying so, with a notification sound.

- **No buttons.** No *Resume*, no *Keep paused*. It is purely informational — "your tracking has been paused for 30 minutes".
- **Sound.** A short "ting", like a Windows notification.
- **The clock is wall-clock time and does not stop when the machine is off.**

That last point is the whole design. Worked through with the stakeholder's own examples:

| | Example A | Example B |
|---|---|---|
| Pause | 10:00 | 10:00 |
| Machine off | 10:05 | 10:05 |
| Machine back on | 10:20 *(off for 15 min)* | 11:05 *(off for 1 hour)* |
| **Popup fires** | **10:30** — 10 minutes after restart | **immediately on unlock** — the 30 min already elapsed while off |

In both cases the popup lands **30 minutes of real time after the pause began**. Time spent shut down, asleep or locked still counts. If the threshold passed while the machine was off, the popup is waiting the moment the user unlocks.

> **Explicitly NOT "30 minutes of powered-on time".** If it were, Example A would fire at 10:45 (25 more minutes of runtime after a 5-minute head start) and Example B would fire 25 minutes after an hour-late boot. Both are wrong.

---

## 2. Where the clock comes from

Elapsed time needs one thing: **when did this pause start?** It must survive shutdown, and it must be right for a pause an admin started from the backend as well as one the user started in the app.

Nothing records that today. `PAUSE-RESUME-FLOW.md` just made `TrackingManager` the single chokepoint for every pause/resume on the device — so it is the natural place to stamp it, and it is already writing the registry on every transition.

### One new registry value

| Value | Type | Meaning |
|---|---|---|
| `TrackingEnabled` | `REG_DWORD` | existing — `0` paused, `1` running |
| **`TrackingChangedAt`** | **`REG_QWORD`** | **new — Unix epoch seconds of the last transition** |

Written inside `TrackingManager::saveStateToDisk()`, in the same call that writes `TrackingEnabled`, so the two can never disagree. When `TrackingEnabled` is `0`, `TrackingChangedAt` **is** the pause start time.

Why this is the right home:
- **Survives shutdown** — it is in the registry, like the pause state itself.
- **Correct for every pause source** — user-initiated (pipe), admin-initiated (socket), and the boot-time replay all funnel through `setTrackingEnabled()`.
- **Distinguishes pause episodes.** If a user resumes and re-pauses, the timestamp moves and the reminder clock restarts. Without it, an app that was closed across a resume/re-pause cycle could not tell the two episodes apart.
- Available to company Intune devices too, if a service-side reminder is ever wanted.

`GET_TRACKING_STATE` gains the field:

```jsonc
{ "ok": true, "enabled": false, "changedAt": 1755082800 }
```

### Fallbacks

| Situation | Behaviour |
|---|---|
| `TrackingChangedAt` missing (device paused before this version shipped) | The service stamps "now" the first time it sees a paused device with no timestamp. The reminder then fires 30 minutes later showing a **true** duration. Simpler and more honest than displaying a number we cannot substantiate — the only cost is one delayed reminder on the upgrade itself. |
| Clock jumped backwards (`changedAt` in the future) | Re-stamp to now, log it. |
| Elapsed > 24h | Still fires; the text just reads in hours. |
| `GET_TRACKING_STATE` unreachable (service down / old build) | **No reminder.** Unknown is not "paused". Never nag a user whose agent is dead — the message would be a lie. |

---

## 3. When it fires

```
every 60s while the app is running:

  state = pipe GET_TRACKING_STATE
  if state unavailable            -> do nothing (UNKNOWN, never assume)
  if state.enabled (running)      -> clear reminder state, done
  if screen is locked             -> HOLD (do not fire, do not advance)

  elapsedMs = now - (state.changedAt * 1000)
  if elapsedMs >= nextThresholdMs -> FIRE
                                     nextThresholdMs = elapsedMs + 30min
```

Plus an **immediate check** (not waiting for the next tick) on:
- `powerMonitor` **`unlock-screen`** ← this is what makes Example B work
- `powerMonitor` **`resume`** (wake from sleep)
- app startup / login — covers the boot case

### Why the lock guard matters

A popup that fires into a locked session is never seen, and firing it would advance the threshold — so the user comes back to *nothing*. Holding while locked and firing on unlock is what produces the stakeholder's Example B behaviour: turn the laptop on after an hour, unlock, and the popup is there.

The threshold is **not advanced** while holding, so nothing is lost.

### Repeat cadence

Fires at 30 minutes, then every 30 minutes after (60, 90, …). Each popup shows the **actual** elapsed time, not a fixed "30 minutes".

Anti-burst: after firing, the next threshold is `elapsedMs + 30min` — computed from *current* elapsed, never `previous + 30min`. So returning to a machine that was off for 3 hours produces **exactly one** popup, not six. Example B fires once at ~65 minutes elapsed, and the next is at ~95 minutes.

---

## 4. The popup

A small always-on-top card in the bottom-right corner, cloned from the existing widget window (`main.ts:537-621`), which is already a frameless transparent always-visible mini window.

```
        ┌─────────────────────────────────┐
        │  ⏸   Tracking is paused      ×  │
        │                                 │
        │  Your tracking has been paused  │
        │  for 32 minutes.                │
        │                                 │
        │  No activity is being recorded. │
        └─────────────────────────────────┘
```

| Property | Decision |
|---|---|
| Buttons | **None**, per the requirement. Only a small `×`. |
| Auto-dismiss | **30 seconds** on prod, then fades out. Required — with no buttons there would otherwise be no way to get rid of it. **8 seconds on stage**, because the stage cadence is also 30s and a 30s card would still be on screen when the next one fires — permanently visible, and impossible to tell whether the schedule is working. |
| Branding | piFocus logo in the header, brand-blue gradient bar across the top. Amber is reserved for the *state* (pause badge, elapsed time) so it reads as "a piFocus notification" first, "you are paused" second. |
| Focus | `showInactive()` — **never steals focus.** It must not eat a keystroke or an Enter while someone is typing. |
| Always on top | `setAlwaysOnTop(true, 'screen-saver')` so it is visible over other windows. |
| Taskbar | `skipTaskbar: true` |
| Position | Bottom-right of the display **containing the cursor**, computed at show time. Stacks *above* the widget if the widget is on that display, rather than covering it. |
| Repeat while open | Singleton window. A second fire updates the text in place — never two cards. |
| Sound | Plays once on show. |

### The sound

The requirement is that the user immediately recognises *"a notification just arrived"* — not merely that a sound played. So use **the actual Windows notification sound**, the one every Windows user already associates with a toast:

```
C:\Windows\Media\Windows Notify System Generic.wav
```

Confirmed present on this machine (248 KB, shipped with Windows). This beats a custom chime on every axis: instantly recognisable, matches OS convention, no licensing question, and nothing extra to ship.

**How it is loaded.** The main process reads the WAV **once at startup**, base64-encodes it, and passes it to the popup as a data URI in the show payload. The renderer never touches the filesystem — that sidesteps `webSecurity` and CSP entirely, which a `file:///C:/Windows/Media/...` reference from the renderer would run into.

**Fallback chain**, first file that exists wins:

1. `Windows Notify System Generic.wav` — the Win10/11 toast sound
2. `Windows Notify.wav`
3. `notify.wav`
4. `chimes.wav`
5. `assets/pause-reminder.wav` — a bundled copy, for stripped Windows images (N editions, locked-down enterprise builds) where `C:\Windows\Media` has been emptied

**Playback details that actually matter:**

- `webPreferences: { autoplayPolicy: 'no-user-gesture-required' }` on the popup window. Without it Chromium blocks audio in a window the user has never clicked — and this window is deliberately shown with `showInactive()`, so it never gets a click.
- Audio plays fine from an inactive/unfocused window, so not stealing focus costs nothing here.
- Volume left at system default. The user's notification volume is their choice; overriding it to be "more noticeable" is how an app becomes the one people uninstall.
- Played **once per popup**, on show.

If audio fails for any reason the popup still shows — sound is an enhancement, never a gate.

> **Native Windows toast was considered and rejected.** It gives a sound for free, but `app.setAppUserModelId()` is never called in this app, and toasts are silently swallowed by Focus Assist / Do Not Disturb and can be switched off per-app in Windows Settings. For a compliance nudge that is exactly the wrong failure mode. A `BrowserWindow` cannot be suppressed by OS notification policy.

---

## 5. Flows

### Flow A — paused while the user stays at the machine

```
10:00  user pauses          TrackingEnabled=0, TrackingChangedAt=10:00
10:30  tick: elapsed=30min  FIRE — "paused for 30 minutes" + ting
11:00  tick: elapsed=60min  FIRE — "paused for 1 hour"
```

### Flow B — machine off across the threshold *(stakeholder Example A)*

```
10:00  user pauses          TrackingEnabled=0, TrackingChangedAt=10:00
10:05  shutdown             registry persists both values
10:20  boot + login         app starts, checks: elapsed=20min -> not yet
10:30  tick: elapsed=30min  FIRE   (10 minutes after restart)
```

### Flow C — machine off well past the threshold *(stakeholder Example B)*

```
10:00  user pauses          TrackingEnabled=0, TrackingChangedAt=10:00
10:05  shutdown
11:05  boot + login         locked -> HOLD
11:05  user unlocks         unlock-screen -> immediate check
                            elapsed=65min >= 30min -> FIRE at once
                            "paused for 1 hour 5 minutes"
       next threshold = 95min
```

### Flow D — admin paused the device from the backend

Identical. The socket handler goes through `setTrackingEnabled()`, so `TrackingChangedAt` is stamped the same way. The user gets the reminder without ever having touched pause themselves.

### Flow E — user resumes

Any tick that sees `enabled: true` clears the reminder state. A later re-pause writes a fresh `TrackingChangedAt`, so the clock starts from zero — no leftover credit from the previous episode.

### Flow F — agent not running

`GET_TRACKING_STATE` unreachable → **no popup**. "You've been paused for 30 minutes" is false when the service is dead, and there is nothing the user could do about it anyway.

---

## 6. What changes

### C++ — `WindowService`

| File | Change |
|---|---|
| `TrackingManager.cpp/.h` | Write `TrackingChangedAt` (REG_QWORD, epoch seconds) next to `TrackingEnabled` in `saveStateToDisk()`. Read it back in `loadStateFromDisk()` and expose via a getter. On boot replay, **preserve** the stored timestamp rather than stamping a new one — a reboot must not restart the pause clock. |
| `main.cpp` | `GET_TRACKING_STATE` response gains `changedAt`. |

That is the whole service change — it rides on the chokepoint that already exists.

### Electron

| File | Change |
|---|---|
| `src/main/pauseReminder.ts` *(new)* | The scheduler: 60s tick, lock/unlock/resume hooks, threshold tracking, singleton window control. |
| `src/main/main.ts` | Create/show/position the popup window; `powerMonitor` hooks for `lock-screen` / `unlock-screen` / `resume`; add the window to the `tracking-state-changed` fan-out array at `:822`; start the scheduler after `createTray()`. |
| `src/main/trackingPipe.ts` | Surface `changedAt` from `GET_TRACKING_STATE`. |
| `src/main/preload.ts` + `src/renderer/preload.d.ts` | `pause-reminder:*` channels (hand-maintained in sync). |
| `src/renderer/App.tsx` | Route `?pausereminder=1` to the new screen. |
| `src/renderer/Pages/TrackingNotification/PauseReminderScreen.tsx` *(new)* | The card. Fills the already-existing empty directory. |
| `src/renderer/Styles/PauseReminder.css` *(new)* | `pr-*` prefix; transparent-window preamble copied from `Widget.css:16-27`. |
| `assets/pause-reminder.wav` *(new)* | Fallback copy of a notification sound, used only when `C:\Windows\Media` has been stripped. |

### Cadence on stage builds

`env.ts` gets the timings so a **stage build fires after 30 seconds** with zero configuration — testers install stage, pause, and see the card half a minute later:

```ts
export const PF_PAUSE_REMINDER_MS         = isStage ? 30_000 : 30 * 60_000;
export const PF_PAUSE_REMINDER_VISIBLE_MS = isStage ?  8_000 : 30_000;
```

The tick derives from the interval (`interval / 4`, clamped to 5–60s), so stage polls every 7.5s and prod every 60s. Without that scaling a flat 60s tick would make a 30s stage interval fire up to a minute late and behave like 90 seconds.

A debug JSON in `%APPDATA%` overrides it on a prod build, for reproducing a field report. `"enabled": false` in that file is also the production kill switch.

---

## 7. Test plan

Reuses the existing harness in `tests/pause-resume/` — the pipe client and state reader already exist, and `setup-stage-service.ps1` installs a stage service without touching production.

| # | Test | Expected |
|---|---|---|
| 1 | Pause, wait | Fires at exactly the threshold; sound plays; auto-dismisses after 10s |
| 2 | Type in Notepad across a fire | **No character loss, caret does not move** — proves focus is never stolen |
| 3 | **Example A** — pause, kill the app, wait past the threshold, relaunch | Fires within one tick of relaunch, text shows true elapsed |
| 4 | **Example B** — pause, lock, wait past the threshold, unlock | Fires within seconds of unlock, **exactly once** |
| 5 | Sleep 3 hours across the threshold | **Exactly one** popup on wake — not six (anti-burst) |
| 6 | Registry check | `TrackingChangedAt` is `REG_QWORD` and matches the pause moment |
| 7 | **Reboot mid-pause** | `TrackingChangedAt` is unchanged by the boot replay — the clock does not restart |
| 8 | Resume, then re-pause | Clock restarts from zero; no leftover credit |
| 9 | Admin pause from backend (mock socket server) | Reminder fires the same way |
| 10 | Stop the service | **No popup** while unreachable; resumes when the service returns |
| 11 | Repeat cadence | 30, 60, 90 min — each showing true elapsed |
| 12 | Two windows open | Exactly one card in Task Manager, text updates in place |
| 13 | Paused before upgrade (no `TrackingChangedAt`) | Fires without stating a duration |
| 14 | Quit while the card is open | App exits cleanly |

---

## 8. Decisions (confirmed)

1. **Device scope: Electron only.** Personal devices get the popup. Company Intune laptops have no Electron app and get nothing — `TrackingChangedAt` still lands on them, so a service-side version stays possible later, but it would need a UI process in the user session.
2. **Auto-dismiss: 30 seconds.**
3. **Repeat every 30 minutes indefinitely** — 30, 60, 90, … with no cap.
4. **Sound plays on every reminder**, not just the first.

---

## 9. Deliberate non-goals

- **This is a nudge, not a control.** No resume button, no auto-resume, no cap on total paused time. Pause remains indefinite.
- **Does not fire when the app is closed.** The app auto-starts at login, so the boot case is covered; a user who quits it entirely gets nothing until they reopen it.
- **A true exclusive-fullscreen game or D3D app will still cover the card.** Always-on-top beats normal windows and windowed-fullscreen Teams/Zoom, not exclusive fullscreen.
- **Up to 60 seconds late** on a prod build, by design — that is the tick granularity. Unlock and wake are checked immediately, so the cases the stakeholder called out are not subject to it.
