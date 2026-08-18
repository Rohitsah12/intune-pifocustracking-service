'use strict';

// Standalone consistency checker. No dependencies — safe to run on any user's
// machine, including production, to answer "is this device's pause state sane?"
//
//   node check-state.js
//   node check-state.js --watch          re-check every 2s
//   node check-state.js --json           machine-readable, for support tooling
//   PIFOCUS_ENV=stage node check-state.js
//
// Read-only: never changes state.

const env = require('./lib/env');
const st = require('./lib/state');

const argv = process.argv.slice(2);
const WATCH = argv.includes('--watch');
const JSON_OUT = argv.includes('--json');

const c = {
  green: (s) => `\x1b[32m${s}\x1b[0m`,
  red: (s) => `\x1b[31m${s}\x1b[0m`,
  yellow: (s) => `\x1b[33m${s}\x1b[0m`,
  dim: (s) => `\x1b[2m${s}\x1b[0m`,
  bold: (s) => `\x1b[1m${s}\x1b[0m`,
};

function verdict(snap) {
  if (snap.knownLayerCount === 0) {
    return { level: 'error', text: 'Nothing readable — is the service installed and running?' };
  }
  if (!snap.consistent) {
    return {
      level: 'error',
      text: 'INCONSISTENT — the layers disagree. The device will flip state on the next service restart.',
    };
  }
  if (snap.knownLayerCount < 3) {
    const missing = Object.entries(snap.layers)
      .filter(([, v]) => v === null).map(([k]) => k).join(', ');
    if (snap.detail.device.unsupported) {
      return {
        level: 'warn',
        text: `Consistent so far, but the installed WindowService predates the tracking pipe ` +
              `(unreadable: ${missing}). App-initiated pause on this machine will NOT update the registry.`,
      };
    }
    return { level: 'warn', text: `Consistent, but could not read: ${missing}` };
  }
  return {
    level: 'ok',
    text: `All three layers agree: tracking is ${snap.paused ? 'PAUSED' : 'RUNNING'}.`,
  };
}

async function once() {
  const snap = await st.snapshot();
  const v = verdict(snap);

  if (JSON_OUT) {
    console.log(JSON.stringify({
      env: env.ENV,
      timestamp: new Date().toISOString(),
      paused: snap.paused,
      consistent: snap.consistent,
      verdict: v.level,
      message: v.text,
      layers: snap.layers,
      detail: snap.detail,
    }, null, 2));
    return v.level === 'ok';
  }

  const fmt = (val) => (val === null ? c.yellow('unknown') : val ? c.red('PAUSED') : c.green('running'));

  console.log(c.bold(`\nPiFocus tracking state  ${c.dim(`(env=${env.ENV}, ${new Date().toLocaleTimeString()})`)}`));
  console.log(`  registry  ${fmt(snap.layers.registry)}  ${c.dim(
    `${env.HKLM_ROOT_FULL}\\TrackingEnabled = ${snap.detail.registry.present
      ? `${snap.detail.registry.raw} (${snap.detail.registry.type})`
      : 'ABSENT'}`)}`);
  console.log(`  event     ${fmt(snap.layers.event)}  ${c.dim(
    `${env.PAUSE_EVENT} ${snap.detail.event.openable
      ? snap.detail.event.signaled ? '(signaled)' : '(not signaled)'
      : `(${snap.detail.event.error})`}`)}`);
  console.log(`  service   ${fmt(snap.layers.device)}  ${c.dim(
    snap.detail.device.reachable ? 'TrackingManager via pipe' : `unreachable: ${snap.detail.device.error}`)}`);
  console.log(`  ${env.SERVICE_NAME}  ${snap.detail.serviceRunning === null
    ? c.yellow('unknown')
    : snap.detail.serviceRunning ? c.green('RUNNING') : c.red('STOPPED')}`);

  const paint = v.level === 'ok' ? c.green : v.level === 'warn' ? c.yellow : c.red;
  console.log(`\n  ${paint(v.text)}\n`);
  return v.level === 'ok';
}

async function main() {
  if (!WATCH) {
    const ok = await once();
    process.exit(ok ? 0 : 1);
  }
  for (;;) {
    await once();
    await new Promise((r) => { setTimeout(r, 2000); });
  }
}

main().catch((e) => {
  console.error(`fatal: ${e.stack || e.message}`);
  process.exit(1);
});
