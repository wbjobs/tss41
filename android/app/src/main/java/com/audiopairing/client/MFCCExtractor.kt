package com.audiopairing.client

import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.sqrt

class MFCCExtractor(
    private val sampleRate: Double = 16000.0,
    private val numCepstralCoefficients: Int = 13,
    private val numFilters: Int = 40,
    frameSizeMs: Double = 25.0,
    frameStrideMs: Double = 10.0,
    private val fftSize: Int = 512
) {
    private val frameSize = (frameSizeMs * sampleRate / 1000.0).toInt()
    private val frameStride = (frameStrideMs * sampleRate / 1000.0).toInt()
    private val preEmphasisCoeff = 0.97

    fun extractMFCC(audioData: FloatArray): Array<DoubleArray> {
        val signal = preEmphasis(audioData.map { it.toDouble() }.toDoubleArray())
        val frames = framing(signal)
        val windowedFrames = applyHammingWindow(frames)
        val powerSpectra = computePowerSpectrum(windowedFrames)
        val filterBanks = applyMelFilterBank(powerSpectra)
        val mfcc = computeDCT(filterBanks)
        return normalizeMFCC(mfcc)
    }

    private fun preEmphasis(signal: DoubleArray): DoubleArray {
        val result = DoubleArray(signal.size)
        result[0] = signal[0]
        for (i in 1 until signal.size) {
            result[i] = signal[i] - preEmphasisCoeff * signal[i - 1]
        }
        return result
    }

    private fun framing(signal: DoubleArray): Array<DoubleArray> {
        val signalLength = signal.size
        val numFrames = kotlin.math.ceil((signalLength - frameSize).toDouble() / frameStride.toDouble()).toInt() + 1
        
        val paddedLength = (numFrames - 1) * frameStride + frameSize
        val paddedSignal = if (paddedLength > signalLength) {
            signal + DoubleArray(paddedLength - signalLength)
        } else {
            signal
        }
        
        return Array(numFrames) { i ->
            val start = i * frameStride
            paddedSignal.copyOfRange(start, start + frameSize)
        }
    }

    private fun applyHammingWindow(frames: Array<DoubleArray>): Array<DoubleArray> {
        val window = DoubleArray(frameSize) { i ->
            0.54 - 0.46 * cos(2.0 * Math.PI * i / (frameSize - 1))
        }
        
        return Array(frames.size) { i ->
            DoubleArray(frameSize) { j ->
                frames[i][j] * window[j]
            }
        }
    }

    private fun computePowerSpectrum(frames: Array<DoubleArray>): Array<DoubleArray> {
        val numBins = fftSize / 2 + 1
        
        return Array(frames.size) { frameIndex ->
            val frame = frames[frameIndex].copyOf(fftSize)
            val fftResult = fft(frame)
            
            DoubleArray(numBins) { i ->
                val real = fftResult[i * 2]
                val imag = fftResult[i * 2 + 1]
                val magnitude = sqrt(real * real + imag * imag)
                (magnitude * magnitude) * (2.0 / fftSize)
            }
        }
    }

    private fun fft(input: DoubleArray): DoubleArray {
        val n = input.size
        if (n <= 1) return doubleArrayOf(input[0], 0.0)
        
        val even = DoubleArray(n / 2) { i -> input[i * 2] }
        val odd = DoubleArray(n / 2) { i -> input[i * 2 + 1] }
        
        val evenFFT = fft(even)
        val oddFFT = fft(odd)
        
        val result = DoubleArray(n * 2)
        
        for (k in 0 until n / 2) {
            val angle = -2.0 * Math.PI * k / n
            val cos = cos(angle)
            val sin = kotlin.math.sin(angle)
            
            val tReal = cos * oddFFT[k * 2] - sin * oddFFT[k * 2 + 1]
            val tImag = sin * oddFFT[k * 2] + cos * oddFFT[k * 2 + 1]
            
            result[k * 2] = evenFFT[k * 2] + tReal
            result[k * 2 + 1] = evenFFT[k * 2 + 1] + tImag
            
            result[(k + n / 2) * 2] = evenFFT[k * 2] - tReal
            result[(k + n / 2) * 2 + 1] = evenFFT[k * 2 + 1] - tImag
        }
        
        return result
    }

    private fun computeMelFilterBank(): Array<DoubleArray> {
        val numBins = fftSize / 2 + 1
        val lowMel = 0.0
        val highMel = 2595.0 * log10(1.0 + (sampleRate / 2.0) / 700.0)
        
        val melPoints = DoubleArray(numFilters + 2) { i ->
            lowMel + (highMel - lowMel) * i / (numFilters + 1)
        }
        
        val hzPoints = melPoints.map { 700.0 * (10.0.pow(it / 2595.0) - 1.0) }
        val binPoints = hzPoints.map { kotlin.math.floor((fftSize + 1) * it / sampleRate).toInt() }
        
        val filterBank = Array(numFilters) { DoubleArray(numBins) }
        
        for (m in 1..numFilters) {
            val left = binPoints[m - 1]
            val center = binPoints[m]
            val right = binPoints[m + 1]
            
            for (k in left until center) {
                if (center > left) {
                    filterBank[m - 1][k] = (k - left).toDouble() / (center - left).toDouble()
                }
            }
            
            for (k in center until right) {
                if (right > center) {
                    filterBank[m - 1][k] = (right - k).toDouble() / (right - center).toDouble()
                }
            }
        }
        
        return filterBank
    }

    private fun applyMelFilterBank(powerSpectra: Array<DoubleArray>): Array<DoubleArray> {
        val filterBank = computeMelFilterBank()
        val result = Array(powerSpectra.size) { DoubleArray(numFilters) }
        
        for (i in powerSpectra.indices) {
            for (j in 0 until numFilters) {
                var sum = 0.0
                for (k in powerSpectra[i].indices) {
                    sum += powerSpectra[i][k] * filterBank[j][k]
                }
                result[i][j] = maxOf(sum, 1e-8)
            }
            
            for (j in 0 until numFilters) {
                result[i][j] = 20.0 * log10(result[i][j])
            }
        }
        
        return result
    }

    private fun computeDCT(filterBanks: Array<DoubleArray>): Array<DoubleArray> {
        val result = Array(filterBanks.size) { DoubleArray(numCepstralCoefficients) }
        
        for (i in filterBanks.indices) {
            for (j in 0 until numCepstralCoefficients) {
                var sum = 0.0
                for (k in 0 until numFilters) {
                    sum += filterBanks[i][k] * cos(Math.PI * j * (k + 0.5) / numFilters)
                }
                result[i][j] = sum * sqrt(2.0 / numFilters)
            }
        }
        
        return result
    }

    private fun normalizeMFCC(mfcc: Array<DoubleArray>): Array<DoubleArray> {
        if (mfcc.size <= 1) return mfcc
        
        val numFrames = mfcc.size
        val numCoeffs = mfcc[0].size
        
        val mean = DoubleArray(numCoeffs) { j ->
            var sum = 0.0
            for (i in 0 until numFrames) {
                sum += mfcc[i][j]
            }
            sum / numFrames
        }
        
        val std = DoubleArray(numCoeffs) { j ->
            var sum = 0.0
            for (i in 0 until numFrames) {
                val diff = mfcc[i][j] - mean[j]
                sum += diff * diff
            }
            sqrt(sum / numFrames) + 1e-8
        }
        
        return Array(numFrames) { i ->
            DoubleArray(numCoeffs) { j ->
                (mfcc[i][j] - mean[j]) / std[j]
            }
        }
    }
}
