package com.hypertechlabs.instantgram

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.graphics.Rect
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
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("settings", e.message, null)
                }
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
