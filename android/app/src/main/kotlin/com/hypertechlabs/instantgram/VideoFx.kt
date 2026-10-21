package com.hypertechlabs.instantgram

import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Green screen / background effects INTO a filmed video (no ffmpeg):
 * decoder -> OpenGL (find the person with [Selfie], swap the background)
 * -> H.264 encoder -> MP4. The sound is copied as it is.
 *
 * mode: "green" (the picture [background] behind you), "blur", "mono"
 * (black and white behind you) or "spot" (dark behind you).
 */
class VideoFx(
    private val selfie: Selfie,
    private val onProgress: (Int) -> Unit
) {
    @Volatile
    var cancelled = false

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    private val frameLock = ReentrantLock()
    private val frameSignal = frameLock.newCondition()
    private var frameReady = false

    /** Answers false when cancelled (nothing is written then). */
    fun run(src: String, dst: String, mode: String, background: Bitmap?): Boolean {
        val ex = MediaExtractor()
        var dec: MediaCodec? = null
        var enc: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var st: SurfaceTexture? = null
        var decSurface: Surface? = null
        var encSurface: Surface? = null
        val cbThread = HandlerThread("fx-frames").also { it.start() }
        var ok = false
        var muxStarted = false
        try {
            ex.setDataSource(src)
            var vTrack = -1
            var aTrack = -1
            for (i in 0 until ex.trackCount) {
                val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("video/") && vTrack < 0) vTrack = i
                if (mime.startsWith("audio/") && aTrack < 0) aTrack = i
            }
            if (vTrack < 0) throw IllegalStateException("no video")
            val vf = ex.getTrackFormat(vTrack)
            val mime = vf.getString(MediaFormat.KEY_MIME) ?: "video/avc"
            val w = vf.getInteger(MediaFormat.KEY_WIDTH)
            val h = vf.getInteger(MediaFormat.KEY_HEIGHT)
            val rotation = rotationOf(vf, src)
            val durUs = if (vf.containsKey(MediaFormat.KEY_DURATION)) vf.getLong(MediaFormat.KEY_DURATION) else 0L
            ex.selectTrack(vTrack)

            // the picture as you see it (portrait video = taller)
            val turned = rotation % 180 != 0
            val dispW = if (turned) h else w
            val dispH = if (turned) w else h

            // ---- encoder (+ the OpenGL screen that feeds it)
            var outW = 0
            var outH = 0
            var lastError: Exception? = null
            for (limit in intArrayOf(1920, 1280)) {
                val s = min(1f, limit.toFloat() / max(w, h))
                val tw = ((w * s).roundToInt() / 16) * 16
                val th = ((h * s).roundToInt() / 16) * 16
                val c = MediaCodec.createEncoderByType("video/avc")
                try {
                    val f = MediaFormat.createVideoFormat("video/avc", tw, th)
                    f.setInteger(
                        MediaFormat.KEY_COLOR_FORMAT,
                        MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
                    )
                    f.setInteger(MediaFormat.KEY_BIT_RATE, min(12_000_000, max(2_000_000, tw * th * 5)))
                    f.setInteger(MediaFormat.KEY_FRAME_RATE, 30)
                    f.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                    c.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    enc = c
                    outW = tw
                    outH = th
                    break
                } catch (e: Exception) {
                    lastError = e
                    c.release()
                }
            }
            val encoder = enc ?: throw lastError ?: IllegalStateException("no encoder")
            encSurface = encoder.createInputSurface()
            encoder.start()
            eglSetup(encSurface)

            val gl = Gl(mode, rotation, dispW, dispH, background)

            // ---- decoder draws into a texture
            st = SurfaceTexture(gl.oesTex)
            st.setOnFrameAvailableListener({
                frameLock.lock()
                try {
                    frameReady = true
                    frameSignal.signalAll()
                } finally {
                    frameLock.unlock()
                }
            }, Handler(cbThread.looper))
            decSurface = Surface(st)
            val decoder = MediaCodec.createDecoderByType(mime)
            dec = decoder
            decoder.configure(vf, decSurface, null, 0)
            decoder.start()

            val mux = MediaMuxer(dst, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mux
            mux.setOrientationHint(rotation)
            val audioFormat = if (aTrack >= 0) ex.getTrackFormat(aTrack) else null
            var vOut = -1
            var aOut = -1

            val info = MediaCodec.BufferInfo()
            val stm = FloatArray(16)
            var inDone = false
            var decDone = false
            var encDone = false
            var lastP = -1
            while (!encDone) {
                if (cancelled) break
                if (!inDone) {
                    val i = decoder.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val buf = decoder.getInputBuffer(i)!!
                        val n = ex.readSampleData(buf, 0)
                        if (n < 0) {
                            decoder.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inDone = true
                        } else {
                            decoder.queueInputBuffer(i, 0, n, ex.sampleTime, 0)
                            ex.advance()
                        }
                    }
                }
                // what the encoder made -> the file
                while (true) {
                    val o = encoder.dequeueOutputBuffer(info, 0)
                    if (o == MediaCodec.INFO_TRY_AGAIN_LATER) break
                    if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        vOut = mux.addTrack(encoder.outputFormat)
                        if (audioFormat != null) {
                            aOut = try {
                                mux.addTrack(audioFormat)
                            } catch (_: Exception) {
                                -1
                            }
                        }
                        mux.start()
                        muxStarted = true
                        continue
                    }
                    if (o < 0) continue
                    val b = encoder.getOutputBuffer(o)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                    if (b != null && info.size > 0 && muxStarted) {
                        b.position(info.offset)
                        b.limit(info.offset + info.size)
                        mux.writeSampleData(vOut, b, info)
                    }
                    encoder.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        encDone = true
                        break
                    }
                }
                if (!decDone) {
                    val o = decoder.dequeueOutputBuffer(info, 10_000)
                    if (o >= 0) {
                        val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        val render = info.size > 0
                        val pts = info.presentationTimeUs
                        decoder.releaseOutputBuffer(o, render)
                        if (render) {
                            awaitFrame()
                            st.updateTexImage()
                            st.getTransformMatrix(stm)
                            gl.draw(stm, selfie, outW, outH)
                            EGLExt.eglPresentationTimeANDROID(display, eglSurface, pts * 1000L)
                            EGL14.eglSwapBuffers(display, eglSurface)
                            if (durUs > 0) {
                                val p = (pts * 100 / durUs).toInt().coerceIn(0, 99)
                                if (p != lastP) {
                                    lastP = p
                                    onProgress(p)
                                }
                            }
                        }
                        if (eos) {
                            encoder.signalEndOfInputStream()
                            decDone = true
                        }
                    }
                }
            }
            if (!cancelled && muxStarted) {
                if (aOut >= 0) copyAudio(src, aTrack, mux, aOut)
                ok = true
            }
            gl.release()
        } finally {
            try {
                dec?.stop()
            } catch (_: Exception) {
            }
            try {
                dec?.release()
            } catch (_: Exception) {
            }
            try {
                enc?.stop()
            } catch (_: Exception) {
            }
            try {
                enc?.release()
            } catch (_: Exception) {
            }
            try {
                if (muxStarted) muxer?.stop()
            } catch (_: Exception) {
                ok = false
            }
            try {
                muxer?.release()
            } catch (_: Exception) {
            }
            try {
                ex.release()
            } catch (_: Exception) {
            }
            decSurface?.release()
            st?.release()
            eglRelease()
            encSurface?.release()
            cbThread.quitSafely()
            if (!ok) File(dst).delete()
        }
        if (ok) onProgress(100)
        return ok
    }

    private fun rotationOf(f: MediaFormat, src: String): Int {
        if (f.containsKey("rotation-degrees")) return ((f.getInteger("rotation-degrees") % 360) + 360) % 360
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(src)
            mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        } catch (_: Exception) {
            0
        } finally {
            try {
                mmr.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun awaitFrame() {
        frameLock.lock()
        try {
            val until = System.currentTimeMillis() + 3000
            while (!frameReady) {
                val left = until - System.currentTimeMillis()
                if (left <= 0) throw IllegalStateException("video frame timed out")
                frameSignal.await(left, TimeUnit.MILLISECONDS)
            }
            frameReady = false
        } finally {
            frameLock.unlock()
        }
    }

    private fun copyAudio(src: String, track: Int, mux: MediaMuxer, out: Int) {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(src)
            ex.selectTrack(track)
            val f = ex.getTrackFormat(track)
            val size = if (f.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                max(f.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE), 64 * 1024)
            } else 1024 * 1024
            val buf = ByteBuffer.allocateDirect(size)
            val info = MediaCodec.BufferInfo()
            while (!cancelled) {
                buf.clear()
                val n = ex.readSampleData(buf, 0)
                if (n < 0) break
                val key = ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                info.set(0, n, ex.sampleTime, if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                mux.writeSampleData(out, buf, info)
                ex.advance()
            }
        } finally {
            ex.release()
        }
    }

    // ------------------------------------------------------------ EGL

    private fun eglSetup(surface: Surface) {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val v = IntArray(2)
        if (!EGL14.eglInitialize(display, v, 0, v, 1)) throw IllegalStateException("no EGL")
        val attrs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        EGL14.eglChooseConfig(display, attrs, 0, configs, 0, 1, n, 0)
        val config = configs[0] ?: throw IllegalStateException("no EGL config")
        eglContext = EGL14.eglCreateContext(
            display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0
        )
        eglSurface = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
        if (!EGL14.eglMakeCurrent(display, eglSurface, eglSurface, eglContext)) {
            throw IllegalStateException("EGL make current failed")
        }
    }

    private fun eglRelease() {
        if (display == EGL14.EGL_NO_DISPLAY) return
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, eglSurface)
        if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, eglContext)
        EGL14.eglReleaseThread()
        EGL14.eglTerminate(display)
        display = EGL14.EGL_NO_DISPLAY
        eglContext = EGL14.EGL_NO_CONTEXT
        eglSurface = EGL14.EGL_NO_SURFACE
    }

    // ------------------------------------------------------------ OpenGL

    /**
     * p = place in the video as stored (0..1, y up), q = the same place
     * in the upright picture you see. [fwd] p -> q, [inv] q -> p.
     */
    private class Gl(mode: String, rotation: Int, dispW: Int, dispH: Int, background: Bitmap?) {
        val oesTex: Int
        private val smallTex: Int
        private val smallFbo: Int
        private val maskTex: Int
        private val bgTex: Int
        private val progSmall: Int
        private val progMain: Int
        private val quad: FloatBuffer
        private val pixels: ByteBuffer =
            ByteBuffer.allocateDirect(S * S * 4).order(ByteOrder.nativeOrder())
        private val modeId = when (mode) {
            "blur" -> 1
            "mono" -> 2
            "spot" -> 3
            else -> 0
        }
        private val fwd: FloatArray
        private val inv: FloatArray

        init {
            // [x row (a, b, c), y row (a, b, c)]: q.x = a*u + b*v + c
            val r0 = floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f)
            val r90 = floatArrayOf(0f, 1f, 0f, -1f, 0f, 1f)
            val r180 = floatArrayOf(-1f, 0f, 1f, 0f, -1f, 1f)
            val r270 = floatArrayOf(0f, -1f, 1f, 1f, 0f, 0f)
            when (rotation) {
                90 -> {
                    fwd = r90; inv = r270
                }
                180 -> {
                    fwd = r180; inv = r180
                }
                270 -> {
                    fwd = r270; inv = r90
                }
                else -> {
                    fwd = r0; inv = r0
                }
            }
            quad = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
            quad.put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)).position(0)

            val t = IntArray(4)
            GLES20.glGenTextures(4, t, 0)
            oesTex = t[0]
            smallTex = t[1]
            maskTex = t[2]
            bgTex = t[3]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
            params(GLES11Ext.GL_TEXTURE_EXTERNAL_OES)

            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, smallTex)
            params(GLES20.GL_TEXTURE_2D)
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, S, S, 0,
                GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null
            )
            val f = IntArray(1)
            GLES20.glGenFramebuffers(1, f, 0)
            smallFbo = f[0]
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, smallFbo)
            GLES20.glFramebufferTexture2D(
                GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
                GLES20.GL_TEXTURE_2D, smallTex, 0
            )
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)

            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTex)
            params(GLES20.GL_TEXTURE_2D)

            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, bgTex)
            params(GLES20.GL_TEXTURE_2D)
            val bg = cover(background ?: plain(), dispW, dispH)
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bg, 0)

            progSmall = program(VS, FS_SMALL)
            progMain = program(VS, FS_MAIN)
        }

        private fun params(target: Int) {
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        }

        private fun plain(): Bitmap {
            val b = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
            b.eraseColor(-0xe0dfda)
            return b
        }

        /** Background cut like BoxFit.cover for the upright picture. */
        private fun cover(src: Bitmap, w: Int, h: Int): Bitmap {
            val want = w.toFloat() / max(1, h)
            val have = src.width.toFloat() / max(1, src.height)
            var cw = src.width
            var ch = src.height
            if (have > want) cw = max(1, (src.height * want).roundToInt()) else ch = max(1, (src.width / want).roundToInt())
            val x = (src.width - cw) / 2
            val y = (src.height - ch) / 2
            val crop = Bitmap.createBitmap(src, x, y, cw, ch)
            val s = min(1f, 1080f / max(cw, ch))
            return if (s < 1f) Bitmap.createScaledBitmap(crop, max(1, (cw * s).toInt()), max(1, (ch * s).toInt()), true) else crop
        }

        fun draw(stm: FloatArray, selfie: Selfie, outW: Int, outH: Int) {
            // 1) the upright picture, small -> find the person
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, smallFbo)
            GLES20.glViewport(0, 0, S, S)
            use(progSmall, stm, inv)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            pixels.rewind()
            GLES20.glReadPixels(0, 0, S, S, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixels)
            pixels.rewind()
            val mask = selfie.maskRgba(pixels, true)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTex)
            GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE, S, S, 0,
                GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, ByteBuffer.wrap(mask)
            )

            // 2) the full picture with the new background -> encoder
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            GLES20.glViewport(0, 0, outW, outH)
            use(progMain, stm, fwd)
            val p = progMain
            GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTex)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(p, "sMask"), 1)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE2)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, bgTex)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(p, "sBg"), 2)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE3)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, smallTex)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(p, "sSmall"), 3)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(p, "uMode"), modeId)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        }

        private fun use(p: Int, stm: FloatArray, m: FloatArray) {
            GLES20.glUseProgram(p)
            val a = GLES20.glGetAttribLocation(p, "aPos")
            GLES20.glEnableVertexAttribArray(a)
            quad.position(0)
            GLES20.glVertexAttribPointer(a, 2, GLES20.GL_FLOAT, false, 8, quad)
            GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(p, "uST"), 1, false, stm, 0)
            GLES20.glUniform3f(GLES20.glGetUniformLocation(p, "uMx"), m[0], m[1], m[2])
            GLES20.glUniform3f(GLES20.glGetUniformLocation(p, "uMy"), m[3], m[4], m[5])
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(p, "sTex"), 0)
        }

        fun release() {
            GLES20.glDeleteTextures(4, intArrayOf(oesTex, smallTex, maskTex, bgTex), 0)
            GLES20.glDeleteFramebuffers(1, intArrayOf(smallFbo), 0)
            GLES20.glDeleteProgram(progSmall)
            GLES20.glDeleteProgram(progMain)
        }

        private fun shader(type: Int, src: String): Int {
            val s = GLES20.glCreateShader(type)
            GLES20.glShaderSource(s, src)
            GLES20.glCompileShader(s)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
            if (ok[0] == 0) {
                val log = GLES20.glGetShaderInfoLog(s)
                GLES20.glDeleteShader(s)
                throw IllegalStateException("shader: $log")
            }
            return s
        }

        private fun program(vs: String, fs: String): Int {
            val p = GLES20.glCreateProgram()
            GLES20.glAttachShader(p, shader(GLES20.GL_VERTEX_SHADER, vs))
            GLES20.glAttachShader(p, shader(GLES20.GL_FRAGMENT_SHADER, fs))
            GLES20.glLinkProgram(p)
            val ok = IntArray(1)
            GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
            if (ok[0] == 0) throw IllegalStateException("program: " + GLES20.glGetProgramInfoLog(p))
            return p
        }
    }

    companion object {
        private const val S = Selfie.SIZE
        private const val EGL_RECORDABLE_ANDROID = 0x3142

        private const val VS = """
attribute vec2 aPos;
varying vec2 vUv;
void main() {
  vUv = aPos * 0.5 + 0.5;
  gl_Position = vec4(aPos, 0.0, 1.0);
}
"""

        // small upright copy: vUv = q, sample the video at p = inv(q)
        private const val FS_SMALL = """
#extension GL_OES_EGL_image_external : require
precision mediump float;
varying vec2 vUv;
uniform samplerExternalOES sTex;
uniform mat4 uST;
uniform vec3 uMx;
uniform vec3 uMy;
void main() {
  vec3 q = vec3(vUv, 1.0);
  vec2 p = vec2(dot(uMx, q), dot(uMy, q));
  gl_FragColor = texture2D(sTex, (uST * vec4(p, 0.0, 1.0)).xy);
}
"""

        // full picture: vUv = p (as stored), q = fwd(p) for mask / background
        private const val FS_MAIN = """
#extension GL_OES_EGL_image_external : require
precision mediump float;
varying vec2 vUv;
uniform samplerExternalOES sTex;
uniform sampler2D sMask;
uniform sampler2D sBg;
uniform sampler2D sSmall;
uniform mat4 uST;
uniform vec3 uMx;
uniform vec3 uMy;
uniform int uMode;
void main() {
  vec3 p = vec3(vUv, 1.0);
  vec2 q = vec2(dot(uMx, p), dot(uMy, p));
  vec4 c = texture2D(sTex, (uST * vec4(vUv, 0.0, 1.0)).xy);
  float m = texture2D(sMask, vec2(q.x, 1.0 - q.y)).r;
  vec3 bg;
  if (uMode == 1) {
    vec3 s = texture2D(sSmall, q).rgb * 0.2;
    float r1 = 0.012;
    float r2 = 0.026;
    s += texture2D(sSmall, q + vec2(r1, 0.0)).rgb * 0.1;
    s += texture2D(sSmall, q - vec2(r1, 0.0)).rgb * 0.1;
    s += texture2D(sSmall, q + vec2(0.0, r1)).rgb * 0.1;
    s += texture2D(sSmall, q - vec2(0.0, r1)).rgb * 0.1;
    s += texture2D(sSmall, q + vec2(r2, r2)).rgb * 0.1;
    s += texture2D(sSmall, q - vec2(r2, r2)).rgb * 0.1;
    s += texture2D(sSmall, q + vec2(r2, -r2)).rgb * 0.1;
    s += texture2D(sSmall, q - vec2(r2, -r2)).rgb * 0.1;
    bg = s;
  } else if (uMode == 2) {
    bg = vec3(dot(c.rgb, vec3(0.299, 0.587, 0.114)));
  } else if (uMode == 3) {
    bg = c.rgb * 0.22;
  } else {
    bg = texture2D(sBg, vec2(q.x, 1.0 - q.y)).rgb;
  }
  gl_FragColor = vec4(mix(bg, c.rgb, m), 1.0);
}
"""
    }
}
