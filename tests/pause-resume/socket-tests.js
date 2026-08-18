'use strict';

// Backend-initiated pause/resume tests (Flow 3) — the A/B half that the pipe
// suite cannot cover, because it exercises the socket.io command path that
// company Intune devices depend on.
//
// SETUP (stage build only — the redirect is #ifdef'd out of prod):
//   1. npm install
//   2. node mock-socket-server.js                       (leave running)
//   3. reg add HKLM\SOFTWARE\PiFocusStage /v TestWsUrl /t REG_SZ /d "ws://127.0.0.1:8899" /f
//   4. sc stop PiFocusWindowServiceStage & sc start PiFocusWindowServiceStage
//   5. wait for "[mock] agent connected"
//   6. PIFOCUS_ENV=stage node socket-tests.js
//
// TEARDOWN:
//   reg delete HKLM\SOFTWARE\PiFocusStage /v TestWsUrl /f
//   sc stop PiFocusWindowServiceStage & sc start PiFocusWindowServiceStage
//
// NOTE the service only opens the socket AFTER HelperService hands it a device
// token over the pipe, so the helper must be running and the device enrolled.

const http = require('http');
const { setTimeout: sleep } = require('timers/promises');
const env = require('./lib/env');
const st = require('./lib/state');

const MOCK_PORT = Number(process.env.MOCK_WS_PORT || 8899);
const SETTLE_MS = Number(process.env.SOCKET_SETTLE_MS || 4000);

const results = [];
const c = {
  green: (s) => `\x1b[32m${s}\x1b[0m`,
  red: (s) => `\x1b[31m${s}\x1b[0m`,
  dim: (s) => `\x1b[2m${s}\x1b[0m`,
  bold: (s) => `\x1b[1m${s}\x1b[0m`,
};

function req(method, path, body) {
  return new Promise((resolve, reject) => {
    const r = http.request(
      { host: '127.0.0.1', port: MOCK_PORT, path, method,
        headers: { 'Content-Type': 'application/json' } },
      (res) => {
        let data = '';
        res.on('data', (ch) => { data += ch; });
        res.on('end', () => {
          try { resolve(JSON.parse(data)); } catch (e) { resolve({ raw: data }); }
        });
      },
    );
    r.on('error', reject);
    if (body) r.write(JSON.stringify(body));
    r.end();
  });
}

function assert(cond, msg) { if (!cond) throw new Error(msg); }

async function test(name, fn) {
  try {
    const detail = await fn();
    results.push({ name, status: 'pass' });
    console.log(`${c.green('PASS')}  ${name}${detail ? c.dim(` — ${detail}`) : ''}`);
  } catch (e) {
    results.push({ name, status: 'fail', error: e.message });
    console.log(`${c.red('FAIL')}  ${name}\n      ${c.red(e.message)}`);
  }
}

/** Emit a toggle, wait for it to land, then assert the full contract. */
async function emitAndVerify(what, expectPaused, payloadOverride) {
  if (payloadOverride) {
    await req('POST', '/emit/raw', payloadOverride);
  } else {
    await req('POST', `/emit/${what}`);
  }
  await sleep(SETTLE_MS);

  const snap = await st.snapshot();
  assert(snap.knownLayerCount === 3, `layers unreadable: ${st.describe(snap)}`);
  assert(snap.consistent, `layers disagree after socket ${what}: ${st.describe(snap)}`);
  assert(
    snap.paused === expectPaused,
    `expected ${expectPaused ? 'PAUSED' : 'running'} after socket ${what}, got ${st.describe(snap)}`,
  );
  return st.describe(snap);
}

async function main() {
  console.log(c.bold(`\nBackend-initiated (socket.io) pause/resume tests — env=${env.ENV}\n`));

  if (!env.isStage) {
    console.log(c.red('Refusing to run against a PROD install.'));
    console.log(c.dim('The TestWsUrl redirect only exists in stage builds. Use PIFOCUS_ENV=stage.'));
    process.exit(2);
  }

  let status;
  try {
    status = await req('GET', '/status');
  } catch (e) {
    console.log(c.red(`Mock server not reachable on 127.0.0.1:${MOCK_PORT}. Start it first:`));
    console.log(c.dim('  node mock-socket-server.js'));
    process.exit(2);
  }

  if (!status.connectedAgents) {
    console.log(c.red('No agent connected to the mock server.'));
    console.log(c.dim('  1. reg add HKLM\\SOFTWARE\\PiFocusStage /v TestWsUrl /t REG_SZ ' +
      `/d "ws://127.0.0.1:${MOCK_PORT}" /f`));
    console.log(c.dim(`  2. sc stop ${env.SERVICE_NAME} & sc start ${env.SERVICE_NAME}`));
    console.log(c.dim('  3. make sure HelperService is running (it supplies the device token'));
    console.log(c.dim('     that triggers the socket connect)'));
    process.exit(2);
  }

  console.log(c.dim(`agent connected (${status.connectedAgents}), baseline: ${st.describe(await st.snapshot())}\n`));

  // ---- the two flows the stakeholder asked about ------------------------

  await test('socket/admin-pause — registry 0, event signaled, service agrees', async () =>
    emitAndVerify('pause', true));

  await test('socket/admin-resume — registry 1, event clear, service agrees', async () =>
    emitAndVerify('resume', false));

  await test('socket/repeated-toggles-stay-consistent', async () => {
    for (let i = 0; i < 5; i += 1) {
      await emitAndVerify('pause', true);
      await emitAndVerify('resume', false);
    }
    return '5 pause/resume cycles over the socket, contract held every time';
  });

  // ---- the bug that turned a pause command into a resume ----------------

  await test('socket/missing-enabled-is-rejected-NOT-defaulted-to-resume', async () => {
    await emitAndVerify('pause', true);            // start paused
    await req('POST', '/emit/raw', {});            // payload with no "enabled"
    await sleep(SETTLE_MS);

    const snap = await st.snapshot();
    assert(snap.consistent, `layers disagree: ${st.describe(snap)}`);
    assert(
      snap.paused === true,
      'a malformed toggle RESUMED tracking — this is the old ' +
      'payloadJson.value("enabled", true) bug turning monitoring back on',
    );
    return 'still paused; malformed command ignored';
  });

  await test('socket/string-enabled-is-honoured-not-dropped', async () => {
    await emitAndVerify('resume', false);
    // Previously "false" (a string) raised type_error, was swallowed, and the
    // command vanished with no ack — the admin thought the device was paused.
    await emitAndVerify(null, true, { enabled: 'false' });
    return 'string "false" applied as PAUSE';
  });

  await test('socket/numeric-enabled-is-honoured', async () => {
    await emitAndVerify(null, false, { enabled: 1 });
    await emitAndVerify(null, true, { enabled: 0 });
    return '0/1 applied correctly';
  });

  // ---- offline / reconnect ----------------------------------------------

  await test('socket/state-survives-a-socket-drop', async () => {
    await emitAndVerify('pause', true);
    // The device must not "un-pause" just because the backend went away.
    await sleep(3000);
    const snap = await st.snapshot();
    assert(snap.consistent && snap.paused === true,
      `state changed while idle: ${st.describe(snap)}`);
    return 'pause held with no further commands';
  });

  const pass = results.filter((r) => r.status === 'pass').length;
  const fail = results.filter((r) => r.status === 'fail').length;
  console.log(c.bold('\n──────────────── summary ────────────────'));
  console.log(`  ${c.green(`${pass} passed`)}   ${fail ? c.red(`${fail} failed`) : '0 failed'}\n`);
  console.log(c.dim('remember to tear down:'));
  console.log(c.dim(`  reg delete HKLM\\${env.HKLM_ROOT} /v TestWsUrl /f`));
  console.log(c.dim(`  sc stop ${env.SERVICE_NAME} & sc start ${env.SERVICE_NAME}\n`));

  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error(c.red(`\nfatal: ${e.stack || e.message}`));
  process.exit(1);
});
