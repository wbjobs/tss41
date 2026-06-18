package com.audiopairing.client

import android.os.Handler
import android.os.Looper
import com.google.gson.Gson
import com.google.gson.JsonObject
import org.java_websocket.client.WebSocketClient
import org.java_websocket.handshake.ServerHandshake
import java.net.URI
import java.nio.ByteBuffer

interface WebSocketManagerListener {
    fun onConnected()
    fun onDisconnected(error: Exception?)
    fun onMessageReceived(message: Map<String, Any>)
    fun onError(error: Exception)
}

class WebSocketManager(private val serverUrl: String) {
    
    private var webSocketClient: WebSocketClient? = null
    private val gson = Gson()
    private val handler = Handler(Looper.getMainLooper())
    private var isConnected = false
    private var reconnectAttempts = 0
    private val maxReconnectAttempts = 5
    private val reconnectDelay: Long = 2000
    
    var listener: WebSocketManagerListener? = null
    
    fun connect() {
        val uri = URI.create(serverUrl)
        
        webSocketClient = object : WebSocketClient(uri) {
            override fun onOpen(handshakedata: ServerHandshake?) {
                isConnected = true
                reconnectAttempts = 0
                println("WebSocket connected")
                handler.post {
                    listener?.onConnected()
                }
            }
            
            override fun onMessage(message: String?) {
                message?.let {
                    try {
                        val jsonObject = gson.fromJson(it, JsonObject::class.java)
                        val messageMap = jsonObjectToMap(jsonObject)
                        handler.post {
                            listener?.onMessageReceived(messageMap)
                        }
                    } catch (e: Exception) {
                        println("Error parsing message: ${e.message}")
                    }
                }
            }
            
            override fun onMessage(bytes: ByteBuffer?) {
                bytes?.let {
                    try {
                        val jsonString = String(it.array())
                        val jsonObject = gson.fromJson(jsonString, JsonObject::class.java)
                        val messageMap = jsonObjectToMap(jsonObject)
                        handler.post {
                            listener?.onMessageReceived(messageMap)
                        }
                    } catch (e: Exception) {
                        println("Error parsing binary message: ${e.message}")
                    }
                }
            }
            
            override fun onClose(code: Int, reason: String?, remote: Boolean) {
                isConnected = false
                println("WebSocket disconnected: $reason, code: $code")
                handler.post {
                    listener?.onDisconnected(null)
                }
                attemptReconnect()
            }
            
            override fun onError(ex: Exception?) {
                isConnected = false
                println("WebSocket error: ${ex?.message}")
                handler.post {
                    ex?.let { listener?.onError(it) }
                }
                attemptReconnect()
            }
        }
        
        webSocketClient?.connect()
    }
    
    fun disconnect() {
        webSocketClient?.close()
        webSocketClient = null
        isConnected = false
    }
    
    fun sendMessage(type: String, payload: Map<String, Any> = emptyMap()) {
        if (!isConnected) {
            println("WebSocket not connected, cannot send message")
            return
        }
        
        val message = mutableMapOf<String, Any>()
        message["type"] = type
        message.putAll(payload)
        
        try {
            val json = gson.toJson(message)
            webSocketClient?.send(json)
        } catch (e: Exception) {
            println("Error sending message: ${e.message}")
            listener?.onError(e)
        }
    }
    
    fun sendEncryptedMessage(encryptedData: Map<String, Any>) {
        sendMessage("send_encrypted", encryptedData)
    }
    
    fun sendHeartbeat() {
        sendMessage("heartbeat", mapOf("timestamp" to System.currentTimeMillis() / 1000.0))
    }
    
    fun isConnected(): Boolean = isConnected
    
    private fun jsonObjectToMap(jsonObject: JsonObject): Map<String, Any> {
        val map = mutableMapOf<String, Any>()
        val entrySet = jsonObject.entrySet()
        
        for (entry in entrySet) {
            val key = entry.key
            val value = entry.value
            
            when {
                value.isJsonObject -> map[key] = jsonObjectToMap(value.asJsonObject)
                value.isJsonArray -> map[key] = jsonArrayToList(value.asJsonArray)
                value.isJsonPrimitive -> {
                    val primitive = value.asJsonPrimitive
                    when {
                        primitive.isBoolean -> map[key] = primitive.asBoolean
                        primitive.isNumber -> map[key] = primitive.asNumber
                        primitive.isString -> map[key] = primitive.asString
                        else -> map[key] = primitive.asString
                    }
                }
                value.isJsonNull -> map[key] = Any()
            }
        }
        
        return map
    }
    
    private fun jsonArrayToList(jsonArray: com.google.gson.JsonArray): List<Any> {
        val list = mutableListOf<Any>()
        for (element in jsonArray) {
            when {
                element.isJsonObject -> list.add(jsonObjectToMap(element.asJsonObject))
                element.isJsonArray -> list.add(jsonArrayToList(element.asJsonArray))
                element.isJsonPrimitive -> {
                    val primitive = element.asJsonPrimitive
                    when {
                        primitive.isBoolean -> list.add(primitive.asBoolean)
                        primitive.isNumber -> list.add(primitive.asNumber)
                        primitive.isString -> list.add(primitive.asString)
                        else -> list.add(primitive.asString)
                    }
                }
                element.isJsonNull -> list.add(Any())
            }
        }
        return list
    }
    
    private fun attemptReconnect() {
        if (reconnectAttempts >= maxReconnectAttempts) {
            println("Max reconnect attempts reached")
            return
        }
        
        reconnectAttempts++
        println("Attempting reconnect $reconnectAttempts/$maxReconnectAttempts")
        
        handler.postDelayed({
            connect()
        }, reconnectDelay)
    }
}
