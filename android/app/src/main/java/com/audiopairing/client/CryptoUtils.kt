package com.audiopairing.client

import android.os.Build
import android.util.Base64
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import java.security.MessageDigest
import java.util.UUID

object CryptoUtils {
    
    const val ALGORITHM = "AES/GCM/NoPadding"
    const val KEY_LENGTH = 32
    const val IV_LENGTH = 12
    const val TAG_LENGTH = 16
    
    fun generateAESKey(): ByteArray {
        val keyGenerator = KeyGenerator.getInstance("AES")
        keyGenerator.init(256)
        val secretKey = keyGenerator.generateKey()
        return secretKey.encoded
    }
    
    fun generateIV(): ByteArray {
        val iv = ByteArray(IV_LENGTH)
        SecureRandom().nextBytes(iv)
        return iv
    }
    
    fun encrypt(key: ByteArray, plaintext: String): Map<String, String> {
        if (key.size != KEY_LENGTH) {
            throw IllegalArgumentException("Invalid key length")
        }
        
        val iv = generateIV()
        val secretKey = SecretKeySpec(key, "AES")
        val cipher = Cipher.getInstance(ALGORITHM)
        val parameterSpec = GCMParameterSpec(TAG_LENGTH * 8, iv)
        
        cipher.init(Cipher.ENCRYPT_MODE, secretKey, parameterSpec)
        
        val ciphertextWithTag = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        
        val ciphertext = ciphertextWithTag.copyOfRange(0, ciphertextWithTag.size - TAG_LENGTH)
        val tag = ciphertextWithTag.copyOfRange(ciphertextWithTag.size - TAG_LENGTH, ciphertextWithTag.size)
        
        return mapOf(
            "encrypted" to Base64.encodeToString(ciphertext, Base64.NO_WRAP),
            "iv" to Base64.encodeToString(iv, Base64.NO_WRAP),
            "authTag" to Base64.encodeToString(tag, Base64.NO_WRAP)
        )
    }
    
    fun decrypt(key: ByteArray, encryptedData: Map<String, String>): String {
        if (key.size != KEY_LENGTH) {
            throw IllegalArgumentException("Invalid key length")
        }
        
        val encryptedBase64 = encryptedData["encrypted"] ?: throw IllegalArgumentException("Missing encrypted data")
        val ivBase64 = encryptedData["iv"] ?: throw IllegalArgumentException("Missing IV")
        val tagBase64 = encryptedData["authTag"] ?: throw IllegalArgumentException("Missing auth tag")
        
        val ciphertext = Base64.decode(encryptedBase64, Base64.NO_WRAP)
        val iv = Base64.decode(ivBase64, Base64.NO_WRAP)
        val tag = Base64.decode(tagBase64, Base64.NO_WRAP)
        
        val ciphertextWithTag = ciphertext + tag
        
        val secretKey = SecretKeySpec(key, "AES")
        val cipher = Cipher.getInstance(ALGORITHM)
        val parameterSpec = GCMParameterSpec(TAG_LENGTH * 8, iv)
        
        cipher.init(Cipher.DECRYPT_MODE, secretKey, parameterSpec)
        
        val plaintextBytes = cipher.doFinal(ciphertextWithTag)
        return String(plaintextBytes, Charsets.UTF_8)
    }
    
    fun encryptBinary(key: ByteArray, data: ByteArray): ByteArray {
        if (key.size != KEY_LENGTH) {
            throw IllegalArgumentException("Invalid key length")
        }
        
        val iv = generateIV()
        val secretKey = SecretKeySpec(key, "AES")
        val cipher = Cipher.getInstance(ALGORITHM)
        val parameterSpec = GCMParameterSpec(TAG_LENGTH * 8, iv)
        
        cipher.init(Cipher.ENCRYPT_MODE, secretKey, parameterSpec)
        
        val ciphertextWithTag = cipher.doFinal(data)
        
        return iv + ciphertextWithTag
    }
    
    fun decryptBinary(key: ByteArray, encryptedData: ByteArray): ByteArray {
        if (key.size != KEY_LENGTH) {
            throw IllegalArgumentException("Invalid key length")
        }
        
        if (encryptedData.size < IV_LENGTH + TAG_LENGTH) {
            throw IllegalArgumentException("Invalid encrypted data")
        }
        
        val iv = encryptedData.copyOfRange(0, IV_LENGTH)
        val ciphertextWithTag = encryptedData.copyOfRange(IV_LENGTH, encryptedData.size)
        
        val secretKey = SecretKeySpec(key, "AES")
        val cipher = Cipher.getInstance(ALGORITHM)
        val parameterSpec = GCMParameterSpec(TAG_LENGTH * 8, iv)
        
        cipher.init(Cipher.DECRYPT_MODE, secretKey, parameterSpec)
        
        return cipher.doFinal(ciphertextWithTag)
    }
    
    fun keyToBase64(key: ByteArray): String {
        return Base64.encodeToString(key, Base64.NO_WRAP)
    }
    
    fun keyFromBase64(base64String: String): ByteArray? {
        return try {
            Base64.decode(base64String, Base64.NO_WRAP)
        } catch (e: Exception) {
            null
        }
    }
    
    fun hashData(data: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(data)
        return hash.joinToString("") { "%02x".format(it) }
    }
    
    fun generateClientId(): String {
        return UUID.randomUUID().toString().replace("-", "").lowercase()
    }
    
    fun hmac(key: ByteArray, data: String): String {
        val secretKey = SecretKeySpec(key, "HmacSHA256")
        val mac = javax.crypto.Mac.getInstance("HmacSHA256")
        mac.init(secretKey)
        val hmacBytes = mac.doFinal(data.toByteArray(Charsets.UTF_8))
        return hmacBytes.joinToString("") { "%02x".format(it) }
    }
    
    fun generateNonce(): String {
        val nonce = ByteArray(16)
        SecureRandom().nextBytes(nonce)
        return nonce.joinToString("") { "%02x".format(it) }
    }
    
    fun constantTimeCompare(a: String, b: String): Boolean {
        return MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))
    }
}
