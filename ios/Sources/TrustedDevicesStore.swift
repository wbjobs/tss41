import Foundation
import SQLite3

struct TrustedDevice {
    let partnerPublicKeyFingerprint: String
    let partnerDeviceInfo: [String: String]
    let createdAt: TimeInterval
    let lastSeenAt: TimeInterval
    let pairCount: Int
    
    var displayName: String {
        if let model = partnerDeviceInfo["model"] {
            return model
        }
        return String(partnerPublicKeyFingerprint.prefix(12))
    }
}

enum TrustedStoreError: Error {
    case openDatabaseFailed
    case prepareStatementFailed(String)
    case executeStatementFailed(String)
}

class TrustedDevicesStore {
    static let shared = TrustedDevicesStore()
    
    private var db: OpaquePointer?
    private let dbFileName = "trusted_devices.sqlite3"
    
    private init() {
        do {
            try openDatabase()
            try createTableIfNeeded()
        } catch {
            print("Failed to initialize trusted devices store: \(error)")
        }
    }
    
    private func getDatabasePath() -> String {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let documentsDirectory = paths[0]
        return (documentsDirectory as NSString).appendingPathComponent(dbFileName)
    }
    
    private func openDatabase() throws {
        let dbPath = getDatabasePath()
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            throw TrustedStoreError.openDatabaseFailed
        }
    }
    
    private func createTableIfNeeded() throws {
        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS trusted_devices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            partner_public_key_fingerprint TEXT UNIQUE NOT NULL,
            partner_device_info TEXT,
            created_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            pair_count INTEGER DEFAULT 1
        );
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, createTableSQL, -1, &statement, nil) == SQLITE_OK else {
            throw TrustedStoreError.prepareStatementFailed("create table")
        }
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TrustedStoreError.executeStatementFailed("create table")
        }
    }
    
    func addOrUpdateTrustedDevice(
        partnerPublicKeyFingerprint: String,
        partnerDeviceInfo: [String: String]
    ) throws {
        let existing = try getTrustedDevice(byFingerprint: partnerPublicKeyFingerprint)
        
        if var device = existing {
            let newPairCount = device.pairCount + 1
            let now = Date().timeIntervalSince1970
            
            let updateSQL = """
            UPDATE trusted_devices 
            SET last_seen_at = ?, pair_count = ?, partner_device_info = ?
            WHERE partner_public_key_fingerprint = ?
            """
            
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &statement, nil) == SQLITE_OK else {
                throw TrustedStoreError.prepareStatementFailed("update device")
            }
            defer { sqlite3_finalize(statement) }
            
            let deviceInfoData = try JSONSerialization.data(withJSONObject: partnerDeviceInfo)
            let deviceInfoJSON = String(data: deviceInfoData, encoding: .utf8) ?? "{}"
            
            sqlite3_bind_double(statement, 1, now)
            sqlite3_bind_int(statement, 2, Int32(newPairCount))
            sqlite3_bind_text(statement, 3, (deviceInfoJSON as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (partnerPublicKeyFingerprint as NSString).utf8String, -1, nil)
            
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TrustedStoreError.executeStatementFailed("update device")
            }
        } else {
            let insertSQL = """
            INSERT INTO trusted_devices 
            (partner_public_key_fingerprint, partner_device_info, created_at, last_seen_at, pair_count)
            VALUES (?, ?, ?, ?, 1)
            """
            
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
                throw TrustedStoreError.prepareStatementFailed("insert device")
            }
            defer { sqlite3_finalize(statement) }
            
            let deviceInfoData = try JSONSerialization.data(withJSONObject: partnerDeviceInfo)
            let deviceInfoJSON = String(data: deviceInfoData, encoding: .utf8) ?? "{}"
            let now = Date().timeIntervalSince1970
            
            sqlite3_bind_text(statement, 1, (partnerPublicKeyFingerprint as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (deviceInfoJSON as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 3, now)
            sqlite3_bind_double(statement, 4, now)
            
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TrustedStoreError.executeStatementFailed("insert device")
            }
        }
    }
    
    func getTrustedDevice(byFingerprint fingerprint: String) throws -> TrustedDevice? {
        let querySQL = """
        SELECT partner_public_key_fingerprint, partner_device_info, created_at, last_seen_at, pair_count
        FROM trusted_devices
        WHERE partner_public_key_fingerprint = ?
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK else {
            throw TrustedStoreError.prepareStatementFailed("query device")
        }
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, (fingerprint as NSString).utf8String, -1, nil)
        
        if sqlite3_step(statement) == SQLITE_ROW {
            return rowToDevice(statement: statement)
        }
        return nil
    }
    
    func getAllTrustedDevices() throws -> [TrustedDevice] {
        let querySQL = """
        SELECT partner_public_key_fingerprint, partner_device_info, created_at, last_seen_at, pair_count
        FROM trusted_devices
        ORDER BY last_seen_at DESC
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK else {
            throw TrustedStoreError.prepareStatementFailed("query all devices")
        }
        defer { sqlite3_finalize(statement) }
        
        var devices: [TrustedDevice] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let device = rowToDevice(statement: statement) {
                devices.append(device)
            }
        }
        return devices
    }
    
    func removeTrustedDevice(partnerPublicKeyFingerprint: String) throws {
        let deleteSQL = """
        DELETE FROM trusted_devices WHERE partner_public_key_fingerprint = ?
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK else {
            throw TrustedStoreError.prepareStatementFailed("delete device")
        }
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, (partnerPublicKeyFingerprint as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TrustedStoreError.executeStatementFailed("delete device")
        }
    }
    
    func isTrustedDevice(partnerPublicKeyFingerprint: String) -> Bool {
        do {
            return try getTrustedDevice(byFingerprint: partnerPublicKeyFingerprint) != nil
        } catch {
            return false
        }
    }
    
    private func rowToDevice(statement: OpaquePointer?) -> TrustedDevice? {
        guard let statement = statement else { return nil }
        
        guard let fingerprintCStr = sqlite3_column_text(statement, 0),
              let deviceInfoCStr = sqlite3_column_text(statement, 1) else {
            return nil
        }
        
        let fingerprint = String(cString: fingerprintCStr)
        let deviceInfoJSON = String(cString: deviceInfoCStr)
        let createdAt = sqlite3_column_double(statement, 2)
        let lastSeenAt = sqlite3_column_double(statement, 3)
        let pairCount = Int(sqlite3_column_int(statement, 4))
        
        var deviceInfo: [String: String] = [:]
        if let data = deviceInfoJSON.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            deviceInfo = dict
        }
        
        return TrustedDevice(
            partnerPublicKeyFingerprint: fingerprint,
            partnerDeviceInfo: deviceInfo,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            pairCount: pairCount
        )
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
}
