const WebSocket = require('ws');
const { SessionPool } = require('./sessionPool');
const { AudioMatcher } = require('./pythonBridge');
const cryptoUtils = require('./cryptoUtils');

const PORT = process.env.PORT || 8080;
const PYTHON_EXECUTABLE = process.env.PYTHON_EXECUTABLE || 'python3';
const MATCH_THRESHOLD = parseFloat(process.env.MATCH_THRESHOLD) || 0.75;
const SESSION_TIMEOUT = parseInt(process.env.SESSION_TIMEOUT) || 30000;
const AUDIO_TIMEOUT = parseInt(process.env.AUDIO_TIMEOUT) || 15000;

const wss = new WebSocket.Server({ port: PORT });
const sessionPool = new SessionPool({ 
  sessionTimeoutMs: SESSION_TIMEOUT,
  audioTimeoutMs: AUDIO_TIMEOUT
});
const audioMatcher = new AudioMatcher({
  pythonExecutable: PYTHON_EXECUTABLE,
  threshold: MATCH_THRESHOLD
});

const clients = new Map();

console.log('='.repeat(60));
console.log('Audio Pairing Backend Server');
console.log('='.repeat(60));
console.log(`WebSocket Server listening on port ${PORT}`);
console.log(`Python executable: ${PYTHON_EXECUTABLE}`);
console.log(`Match threshold: ${MATCH_THRESHOLD}`);
console.log(`Session timeout: ${SESSION_TIMEOUT}ms`);
console.log(`Audio timeout: ${AUDIO_TIMEOUT}ms`);
console.log('='.repeat(60));

wss.on('connection', (ws, req) => {
  const clientId = cryptoUtils.generateClientId();
  const clientInfo = {
    id: clientId,
    ws,
    platform: null,
    connectedAt: Date.now(),
    sessionId: null,
    encryptionKey: null
  };

  clients.set(clientId, clientInfo);
  
  console.log(`[${new Date().toISOString()}] Client connected: ${clientId}`);

  sendMessage(ws, {
    type: 'connected',
    clientId,
    timestamp: Date.now()
  });

  ws.on('message', async (data) => {
    try {
      const message = JSON.parse(data.toString());
      await handleMessage(clientId, message);
    } catch (error) {
      console.error(`Error parsing message from client ${clientId}:`, error.message);
      sendMessage(ws, {
        type: 'error',
        message: 'Invalid message format'
      });
    }
  });

  ws.on('close', (code, reason) => {
    console.log(`[${new Date().toISOString()}] Client disconnected: ${clientId}, code: ${code}`);
    handleClientDisconnect(clientId);
  });

  ws.on('error', (error) => {
    console.error(`WebSocket error for client ${clientId}:`, error.message);
  });
});

async function handleMessage(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  switch (message.type) {
    case 'register':
      handleRegister(clientId, message);
      break;
    case 'start_pairing':
      handleStartPairing(clientId, message);
      break;
    case 'audio_data':
      handleAudioData(clientId, message);
      break;
    case 'cancel_pairing':
      handleCancelPairing(clientId, message);
      break;
    case 'send_encrypted':
      handleSendEncrypted(clientId, message);
      break;
    case 'heartbeat':
      handleHeartbeat(clientId, message);
      break;
    case 'stats':
      handleStats(clientId, message);
      break;
    default:
      console.log(`Unknown message type from client ${clientId}: ${message.type}`);
      sendMessage(client.ws, {
        type: 'error',
        message: `Unknown message type: ${message.type}`
      });
  }
}

function handleRegister(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  client.platform = message.platform || 'unknown';
  client.deviceInfo = message.deviceInfo || {};

  console.log(`Client ${clientId} registered as ${client.platform}`);

  sendMessage(client.ws, {
    type: 'registered',
    clientId,
    platform: client.platform
  });
}

function handleStartPairing(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  const existingSession = sessionPool.getSessionByClient(clientId);
  if (existingSession) {
    sendMessage(client.ws, {
      type: 'error',
      message: 'Already in a pairing session'
    });
    return;
  }

  let session = sessionPool.findWaitingSession(clientId);

  if (!session) {
    session = sessionPool.createSession(SESSION_TIMEOUT);
    sessionPool.addClientToSession(session.id, clientId, client.ws, client.platform);
    
    console.log(`Client ${clientId} created new session: ${session.id}`);
    
    sendMessage(client.ws, {
      type: 'session_created',
      sessionId: session.id,
      status: 'waiting_for_partner'
    });
  } else {
    sessionPool.addClientToSession(session.id, clientId, client.ws, client.platform);
    
    console.log(`Client ${clientId} joined session: ${session.id}`);
    
    sendMessage(client.ws, {
      type: 'session_joined',
      sessionId: session.id,
      status: 'ready'
    });

    const otherClient = session.getOtherClient(clientId);
    if (otherClient && otherClient.ws.readyState === WebSocket.OPEN) {
      sendMessage(otherClient.ws, {
        type: 'partner_joined',
        sessionId: session.id,
        partnerPlatform: client.platform
      });
    }

    broadcastToSession(session.id, {
      type: 'start_recording',
      sessionId: session.id,
      duration: 3000
    });
  }

  client.sessionId = session.id;
}

async function handleAudioData(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  const session = sessionPool.getSessionByClient(clientId);
  if (!session) {
    sendMessage(client.ws, {
      type: 'error',
      message: 'No active pairing session'
    });
    return;
  }

  const { audioData, sampleRate } = message;
  
  if (!audioData) {
    sendMessage(client.ws, {
      type: 'error',
      message: 'Missing audio data'
    });
    return;
  }

  session.setAudioData(clientId, audioData, sampleRate || 16000);

  console.log(`Received audio data from client ${clientId} in session ${session.id}`);

  sendMessage(client.ws, {
    type: 'audio_received',
    sessionId: session.id
  });

  const otherClient = session.getOtherClient(clientId);
  if (otherClient && otherClient.ws.readyState === WebSocket.OPEN) {
    sendMessage(otherClient.ws, {
      type: 'partner_audio_received',
      sessionId: session.id
    });
  }

  if (session.hasAllAudioData()) {
    await processPairingMatch(session);
  }
}

async function processPairingMatch(session) {
  console.log(`Processing audio match for session ${session.id}...`);

  broadcastToSession(session.id, {
    type: 'matching_started',
    sessionId: session.id
  });

  const [client1, client2] = session.getAudioDataPair();

  try {
    const matchResult = await audioMatcher.match(
      client1.audioData,
      client2.audioData,
      client1.sampleRate || 16000
    );

    console.log(`Match result for session ${session.id}:`, matchResult);

    if (matchResult.success && matchResult.is_match) {
      const aesKey = cryptoUtils.generateAESKey();
      const aesKeyBase64 = cryptoUtils.keyToBase64(aesKey);

      session.setPaired(aesKeyBase64, aesKey);

      const c1 = clients.get(client1.clientId);
      const c2 = clients.get(client2.clientId);
      if (c1) c1.encryptionKey = aesKey;
      if (c2) c2.encryptionKey = aesKey;

      sendMessage(client1.ws, {
        type: 'pairing_success',
        sessionId: session.id,
        aesKey: aesKeyBase64,
        partnerId: client2.clientId,
        partnerPlatform: client2.platform,
        matchScore: matchResult
      });

      sendMessage(client2.ws, {
        type: 'pairing_success',
        sessionId: session.id,
        aesKey: aesKeyBase64,
        partnerId: client1.clientId,
        partnerPlatform: client1.platform,
        matchScore: matchResult
      });

      console.log(`Session ${session.id} paired successfully!`);
    } else {
      session.setFailed(matchResult.error || 'Audio signatures do not match');

      broadcastToSession(session.id, {
        type: 'pairing_failed',
        sessionId: session.id,
        reason: matchResult.error || 'Audio signatures do not match',
        matchScore: matchResult
      });

      console.log(`Session ${session.id} pairing failed: ${matchResult.error || 'No match'}`);
      sessionPool.destroySession(session.id);
    }
  } catch (error) {
    console.error(`Error processing match for session ${session.id}:`, error);
    
    session.setFailed(error.message);
    broadcastToSession(session.id, {
      type: 'pairing_failed',
      sessionId: session.id,
      reason: 'Internal server error during matching'
    });
    
    sessionPool.destroySession(session.id);
  }
}

function handleCancelPairing(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  const session = sessionPool.getSessionByClient(clientId);
  if (!session) {
    sendMessage(client.ws, {
      type: 'error',
      message: 'No active pairing session'
    });
    return;
  }

  const otherClient = session.getOtherClient(clientId);
  if (otherClient && otherClient.ws.readyState === WebSocket.OPEN) {
    sendMessage(otherClient.ws, {
      type: 'pairing_cancelled',
      sessionId: session.id,
      reason: 'Partner cancelled pairing'
    });
  }

  sessionPool.destroySession(session.id);
  client.sessionId = null;

  sendMessage(client.ws, {
    type: 'pairing_cancelled',
    sessionId: session.id
  });

  console.log(`Client ${clientId} cancelled pairing in session ${session.id}`);
}

function handleSendEncrypted(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  const session = sessionPool.getSessionByClient(clientId);
  if (!session || session.status !== 'paired') {
    sendMessage(client.ws, {
      type: 'error',
      message: 'Not in an active paired session'
    });
    return;
  }

  const otherClient = session.getOtherClient(clientId);
  if (!otherClient || otherClient.ws.readyState !== WebSocket.OPEN) {
    sendMessage(client.ws, {
      type: 'error',
      message: 'Partner not connected'
    });
    return;
  }

  sendMessage(otherClient.ws, {
    type: 'encrypted_message',
    fromClientId: clientId,
    sessionId: session.id,
    encryptedData: message.encryptedData,
    timestamp: Date.now()
  });

  sendMessage(client.ws, {
    type: 'message_delivered',
    sessionId: session.id,
    timestamp: Date.now()
  });
}

function handleHeartbeat(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  sendMessage(client.ws, {
    type: 'heartbeat_ack',
    timestamp: Date.now(),
    clientTimestamp: message.timestamp
  });
}

function handleStats(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  const stats = {
    server: sessionPool.getStats(),
    client: {
      id: clientId,
      platform: client.platform,
      connectedMs: Date.now() - client.connectedAt,
      sessionId: client.sessionId
    }
  };

  sendMessage(client.ws, {
    type: 'stats_response',
    stats
  });
}

function handleClientDisconnect(clientId) {
  const client = clients.get(clientId);
  if (!client) return;

  const session = sessionPool.getSessionByClient(clientId);
  if (session) {
    const otherClient = session.getOtherClient(clientId);
    if (otherClient && otherClient.ws.readyState === WebSocket.OPEN) {
      sendMessage(otherClient.ws, {
        type: 'partner_disconnected',
        sessionId: session.id
      });
    }
    
    sessionPool.removeClientFromSession(clientId);
  }

  clients.delete(clientId);
}

function sendMessage(ws, message) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(message));
  }
}

function broadcastToSession(sessionId, message) {
  const session = sessionPool.getSession(sessionId);
  if (!session) return;

  for (const client of session.clients.values()) {
    if (client.ws.readyState === WebSocket.OPEN) {
      client.ws.send(JSON.stringify(message));
    }
  }
}

sessionPool.on('session:created', (data) => {
  console.log(`[Event] Session created: ${data.id}`);
});

sessionPool.on('session:client_joined', (data) => {
  console.log(`[Event] Client ${data.clientId} joined session ${data.sessionId}`);
});

sessionPool.on('session:timeout', (data) => {
  console.log(`[Event] Session ${data.sessionId} timed out`);
  
  const session = sessionPool.getSession(data.sessionId);
  if (session) {
    broadcastToSession(data.sessionId, {
      type: 'session_timeout',
      sessionId: data.sessionId
    });
  }
});

sessionPool.on('session:audio_timeout', (data) => {
  console.log(`[Event] Session ${data.sessionId} audio fingerprint timeout`);
  
  const session = sessionPool.getSession(data.sessionId);
  if (session) {
    broadcastToSession(data.sessionId, {
      type: 'pairing_failed',
      sessionId: data.sessionId,
      reason: 'Audio fingerprint timeout - partner did not submit audio in time'
    });
    
    setTimeout(() => {
      sessionPool.destroySession(data.sessionId);
    }, 1000);
  }
});

sessionPool.on('session:failed', (data) => {
  console.log(`[Event] Session ${data.sessionId} failed: ${data.reason}`);
});

sessionPool.on('session:destroyed', (data) => {
  console.log(`[Event] Session destroyed: ${data.sessionId}`);
});

process.on('SIGINT', () => {
  console.log('\nShutting down server...');
  
  for (const [clientId, client] of clients) {
    if (client.ws.readyState === WebSocket.OPEN) {
      sendMessage(client.ws, {
        type: 'server_shutdown',
        message: 'Server is shutting down'
      });
      client.ws.close();
    }
  }

  sessionPool.shutdown();
  wss.close(() => {
    console.log('Server shutdown complete');
    process.exit(0);
  });

  setTimeout(() => {
    console.log('Forced shutdown');
    process.exit(1);
  }, 5000);
});

wss.on('error', (error) => {
  console.error('WebSocket server error:', error);
});

setInterval(() => {
  const stats = sessionPool.getStats();
  console.log(`[${new Date().toISOString()}] Stats: ` +
    `Sessions: ${stats.totalSessions} ` +
    `(Waiting: ${stats.waitingSessions}, Ready: ${stats.readySessions}, ` +
    `Paired: ${stats.pairedSessions}), Clients: ${stats.connectedClients}`);
}, 30000);
