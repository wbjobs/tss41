package com.audiopairing.client

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject

data class TrustedDevice(
    val partnerPublicKeyFingerprint: String,
    val partnerDeviceInfo: Map<String, String>,
    val createdAt: Long,
    val lastSeenAt: Long,
    val pairCount: Int
) {
    val displayName: String
        get() = partnerDeviceInfo["model"] 
            ?: partnerPublicKeyFingerprint.take(12)
}

class TrustedDevicesStore(context: Context) : SQLiteOpenHelper(
    context, DATABASE_NAME, null, DATABASE_VERSION
) {
    
    companion object {
        private const val DATABASE_NAME = "trusted_devices.db"
        private const val DATABASE_VERSION = 1
        
        private const val TABLE_NAME = "trusted_devices"
        private const val COLUMN_ID = "id"
        private const val COLUMN_FINGERPRINT = "partner_public_key_fingerprint"
        private const val COLUMN_DEVICE_INFO = "partner_device_info"
        private const val COLUMN_CREATED_AT = "created_at"
        private const val COLUMN_LAST_SEEN = "last_seen_at"
        private const val COLUMN_PAIR_COUNT = "pair_count"
        
        @Volatile
        private var instance: TrustedDevicesStore? = null
        
        fun getInstance(context: Context): TrustedDevicesStore {
            return instance ?: synchronized(this) {
                instance ?: TrustedDevicesStore(context.applicationContext).also { instance = it }
            }
        }
    }
    
    override fun onCreate(db: SQLiteDatabase) {
        val createTableSQL = """
            CREATE TABLE $TABLE_NAME (
                $COLUMN_ID INTEGER PRIMARY KEY AUTOINCREMENT,
                $COLUMN_FINGERPRINT TEXT UNIQUE NOT NULL,
                $COLUMN_DEVICE_INFO TEXT,
                $COLUMN_CREATED_AT REAL NOT NULL,
                $COLUMN_LAST_SEEN REAL NOT NULL,
                $COLUMN_PAIR_COUNT INTEGER DEFAULT 1
            )
        """.trimIndent()
        
        db.execSQL(createTableSQL)
    }
    
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        db.execSQL("DROP TABLE IF EXISTS $TABLE_NAME")
        onCreate(db)
    }
    
    fun addOrUpdateTrustedDevice(
        partnerPublicKeyFingerprint: String,
        partnerDeviceInfo: Map<String, String>
    ) {
        val existing = getTrustedDeviceByFingerprint(partnerPublicKeyFingerprint)
        val now = System.currentTimeMillis()
        
        if (existing != null) {
            val db = writableDatabase
            val values = ContentValues().apply {
                put(COLUMN_LAST_SEEN, now)
                put(COLUMN_PAIR_COUNT, existing.pairCount + 1)
                put(COLUMN_DEVICE_INFO, JSONObject(partnerDeviceInfo).toString())
            }
            
            db.update(
                TABLE_NAME, values,
                "$COLUMN_FINGERPRINT = ?",
                arrayOf(partnerPublicKeyFingerprint)
            )
        } else {
            val db = writableDatabase
            val values = ContentValues().apply {
                put(COLUMN_FINGERPRINT, partnerPublicKeyFingerprint)
                put(COLUMN_DEVICE_INFO, JSONObject(partnerDeviceInfo).toString())
                put(COLUMN_CREATED_AT, now)
                put(COLUMN_LAST_SEEN, now)
                put(COLUMN_PAIR_COUNT, 1)
            }
            
            db.insert(TABLE_NAME, null, values)
        }
    }
    
    fun getTrustedDeviceByFingerprint(fingerprint: String): TrustedDevice? {
        val db = readableDatabase
        val cursor = db.query(
            TABLE_NAME, null,
            "$COLUMN_FINGERPRINT = ?",
            arrayOf(fingerprint),
            null, null, null
        )
        
        return cursor.use {
            if (it.moveToFirst()) {
                cursorToDevice(it)
            } else {
                null
            }
        }
    }
    
    fun getAllTrustedDevices(): List<TrustedDevice> {
        val devices = mutableListOf<TrustedDevice>()
        val db = readableDatabase
        val cursor = db.query(
            TABLE_NAME, null, null, null,
            null, null, "$COLUMN_LAST_SEEN DESC"
        )
        
        cursor.use {
            while (it.moveToNext()) {
                cursorToDevice(it)?.let { device ->
                    devices.add(device)
                }
            }
        }
        
        return devices
    }
    
    fun removeTrustedDevice(partnerPublicKeyFingerprint: String): Boolean {
        val db = writableDatabase
        val rowsAffected = db.delete(
            TABLE_NAME,
            "$COLUMN_FINGERPRINT = ?",
            arrayOf(partnerPublicKeyFingerprint)
        )
        return rowsAffected > 0
    }
    
    fun isTrustedDevice(partnerPublicKeyFingerprint: String): Boolean {
        return getTrustedDeviceByFingerprint(partnerPublicKeyFingerprint) != null
    }
    
    private fun cursorToDevice(cursor: Cursor): TrustedDevice? {
        try {
            val fingerprintIndex = cursor.getColumnIndex(COLUMN_FINGERPRINT)
            val deviceInfoIndex = cursor.getColumnIndex(COLUMN_DEVICE_INFO)
            val createdAtIndex = cursor.getColumnIndex(COLUMN_CREATED_AT)
            val lastSeenIndex = cursor.getColumnIndex(COLUMN_LAST_SEEN)
            val pairCountIndex = cursor.getColumnIndex(COLUMN_PAIR_COUNT)
            
            if (fingerprintIndex < 0) return null
            
            val fingerprint = cursor.getString(fingerprintIndex)
            val deviceInfoJSON = if (deviceInfoIndex >= 0) cursor.getString(deviceInfoIndex) else "{}"
            val createdAt = if (createdAtIndex >= 0) cursor.getLong(createdAtIndex) else 0L
            val lastSeenAt = if (lastSeenIndex >= 0) cursor.getLong(lastSeenIndex) else 0L
            val pairCount = if (pairCountIndex >= 0) cursor.getInt(pairCountIndex) else 1
            
            val deviceInfo = mutableMapOf<String, String>()
            try {
                val json = JSONObject(deviceInfoJSON)
                val keys = json.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    deviceInfo[key] = json.getString(key)
                }
            } catch (e: Exception) {
                // ignore JSON parsing errors
            }
            
            return TrustedDevice(
                partnerPublicKeyFingerprint = fingerprint,
                partnerDeviceInfo = deviceInfo,
                createdAt = createdAt,
                lastSeenAt = lastSeenAt,
                pairCount = pairCount
            )
        } catch (e: Exception) {
            return null
        }
    }
}
