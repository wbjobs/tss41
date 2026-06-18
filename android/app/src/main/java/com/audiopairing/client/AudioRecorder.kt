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
}

class AudioRecorder(private val context: Context, private val recordingDuration: Long = 3000) {
    
    private var audioRecord: AudioRecord? = null
    private var isRecording = false
    private var recordingThread: Thread? = null
    private var startTime: Long = 0
    private val sampleRate = 16000
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_FLOAT
    private var bufferSize = 0
    
    private val recordedSamples = mutableListOf<Float>()
    private val handler = Handler(Looper.getMainLooper())
    
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
        
        if (isRecording) {
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
        startTime = System.currentTimeMillis()
        isRecording = true
        
        audioRecord?.startRecording()
        
        recordingThread = Thread {
            val buffer = FloatArray(bufferSize)
            while (isRecording && !Thread.currentThread().isInterrupted) {
                val readSize = audioRecord?.read(buffer, 0, bufferSize, AudioRecord.READ_BLOCKING) ?: 0
                
                if (readSize > 0) {
                    val currentTime = (System.currentTimeMillis() - startTime) / 1000.0
                    
                    for (i in 0 until readSize) {
                        recordedSamples.add(buffer[i])
                    }
                    
                    val lastSample = buffer[readSize - 1]
                    handler.post {
                        listener?.onSampleReceived(abs(lastSample), currentTime)
                    }
                    
                    if (currentTime * 1000 >= recordingDuration) {
                        handler.post {
                            stopRecording()
                        }
                        break
                    }
                }
            }
        }
        
        recordingThread?.start()
        
        println("Audio recording started at $sampleRate Hz")
    }
    
    fun stopRecording() {
        if (!isRecording) return
        
        isRecording = false
        
        recordingThread?.interrupt()
        recordingThread = null
        
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
        
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
    
    fun getSampleRate(): Int = sampleRate
    
    fun isRecording(): Boolean = isRecording
}
