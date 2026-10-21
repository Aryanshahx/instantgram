package com.hypertechlabs.instantgram

import android.content.Context
import android.graphics.Bitmap
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.tflite.java.TfLite
import org.tensorflow.lite.InterpreterApi
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.TimeUnit

/**
 * Fast green screen: Google's small "selfie segmenter" model (250 KB,
 * downloaded by the app the first time, not inside the APK) running on
 * TensorFlow Lite from Google Play services (also not inside the APK).
 *
 * In: a 256 x 256 colour picture. Out: 256 x 256 numbers, 1 = person.
 */
class Selfie(private val context: Context) {

    private var interpreter: InterpreterApi? = null
    private var modelPath = ""
    private val input: ByteBuffer =
        ByteBuffer.allocateDirect(SIZE * SIZE * 3 * 4).order(ByteOrder.nativeOrder())
    private val output: ByteBuffer =
        ByteBuffer.allocateDirect(SIZE * SIZE * 4).order(ByteOrder.nativeOrder())
    private val px = IntArray(SIZE * SIZE)
    private var last: FloatArray? = null
    private var lastAt = 0L

    val ready: Boolean
        get() = interpreter != null

    /** Loads the model (and TensorFlow Lite from Play services). Slow: not on the main thread. */
    @Synchronized
    fun prepare(path: String) {
        if (interpreter != null && path == modelPath) return
        val file = File(path)
        if (!file.exists()) throw IllegalStateException("no model")
        Tasks.await(TfLite.initialize(context), 90, TimeUnit.SECONDS)
        val options = InterpreterApi.Options()
            .setRuntime(InterpreterApi.Options.TfLiteRuntime.FROM_SYSTEM_ONLY)
            .setNumThreads(4)
            .setUseXNNPACK(true)
        val next = InterpreterApi.create(file, options)
        try {
            interpreter?.close()
        } catch (_: Exception) {
        }
        interpreter = next
        modelPath = path
        last = null
    }

    @Synchronized
    fun close() {
        try {
            interpreter?.close()
        } catch (_: Exception) {
        }
        interpreter = null
        last = null
    }

    /**
     * Person mask for an (upright) picture, made [outW] x [outH] bytes
     * (255 = person). [smooth] = camera frames: mixes with the last
     * frame so the edge does not flicker.
     */
    @Synchronized
    fun mask(bmp: Bitmap, outW: Int, outH: Int, smooth: Boolean): ByteArray {
        val small = if (bmp.width == SIZE && bmp.height == SIZE) bmp
        else Bitmap.createScaledBitmap(bmp, SIZE, SIZE, true)
        small.getPixels(px, 0, SIZE, 0, 0, SIZE, SIZE)
        input.rewind()
        for (c in px) {
            input.putFloat(((c shr 16) and 0xff) / 255f)
            input.putFloat(((c shr 8) and 0xff) / 255f)
            input.putFloat((c and 0xff) / 255f)
        }
        val conf = infer(smooth)
        return resize(conf, outW, outH)
    }

    /**
     * Video frames: [rgba] = 256 x 256 RGBA read from OpenGL (bottom row
     * first). Answers 256 x 256 bytes, TOP row first.
     */
    @Synchronized
    fun maskRgba(rgba: ByteBuffer, smooth: Boolean): ByteArray {
        input.rewind()
        for (y in 0 until SIZE) {
            var o = (SIZE - 1 - y) * SIZE * 4
            for (x in 0 until SIZE) {
                input.putFloat((rgba.get(o).toInt() and 0xff) / 255f)
                input.putFloat((rgba.get(o + 1).toInt() and 0xff) / 255f)
                input.putFloat((rgba.get(o + 2).toInt() and 0xff) / 255f)
                o += 4
            }
        }
        val conf = infer(smooth)
        val out = ByteArray(SIZE * SIZE)
        for (i in out.indices) out[i] = toByte(conf[i])
        return out
    }

    /** Runs the model on [input]; answers 0..1 per pixel (top row first). */
    private fun infer(smooth: Boolean): FloatArray {
        val it = interpreter ?: throw IllegalStateException("green screen not ready")
        input.rewind()
        output.rewind()
        it.run(input, output)
        output.rewind()
        val conf = FloatArray(SIZE * SIZE)
        output.asFloatBuffer().get(conf)
        val now = System.currentTimeMillis()
        val prev = last
        if (smooth && prev != null && now - lastAt < 600) {
            for (i in conf.indices) conf[i] = conf[i] * 0.65f + prev[i] * 0.35f
        }
        last = conf
        lastAt = now
        return conf
    }

    /** Bilinear resize to [w] x [h] bytes with a slightly sharper edge. */
    private fun resize(conf: FloatArray, w: Int, h: Int): ByteArray {
        val out = ByteArray(w * h)
        val sx = SIZE.toFloat() / w
        val sy = SIZE.toFloat() / h
        for (y in 0 until h) {
            val fy = ((y + 0.5f) * sy - 0.5f).coerceIn(0f, (SIZE - 1).toFloat())
            val y0 = fy.toInt()
            val y1 = if (y0 + 1 < SIZE) y0 + 1 else y0
            val ty = fy - y0
            val r0 = y0 * SIZE
            val r1 = y1 * SIZE
            val row = y * w
            for (x in 0 until w) {
                val fx = ((x + 0.5f) * sx - 0.5f).coerceIn(0f, (SIZE - 1).toFloat())
                val x0 = fx.toInt()
                val x1 = if (x0 + 1 < SIZE) x0 + 1 else x0
                val tx = fx - x0
                val a = conf[r0 + x0] + (conf[r0 + x1] - conf[r0 + x0]) * tx
                val b = conf[r1 + x0] + (conf[r1 + x1] - conf[r1 + x0]) * tx
                out[row + x] = toByte(a + (b - a) * ty)
            }
        }
        return out
    }

    private fun toByte(c: Float): Byte {
        // 0.2 .. 0.8 -> 0 .. 1 : a cleaner edge than the raw numbers
        val v = (c - 0.2f) / 0.6f
        return (if (v <= 0f) 0 else if (v >= 1f) 255 else (v * 255f).toInt()).toByte()
    }

    companion object {
        const val SIZE = 256
    }
}
