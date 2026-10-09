# tflite_flutter (photo check): the optional GPU delegate is not part of the app
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.gpu.**
