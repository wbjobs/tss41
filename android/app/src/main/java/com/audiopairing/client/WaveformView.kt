package com.audiopairing.client

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import android.view.View
import kotlin.math.abs
import kotlin.math.min

class WaveformView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private val samples = mutableListOf<Float>()
    private val maxSamples = 200

    private val waveformPaint = Paint().apply {
        color = Color.parseColor("#2196F3")
        style = Paint.Style.STROKE
        strokeWidth = 4f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        isAntiAlias = true
    }

    private val backgroundPaint = Paint().apply {
        color = Color.parseColor("#E0E0E0")
        style = Paint.Style.STROKE
        strokeWidth = 4f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        isAntiAlias = true
        alpha = 77
    }

    private val centerLinePaint = Paint().apply {
        color = Color.parseColor("#BDBDBD")
        style = Paint.Style.STROKE
        strokeWidth = 1f
        isAntiAlias = true
        pathEffect = android.graphics.DashPathEffect(floatArrayOf(8f, 8f), 0f)
    }

    private val waveformPath = Path()
    private val backgroundPath = Path()

    var waveformColor: Int
        get() = waveformPaint.color
        set(value) {
            waveformPaint.color = value
            invalidate()
        }

    fun addSample(sample: Float) {
        samples.add(abs(sample))
        if (samples.size > maxSamples) {
            samples.removeFirst()
        }
        invalidate()
    }

    fun clear() {
        samples.clear()
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val height = height.toFloat()
        val width = width.toFloat()
        val midY = height / 2f

        if (samples.isEmpty()) {
            canvas.drawLine(0f, midY, width, midY, centerLinePaint)
            return
        }

        val xStep = width / maxSamples.toFloat()
        val emptySamples = maxSamples - samples.size

        waveformPath.reset()
        backgroundPath.reset()

        for (i in 0 until maxSamples) {
            val x = i * xStep
            val sampleValue = if (i >= emptySamples) samples[i - emptySamples] else 0f
            val amplitude = min(sampleValue.coerceIn(0f, 1f), 1f) * (height * 0.4f)

            val topY = midY - amplitude
            val bottomY = midY + amplitude

            if (i == 0) {
                waveformPath.moveTo(x, topY)
                backgroundPath.moveTo(x, bottomY)
            } else {
                waveformPath.lineTo(x, topY)
                backgroundPath.lineTo(x, bottomY)
            }
        }

        for (i in maxSamples - 1 downTo 0) {
            val x = i * xStep
            val sampleValue = if (i >= emptySamples) samples[i - emptySamples] else 0f
            val amplitude = min(sampleValue.coerceIn(0f, 1f), 1f) * (height * 0.4f)
            val bottomY = midY + amplitude
            waveformPath.lineTo(x, bottomY)
        }

        waveformPath.close()

        canvas.drawLine(0f, midY, width, midY, centerLinePaint)
        canvas.drawPath(backgroundPath, backgroundPaint)
        canvas.drawPath(waveformPath, waveformPaint)
    }

    fun animateSuccess() {
        val originalColor = waveformColor
        waveformColor = Color.parseColor("#4CAF50")
        
        val pulseAnimator = android.animation.ValueAnimator.ofFloat(1f, 0.5f, 1f).apply {
            duration = 300
            repeatCount = 3
            addUpdateListener { animation ->
                alpha = animation.animatedValue as Float
                invalidate()
            }
        }
        pulseAnimator.start()

        postDelayed({
            waveformColor = originalColor
            alpha = 1f
        }, 1800)
    }

    fun animateFailure() {
        val originalColor = waveformColor
        waveformColor = Color.parseColor("#F44336")
        
        val shakeAnimator = android.animation.ValueAnimator.ofFloat(0f, 10f, -10f, 5f, -5f, 0f).apply {
            duration = 500
            addUpdateListener { animation ->
                translationX = animation.animatedValue as Float
                invalidate()
            }
        }
        shakeAnimator.start()

        postDelayed({
            waveformColor = originalColor
            translationX = 0f
        }, 500)
    }
}
