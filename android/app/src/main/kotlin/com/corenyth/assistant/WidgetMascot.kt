package com.corenyth.assistant

import android.graphics.*
import kotlin.math.*

/** Launcher-owned ViewFlipper frames: no background timers, service, or Flutter engine. */
object WidgetMascot {
    private val frames by lazy { List(12) { draw(it) } }
    fun frame(index: Int): Bitmap = frames[index]
    private fun draw(index: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(128, 144, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val phase = index * 2 * Math.PI / 12
        canvas.translate(18f, (10 + 4 * sin(phase)).toFloat())
        canvas.scale(.4f, .4f)
        val body = Path().apply {
            moveTo(230.809f, 115.385f)
            lineTo(230.809f, 249.411f)
            cubicTo(230.809f,269.923f,214.985f,287.282f,194.495f,288.411f)
            cubicTo(184.544f,288.949f,175.364f,285.718f,168.26f,280f)
            cubicTo(159.746f,273.154f,147.769f,273.461f,139.178f,280.23f)
            cubicTo(132.638f,285.384f,124.381f,288.462f,115.379f,288.462f)
            cubicTo(106.377f,288.462f,98.1451f,285.384f,91.6055f,280.23f)
            cubicTo(82.912f,273.385f,70.9353f,273.385f,62.2415f,280.23f)
            cubicTo(55.7532f,285.334f,47.598f,288.411f,38.7246f,288.462f)
            cubicTo(17.4132f,288.615f,0f,270.667f,0f,249.359f)
            lineTo(0f,115.385f)
            cubicTo(0f,51.6667f,51.6756f,0f,115.404f,0f)
            cubicTo(179.134f,0f,230.809f,51.6667f,230.809f,115.385f)
            close()
        }
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.shader = LinearGradient(0f,0f,230f,290f, intArrayOf(Color.rgb(100,214,235),Color.rgb(152,127,236),Color.rgb(238,174,205)), null, Shader.TileMode.CLAMP)
        canvas.drawPath(body, paint)
        paint.shader = null
        paint.color = Color.rgb(243,236,221)
        val eyeHeight = if (index == 10) 3f else if (index == 9 || index == 11) 20f else 30f
        for (x in listOf(80f,150f)) canvas.drawOval(x-20f,120f-eyeHeight,x+20f,120f+eyeHeight,paint)
        return bitmap
    }
}
