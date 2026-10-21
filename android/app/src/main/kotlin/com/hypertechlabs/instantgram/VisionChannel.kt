package com.hypertechlabs.instantgram

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.android.gms.common.api.OptionalModuleApi
import com.google.android.gms.common.moduleinstall.InstallStatusListener
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.android.gms.common.moduleinstall.ModuleInstallStatusUpdate
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.face.FaceLandmark
import com.google.mlkit.vision.segmentation.subject.SubjectSegmentation
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenter
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenterOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * Face effects + green screen (Google ML Kit, models from Google Play
 * services). The models are NOT in the app: they download the first time
 * you open Effects ("install"), so the app stays small.
 *
 *  status  {segment}                          -> Boolean (models on the phone)
 *  install {segment}                          -> Boolean, sends "progress"
 *  analyze {bytes (NV21), w, h, rotation, mirror, face, segment}
 *                                             -> {w, h, faces, mask?, mw, mh}
 *  photo   {path, face, segment}              -> {path, w, h, faces, mask?, mw, mh}
 *  video   {path, fps, maxFrames}             -> {track, cancelled}, sends "progress"
 *  cancelVideo
 *
 * Face numbers are 0..1 of the (upright) picture:
 * lx, ly, rx, ry = the eyes, l, t, r, b = the face box.
 */
class VisionChannel(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "instantgram/vision")
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val videoWorker: ExecutorService = Executors.newSingleThreadExecutor()
    private var fastDetector: FaceDetector? = null
    private var photoDetector: FaceDetector? = null
    private var segmenter: SubjectSegmenter? = null

    @Volatile
    private var cancelVideo = false

    init {
        channel.setMethodCallHandler(this)
    }

    fun close() {
        channel.setMethodCallHandler(null)
        worker.shutdown()
        videoWorker.shutdown()
        try {
            fastDetector?.close()
            photoDetector?.close()
            segmenter?.close()
        } catch (_: Exception) {
        }
    }

    private fun fast(): FaceDetector {
        val d = fastDetector
        if (d != null) return d
        val n = FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
                .setMinFaceSize(0.12f)
                .build()
        )
        fastDetector = n
        return n
    }

    private fun accurate(): FaceDetector {
        val d = photoDetector
        if (d != null) return d
        val n = FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
                .setMinFaceSize(0.08f)
                .build()
        )
        photoDetector = n
        return n
    }

    private fun seg(): SubjectSegmenter {
        val s = segmenter
        if (s != null) return s
        val n = SubjectSegmentation.getClient(
            SubjectSegmenterOptions.Builder().enableForegroundConfidenceMask().build()
        )
        segmenter = n
        return n
    }

    private fun apis(segment: Boolean): Array<OptionalModuleApi> =
        if (segment) arrayOf(fast(), seg()) else arrayOf(fast())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> status(call.argument<Boolean>("segment") == true, result)
                "install" -> install(call.argument<Boolean>("segment") == true, result)
                "analyze" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val w = call.argument<Int>("w") ?: 0
                    val h = call.argument<Int>("h") ?: 0
                    val rotation = call.argument<Int>("rotation") ?: 0
                    val mirror = call.argument<Boolean>("mirror") == true
                    val face = call.argument<Boolean>("face") == true
                    val segment = call.argument<Boolean>("segment") == true
                    if (bytes == null || w <= 0 || h <= 0 || bytes.size < w * h * 3 / 2) {
                        result.error("vision", "bad frame", null)
                        return
                    }
                    background(worker, result) {
                        val up = orient(nv21ToBitmap(bytes, w, h), rotation, mirror)
                        analyzeBitmap(up, face, segment, fast(), 3)
                    }
                }
                "photo" -> {
                    val path = call.argument<String>("path") ?: ""
                    val face = call.argument<Boolean>("face") == true
                    val segment = call.argument<Boolean>("segment") == true
                    background(worker, result) { photo(path, face, segment) }
                }
                "video" -> {
                    val path = call.argument<String>("path") ?: ""
                    val fps = call.argument<Int>("fps") ?: 5
                    val maxFrames = call.argument<Int>("maxFrames") ?: 150
                    cancelVideo = false
                    background(videoWorker, result) { video(path, fps, maxFrames) }
                }
                "cancelVideo" -> {
                    cancelVideo = true
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("vision", e.message, null)
        }
    }

    /** Runs [work] off the main thread and answers on the main thread. */
    private fun background(
        pool: ExecutorService,
        result: MethodChannel.Result,
        work: () -> Any?
    ) {
        try {
            pool.execute {
                try {
                    val v = work()
                    main.post { result.success(v) }
                } catch (e: Throwable) {
                    val msg = e.message ?: e.javaClass.simpleName
                    main.post { result.error("vision", msg, null) }
                }
            }
        } catch (e: Exception) {
            result.error("vision", e.message, null)
        }
    }

    // ------------------------------------------------------------ models

    private fun status(segment: Boolean, result: MethodChannel.Result) {
        ModuleInstall.getClient(context)
            .areModulesAvailable(*apis(segment))
            .addOnSuccessListener { result.success(it.areModulesAvailable()) }
            .addOnFailureListener { result.success(false) }
    }

    private fun install(segment: Boolean, result: MethodChannel.Result) {
        val client = ModuleInstall.getClient(context)
        var answered = false
        fun answer(ok: Boolean, why: String?) {
            main.post {
                if (answered) return@post
                answered = true
                if (ok) result.success(true) else result.error("install", why ?: "failed", null)
            }
        }

        val listener = object : InstallStatusListener {
            override fun onInstallStatusUpdated(update: ModuleInstallStatusUpdate) {
                val info = update.progressInfo
                if (info != null && info.totalBytesToDownload > 0) {
                    val p = (info.bytesDownloaded * 100 / info.totalBytesToDownload).toInt()
                    main.post { channel.invokeMethod("progress", mapOf("kind" to "install", "p" to p)) }
                }
                when (update.installState) {
                    ModuleInstallStatusUpdate.InstallState.STATE_COMPLETED -> {
                        client.unregisterListener(this)
                        answer(true, null)
                    }
                    ModuleInstallStatusUpdate.InstallState.STATE_CANCELED,
                    ModuleInstallStatusUpdate.InstallState.STATE_FAILED -> {
                        client.unregisterListener(this)
                        answer(false, "error ${update.errorCode}")
                    }
                    else -> {}
                }
            }
        }
        val builder = ModuleInstallRequest.newBuilder()
        for (api in apis(segment)) builder.addApi(api)
        client.installModules(builder.setListener(listener).build())
            .addOnSuccessListener { r ->
                if (r.areModulesAlreadyInstalled()) {
                    client.unregisterListener(listener)
                    answer(true, null)
                }
            }
            .addOnFailureListener { e ->
                client.unregisterListener(listener)
                answer(false, e.message)
            }
    }

    // ------------------------------------------------------------ frames

    /** NV21 camera frame -> colour picture. */
    private fun nv21ToBitmap(d: ByteArray, w: Int, h: Int): Bitmap {
        val px = IntArray(w * h)
        val frame = w * h
        for (j in 0 until h) {
            val row = j * w
            val uvRow = frame + (j shr 1) * w
            for (i in 0 until w) {
                val y = d[row + i].toInt() and 0xff
                val uv = uvRow + (i and 1.inv())
                val v = (d[uv].toInt() and 0xff) - 128
                val u = (d[uv + 1].toInt() and 0xff) - 128
                val r = clamp(y + (1.370705f * v).toInt())
                val g = clamp(y - (0.337633f * u + 0.698001f * v).toInt())
                val b = clamp(y + (1.732446f * u).toInt())
                px[row + i] = -0x1000000 or (r shl 16) or (g shl 8) or b
            }
        }
        return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
    }

    private fun clamp(v: Int): Int = if (v < 0) 0 else if (v > 255) 255 else v

    /** Turns the frame upright (like the screen) and mirrors the selfie camera. */
    private fun orient(src: Bitmap, rotation: Int, mirror: Boolean): Bitmap {
        if (rotation % 360 == 0 && !mirror) return src
        val m = Matrix()
        m.postRotate(rotation.toFloat())
        if (mirror) m.postScale(-1f, 1f)
        return Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true)
    }

    private fun analyzeBitmap(
        up: Bitmap,
        face: Boolean,
        segment: Boolean,
        detector: FaceDetector,
        maxFaces: Int
    ): HashMap<String, Any> {
        val out = HashMap<String, Any>()
        out["w"] = up.width
        out["h"] = up.height
        val image = InputImage.fromBitmap(up, 0)
        if (face) {
            val faces = Tasks.await(detector.process(image))
            out["faces"] = faces
                .sortedByDescending { it.boundingBox.width() }
                .take(maxFaces)
                .map { faceMap(it, up.width, up.height) }
        }
        if (segment) {
            val mask = maskOf(up)
            if (mask != null) {
                out["mask"] = mask
                out["mw"] = up.width
                out["mh"] = up.height
            }
        }
        return out
    }

    /** Foreground mask: one byte per pixel, 255 = person / subject. */
    private fun maskOf(bmp: Bitmap): ByteArray? {
        val r = Tasks.await(seg().process(InputImage.fromBitmap(bmp, 0)))
        val buf = r.foregroundConfidenceMask ?: return null
        val n = bmp.width * bmp.height
        if (buf.capacity() < n) return null
        buf.rewind()
        val out = ByteArray(n)
        for (i in 0 until n) {
            val c = buf.get()
            out[i] = (if (c <= 0f) 0 else if (c >= 1f) 255 else (c * 255f).toInt()).toByte()
        }
        return out
    }

    private fun faceMap(f: Face, w: Int, h: Int): Map<String, Double> {
        val b = f.boundingBox
        val le = f.getLandmark(FaceLandmark.LEFT_EYE)?.position
        val re = f.getLandmark(FaceLandmark.RIGHT_EYE)?.position
        val fw = b.width().toFloat()
        val fh = b.height().toFloat()
        val lx = le?.x ?: (b.left + fw * 0.68f)
        val ly = le?.y ?: (b.top + fh * 0.4f)
        val rx = re?.x ?: (b.left + fw * 0.32f)
        val ry = re?.y ?: (b.top + fh * 0.4f)
        val wd = w.toDouble()
        val hd = h.toDouble()
        return mapOf(
            "lx" to lx / wd, "ly" to ly / hd,
            "rx" to rx / wd, "ry" to ry / hd,
            "l" to b.left / wd, "t" to b.top / hd,
            "r" to b.right / wd, "b" to b.bottom / hd
        )
    }

    // ------------------------------------------------------------ photos

    private fun photo(path: String, face: Boolean, segment: Boolean): HashMap<String, Any> {
        val bounds = BitmapFactory.Options()
        bounds.inJustDecodeBounds = true
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw IllegalStateException("no photo")
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / sample > 2400) sample *= 2
        val opts = BitmapFactory.Options()
        opts.inSampleSize = sample
        val raw = BitmapFactory.decodeFile(path, opts) ?: throw IllegalStateException("no photo")
        val up = uprightPhoto(raw, path)
        val file = File(context.cacheDir, "fx_up_${System.currentTimeMillis()}.jpg")
        FileOutputStream(file).use { up.compress(Bitmap.CompressFormat.JPEG, 95, it) }

        val out = HashMap<String, Any>()
        out["path"] = file.absolutePath
        out["w"] = up.width
        out["h"] = up.height
        if (face) {
            val faces = Tasks.await(accurate().process(InputImage.fromBitmap(up, 0)))
            out["faces"] = faces
                .sortedByDescending { it.boundingBox.width() }
                .take(5)
                .map { faceMap(it, up.width, up.height) }
        }
        if (segment) {
            val scale = min(1f, 1024f / max(up.width, up.height))
            val small = if (scale < 1f) {
                Bitmap.createScaledBitmap(
                    up,
                    max(1, (up.width * scale).toInt()),
                    max(1, (up.height * scale).toInt()),
                    true
                )
            } else up
            val mask = maskOf(small)
            if (mask != null) {
                out["mask"] = mask
                out["mw"] = small.width
                out["mh"] = small.height
            }
        }
        return out
    }

    /** Applies the photo's EXIF turn / flip (so it looks like in the gallery). */
    private fun uprightPhoto(raw: Bitmap, path: String): Bitmap {
        val o = try {
            ExifInterface(path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val m = Matrix()
        when (o) {
            ExifInterface.ORIENTATION_ROTATE_90 -> m.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> m.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                m.postRotate(90f)
                m.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                m.postRotate(270f)
                m.postScale(-1f, 1f)
            }
            else -> return raw
        }
        return Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, m, true)
    }

    // ------------------------------------------------------------ videos

    /** Finds the face in frames of a filmed video (for the face effect). */
    private fun video(path: String, fps: Int, maxFrames: Int): HashMap<String, Any> {
        val mmr = MediaMetadataRetriever()
        val sb = StringBuilder("v1")
        var cancelled = false
        try {
            mmr.setDataSource(path)
            val dur = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            val vw = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 0
            val vh = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 0
            val rot = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0
            // the picture as you see it (portrait video = taller than wide)
            val turned = rot % 180 != 0
            val wantTall = if (turned) vw > vh else vh > vw
            val n = max(1, min(maxFrames.toLong(), dur * max(1, fps) / 1000L).toInt())
            val step = if (n > 1) dur / n else 0L
            for (k in 0 until n) {
                if (cancelVideo) {
                    cancelled = true
                    break
                }
                val tMs = k * step
                var frame: Bitmap? = if (Build.VERSION.SDK_INT >= 27) {
                    mmr.getScaledFrameAtTime(
                        tMs * 1000L,
                        MediaMetadataRetriever.OPTION_CLOSEST,
                        480,
                        480
                    )
                } else {
                    mmr.getFrameAtTime(tMs * 1000L, MediaMetadataRetriever.OPTION_CLOSEST)
                }
                sb.append(';').append(tMs)
                if (frame != null) {
                    val tall = frame.height > frame.width
                    if (turned && tall != wantTall) frame = orient(frame, rot, false)
                    val faces = Tasks.await(fast().process(InputImage.fromBitmap(frame, 0)))
                    val best = faces.maxByOrNull { it.boundingBox.width() }
                    if (best != null) {
                        val f = faceMap(best, frame.width, frame.height)
                        for (key in KEYS) {
                            sb.append(',').append(String.format(Locale.US, "%.3f", f[key] ?: 0.0))
                        }
                    }
                }
                val p = (k + 1) * 100 / n
                main.post { channel.invokeMethod("progress", mapOf("kind" to "video", "p" to p)) }
            }
        } finally {
            try {
                mmr.release()
            } catch (_: Exception) {
            }
        }
        val out = HashMap<String, Any>()
        out["track"] = sb.toString()
        out["cancelled"] = cancelled
        return out
    }

    companion object {
        private val KEYS = listOf("lx", "ly", "rx", "ry", "l", "t", "r", "b")
    }
}
