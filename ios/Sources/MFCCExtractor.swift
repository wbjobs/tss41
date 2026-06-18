import Foundation
import Accelerate

class MFCCExtractor {
    private let sampleRate: Double
    private let numCepstralCoefficients: Int
    private let numFilters: Int
    private let frameSize: Int
    private let frameStride: Int
    private let fftSize: Int
    private let preEmphasisCoeff: Double = 0.97
    
    init(sampleRate: Double = 16000.0,
         numCepstralCoefficients: Int = 13,
         numFilters: Int = 40,
         frameSizeMs: Double = 25.0,
         frameStrideMs: Double = 10.0,
         fftSize: Int = 512) {
        self.sampleRate = sampleRate
        self.numCepstralCoefficients = numCepstralCoefficients
        self.numFilters = numFilters
        self.frameSize = Int(frameSizeMs * sampleRate / 1000.0)
        self.frameStride = Int(frameStrideMs * sampleRate / 1000.0)
        self.fftSize = fftSize
    }
    
    func extractMFCC(from audioData: [Float]) -> [[Double]] {
        let signal = preEmphasis(signal: audioData.map { Double($0) })
        let frames = framing(signal: signal)
        let windowedFrames = applyHammingWindow(frames: frames)
        let powerSpectra = computePowerSpectrum(frames: windowedFrames)
        let filterBanks = applyMelFilterBank(powerSpectra: powerSpectra)
        let mfcc = computeDCT(filterBanks: filterBanks)
        
        return normalizeMFCC(mfcc: mfcc)
    }
    
    private func preEmphasis(signal: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: signal.count)
        result[0] = signal[0]
        
        for i in 1..<signal.count {
            result[i] = signal[i] - preEmphasisCoeff * signal[i - 1]
        }
        
        return result
    }
    
    private func framing(signal: [Double]) -> [[Double]] {
        let signalLength = signal.count
        let numFrames = Int(ceil(Double(signalLength - frameSize) / Double(frameStride))) + 1
        
        let paddedLength = (numFrames - 1) * frameStride + frameSize
        var paddedSignal = signal
        if paddedLength > signalLength {
            paddedSignal.append(contentsOf: [Double](repeating: 0, count: paddedLength - signalLength))
        }
        
        var frames = [[Double]](repeating: [Double](repeating: 0, count: frameSize), count: numFrames)
        
        for i in 0..<numFrames {
            let start = i * frameStride
            for j in 0..<frameSize {
                frames[i][j] = paddedSignal[start + j]
            }
        }
        
        return frames
    }
    
    private func applyHammingWindow(frames: [[Double]]) -> [[Double]] {
        var window = [Double](repeating: 0, count: frameSize)
        for i in 0..<frameSize {
            window[i] = 0.54 - 0.46 * cos(2.0 * Double.pi * Double(i) / Double(frameSize - 1))
        }
        
        var windowedFrames = [[Double]](repeating: [Double](repeating: 0, count: frameSize), count: frames.count)
        
        for i in 0..<frames.count {
            for j in 0..<frameSize {
                windowedFrames[i][j] = frames[i][j] * window[j]
            }
        }
        
        return windowedFrames
    }
    
    private func computePowerSpectrum(frames: [[Double]]) -> [[Double]] {
        let numBins = fftSize / 2 + 1
        var powerSpectra = [[Double]](repeating: [Double](repeating: 0, count: numBins), count: frames.count)
        
        for frameIndex in 0..<frames.count {
            var frame = frames[frameIndex]
            
            if frame.count < fftSize {
                frame.append(contentsOf: [Double](repeating: 0, count: fftSize - frame.count))
            }
            
            var fftInput = [Double](repeating: 0, count: fftSize * 2)
            for i in 0..<fftSize {
                fftInput[i * 2] = frame[i]
                fftInput[i * 2 + 1] = 0
            }
            
            var fftOutput = fftInput
            var fftLength = vDSP_Length(log2(Double(fftSize)))
            var direction = Int32(FFT_FORWARD)
            
            fftOutput.withUnsafeMutableBufferPointer { outputPtr in
                fftInput.withUnsafeMutableBufferPointer { inputPtr in
                    vDSP_fft_zrip(
                        vDSP_create_fftsetup(fftLength, FFTRadix(kFFTRadix2))!,
                        UnsafeMutableRawPointer(inputPtr.baseAddress!).assumingMemoryBound(to: COMPLEX.self),
                        1,
                        fftLength,
                        direction
                    )
                }
            }
            
            let scale = 2.0 / Double(fftSize)
            for i in 0..<numBins {
                let real = fftOutput[i * 2]
                let imag = fftOutput[i * 2 + 1]
                let magnitude = sqrt(real * real + imag * imag)
                powerSpectra[frameIndex][i] = (magnitude * magnitude) * scale
            }
        }
        
        return powerSpectra
    }
    
    private func computeMelFilterBank() -> [[Double]] {
        let numBins = fftSize / 2 + 1
        let lowMel = 0.0
        let highMel = 2595.0 * log10(1.0 + (sampleRate / 2.0) / 700.0)
        
        var melPoints = [Double](repeating: 0, count: numFilters + 2)
        for i in 0..<numFilters + 2 {
            melPoints[i] = lowMel + (highMel - lowMel) * Double(i) / Double(numFilters + 1)
        }
        
        let hzPoints = melPoints.map { 700.0 * (pow(10.0, $0 / 2595.0) - 1.0) }
        let binPoints = hzPoints.map { Int(floor(Double(fftSize + 1) * $0 / sampleRate)) }
        
        var filterBank = [[Double]](repeating: [Double](repeating: 0, count: numBins), count: numFilters)
        
        for m in 1...numFilters {
            let left = binPoints[m - 1]
            let center = binPoints[m]
            let right = binPoints[m + 1]
            
            for k in left..<center {
                if center > left {
                    filterBank[m - 1][k] = Double(k - left) / Double(center - left)
                }
            }
            
            for k in center..<right {
                if right > center {
                    filterBank[m - 1][k] = Double(right - k) / Double(right - center)
                }
            }
        }
        
        return filterBank
    }
    
    private func applyMelFilterBank(powerSpectra: [[Double]]) -> [[Double]] {
        let filterBank = computeMelFilterBank()
        var filterBanks = [[Double]](repeating: [Double](repeating: 0, count: numFilters), count: powerSpectra.count)
        
        for i in 0..<powerSpectra.count {
            for j in 0..<numFilters {
                var sum = 0.0
                for k in 0..<powerSpectra[i].count {
                    sum += powerSpectra[i][k] * filterBank[j][k]
                }
                filterBanks[i][j] = max(sum, 1e-8)
            }
            
            for j in 0..<numFilters {
                filterBanks[i][j] = 20.0 * log10(filterBanks[i][j])
            }
        }
        
        return filterBanks
    }
    
    private func computeDCT(filterBanks: [[Double]]) -> [[Double]] {
        var mfcc = [[Double]](repeating: [Double](repeating: 0, count: numCepstralCoefficients), count: filterBanks.count)
        
        for i in 0..<filterBanks.count {
            for j in 0..<numCepstralCoefficients {
                var sum = 0.0
                for k in 0..<numFilters {
                    sum += filterBanks[i][k] * cos(Double.pi * Double(j) * (Double(k) + 0.5) / Double(numFilters))
                }
                mfcc[i][j] = sum * sqrt(2.0 / Double(numFilters))
            }
        }
        
        return mfcc
    }
    
    private func normalizeMFCC(mfcc: [[Double]]) -> [[Double]] {
        guard mfcc.count > 1 else { return mfcc }
        
        let numFrames = mfcc.count
        let numCoeffs = mfcc[0].count
        
        var mean = [Double](repeating: 0, count: numCoeffs)
        var std = [Double](repeating: 0, count: numCoeffs)
        
        for j in 0..<numCoeffs {
            var sum = 0.0
            for i in 0..<numFrames {
                sum += mfcc[i][j]
            }
            mean[j] = sum / Double(numFrames)
        }
        
        for j in 0..<numCoeffs {
            var sum = 0.0
            for i in 0..<numFrames {
                let diff = mfcc[i][j] - mean[j]
                sum += diff * diff
            }
            std[j] = sqrt(sum / Double(numFrames)) + 1e-8
        }
        
        var normalized = [[Double]](repeating: [Double](repeating: 0, count: numCoeffs), count: numFrames)
        for i in 0..<numFrames {
            for j in 0..<numCoeffs {
                normalized[i][j] = (mfcc[i][j] - mean[j]) / std[j]
            }
        }
        
        return normalized
    }
}
