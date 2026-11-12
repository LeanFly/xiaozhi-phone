package com.lhht.aiassistant

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import androidx.appcompat.widget.AppCompatImageView
import kotlin.math.sin

/** Draws state-driven signal and mouth over the transparent mascot artwork. */
class MascotView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) :
    AppCompatImageView(context, attrs) {
    enum class Mode { IDLE, LISTENING, SPEAKING }
    private var mode = Mode.IDLE
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val path = Path()

    fun setMode(value: Mode) {
        if (mode == value) return
        mode = value
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val drawable = drawable ?: return
        val save = canvas.save()
        canvas.translate(paddingLeft.toFloat(), paddingTop.toFloat())
        canvas.concat(imageMatrix)
        val sx = drawable.intrinsicWidth / 240f
        val sy = drawable.intrinsicHeight / 240f
        canvas.scale(sx, sy)
        val t = android.os.SystemClock.uptimeMillis().toFloat()
        if (mode == Mode.LISTENING) {
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 2.5f
            paint.strokeCap = Paint.Cap.ROUND
            paint.color = Color.rgb(94, 227, 244)
            val pulse = (sin(t / 450f) + 1f) / 2f
            paint.alpha = (100 + 130 * pulse).toInt()
            canvas.drawArc(103f, 13f, 137f, 47f, 205f, 130f, false, paint)
            paint.alpha = (60 + 110 * pulse).toInt()
            canvas.drawArc(96f, 6f, 144f, 54f, 210f, 120f, false, paint)
        }
        paint.alpha = 255
        paint.color = Color.rgb(50, 97, 135)
        if (mode == Mode.SPEAKING) {
            paint.style = Paint.Style.FILL
            val height = 2.5f + 4f * ((sin(t / 130f) + 1f) / 2f)
            canvas.drawOval(111f, 143f - height, 129f, 143f + height, paint)
        } else {
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 4f
            paint.strokeCap = Paint.Cap.ROUND
            path.reset()
            path.moveTo(108f, 139f)
            path.quadTo(120f, 151f, 132f, 139f)
            canvas.drawPath(path, paint)
        }
        canvas.restoreToCount(save)
        if (mode != Mode.IDLE && isShown) postInvalidateDelayed(70)
    }
}
