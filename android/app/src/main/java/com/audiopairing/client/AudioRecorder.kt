package com.audiopairing.client

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import kotlin.math.abs

interface AudioRecorderListener {
    fun onSampleReceived(sample: Float, time: Double)
    fun onRecordingFinished(data: ByteArray, duration: Double)
    fun onError(error: String)
    fun onPermissionChanged(granted: Boolean)
    fun onAGCUpdate(gain: Float, peak: Float, clippingRatio: Float)
}

class AudioRecorder(private val context: Context, private val recordingDuration: Long = 3000) {
    
    private var audioRecord: AudioRecord? = null
    private var isRecording = false
    private var isCalibrating = false
    private var recordingThread: Thread? = null
    private var startTime: Long = 0
    private val sampleRate = 16000
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_FLOAT
    private var bufferSize = 0
    
    private val recordedSamples = mutableListOf<Float>()
    private val handler = Handler(Looper.getMainLooper())
    
    private var currentGain: Float = 1.0f
    private val targetPeak: Float = 0.7f
    private val maxGain: Float = 2.0f
    private val minGain: Float = 0.1f
    private val agcSmoothing: Float = 0.3f
    
    private var peakLevel: Float = 0.0f
    private var clippingSampleCount: Int = 0
    private var totalSampleCount: Int = 0
    private val clippingThreshold: Float = 0.95f
    
    private val calibrationDuration: Long = 300
    private var calibrationStartTime: Long = 0
    private val maxRetries: Int = 3
    private var retryCount: Int = 0
    
    private val compressionThreshold: Float = 0.6f
    private val compressionRatio: Float = 4.0f
    
    var listener: AudioRecorderListener? = null
    
    fun checkPermission(): Boolean {
        return ActivityCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }
    
    fun requestPermission() {
        listener?.onPermissionChanged(checkPermission())
    }
    
    @Throws(SecurityException::class)
    fun startRecording() {
        if (!checkPermission()) {
            listener?.onError("Microphone permission not granted")
            listener?.onPermissionChanged(false)
            return
        }
        
        if (isRecording || isCalibrating) {
            stopRecording()
        }
        
        bufferSize = AudioRecord.getMinBufferSize(
            sampleRate,
            channelConfig,
            audioFormat
        )
        
        if (bufferSize < 1024) bufferSize = 1024
        
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            channelConfig,
            audioFormat,
            bufferSize
        )
        
        recordedSamples.clear()
        peakLevel = 0.0f
        clippingSampleCount = 0
        totalSampleCount = 0
        retryCount = 0
        
        isCalibrating = true
        calibrationStartTime = System.currentTimeMillis()
        
        audioRecord?.startRecording()
        
        recordingThread = Thread {
            val buffer = FloatArray(bufferSize)
            while ((isRecording || isCalibrating) && !Thread.currentThread().isInterrupted) {
                val readSize = audioRecord?.read(buffer, 0, bufferSize, AudioRecord.READ_BLOCKING) ?: 0
                
                if (readSize > 0) {
                    processAudioBuffer(buffer, readSize)
                }
            }
        }
        
        recordingThread?.start()
        
        println("Audio calibration started at $sampleRate Hz, gain: $currentGain")
    }
    
    private fun processAudioBuffer(buffer: FloatArray, readSize: Int) {
        var bufferPeak: Float = 0.0f
        var bufferClippingCount = 0
        
        for (i in 0 until readSize) {
            val absSample = Math.abs(buffer[i])
            if (absSample > bufferPeak) {
                bufferPeak = absSample
            }
            if (absSample >= clippingThreshold) {
                bufferClippingCount++
            }
        }
        
        peakLevel = maxOf(peakLevel * 0.95f, bufferPeak)
        clippingSampleCount += bufferClippingCount
        totalSampleCount += readSize
        
        val clippingRatio = clippingSampleCount.toFloat() / maxOf(totalSampleCount, 1).toFloat()
        
        updateAGC(peakLevel, clippingRatio)
        
        handler.post {
            listener?.onAGCUpdate(currentGain, peakLevel, clippingRatio)
        }
        
        if (isCalibrating) {
            val calibrationTime = System.currentTimeMillis() - calibrationStartTime
            
            if (calibrationTime >= calibrationDuration) {
                val needsRetry = clippingRatio > 0.01f && retryCount < maxRetries
                
                if (needsRetry) {
                    retryCount++
                    currentGain *= 0.7f
                    currentGain = maxOf(minGain, currentGain)
                    
                    peakLevel = 0.0f
                    clippingSampleCount = 0
                    totalSampleCount = 0
                    calibrationStartTime = System.currentTimeMillis()
                    
                    println("Calibration retry $retryCount/$maxRetries, adjusting gain to $currentGain")
                } else {
                    finishCalibration()
                }
            }
            
            val lastSample = buffer[readSize - 1]
            val displaySample = applyCompression(lastSample * currentGain)
            val calTime = (System.currentTimeMillis() - calibrationStartTime) / 1000.0
            
            handler.post {
                listener?.onSampleReceived(Math.abs(displaySample), calTime)
            }
            return
        }
        
        for (i in 0 until readSize) {
            val gained = buffer[i] * currentGain
            val compressed = applyCompression(gained)
            recordedSamples.add(compressed)
        }
        
        val currentTime = (System.currentTimeMillis() - startTime) / 1000.0
        
        val lastSample = buffer[readSize - 1]
        val displaySample = applyCompression(lastSample * currentGain)
        
        handler.post {
            listener?.onSampleReceived(Math.abs(displaySample), currentTime)
        }
        
        if (currentTime * 1000 >= recordingDuration) {
            handler.post {
                stopRecording()
            }
        }
    }
    
    private fun updateAGC(peak: Float, clippingRatio: Float) {
        if (!isRecording) return
        
        var targetGain = currentGain
        
        if (clippingRatio > 0.005f) {
            targetGain = currentGain * 0.85f
        } else if (peak > targetPeak * 1.1f) {
            targetGain = currentGain * (targetPeak / peak)
        } else if (peak < targetPeak * 0.5f) {
            targetGain = currentGain * 1.1f
        }
        
        currentGain += (targetGain - currentGain) * agcSmoothing
        currentGain = minOf(maxGain, maxOf(minGain, currentGain))
    }
    
    private fun applyCompression(sample: Float): Float {
        val absSample = Math.abs(sample)
        
        if (absSample <= compressionThreshold) {
            return sample
        }
        
        val overThreshold = absSample - compressionThreshold
        val compressed = compressionThreshold + overThreshold / compressionRatio
        
        return if (sample > 0) compressed else -compressed
    }
    
    private fun finishCalibration() {
        isCalibrating = false
        isRecording = true
        recordedSamples.clear()
        startTime = System.currentTimeMillis()
        
        val clippingRatio = clippingSampleCount.toFloat() / maxOf(totalSampleCount, 1).toFloat()
        
        println("Calibration finished. Gain: ${String.format("%.2f", currentGain)}, " +
                "Peak: ${String.format("%.3f", peakLevel)}, " +
                "Clipping: ${String.format("%.2f%%", clippingRatio * 100)}")
    }
    
    fun stopRecording() {
        if (!isRecording && !isCalibrating) return
        
        val wasRecording = isRecording
        isRecording = false
        isCalibrating = false
        
        recordingThread?.interrupt()
        recordingThread = null
        
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
        
        if (wasRecording) {
            val duration = (System.currentTimeMillis() - startTime) / 1000.0
            
            val audioData = ByteArray(recordedSamples.size * 4)
            for (i in recordedSamples.indices) {
                val bits = java.lang.Float.floatToIntBits(recordedSamples[i])
                audioData[i * 4] = (bits and 0xFF).toByte()
                audioData[i * 4 + 1] = ((bits shr 8) and 0xFF).toByte()
                audioData[i * 4 + 2] = ((bits shr 16) and 0xFF).toByte()
                audioData[i * 4 + 3] = ((bits shr 24) and 0xFF).toByte()
            }
            
            listener?.onRecordingFinished(audioData, duration)
            
            println("Audio recording stopped. Duration: ${String.format("%.2f", duration)}s, Samples: ${recordedSamples.size}")
        }
    }
    
    fun getSampleRate(): Int = sampleRate
    
    fun isRecording(): Boolean = isRecording
    
    fun isCalibrating(): Boolean = isCalibrating
    
    fun getCurrentGain(): Float = currentGain
    
    fun getPeakLevel(): Float = peakLevel
    
    fun getClippingRatio(): Float = 
        clippingSampleCount.toFloat() / maxOf(totalSampleCount, 1).toFloat()
    
    fun setManualGain(gain: Float) {
        currentGain = minOf(maxGain, maxOf(minGain, gain))
    }
    
    fun resetGain() {
        currentGain = 1.0f
    }
}
