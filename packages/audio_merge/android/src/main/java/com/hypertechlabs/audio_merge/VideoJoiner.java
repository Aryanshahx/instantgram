package com.hypertechlabs.audio_merge;

import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMuxer;

import java.io.File;
import java.nio.ByteBuffer;
import java.util.List;

/**
 * Joins video files one after the other into one MP4, without decoding (the samples are
 * copied, only their times move). Used after Split: every kept part is made with the same
 * settings by the compressor, so the parts fit together.
 */
final class VideoJoiner {
    private VideoJoiner() {}

    /** Returns the length of the joined file in microseconds. */
    static long join(List<String> inputs, String output) throws Exception {
        if (inputs == null || inputs.isEmpty()) throw new IllegalArgumentException("nothing to join");
        new File(output).delete();
        MediaMuxer muxer = new MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
        int outVideo = -1;
        int outAudio = -1;
        boolean started = false;
        long offsetUs = 0;
        ByteBuffer buf = ByteBuffer.allocate(4 * 1024 * 1024);
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        try {
            for (String path : inputs) {
                MediaExtractor ex = new MediaExtractor();
                try {
                    ex.setDataSource(path);
                    int inVideo = -1;
                    int inAudio = -1;
                    for (int i = 0; i < ex.getTrackCount(); i++) {
                        MediaFormat f = ex.getTrackFormat(i);
                        String mime = f.getString(MediaFormat.KEY_MIME);
                        if (mime == null) continue;
                        if (mime.startsWith("video/") && inVideo < 0) {
                            inVideo = i;
                            if (!started) {
                                outVideo = muxer.addTrack(f);
                                if (f.containsKey("rotation-degrees")) {
                                    muxer.setOrientationHint(f.getInteger("rotation-degrees"));
                                }
                            }
                        } else if (mime.startsWith("audio/") && inAudio < 0) {
                            inAudio = i;
                            if (!started) outAudio = muxer.addTrack(f);
                        }
                    }
                    if (inVideo < 0) throw new IllegalStateException("a part has no picture");
                    if (!started) {
                        muxer.start();
                        started = true;
                    }
                    long end = offsetUs;
                    end = Math.max(end, copy(ex, inVideo, outVideo, muxer, buf, info, offsetUs));
                    if (inAudio >= 0 && outAudio >= 0) {
                        end = Math.max(end, copy(ex, inAudio, outAudio, muxer, buf, info, offsetUs));
                    }
                    // the next part starts one frame after the last picture of this one
                    offsetUs = end + 33_000;
                } finally {
                    ex.release();
                }
            }
        } finally {
            try {
                if (started) muxer.stop();
            } finally {
                muxer.release();
            }
        }
        return offsetUs;
    }

    /** Copies one track; returns the time of its last sample (with the offset). */
    private static long copy(MediaExtractor ex, int track, int outTrack, MediaMuxer muxer,
                             ByteBuffer buf, MediaCodec.BufferInfo info, long offsetUs) {
        ex.selectTrack(track);
        ex.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC);
        long last = offsetUs;
        long first = -1;
        while (true) {
            buf.clear();
            int size = ex.readSampleData(buf, 0);
            if (size < 0) break;
            long t = ex.getSampleTime();
            if (first < 0) first = t;
            info.offset = 0;
            info.size = size;
            info.presentationTimeUs = offsetUs + Math.max(0, t - first);
            int flags = 0;
            if ((ex.getSampleFlags() & MediaExtractor.SAMPLE_FLAG_SYNC) != 0) flags |= MediaCodec.BUFFER_FLAG_KEY_FRAME;
            info.flags = flags;
            muxer.writeSampleData(outTrack, buf, info);
            last = Math.max(last, info.presentationTimeUs);
            ex.advance();
        }
        ex.unselectTrack(track);
        return last;
    }
}
