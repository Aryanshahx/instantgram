package com.hypertechlabs.audio_merge;

import android.content.ComponentName;
import android.content.Context;
import android.content.pm.PackageManager;

import androidx.annotation.NonNull;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Switches the launcher icon. The app's manifest has one activity-alias per icon
 * ("<applicationId>.IconClassic", ".IconMidnight", ...); exactly one is enabled.
 * Channel "instantgram/app_icon": get() -> id, set(id) -> id, available() -> bool.
 */
final class AppIcon implements MethodChannel.MethodCallHandler {
    static final String[] IDS = {"classic", "midnight", "sunset", "ocean", "mono", "gold"};

    private final Context context;

    AppIcon(Context context) {
        this.context = context.getApplicationContext();
    }

    private ComponentName alias(String id) {
        String name = "Icon" + Character.toUpperCase(id.charAt(0)) + id.substring(1);
        return new ComponentName(context.getPackageName(), context.getPackageName() + "." + name);
    }

    @SuppressWarnings("deprecation")
    private boolean exists(ComponentName c) {
        try {
            context.getPackageManager().getActivityInfo(c, PackageManager.MATCH_DISABLED_COMPONENTS);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    private boolean enabled(String id) {
        int s = context.getPackageManager().getComponentEnabledSetting(alias(id));
        if (s == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT) return "classic".equals(id);
        return s == PackageManager.COMPONENT_ENABLED_STATE_ENABLED;
    }

    private String current() {
        for (String id : IDS) {
            if (enabled(id)) return id;
        }
        return "classic";
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "available":
                    result.success(exists(alias("classic")));
                    return;
                case "get":
                    result.success(current());
                    return;
                case "set": {
                    String id = call.argument("id");
                    boolean known = false;
                    for (String k : IDS) known |= k.equals(id);
                    if (!known || !exists(alias(id))) {
                        result.error("missing", "this icon is not in the app", null);
                        return;
                    }
                    PackageManager pm = context.getPackageManager();
                    // the new one first, so there is always an icon
                    pm.setComponentEnabledSetting(alias(id),
                            PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP);
                    for (String k : IDS) {
                        if (k.equals(id)) continue;
                        pm.setComponentEnabledSetting(alias(k),
                                PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP);
                    }
                    result.success(id);
                    return;
                }
                default:
                    result.notImplemented();
            }
        } catch (Exception e) {
            result.error("failed", String.valueOf(e.getMessage()), null);
        }
    }
}
