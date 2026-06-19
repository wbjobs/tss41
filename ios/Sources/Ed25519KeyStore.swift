import Foundation
import CryptoKit

enum KeyStoreError: Error {
    case keyGenerationFailed
    case keyConversionFailed
    case invalidKeyData
}

@available(iOS 13.0, *)
class Ed25519KeyStore {
    static let shared = Ed25519KeyStore()
    
    private let privateKeyTag = "com.audiopairing.client.privateKey"
    private var cachedKeyPair: Curve25519.KeyAgreement.PrivateKey?
    
    private init() {
        loadOrGenerateKeyPair()
    }
    
    private func loadOrGenerateKeyPair() {
        if let existing = loadPrivateKey() {
            cachedKeyPair = existing
        } else {
            cachedKeyPair = Curve25519.KeyAgreement.PrivateKey()
            savePrivateKey(cachedKeyPair!)
        }
    }
    
    func getPrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        if cachedKeyPair == nil {
            loadOrGenerateKeyPair()
        }
        return cachedKeyPair!
    }
    
    func getPublicKey() -> Curve25519.KeyAgreement.PublicKey {
        return getPrivateKey().publicKey
    }
    
    func getPublicKeyPEM() -> String {
        let publicKey = getPublicKey()
        let rawBytes = publicKey.rawRepresentation
        let base64 = rawBytes.base64EncodedString()
        var pem = "-----BEGIN PUBLIC KEY-----\n"
        let lines = stride(from: 0, to: base64.count, by: 64).map { index -> String in
            let start = base64.index(base64.startIndex, offsetBy: index)
            let end = base64.index(start, offsetBy: min(64, base64.count - index))
            return String(base64[start..<end])
        }
        pem += lines.joined(separator: "\n")
        pem += "\n-----END PUBLIC KEY-----\n"
        return pem
    }
    
    func getPublicKeyFingerprint() -> String {
        let pem = getPublicKeyPEM()
        return CryptoUtils.hashData(pem.data(using: .utf8)!)
    }
    
    private func savePrivateKey(_ privateKey: Curve25519.KeyAgreement.PrivateKey) {
        let keyData = privateKey.rawRepresentation
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: privateKeyTag,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("Failed to save private key to Keychain: \(status)")
        }
    }
    
    private func loadPrivateKey() -> Curve25519.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: privateKeyTag,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var data: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &data)
        
        guard status == errSecSuccess,
              let keyData = data as? Data else {
            return nil
        }
        
        do {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
        } catch {
            print("Failed to load private key: \(error)")
            return nil
        }
    }
    
    func sign(data: Data) throws -> Data {
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: getPrivateKey().rawRepresentation)
        return try signingKey.signature(for: data)
    }
}
