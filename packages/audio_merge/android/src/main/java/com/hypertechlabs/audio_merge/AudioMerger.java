package com.hypertechlabs.audio_merge;

import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMetadataRetriever;
import android.media.MediaMuxer;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;

/**
 * Puts the audio of one file (a 30 second AAC preview, .m4a) under the picture of a video and
 * writes an .mp4. The same as
 *
 *   ffmpeg -i video.mp4 -i song.m4a -map 0:v:0 -map 1:a:0 -c:v copy -c:a copy
 *          -t 30 -shortest -movflags +faststart out.mp4
 *
 * - nothing is re-encoded: the picture is copied byte for byte (no loss of quality, very fast);
 * - the sound of the video is dropped, only the song is in the result;
 * - the result is as long as the shortest of: the video, the song, and [maxUs].
 */
final class AudioMerger {
    private AudioMerger() {}

    /** Returns the length of the written file in microseconds. */
    static long merge(String videoPath, String audioPath, String outPath, long maxUs) throws IOException {
        MediaExtractor video = new MediaExtractor();
        MediaExtractor audio = new MediaExtractor();
        MediaMuxer muxer = null;
        boolean started = false;
        boolean ok = false;
        try {
            video.setDataSource(videoPath);
            audio.setDataSource(audioPath);
            int vTrack = findTrack(video, "video/");
            int aTrack = findTrack(audio, "audio/");
            if (vTrack < 0) throw new IOException("The video has no picture.");
            if (aTrack < 0) throw new IOException("The song file has no sound.");
            video.selectTrack(vTrack);
            audio.selectTrack(aTrack);
            MediaFormat vFormat = video.getTrackFormat(vTrack);
            MediaFormat aFormat = audio.getTrackFormat(aTrack);
            String aMime = aFormat.getString(MediaFormat.KEY_MIME);
            if (!"audio/mp4a-latm".equals(aMime)) {
                throw new IOException("The song is not AAC audio (" + aMime + ").");
            }

            long limit = maxUs;
            long vDur = duration(vFormat);
            long aDur = duration(aFormat);
            if (vDur > 0) limit = Math.min(limit, vDur);
            if (aDur > 0) limit = Math.min(limit, aDur);

            File out = new File(outPath);
            if (out.exists() && !out.delete()) throw new IOException("Cannot replace the output file.");
            muxer = new MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            int rotation = rotationOf(videoPath);
            if (rotation != 0) muxer.setOrientationHint(rotation);
            int vOut = muxer.addTrack(vFormat);
            int aOut = muxer.addTrack(aFormat);
            muxer.start();
            started = true;

            int size = 4 * 1024 * 1024;
            if (vFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                size = Math.max(size, vFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE));
            }
            ByteBuffer buffer = ByteBuffer.allocate(size);
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            copy(video, muxer, vOut, buffer, info, limit);
            copy(audio, muxer, aOut, buffer, info, limit);
            ok = true;
            return limit;
        } catch (RuntimeException e) {
            // MediaExtractor / MediaMuxer report unsupported files this way
            throw new IOException("This video cannot be combined with a song: " + e.getMessage(), e);
        } finally {
            try {
                if (muxer != null) {
                    if (started) muxer.stop();
                    muxer.release();
                }
            } catch (RuntimeException e) {
                ok = false;
            }
            video.release();
            audio.release();
            if (!ok) new File(outPath).delete();
        }
    }

    /** Copies the samples of the selected track up to [limitUs] (times start at zero). */
    private static void copy(MediaExtractor src, MediaMuxer muxer, int track, ByteBuffer buffer,
                             MediaCodec.BufferInfo info, long limitUs) {
        long first = src.getSampleTime();
        if (first < 0) return;
        while (true) {
            long t = src.getSampleTime();
            if (t < 0) break;
            long rel = Math.max(0, t - first);
            if (rel > limitUs) break;
            buffer.clear();
            int n = src.readSampleData(buffer, 0);
            if (n < 0) break;
            info.set(0, n, rel, src.getSampleFlags() & MediaCodec.BUFFER_FLAG_KEY_FRAME);
            muxer.writeSampleData(track, buffer, info);
            if (!src.advance()) break;
        }
    }

    private static int findTrack(MediaExtractor e, String prefix) {
        for (int i = 0; i < e.getTrackCount(); i++) {
            String mime = e.getTrackFormat(i).getString(MediaFormat.KEY_MIME);
            if (mime != null && mime.startsWith(prefix)) return i;
        }
        return -1;
    }

    private static long duration(MediaFormat f) {
        return f.containsKey(MediaFormat.KEY_DURATION) ? f.getLong(MediaFormat.KEY_DURATION) : 0;
    }

    private static int rotationOf(String path) {
        MediaMetadataRetriever r = new MediaMetadataRetriever();
        try {
            r.setDataSource(path);
            String v = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION);
            return v == null ? 0 : Integer.parseInt(v);
        } catch (RuntimeException e) {
            return 0;
        } finally {
            try {
                r.release();
            } catch (Exception ignored) {
                // nothing to do
            }
        }
    }
}
