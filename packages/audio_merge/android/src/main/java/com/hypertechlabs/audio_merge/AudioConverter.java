package com.hypertechlabs.audio_merge;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMuxer;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;

/**
 * Turns any audio file the phone can play (mp3, m4a, aac, wav, ogg, flac, ...) into AAC audio in
 * an .mp4 container, at most [maxUs] long, counted from the start of the file.
 *
 * - a file that already is AAC is copied sample by sample (no loss, very fast);
 * - everything else is decoded and encoded again (AAC-LC, 128 kbit/s stereo).
 *
 * The result can be mixed under a video by AudioMerger and is small enough to upload (about
 * 1 MB per minute).
 */
final class AudioConverter {
    private AudioConverter() {}

    private static final long TIMEOUT_US = 10000;

    /** Returns the length of the written file in microseconds. */
    static long toAac(String inPath, String outPath, long maxUs) throws IOException {
        MediaExtractor ex = new MediaExtractor();
        boolean ok = false;
        try {
            ex.setDataSource(inPath);
            int track = -1;
            for (int i = 0; i < ex.getTrackCount(); i++) {
                String mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME);
                if (mime != null && mime.startsWith("audio/")) {
                    track = i;
                    break;
                }
            }
            if (track < 0) throw new IOException("This file has no sound.");
            ex.selectTrack(track);
            MediaFormat format = ex.getTrackFormat(track);
            String mime = format.getString(MediaFormat.KEY_MIME);
            long total = format.containsKey(MediaFormat.KEY_DURATION) ? format.getLong(MediaFormat.KEY_DURATION) : 0;
            long limit = total > 0 ? Math.min(maxUs, total) : maxUs;

            File out = new File(outPath);
            if (out.exists() && !out.delete()) throw new IOException("Cannot replace the output file.");
            long written;
            if ("audio/mp4a-latm".equals(mime)) {
                written = copyAac(ex, format, outPath, limit);
            } else {
                written = transcode(ex, format, mime, outPath, limit);
            }
            ok = true;
            return written;
        } catch (RuntimeException e) {
            throw new IOException("This audio file cannot be used: " + e.getMessage(), e);
        } finally {
            ex.release();
            if (!ok) new File(outPath).delete();
        }
    }

    // ---------------------------------------------------------------- copy

    private static long copyAac(MediaExtractor ex, MediaFormat format, String outPath, long limitUs)
            throws IOException {
        MediaMuxer mux = new MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
        boolean started = false;
        try {
            int t = mux.addTrack(format);
            mux.start();
            started = true;
            ByteBuffer buf = ByteBuffer.allocate(1024 * 1024);
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            long first = ex.getSampleTime();
            long last = 0;
            while (first >= 0) {
                long ts = ex.getSampleTime();
                if (ts < 0) break;
                long rel = Math.max(0, ts - first);
                if (rel > limitUs) break;
                buf.clear();
                int n = ex.readSampleData(buf, 0);
                if (n < 0) break;
                info.set(0, n, rel, MediaCodec.BUFFER_FLAG_KEY_FRAME);
                mux.writeSampleData(t, buf, info);
                last = rel;
                if (!ex.advance()) break;
            }
            return Math.max(last, Math.min(limitUs, last + 23220));
        } finally {
            try {
                if (started) mux.stop();
            } finally {
                mux.release();
            }
        }
    }

    // ------------------------------------------------------------ transcode

    private static long transcode(MediaExtractor ex, MediaFormat inFormat, String mime, String outPath,
                                  long limitUs) throws IOException {
        MediaCodec dec = MediaCodec.createDecoderByType(mime);
        MediaCodec enc = null;
        MediaMuxer mux = null;
        boolean muxStarted = false;
        try {
            dec.configure(inFormat, null, null, 0);
            dec.start();
            mux = new MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);

            MediaCodec.BufferInfo decInfo = new MediaCodec.BufferInfo();
            MediaCodec.BufferInfo encInfo = new MediaCodec.BufferInfo();
            boolean inDone = false;
            boolean decEos = false;
            boolean encInEos = false;
            boolean encDone = false;
            byte[] pending = null;
            int pendingPos = 0;
            int sampleRate = 0;
            int channels = 0;
            long pcmBytes = 0;
            int outTrack = -1;
            long first = ex.getSampleTime();
            long lastUs = 0;
            long stuckSince = System.nanoTime();

            while (!encDone) {
                boolean progressed = false;

                // 1. compressed audio -> decoder
                if (!inDone) {
                    int ii = dec.dequeueInputBuffer(TIMEOUT_US);
                    if (ii >= 0) {
                        ByteBuffer ib = dec.getInputBuffer(ii);
                        long ts = ex.getSampleTime();
                        int n = ts < 0 ? -1 : ex.readSampleData(ib, 0);
                        if (n < 0 || ts - first > limitUs) {
                            dec.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inDone = true;
                        } else {
                            dec.queueInputBuffer(ii, 0, n, ts, 0);
                            ex.advance();
                        }
                        progressed = true;
                    }
                }

                // 2. decoder -> a block of PCM (only when the last one has been passed on)
                if (pending == null && !decEos) {
                    int oi = dec.dequeueOutputBuffer(decInfo, TIMEOUT_US);
                    if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        progressed = true;
                    } else if (oi >= 0) {
                        progressed = true;
                        if (enc == null) {
                            MediaFormat of = dec.getOutputFormat();
                            sampleRate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE);
                            channels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
                            if (channels < 1 || channels > 2) {
                                throw new IOException("Only mono and stereo audio is supported.");
                            }
                            MediaFormat ef = MediaFormat.createAudioFormat("audio/mp4a-latm", sampleRate, channels);
                            ef.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
                            ef.setInteger(MediaFormat.KEY_BIT_RATE, channels == 1 ? 96000 : 128000);
                            ef.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 32768);
                            enc = MediaCodec.createEncoderByType("audio/mp4a-latm");
                            enc.configure(ef, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
                            enc.start();
                        }
                        if (decInfo.size > 0) {
                            ByteBuffer ob = dec.getOutputBuffer(oi);
                            ob.position(decInfo.offset);
                            ob.limit(decInfo.offset + decInfo.size);
                            pending = new byte[decInfo.size];
                            ob.get(pending);
                            pendingPos = 0;
                        }
                        if ((decInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) decEos = true;
                        dec.releaseOutputBuffer(oi, false);
                    }
                }

                // 3. PCM -> encoder (in pieces that fit its buffers)
                if (enc != null && !encInEos) {
                    if (pending != null) {
                        int ei = enc.dequeueInputBuffer(TIMEOUT_US);
                        if (ei >= 0) {
                            ByteBuffer ib = enc.getInputBuffer(ei);
                            ib.clear();
                            int n = Math.min(ib.remaining(), pending.length - pendingPos);
                            ib.put(pending, pendingPos, n);
                            long pts = pcmBytes * 1000000L / ((long) sampleRate * channels * 2);
                            enc.queueInputBuffer(ei, 0, n, pts, 0);
                            pcmBytes += n;
                            pendingPos += n;
                            if (pendingPos >= pending.length) pending = null;
                            progressed = true;
                        }
                    } else if (decEos) {
                        int ei = enc.dequeueInputBuffer(TIMEOUT_US);
                        if (ei >= 0) {
                            long pts = pcmBytes * 1000000L / ((long) sampleRate * channels * 2);
                            enc.queueInputBuffer(ei, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            encInEos = true;
                            progressed = true;
                        }
                    }
                } else if (enc == null && decEos) {
                    throw new IOException("This file has no sound.");
                }

                // 4. encoder -> file
                if (enc != null) {
                    int eo = enc.dequeueOutputBuffer(encInfo, 0);
                    while (eo != MediaCodec.INFO_TRY_AGAIN_LATER) {
                        progressed = true;
                        if (eo == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                            outTrack = mux.addTrack(enc.getOutputFormat());
                            mux.start();
                            muxStarted = true;
                        } else if (eo >= 0) {
                            ByteBuffer eb = enc.getOutputBuffer(eo);
                            if ((encInfo.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) encInfo.size = 0;
                            if (encInfo.size > 0 && muxStarted) {
                                eb.position(encInfo.offset);
                                eb.limit(encInfo.offset + encInfo.size);
                                mux.writeSampleData(outTrack, eb, encInfo);
                                lastUs = encInfo.presentationTimeUs;
                            }
                            enc.releaseOutputBuffer(eo, false);
                            if ((encInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                encDone = true;
                                break;
                            }
                        }
                        eo = enc.dequeueOutputBuffer(encInfo, 0);
                    }
                }

                if (progressed) {
                    stuckSince = System.nanoTime();
                } else if (System.nanoTime() - stuckSince > 20L * 1000000000L) {
                    throw new IOException("Converting the audio took too long.");
                }
            }
            if (!muxStarted) throw new IOException("This file has no sound.");
            return Math.min(limitUs, lastUs + 23220);
        } finally {
            try {
                if (muxStarted) mux.stop();
            } catch (RuntimeException ignored) {
                // nothing to finish
            }
            try {
                if (mux != null) mux.release();
            } catch (RuntimeException ignored) {
                // nothing to release
            }
            try {
                dec.stop();
            } catch (RuntimeException ignored) {
                // already stopped
            }
            dec.release();
            if (enc != null) {
                try {
                    enc.stop();
                } catch (RuntimeException ignored) {
                    // already stopped
                }
                enc.release();
            }
        }
    }
}
