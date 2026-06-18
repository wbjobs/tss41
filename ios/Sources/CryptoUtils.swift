import Foundation
import CryptoKit

enum CryptoError: Error {
    case invalidKey
    case encryptionFailed
    case decryptionFailed
    case invalidData
}

class CryptoUtils {
    static let algorithm = "aes-256-gcm"
    static let keyLength = 32
    static let ivLength = 12
    
    static func generateAESKey() -> Data {
        var keyData = Data(count: keyLength)
        let result = keyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, keyLength, $0.baseAddress!)
        }
        assert(result == errSecSuccess, "Failed to generate random key")
        return keyData
    }
    
    static func generateIV() -> Data {
        var ivData = Data(count: ivLength)
        let result = ivData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, ivLength, $0.baseAddress!)
        }
        assert(result == errSecSuccess, "Failed to generate random IV")
        return ivData
    }
    
    static func encrypt(key: Data, plaintext: String) throws -> [String: String] {
        guard key.count == keyLength else {
            throw CryptoError.invalidKey
        }
        
        let iv = generateIV()
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealedBox = try AES.GCM.seal(plaintext.data(using: .utf8)!, using: SymmetricKey(data: key), nonce: nonce)
        
        guard let ciphertext = sealedBox.ciphertext.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let tag = sealedBox.tag.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw CryptoError.encryptionFailed
        }
        
        return [
            "encrypted": ciphertext,
            "iv": iv.base64EncodedString(),
            "authTag": tag
        ]
    }
    
    static func decrypt(key: Data, encryptedData: [String: String]) throws -> String {
        guard key.count == keyLength,
              let encryptedBase64 = encryptedData["encrypted"],
              let ivBase64 = encryptedData["iv"],
              let tagBase64 = encryptedData["authTag"],
              let encrypted = Data(base64Encoded: encryptedBase64.removingPercentEncoding ?? encryptedBase64),
              let iv = Data(base64Encoded: ivBase64),
              let tag = Data(base64Encoded: tagBase64.removingPercentEncoding ?? tagBase64) else {
            throw CryptoError.invalidData
        }
        
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encrypted, tag: tag)
        let decryptedData = try AES.GCM.open(sealedBox, using: SymmetricKey(data: key))
        
        guard let plaintext = String(data: decryptedData, encoding: .utf8) else {
            throw CryptoError.decryptionFailed
        }
        
        return plaintext
    }
    
    static func encryptBinary(key: Data, data: Data) throws -> Data {
        guard key.count == keyLength else {
            throw CryptoError.invalidKey
        }
        
        let iv = generateIV()
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealedBox = try AES.GCM.seal(data, using: SymmetricKey(data: key), nonce: nonce)
        
        var result = Data()
        result.append(iv)
        result.append(sealedBox.tag)
        result.append(sealedBox.ciphertext)
        
        return result
    }
    
    static func decryptBinary(key: Data, encryptedData: Data) throws -> Data {
        guard key.count == keyLength,
              encryptedData.count > ivLength + 16 else {
            throw CryptoError.invalidData
        }
        
        let iv = encryptedData.prefix(ivLength)
        let tag = encryptedData.dropFirst(ivLength).prefix(16)
        let ciphertext = encryptedData.dropFirst(ivLength + 16)
        
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let decryptedData = try AES.GCM.open(sealedBox, using: SymmetricKey(data: key))
        
        return decryptedData
    }
    
    static func keyToBase64(_ key: Data) -> String {
        return key.base64EncodedString()
    }
    
    static func keyFromBase64(_ base64String: String) -> Data? {
        return Data(base64Encoded: base64String)
    }
    
    static func hashData(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    static func generateClientId() -> String {
        let uuid = UUID().uuidString
        return uuid.replacingOccurrences(of: "-", with: "").lowercased()
    }
    
    static func hmac(key: Data, data: String) -> String {
        let key = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: data.data(using: .utf8)!, using: key)
        return Data(signature).map { String(format: "%02hhx", $0) }.joined()
    }
    
    static func generateNonce() -> String {
        var nonceData = Data(count: 16)
        let _ = nonceData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        return nonceData.map { String(format: "%02hhx", $0) }.joined()
    }
}
