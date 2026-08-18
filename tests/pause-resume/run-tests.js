'use strict';

// Pause/Resume conformance + load + soak suite.
//
//   node run-tests.js                       run everything safe by default
//   PIFOCUS_ENV=stage node run-tests.js     against a stage install
//   node run-tests.js --only=load,concurrency
//   node run-tests.js --include-destructive  also run service-restart tests
//   node run-tests.js --load-iterations=500
//
// Every test asserts THE CONTRACT: registry, pause event and the service's own
// view must all agree, and must match what we asked for. See PAUSE-RESUME-FLOW.md.

const { setTimeout: sleep } = require('timers/promises');
const env = require('./lib/env');
const pipe = require('./lib/pipe');
const st = require('./lib/state');

const argv = process.argv.slice(2);
const argVal = (name, dflt) => {
  const hit = argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.split('=').slice(1).join('=') : dflt;
};
const hasFlag = (name) => argv.includes(`--${name}`);

const ONLY = argVal('only', '').split(',').filter(Boolean);
// Testing a WindowService.exe launched directly from a console rather than as
// an installed service. Skips the sc-query preflight and the tests that need
// a real service (restart persistence, helper watchdog).
const CONSOLE_MODE = hasFlag('console-mode');
const INCLUDE_DESTRUCTIVE = hasFlag('include-destructive') && !CONSOLE_MODE;
const LOAD_ITERATIONS = Number(argVal('load-iterations', 200));
const CONCURRENCY = Number(argVal('concurrency', 8));
const SOAK_SECONDS = Number(argVal('soak-seconds', 0));

const results = [];
let originalState = null;

const c = {
  green: (s) => `\x1b[32m${s}\x1b[0m`,
  red: (s) => `\x1b[31m${s}\x1b[0m`,
  yellow: (s) => `\x1b[33m${s}\x1b[0m`,
  dim: (s) => `\x1b[2m${s}\x1b[0m`,
  bold: (s) => `\x1b[1m${s}\x1b[0m`,
};

function log(...a) { console.log(...a); }

async function test(name, fn, opts = {}) {
  if (ONLY.length && !ONLY.some((o) => name.includes(o))) return;
  if (opts.destructive && !INCLUDE_DESTRUCTIVE) {
    results.push({ name, status: 'skipped', reason: 'destructive (pass --include-destructive)' });
    log(`${c.yellow('SKIP')}  ${name} ${c.dim('(destructive)')}`);
    return;
  }

  const started = Date.now();
  try {
    const detail = await fn();
    const ms = Date.now() - started;
    results.push({ name, status: 'pass', ms, detail });
    log(`${c.green('PASS')}  ${name} ${c.dim(`${ms}ms`)}${detail ? c.dim(` — ${detail}`) : ''}`);
  } catch (e) {
    const ms = Date.now() - started;
    results.push({ name, status: 'fail', ms, error: e.message });
    log(`${c.red('FAIL')}  ${name} ${c.dim(`${ms}ms`)}\n      ${c.red(e.message)}`);
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

/**
 * The central assertion. Applies the contract from PAUSE-RESUME-FLOW.md §2.
 *
 * Note it requires ALL THREE layers to be readable. A test that "passes"
 * because the registry was unreadable is worse than useless, so unknown
 * layers are a failure here, not a shrug.
 */
async function assertContract(expectPaused, context) {
  const snap = await st.snapshot();
  const where = context ? ` [${context}]` : '';

  assert(
    snap.knownLayerCount === 3,
    `not all layers readable${where}: ${st.describe(snap)}`,
  );
  assert(
    snap.consistent,
    `layers disagree${where}: ${st.describe(snap)}`,
  );
  assert(
    snap.paused === expectPaused,
    `expected ${expectPaused ? 'PAUSED' : 'running'} but got ${snap.paused ? 'PAUSED' : 'running'}${where}: ${st.describe(snap)}`,
  );
  return snap;
}

/** Applies a state and waits for it to settle across all layers. */
async function setAndVerify(enabled, context) {
  const res = await pipe.setTrackingEnabled(enabled);
  assert(res.ok, `pipe SET_TRACKING_ENABLED(${enabled}) failed: ${res.error || 'no response'}`);
  assert(res.data.ok === true, `service rejected SET_TRACKING_ENABLED(${enabled}): ${res.data.error}`);
  return assertContract(!enabled, context);
}

// ───────────────────────────── preflight ─────────────────────────────

async function preflight() {
  log(c.bold(`\nPiFocus pause/resume suite — env=${env.ENV}`));
  log(c.dim(`  pipe     ${env.PIPE_NAME}`));
  log(c.dim(`  event    ${env.PAUSE_EVENT}`));
  log(c.dim(`  registry ${env.HKLM_ROOT_FULL}\\TrackingEnabled`));
  log(c.dim(`  service  ${env.SERVICE_NAME}\n`));

  const running = await st.readServiceRunning();
  if (running === false && !CONSOLE_MODE) {
    log(c.red(`${env.SERVICE_NAME} is not RUNNING. Start it and re-run.`));
    log(c.dim('  (pass --console-mode if you are testing a WindowService.exe run'));
    log(c.dim('   directly from a console instead of as an installed service)'));
    process.exit(2);
  }
  if (CONSOLE_MODE) {
    log(c.yellow('  console mode: service-restart and watchdog tests are unavailable\n'));
  }

  const dev = await st.readDevice();
  if (!dev.reachable) {
    if (dev.unsupported) {
      log(c.red('The installed WindowService does not support the tracking pipe commands.'));
      log(c.red('This build predates the fix — deploy the new service first.'));
      log(c.dim(`  (${dev.error})`));
    } else {
      log(c.red(`Cannot reach WindowService over the pipe: ${dev.error}`));
    }
    process.exit(2);
  }

  originalState = await st.snapshot();
  log(c.dim(`baseline: ${st.describe(originalState)}\n`));
}

async function restoreOriginal() {
  if (!originalState || originalState.paused === null) return;
  try {
    await pipe.setTrackingEnabled(!originalState.paused);
    log(c.dim(`\nrestored original state: ${originalState.paused ? 'PAUSED' : 'running'}`));
  } catch (e) { /* best effort */ }
}

// ───────────────────────────── the suite ─────────────────────────────

async function main() {
  await preflight();

  // ---- 1. Basic contract ------------------------------------------------

  await test('contract/pause — registry, event and service all agree on PAUSED', async () => {
    const snap = await setAndVerify(false, 'after pause');
    return st.describe(snap);
  });

  await test('contract/resume — registry, event and service all agree on running', async () => {
    const snap = await setAndVerify(true, 'after resume');
    return st.describe(snap);
  });

  await test('contract/registry-is-REG_DWORD', async () => {
    await pipe.setTrackingEnabled(false);
    const reg = await st.readRegistry();
    assert(reg.present, 'TrackingEnabled missing from the registry after a pause');
    assert(reg.type === 'REG_DWORD', `wrong type ${reg.type} (a REG_SZ "0" reads back as ENABLED)`);
    return `type=${reg.type} raw=${reg.raw}`;
  });

  // This is the headline regression. Before the fix the registry was NEVER
  // written by an app-initiated toggle, so it sat stale and the next service
  // start silently reverted the user.
  await test('regression/registry-actually-changes-on-every-toggle', async () => {
    await pipe.setTrackingEnabled(true);
    const before = await st.readRegistry();
    await pipe.setTrackingEnabled(false);
    const after = await st.readRegistry();
    assert(
      before.enabled === true && after.enabled === false,
      `registry did not follow the toggle: before=${before.raw} after=${after.raw} — ` +
      `this is the exact bug the fix exists to close`,
    );
    return `${before.raw} -> ${after.raw}`;
  });

  // ---- 1b. Pause-start clock (feeds the 30-minute reminder) --------------
  //
  // The reminder counts 30 minutes of WALL-CLOCK time from TrackingChangedAt.
  // Time the machine spends shut down still counts, so this timestamp has to
  // be recorded once when the pause begins and then left alone.

  await test('clock/changedAt-is-stamped-on-pause', async () => {
    await pipe.setTrackingEnabled(true);
    await sleep(1100);
    const before = Math.floor(Date.now() / 1000);
    await pipe.setTrackingEnabled(false);

    const res = await pipe.getTrackingState();
    assert(res.ok, `pipe read failed: ${res.error}`);
    const ca = res.data.changedAt;
    assert(typeof ca === 'number' && ca > 0,
      `changedAt missing from GET_TRACKING_STATE (got ${JSON.stringify(res.data)}) — ` +
      `the reminder has no clock to count from`);
    assert(Math.abs(ca - before) <= 5,
      `changedAt ${ca} is not close to the pause moment ${before}`);
    return `changedAt=${ca} (${new Date(ca * 1000).toLocaleTimeString()})`;
  });

  await test('clock/changedAt-persisted-as-REG_QWORD', async () => {
    await pipe.setTrackingEnabled(false);
    const reg = await st.readRegistry();
    assert(reg.changedAtType === 'REG_QWORD',
      `TrackingChangedAt type is ${reg.changedAtType || 'ABSENT'}, expected REG_QWORD`);
    assert(reg.changedAt > 0, 'TrackingChangedAt is zero in the registry');

    const dev = await st.readDevice();
    assert(dev.changedAt === reg.changedAt,
      `registry (${reg.changedAt}) and service (${dev.changedAt}) disagree on the pause start`);
    return `${reg.hive}/${reg.changedAtType} = ${reg.changedAt}, matches the service`;
  });

  await test('clock/does-not-restart-when-the-same-state-is-re-sent', async () => {
    // An admin re-issuing "pause" on an already-paused device, or the
    // reconciler converging, must NOT restart the 30-minute clock.
    await pipe.setTrackingEnabled(false);
    const first = (await pipe.getTrackingState()).data.changedAt;
    await sleep(2500);
    await pipe.setTrackingEnabled(false);
    const second = (await pipe.getTrackingState()).data.changedAt;
    assert(first === second,
      `clock restarted on a redundant pause (${first} -> ${second}); a user who got ` +
      `re-paused every sync would never reach 30 minutes`);
    return `unchanged across a redundant pause (${first})`;
  });

  await test('clock/restarts-on-a-genuine-new-pause-episode', async () => {
    await pipe.setTrackingEnabled(false);
    const first = (await pipe.getTrackingState()).data.changedAt;
    await sleep(2500);
    await pipe.setTrackingEnabled(true);   // resume
    await pipe.setTrackingEnabled(false);  // pause again — new episode
    const second = (await pipe.getTrackingState()).data.changedAt;
    assert(second > first,
      `clock did not restart after resume+re-pause (${first} -> ${second}); the user ` +
      `would carry credit from the previous pause`);
    return `${first} -> ${second} (new episode)`;
  });

  // ---- 2. Malformed input ----------------------------------------------
  //
  // The old socket handler defaulted a missing "enabled" to TRUE, so a
  // malformed PAUSE command turned monitoring ON. These prove the command is
  // now rejected rather than defaulted.

  await test('malformed/missing-enabled-is-rejected-not-defaulted', async () => {
    await setAndVerify(false, 'setup');
    const res = await pipe.sendCommand({ type: 'SET_TRACKING_ENABLED' });
    assert(res.ok, `expected a response frame, got: ${res.error}`);
    assert(res.data.ok === false, 'service ACCEPTED a command with no "enabled" field');
    await assertContract(true, 'state must be untouched by a rejected command');
    return `rejected: ${res.data.error}`;
  });

  await test('malformed/garbage-enabled-is-rejected', async () => {
    await setAndVerify(false, 'setup');
    const res = await pipe.sendCommand({ type: 'SET_TRACKING_ENABLED', enabled: { nested: 1 } });
    assert(res.ok, `expected a response frame, got: ${res.error}`);
    assert(res.data.ok === false, 'service ACCEPTED an object as "enabled"');
    await assertContract(true, 'state must be untouched');
    return `rejected: ${res.data.error}`;
  });

  await test('malformed/always-answers-never-hangs', async () => {
    // An empty return from the dispatch handler makes PipeServer skip the
    // response frame, hanging the client until disconnect. Every branch must
    // answer.
    const cases = [
      { type: 'SET_TRACKING_ENABLED' },
      { type: 'SET_TRACKING_ENABLED', enabled: 'nonsense' },
      { type: 'SET_TRACKING_ENABLED', enabled: null },
    ];
    for (const req of cases) {
      const res = await pipe.sendCommand(req, 4000);
      assert(res.ok, `no response frame for ${JSON.stringify(req)} — client would hang: ${res.error}`);
    }
    return `${cases.length} malformed variants all answered`;
  });

  await test('malformed/tolerant-bool-forms-accepted', async () => {
    for (const [form, expectPaused] of [[0, true], [1, false], ['false', true], ['true', false]]) {
      const res = await pipe.sendCommand({ type: 'SET_TRACKING_ENABLED', enabled: form });
      assert(res.ok && res.data.ok === true,
        `form ${JSON.stringify(form)} rejected: ${res.data && res.data.error}`);
      await assertContract(expectPaused, `enabled=${JSON.stringify(form)}`);
    }
    return 'accepts bool, 0/1 and "true"/"false"';
  });

  await test('malformed/unparseable-frame-does-not-change-state', async () => {
    await setAndVerify(false, 'setup');
    await pipe.sendRaw('{this is not json', 4000);
    await pipe.sendRaw('', 2000).catch(() => {});
    await assertContract(true, 'after garbage frames');
    return 'state survived unparseable frames';
  });

  // ---- 3. WaitOne(0) must not consume the signal ------------------------

  await test('waitone-nondestructive — polling the event does not resume tracking', async () => {
    await setAndVerify(false, 'setup');
    for (let i = 0; i < 25; i += 1) {
      const ev = await st.readEvent();
      assert(ev.openable, `event unreadable on poll ${i}: ${ev.error}`);
      assert(ev.signaled === true,
        `event stopped being signaled after ${i} polls — WaitOne(0) is CONSUMING it, ` +
        `which would silently resume a paused device`);
    }
    await assertContract(true, 'after 25 polls');
    return '25 consecutive polls, still signaled';
  });

  // ---- 4. Load ----------------------------------------------------------

  await test(`load/${LOAD_ITERATIONS}-sequential-toggles`, async () => {
    let mismatches = 0;
    let slowest = 0;
    const started = Date.now();

    for (let i = 0; i < LOAD_ITERATIONS; i += 1) {
      const enabled = i % 2 === 0;
      const t0 = Date.now();
      const res = await pipe.setTrackingEnabled(enabled);
      const dt = Date.now() - t0;
      if (dt > slowest) slowest = dt;

      assert(res.ok, `iteration ${i}: pipe failed: ${res.error}`);
      assert(res.data.ok === true, `iteration ${i}: rejected: ${res.data.error}`);
      assert(res.data.enabled === enabled,
        `iteration ${i}: service echoed enabled=${res.data.enabled}, expected ${enabled}`);

      // Full three-layer check every 10th to keep runtime sane; the echo above
      // covers every single iteration.
      if (i % 10 === 0) {
        const snap = await st.snapshot();
        if (!snap.consistent || snap.paused !== !enabled) mismatches += 1;
      }
    }

    const total = Date.now() - started;
    assert(mismatches === 0, `${mismatches} consistency mismatches during load`);
    await assertContract(true, 'final state after load');
    return `${LOAD_ITERATIONS} toggles in ${total}ms (avg ${(total / LOAD_ITERATIONS).toFixed(1)}ms, max ${slowest}ms), 0 mismatches`;
  });

  // ---- 5. Concurrency ---------------------------------------------------
  //
  // The reason TrackingManager got a mutex + atomic. The pipe server
  // serializes, but setTrackingEnabled is also reachable from the socket.io
  // thread, so the event write and the registry write must not interleave.

  await test(`concurrency/${CONCURRENCY}-simultaneous-clients`, async () => {
    for (let round = 0; round < 10; round += 1) {
      const target = round % 2 === 0;
      // Everyone asks for the SAME state: the end state is unambiguous, so any
      // inconsistency is a real interleaving bug rather than a race we created.
      const all = await Promise.all(
        Array.from({ length: CONCURRENCY }, () => pipe.setTrackingEnabled(target)),
      );
      const failed = all.filter((r) => !r.ok);
      assert(failed.length === 0,
        `round ${round}: ${failed.length}/${CONCURRENCY} concurrent calls failed: ${failed[0] && failed[0].error}`);
      await assertContract(!target, `after ${CONCURRENCY} concurrent calls, round ${round}`);
    }
    return `${CONCURRENCY} clients x 10 rounds, contract held every round`;
  });

  await test('concurrency/interleaved-opposite-commands-still-consistent', async () => {
    // Deliberately ambiguous: half pause, half resume, fired together. We do
    // NOT assert which side wins — only that the three layers never end up
    // disagreeing with each other, which is the actual invariant.
    for (let round = 0; round < 8; round += 1) {
      await Promise.all(
        Array.from({ length: CONCURRENCY }, (_, i) => pipe.setTrackingEnabled(i % 2 === 0)),
      );
      const snap = await st.snapshot();
      assert(snap.knownLayerCount === 3, `round ${round}: layers unreadable: ${st.describe(snap)}`);
      assert(snap.consistent,
        `round ${round}: TORN STATE after interleaved commands: ${st.describe(snap)}`);
    }
    return `${CONCURRENCY} opposing clients x 8 rounds, never torn`;
  });

  // ---- 6. Reads under write pressure ------------------------------------

  await test('concurrency/reads-during-writes-never-see-torn-state', async () => {
    let torn = 0;
    let reads = 0;
    let stop = false;

    const writer = (async () => {
      for (let i = 0; i < 60 && !stop; i += 1) {
        await pipe.setTrackingEnabled(i % 2 === 0);
      }
      stop = true;
    })();

    const reader = (async () => {
      while (!stop) {
        const res = await pipe.getTrackingState();
        if (res.ok) {
          reads += 1;
          if (typeof res.data.enabled !== 'boolean') torn += 1;
        }
      }
    })();

    await Promise.all([writer, reader]);
    assert(torn === 0, `${torn}/${reads} reads returned a non-boolean state`);
    return `${reads} concurrent reads during 60 writes, 0 torn`;
  });

  // ---- 7. Helper watchdog must survive Electron pipe traffic -------------

  await test('watchdog/electron-traffic-does-not-fake-helper-liveness', async () => {
    // PipeServer invokes onDataReceived for EVERY frame. If the tracking
    // commands were not excluded, hammering the pipe from the app would keep
    // refreshing the helper heartbeat and a dead helper would never be
    // restarted. We cannot read the internal timer, so this asserts the
    // observable proxy: the commands are answered and never logged as helper
    // heartbeats. Full proof is the destructive test below.
    const before = Date.now();
    for (let i = 0; i < 40; i += 1) {
      const res = await pipe.getTrackingState();
      assert(res.ok, `GET_TRACKING_STATE ${i} failed: ${res.error}`);
    }
    return `40 rapid state reads in ${Date.now() - before}ms (see watchdog/helper-restart for the full check)`;
  });

  await test('watchdog/helper-restart — dead helper is still detected while the pipe is busy', async () => {
    const { run } = st;
    await run('taskkill.exe', ['/F', '/IM', 'HelperService.exe', '/T']);
    log(c.dim('      killed HelperService, hammering the pipe for 45s while the watchdog should notice...'));

    const deadline = Date.now() + 45000;
    while (Date.now() < deadline) {
      await pipe.getTrackingState();
      await sleep(200);
    }

    const { stdout } = await run('tasklist.exe', ['/FI', 'IMAGENAME eq HelperService.exe']);
    const alive = /HelperService\.exe/i.test(stdout);
    assert(alive,
      'HelperService was NOT restarted within 45s while the pipe was busy — ' +
      'Electron traffic is masking the heartbeat and suppressing the watchdog');
    return 'helper restarted despite continuous pipe traffic';
  }, { destructive: true });

  // ---- 8. Persistence across a service restart --------------------------

  await test('persistence/pause-survives-a-service-restart', async () => {
    const { run } = st;
    await setAndVerify(false, 'before restart');

    await run('sc.exe', ['stop', env.SERVICE_NAME], 60000);
    await sleep(4000);
    await run('sc.exe', ['start', env.SERVICE_NAME], 60000);
    await sleep(8000);

    await assertContract(true,
      'after a service restart — a stale registry here is the silent-resume bug');
    return 'still paused after stop/start';
  }, { destructive: true });

  await test('persistence/pause-CLOCK-survives-a-service-restart', async () => {
    // THE test for the 30-minute reminder.
    //
    // The reminder counts wall-clock time from TrackingChangedAt. If a service
    // start re-stamped that timestamp, every reboot would reset the clock to
    // zero and the reminder would NEVER fire for anyone who restarts their
    // laptop — which is precisely the stakeholder's scenario (pause, shut down,
    // come back, expect the popup on schedule).
    const { run } = st;
    await setAndVerify(false, 'before restart');
    const before = (await pipe.getTrackingState()).data.changedAt;
    assert(before > 0, 'no changedAt to compare');

    await sleep(2500);
    await run('sc.exe', ['stop', env.SERVICE_NAME], 60000);
    await sleep(4000);
    await run('sc.exe', ['start', env.SERVICE_NAME], 60000);
    await sleep(8000);

    const after = (await pipe.getTrackingState()).data.changedAt;
    assert(after === before,
      `pause clock RESTARTED across the service restart (${before} -> ${after}). ` +
      `The 30-minute reminder would never fire for a user who reboots.`);

    const elapsed = Math.floor(Date.now() / 1000) - after;
    assert(elapsed >= 10,
      `elapsed reads ${elapsed}s but the pause began well before the restart — ` +
      `the clock is not accumulating across the restart`);

    // Registry is the thing that actually survives a power cycle.
    const reg = await st.readRegistry();
    assert(reg.changedAt === before,
      `registry changedAt (${reg.changedAt}) no longer matches (${before})`);

    return `preserved (${before}); elapsed now ${elapsed}s across the restart`;
  }, { destructive: true });

  await test('persistence/resume-survives-a-service-restart', async () => {
    const { run } = st;
    await setAndVerify(true, 'before restart');

    await run('sc.exe', ['stop', env.SERVICE_NAME], 60000);
    await sleep(4000);
    await run('sc.exe', ['start', env.SERVICE_NAME], 60000);
    await sleep(8000);

    await assertContract(false, 'after a service restart');
    return 'still running after stop/start';
  }, { destructive: true });

  // ---- 9. Optional soak -------------------------------------------------

  if (SOAK_SECONDS > 0) {
    await test(`soak/${SOAK_SECONDS}s-continuous`, async () => {
      const deadline = Date.now() + SOAK_SECONDS * 1000;
      let ops = 0;
      let mismatches = 0;
      let i = 0;
      while (Date.now() < deadline) {
        const enabled = i % 2 === 0;
        const res = await pipe.setTrackingEnabled(enabled);
        ops += 1;
        if (!res.ok || res.data.ok !== true || res.data.enabled !== enabled) mismatches += 1;
        if (i % 25 === 0) {
          const snap = await st.snapshot();
          if (!snap.consistent) mismatches += 1;
        }
        i += 1;
      }
      assert(mismatches === 0, `${mismatches} failures across ${ops} operations`);
      return `${ops} operations over ${SOAK_SECONDS}s, 0 failures`;
    });
  }

  await restoreOriginal();

  // ───────────────────────────── summary ─────────────────────────────

  const pass = results.filter((r) => r.status === 'pass').length;
  const fail = results.filter((r) => r.status === 'fail').length;
  const skip = results.filter((r) => r.status === 'skipped').length;

  log(c.bold('\n──────────────── summary ────────────────'));
  log(`  ${c.green(`${pass} passed`)}   ${fail ? c.red(`${fail} failed`) : '0 failed'}   ${c.yellow(`${skip} skipped`)}`);
  if (fail) {
    log(c.red('\nfailures:'));
    results.filter((r) => r.status === 'fail').forEach((r) => log(`  - ${r.name}\n      ${r.error}`));
  }
  if (skip && !INCLUDE_DESTRUCTIVE) {
    log(c.dim('\n  destructive tests skipped — rerun with --include-destructive to cover'));
    log(c.dim('  service restarts and the helper watchdog.'));
  }
  log('');

  process.exit(fail ? 1 : 0);
}

main().catch(async (e) => {
  console.error(c.red(`\nfatal: ${e.stack || e.message}`));
  await restoreOriginal();
  process.exit(1);
});
