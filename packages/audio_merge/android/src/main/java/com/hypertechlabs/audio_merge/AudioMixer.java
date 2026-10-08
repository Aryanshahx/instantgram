package com.hypertechlabs.audio_merge;

import android.media.AudioFormat;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMetadataRetriever;
import android.media.MediaMuxer;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

/**
 * Builds the sound of a clip from up to three parts and writes it under the picture:
 *
 *   - the song, starting [songStartUs] into it, at [songGain], with a fade in and a fade out;
 *   - the video's own sound at [origGain] (0 = left out);
 *   - a voiceover recorded over the clip, at [voiceGain].
 *
 * The picture is copied byte for byte (no loss). With [speed] other than 1 the picture's times
 * are stretched (0.5 = slow motion, 2 = twice as fast); the sound is not stretched, it is laid
 * over the faster or slower picture. The sound is mixed as 44.1 kHz stereo and encoded as AAC.
 *
 * Every clip is at most 60 s, so each part is decoded into memory (about 10 MB at most).
 */
final class AudioMixer {
    private AudioMixer() {}

    static final int RATE = 44100;
    private static final long TIMEOUT_US = 10000;

    /** What to mix. Times are microseconds, gains 0..2 (1 = as recorded). */
    static final class Params {
        String video;
        String song;
        long songStartUs;
        double songGain = 1;
        double origGain;
        String voice;
        double voiceGain = 1;
        long fadeInUs;
        long fadeOutUs;
        double speed = 1;
        long maxUs = 60_000_000L;
        /** true = the clip ends when the song ends (a 30 s preview); false = video length. */
        boolean cutToSong = true;
        /** Quarter turns to the right added to the video's own rotation (0-3). */
        int turns;
    }

    /** Returns the length of the written file in microseconds. */
    static long mix(Params p, String outPath) throws IOException {
        if (p.video == null) throw new IOException("The video is missing.");
        double speed = p.speed <= 0 ? 1 : Math.max(0.25, Math.min(4, p.speed));

        MediaExtractor video = new MediaExtractor();
        MediaMuxer muxer = null;
        boolean started = false;
        boolean ok = false;
        try {
            video.setDataSource(p.video);
            int vTrack = findTrack(video, "video/");
            if (vTrack < 0) throw new IOException("The video has no picture.");
            MediaFormat vFormat = video.getTrackFormat(vTrack);
            long vDur = duration(vFormat);

            // how long the result is
            long limit = p.maxUs;
            if (vDur > 0) limit = Math.min(limit, (long) (vDur / speed));

            short[] song = null;
            if (p.song != null && p.songGain > 0) {
                song = decode(p.song, Math.max(0, p.songStartUs), limit);
                if (p.cutToSong && song.length > 0) {
                    limit = Math.min(limit, framesToUs(song.length / 2));
                }
            }
            short[] orig = null;
            if (p.origGain > 0 && hasAudio(p.video)) {
                orig = decode(p.video, 0, limit);
            }
            short[] voice = null;
            if (p.voice != null && p.voiceGain > 0) {
                voice = decode(p.voice, 0, limit);
            }
            if (limit <= 0) throw new IOException("The clip would be empty.");

            int frames = (int) (limit * RATE / 1_000_000L);
            short[] mixed = mixDown(frames, song, p.songGain, p.fadeInUs, p.fadeOutUs,
                    orig, p.origGain, voice, p.voiceGain);

            List<Encoded> aac = new ArrayList<>();
            MediaFormat aFormat = encode(mixed, aac);

            File out = new File(outPath);
            if (out.exists() && !out.delete()) throw new IOException("Cannot replace the output file.");
            muxer = new MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            int rotation = (rotationOf(p.video) + 90 * ((p.turns % 4 + 4) % 4)) % 360;
            if (rotation != 0) muxer.setOrientationHint(rotation);
            int vOut = muxer.addTrack(vFormat);
            int aOut = muxer.addTrack(aFormat);
            muxer.start();
            started = true;

            // the picture, its times stretched by the speed
            video.selectTrack(vTrack);
            int size = 4 * 1024 * 1024;
            if (vFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                size = Math.max(size, vFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE));
            }
            ByteBuffer buffer = ByteBuffer.allocate(size);
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            long first = video.getSampleTime();
            while (first >= 0) {
                long t = video.getSampleTime();
                if (t < 0) break;
                long rel = (long) (Math.max(0, t - first) / speed);
                if (rel > limit) break;
                buffer.clear();
                int n = video.readSampleData(buffer, 0);
                if (n < 0) break;
                info.set(0, n, rel, video.getSampleFlags() & MediaCodec.BUFFER_FLAG_KEY_FRAME);
                muxer.writeSampleData(vOut, buffer, info);
                if (!video.advance()) break;
            }

            // the sound
            for (Encoded e : aac) {
                info.set(0, e.data.length, e.pts, e.flags);
                muxer.writeSampleData(aOut, ByteBuffer.wrap(e.data), info);
            }
            ok = true;
            return limit;
        } catch (RuntimeException e) {
            throw new IOException("The sound could not be mixed: " + e.getMessage(), e);
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
            if (!ok) new File(outPath).delete();
        }
    }

    // ------------------------------------------------------------------ mixing

    /** Adds the parts sample by sample (stereo, interleaved). Pure: tested on the computer. */
    static short[] mixDown(int frames, short[] song, double songGain, long fadeInUs, long fadeOutUs,
                           short[] orig, double origGain, short[] voice, double voiceGain) {
        short[] out = new short[frames * 2];
        long fadeIn = fadeInUs * RATE / 1_000_000L;
        long fadeOut = fadeOutUs * RATE / 1_000_000L;
        for (int f = 0; f < frames; f++) {
            double fade = 1;
            if (fadeIn > 0 && f < fadeIn) fade = (double) f / fadeIn;
            if (fadeOut > 0 && f > frames - fadeOut) {
                fade = Math.min(fade, (double) (frames - f) / fadeOut);
            }
            for (int c = 0; c < 2; c++) {
                int i = f * 2 + c;
                double v = 0;
                if (song != null && i < song.length) v += song[i] * songGain * fade;
                if (orig != null && i < orig.length) v += orig[i] * origGain;
                if (voice != null && i < voice.length) v += voice[i] * voiceGain;
                if (v > Short.MAX_VALUE) v = Short.MAX_VALUE;
                if (v < Short.MIN_VALUE) v = Short.MIN_VALUE;
                out[i] = (short) Math.round(v);
            }
        }
        return out;
    }

    /** Linear resampling of interleaved stereo [src] from [from] Hz to [RATE]. Pure. */
    static short[] resample(short[] src, int from) {
        if (from == RATE || src.length == 0) return src;
        int inFrames = src.length / 2;
        int outFrames = (int) ((long) inFrames * RATE / from);
        short[] out = new short[outFrames * 2];
        for (int f = 0; f < outFrames; f++) {
            double pos = (double) f * from / RATE;
            int a = (int) pos;
            int b = Math.min(a + 1, inFrames - 1);
            double t = pos - a;
            for (int c = 0; c < 2; c++) {
                out[f * 2 + c] = (short) Math.round(src[a * 2 + c] * (1 - t) + src[b * 2 + c] * t);
            }
        }
        return out;
    }

    static long framesToUs(long frames) {
        return frames * 1_000_000L / RATE;
    }

    // ---------------------------------------------------------------- decoding

    /** Growing array of shorts. */
    private static final class Shorts {
        short[] a = new short[RATE * 2 * 8];
        int n;

        void add(short v) {
            if (n == a.length) {
                short[] b = new short[a.length * 2];
                System.arraycopy(a, 0, b, 0, n);
                a = b;
            }
            a[n++] = v;
        }

        short[] done() {
            short[] b = new short[n];
            System.arraycopy(a, 0, b, 0, n);
            return b;
        }
    }

    private static boolean hasAudio(String path) {
        MediaExtractor e = new MediaExtractor();
        try {
            e.setDataSource(path);
            return findTrack(e, "audio/") >= 0;
        } catch (IOException | RuntimeException ignored) {
            return false;
        } finally {
            e.release();
        }
    }

    /**
     * Decodes the sound of [path] from [startUs] for at most [lengthUs] into 44.1 kHz stereo.
     * A file without sound gives an empty array.
     */
    static short[] decode(String path, long startUs, long lengthUs) throws IOException {
        MediaExtractor ex = new MediaExtractor();
        MediaCodec dec = null;
        try {
            ex.setDataSource(path);
            int track = findTrack(ex, "audio/");
            if (track < 0) return new short[0];
            ex.selectTrack(track);
            MediaFormat format = ex.getTrackFormat(track);
            String mime = format.getString(MediaFormat.KEY_MIME);
            int rate = format.containsKey(MediaFormat.KEY_SAMPLE_RATE)
                    ? format.getInteger(MediaFormat.KEY_SAMPLE_RATE) : RATE;
            int channels = format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)
                    ? format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) : 2;
            boolean floats = false;
            if (startUs > 0) ex.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC);

            dec = MediaCodec.createDecoderByType(mime);
            dec.configure(format, null, null, 0);
            dec.start();

            Shorts out = new Shorts();
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            boolean inDone = false;
            boolean outDone = false;
            long endUs = startUs + lengthUs;
            long stuckSince = System.nanoTime();
            while (!outDone) {
                boolean progressed = false;
                if (!inDone) {
                    int ii = dec.dequeueInputBuffer(TIMEOUT_US);
                    if (ii >= 0) {
                        ByteBuffer ib = dec.getInputBuffer(ii);
                        long ts = ex.getSampleTime();
                        int n = ts < 0 ? -1 : ex.readSampleData(ib, 0);
                        if (n < 0 || ts > endUs + 500_000L) {
                            dec.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inDone = true;
                        } else {
                            dec.queueInputBuffer(ii, 0, n, ts, 0);
                            ex.advance();
                        }
                        progressed = true;
                    }
                }
                int oi = dec.dequeueOutputBuffer(info, TIMEOUT_US);
                if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat of = dec.getOutputFormat();
                    if (of.containsKey(MediaFormat.KEY_SAMPLE_RATE)) rate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE);
                    if (of.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) channels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
                    floats = of.containsKey(MediaFormat.KEY_PCM_ENCODING)
                            && of.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT;
                    progressed = true;
                } else if (oi >= 0) {
                    progressed = true;
                    if (info.size > 0) {
                        ByteBuffer ob = dec.getOutputBuffer(oi);
                        ob.position(info.offset);
                        ob.limit(info.offset + info.size);
                        ob.order(ByteOrder.nativeOrder());
                        int bytesPerSample = floats ? 4 : 2;
                        int count = info.size / bytesPerSample;
                        int frameCount = count / Math.max(1, channels);
                        // skip what lies before the wanted start (the seek lands on a sync point)
                        long skip = 0;
                        if (info.presentationTimeUs < startUs) {
                            skip = (startUs - info.presentationTimeUs) * rate / 1_000_000L;
                        }
                        for (int f = 0; f < frameCount; f++) {
                            float l;
                            float r;
                            if (floats) {
                                l = ob.getFloat();
                                r = channels > 1 ? ob.getFloat() : l;
                                for (int c = 2; c < channels; c++) ob.getFloat();
                            } else {
                                l = ob.getShort() / 32768f;
                                r = channels > 1 ? ob.getShort() / 32768f : l;
                                for (int c = 2; c < channels; c++) ob.getShort();
                            }
                            if (f < skip) continue;
                            out.add(toShort(l));
                            out.add(toShort(r));
                        }
                    }
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) outDone = true;
                    dec.releaseOutputBuffer(oi, false);
                    // enough sound decoded
                    if ((long) out.n / 2 * 1_000_000L / Math.max(1, rate) >= lengthUs) outDone = true;
                }
                if (progressed) {
                    stuckSince = System.nanoTime();
                } else if (System.nanoTime() - stuckSince > 5_000_000_000L) {
                    throw new IOException("The audio decoder stopped answering.");
                }
            }
            short[] pcm = resample(out.done(), rate);
            int maxFrames = (int) (lengthUs * RATE / 1_000_000L);
            if (pcm.length > maxFrames * 2) {
                short[] cut = new short[maxFrames * 2];
                System.arraycopy(pcm, 0, cut, 0, cut.length);
                pcm = cut;
            }
            return pcm;
        } finally {
            if (dec != null) {
                try {
                    dec.stop();
                } catch (RuntimeException ignored) {
                    // already stopped
                }
                dec.release();
            }
            ex.release();
        }
    }

    private static short toShort(float v) {
        float s = v * 32767f;
        if (s > 32767f) s = 32767f;
        if (s < -32768f) s = -32768f;
        return (short) s;
    }

    // ---------------------------------------------------------------- encoding

    private static final class Encoded {
        final byte[] data;
        final long pts;
        final int flags;

        Encoded(byte[] data, long pts, int flags) {
            this.data = data;
            this.pts = pts;
            this.flags = flags;
        }
    }

    /** Encodes [pcm] (44.1 kHz stereo) to AAC into [out]; returns the track format. */
    private static MediaFormat encode(short[] pcm, List<Encoded> out) throws IOException {
        MediaFormat ef = MediaFormat.createAudioFormat("audio/mp4a-latm", RATE, 2);
        ef.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
        ef.setInteger(MediaFormat.KEY_BIT_RATE, 128000);
        ef.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384);
        MediaCodec enc = MediaCodec.createEncoderByType("audio/mp4a-latm");
        MediaFormat format = null;
        try {
            enc.configure(ef, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            enc.start();
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            int pos = 0; // in shorts
            boolean inEos = false;
            boolean done = false;
            long stuckSince = System.nanoTime();
            while (!done) {
                boolean progressed = false;
                if (!inEos) {
                    int ii = enc.dequeueInputBuffer(TIMEOUT_US);
                    if (ii >= 0) {
                        ByteBuffer ib = enc.getInputBuffer(ii);
                        ib.clear();
                        ib.order(ByteOrder.nativeOrder());
                        long pts = framesToUs(pos / 2);
                        if (pos >= pcm.length) {
                            enc.queueInputBuffer(ii, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inEos = true;
                        } else {
                            int n = Math.min(ib.remaining() / 2, pcm.length - pos);
                            n -= n % 2; // whole frames
                            if (n <= 0) n = Math.min(2, pcm.length - pos);
                            for (int i = 0; i < n; i++) ib.putShort(pcm[pos + i]);
                            enc.queueInputBuffer(ii, 0, n * 2, pts, 0);
                            pos += n;
                        }
                        progressed = true;
                    }
                }
                int oi = enc.dequeueOutputBuffer(info, TIMEOUT_US);
                if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    format = enc.getOutputFormat();
                    progressed = true;
                } else if (oi >= 0) {
                    progressed = true;
                    boolean config = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
                    if (info.size > 0 && !config) {
                        ByteBuffer ob = enc.getOutputBuffer(oi);
                        ob.position(info.offset);
                        ob.limit(info.offset + info.size);
                        byte[] b = new byte[info.size];
                        ob.get(b);
                        out.add(new Encoded(b, info.presentationTimeUs,
                                info.flags & ~MediaCodec.BUFFER_FLAG_END_OF_STREAM));
                    }
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) done = true;
                    enc.releaseOutputBuffer(oi, false);
                }
                if (progressed) {
                    stuckSince = System.nanoTime();
                } else if (System.nanoTime() - stuckSince > 5_000_000_000L) {
                    throw new IOException("The audio encoder stopped answering.");
                }
            }
            if (format == null) throw new IOException("The audio encoder gave no format.");
            return format;
        } finally {
            try {
                enc.stop();
            } catch (RuntimeException ignored) {
                // already stopped
            }
            enc.release();
        }
    }

    // ------------------------------------------------------------------ helpers

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
