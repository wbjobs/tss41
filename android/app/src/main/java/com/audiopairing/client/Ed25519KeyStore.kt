package com.audiopairing.client

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.*
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher

object Ed25519KeyStore {
    
    private const val KEY_ALIAS = "audiopairing_ed25519_key"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    
    private var cachedKeyPair: KeyPair? = null
    
    fun init(context: Context) {
        loadOrGenerateKeyPair(context)
    }
    
    private fun loadOrGenerateKeyPair(context: Context) {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE)
        keyStore.load(null)
        
        if (keyStore.containsAlias(KEY_ALIAS)) {
            val privateKey = keyStore.getKey(KEY_ALIAS, null) as PrivateKey
            val publicKey = keyStore.getCertificate(KEY_ALIAS).publicKey
            cachedKeyPair = KeyPair(publicKey, privateKey)
        } else {
            val keyPairGenerator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC,
                ANDROID_KEYSTORE
            )
            
            val spec = KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
            )
                .setAlgorithmParameterSpec(
                    java.security.spec.ECGenParameterSpec("secp256r1")
                )
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setUserAuthenticationRequired(false)
                .build()
            
            keyPairGenerator.initialize(spec)
            cachedKeyPair = keyPairGenerator.generateKeyPair()
        }
    }
    
    fun getPublicKey(): PublicKey {
        return cachedKeyPair?.public 
            ?: throw IllegalStateException("KeyStore not initialized")
    }
    
    fun getPrivateKey(): PrivateKey {
        return cachedKeyPair?.private 
            ?: throw IllegalStateException("KeyStore not initialized")
    }
    
    fun getPublicKeyPEM(): String {
        val publicKey = getPublicKey()
        val encoded = publicKey.encoded
        val base64 = Base64.encodeToString(encoded, Base64.NO_WRAP)
        
        val pem = StringBuilder()
        pem.append("-----BEGIN PUBLIC KEY-----\n")
        
        var i = 0
        while (i < base64.length) {
            pem.append(base64.substring(i, minOf(i + 64, base64.length)))
            pem.append("\n")
            i += 64
        }
        
        pem.append("-----END PUBLIC KEY-----\n")
        return pem.toString()
    }
    
    fun getPublicKeyFingerprint(): String {
        val pem = getPublicKeyPEM()
        return CryptoUtils.hashData(pem.toByteArray(Charsets.UTF_8))
    }
    
    fun sign(data: ByteArray): ByteArray {
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(getPrivateKey())
        signature.update(data)
        return signature.sign()
    }
    
    fun verify(data: ByteArray, signatureBytes: ByteArray): Boolean {
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initVerify(getPublicKey())
        signature.update(data)
        return signature.verify(signatureBytes)
    }
}
