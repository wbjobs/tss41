const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const DEFAULT_DB_PATH = path.join(__dirname, 'data', 'trusted_devices.json');

class TrustedDevicesManager {
  constructor(options = {}) {
    this.dbPath = options.dbPath || DEFAULT_DB_PATH;
    this.devices = new Map();
    this.lastSyncAt = 0;
    this.syncIntervalMs = options.syncIntervalMs || 300000;
    this._ensureDbDir();
    this._loadFromDisk();
    this._startAutoSync();
  }

  _ensureDbDir() {
    const dir = path.dirname(this.dbPath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }
  }

  _loadFromDisk() {
    try {
      if (fs.existsSync(this.dbPath)) {
        const data = JSON.parse(fs.readFileSync(this.dbPath, 'utf8'));
        for (const [key, device] of Object.entries(data)) {
          this.devices.set(key, device);
        }
        this.lastSyncAt = Date.now();
      }
    } catch (error) {
      console.error('Failed to load trusted devices:', error.message);
    }
  }

  _saveToDisk() {
    try {
      const data = {};
      for (const [key, device] of this.devices.entries()) {
        data[key] = device;
      }
      fs.writeFileSync(this.dbPath, JSON.stringify(data, null, 2), 'utf8');
      this.lastSyncAt = Date.now();
    } catch (error) {
      console.error('Failed to save trusted devices:', error.message);
    }
  }

  _startAutoSync() {
    this.syncTimer = setInterval(() => {
      this._saveToDisk();
    }, this.syncIntervalMs);
  }

  _makeKey(deviceId, partnerPublicKeyFingerprint) {
    const sorted = [deviceId, partnerPublicKeyFingerprint].sort();
    return crypto.createHash('sha256')
      .update(sorted.join('|'))
      .digest('hex')
      .substring(0, 32);
  }

  generatePublicKeyPair() {
    const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519', {
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
    });
    return { privateKey, publicKey };
  }

  fingerprintPublicKey(publicKeyPem) {
    return crypto.createHash('sha256')
      .update(publicKeyPem)
      .digest('hex');
  }

  signData(privateKeyPem, data) {
    const sign = crypto.createSign('sha256');
    sign.update(JSON.stringify(data));
    return sign.sign(privateKeyPem, 'base64');
  }

  verifySignature(publicKeyPem, data, signature) {
    try {
      const verify = crypto.createVerify('sha256');
      verify.update(JSON.stringify(data));
      return verify.verify(publicKeyPem, signature, 'base64');
    } catch (error) {
      return false;
    }
  }

  addTrustedDevice(deviceId, partnerDeviceId, partnerPublicKeyFingerprint, partnerDeviceInfo = {}) {
    const key = this._makeKey(deviceId, partnerPublicKeyFingerprint);
    
    const existing = this.devices.get(key);
    const now = Date.now();
    
    if (existing) {
      existing.lastSeenAt = now;
      existing.pairCount = (existing.pairCount || 1) + 1;
      existing.partnerDeviceInfo = partnerDeviceInfo;
    } else {
      this.devices.set(key, {
        deviceId,
        partnerDeviceId,
        partnerPublicKeyFingerprint,
        partnerDeviceInfo,
        createdAt: now,
        lastSeenAt: now,
        pairCount: 1,
        trusted: true,
        blocked: false
      });
    }
    
    this._saveToDisk();
    return this.devices.get(key);
  }

  isTrustedDevice(deviceId, partnerPublicKeyFingerprint) {
    const key = this._makeKey(deviceId, partnerPublicKeyFingerprint);
    const device = this.devices.get(key);
    return device && device.trusted && !device.blocked;
  }

  getTrustedDevices(deviceId) {
    const result = [];
    for (const device of this.devices.values()) {
      if (device.deviceId === deviceId && device.trusted && !device.blocked) {
        result.push({
          partnerDeviceId: device.partnerDeviceId,
          partnerPublicKeyFingerprint: device.partnerPublicKeyFingerprint,
          partnerDeviceInfo: device.partnerDeviceInfo,
          createdAt: device.createdAt,
          lastSeenAt: device.lastSeenAt,
          pairCount: device.pairCount
        });
      }
    }
    return result.sort((a, b) => b.lastSeenAt - a.lastSeenAt);
  }

  removeTrustedDevice(deviceId, partnerPublicKeyFingerprint) {
    const key = this._makeKey(deviceId, partnerPublicKeyFingerprint);
    const result = this.devices.delete(key);
    if (result) this._saveToDisk();
    return result;
  }

  blockDevice(deviceId, partnerPublicKeyFingerprint) {
    const key = this._makeKey(deviceId, partnerPublicKeyFingerprint);
    const device = this.devices.get(key);
    if (device) {
      device.blocked = true;
      device.trusted = false;
      this._saveToDisk();
      return true;
    }
    return false;
  }

  unblockDevice(deviceId, partnerPublicKeyFingerprint) {
    const key = this._makeKey(deviceId, partnerPublicKeyFingerprint);
    const device = this.devices.get(key);
    if (device) {
      device.blocked = false;
      device.trusted = true;
      this._saveToDisk();
      return true;
    }
    return false;
  }

  updateLastSeen(deviceId, partnerPublicKeyFingerprint) {
    const key = this._makeKey(deviceId, partnerPublicKeyFingerprint);
    const device = this.devices.get(key);
    if (device) {
      device.lastSeenAt = Date.now();
      return true;
    }
    return false;
  }

  clearAllForDevice(deviceId) {
    let count = 0;
    for (const [key, device] of this.devices.entries()) {
      if (device.deviceId === deviceId) {
        this.devices.delete(key);
        count++;
      }
    }
    if (count > 0) this._saveToDisk();
    return count;
  }

  getStats() {
    const total = this.devices.size;
    const trusted = Array.from(this.devices.values()).filter(d => d.trusted && !d.blocked).length;
    const blocked = Array.from(this.devices.values()).filter(d => d.blocked).length;
    
    return {
      total,
      trusted,
      blocked,
      lastSyncAt: this.lastSyncAt
    };
  }

  shutdown() {
    if (this.syncTimer) {
      clearInterval(this.syncTimer);
      this.syncTimer = null;
    }
    this._saveToDisk();
  }
}

module.exports = { TrustedDevicesManager };
