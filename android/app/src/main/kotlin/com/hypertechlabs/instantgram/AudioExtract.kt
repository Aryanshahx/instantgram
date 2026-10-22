package com.hypertechlabs.instantgram

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.min

/**
 * "Original audio": copies a video's own sound (AAC) into an .m4a file,
 * without decoding (fast, same quality). Only the played part is kept:
 * from [startMs] to [endMs] (0 = to the end), without the removed parts
 * ([cuts] = start, end, start, end ... in ms of the video file).
 */
object AudioExtract {

    /** Length of the new file in ms, or -1 (no AAC sound / failed). */
    fun run(src: String, dst: String, startMs: Long, endMs: Long, cuts: LongArray): Long {
        val ex = MediaExtractor()
        var mux: MediaMuxer? = null
        var started = false
        var lastOut = -1L
        var wrote = 0
        var ok = false
        try {
            ex.setDataSource(src)
            var track = -1
            for (i in 0 until ex.trackCount) {
                val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (mime == MediaFormat.MIMETYPE_AUDIO_AAC) {
                    track = i
                    break
                }
            }
            if (track < 0) return -1
            val format = ex.getTrackFormat(track)
            ex.selectTrack(track)
            val startUs = max(0L, startMs) * 1000
            val endUs = if (endMs > 0) endMs * 1000 else Long.MAX_VALUE
            if (startUs > 0) ex.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val size = if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                max(format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE), 64 * 1024)
            } else 256 * 1024
            val buf = ByteBuffer.allocateDirect(size)
            val info = MediaCodec.BufferInfo()
            val pairs = cuts.size / 2
            File(dst).parentFile?.mkdirs()
            val m = MediaMuxer(dst, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            mux = m
            val out = m.addTrack(format)
            m.start()
            started = true
            while (true) {
                buf.clear()
                val n = ex.readSampleData(buf, 0)
                if (n < 0) break
                val t = ex.sampleTime
                if (t >= endUs) break
                if (t < startUs) {
                    ex.advance()
                    continue
                }
                var skip = false
                var removed = 0L
                for (i in 0 until pairs) {
                    val cs = cuts[2 * i] * 1000
                    val ce = cuts[2 * i + 1] * 1000
                    if (ce <= cs) continue
                    if (t in cs until ce) {
                        skip = true
                        break
                    }
                    // the part of this cut that is before t and after the start
                    removed += max(0L, min(ce, t) - max(cs, startUs))
                }
                if (!skip) {
                    var pts = t - startUs - removed
                    if (pts <= lastOut) pts = lastOut + 1
                    lastOut = pts
                    info.set(0, n, pts, MediaCodec.BUFFER_FLAG_KEY_FRAME)
                    m.writeSampleData(out, buf, info)
                    wrote++
                }
                ex.advance()
            }
            ok = wrote > 0
        } catch (e: Exception) {
            ok = false
        } finally {
            try {
                ex.release()
            } catch (_: Exception) {
            }
            try {
                if (started) mux?.stop()
            } catch (_: Exception) {
                ok = false
            }
            try {
                mux?.release()
            } catch (_: Exception) {
            }
            if (!ok) File(dst).delete()
        }
        return if (ok) max(1L, lastOut / 1000 + 23) else -1
    }
}
