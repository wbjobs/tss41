import UIKit
import Foundation

enum PairingState {
    case idle
    case connecting
    case waitingForPartner
    case recording
    case matching
    case paired
    case failed(String)
}

class PairingViewController: UIViewController, AudioRecorderDelegate, WebSocketManagerDelegate {
    
    @IBOutlet weak var waveformView: WaveformView!
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var pairButton: UIButton!
    @IBOutlet weak var cancelButton: UIButton!
    @IBOutlet weak var progressView: UIProgressView!
    @IBOutlet weak var messageTextView: UITextView!
    @IBOutlet weak var messageTextField: UITextField!
    @IBOutlet weak var sendButton: UIButton!
    
    private var audioRecorder: AudioRecorder!
    private var webSocketManager: WebSocketManager!
    private var mfccExtractor: MFCCExtractor!
    
    private var clientId: String?
    private var sessionId: String?
    private var pairingState: PairingState = .idle
    private var aesKey: Data?
    private var partnerId: String?
    private var partnerPlatform: String?
    
    private let serverURL = URL(string: "ws://localhost:8080")!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupDependencies()
        requestMicrophonePermission()
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
    
    private func updateStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = message
        }
    }
    
    private func updatePairingState(_ state: PairingState) {
        pairingState = state
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch state {
            case .idle:
                self.pairButton.isHidden = false
                self.pairButton.setTitle("Start Pairing", for: .normal)
                self.cancelButton.isHidden = true
                self.progressView.isHidden = true
                self.messageTextView.isHidden = true
                self.messageTextField.isHidden = true
                self.sendButton.isHidden = true
                self.waveformView.clear()
                
            case .connecting:
                self.pairButton.isHidden = true
                self.cancelButton.isHidden = false
                self.updateStatus("Connecting to server...")
                
            case .waitingForPartner:
                self.pairButton.isHidden = true
                self.cancelButton.isHidden = false
                self.progressView.isHidden = false
                self.progressView.progress = 0.5
                self.updateStatus("Waiting for partner to join...")
                
            case .recording:
                self.pairButton.isHidden = true
                self.cancelButton.isHidden = false
                self.progressView.isHidden = false
                self.progressView.progress = 0.0
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
                self.messageTextView.isHidden = false
                self.messageTextField.isHidden = false
                self.sendButton.isHidden = false
                self.waveformView.animateSuccess()
                self.updateStatus("Paired successfully!")
                
            case .failed(let reason):
                self.pairButton.isHidden = false
                self.pairButton.setTitle("Try Again", for: .normal)
                self.cancelButton.isHidden = true
                self.progressView.isHidden = true
                self.waveformView.animateFailure()
                self.updateStatus("Pairing failed: \(reason)")
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
        webSocketManager.sendMessage(type: "start_pairing")
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
    
    func audioRecorder(_ recorder: AudioRecorder, didReceiveSample sample: Float, at time: TimeInterval) {
        waveformView.addSample(sample)
        
        let progress = Float(time / 3.0)
        DispatchQueue.main.async { [weak self] in
            self?.progressView.progress = progress
        }
    }
    
    func audioRecorder(_ recorder: AudioRecorder, didFinishRecording data: Data, duration: TimeInterval) {
        updatePairingState(.matching)
        
        let audioBase64 = data.base64EncodedString()
        
        webSocketManager.sendMessage(type: "audio_data", payload: [
            "audioData": audioBase64,
            "sampleRate": 16000,
            "sessionId": sessionId ?? ""
        ])
        
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
        
        webSocketManager.sendMessage(type: "register", payload: [
            "platform": "ios",
            "deviceInfo": deviceInfo
        ])
        
        if pairingState == .connecting {
            webSocketManager.sendMessage(type: "start_pairing")
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
            
        case "session_created":
            sessionId = message["sessionId"] as? String
            updatePairingState(.waitingForPartner)
            
        case "session_joined":
            sessionId = message["sessionId"] as? String
            
        case "partner_joined":
            partnerPlatform = message["partnerPlatform"] as? String
            updateStatus("Partner joined!")
            
        case "start_recording":
            startRecording()
            
        case "audio_received":
            updateStatus("Audio data received by server")
            
        case "partner_audio_received":
            updateStatus("Partner audio received")
            
        case "matching_started":
            updatePairingState(.matching)
            
        case "pairing_success":
            handlePairingSuccess(message)
            
        case "pairing_failed":
            let reason = message["reason"] as? String ?? "Unknown error"
            updatePairingState(.failed(reason))
            
        case "pairing_cancelled":
            updatePairingState(.idle)
            updateStatus("Pairing cancelled")
            
        case "session_timeout":
            updatePairingState(.failed("Session timed out"))
            
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
        
        if let matchScore = message["matchScore"] as? [String: Any] {
            let distance = matchScore["normalized_distance"] as? Double ?? 0
            print("Match score: \(distance)")
        }
        
        updatePairingState(.paired)
        addMessage("Paired with \(partnerPlatform ?? "unknown") device", isEncrypted: false)
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
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        messageTextField.resignFirstResponder()
    }
}
