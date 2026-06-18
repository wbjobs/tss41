import Foundation
import AVFoundation
import Accelerate

protocol AudioRecorderDelegate: AnyObject {
    func audioRecorder(_ recorder: AudioRecorder, didReceiveSample sample: Float, at time: TimeInterval)
    func audioRecorder(_ recorder: AudioRecorder, didFinishRecording data: Data, duration: TimeInterval)
    func audioRecorder(_ recorder: AudioRecorder, didFailWithError error: Error)
    func audioRecorderPermissionDidChange(_ granted: Bool)
}

class AudioRecorder: NSObject {
    weak var delegate: AudioRecorderDelegate?
    
    private var audioEngine: AVAudioEngine?
    private var isRecording = false
    private var recordedSamples: [Float] = []
    private var startTime: TimeInterval = 0
    private let sampleRate: Double = 16000.0
    private let recordingDuration: TimeInterval
    
    init(recordingDuration: TimeInterval = 3.0) {
        self.recordingDuration = recordingDuration
        super.init()
    }
    
    func requestPermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.delegate?.audioRecorderPermissionDidChange(granted)
            }
        }
    }
    
    func checkPermission() -> Bool {
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }
    
    func startRecording() throws {
        guard checkPermission() else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission not granted"])
        }
        
        if isRecording {
            stopRecording()
        }
        
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetooth])
        try audioSession.setPreferredSampleRate(sampleRate)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        
        recordedSamples.removeAll()
        startTime = Date.timeIntervalSinceReferenceDate
        isRecording = true
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            guard let self = self, self.isRecording else { return }
            
            let channelData = buffer.floatChannelData?[0]
            let frameCount = Int(buffer.frameLength)
            
            var floatSamples = [Float](repeating: 0, count: frameCount)
            vDSP_vsmul(channelData!, 1, [1.0], &floatSamples, 1, vDSP_Length(frameCount))
            
            self.recordedSamples.append(contentsOf: floatSamples)
            
            let currentTime = Date.timeIntervalSinceReferenceDate - self.startTime
            
            if let sample = floatSamples.last {
                DispatchQueue.main.async {
                    self.delegate?.audioRecorder(self, didReceiveSample: sample, at: currentTime)
                }
            }
            
            if currentTime >= self.recordingDuration {
                DispatchQueue.main.async {
                    self.stopRecording()
                }
            }
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        print("Audio recording started at \(sampleRate) Hz")
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        isRecording = false
        
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        
        let duration = Date.timeIntervalSinceReferenceDate - startTime
        
        var audioData = Data()
        recordedSamples.withUnsafeBufferPointer { buffer in
            audioData.append(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: recordedSamples.count * MemoryLayout<Float>.size)
        }
        
        delegate?.audioRecorder(self, didFinishRecording: audioData, duration: duration)
        
        print("Audio recording stopped. Duration: \(String(format: "%.2f", duration))s, Samples: \(recordedSamples.count)")
    }
    
    func getSampleRate() -> Double {
        return sampleRate
    }
    
    func isCurrentlyRecording() -> Bool {
        return isRecording
    }
}
