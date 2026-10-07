package com.hypertechlabs.audio_merge;

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

/** `merge(video, audio, output, maxSeconds)` -> {seconds}. Runs on a background thread. */
public class AudioMergePlugin implements FlutterPlugin, MethodCallHandler {
    private MethodChannel channel;
    private final ExecutorService pool = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        channel = new MethodChannel(binding.getBinaryMessenger(), "com.hypertechlabs.audio_merge");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull final Result result) {
        if (!"merge".equals(call.method)) {
            result.notImplemented();
            return;
        }
        final String video = call.argument("video");
        final String audio = call.argument("audio");
        final String output = call.argument("output");
        Double max = call.argument("maxSeconds");
        final long maxUs = (long) ((max == null ? 30.0 : max) * 1000000.0);
        if (video == null || audio == null || output == null) {
            result.error("bad_args", "video, audio and output are needed", null);
            return;
        }
        pool.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    final long us = AudioMerger.merge(video, audio, output, maxUs);
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
                            result.error("merge_failed", String.valueOf(e.getMessage()), null);
                        }
                    });
                }
            }
        });
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
    }
}
