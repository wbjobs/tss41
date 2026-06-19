const EventEmitter = require('events');

class PairingSession {
  constructor(id, timeoutMs = 30000, audioTimeoutMs = 15000, mode = 'auto') {
    this.id = id;
    this.clients = new Map();
    this.createdAt = Date.now();
    this.timeoutMs = timeoutMs;
    this.audioTimeoutMs = audioTimeoutMs;
    this.status = 'waiting';
    this.aesKey = null;
    this.encryptionKey = null;
    this.timeoutTimer = null;
    this.audioTimeoutTimer = null;
    this.firstAudioAt = null;
    this.mode = mode;
    this.roomCode = null;
    this.masterClientId = null;
    this.onDestroy = null;
    this.onAudioTimeout = null;
  }

  addClient(clientId, ws, platform, role = 'auto', publicKeyFingerprint = null, deviceInfo = {}) {
    if (this.clients.size >= 2) {
      return false;
    }
    
    let actualRole = role;
    if (this.mode === 'master_slave') {
      if (this.clients.size === 0) {
        actualRole = 'master';
        this.masterClientId = clientId;
      } else {
        actualRole = 'slave';
      }
    }
    
    this.clients.set(clientId, {
      ws,
      platform,
      audioData: null,
      sampleRate: null,
      paired: false,
      role: actualRole,
      publicKeyFingerprint,
      deviceInfo
    });
    
    if (this.clients.size === 2) {
      this.status = 'ready';
      this.resetTimeout();
    }
    
    return actualRole;
  }

  setRoomCode(code) {
    this.roomCode = code;
  }

  getMaster() {
    if (!this.masterClientId) return null;
    const client = this.clients.get(this.masterClientId);
    if (!client) return null;
    return { id: this.masterClientId, ...client };
  }

  getSlave() {
    for (const [id, client] of this.clients.entries()) {
      if (id !== this.masterClientId) {
        return { id, ...client };
      }
    }
    return null;
  }

  getRole(clientId) {
    const client = this.clients.get(clientId);
    return client ? client.role : null;
  }

  hasClient(clientId) {
    return this.clients.has(clientId);
  }

  getClient(clientId) {
    return this.clients.get(clientId);
  }

  getOtherClient(clientId) {
    for (const [id, client] of this.clients) {
      if (id !== clientId) {
        return { id, ...client };
      }
    }
    return null;
  }

  setAudioData(clientId, audioData, sampleRate) {
    const client = this.clients.get(clientId);
    if (client) {
      client.audioData = audioData;
      client.sampleRate = sampleRate;
      client.audioReceivedAt = Date.now();
      
      if (!this.firstAudioAt) {
        this.firstAudioAt = Date.now();
        this.startAudioTimeout();
      }
    }
  }
  
  startAudioTimeout() {
    this.clearAudioTimeout();
    
    this.audioTimeoutTimer = setTimeout(() => {
      if (this.status !== 'paired' && this.status !== 'failed') {
        console.log(`Session ${this.id} audio timeout after ${this.audioTimeoutMs}ms`);
        if (this.onAudioTimeout) {
          this.onAudioTimeout(this.id);
        }
      }
    }, this.audioTimeoutMs);
  }
  
  clearAudioTimeout() {
    if (this.audioTimeoutTimer) {
      clearTimeout(this.audioTimeoutTimer);
      this.audioTimeoutTimer = null;
    }
  }

  hasAllAudioData() {
    if (this.clients.size !== 2) return false;
    
    for (const client of this.clients.values()) {
      if (!client.audioData) return false;
    }
    return true;
  }

  getAudioDataPair() {
    const clients = Array.from(this.clients.entries());
    return [
      { clientId: clients[0][0], ...clients[0][1] },
      { clientId: clients[1][0], ...clients[1][1] }
    ];
  }

  setPaired(aesKey, encryptionKey) {
    this.status = 'paired';
    this.aesKey = aesKey;
    this.encryptionKey = encryptionKey;
    
    for (const client of this.clients.values()) {
      client.paired = true;
    }
    
    this.clearTimeout();
    this.clearAudioTimeout();
  }

  setFailed(reason) {
    this.status = 'failed';
    this.failureReason = reason;
    this.clearTimeout();
    this.clearAudioTimeout();
  }

  resetTimeout() {
    this.clearTimeout();
    this.timeoutTimer = setTimeout(() => {
      if (this.onDestroy) {
        this.onDestroy(this.id, 'timeout');
      }
    }, this.timeoutMs);
  }

  clearTimeout() {
    if (this.timeoutTimer) {
      clearTimeout(this.timeoutTimer);
      this.timeoutTimer = null;
    }
  }

  destroy() {
    this.clearTimeout();
    this.clearAudioTimeout();
    this.clients.clear();
  }

  toJSON() {
    return {
      id: this.id,
      status: this.status,
      mode: this.mode,
      roomCode: this.roomCode,
      clientCount: this.clients.size,
      masterClientId: this.masterClientId,
      createdAt: this.createdAt,
      ageMs: Date.now() - this.createdAt
    };
  }
}

class SessionPool extends EventEmitter {
  constructor(options = {}) {
    super();
    this.sessions = new Map();
    this.clientToSession = new Map();
    this.sessionTimeoutMs = options.sessionTimeoutMs || 30000;
    this.audioTimeoutMs = options.audioTimeoutMs || 15000;
    this.cleanupIntervalMs = options.cleanupIntervalMs || 5000;
    this.cleanupTimer = null;
    this.startCleanup();
  }

  createSession(timeoutMs, audioTimeoutMs, mode = 'auto') {
    const { v4: uuidv4 } = require('uuid');
    const sessionId = uuidv4();
    const session = new PairingSession(
      sessionId, 
      timeoutMs || this.sessionTimeoutMs,
      audioTimeoutMs || this.audioTimeoutMs,
      mode
    );
    
    session.onDestroy = (id, reason) => {
      this.emit('session:timeout', { sessionId: id, reason });
      this.destroySession(id);
    };
    
    session.onAudioTimeout = (id) => {
      this.emit('session:audio_timeout', { sessionId: id });
      const sess = this.sessions.get(id);
      if (sess) {
        sess.setFailed('Audio fingerprint timeout');
        this.emit('session:failed', { sessionId: id, reason: 'audio_timeout' });
      }
    };
    
    this.sessions.set(sessionId, session);
    session.resetTimeout();
    
    this.emit('session:created', session.toJSON());
    return session;
  }

  getSession(sessionId) {
    return this.sessions.get(sessionId);
  }

  getSessionByRoomCode(roomCode) {
    for (const session of this.sessions.values()) {
      if (session.roomCode === roomCode && session.status !== 'failed') {
        return session;
      }
    }
    return null;
  }

  findWaitingSession(excludeClientId, mode = null) {
    for (const session of this.sessions.values()) {
      if (session.status === 'waiting' && session.clients.size === 1) {
        if (mode && session.mode !== mode) continue;
        const hasExcluded = excludeClientId && session.hasClient(excludeClientId);
        if (!hasExcluded) {
          return session;
        }
      }
    }
    return null;
  }

  findMasterSession(excludeClientId) {
    for (const session of this.sessions.values()) {
      if (session.status === 'waiting' && 
          session.mode === 'master_slave' && 
          session.clients.size === 1) {
        const hasExcluded = excludeClientId && session.hasClient(excludeClientId);
        if (!hasExcluded) {
          return session;
        }
      }
    }
    return null;
  }

  addClientToSession(sessionId, clientId, ws, platform, role = 'auto', publicKeyFingerprint = null, deviceInfo = {}) {
    const session = this.sessions.get(sessionId);
    if (!session) return false;
    
    const resultRole = session.addClient(clientId, ws, platform, role, publicKeyFingerprint, deviceInfo);
    if (resultRole !== false) {
      this.clientToSession.set(clientId, sessionId);
      this.emit('session:client_joined', {
        sessionId,
        clientId,
        platform,
        role: resultRole,
        clientCount: session.clients.size
      });
    }
    
    return resultRole;
  }

  getSessionByClient(clientId) {
    const sessionId = this.clientToSession.get(clientId);
    if (!sessionId) return null;
    return this.sessions.get(sessionId);
  }

  removeClientFromSession(clientId) {
    const sessionId = this.clientToSession.get(clientId);
    if (!sessionId) return;
    
    const session = this.sessions.get(sessionId);
    if (session) {
      this.clientToSession.delete(clientId);
      
      if (session.status === 'paired') {
        this.destroySession(sessionId);
      } else if (session.clients.size > 0) {
        session.clients.delete(clientId);
        if (session.clients.size === 0) {
          this.destroySession(sessionId);
        }
      }
      
      this.emit('session:client_left', { sessionId, clientId });
    }
  }

  destroySession(sessionId) {
    const session = this.sessions.get(sessionId);
    if (session) {
      for (const clientId of session.clients.keys()) {
        this.clientToSession.delete(clientId);
      }
      session.destroy();
      this.sessions.delete(sessionId);
      this.emit('session:destroyed', { sessionId });
    }
  }

  cleanupExpiredSessions() {
    const now = Date.now();
    const expiredSessions = [];
    
    for (const [id, session] of this.sessions.entries()) {
      if (session.status !== 'paired' && (now - session.createdAt) > this.sessionTimeoutMs) {
        expiredSessions.push(id);
      }
    }
    
    for (const id of expiredSessions) {
      this.emit('session:expired', { sessionId: id });
      this.destroySession(id);
    }
  }

  startCleanup() {
    this.cleanupTimer = setInterval(() => {
      this.cleanupExpiredSessions();
    }, this.cleanupIntervalMs);
  }

  stopCleanup() {
    if (this.cleanupTimer) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
    }
  }

  getStats() {
    return {
      totalSessions: this.sessions.size,
      waitingSessions: Array.from(this.sessions.values()).filter(s => s.status === 'waiting').length,
      readySessions: Array.from(this.sessions.values()).filter(s => s.status === 'ready').length,
      pairedSessions: Array.from(this.sessions.values()).filter(s => s.status === 'paired').length,
      failedSessions: Array.from(this.sessions.values()).filter(s => s.status === 'failed').length,
      connectedClients: this.clientToSession.size
    };
  }

  shutdown() {
    this.stopCleanup();
    for (const sessionId of Array.from(this.sessions.keys())) {
      this.destroySession(sessionId);
    }
  }
}

module.exports = { SessionPool, PairingSession };
