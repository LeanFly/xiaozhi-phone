package com.lhht.aiassistant

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View

class RippleView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = resources.displayMetrics.density * 2 }
    private var active = false
    fun setActive(value: Boolean) { active = value; invalidate() }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (!active) return
        val maxRadius = minOf(width, height) * 0.55f
        val phase = (android.os.SystemClock.uptimeMillis() % 2400L) / 2400f
        for (i in 0..2) {
            val p = (phase + i / 3f) % 1f
            paint.color = Color.argb(((1f - p) * 110).toInt(), 92, 214, 245)
            canvas.drawCircle(width / 2f, height / 2f, maxRadius * (0.25f + p), paint)
        }
        if (isShown) postInvalidateDelayed(40)
    }
}
