package com.audiopairing.client

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.RadioButton
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.LinearLayoutManager
import com.audiopairing.client.databinding.ActivityMainBinding
import android.util.Base64

enum class PairingMode {
    AUTO, MASTER, SLAVE
}

sealed class PairingState {
    object Idle : PairingState()
    object Connecting : PairingState()
    object WaitingForPartner : PairingState()
    object WaitingForSlave : PairingState()
    object WaitingFingerprintBroadcast : PairingState()
    object WaitingSlaveFingerprint : PairingState()
    object Recording : PairingState()
    object Matching : PairingState()
    object Paired : PairingState()
    data class Failed(val reason: String) : PairingState()
    object QuickReconnecting : PairingState()
}

class MainActivity : AppCompatActivity(), AudioRecorderListener, WebSocketManagerListener {

    private lateinit var binding: ActivityMainBinding
    
    private lateinit var audioRecorder: AudioRecorder
    private lateinit var webSocketManager: WebSocketManager
    private lateinit var mfccExtractor: MFCCExtractor
    private lateinit var trustedDevicesStore: TrustedDevicesStore
    private lateinit var trustedDevicesAdapter: TrustedDevicesAdapter
    
    private var clientId: String? = null
    private var sessionId: String? = null
    private var pairingState: PairingState = PairingState.Idle
    private var currentMode: PairingMode = PairingMode.AUTO
    private var currentRoomCode: String? = null
    private var aesKey: ByteArray? = null
    private var partnerId: String? = null
    private var partnerPlatform: String? = null
    private var partnerPublicKeyFingerprint: String? = null
    private var trustedDevices: List<TrustedDevice> = emptyList()
    private var isTrustedDevicesVisible = false
    
    private val serverUrl = "ws://10.0.2.2:8080"
    private val REQUEST_RECORD_AUDIO_PERMISSION = 200

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        
        Ed25519KeyStore.init(this)
        
        setupUI()
        setupDependencies()
        requestPermissions()
        loadTrustedDevices()
    }
    
    private fun setupUI() {
        supportActionBar?.title = "Audio Pairing"
        
        binding.modeRadioGroup.setOnCheckedChangeListener { _, checkedId ->
            currentMode = when (checkedId) {
                R.id.radioMaster -> PairingMode.MASTER
                R.id.radioSlave -> PairingMode.SLAVE
                else -> PairingMode.AUTO
            }
            updateModeUI()
        }
        
        binding.pairButton.setOnClickListener {
            startPairing()
        }
        
        binding.cancelButton.setOnClickListener {
            cancelPairing()
        }
        
        binding.sendButton.setOnClickListener {
            sendMessage()
        }
        
        binding.generateRoomCodeButton.setOnClickListener {
            generateRoomCode()
        }
        
        binding.joinRoomButton.setOnClickListener {
            joinRoom()
        }
        
        binding.showTrustedButton.setOnClickListener {
            toggleTrustedDevices()
        }
        
        trustedDevicesAdapter = TrustedDevicesAdapter(
            devices = emptyList(),
            onDeviceClick = { device -> attemptQuickReconnect(device) },
            onDeviceRemove = { device -> removeTrustedDevice(device) }
        )
        
        binding.trustedDevicesRecyclerView.apply {
            layoutManager = LinearLayoutManager(this@MainActivity)
            adapter = trustedDevicesAdapter
        }
        
        binding.root.setOnTouchListener { _, _ ->
            hideKeyboard()
            false
        }
        
        updatePairingState(PairingState.Idle)
        updateStatus("Ready to pair")
    }
    
    private fun updateModeUI() {
        runOnUiThread {
            when (currentMode) {
                PairingMode.AUTO -> {
                    binding.roomCodeContainer.visibility = View.GONE
                    binding.pairButton.visibility = View.VISIBLE
                }
                PairingMode.MASTER -> {
                    binding.roomCodeContainer.visibility = View.VISIBLE
                    binding.roomCodeDisplay.visibility = View.VISIBLE
                    binding.roomCodeInput.visibility = View.GONE
                    binding.generateRoomCodeButton.visibility = View.VISIBLE
                    binding.joinRoomButton.visibility = View.GONE
                    binding.pairButton.visibility = View.GONE
                    binding.roomCodeDisplay.text = "------"
                }
                PairingMode.SLAVE -> {
                    binding.roomCodeContainer.visibility = View.VISIBLE
                    binding.roomCodeDisplay.visibility = View.GONE
                    binding.roomCodeInput.visibility = View.VISIBLE
                    binding.generateRoomCodeButton.visibility = View.GONE
                    binding.joinRoomButton.visibility = View.VISIBLE
                    binding.pairButton.visibility = View.GONE
                    binding.roomCodeInput.text.clear()
                }
            }
        }
    }
    
    private fun setupDependencies() {
        audioRecorder = AudioRecorder(this, 3000)
        audioRecorder.listener = this
        
        mfccExtractor = MFCCExtractor(16000.0)
        
        trustedDevicesStore = TrustedDevicesStore.getInstance(this)
        
        webSocketManager = WebSocketManager(serverUrl)
        webSocketManager.listener = this
        webSocketManager.connect()
    }
    
    private fun loadTrustedDevices() {
        trustedDevices = trustedDevicesStore.getAllTrustedDevices()
        trustedDevicesAdapter.updateDevices(trustedDevices)
        
        runOnUiThread {
            if (trustedDevices.isNotEmpty()) {
                binding.showTrustedButton.visibility = View.VISIBLE
                binding.showTrustedButton.text = "Trusted Devices (${trustedDevices.size})"
            } else {
                binding.showTrustedButton.visibility = View.GONE
            }
        }
    }
    
    private fun toggleTrustedDevices() {
        isTrustedDevicesVisible = !isTrustedDevicesVisible
        binding.trustedDevicesContainer.visibility = if (isTrustedDevicesVisible) View.VISIBLE else View.GONE
    }
    
    private fun removeTrustedDevice(device: TrustedDevice) {
        trustedDevicesStore.removeTrustedDevice(device.partnerPublicKeyFingerprint)
        loadTrustedDevices()
        if (trustedDevices.isEmpty()) {
            isTrustedDevicesVisible = false
            binding.trustedDevicesContainer.visibility = View.GONE
        }
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
                    binding.pairButton.visibility = if (currentMode == PairingMode.AUTO) View.VISIBLE else View.GONE
                    binding.cancelButton.visibility = View.GONE
                    binding.progressBar.visibility = View.GONE
                    binding.messageContainer.visibility = View.GONE
                    binding.waveformView.clear()
                    updateModeUI()
                }
                
                is PairingState.Connecting -> {
                    binding.pairButton.visibility = View.GONE
                    binding.cancelButton.visibility = View.VISIBLE
                    binding.generateRoomCodeButton.visibility = View.GONE
                    binding.joinRoomButton.visibility = View.GONE
                    updateStatus("Connecting to server...")
                }
                
                is PairingState.WaitingForPartner -> {
                    binding.pairButton.visibility = View.GONE
                    binding.cancelButton.visibility = View.VISIBLE
                    binding.progressBar.visibility = View.VISIBLE
                    binding.progressBar.progress = 50
                    updateStatus("Waiting for partner to join...")
                }
                
                is PairingState.WaitingForSlave -> {
                    binding.pairButton.visibility = View.GONE
                    binding.cancelButton.visibility = View.VISIBLE
                    binding.progressBar.visibility = View.VISIBLE
                    binding.progressBar.progress = 30
                    binding.roomCodeDisplay.visibility = View.VISIBLE
                    binding.generateRoomCodeButton.visibility = View.GONE
                    val codeText = currentRoomCode ?: "------"
                    updateStatus("Waiting for slave to join with code: $codeText")
                }
                
                is PairingState.WaitingFingerprintBroadcast -> {
                    binding.pairButton.visibility = View.GONE
                    binding.cancelButton.visibility = View.VISIBLE
                    binding.progressBar.visibility = View.VISIBLE
                    binding.progressBar.progress = 40
                    binding.roomCodeInput.visibility = View.GONE
                    binding.joinRoomButton.visibility = View.GONE
                    updateStatus("Joined room! Waiting for master to broadcast fingerprint...")
                }
                
                is PairingState.WaitingSlaveFingerprint -> {
                    binding.pairButton.visibility = View.GONE
                    binding.cancelButton.visibility = View.VISIBLE
                    binding.progressBar.visibility = View.VISIBLE
                    binding.progressBar.progress = 60
                    updateStatus("Fingerprint broadcasted! Waiting for slave to submit...")
                }
                
                is PairingState.Recording -> {
                    binding.pairButton.visibility = View.GONE
                    binding.cancelButton.visibility = View.VISIBLE
                    binding.progressBar.visibility = View.VISIBLE
                    binding.progressBar.progress = 0
                    binding.roomCodeContainer.visibility = View.GONE
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
                    binding.roomCodeContainer.visibility = View.GONE
                    binding.messageContainer.visibility = View.VISIBLE
                    binding.waveformView.animateSuccess()
                    updateStatus("Paired successfully!")
                }
                
                is PairingState.Failed -> {
                    binding.pairButton.visibility = if (currentMode == PairingMode.AUTO) View.VISIBLE else View.GONE
                    binding.pairButton.text = "Try Again"
                    binding.cancelButton.visibility = View.GONE
                    binding.progressBar.visibility = View.GONE
                    binding.waveformView.animateFailure()
                    updateStatus("Pairing failed: ${state.reason}")
                    updateModeUI()
                }
                
                is PairingState.QuickReconnecting -> {
                    binding.pairButton.visibility = View.GONE
                    binding.cancelButton.visibility = View.VISIBLE
                    binding.progressBar.visibility = View.VISIBLE
                    binding.progressBar.progress = 70
                    updateStatus("Attempting quick reconnect to trusted device...")
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
        webSocketManager.sendMessage("start_pairing", mapOf("mode" to "auto"))
    }
    
    private fun generateRoomCode() {
        if (!webSocketManager.isConnected()) {
            updateStatus("Not connected to server. Reconnecting...")
            webSocketManager.connect()
            return
        }
        
        updatePairingState(PairingState.Connecting)
        webSocketManager.sendMessage("start_pairing", mapOf("mode" to "master"))
    }
    
    private fun joinRoom() {
        if (!webSocketManager.isConnected()) {
            updateStatus("Not connected to server. Reconnecting...")
            webSocketManager.connect()
            return
        }
        
        val code = binding.roomCodeInput.text.toString().trim()
        if (code.length != 6 || code.toIntOrNull() == null) {
            updateStatus("Please enter a valid 6-digit code")
            return
        }
        
        updatePairingState(PairingState.Connecting)
        webSocketManager.sendMessage("join_room", mapOf("roomCode" to code))
    }
    
    private fun attemptQuickReconnect(device: TrustedDevice) {
        if (!webSocketManager.isConnected()) {
            updateStatus("Not connected to server")
            webSocketManager.connect()
            return
        }
        
        updateStatus("Attempting quick reconnect to ${device.displayName}...")
        updatePairingState(PairingState.QuickReconnecting)
        
        val nonce = CryptoUtils.generateNonce()
        val signature = try {
            Base64.encodeToString(
                Ed25519KeyStore.sign(nonce.toByteArray(Charsets.UTF_8)),
                Base64.NO_WRAP
            )
        } catch (e: Exception) {
            ""
        }
        
        webSocketManager.sendMessage("quick_reconnect", mapOf(
            "partnerPublicKeyFingerprint" to device.partnerPublicKeyFingerprint,
            "nonce" to nonce,
            "signature" to signature
        ))
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
        partnerPublicKeyFingerprint = null
        currentRoomCode = null
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
        val audioBase64 = Base64.encodeToString(data, Base64.NO_WRAP)
        
        if (currentMode == PairingMode.MASTER && pairingState == PairingState.Recording) {
            updatePairingState(PairingState.WaitingSlaveFingerprint)
            webSocketManager.sendMessage(
                "broadcast_fingerprint",
                mapOf(
                    "audioData" to audioBase64,
                    "sampleRate" to 16000,
                    "sessionId" to (sessionId ?: "")
                )
            )
        } else if (currentMode == PairingMode.SLAVE && pairingState == PairingState.Recording) {
            updatePairingState(PairingState.Matching)
            webSocketManager.sendMessage(
                "submit_fingerprint",
                mapOf(
                    "audioData" to audioBase64,
                    "sampleRate" to 16000,
                    "sessionId" to (sessionId ?: "")
                )
            )
        } else {
            updatePairingState(PairingState.Matching)
            webSocketManager.sendMessage(
                "audio_data",
                mapOf(
                    "audioData" to audioBase64,
                    "sampleRate" to 16000,
                    "sessionId" to (sessionId ?: "")
                )
            )
        }
        
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
        
        val publicKeyPEM = try {
            Ed25519KeyStore.getPublicKeyPEM()
        } catch (e: Exception) {
            ""
        }
        
        webSocketManager.sendMessage(
            "register",
            mapOf(
                "platform" to "android",
                "deviceInfo" to deviceInfo,
                "publicKey" to publicKeyPEM
            )
        )
        
        if (pairingState == PairingState.Connecting) {
            when (currentMode) {
                PairingMode.AUTO -> webSocketManager.sendMessage("start_pairing", mapOf("mode" to "auto"))
                PairingMode.MASTER -> webSocketManager.sendMessage("start_pairing", mapOf("mode" to "master"))
                else -> {}
            }
        }
        
        attemptAutoQuickReconnect()
    }
    
    private fun attemptAutoQuickReconnect() {
        if (trustedDevices.isNotEmpty() && pairingState == PairingState.Idle) {
            val mostRecent = trustedDevices.firstOrNull()
            if (mostRecent != null) {
                updateStatus("Found trusted device, attempting quick reconnect...")
                updatePairingState(PairingState.QuickReconnecting)
                
                val nonce = CryptoUtils.generateNonce()
                val signature = try {
                    Base64.encodeToString(
                        Ed25519KeyStore.sign(nonce.toByteArray(Charsets.UTF_8)),
                        Base64.NO_WRAP
                    )
                } catch (e: Exception) {
                    ""
                }
                
                webSocketManager.sendMessage("quick_reconnect", mapOf(
                    "partnerPublicKeyFingerprint" to mostRecent.partnerPublicKeyFingerprint,
                    "nonce" to nonce,
                    "signature" to signature
                ))
            }
        }
    }
    
    override fun onDisconnected(error: Exception?) {
        updateStatus("Disconnected from server")
        if (pairingState == PairingState.Paired) {
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
            
            "registered" -> {
                println("Device registered")
            }
            
            "session_created" -> {
                sessionId = message["sessionId"] as? String
                val mode = message["mode"] as? String ?: "auto"
                if (mode == "master_slave") {
                    updatePairingState(PairingState.WaitingForSlave)
                    webSocketManager.sendMessage("generate_room_code")
                } else {
                    updatePairingState(PairingState.WaitingForPartner)
                }
            }
            
            "room_code_generated" -> {
                currentRoomCode = message["roomCode"] as? String
                runOnUiThread {
                    binding.roomCodeDisplay.text = currentRoomCode
                }
                updatePairingState(PairingState.WaitingForSlave)
            }
            
            "master_ready" -> {
                updateStatus("Master ready - waiting for slave")
            }
            
            "session_joined" -> {
                sessionId = message["sessionId"] as? String
                val role = message["role"] as? String
                if (role == "slave") {
                    updatePairingState(PairingState.WaitingFingerprintBroadcast)
                }
            }
            
            "slave_joined" -> {
                updateStatus("Slave joined! Start recording fingerprint...")
                if (!audioRecorder.checkPermission()) {
                    updateStatus("Microphone permission not granted")
                    return
                }
                startRecording()
            }
            
            "partner_joined" -> {
                partnerPlatform = message["partnerPlatform"] as? String
                updateStatus("Partner joined!")
            }
            
            "start_recording" -> {
                startRecording()
            }
            
            "master_fingerprint_broadcasted" -> {
                updateStatus("Master fingerprint broadcasted, start recording...")
                if (!audioRecorder.checkPermission()) {
                    updateStatus("Microphone permission not granted")
                    return
                }
                startRecording()
            }
            
            "fingerprint_broadcasted" -> {
                updatePairingState(PairingState.WaitingSlaveFingerprint)
            }
            
            "fingerprint_submitted" -> {
                updatePairingState(PairingState.Matching)
            }
            
            "slave_fingerprint_received" -> {
                updatePairingState(PairingState.Matching)
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
            
            "quick_reconnect_success" -> {
                handleQuickReconnectSuccess(message)
            }
            
            "quick_reconnect_failed" -> {
                val reason = message["reason"] as? String ?: "Unknown"
                updateStatus("Quick reconnect failed: $reason")
                updatePairingState(PairingState.Idle)
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
            
            "room_code_invalid" -> {
                val reason = message["reason"] as? String ?: "Invalid"
                updatePairingState(PairingState.Failed("Room code invalid: $reason"))
            }
            
            "trusted_devices_list" -> {}
            
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
        partnerPublicKeyFingerprint = message["partnerPublicKeyFingerprint"] as? String
        
        val matchScore = message["matchScore"] as? Map<*, *>
        matchScore?.let {
            val distance = it["normalized_distance"] as? Double ?: 0.0
            println("Match score: $distance")
        }
        
        partnerPublicKeyFingerprint?.let { fingerprint ->
            if (fingerprint.isNotEmpty()) {
                val partnerInfo = mutableMapOf<String, String>()
                val deviceInfo = message["partnerDeviceInfo"] as? Map<*, *>
                deviceInfo?.let { info ->
                    for ((key, value) in info) {
                        partnerInfo[key.toString()] = value.toString()
                    }
                }
                
                trustedDevicesStore.addOrUpdateTrustedDevice(fingerprint, partnerInfo)
                loadTrustedDevices()
            }
        }
        
        updatePairingState(PairingState.Paired)
        addMessage("Paired with ${partnerPlatform ?: "unknown"} device", false)
    }
    
    private fun handleQuickReconnectSuccess(message: Map<String, Any>) {
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
        
        updatePairingState(PairingState.Paired)
        addMessage("Quick reconnect successful with ${partnerPlatform ?: "unknown"} device", false)
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
