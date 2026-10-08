package com.hypertechlabs.audio_merge;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * `merge(video, audio, output, maxSeconds)` and `toAac(input, output, maxSeconds)` -> {seconds}.
 * `mix(...)` builds a clip's sound from song, original sound and voiceover (see AudioMixer).
 * All run on a background thread.
 */
public class AudioMergePlugin implements FlutterPlugin, MethodCallHandler {
    private MethodChannel channel;
    private final ExecutorService pool = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        channel = new MethodChannel(binding.getBinaryMessenger(), "com.hypertechlabs.audio_merge");
        channel.setMethodCallHandler(this);
        createPushChannels(binding.getApplicationContext());
    }

    /** The notification channels the push messages use (Settings > Apps > InstantGram > Notifications). */
    private static void createPushChannels(Context context) {
        if (Build.VERSION.SDK_INT < 26) return;
        try {
            NotificationManager nm = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm == null) return;
            NotificationChannel messages = new NotificationChannel("messages", "Messages", NotificationManager.IMPORTANCE_HIGH);
            messages.setDescription("New chat messages");
            NotificationChannel calls = new NotificationChannel("calls", "Calls", NotificationManager.IMPORTANCE_HIGH);
            calls.setDescription("Incoming voice and video calls");
            NotificationChannel activity = new NotificationChannel("activity", "Activity", NotificationManager.IMPORTANCE_DEFAULT);
            activity.setDescription("Likes, comments, mentions and new followers");
            nm.createNotificationChannel(messages);
            nm.createNotificationChannel(calls);
            nm.createNotificationChannel(activity);
        } catch (Exception ignored) {
            // notifications still arrive in the default channel
        }
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull final Result result) {
        if ("mix".equals(call.method)) {
            mix(call, result);
            return;
        }
        final boolean merge = "merge".equals(call.method);
        final boolean convert = "toAac".equals(call.method);
        if (!merge && !convert) {
            result.notImplemented();
            return;
        }
        final String video = call.argument("video");
        final String audio = call.argument("audio");
        final String input = call.argument("input");
        final String output = call.argument("output");
        Double max = call.argument("maxSeconds");
        final long maxUs = (long) ((max == null ? 30.0 : max) * 1000000.0);
        if (output == null || (merge && (video == null || audio == null)) || (convert && input == null)) {
            result.error("bad_args", "the file names are missing", null);
            return;
        }
        pool.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    final long us = merge
                            ? AudioMerger.merge(video, audio, output, maxUs)
                            : AudioConverter.toAac(input, output, maxUs);
                    final Map<String, Object> out = new HashMap<>();
                    out.put("seconds", us / 1000000.0);
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            result.success(out);
                        }
                    });
                } catch (final Exception e) {
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            result.error(merge ? "merge_failed" : "convert_failed", String.valueOf(e.getMessage()), null);
                        }
                    });
                }
            }
        });
    }

    /**
     * `mix(video, output, song?, songStart, songGain, origGain, voice?, voiceGain, fadeIn,
     * fadeOut, speed, maxSeconds, cutToSong)` -> {seconds}. Seconds are doubles.
     */
    private void mix(@NonNull MethodCall call, @NonNull final Result result) {
        final AudioMixer.Params p = new AudioMixer.Params();
        p.video = call.argument("video");
        final String output = call.argument("output");
        if (p.video == null || output == null) {
            result.error("bad_args", "the file names are missing", null);
            return;
        }
        p.song = call.argument("song");
        p.voice = call.argument("voice");
        p.songStartUs = us(call.argument("songStart"), 0);
        p.songGain = num(call.argument("songGain"), 1);
        p.origGain = num(call.argument("origGain"), 0);
        p.voiceGain = num(call.argument("voiceGain"), 1);
        p.fadeInUs = us(call.argument("fadeIn"), 0);
        p.fadeOutUs = us(call.argument("fadeOut"), 0);
        p.speed = num(call.argument("speed"), 1);
        p.maxUs = us(call.argument("maxSeconds"), 60);
        Object turns = call.argument("turns");
        p.turns = turns instanceof Number ? ((Number) turns).intValue() : 0;
        Boolean cut = call.argument("cutToSong");
        p.cutToSong = cut == null || cut;
        pool.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    final long written = AudioMixer.mix(p, output);
                    final Map<String, Object> out = new HashMap<>();
                    out.put("seconds", written / 1000000.0);
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            result.success(out);
                        }
                    });
                } catch (final Exception e) {
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            result.error("mix_failed", String.valueOf(e.getMessage()), null);
                        }
                    });
                }
            }
        });
    }

    private static double num(Object v, double fallback) {
        return v instanceof Number ? ((Number) v).doubleValue() : fallback;
    }

    private static long us(Object seconds, double fallback) {
        return (long) (num(seconds, fallback) * 1000000.0);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
    }
}
