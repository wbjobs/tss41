const crypto = require('crypto');

const ROOM_CODE_LENGTH = 6;
const ROOM_CODE_TTL_MS = 5 * 60 * 1000;
const TIME_BUCKET_MS = 60 * 1000;

class RoomCodeManager {
  constructor(options = {}) {
    this.ttlMs = options.ttlMs || ROOM_CODE_TTL_MS;
    this.timeBucketMs = options.timeBucketMs || TIME_BUCKET_MS;
    this.activeCodes = new Map();
    this.startCleanup();
  }

  _getTimeBucket(timestamp = Date.now()) {
    return Math.floor(timestamp / this.timeBucketMs);
  }

  _getValidBuckets(timestamp = Date.now()) {
    const currentBucket = this._getTimeBucket(timestamp);
    return [currentBucket, currentBucket - 1];
  }

  generateDeviceFingerprint(deviceId, deviceInfo = {}) {
    const rawString = [
      deviceId,
      deviceInfo.platform || '',
      deviceInfo.model || '',
      deviceInfo.systemName || '',
      deviceInfo.systemVersion || ''
    ].join('|');
    
    return crypto.createHash('sha256').update(rawString).digest('hex').substring(0, 32);
  }

  _generateCodeFromBucket(bucket, deviceFingerprint) {
    const data = bucket.toString() + '|' + deviceFingerprint;
    const hash = crypto.createHash('sha256').update(data).digest('hex');
    const numericValue = BigInt('0x' + hash.substring(0, 12));
    const code = Number(numericValue % BigInt(Math.pow(10, ROOM_CODE_LENGTH)));
    return code.toString().padStart(ROOM_CODE_LENGTH, '0');
  }

  generateRoomCode(deviceId, deviceInfo = {}) {
    const deviceFingerprint = this.generateDeviceFingerprint(deviceId, deviceInfo);
    const currentBucket = this._getTimeBucket();
    const code = this._generateCodeFromBucket(currentBucket, deviceFingerprint);
    
    this.activeCodes.set(code, {
      deviceId,
      deviceFingerprint,
      deviceInfo,
      bucket: currentBucket,
      createdAt: Date.now(),
      expiresAt: Date.now() + this.ttlMs,
      used: false
    });

    setTimeout(() => {
      this._cleanupExpired();
    }, this.ttlMs + 1000);

    return {
      code,
      deviceFingerprint,
      expiresAt: Date.now() + this.ttlMs,
      ttlMs: this.ttlMs
    };
  }

  validateRoomCode(code) {
    if (!code || code.length !== ROOM_CODE_LENGTH || !/^\d+$/.test(code)) {
      return { valid: false, reason: 'invalid_format' };
    }

    const entry = this.activeCodes.get(code);
    if (!entry) {
      return { valid: false, reason: 'not_found' };
    }

    if (entry.used) {
      return { valid: false, reason: 'already_used' };
    }

    if (Date.now() > entry.expiresAt) {
      this.activeCodes.delete(code);
      return { valid: false, reason: 'expired' };
    }

    return {
      valid: true,
      ...entry
    };
  }

  verifyCodeWithFingerprint(code, deviceFingerprint, timestamp = Date.now()) {
    if (!code || code.length !== ROOM_CODE_LENGTH || !/^\d+$/.test(code)) {
      return false;
    }

    const validBuckets = this._getValidBuckets(timestamp);
    
    for (const bucket of validBuckets) {
      const expectedCode = this._generateCodeFromBucket(bucket, deviceFingerprint);
      if (expectedCode === code) {
        return true;
      }
    }

    return false;
  }

  markCodeUsed(code) {
    const entry = this.activeCodes.get(code);
    if (entry) {
      entry.used = true;
      return true;
    }
    return false;
  }

  revokeCode(code) {
    return this.activeCodes.delete(code);
  }

  revokeAllForDevice(deviceId) {
    let count = 0;
    for (const [code, entry] of this.activeCodes.entries()) {
      if (entry.deviceId === deviceId) {
        this.activeCodes.delete(code);
        count++;
      }
    }
    return count;
  }

  getCodeInfo(code) {
    const entry = this.activeCodes.get(code);
    if (!entry) return null;
    
    return {
      code,
      deviceId: entry.deviceId,
      deviceInfo: entry.deviceInfo,
      createdAt: entry.createdAt,
      expiresAt: entry.expiresAt,
      used: entry.used,
      remainingMs: Math.max(0, entry.expiresAt - Date.now())
    };
  }

  getStats() {
    const now = Date.now();
    let activeCount = 0;
    let usedCount = 0;
    let expiringCount = 0;

    for (const entry of this.activeCodes.values()) {
      if (now > entry.expiresAt) continue;
      if (entry.used) {
        usedCount++;
      } else {
        activeCount++;
        if (entry.expiresAt - now < 60000) {
          expiringCount++;
        }
      }
    }

    return {
      total: this.activeCodes.size,
      active: activeCount,
      used: usedCount,
      expiring: expiringCount
    };
  }

  _cleanupExpired() {
    const now = Date.now();
    for (const [code, entry] of this.activeCodes.entries()) {
      if (now > entry.expiresAt) {
        this.activeCodes.delete(code);
      }
    }
  }

  startCleanup() {
    this.cleanupTimer = setInterval(() => {
      this._cleanupExpired();
    }, 30000);
  }

  stopCleanup() {
    if (this.cleanupTimer) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
    }
  }

  shutdown() {
    this.stopCleanup();
    this.activeCodes.clear();
  }
}

module.exports = { RoomCodeManager };
