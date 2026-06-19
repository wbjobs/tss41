const WebSocket = require('ws');
const { SessionPool } = require('./sessionPool');
const { AudioMatcher } = require('./pythonBridge');
const cryptoUtils = require('./cryptoUtils');
const { RoomCodeManager } = require('./roomCodeManager');
const { TrustedDevicesManager } = require('./trustedDevices');

const PORT = process.env.PORT || 8080;
const PYTHON_EXECUTABLE = process.env.PYTHON_EXECUTABLE || 'python3';
const MATCH_THRESHOLD = parseFloat(process.env.MATCH_THRESHOLD) || 0.75;
const SESSION_TIMEOUT = parseInt(process.env.SESSION_TIMEOUT) || 30000;
const AUDIO_TIMEOUT = parseInt(process.env.AUDIO_TIMEOUT) || 15000;
const ROOM_CODE_TTL = parseInt(process.env.ROOM_CODE_TTL) || 5 * 60 * 1000;

const wss = new WebSocket.Server({ port: PORT });
const sessionPool = new SessionPool({ 
  sessionTimeoutMs: SESSION_TIMEOUT,
  audioTimeoutMs: AUDIO_TIMEOUT
});
const audioMatcher = new AudioMatcher({
  pythonExecutable: PYTHON_EXECUTABLE,
  threshold: MATCH_THRESHOLD
});
const roomCodeManager = new RoomCodeManager({
  ttlMs: ROOM_CODE_TTL
});
const trustedDevices = new TrustedDevicesManager();

const clients = new Map();

console.log('='.repeat(60));
console.log('Audio Pairing Backend Server');
console.log('='.repeat(60));
console.log(`WebSocket Server listening on port ${PORT}`);
console.log(`Python executable: ${PYTHON_EXECUTABLE}`);
console.log(`Match threshold: ${MATCH_THRESHOLD}`);
console.log(`Session timeout: ${SESSION_TIMEOUT}ms`);
console.log(`Audio timeout: ${AUDIO_TIMEOUT}ms`);
console.log(`Room code TTL: ${ROOM_CODE_TTL}ms`);
console.log('='.repeat(60));

wss.on('connection', (ws, req) => {
  const clientId = cryptoUtils.generateClientId();
  const keyPair = trustedDevices.generatePublicKeyPair();
  
  const clientInfo = {
    id: clientId,
    ws,
    platform: null,
    deviceInfo: null,
    connectedAt: Date.now(),
    sessionId: null,
    encryptionKey: null,
    publicKey: keyPair.publicKey,
    privateKey: keyPair.privateKey,
    publicKeyFingerprint: trustedDevices.fingerprintPublicKey(keyPair.publicKey)
  };

  clients.set(clientId, clientInfo);
  
  console.log(`[${new Date().toISOString()}] Client connected: ${clientId.substring(0, 8)}...`);

  sendMessage(ws, {
    type: 'connected',
    clientId,
    timestamp: Date.now(),
    serverPublicKey: keyPair.publicKey,
    serverPublicKeyFingerprint: clientInfo.publicKeyFingerprint
  });

  ws.on('message', async (data) => {
    try {
      const message = JSON.parse(data.toString());
      await handleMessage(clientId, message);
    } catch (error) {
      console.error(`Error parsing message from client ${clientId.substring(0, 8)}:`, error.message);
      sendMessage(ws, {
        type: 'error',
        message: 'Invalid message format'
      });
    }
  });

  ws.on('close', (code, reason) => {
    console.log(`[${new Date().toISOString()}] Client disconnected: ${clientId.substring(0, 8)}..., code: ${code}`);
    handleClientDisconnect(clientId);
  });

  ws.on('error', (error) => {
    console.error(`WebSocket error for client ${clientId.substring(0, 8)}:`, error.message);
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
    case 'generate_room_code':
      handleGenerateRoomCode(clientId, message);
      break;
    case 'join_room':
      handleJoinRoom(clientId, message);
      break;
    case 'audio_data':
      handleAudioData(clientId, message);
      break;
    case 'broadcast_fingerprint':
      handleBroadcastFingerprint(clientId, message);
      break;
    case 'submit_fingerprint':
      handleSubmitFingerprint(clientId, message);
      break;
    case 'cancel_pairing':
      handleCancelPairing(clientId, message);
      break;
    case 'get_trusted_devices':
      handleGetTrustedDevices(clientId, message);
      break;
    case 'remove_trusted_device':
      handleRemoveTrustedDevice(clientId, message);
      break;
    case 'quick_reconnect':
      handleQuickReconnect(clientId, message);
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
      console.log(`Unknown message type from client ${clientId.substring(0, 8)}: ${message.type}`);
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
  client.clientPublicKey = message.publicKey || null;
  if (message.publicKey) {
    client.clientPublicKeyFingerprint = trustedDevices.fingerprintPublicKey(message.publicKey);
  }

  console.log(`Client ${clientId.substring(0, 8)} registered as ${client.platform}`);

  sendMessage(client.ws, {
    type: 'registered',
    clientId,
    platform: client.platform,
    deviceFingerprint: roomCodeManager.generateDeviceFingerprint(clientId, client.deviceInfo)
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

  const mode = message.mode || 'auto';
  
  if (mode === 'auto') {
    let session = sessionPool.findWaitingSession(clientId, 'auto');

    if (!session) {
      session = sessionPool.createSession(SESSION_TIMEOUT, AUDIO_TIMEOUT, 'auto');
      sessionPool.addClientToSession(
        session.id, clientId, client.ws, client.platform,
        'auto', client.clientPublicKeyFingerprint, client.deviceInfo
      );
      
      console.log(`Client ${clientId.substring(0, 8)} created auto session: ${session.id.substring(0, 8)}`);
      
      sendMessage(client.ws, {
        type: 'session_created',
        sessionId: session.id,
        status: 'waiting_for_partner',
        mode: 'auto'
      });
    } else {
      sessionPool.addClientToSession(
        session.id, clientId, client.ws, client.platform,
        'auto', client.clientPublicKeyFingerprint, client.deviceInfo
      );
      
      console.log(`Client ${clientId.substring(0, 8)} joined auto session: ${session.id.substring(0, 8)}`);
      
      sendMessage(client.ws, {
        type: 'session_joined',
        sessionId: session.id,
        status: 'ready',
        mode: 'auto'
      });

      const otherClient = session.getOtherClient(clientId);
      if (otherClient && otherClient.ws.readyState === WebSocket.OPEN) {
        sendMessage(otherClient.ws, {
          type: 'partner_joined',
          sessionId: session.id,
          partnerPlatform: client.platform,
          mode: 'auto'
        });
      }

      broadcastToSession(session.id, {
        type: 'start_recording',
        sessionId: session.id,
        duration: 3000,
        mode: 'auto'
      });
    }

    client.sessionId = session.id;
  } else if (mode === 'master') {
    const session = sessionPool.createSession(SESSION_TIMEOUT, AUDIO_TIMEOUT, 'master_slave');
    sessionPool.addClientToSession(
      session.id, clientId, client.ws, client.platform,
      'master', client.clientPublicKeyFingerprint, client.deviceInfo
    );
    client.sessionId = session.id;
    
    console.log(`Client ${clientId.substring(0, 8)} created master session: ${session.id.substring(0, 8)}`);
    
    sendMessage(client.ws, {
      type: 'session_created',
      sessionId: session.id,
      status: 'waiting_for_slave',
      mode: 'master_slave',
      role: 'master'
    });
  }
}

function handleGenerateRoomCode(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  const session = sessionPool.getSessionByClient(clientId);
  if (!session || session.mode !== 'master_slave' || session.getRole(clientId) !== 'master') {
    sendMessage(client.ws, {
      type: 'error',
      message: 'Not in a valid master session'
    });
    return;
  }

  roomCodeManager.revokeAllForDevice(clientId);
  
  const result = roomCodeManager.generateRoomCode(clientId, client.deviceInfo);
  session.setRoomCode(result.code);

  console.log(`Client ${clientId.substring(0, 8)} generated room code: ${result.code}`);

  sendMessage(client.ws, {
    type: 'room_code_generated',
    sessionId: session.id,
    roomCode: result.code,
    expiresAt: result.expiresAt,
    ttlMs: result.ttlMs
  });

  sendMessage(client.ws, {
    type: 'master_ready',
    sessionId: session.id,
    roomCode: result.code,
    instruction: 'Please wait for slave to join and submit fingerprint'
  });
}

function handleJoinRoom(clientId, message) {
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

  const roomCode = message.roomCode;
  if (!roomCode) {
    sendMessage(client.ws, {
      type: 'error',
      message: 'Room code is required'
    });
    return;
  }

  const validation = roomCodeManager.validateRoomCode(roomCode);
  if (!validation.valid) {
    sendMessage(client.ws, {
      type: 'room_code_invalid',
      roomCode,
      reason: validation.reason
    });
    return;
  }

  let session = sessionPool.getSessionByRoomCode(roomCode);
  if (!session) {
    session = sessionPool.createSession(SESSION_TIMEOUT, AUDIO_TIMEOUT, 'master_slave');
    session.setRoomCode(roomCode);
    sessionPool.addClientToSession(
      session.id, validation.deviceId, 
      clients.get(validation.deviceId)?.ws || client.ws, 
      validation.deviceInfo?.platform || 'unknown',
      'master', null, validation.deviceInfo || {}
    );
  }

  roomCodeManager.markCodeUsed(roomCode);

  sessionPool.addClientToSession(
    session.id, clientId, client.ws, client.platform,
    'slave', client.clientPublicKeyFingerprint, client.deviceInfo
  );
  client.sessionId = session.id;

  console.log(`Client ${clientId.substring(0, 8)} joined room ${roomCode}, session: ${session.id.substring(0, 8)}`);

  sendMessage(client.ws, {
    type: 'session_joined',
    sessionId: session.id,
    status: 'waiting_fingerprint_broadcast',
    mode: 'master_slave',
    role: 'slave',
    roomCode
  });

  const master = session.getMaster();
  if (master && master.ws && master.ws.readyState === WebSocket.OPEN) {
    sendMessage(master.ws, {
      type: 'slave_joined',
      sessionId: session.id,
      slavePlatform: client.platform,
      roomCode,
      instruction: 'Please broadcast your audio fingerprint now'
    });
  }
}

function handleBroadcastFingerprint(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  const session = sessionPool.getSessionByClient(clientId);
  if (!session || session.mode !== 'master_slave' || session.getRole(clientId) !== 'master') {
    sendMessage(client.ws, {
      type: 'error',
      message: 'Not authorized to broadcast fingerprint'
    });
    return;
  }

  const { audioData, sampleRate } = message;
  if (!audioData) {
    sendMessage(client.ws, {
      type: 'error',
      message: 'Missing audio data for fingerprint broadcast'
    });
    return;
  }

  session.setAudioData(clientId, audioData, sampleRate || 16000);

  console.log(`Master ${clientId.substring(0, 8)} broadcast fingerprint in session ${session.id.substring(0, 8)}`);

  sendMessage(client.ws, {
    type: 'fingerprint_broadcasted',
    sessionId: session.id,
    status: 'waiting_slave_fingerprint'
  });

  const slave = session.getSlave();
  if (slave && slave.ws && slave.ws.readyState === WebSocket.OPEN) {
    sendMessage(slave.ws, {
      type: 'master_fingerprint_broadcasted',
      sessionId: session.id,
      instruction: 'Please record and submit your audio fingerprint now',
      duration: 3000
    });
  }

  if (session.hasAllAudioData()) {
    processPairingMatch(session);
  }
}

function handleSubmitFingerprint(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  const session = sessionPool.getSessionByClient(clientId);
  if (!session || session.mode !== 'master_slave' || session.getRole(clientId) !== 'slave') {
    sendMessage(client.ws, {
      type: 'error',
      message: 'Not authorized to submit fingerprint'
    });
    return;
  }

  const { audioData, sampleRate } = message;
  if (!audioData) {
    sendMessage(client.ws, {
      type: 'error',
      message: 'Missing audio data for fingerprint submission'
    });
    return;
  }

  session.setAudioData(clientId, audioData, sampleRate || 16000);

  console.log(`Slave ${clientId.substring(0, 8)} submitted fingerprint in session ${session.id.substring(0, 8)}`);

  sendMessage(client.ws, {
    type: 'fingerprint_submitted',
    sessionId: session.id,
    status: 'matching'
  });

  const master = session.getMaster();
  if (master && master.ws && master.ws.readyState === WebSocket.OPEN) {
    sendMessage(master.ws, {
      type: 'slave_fingerprint_received',
      sessionId: session.id,
      status: 'matching'
    });
  }

  if (session.hasAllAudioData()) {
    processPairingMatch(session);
  }
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

  console.log(`Received audio data from client ${clientId.substring(0, 8)} in session ${session.id.substring(0, 8)}`);

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
  console.log(`Processing audio match for session ${session.id.substring(0, 8)} (mode: ${session.mode})...`);

  broadcastToSession(session.id, {
    type: 'matching_started',
    sessionId: session.id,
    mode: session.mode
  });

  const [client1, client2] = session.getAudioDataPair();

  try {
    const matchResult = await audioMatcher.match(
      client1.audioData,
      client2.audioData,
      client1.sampleRate || 16000
    );

    console.log(`Match result for session ${session.id.substring(0, 8)}:`, matchResult);

    if (matchResult.success && matchResult.is_match) {
      const aesKey = cryptoUtils.generateAESKey();
      const aesKeyBase64 = cryptoUtils.keyToBase64(aesKey);

      session.setPaired(aesKeyBase64, aesKey);

      const c1 = clients.get(client1.clientId);
      const c2 = clients.get(client2.clientId);
      if (c1) c1.encryptionKey = aesKey;
      if (c2) c2.encryptionKey = aesKey;

      if (c1 && c2) {
        if (c1.clientPublicKeyFingerprint) {
          trustedDevices.addTrustedDevice(
            c1.id, c2.id, c2.clientPublicKeyFingerprint, c2.deviceInfo || {}
          );
        }
        if (c2.clientPublicKeyFingerprint) {
          trustedDevices.addTrustedDevice(
            c2.id, c1.id, c1.clientPublicKeyFingerprint, c1.deviceInfo || {}
          );
        }
      }

      const partner1Info = {
        partnerId: client2.clientId,
        partnerPlatform: client2.platform,
        partnerRole: session.getRole(client2.clientId),
        partnerDeviceInfo: client2.deviceInfo,
        partnerPublicKeyFingerprint: client2.publicKeyFingerprint || c2?.clientPublicKeyFingerprint
      };

      const partner2Info = {
        partnerId: client1.clientId,
        partnerPlatform: client1.platform,
        partnerRole: session.getRole(client1.clientId),
        partnerDeviceInfo: client1.deviceInfo,
        partnerPublicKeyFingerprint: client1.publicKeyFingerprint || c1?.clientPublicKeyFingerprint
      };

      sendMessage(client1.ws, {
        type: 'pairing_success',
        sessionId: session.id,
        aesKey: aesKeyBase64,
        ...partner1Info,
        matchScore: matchResult,
        mode: session.mode,
        yourRole: session.getRole(client1.clientId),
        isTrustedDevice: c1?.clientPublicKeyFingerprint ? 
          trustedDevices.isTrustedDevice(c1.id, c2?.clientPublicKeyFingerprint) : false
      });

      sendMessage(client2.ws, {
        type: 'pairing_success',
        sessionId: session.id,
        aesKey: aesKeyBase64,
        ...partner2Info,
        matchScore: matchResult,
        mode: session.mode,
        yourRole: session.getRole(client2.clientId),
        isTrustedDevice: c2?.clientPublicKeyFingerprint ? 
          trustedDevices.isTrustedDevice(c2.id, c1?.clientPublicKeyFingerprint) : false
      });

      console.log(`Session ${session.id.substring(0, 8)} paired successfully!`);
    } else {
      session.setFailed(matchResult.error || 'Audio signatures do not match');

      broadcastToSession(session.id, {
        type: 'pairing_failed',
        sessionId: session.id,
        reason: matchResult.error || 'Audio signatures do not match',
        matchScore: matchResult,
        mode: session.mode
      });

      console.log(`Session ${session.id.substring(0, 8)} pairing failed: ${matchResult.error || 'No match'}`);
      setTimeout(() => {
        sessionPool.destroySession(session.id);
      }, 2000);
    }
  } catch (error) {
    console.error(`Error processing match for session ${session.id.substring(0, 8)}:`, error);
    
    session.setFailed(error.message);
    broadcastToSession(session.id, {
      type: 'pairing_failed',
      sessionId: session.id,
      reason: 'Internal server error during matching',
      mode: session.mode
    });
    
    setTimeout(() => {
      sessionPool.destroySession(session.id);
    }, 2000);
  }
}

function handleGetTrustedDevices(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  const devices = trustedDevices.getTrustedDevices(clientId);

  sendMessage(client.ws, {
    type: 'trusted_devices_list',
    devices,
    total: devices.length
  });
}

function handleRemoveTrustedDevice(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  const { partnerPublicKeyFingerprint } = message;
  if (!partnerPublicKeyFingerprint) {
    sendMessage(client.ws, {
      type: 'error',
      message: 'Missing partner public key fingerprint'
    });
    return;
  }

  const removed = trustedDevices.removeTrustedDevice(clientId, partnerPublicKeyFingerprint);

  sendMessage(client.ws, {
    type: 'trusted_device_removed',
    partnerPublicKeyFingerprint,
    removed
  });
}

function handleQuickReconnect(clientId, message) {
  const client = clients.get(clientId);
  if (!client) return;

  const { partnerPublicKeyFingerprint, signature, nonce } = message;
  if (!partnerPublicKeyFingerprint) {
    sendMessage(client.ws, {
      type: 'error',
      message: 'Missing partner public key fingerprint'
    });
    return;
  }

  const isTrusted = trustedDevices.isTrustedDevice(clientId, partnerPublicKeyFingerprint);
  
  if (!isTrusted) {
    sendMessage(client.ws, {
      type: 'quick_reconnect_failed',
      reason: 'device_not_trusted'
    });
    return;
  }

  let partnerClient = null;
  let partnerSession = null;
  
  for (const [otherId, otherClient] of clients.entries()) {
    if (otherClient.clientPublicKeyFingerprint === partnerPublicKeyFingerprint &&
        otherClient.ws.readyState === WebSocket.OPEN) {
      partnerClient = otherClient;
      partnerSession = sessionPool.getSessionByClient(otherId);
      break;
    }
  }

  if (!partnerClient) {
    sendMessage(client.ws, {
      type: 'quick_reconnect_failed',
      reason: 'partner_offline'
    });
    return;
  }

  if (!partnerSession) {
    partnerSession = sessionPool.createSession(SESSION_TIMEOUT, AUDIO_TIMEOUT, 'quick_reconnect');
    sessionPool.addClientToSession(
      partnerSession.id, partnerClient.id, partnerClient.ws, partnerClient.platform,
      'auto', partnerClient.clientPublicKeyFingerprint, partnerClient.deviceInfo
    );
  }

  if (partnerSession.clients.size >= 2) {
    sendMessage(client.ws, {
      type: 'quick_reconnect_failed',
      reason: 'partner_busy'
    });
    return;
  }

  sessionPool.addClientToSession(
    partnerSession.id, clientId, client.ws, client.platform,
    'auto', client.clientPublicKeyFingerprint, client.deviceInfo
  );
  client.sessionId = partnerSession.id;

  const aesKey = cryptoUtils.generateAESKey();
  const aesKeyBase64 = cryptoUtils.keyToBase64(aesKey);

  partnerSession.setPaired(aesKeyBase64, aesKey);
  client.encryptionKey = aesKey;
  partnerClient.encryptionKey = aesKey;

  trustedDevices.updateLastSeen(clientId, partnerPublicKeyFingerprint);
  if (partnerClient.clientPublicKeyFingerprint) {
    trustedDevices.updateLastSeen(partnerClient.id, client.clientPublicKeyFingerprint);
  }

  sendMessage(client.ws, {
    type: 'quick_reconnect_success',
    sessionId: partnerSession.id,
    aesKey: aesKeyBase64,
    partnerId: partnerClient.id,
    partnerPlatform: partnerClient.platform,
    mode: 'quick_reconnect'
  });

  sendMessage(partnerClient.ws, {
    type: 'quick_reconnect_success',
    sessionId: partnerSession.id,
    aesKey: aesKeyBase64,
    partnerId: clientId,
    partnerPlatform: client.platform,
    mode: 'quick_reconnect'
  });

  console.log(`Quick reconnect successful between ${clientId.substring(0, 8)} and ${partnerClient.id.substring(0, 8)}`);
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

  if (session.roomCode) {
    roomCodeManager.revokeCode(session.roomCode);
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

  console.log(`Client ${clientId.substring(0, 8)} cancelled pairing in session ${session.id.substring(0, 8)}`);
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
    server: {
      ...sessionPool.getStats(),
      roomCodes: roomCodeManager.getStats(),
      trustedDevices: trustedDevices.getStats()
    },
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

  roomCodeManager.revokeAllForDevice(clientId);

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
  if (ws && ws.readyState === WebSocket.OPEN) {
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
  console.log(`[Event] Session created: ${data.id.substring(0, 8)} (mode: ${data.mode})`);
});

sessionPool.on('session:client_joined', (data) => {
  console.log(`[Event] Client ${data.clientId.substring(0, 8)} joined session ${data.sessionId.substring(0, 8)} (role: ${data.role})`);
});

sessionPool.on('session:timeout', (data) => {
  console.log(`[Event] Session ${data.sessionId.substring(0, 8)} timed out`);
  
  const session = sessionPool.getSession(data.sessionId);
  if (session) {
    broadcastToSession(data.sessionId, {
      type: 'session_timeout',
      sessionId: data.sessionId
    });
  }
});

sessionPool.on('session:audio_timeout', (data) => {
  console.log(`[Event] Session ${data.sessionId.substring(0, 8)} audio fingerprint timeout`);
  
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
  console.log(`[Event] Session ${data.sessionId.substring(0, 8)} failed: ${data.reason}`);
});

sessionPool.on('session:destroyed', (data) => {
  console.log(`[Event] Session destroyed: ${data.sessionId.substring(0, 8)}`);
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

  roomCodeManager.shutdown();
  trustedDevices.shutdown();
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
  const rcStats = roomCodeManager.getStats();
  const tdStats = trustedDevices.getStats();
  console.log(`[${new Date().toISOString()}] Stats: ` +
    `Sessions: ${stats.totalSessions} ` +
    `(Waiting: ${stats.waitingSessions}, Ready: ${stats.readySessions}, ` +
    `Paired: ${stats.pairedSessions}), Clients: ${stats.connectedClients}, ` +
    `RoomCodes: ${rcStats.active}, TrustedDevices: ${tdStats.trusted}`);
}, 30000);
