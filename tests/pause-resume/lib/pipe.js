'use strict';

// Named-pipe client for WindowService's IPC server.
//
// Wire format is fixed by WindowService/PipeServer.cpp:82-95:
//   uint32 little-endian byte count, then exactly that many bytes of JSON.
// One request/response per connection; the server disconnects after replying.
//
// This is a deliberate second implementation of the same protocol the Electron
// app uses (src/main/trackingPipe.ts). Keeping the test driver independent of
// the app means a bug in the app's client cannot make these tests pass.

const net = require('net');
const { PIPE_NAME } = require('./env');

const DEFAULT_TIMEOUT_MS = 5000;
const MAX_FRAME_BYTES = 1024 * 1024;

/**
 * Write a frame as TWO separate writes: the 4-byte header, then the body.
 *
 * This is load-bearing, not style. The server creates the pipe with
 * PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE, so every WriteFile becomes its
 * own discrete message. Its ReadFrame does ReadExact(&len, 4) followed by
 * ReadExact(body, len) — two reads expecting two messages. Send header+body
 * as ONE concatenated write and the server's 4-byte read hits
 * ERROR_MORE_DATA, ReadExact returns false, and the connection is dropped
 * with "Failed to read request frame" — which surfaces to the client as EPIPE.
 *
 * The C++ PipeClient/PipeServer WriteFrame does the same two-write split.
 */
function writeFrame(socket, payload) {
  const body = Buffer.from(payload, 'utf-8');
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  socket.write(header, () => socket.write(body));
}

/**
 * Send one command and await the response.
 *
 * Resolves { ok:true, data } on a parsed reply, or
 * { ok:false, unsupported, error } otherwise.
 *
 * `unsupported: true` means the service connected but never sent a response
 * frame — the signature of a build that predates the tracking commands, since
 * PipeServer skips the frame when the dispatch handler returns "".
 */
function sendCommandOnce(request, timeoutMs = DEFAULT_TIMEOUT_MS) {
  return new Promise((resolve) => {
    let settled = false;
    let sawAnyData = false;
    let buffer = Buffer.alloc(0);
    let timer = null;

    const socket = new net.Socket();

    const finish = (result) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      try { socket.destroy(); } catch (e) { /* already gone */ }
      resolve(result);
    };

    timer = setTimeout(() => {
      finish({ ok: false, unsupported: !sawAnyData, error: `timeout after ${timeoutMs}ms` });
    }, timeoutMs);

    socket.on('error', (err) => {
      const unsupported = err.code === 'EPIPE' || err.code === 'ECONNRESET';
      finish({ ok: false, unsupported, error: `${err.code || 'ERR'}: ${err.message}` });
    });

    socket.on('close', () => {
      finish({
        ok: false,
        unsupported: !sawAnyData,
        error: sawAnyData
          ? 'closed with an incomplete response frame'
          : 'closed without a response (command not supported by this service build)',
      });
    });

    socket.on('data', (chunk) => {
      sawAnyData = true;
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length < 4) return;

      const len = buffer.readUInt32LE(0);
      if (len === 0 || len > MAX_FRAME_BYTES) {
        finish({ ok: false, unsupported: false, error: `invalid frame length ${len}` });
        return;
      }
      if (buffer.length < 4 + len) return;

      const json = buffer.subarray(4, 4 + len).toString('utf-8');
      try {
        finish({ ok: true, data: JSON.parse(json) });
      } catch (e) {
        finish({ ok: false, unsupported: false, error: `unparseable: ${json.slice(0, 200)}` });
      }
    });

    socket.connect(PIPE_NAME, () => {
      try {
        writeFrame(socket, JSON.stringify(request));
      } catch (e) {
        finish({ ok: false, unsupported: false, error: `write failed: ${e.message}` });
      }
    });
  });
}

/**
 * Send with a short retry on ENOENT.
 *
 * PipeServer serves ONE instance at a time: DisconnectNamedPipe + CloseHandle,
 * then back to CreateNamedPipeW. In between, the pipe name does not exist and
 * a connecting client gets ENOENT. Retrying is the standard named-pipe client
 * contract (what WaitNamedPipe is for). The Electron client does the same.
 *
 * Note this masks a real server limitation rather than fixing it — see the
 * "pipe instance recycling" note in README.md.
 */
async function sendCommand(request, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const MAX_ATTEMPTS = 6;
  const BACKOFF_MS = 50;

  let last = null;
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) {
    const res = await sendCommandOnce(request, timeoutMs);
    if (res.ok) return res;
    last = res;
    if (!String(res.error).startsWith('ENOENT')) return res;
    await new Promise((r) => { setTimeout(r, BACKOFF_MS); });
  }
  return last;
}

/**
 * Send a RAW frame body without JSON-encoding it. Used by the malformed-input
 * tests to prove the service rejects garbage instead of defaulting to
 * "resume tracking".
 */
function sendRaw(rawBody, timeoutMs = DEFAULT_TIMEOUT_MS) {
  return new Promise((resolve) => {
    let settled = false;
    let sawAnyData = false;
    let buffer = Buffer.alloc(0);
    const socket = new net.Socket();

    const finish = (r) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { socket.destroy(); } catch (e) {}
      resolve(r);
    };

    const timer = setTimeout(
      () => finish({ ok: false, unsupported: !sawAnyData, error: 'timeout' }),
      timeoutMs,
    );

    socket.on('error', (err) => finish({ ok: false, unsupported: false, error: err.message }));
    socket.on('close', () => finish({ ok: false, unsupported: !sawAnyData, error: 'closed' }));
    socket.on('data', (chunk) => {
      sawAnyData = true;
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length < 4) return;
      const len = buffer.readUInt32LE(0);
      if (buffer.length < 4 + len) return;
      const json = buffer.subarray(4, 4 + len).toString('utf-8');
      try { finish({ ok: true, data: JSON.parse(json) }); }
      catch (e) { finish({ ok: false, unsupported: false, error: 'unparseable' }); }
    });

    socket.connect(PIPE_NAME, () => {
      writeFrame(socket, rawBody);
    });
  });
}

const setTrackingEnabled = (enabled) => sendCommand({ type: 'SET_TRACKING_ENABLED', enabled });
const getTrackingState = () => sendCommand({ type: 'GET_TRACKING_STATE' });
const getSerialNumber = () => sendCommand({ type: 'GET_SERIAL_NUMBER' });
const getLockState = () => sendCommand({ type: 'GET_LOCK_STATE' });

module.exports = {
  sendCommand,
  sendRaw,
  setTrackingEnabled,
  getTrackingState,
  getSerialNumber,
  getLockState,
};
