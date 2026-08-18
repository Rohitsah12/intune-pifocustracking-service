'use strict';

// Mock backend socket.io server for testing the ADMIN-INITIATED pause path
// (Flow 3 in PAUSE-RESUME-FLOW.md) without touching the real backend.
//
// WindowService normally connects to PF_WS_URL, a compile-time constant.
// A stage build reads an override from the registry first, so:
//
//   1. npm install                          (in tests/pause-resume)
//   2. node mock-socket-server.js
//   3. reg add HKLM\SOFTWARE\PiFocusStage /v TestWsUrl /t REG_SZ /d "ws://127.0.0.1:8899" /f
//   4. sc stop PiFocusWindowServiceStage && sc start PiFocusWindowServiceStage
//   5. watch this server log "agent connected"
//
// Cleanup:
//   reg delete HKLM\SOFTWARE\PiFocusStage /v TestWsUrl /f
//   sc stop PiFocusWindowServiceStage && sc start PiFocusWindowServiceStage
//
// The override is compiled out of production builds (#ifdef PIFOCUS_STAGING),
// so a prod binary cannot be redirected here even if the registry value exists.

const http = require('http');

let Server;
try {
  ({ Server } = require('socket.io'));
} catch (e) {
  console.error('socket.io is not installed. Run:  npm install    (inside tests/pause-resume)');
  process.exit(1);
}

const PORT = Number(process.env.MOCK_WS_PORT || 8899);
const NAMESPACE = '/pi-focus/agent'; // must match PF_SOCKETIO_NS in Env.h

const httpServer = http.createServer((req, res) => {
  // Tiny control API so the test runner can drive toggles without a socket client.
  //   POST /emit/pause    -> emit agent_tracking_toggle {enabled:false}
  //   POST /emit/resume   -> emit agent_tracking_toggle {enabled:true}
  //   POST /emit/raw      -> body is the literal payload object to send
  //   GET  /status        -> connected agents + last emit
  const url = new URL(req.url, `http://${req.headers.host}`);

  const json = (code, obj) => {
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(obj));
  };

  if (url.pathname === '/status') {
    return json(200, {
      connectedAgents: agents.size,
      agents: [...agents].map((s) => ({ id: s.id, query: s.handshake.query })),
      lastEmit,
      received: receivedEvents.slice(-50),
    });
  }

  if (url.pathname.startsWith('/emit/')) {
    const what = url.pathname.split('/')[2];

    const send = (payload) => {
      const envelope = {
        from: 'USER',
        type: 'agent_tracking_toggle',
        senderId: 'mock-admin',
        payload,
      };
      ns.emit('command', envelope);
      lastEmit = { at: new Date().toISOString(), envelope };
      console.log(`[mock] emitted agent_tracking_toggle ${JSON.stringify(payload)} to ${agents.size} agent(s)`);
      return json(200, { ok: true, sentTo: agents.size, envelope });
    };

    if (what === 'pause') return send({ enabled: false });
    if (what === 'resume') return send({ enabled: true });

    if (what === 'raw') {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        try {
          send(JSON.parse(body || '{}'));
        } catch (e) {
          json(400, { ok: false, error: 'bad json' });
        }
      });
      return undefined;
    }
    return json(404, { ok: false, error: 'unknown emit target' });
  }

  return json(404, { ok: false });
});

const io = new Server(httpServer, {
  path: '/ws/',           // matches the path the C++ client uses
  cors: { origin: '*' },
  allowEIO3: true,        // the C++ socket.io client speaks Engine.IO 3/4
});

const ns = io.of(NAMESPACE);
const agents = new Set();
let lastEmit = null;
const receivedEvents = [];

ns.on('connection', (socket) => {
  agents.add(socket);
  console.log(`[mock] agent connected  id=${socket.id}  query=${JSON.stringify(socket.handshake.query)}`);

  socket.onAny((event, ...args) => {
    const entry = { at: new Date().toISOString(), event, args };
    receivedEvents.push(entry);
    if (receivedEvents.length > 500) receivedEvents.shift();
    if (event !== 'agent:heartbeat') {
      console.log(`[mock] <- ${event} ${JSON.stringify(args).slice(0, 300)}`);
    }
  });

  socket.on('disconnect', (reason) => {
    agents.delete(socket);
    console.log(`[mock] agent disconnected id=${socket.id} reason=${reason}`);
  });
});

io.on('connection', (socket) => {
  console.log(`[mock] ROOT namespace connection id=${socket.id} (agent should join ${NAMESPACE})`);
});

httpServer.listen(PORT, '127.0.0.1', () => {
  console.log(`[mock] socket.io listening on ws://127.0.0.1:${PORT}  path=/ws/  ns=${NAMESPACE}`);
  console.log('[mock] control API:');
  console.log(`[mock]   curl -X POST http://127.0.0.1:${PORT}/emit/pause`);
  console.log(`[mock]   curl -X POST http://127.0.0.1:${PORT}/emit/resume`);
  console.log(`[mock]   curl http://127.0.0.1:${PORT}/status`);
  console.log('[mock] point the STAGE service here:');
  console.log(`[mock]   reg add HKLM\\SOFTWARE\\PiFocusStage /v TestWsUrl /t REG_SZ /d "ws://127.0.0.1:${PORT}" /f`);
});

module.exports = { io, ns, agents };
