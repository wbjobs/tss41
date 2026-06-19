import UIKit
import Foundation

enum PairingMode {
    case auto
    case master
    case slave
}

enum PairingState {
    case idle
    case connecting
    case waitingForPartner
    case waitingForSlave
    case waitingFingerprintBroadcast
    case waitingSlaveFingerprint
    case recording
    case matching
    case paired
    case failed(String)
    case quickReconnecting
}

class PairingViewController: UIViewController, AudioRecorderDelegate, WebSocketManagerDelegate, UITableViewDataSource, UITableViewDelegate {
    
    @IBOutlet weak var waveformView: WaveformView!
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var pairButton: UIButton!
    @IBOutlet weak var cancelButton: UIButton!
    @IBOutlet weak var progressView: UIProgressView!
    @IBOutlet weak var messageTextView: UITextView!
    @IBOutlet weak var messageTextField: UITextField!
    @IBOutlet weak var sendButton: UIButton!
    
    @IBOutlet weak var modeControl: UISegmentedControl!
    @IBOutlet weak var roomCodeContainer: UIView!
    @IBOutlet weak var roomCodeLabel: UILabel!
    @IBOutlet weak var roomCodeInput: UITextField!
    @IBOutlet weak var joinRoomButton: UIButton!
    @IBOutlet weak var generateRoomCodeButton: UIButton!
    
    @IBOutlet weak var trustedDevicesContainer: UIView!
    @IBOutlet weak var trustedDevicesTableView: UITableView!
    @IBOutlet weak var trustedDevicesLabel: UILabel!
    @IBOutlet weak var showTrustedButton: UIButton!
    
    private var audioRecorder: AudioRecorder!
    private var webSocketManager: WebSocketManager!
    private var mfccExtractor: MFCCExtractor!
    
    private var clientId: String?
    private var sessionId: String?
    private var pairingState: PairingState = .idle
    private var currentMode: PairingMode = .auto
    private var currentRoomCode: String?
    private var aesKey: Data?
    private var partnerId: String?
    private var partnerPlatform: String?
    private var partnerPublicKeyFingerprint: String?
    private var trustedDevices: [TrustedDevice] = []
    private var isTrustedDevicesVisible = false
    
    private let serverURL = URL(string: "ws://localhost:8080")!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupDependencies()
        requestMicrophonePermission()
        loadTrustedDevices()
    }
    
    private func setupUI() {
        title = "Audio Pairing"
        view.backgroundColor = .systemBackground
        
        pairButton.layer.cornerRadius = 12
        pairButton.backgroundColor = .systemBlue
        pairButton.setTitleColor(.white, for: .normal)
        
        cancelButton.layer.cornerRadius = 12
        cancelButton.backgroundColor = .systemGray4
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.isHidden = true
        
        sendButton.layer.cornerRadius = 8
        sendButton.backgroundColor = .systemGreen
        sendButton.setTitleColor(.white, for: .normal)
        
        progressView.progress = 0
        progressView.isHidden = true
        
        messageTextView.layer.borderColor = UIColor.systemGray4.cgColor
        messageTextView.layer.borderWidth = 1
        messageTextView.layer.cornerRadius = 8
        messageTextView.isEditable = false
        messageTextView.isHidden = true
        
        messageTextField.layer.borderColor = UIColor.systemGray4.cgColor
        messageTextField.layer.borderWidth = 1
        messageTextField.layer.cornerRadius = 8
        messageTextField.isHidden = true
        sendButton.isHidden = true
        
        modeControl.insertSegment(withTitle: "Auto", at: 0, animated: false)
        modeControl.insertSegment(withTitle: "Master", at: 1, animated: false)
        modeControl.insertSegment(withTitle: "Slave", at: 2, animated: false)
        modeControl.selectedSegmentIndex = 0
        modeControl.addTarget(self, action: #selector(modeChanged(_:)), for: .valueChanged)
        
        roomCodeContainer.layer.cornerRadius = 12
        roomCodeContainer.backgroundColor = .secondarySystemBackground
        roomCodeContainer.isHidden = true
        
        roomCodeLabel.font = UIFont.monospacedSystemFont(ofSize: 36, weight: .bold)
        roomCodeLabel.textAlignment = .center
        roomCodeLabel.textColor = .systemBlue
        roomCodeLabel.isHidden = true
        
        roomCodeInput.layer.borderColor = UIColor.systemGray4.cgColor
        roomCodeInput.layer.borderWidth = 1
        roomCodeInput.layer.cornerRadius = 8
        roomCodeInput.keyboardType = .numberPad
        roomCodeInput.placeholder = "Enter 6-digit code"
        roomCodeInput.textAlignment = .center
        roomCodeInput.font = UIFont.monospacedSystemFont(ofSize: 24, weight: .medium)
        roomCodeInput.isHidden = true
        
        generateRoomCodeButton.layer.cornerRadius = 8
        generateRoomCodeButton.backgroundColor = .systemIndigo
        generateRoomCodeButton.setTitleColor(.white, for: .normal)
        generateRoomCodeButton.setTitle("Generate Room Code", for: .normal)
        generateRoomCodeButton.isHidden = true
        generateRoomCodeButton.addTarget(self, action: #selector(generateRoomCodeTapped(_:)), for: .touchUpInside)
        
        joinRoomButton.layer.cornerRadius = 8
        joinRoomButton.backgroundColor = .systemPurple
        joinRoomButton.setTitleColor(.white, for: .normal)
        joinRoomButton.setTitle("Join Room", for: .normal)
        joinRoomButton.isHidden = true
        joinRoomButton.addTarget(self, action: #selector(joinRoomTapped(_:)), for: .touchUpInside)
        
        trustedDevicesContainer.isHidden = true
        trustedDevicesTableView.dataSource = self
        trustedDevicesTableView.delegate = self
        trustedDevicesTableView.register(UITableViewCell.self, forCellReuseIdentifier: "TrustedDeviceCell")
        trustedDevicesTableView.layer.cornerRadius = 8
        
        showTrustedButton.layer.cornerRadius = 8
        showTrustedButton.backgroundColor = .systemTeal
        showTrustedButton.setTitleColor(.white, for: .normal)
        showTrustedButton.addTarget(self, action: #selector(toggleTrustedDevices(_:)), for: .touchUpInside)
        
        updateStatus("Ready to pair")
    }
    
    private func setupDependencies() {
        audioRecorder = AudioRecorder(recordingDuration: 3.0)
        audioRecorder.delegate = self
        
        mfccExtractor = MFCCExtractor(sampleRate: 16000.0)
        
        webSocketManager = WebSocketManager(url: serverURL)
        webSocketManager.delegate = self
        webSocketManager.connect()
    }
    
    private func requestMicrophonePermission() {
        audioRecorder.requestPermission()
    }
    
    private func loadTrustedDevices() {
        do {
            trustedDevices = try TrustedDevicesStore.shared.getAllTrustedDevices()
            DispatchQueue.main.async { [weak self] in
                self?.trustedDevicesTableView.reloadData()
                if self?.trustedDevices.isEmpty == false {
                    self?.showTrustedButton.isHidden = false
                    self?.showTrustedButton.setTitle("Trusted Devices (\(self?.trustedDevices.count ?? 0))", for: .normal)
                }
            }
        } catch {
            print("Failed to load trusted devices: \(error)")
        }
    }
    
    private func updateStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = message
        }
    }
    
    @objc private func modeChanged(_ sender: UISegmentedControl) {
        switch sender.selectedSegmentIndex {
        case 0:
            currentMode = .auto
            roomCodeContainer.isHidden = true
            pairButton.isHidden = false
            pairButton.setTitle("Start Pairing", for: .normal)
        case 1:
            currentMode = .master
            roomCodeContainer.isHidden = false
            roomCodeLabel.isHidden = false
            roomCodeInput.isHidden = true
            generateRoomCodeButton.isHidden = false
            joinRoomButton.isHidden = true
            pairButton.isHidden = true
        case 2:
            currentMode = .slave
            roomCodeContainer.isHidden = false
            roomCodeLabel.isHidden = true
            roomCodeInput.isHidden = false
            generateRoomCodeButton.isHidden = true
            joinRoomButton.isHidden = false
            pairButton.isHidden = true
        default:
            break
        }
    }
    
    @objc private func toggleTrustedDevices(_ sender: UIButton) {
        isTrustedDevicesVisible.toggle()
        trustedDevicesContainer.isHidden = !isTrustedDevicesVisible
    }
    
    @objc private func generateRoomCodeTapped(_ sender: UIButton) {
        guard webSocketManager.isCurrentlyConnected() else {
            updateStatus("Not connected to server. Reconnecting...")
            webSocketManager.connect()
            return
        }
        
        updatePairingState(.connecting)
        webSocketManager.sendMessage(type: "start_pairing", payload: ["mode": "master"])
    }
    
    @objc private func joinRoomTapped(_ sender: UIButton) {
        guard webSocketManager.isCurrentlyConnected() else {
            updateStatus("Not connected to server. Reconnecting...")
            webSocketManager.connect()
            return
        }
        
        guard let code = roomCodeInput.text, code.count == 6, Int(code) != nil else {
            updateStatus("Please enter a valid 6-digit code")
            return
        }
        
        updatePairingState(.connecting)
        webSocketManager.sendMessage(type: "join_room", payload: ["roomCode": code])
    }
    
    private func updatePairingState(_ state: PairingState) {
        pairingState = state
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch state {
            case .idle:
                self.pairButton.isHidden = self.currentMode != .auto
                self.cancelButton.isHidden = true
                self.progressView.isHidden = true
                self.messageTextView.isHidden = true
                self.messageTextField.isHidden = true
                self.sendButton.isHidden = true
                self.waveformView.clear()
                self.roomCodeContainer.isHidden = self.currentMode == .auto
                if self.currentMode == .master {
                    self.roomCodeLabel.isHidden = false
                    self.generateRoomCodeButton.isHidden = false
                    self.roomCodeLabel.text = "------"
                } else if self.currentMode == .slave {
                    self.roomCodeInput.isHidden = false
                    self.joinRoomButton.isHidden = false
                    self.roomCodeInput.text = ""
                }
                
            case .connecting:
                self.pairButton.isHidden = true
                self.cancelButton.isHidden = false
                self.generateRoomCodeButton.isHidden = true
                self.joinRoomButton.isHidden = true
                self.updateStatus("Connecting to server...")
                
            case .waitingForPartner:
                self.pairButton.isHidden = true
                self.cancelButton.isHidden = false
                self.progressView.isHidden = false
                self.progressView.progress = 0.5
                self.updateStatus("Waiting for partner to join...")
                
            case .waitingForSlave:
                self.pairButton.isHidden = true
                self.cancelButton.isHidden = false
                self.progressView.isHidden = false
                self.progressView.progress = 0.3
                self.roomCodeLabel.isHidden = false
                self.generateRoomCodeButton.isHidden = true
                self.updateStatus("Waiting for slave to join with code: \(self.currentRoomCode ?? "")")
                
            case .waitingFingerprintBroadcast:
                self.pairButton.isHidden = true
                self.cancelButton.isHidden = false
                self.progressView.isHidden = false
                self.progressView.progress = 0.4
                self.roomCodeInput.isHidden = true
                self.joinRoomButton.isHidden = true
                self.updateStatus("Joined room! Waiting for master to broadcast fingerprint...")
                
            case .waitingSlaveFingerprint:
                self.pairButton.isHidden = true
                self.cancelButton.isHidden = false
                self.progressView.isHidden = false
                self.progressView.progress = 0.6
                self.updateStatus("Fingerprint broadcasted! Waiting for slave to submit...")
                
            case .recording:
                self.pairButton.isHidden = true
                self.cancelButton.isHidden = false
                self.progressView.isHidden = false
                self.progressView.progress = 0.0
                self.roomCodeContainer.isHidden = true
                self.updateStatus("Recording ambient noise...")
                
            case .matching:
                self.pairButton.isHidden = true
                self.cancelButton.isHidden = true
                self.progressView.isHidden = false
                self.progressView.progress = 0.8
                self.updateStatus("Matching audio fingerprints...")
                
            case .paired:
                self.pairButton.isHidden = true
                self.cancelButton.isHidden = true
                self.progressView.isHidden = true
                self.roomCodeContainer.isHidden = true
                self.messageTextView.isHidden = false
                self.messageTextField.isHidden = false
                self.sendButton.isHidden = false
                self.waveformView.animateSuccess()
                self.updateStatus("Paired successfully!")
                
            case .failed(let reason):
                self.pairButton.isHidden = self.currentMode != .auto
                self.pairButton.setTitle("Try Again", for: .normal)
                self.cancelButton.isHidden = true
                self.progressView.isHidden = true
                self.waveformView.animateFailure()
                self.updateStatus("Pairing failed: \(reason)")
                self.roomCodeContainer.isHidden = self.currentMode == .auto
                if self.currentMode == .master {
                    self.roomCodeLabel.isHidden = false
                    self.generateRoomCodeButton.isHidden = false
                } else if self.currentMode == .slave {
                    self.roomCodeInput.isHidden = false
                    self.joinRoomButton.isHidden = false
                }
                
            case .quickReconnecting:
                self.pairButton.isHidden = true
                self.cancelButton.isHidden = false
                self.progressView.isHidden = false
                self.progressView.progress = 0.7
                self.updateStatus("Attempting quick reconnect to trusted device...")
            }
        }
    }
    
    @IBAction func startPairingTapped(_ sender: UIButton) {
        guard webSocketManager.isCurrentlyConnected() else {
            updateStatus("Not connected to server. Reconnecting...")
            webSocketManager.connect()
            return
        }
        
        guard audioRecorder.checkPermission() else {
            updateStatus("Microphone permission not granted")
            requestMicrophonePermission()
            return
        }
        
        updatePairingState(.connecting)
        webSocketManager.sendMessage(type: "start_pairing", payload: ["mode": "auto"])
    }
    
    @IBAction func cancelTapped(_ sender: UIButton) {
        if audioRecorder.isCurrentlyRecording() {
            audioRecorder.stopRecording()
        }
        
        if let sessionId = sessionId {
            webSocketManager.sendMessage(type: "cancel_pairing", payload: ["sessionId": sessionId])
        }
        
        updatePairingState(.idle)
        sessionId = nil
        aesKey = nil
        partnerId = nil
        partnerPlatform = nil
        partnerPublicKeyFingerprint = nil
        currentRoomCode = nil
    }
    
    @IBAction func sendMessageTapped(_ sender: UIButton) {
        guard let message = messageTextField.text, !message.isEmpty,
              let aesKey = aesKey else { return }
        
        do {
            let encryptedData = try CryptoUtils.encrypt(key: aesKey, plaintext: message)
            
            webSocketManager.sendEncryptedMessage(encryptedData: [
                "encryptedData": encryptedData
            ])
            
            addMessage("You: \(message)", isEncrypted: true)
            messageTextField.text = ""
            
        } catch {
            updateStatus("Failed to encrypt message: \(error.localizedDescription)")
        }
    }
    
    private func addMessage(_ text: String, isEncrypted: Bool) {
        DispatchQueue.main.async { [weak self] in
            let prefix = isEncrypted ? "🔒 " : ""
            self?.messageTextView.text += "\(prefix)\(text)\n"
            
            let range = NSMakeRange((self?.messageTextView.text.count ?? 0) - 1, 1)
            self?.messageTextView.scrollRangeToVisible(range)
        }
    }
    
    private func startRecording() {
        do {
            updatePairingState(.recording)
            waveformView.clear()
            try audioRecorder.startRecording()
        } catch {
            updatePairingState(.failed("Failed to start recording: \(error.localizedDescription)"))
        }
    }
    
    private func sendAudioDataAsMaster() {
        do {
            updatePairingState(.recording)
            waveformView.clear()
            try audioRecorder.startRecording()
        } catch {
            updatePairingState(.failed("Failed to start recording: \(error.localizedDescription)"))
        }
    }
    
    private func sendAudioDataAsSlave() {
        do {
            updatePairingState(.recording)
            waveformView.clear()
            try audioRecorder.startRecording()
        } catch {
            updatePairingState(.failed("Failed to start recording: \(error.localizedDescription)"))
        }
    }
    
    func audioRecorder(_ recorder: AudioRecorder, didReceiveSample sample: Float, at time: TimeInterval) {
        waveformView.addSample(sample)
        
        let progress = Float(time / 3.0)
        DispatchQueue.main.async { [weak self] in
            self?.progressView.progress = progress
        }
    }
    
    func audioRecorder(_ recorder: AudioRecorder, didFinishRecording data: Data, duration: TimeInterval) {
        let audioBase64 = data.base64EncodedString()
        
        if currentMode == .master, pairingState == .recording {
            updatePairingState(.waitingSlaveFingerprint)
            webSocketManager.sendMessage(type: "broadcast_fingerprint", payload: [
                "audioData": audioBase64,
                "sampleRate": 16000,
                "sessionId": sessionId ?? ""
            ])
        } else if currentMode == .slave, pairingState == .recording {
            updatePairingState(.matching)
            webSocketManager.sendMessage(type: "submit_fingerprint", payload: [
                "audioData": audioBase64,
                "sampleRate": 16000,
                "sessionId": sessionId ?? ""
            ])
        } else {
            updatePairingState(.matching)
            webSocketManager.sendMessage(type: "audio_data", payload: [
                "audioData": audioBase64,
                "sampleRate": 16000,
                "sessionId": sessionId ?? ""
            ])
        }
        
        updateStatus("Sending audio data to server...")
    }
    
    func audioRecorder(_ recorder: AudioRecorder, didFailWithError error: Error) {
        updatePairingState(.failed(error.localizedDescription))
    }
    
    func audioRecorderPermissionDidChange(_ granted: Bool) {
        if granted {
            updateStatus("Microphone permission granted")
        } else {
            updateStatus("Microphone permission denied. Please enable it in Settings.")
        }
    }
    
    func webSocketDidConnect(_ manager: WebSocketManager) {
        updateStatus("Connected to server")
        
        let deviceInfo: [String: Any] = [
            "model": UIDevice.current.model,
            "systemName": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion
        ]
        
        let publicKeyPEM: String
        if #available(iOS 13.0, *) {
            publicKeyPEM = Ed25519KeyStore.shared.getPublicKeyPEM()
        } else {
            publicKeyPEM = ""
        }
        
        webSocketManager.sendMessage(type: "register", payload: [
            "platform": "ios",
            "deviceInfo": deviceInfo,
            "publicKey": publicKeyPEM
        ])
        
        if pairingState == .connecting {
            if currentMode == .auto {
                webSocketManager.sendMessage(type: "start_pairing", payload: ["mode": "auto"])
            } else if currentMode == .master {
                webSocketManager.sendMessage(type: "start_pairing", payload: ["mode": "master"])
            }
        }
        
        attemptQuickReconnectIfAvailable()
    }
    
    private func attemptQuickReconnectIfAvailable() {
        guard trustedDevices.count > 0, pairingState == .idle else { return }
        
        let mostRecent = trustedDevices.first
        if let device = mostRecent {
            updateStatus("Found trusted device, attempting quick reconnect...")
            updatePairingState(.quickReconnecting)
            
            if #available(iOS 13.0, *) {
                let nonce = CryptoUtils.generateNonce()
                let signature = try? Ed25519KeyStore.shared.sign(data: nonce.data(using: .utf8)!)
                
                webSocketManager.sendMessage(type: "quick_reconnect", payload: [
                    "partnerPublicKeyFingerprint": device.partnerPublicKeyFingerprint,
                    "nonce": nonce,
                    "signature": signature?.base64EncodedString() ?? ""
                ])
            }
        }
    }
    
    func webSocketDidDisconnect(_ manager: WebSocketManager, error: Error?) {
        updateStatus("Disconnected from server")
        if case .paired = pairingState {
            updatePairingState(.failed("Connection lost"))
        }
    }
    
    func webSocket(_ manager: WebSocketManager, didReceiveMessage message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        
        print("Received message: \(type)")
        
        switch type {
        case "connected":
            clientId = message["clientId"] as? String
            
        case "registered":
            print("Device registered")
            
        case "session_created":
            sessionId = message["sessionId"] as? String
            let mode = message["mode"] as? String ?? "auto"
            if mode == "master_slave" {
                updatePairingState(.waitingForSlave)
                webSocketManager.sendMessage(type: "generate_room_code")
            } else {
                updatePairingState(.waitingForPartner)
            }
            
        case "room_code_generated":
            currentRoomCode = message["roomCode"] as? String
            DispatchQueue.main.async { [weak self] in
                self?.roomCodeLabel.text = self?.currentRoomCode
            }
            updatePairingState(.waitingForSlave)
            
        case "master_ready":
            updateStatus("Master ready - waiting for slave")
            
        case "session_joined":
            sessionId = message["sessionId"] as? String
            let role = message["role"] as? String
            if role == "slave" {
                updatePairingState(.waitingFingerprintBroadcast)
            }
            
        case "slave_joined":
            updateStatus("Slave joined! Start recording fingerprint...")
            guard audioRecorder.checkPermission() else {
                updateStatus("Microphone permission not granted")
                return
            }
            sendAudioDataAsMaster()
            
        case "partner_joined":
            partnerPlatform = message["partnerPlatform"] as? String
            updateStatus("Partner joined!")
            
        case "start_recording":
            startRecording()
            
        case "master_fingerprint_broadcasted":
            updateStatus("Master fingerprint broadcasted, start recording...")
            guard audioRecorder.checkPermission() else {
                updateStatus("Microphone permission not granted")
                return
            }
            sendAudioDataAsSlave()
            
        case "fingerprint_broadcasted":
            updatePairingState(.waitingSlaveFingerprint)
            
        case "fingerprint_submitted":
            updatePairingState(.matching)
            
        case "slave_fingerprint_received":
            updatePairingState(.matching)
            
        case "audio_received":
            updateStatus("Audio data received by server")
            
        case "partner_audio_received":
            updateStatus("Partner audio received")
            
        case "matching_started":
            updatePairingState(.matching)
            
        case "pairing_success":
            handlePairingSuccess(message)
            
        case "quick_reconnect_success":
            handleQuickReconnectSuccess(message)
            
        case "quick_reconnect_failed":
            let reason = message["reason"] as? String ?? "Unknown"
            updateStatus("Quick reconnect failed: \(reason)")
            updatePairingState(.idle)
            
        case "pairing_failed":
            let reason = message["reason"] as? String ?? "Unknown error"
            updatePairingState(.failed(reason))
            
        case "pairing_cancelled":
            updatePairingState(.idle)
            updateStatus("Pairing cancelled")
            
        case "session_timeout":
            updatePairingState(.failed("Session timed out"))
            
        case "room_code_invalid":
            let reason = message["reason"] as? String ?? "Invalid"
            updatePairingState(.failed("Room code invalid: \(reason)"))
            
        case "trusted_devices_list":
            break
            
        case "encrypted_message":
            handleEncryptedMessage(message)
            
        case "message_delivered":
            print("Message delivered")
            
        case "partner_disconnected":
            updateStatus("Partner disconnected")
            updatePairingState(.failed("Partner disconnected"))
            
        case "error":
            let errorMessage = message["message"] as? String ?? "Unknown error"
            updateStatus("Error: \(errorMessage)")
            
        default:
            print("Unhandled message type: \(type)")
        }
    }
    
    func webSocket(_ manager: WebSocketManager, didReceiveError error: Error) {
        updateStatus("WebSocket error: \(error.localizedDescription)")
    }
    
    private func handlePairingSuccess(_ message: [String: Any]) {
        guard let aesKeyBase64 = message["aesKey"] as? String,
              let aesKey = CryptoUtils.keyFromBase64(aesKeyBase64) else {
            updatePairingState(.failed("Invalid encryption key received"))
            return
        }
        
        self.aesKey = aesKey
        self.partnerId = message["partnerId"] as? String
        self.partnerPlatform = message["partnerPlatform"] as? String
        self.sessionId = message["sessionId"] as? String
        self.partnerPublicKeyFingerprint = message["partnerPublicKeyFingerprint"] as? String
        
        if let matchScore = message["matchScore"] as? [String: Any] {
            let distance = matchScore["normalized_distance"] as? Double ?? 0
            print("Match score: \(distance)")
        }
        
        if let partnerFingerprint = partnerPublicKeyFingerprint,
           !partnerFingerprint.isEmpty {
            var partnerInfo: [String: String] = [:]
            if let deviceInfo = message["partnerDeviceInfo"] as? [String: Any] {
                for (key, value) in deviceInfo {
                    partnerInfo[key] = "\(value)"
                }
            }
            
            do {
                try TrustedDevicesStore.shared.addOrUpdateTrustedDevice(
                    partnerPublicKeyFingerprint: partnerFingerprint,
                    partnerDeviceInfo: partnerInfo
                )
                loadTrustedDevices()
            } catch {
                print("Failed to save trusted device: \(error)")
            }
        }
        
        updatePairingState(.paired)
        addMessage("Paired with \(partnerPlatform ?? "unknown") device", isEncrypted: false)
    }
    
    private func handleQuickReconnectSuccess(_ message: [String: Any]) {
        guard let aesKeyBase64 = message["aesKey"] as? String,
              let aesKey = CryptoUtils.keyFromBase64(aesKeyBase64) else {
            updatePairingState(.failed("Invalid encryption key received"))
            return
        }
        
        self.aesKey = aesKey
        self.partnerId = message["partnerId"] as? String
        self.partnerPlatform = message["partnerPlatform"] as? String
        self.sessionId = message["sessionId"] as? String
        
        updatePairingState(.paired)
        addMessage("Quick reconnect successful with \(partnerPlatform ?? "unknown") device", isEncrypted: false)
    }
    
    private func handleEncryptedMessage(_ message: [String: Any]) {
        guard let aesKey = aesKey,
              let encryptedData = message["encryptedData"] as? [String: String] else {
            return
        }
        
        do {
            let plaintext = try CryptoUtils.decrypt(key: aesKey, encryptedData: encryptedData)
            addMessage("Partner: \(plaintext)", isEncrypted: true)
        } catch {
            addMessage("Failed to decrypt message", isEncrypted: false)
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return trustedDevices.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "TrustedDeviceCell", for: indexPath)
        let device = trustedDevices[indexPath.row]
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let lastSeen = dateFormatter.string(from: Date(timeIntervalSince1970: device.lastSeenAt))
        
        cell.textLabel?.text = device.displayName
        cell.detailTextLabel?.text = "Paired \(device.pairCount)x • Last seen: \(lastSeen)"
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let device = trustedDevices[indexPath.row]
        guard webSocketManager.isCurrentlyConnected() else {
            updateStatus("Not connected to server")
            webSocketManager.connect()
            return
        }
        
        updateStatus("Attempting quick reconnect to \(device.displayName)...")
        updatePairingState(.quickReconnecting)
        
        if #available(iOS 13.0, *) {
            let nonce = CryptoUtils.generateNonce()
            let signature = try? Ed25519KeyStore.shared.sign(data: nonce.data(using: .utf8)!)
            
            webSocketManager.sendMessage(type: "quick_reconnect", payload: [
                "partnerPublicKeyFingerprint": device.partnerPublicKeyFingerprint,
                "nonce": nonce,
                "signature": signature?.base64EncodedString() ?? ""
            ])
        }
    }
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let deleteAction = UIContextualAction(style: .destructive, title: "Remove") { [weak self] (_, _, completionHandler) in
            guard let self = self else { return }
            let device = self.trustedDevices[indexPath.row]
            do {
                try TrustedDevicesStore.shared.removeTrustedDevice(partnerPublicKeyFingerprint: device.partnerPublicKeyFingerprint)
                self.trustedDevices.remove(at: indexPath.row)
                tableView.deleteRows(at: [indexPath], with: .fade)
                self.showTrustedButton.setTitle("Trusted Devices (\(self.trustedDevices.count))", for: .normal)
                if self.trustedDevices.isEmpty {
                    self.showTrustedButton.isHidden = true
                    self.isTrustedDevicesVisible = false
                    self.trustedDevicesContainer.isHidden = true
                }
            } catch {
                self.updateStatus("Failed to remove trusted device")
            }
            completionHandler(true)
        }
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        messageTextField.resignFirstResponder()
        roomCodeInput.resignFirstResponder()
    }
}
