import Foundation
import AVFoundation
import Accelerate

protocol AudioRecorderDelegate: AnyObject {
    func audioRecorder(_ recorder: AudioRecorder, didReceiveSample sample: Float, at time: TimeInterval)
    func audioRecorder(_ recorder: AudioRecorder, didFinishRecording data: Data, duration: TimeInterval)
    func audioRecorder(_ recorder: AudioRecorder, didFailWithError error: Error)
    func audioRecorderPermissionDidChange(_ granted: Bool)
    func audioRecorderAGCDidUpdate(_ gain: Float, peak: Float, clippingRatio: Float)
}

class AudioRecorder: NSObject {
    weak var delegate: AudioRecorderDelegate?
    
    private var audioEngine: AVAudioEngine?
    private var isRecording = false
    private var isCalibrating = false
    private var recordedSamples: [Float] = []
    private var startTime: TimeInterval = 0
    private let sampleRate: Double = 16000.0
    private let recordingDuration: TimeInterval
    
    private var currentGain: Float = 1.0
    private let targetPeak: Float = 0.7
    private let maxGain: Float = 2.0
    private let minGain: Float = 0.1
    private let agcSmoothing: Float = 0.3
    
    private var peakLevel: Float = 0.0
    private var clippingSampleCount: Int = 0
    private var totalSampleCount: Int = 0
    private let clippingThreshold: Float = 0.95
    
    private var calibrationDuration: TimeInterval = 0.3
    private var calibrationStartTime: TimeInterval = 0
    private var maxRetries: Int = 3
    private var retryCount: Int = 0
    
    private let compressionThreshold: Float = 0.6
    private let compressionRatio: Float = 4.0
    
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
        
        if isRecording || isCalibrating {
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
        peakLevel = 0.0
        clippingSampleCount = 0
        totalSampleCount = 0
        retryCount = 0
        
        isCalibrating = true
        calibrationStartTime = Date.timeIntervalSinceReferenceDate
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            
            let channelData = buffer.floatChannelData?[0]
            let frameCount = Int(buffer.frameLength)
            
            var floatSamples = [Float](repeating: 0, count: frameCount)
            vDSP_vsmul(channelData!, 1, [1.0], &floatSamples, 1, vDSP_Length(frameCount))
            
            self.processAudioBuffer(&floatSamples, frameCount: frameCount)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        print("Audio calibration started at \(sampleRate) Hz, gain: \(currentGain)")
    }
    
    private func processAudioBuffer(_ samples: inout [Float], frameCount: Int) {
        var bufferPeak: Float = 0.0
        var bufferClippingCount = 0
        
        for i in 0..<frameCount {
            let absSample = abs(samples[i])
            if absSample > bufferPeak {
                bufferPeak = absSample
            }
            if absSample >= clippingThreshold {
                bufferClippingCount += 1
            }
        }
        
        peakLevel = max(peakLevel * 0.95, bufferPeak)
        clippingSampleCount += bufferClippingCount
        totalSampleCount += frameCount
        
        let clippingRatio = Float(clippingSampleCount) / Float(max(totalSampleCount, 1))
        
        updateAGC(peak: peakLevel, clippingRatio: clippingRatio)
        
        DispatchQueue.main.async {
            self.delegate?.audioRecorderAGCDidUpdate(self.currentGain, peak: self.peakLevel, clippingRatio: clippingRatio)
        }
        
        if isCalibrating {
            let calibrationTime = Date.timeIntervalSinceReferenceDate - calibrationStartTime
            
            if calibrationTime >= calibrationDuration {
                let needsRetry = clippingRatio > 0.01 && retryCount < maxRetries
                
                if needsRetry {
                    retryCount += 1
                    currentGain *= 0.7
                    currentGain = max(minGain, currentGain)
                    
                    peakLevel = 0.0
                    clippingSampleCount = 0
                    totalSampleCount = 0
                    calibrationStartTime = Date.timeIntervalSinceReferenceDate
                    
                    print("Calibration retry \(retryCount)/\(maxRetries), adjusting gain to \(currentGain)")
                } else {
                    finishCalibration()
                }
            }
            
            if let sample = samples.last {
                let displaySample = applyCompression(sample * currentGain)
                DispatchQueue.main.async {
                    let calTime = Date.timeIntervalSinceReferenceDate - self.calibrationStartTime
                    self.delegate?.audioRecorder(self, didReceiveSample: displaySample, at: calTime)
                }
            }
            return
        }
        
        var processedSamples = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let gained = samples[i] * currentGain
            let compressed = applyCompression(gained)
            processedSamples[i] = compressed
        }
        
        recordedSamples.append(contentsOf: processedSamples)
        
        let currentTime = Date.timeIntervalSinceReferenceDate - startTime
        
        if let lastSample = processedSamples.last {
            DispatchQueue.main.async {
                self.delegate?.audioRecorder(self, didReceiveSample: lastSample, at: currentTime)
            }
        }
        
        if currentTime >= recordingDuration {
            DispatchQueue.main.async {
                self.stopRecording()
            }
        }
    }
    
    private func updateAGC(peak: Float, clippingRatio: Float) {
        guard isRecording else { return }
        
        var targetGain = currentGain
        
        if clippingRatio > 0.005 {
            targetGain = currentGain * 0.85
        } else if peak > targetPeak * 1.1 {
            targetGain = currentGain * (targetPeak / peak)
        } else if peak < targetPeak * 0.5 {
            targetGain = currentGain * 1.1
        }
        
        currentGain = currentGain + (targetGain - currentGain) * agcSmoothing
        currentGain = min(maxGain, max(minGain, currentGain))
    }
    
    private func applyCompression(_ sample: Float) -> Float {
        let absSample = abs(sample)
        
        if absSample <= compressionThreshold {
            return sample
        }
        
        let overThreshold = absSample - compressionThreshold
        let compressed = compressionThreshold + overThreshold / compressionRatio
        
        return sample > 0 ? compressed : -compressed
    }
    
    private func finishCalibration() {
        isCalibrating = false
        isRecording = true
        recordedSamples.removeAll()
        startTime = Date.timeIntervalSinceReferenceDate
        
        let clippingRatio = Float(clippingSampleCount) / Float(max(totalSampleCount, 1))
        
        print("Calibration finished. Gain: \(String(format: "%.2f", currentGain)), " +
              "Peak: \(String(format: "%.3f", peakLevel)), " +
              "Clipping: \(String(format: "%.2f%%", clippingRatio * 100))")
    }
    
    func stopRecording() {
        guard isRecording || isCalibrating else { return }
        
        let wasRecording = isRecording
        isRecording = false
        isCalibrating = false
        
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        
        if wasRecording {
            let duration = Date.timeIntervalSinceReferenceDate - startTime
            
            var audioData = Data()
            recordedSamples.withUnsafeBufferPointer { buffer in
                audioData.append(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: recordedSamples.count * MemoryLayout<Float>.size)
            }
            
            delegate?.audioRecorder(self, didFinishRecording: audioData, duration: duration)
            
            print("Audio recording stopped. Duration: \(String(format: "%.2f", duration))s, Samples: \(recordedSamples.count)")
        }
    }
    
    func getSampleRate() -> Double {
        return sampleRate
    }
    
    func isCurrentlyRecording() -> Bool {
        return isRecording
    }
    
    func isCurrentlyCalibrating() -> Bool {
        return isCalibrating
    }
    
    func getCurrentGain() -> Float {
        return currentGain
    }
    
    func getPeakLevel() -> Float {
        return peakLevel
    }
    
    func getClippingRatio() -> Float {
        return Float(clippingSampleCount) / Float(max(totalSampleCount, 1))
    }
    
    func setManualGain(_ gain: Float) {
        currentGain = min(maxGain, max(minGain, gain))
    }
    
    func resetGain() {
        currentGain = 1.0
    }
}
