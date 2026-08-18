# PiFocus POC — Shared-PC user attribution

## What this proves

Right now, tracking data is attributed **per device**. On a company **PC** the BIOS
serial is often blank/placeholder, so we fall back to the Intune Device ID —
but the same PC is shared by multiple people, so everyone's activity gets
lumped under one user. On a **laptop** the BIOS serial is unique per person,
so attribution already works.

This POC produces a **log file** that shows we can reliably detect **which user
is currently active** (email/UPN) alongside the device's Intune Device ID.
Once we've confirmed the log shape is correct, a future beacon can POST the
same data to the backend for real attribution.

Nothing on your machine is changed. There is nothing to install, no admin
required, no Scheduled Task registered, no registry write, no network call.
The whole POC lives inside this folder and can be deleted at the end.

## How to run

1. Copy this folder to the target machine (email/USB/OneDrive — however you
   prefer). Location doesn't matter.
2. **Right-click `Start-Watcher.ps1` → Run with PowerShell**
   (or from a PowerShell prompt in this folder: `.\Start-Watcher.ps1`)
3. If Windows prompts about execution policy, allow it for this session.
4. A window opens and prints a `[START]`, `[DEVICE]`, `[USER]` block. It
   then keeps running quietly and only prints when the active user changes
   or once per hour as a heartbeat.
5. **Use the machine normally.** If it's a shared PC, ask a colleague to log
   in as themselves and use it for a bit.
6. When done, press **Ctrl+C** in the PowerShell window. It writes a `[STOP]`
   line and exits.
7. Zip the entire `logs\` folder and send it back.

If you close the PowerShell window and reopen it later, just re-run
`Start-Watcher.ps1` — it appends to the same log files.

## What to send back

The whole `logs\` folder. It contains:

| file | purpose |
|---|---|
| `user-events.log` | human-readable timeline, one line per event |
| `snapshots.jsonl` | machine-readable, one JSON object per line, one line per snapshot |
| `latest-user.json` | the most recent snapshot, overwritten on every change |
| `errors.log` | only exists if the watcher hit an exception (optional attach) |

## To inspect a log yourself (optional)

Run `.\Read-Log.ps1` — it prints a colored summary of the log: distinct
users seen, session-change count, device fingerprint, first-seen and
last-seen timestamps per user, any errors. Works on any machine (I use it
too when you send me your log).

## Testing plan

**First: your personal laptop** (which is not Intune-enrolled).
This is a graceful-degradation smoke test. Expected output:
- `[DEVICE] type=Laptop bios='<real serial>'(usable) intuneDeviceId=null (personal device) aadJoined=NO`
- `[USER]   session=1 user=LAPTOP-XX\<you> ... email=<your account name>(src=windows account name (fallback))`

The important thing is that the script runs, produces valid snapshots, and
does not crash on the "no Intune, no AAD, no MDM" fields.

**Then: a shared company PC.** Expected output:
- `[DEVICE] type=PC bios='Default String'(placeholder) intuneDeviceId=<guid> aadJoined=YES`
- Multiple `[USER]` blocks over the run, one per person who signed in.
- At least one `[CHANGE]` line when a different user takes over.

## How to clean up

Delete this folder. Nothing else needs to be undone.
