# Pause / Resume test harness

Proves the contract in [`PAUSE-RESUME-FLOW.md`](../../PAUSE-RESUME-FLOW.md): the backend, the registry, the Windows pause event and the Electron UI must all agree.

Every test reads the three device layers **independently** — `reg.exe` for the registry, PowerShell `OpenExisting` for the event, the named pipe for the service's own view — so a single bug cannot make them agree while the machine is broken.

| Meaning | Backend | Registry `TrackingEnabled` | Event | HelperService |
|---|---|---|---|---|
| **Paused** | `isTrackingEnabled:false` | `0` | signaled | heartbeat only |
| **Running** | `isTrackingEnabled:true` | `1` | non-signaled | tracking |

---

## Quick start

These are **PowerShell** commands (Windows PowerShell 5.1 has no `&&`, and env vars are set with `$env:`):

```powershell
cd tests\pause-resume

node check-state.js          # read-only health check — safe anywhere, incl. prod
npm install                  # only needed for the socket tests (socket.io)
node run-tests.js            # non-destructive suite
```

To target a stage install:

```powershell
$env:PIFOCUS_ENV = 'stage'
node run-tests.js
```

`check-state.js` has **no dependencies** and never mutates. Give it to IT or run it on a user's machine to answer "is this device's pause state sane?"

### Running the destructive tests

`--include-destructive` stops and starts a real Windows service and kills HelperService, so it needs an **installed** service and an **elevated** shell. If you only have the locally-built binaries, install them as a stage service first — separate service name, install dir, pipe, event and registry root, so production is untouched:

```powershell
# elevated PowerShell
cd tests\pause-resume
.\setup-stage-service.ps1

$env:PIFOCUS_ENV = 'stage'
node run-tests.js --include-destructive

.\teardown-stage-service.ps1
```

`setup-stage-service.ps1` refuses to install a WindowService that lacks the `SET_TRACKING_ENABLED` marker, so a pre-fix binary cannot make the tests pass or fail for the wrong reason.

If no service is installed at all, you can still run everything except the service-restart and watchdog tests by launching `WindowService.exe` from a console and passing `--console-mode`. When not elevated the service writes the registry to HKCU instead of HKLM, so pin the checker to that hive:

```powershell
$env:PIFOCUS_ENV = 'stage'
$env:PIFOCUS_REG_HIVE = 'HKCU'
node run-tests.js --console-mode
```

> **Console-mode caveat — read this before believing a console-mode result.**
> A non-elevated `WindowService.exe` **writes HKCU** (the documented `ERROR_ACCESS_DENIED` fallback) but `loadStateFromDisk` still **reads HKLM first**. If HKLM holds leftovers from a previous *installed* service run, a console-mode restart loads that stale state instead of what it just wrote, and any test involving a restart is measuring the wrong thing.
>
> Production is unaffected: the service runs as LocalSystem, so HKLM always succeeds and read and write use the same hive.
>
> `PIFOCUS_REG_HIVE=HKCU` only pins the **checker**, not the service. So **restart-related tests are meaningless in console mode** — run them against a real installed service via `setup-stage-service.ps1`.

---

## Commands

| Command | What it does |
|---|---|
| `node check-state.js` | One-shot consistency verdict |
| `node check-state.js --watch` | Re-checks every 2s — watch state change live |
| `node check-state.js --json` | Machine-readable, for support tooling |
| `node run-tests.js` | Contract + malformed-input + load + concurrency |
| `node run-tests.js --include-destructive` | Also restarts the service and kills the helper |
| `node run-tests.js --only=load,concurrency` | Subset by name |
| `node run-tests.js --load-iterations=500` | Heavier load run |
| `node run-tests.js --soak-seconds=300` | 5-minute soak |
| `node mock-socket-server.js` | Fake backend for admin-initiated tests |
| `node socket-tests.js` | Backend-initiated (socket.io) suite |

Set `PIFOCUS_ENV=stage` for a stage install — it switches the pipe name, event name, registry root and service name together. Getting this wrong is otherwise silent, so `check-state.js` reports which env it used.

---

## What each suite covers

### `run-tests.js` — device-side (no backend needed)

**Contract** — after a pause and after a resume, all three layers agree and match what was asked.

**`regression/registry-actually-changes-on-every-toggle`** — the headline test. Before the fix, an app-initiated toggle *never* wrote the registry; this asserts it now follows every time. Run this against an old build and it fails, which is the A/B proof.

**Malformed input** — the old socket handler defaulted a missing `enabled` to `true`, so a malformed *pause* turned monitoring *on*. These prove the command is now rejected and state is left untouched:
- missing `enabled` → rejected, not defaulted
- object/garbage `enabled` → rejected
- every malformed variant still gets a response frame (an empty return makes `PipeServer` skip the frame and hang the client)
- `0`/`1`/`"true"`/`"false"` are accepted, not dropped
- unparseable frames don't change state

**`waitone-nondestructive`** — 25 consecutive event polls must not clear the signal. If `WaitOne(0)` ever consumed it, polling would silently resume a paused device. This guards an assumption about the C++ event being manual-reset.

**Load** — 200 sequential toggles (configurable), asserting the service's echoed state every iteration and full three-layer consistency every tenth. Reports avg/max latency.

**Concurrency** — 8 simultaneous clients × 10 rounds asking for the *same* state, then 8 opposing clients × 8 rounds. The second one deliberately does not assert who wins — only that the layers never end up **torn**, which is the real invariant and the reason `TrackingManager` got a mutex and an atomic.

**Reads under write pressure** — continuous `GET_TRACKING_STATE` during 60 writes, asserting no read ever returns a non-boolean.

**Destructive** (`--include-destructive`):
- `watchdog/helper-restart` — kills `HelperService.exe`, then hammers the pipe for 45s. The helper must still be restarted. This is the test that catches the heartbeat-spoof bug: `PipeServer` fires its data callback for *every* frame, so without the type gate, app traffic would masquerade as helper liveness and a dead helper would never be detected.
- `persistence/*` — stop/start the service and assert the state survived. Failing these is the silent-revert bug.

### `socket-tests.js` — backend-initiated (Flow 3)

Covers the path **company Intune devices depend on**, since they have no Electron app. Needs the mock server.

- admin pause/resume → registry, event and service all follow
- 5 pause/resume cycles stay consistent
- missing `enabled` is rejected, **not** defaulted to resume
- `"false"` (string) and `0`/`1` are honoured rather than silently dropped
- state holds when the socket goes quiet

---

## Running the socket tests

WindowService connects to a compile-time URL. **Stage builds only** read an override from the registry — the redirect is `#ifdef PIFOCUS_STAGING` and is verifiably absent from prod binaries:

```
PROD  WindowService.exe   missing  TestWsUrl
STAGE WindowService.exe   FOUND    TestWsUrl
```

Setup:

```bash
npm install
node mock-socket-server.js        # leave running
```

```powershell
reg add HKLM\SOFTWARE\PiFocusStage /v TestWsUrl /t REG_SZ /d "ws://127.0.0.1:8899" /f
sc stop PiFocusWindowServiceStage
sc start PiFocusWindowServiceStage
```

Wait for `[mock] agent connected`, then:

```bash
PIFOCUS_ENV=stage node socket-tests.js
```

Teardown — **do not skip this**:

```powershell
reg delete HKLM\SOFTWARE\PiFocusStage /v TestWsUrl /f
sc stop PiFocusWindowServiceStage
sc start PiFocusWindowServiceStage
```

The service only opens its socket **after** HelperService hands it a device token over the pipe, so the helper must be running and the device enrolled. If no agent connects, that's usually why.

The mock server also exposes a control API:

```bash
curl -X POST http://127.0.0.1:8899/emit/pause
curl -X POST http://127.0.0.1:8899/emit/resume
curl -X POST http://127.0.0.1:8899/emit/raw -d '{"enabled":"false"}'
curl http://127.0.0.1:8899/status
```

---

## A/B: old build vs new build

The suite is the A/B instrument. Run it against each build:

| Test | Old service | New service |
|---|---|---|
| `check-state.js` | `device: unknown — predates the tracking pipe` | all three layers readable |
| `regression/registry-actually-changes-on-every-toggle` | **FAIL** — registry never moves | PASS |
| `persistence/pause-survives-a-service-restart` | **FAIL** — silently resumes | PASS |
| `malformed/missing-enabled-is-rejected` | n/a (no pipe command) | PASS |
| `socket/missing-enabled-is-rejected-NOT-defaulted` | **FAIL** — resumes tracking | PASS |

`check-state.js` against the currently deployed build reports exactly this, which is how you confirm a machine still needs the update:

```
service   unknown   unreachable: EPIPE: read EPIPE
Consistent so far, but the installed WindowService predates the tracking pipe.
App-initiated pause on this machine will NOT update the registry.
```

---

## Notes

- `run-tests.js` records the machine's original state at startup and restores it at the end, including on a crash.
- Non-destructive tests do toggle tracking many times while running. Expect a gap in that machine's activity data — don't run the load suite on someone's working laptop mid-day.
- Exit codes: `0` all passed, `1` failures, `2` preflight failed (service down, or a build without the pipe commands).
