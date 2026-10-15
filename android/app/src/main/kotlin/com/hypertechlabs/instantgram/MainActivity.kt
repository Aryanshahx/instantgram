package com.hypertechlabs.instantgram

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// v0.11: notification channels (messages, muted calls) + settings pages.
// v0.12: + activity channel (likes, comments, followers, views).
// v0.14: + gesture exclusion for the editor timeline.
// v0.15: + app icon switch (activity aliases).
// v0.16: + custom icon = a home-screen shortcut with your own picture.
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createChannels()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "instantgram/system")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "openAppSettings" -> {
                            startActivity(
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                    .setData(Uri.parse("package:$packageName"))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(null)
                        }
                        "openNotificationSettings" -> {
                            val i = if (Build.VERSION.SDK_INT >= 26) {
                                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            } else {
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                    .setData(Uri.parse("package:$packageName"))
                            }
                            startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(null)
                        }
                        "maker" -> result.success(Build.MANUFACTURER ?: "")
                        // push notifications use (tag, id 0): "chat_<chatId>"
                        "cancelNotification" -> {
                            val tag = call.argument<String>("tag")
                            if (tag != null) {
                                getSystemService(NotificationManager::class.java)?.cancel(tag, 0)
                            }
                            result.success(null)
                        }
                        // v0.14: no edge back swipe over the editor timeline
                        // (left, top, right, bottom, ... in pixels)
                        "gestureExclusion" -> {
                            val raw = call.argument<List<Number>>("rects") ?: emptyList()
                            val rects = ArrayList<Rect>()
                            var i = 0
                            while (i + 3 < raw.size) {
                                rects.add(
                                    Rect(
                                        raw[i].toInt(), raw[i + 1].toInt(),
                                        raw[i + 2].toInt(), raw[i + 3].toInt()
                                    )
                                )
                                i += 4
                            }
                            if (Build.VERSION.SDK_INT >= 29) {
                                val v = window.decorView
                                v.post { v.systemGestureExclusionRects = rects }
                            }
                            result.success(null)
                        }
                        // v0.15: app icon
                        "getAppIcon" -> result.success(currentIcon())
                        "setAppIcon" -> {
                            setIcon(call.argument<String>("icon") ?: "default")
                            result.success(currentIcon())
                        }
                        // v0.16: custom icon (pinned shortcut)
                        "canPinShortcut" -> result.success(canPin())
                        "pinShortcut" -> result.success(
                            pinShortcut(
                                call.argument<ByteArray>("png"),
                                call.argument<String>("label") ?: "InstantGram"
                            )
                        )
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("settings", e.message, null)
                }
            }
    }

    private fun canPin(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val sm = getSystemService(ShortcutManager::class.java) ?: return false
        return sm.isRequestPinShortcutSupported
    }

    /** Asks the launcher to add a home-screen icon with [png] (square). */
    private fun pinShortcut(png: ByteArray?, label: String): Boolean {
        if (png == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val sm = getSystemService(ShortcutManager::class.java) ?: return false
        if (!sm.isRequestPinShortcutSupported) return false
        val bmp = BitmapFactory.decodeByteArray(png, 0, png.size) ?: return false
        val open = (packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val info = ShortcutInfo.Builder(this, "custom_icon_" + System.currentTimeMillis())
            .setShortLabel(label.take(20).ifBlank { "InstantGram" })
            .setIcon(Icon.createWithAdaptiveBitmap(bmp))
            .setIntent(open)
            .build()
        return sm.requestPinShortcut(info, null)
    }

    private val icons = listOf("default", "night", "sunset", "ocean", "berry", "mono")

    private fun alias(id: String) = ComponentName(
        packageName,
        "com.hypertechlabs.instantgram.Icon" + id.replaceFirstChar { it.uppercase() }
    )

    private fun isOn(id: String): Boolean {
        return when (packageManager.getComponentEnabledSetting(alias(id))) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> id == "default"
            else -> false
        }
    }

    private fun currentIcon(): String = icons.firstOrNull { it != "default" && isOn(it) }
        ?: "default"

    private fun setIcon(id: String) {
        val want = if (icons.contains(id)) id else "default"
        val pm = packageManager
        // turn the new one on first: there is always one icon
        pm.setComponentEnabledSetting(
            alias(want),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP
        )
        for (other in icons) {
            if (other == want) continue
            pm.setComponentEnabledSetting(
                alias(other),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )
        }
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        val messages = NotificationChannel(
            "messages", "Messages", NotificationManager.IMPORTANCE_HIGH
        ).apply { description = "New chat messages" }
        // v0.12: likes, comments, new followers, views ...
        val activity = NotificationChannel(
            "activity", "Activity", NotificationManager.IMPORTANCE_HIGH
        ).apply { description = "Likes, comments, followers and views" }
        // calls from people you muted: shown, but no sound and no vibration
        val muted = NotificationChannel(
            "calls_muted", "Muted calls", NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Calls from people you muted (silent)"
            setSound(null, null)
            enableVibration(false)
            vibrationPattern = longArrayOf(0L)
        }
        nm.createNotificationChannels(listOf(messages, muted, activity))
    }
}
