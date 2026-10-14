# v0.11: keep the incoming-call plugin (release builds removed parts of it,
# so calls could not ring when the app was closed)
-keep class com.hiennv.flutter_callkit_incoming.** { *; }
-keep class com.google.firebase.messaging.** { *; }
