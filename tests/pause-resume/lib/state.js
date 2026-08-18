'use strict';

// Reads the pause state from every layer INDEPENDENTLY, then reports whether
// they agree. This is the core assertion primitive for the whole suite.
//
// Each layer is read through a different mechanism on purpose:
//   registry -> reg.exe query          (what survives a reboot)
//   event    -> PowerShell OpenExisting (what HelperService actually obeys)
//   device   -> named pipe             (what TrackingManager believes)
//   service  -> sc query               (is anyone home)
//
// If all three read through the same code path, a single bug could make them
// agree while the machine is actually broken.

const { execFile } = require('child_process');
const {
  PAUSE_EVENT, HKLM_ROOT_FULL, HKCU_ROOT_FULL, SERVICE_NAME,
} = require('./env');
const pipe = require('./pipe');

function run(cmd, args, timeoutMs = 15000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: timeoutMs, windowsHide: true, maxBuffer: 4 * 1024 * 1024 },
      (err, stdout, stderr) => resolve({ err, stdout: stdout || '', stderr: stderr || '' }));
  });
}

function parseRegOutput(stdout, hive) {
  // "    TrackingEnabled    REG_DWORD    0x1"
  const m = stdout.match(/TrackingEnabled\s+(REG_\w+)\s+(\S+)/i);
  if (!m) return null;

  const type = m[1].toUpperCase();
  const raw = m[2];
  if (type !== 'REG_DWORD') {
    // Present but the wrong type — deliberately NOT interpreted as a boolean,
    // because a REG_SZ "0" would otherwise read back as ENABLED.
    return { present: true, enabled: null, type, raw, hive };
  }
  const num = raw.startsWith('0x') ? parseInt(raw, 16) : parseInt(raw, 10);
  return { present: true, enabled: num !== 0, type, raw, hive };
}

/**
 * Registry TrackingEnabled.
 * Returns { present, enabled, type, raw, hive } — `enabled` is null when absent
 * or when the value has the wrong type.
 *
 * Checks HKLM first then HKCU, mirroring TrackingManager::loadStateFromDisk.
 * The HKCU fallback is the service's documented non-admin path — production
 * runs as LocalSystem and always lands in HKLM, but a console-mode service
 * (used by this harness when not elevated) writes HKCU instead.
 */
async function readRegistry() {
  // PIFOCUS_REG_HIVE=HKCU pins the read to the non-admin hive. Needed only
  // when testing a console-mode WindowService: it cannot write HKLM, so a
  // stale HKLM value left behind by a previous *installed* service would be
  // read as authoritative and every consistency check would fail spuriously.
  // Production always writes HKLM (the service runs as LocalSystem).
  const forced = (process.env.PIFOCUS_REG_HIVE || '').toUpperCase();

  const order = forced === 'HKCU'
    ? [[HKCU_ROOT_FULL, 'HKCU']]
    : forced === 'HKLM'
      ? [[HKLM_ROOT_FULL, 'HKLM']]
      : [[HKLM_ROOT_FULL, 'HKLM'], [HKCU_ROOT_FULL, 'HKCU']];

  for (const [path, hive] of order) {
    const res = await run('reg.exe', ['query', path, '/v', 'TrackingEnabled']);
    if (!res.err) {
      const parsed = parseRegOutput(res.stdout, hive);
      if (parsed) {
        // Pause-start timestamp, read from the SAME hive so the two can never
        // be mixed. Absent on a device paused before this version shipped.
        const ca = await run('reg.exe', ['query', path, '/v', 'TrackingChangedAt']);
        const m = ca.err ? null : ca.stdout.match(/TrackingChangedAt\s+(REG_\w+)\s+(\S+)/i);
        if (m && m[1].toUpperCase() === 'REG_QWORD') {
          const v = m[2];
          parsed.changedAt = Number(v.startsWith('0x') ? BigInt(v) : BigInt(v));
          parsed.changedAtType = m[1].toUpperCase();
        } else {
          parsed.changedAt = null;
          parsed.changedAtType = m ? m[1].toUpperCase() : null;
        }
        return parsed;
      }
    }
  }

  return {
    present: false, enabled: null, type: null, raw: null, hive: null,
    changedAt: null, changedAtType: null,
  };
}

/**
 * Pause event state.
 * signaled == paused. Uses WaitOne(0), which is non-destructive ONLY because
 * the C++ side creates a manual-reset event — test 'waitone-nondestructive'
 * exists to keep that assumption honest.
 *
 * Returns { openable, signaled, error }.
 */
async function readEvent() {
  const ps = `
$ErrorActionPreference='Stop'
try {
  $h = [System.Threading.EventWaitHandle]::OpenExisting('${PAUSE_EVENT}')
  $signaled = $h.WaitOne(0)
  $h.Dispose()
  Write-Output ("{""openable"":true,""signaled"":" + $signaled.ToString().ToLower() + "}")
} catch [System.Threading.WaitHandleCannotBeOpenedException] {
  Write-Output '{"openable":false,"reason":"not-found"}'
} catch [System.UnauthorizedAccessException] {
  Write-Output '{"openable":false,"reason":"access-denied"}'
} catch {
  Write-Output '{"openable":false,"reason":"error"}'
}`.trim();

  const { stdout } = await run('powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', ps]);

  const s = stdout.indexOf('{');
  const e = stdout.lastIndexOf('}');
  if (s === -1 || e === -1) return { openable: false, signaled: null, error: 'unparseable' };
  try {
    const parsed = JSON.parse(stdout.slice(s, e + 1));
    return {
      openable: !!parsed.openable,
      signaled: parsed.openable ? !!parsed.signaled : null,
      error: parsed.reason || null,
    };
  } catch (_) {
    return { openable: false, signaled: null, error: 'unparseable' };
  }
}

/** WindowService's own view, over the pipe. */
async function readDevice() {
  const res = await pipe.getTrackingState();
  if (!res.ok) {
    return {
      reachable: false, enabled: null, changedAt: null,
      unsupported: !!res.unsupported, error: res.error,
    };
  }
  return {
    reachable: true,
    enabled: !!res.data.enabled,
    // Unix epoch seconds of the last transition; 0/undefined = unknown.
    changedAt: typeof res.data.changedAt === 'number' && res.data.changedAt > 0
      ? res.data.changedAt
      : null,
    unsupported: false,
    error: null,
  };
}

async function readServiceRunning() {
  const { err, stdout } = await run('sc.exe', ['query', SERVICE_NAME]);
  if (err && !stdout) return null;
  return /STATE\s+:\s+4\s+RUNNING/i.test(stdout);
}

/**
 * Snapshot every layer and judge consistency.
 *
 * `paused` is reported per layer as a tri-state (true/false/null-for-unknown).
 * `consistent` is true only when every KNOWN layer agrees. Unknown layers are
 * excluded rather than assumed — assuming "running" for an unreadable layer is
 * exactly how you end up reporting a green test on a broken machine.
 */
async function snapshot() {
  const [registry, event, device, serviceRunning] = await Promise.all([
    readRegistry(), readEvent(), readDevice(), readServiceRunning(),
  ]);

  const layers = {
    registry: registry.enabled === null ? null : !registry.enabled,
    event: event.signaled === null ? null : event.signaled,
    device: device.enabled === null ? null : !device.enabled,
  };

  const known = Object.entries(layers).filter(([, v]) => v !== null);
  const consistent = known.length > 0 && known.every(([, v]) => v === known[0][1]);
  const paused = consistent ? known[0][1] : null;

  return {
    paused,
    consistent,
    knownLayerCount: known.length,
    layers,
    detail: { registry, event, device, serviceRunning },
  };
}

function describe(snap) {
  const fmt = (v) => (v === null ? 'unknown' : v ? 'PAUSED' : 'running');
  return (
    `registry=${fmt(snap.layers.registry)}(${snap.detail.registry.hive || '-'}/${snap.detail.registry.type || 'absent'}) ` +
    `event=${fmt(snap.layers.event)} ` +
    `device=${fmt(snap.layers.device)} ` +
    `svc=${snap.detail.serviceRunning === null ? '?' : snap.detail.serviceRunning ? 'running' : 'STOPPED'} ` +
    `=> ${snap.consistent ? `CONSISTENT(${fmt(snap.paused)})` : 'INCONSISTENT'}`
  );
}

module.exports = { readRegistry, readEvent, readDevice, readServiceRunning, snapshot, describe, run };
