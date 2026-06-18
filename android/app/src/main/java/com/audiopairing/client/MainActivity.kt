package com.audiopairing.client

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.audiopairing.client.databinding.ActivityMainBinding

sealed class PairingState {
    object Idle : PairingState()
    object Connecting : PairingState()
    object WaitingForPartner : PairingState()
    object Recording : PairingState()
    object Matching : PairingState()
    object Paired : PairingState()
    data class Failed(val reason: String) : PairingState()
}

class MainActivity : AppCompatActivity(), AudioRecorderListener, WebSocketManagerListener {

    private lateinit var binding: ActivityMainBinding
    
    private lateinit var audioRecorder: AudioRecorder
    private lateinit var webSocketManager: WebSocketManager
    private lateinit var mfccExtractor: MFCCExtractor
    
    private var clientId: String? = null
    private var sessionId: String? = null
    private var pairingState: PairingState = PairingState.Idle
    private var aesKey: ByteArray? = null
    private var partnerId: String? = null
    private var partnerPlatform: String? = null
    
    private val serverUrl = "ws://10.0.2.2:8080"
    private val REQUEST_RECORD_AUDIO_PERMISSION = 200

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        
        setupUI()
        setupDependencies()
        requestPermissions()
    }
    
    private fun setupUI() {
        supportActionBar?.title = "Audio Pairing"
        
        binding.pairButton.setOnClickListener {
            startPairing()
        }
        
        binding.cancelButton.setOnClickListener {
            cancelPairing()
        }
        
        binding.sendButton.setOnClickListener {
            sendMessage()
        }
        
        binding.root.setOnTouchListener { _, _ ->
            hideKeyboard()
            false
        }
        
        updatePairingState(PairingState.Idle)
        updateStatus("Ready to pair")
    }
    
    private fun setupDependencies() {
        audioRecorder = AudioRecorder(this, 3000)
        audioRecorder.listener = this
        
        mfccExtractor = MFCCExtractor(16000.0)
        
        webSocketManager = WebSocketManager(serverUrl)
        webSocketManager.listener = this
        webSocketManager.connect()
    }
    
    private fun requestPermissions() {
        val permissions = mutableListOf<String>()
        
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) 
            != PackageManager.PERMISSION_GRANTED) {
            permissions.add(Manifest.permission.RECORD_AUDIO)
        }
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
                permissions.add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        
        if (permissions.isNotEmpty()) {
            ActivityCompat.requestPermissions(
                this,
                permissions.toTypedArray(),
                REQUEST_RECORD_AUDIO_PERMISSION
            )
        } else {
            audioRecorder.requestPermission()
        }
    }
    
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        
        when (requestCode) {
            REQUEST_RECORD_AUDIO_PERMISSION -> {
                val granted = grantResults.isNotEmpty() && 
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
                audioRecorder.listener?.onPermissionChanged(granted)
                
                if (!granted) {
                    updateStatus("Microphone permission denied. Please enable it in Settings.")
                }
            }
        }
    }
    
    private fun updateStatus(message: String) {
        runOnUiThread {
            binding.statusText.text = message
        }
    }
    
    private fun updatePairingState(state: PairingState) {
        pairingState = state
        
        runOnUiThread {
            when (state) {
                is PairingState.Idle -> {
                    binding.pairButton.visibility = View.VISIBLE
                    binding.pairButton.text = "Start Pairing"
                    binding.cancelButton.visibility = View.GONE
                    binding.progressBar.visibility = View.GONE
                    binding.messageContainer.visibility = View.GONE
                    binding.waveformView.clear()
                }
                
                is PairingState.Connecting -> {
                    binding.pairButton.visibility = View.GONE
                    binding.cancelButton.visibility = View.VISIBLE
                    updateStatus("Connecting to server...")
                }
                
                is PairingState.WaitingForPartner -> {
                    binding.pairButton.visibility = View.GONE
                    binding.cancelButton.visibility = View.VISIBLE
                    binding.progressBar.visibility = View.VISIBLE
                    binding.progressBar.progress = 50
                    updateStatus("Waiting for partner to join...")
                }
                
                is PairingState.Recording -> {
                    binding.pairButton.visibility = View.GONE
                    binding.cancelButton.visibility = View.VISIBLE
                    binding.progressBar.visibility = View.VISIBLE
                    binding.progressBar.progress = 0
                    updateStatus("Recording ambient noise...")
                }
                
                is PairingState.Matching -> {
                    binding.pairButton.visibility = View.GONE
                    binding.cancelButton.visibility = View.GONE
                    binding.progressBar.visibility = View.VISIBLE
                    binding.progressBar.progress = 80
                    updateStatus("Matching audio fingerprints...")
                }
                
                is PairingState.Paired -> {
                    binding.pairButton.visibility = View.GONE
                    binding.cancelButton.visibility = View.GONE
                    binding.progressBar.visibility = View.GONE
                    binding.messageContainer.visibility = View.VISIBLE
                    binding.waveformView.animateSuccess()
                    updateStatus("Paired successfully!")
                }
                
                is PairingState.Failed -> {
                    binding.pairButton.visibility = View.VISIBLE
                    binding.pairButton.text = "Try Again"
                    binding.cancelButton.visibility = View.GONE
                    binding.progressBar.visibility = View.GONE
                    binding.waveformView.animateFailure()
                    updateStatus("Pairing failed: ${state.reason}")
                }
            }
        }
    }
    
    private fun startPairing() {
        if (!webSocketManager.isConnected()) {
            updateStatus("Not connected to server. Reconnecting...")
            webSocketManager.connect()
            return
        }
        
        if (!audioRecorder.checkPermission()) {
            updateStatus("Microphone permission not granted")
            requestPermissions()
            return
        }
        
        updatePairingState(PairingState.Connecting)
        webSocketManager.sendMessage("start_pairing")
    }
    
    private fun cancelPairing() {
        if (audioRecorder.isRecording()) {
            audioRecorder.stopRecording()
        }
        
        sessionId?.let {
            webSocketManager.sendMessage("cancel_pairing", mapOf("sessionId" to it))
        }
        
        updatePairingState(PairingState.Idle)
        sessionId = null
        aesKey = null
        partnerId = null
        partnerPlatform = null
    }
    
    private fun sendMessage() {
        val message = binding.messageInput.text.toString().trim()
        if (message.isEmpty() || aesKey == null) return
        
        try {
            val encryptedData = CryptoUtils.encrypt(aesKey!!, message)
            
            webSocketManager.sendEncryptedMessage(mapOf(
                "encryptedData" to encryptedData
            ))
            
            addMessage("You: $message", true)
            binding.messageInput.text.clear()
            
        } catch (e: Exception) {
            updateStatus("Failed to encrypt message: ${e.message}")
        }
    }
    
    private fun addMessage(text: String, isEncrypted: Boolean) {
        runOnUiThread {
            val prefix = if (isEncrypted) "🔒 " else ""
            binding.messagesText.append("$prefix$text\n")
            
            val scrollAmount = binding.messagesText.layout.getLineTop(
                binding.messagesText.lineCount
            ) - binding.messagesText.height
            
            if (scrollAmount > 0) {
                binding.messagesText.scrollTo(0, scrollAmount)
            }
        }
    }
    
    private fun startRecording() {
        try {
            updatePairingState(PairingState.Recording)
            binding.waveformView.clear()
            audioRecorder.startRecording()
        } catch (e: Exception) {
            updatePairingState(PairingState.Failed("Failed to start recording: ${e.message}"))
        }
    }
    
    private fun hideKeyboard() {
        val inputMethodManager = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
        currentFocus?.let { view ->
            inputMethodManager.hideSoftInputFromWindow(view.windowToken, 0)
        }
    }
    
    override fun onSampleReceived(sample: Float, time: Double) {
        binding.waveformView.addSample(sample)
        
        val progress = (time / 3.0 * 100).toInt()
        runOnUiThread {
            binding.progressBar.progress = progress
        }
    }
    
    override fun onRecordingFinished(data: ByteArray, duration: Double) {
        updatePairingState(PairingState.Matching)
        
        val audioBase64 = android.util.Base64.encodeToString(data, android.util.Base64.NO_WRAP)
        
        webSocketManager.sendMessage(
            "audio_data",
            mapOf(
                "audioData" to audioBase64,
                "sampleRate" to 16000,
                "sessionId" to (sessionId ?: "")
            )
        )
        
        updateStatus("Sending audio data to server...")
    }
    
    override fun onError(error: String) {
        updatePairingState(PairingState.Failed(error))
    }
    
    override fun onPermissionChanged(granted: Boolean) {
        if (granted) {
            updateStatus("Microphone permission granted")
        } else {
            updateStatus("Microphone permission denied. Please enable it in Settings.")
        }
    }
    
    override fun onConnected() {
        updateStatus("Connected to server")
        
        val deviceInfo = mapOf(
            "model" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "systemName" to "Android",
            "systemVersion" to Build.VERSION.RELEASE
        )
        
        webSocketManager.sendMessage(
            "register",
            mapOf(
                "platform" to "android",
                "deviceInfo" to deviceInfo
            )
        )
        
        if (pairingState is PairingState.Connecting) {
            webSocketManager.sendMessage("start_pairing")
        }
    }
    
    override fun onDisconnected(error: Exception?) {
        updateStatus("Disconnected from server")
        if (pairingState is PairingState.Paired) {
            updatePairingState(PairingState.Failed("Connection lost"))
        }
    }
    
    override fun onMessageReceived(message: Map<String, Any>) {
        val type = message["type"] as? String ?: return
        
        println("Received message: $type")
        
        when (type) {
            "connected" -> {
                clientId = message["clientId"] as? String
            }
            
            "session_created" -> {
                sessionId = message["sessionId"] as? String
                updatePairingState(PairingState.WaitingForPartner)
            }
            
            "session_joined" -> {
                sessionId = message["sessionId"] as? String
            }
            
            "partner_joined" -> {
                partnerPlatform = message["partnerPlatform"] as? String
                updateStatus("Partner joined!")
            }
            
            "start_recording" -> {
                startRecording()
            }
            
            "audio_received" -> {
                updateStatus("Audio data received by server")
            }
            
            "partner_audio_received" -> {
                updateStatus("Partner audio received")
            }
            
            "matching_started" -> {
                updatePairingState(PairingState.Matching)
            }
            
            "pairing_success" -> {
                handlePairingSuccess(message)
            }
            
            "pairing_failed" -> {
                val reason = message["reason"] as? String ?: "Unknown error"
                updatePairingState(PairingState.Failed(reason))
            }
            
            "pairing_cancelled" -> {
                updatePairingState(PairingState.Idle)
                updateStatus("Pairing cancelled")
            }
            
            "session_timeout" -> {
                updatePairingState(PairingState.Failed("Session timed out"))
            }
            
            "encrypted_message" -> {
                handleEncryptedMessage(message)
            }
            
            "message_delivered" -> {
                println("Message delivered")
            }
            
            "partner_disconnected" -> {
                updateStatus("Partner disconnected")
                updatePairingState(PairingState.Failed("Partner disconnected"))
            }
            
            "error" -> {
                val errorMessage = message["message"] as? String ?: "Unknown error"
                updateStatus("Error: $errorMessage")
            }
            
            else -> {
                println("Unhandled message type: $type")
            }
        }
    }
    
    override fun onError(error: Exception) {
        updateStatus("WebSocket error: ${error.message}")
    }
    
    private fun handlePairingSuccess(message: Map<String, Any>) {
        val aesKeyBase64 = message["aesKey"] as? String
        val key = aesKeyBase64?.let { CryptoUtils.keyFromBase64(it) }
        
        if (key == null) {
            updatePairingState(PairingState.Failed("Invalid encryption key received"))
            return
        }
        
        aesKey = key
        partnerId = message["partnerId"] as? String
        partnerPlatform = message["partnerPlatform"] as? String
        sessionId = message["sessionId"] as? String
        
        val matchScore = message["matchScore"] as? Map<*, *>
        matchScore?.let {
            val distance = it["normalized_distance"] as? Double ?: 0.0
            println("Match score: $distance")
        }
        
        updatePairingState(PairingState.Paired)
        addMessage("Paired with ${partnerPlatform ?: "unknown"} device", false)
    }
    
    private fun handleEncryptedMessage(message: Map<String, Any>) {
        val key = aesKey ?: return
        val encryptedData = message["encryptedData"] as? Map<*, *> ?: return
        
        try {
            @Suppress("UNCHECKED_CAST")
            val encryptedMap = encryptedData as Map<String, String>
            val plaintext = CryptoUtils.decrypt(key, encryptedMap)
            addMessage("Partner: $plaintext", true)
        } catch (e: Exception) {
            addMessage("Failed to decrypt message", false)
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        if (audioRecorder.isRecording()) {
            audioRecorder.stopRecording()
        }
        webSocketManager.disconnect()
    }
    
    override fun onBackPressed() {
        if (pairingState !is PairingState.Idle && pairingState !is PairingState.Failed) {
            cancelPairing()
        } else {
            super.onBackPressed()
        }
    }
}
