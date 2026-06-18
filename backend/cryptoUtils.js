const crypto = require('crypto');

const ALGORITHM = 'aes-256-gcm';
const KEY_LENGTH = 32;
const IV_LENGTH = 12;
const SALT_LENGTH = 16;

function generateAESKey() {
  return crypto.randomBytes(KEY_LENGTH);
}

function generateIV() {
  return crypto.randomBytes(IV_LENGTH);
}

function encrypt(key, plaintext) {
  const iv = generateIV();
  const cipher = crypto.createCipheriv(ALGORITHM, key, iv);
  
  let encrypted = cipher.update(plaintext, 'utf8', 'base64');
  encrypted += cipher.final('base64');
  
  const authTag = cipher.getAuthTag();
  
  return {
    encrypted,
    iv: iv.toString('base64'),
    authTag: authTag.toString('base64')
  };
}

function decrypt(key, encryptedData) {
  const iv = Buffer.from(encryptedData.iv, 'base64');
  const authTag = Buffer.from(encryptedData.authTag, 'base64');
  const encrypted = Buffer.from(encryptedData.encrypted, 'base64');
  
  const decipher = crypto.createDecipheriv(ALGORITHM, key, iv);
  decipher.setAuthTag(authTag);
  
  let decrypted = decipher.update(encrypted, 'base64', 'utf8');
  decrypted += decipher.final('utf8');
  
  return decrypted;
}

function encryptBinary(key, dataBuffer) {
  const iv = generateIV();
  const cipher = crypto.createCipheriv(ALGORITHM, key, iv);
  
  let encrypted = Buffer.concat([cipher.update(dataBuffer), cipher.final()]);
  const authTag = cipher.getAuthTag();
  
  return Buffer.concat([iv, authTag, encrypted]);
}

function decryptBinary(key, encryptedBuffer) {
  const iv = encryptedBuffer.slice(0, IV_LENGTH);
  const authTag = encryptedBuffer.slice(IV_LENGTH, IV_LENGTH + 16);
  const encrypted = encryptedBuffer.slice(IV_LENGTH + 16);
  
  const decipher = crypto.createDecipheriv(ALGORITHM, key, iv);
  decipher.setAuthTag(authTag);
  
  return Buffer.concat([decipher.update(encrypted), decipher.final()]);
}

function keyToBase64(key) {
  return key.toString('base64');
}

function keyFromBase64(base64Key) {
  return Buffer.from(base64Key, 'base64');
}

function hashData(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function generateClientId() {
  return crypto.randomBytes(16).toString('hex');
}

function hmac(key, data) {
  return crypto.createHmac('sha256', key).update(data).digest('hex');
}

function generateNonce() {
  return crypto.randomBytes(16).toString('hex');
}

function constantTimeCompare(a, b) {
  return crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

module.exports = {
  generateAESKey,
  generateIV,
  encrypt,
  decrypt,
  encryptBinary,
  decryptBinary,
  keyToBase64,
  keyFromBase64,
  hashData,
  generateClientId,
  hmac,
  generateNonce,
  constantTimeCompare,
  ALGORITHM,
  KEY_LENGTH,
  IV_LENGTH
};
