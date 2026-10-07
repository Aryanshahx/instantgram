/// Native side of the app's "put a song into a video" feature. The Dart wrapper lives in the
/// app (`lib/services/audio_merger.dart`); this package only carries the Android code.
library;

/// Name of the method channel the Android code answers on.
const String kAudioMergeChannel = 'com.hypertechlabs.audio_merge';
