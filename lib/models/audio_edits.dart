/// How the sound of a post or clip is put together in the editor.
///
/// * [songStart]: which part of the song plays (seconds into the song);
/// * [songVolume] and [originalVolume]: the song and the video's own sound (0-1);
/// * [fadeIn] / [fadeOut]: seconds the song takes to come in and to go away;
/// * [voicePath] / [voiceVolume]: a voiceover recorded over the clip in the editor.
///
/// Videos get all of it mixed into the file on the phone. Photo posts and photo clips play
/// their song next to the picture, starting at [songStart] at [songVolume].
class AudioEdits {
  const AudioEdits({
    this.songStart = 0,
    this.songVolume = 1,
    this.originalVolume = 0,
    this.fadeIn = 0,
    this.fadeOut = 0,
    this.voicePath = '',
    this.voiceVolume = 1,
  });

  /// Nothing changed: the song from its start, full volume, the video's own sound left out
  /// under a song (the way clips always worked).
  static const AudioEdits none = AudioEdits();

  final double songStart;
  final double songVolume;
  final double originalVolume;
  final double fadeIn;
  final double fadeOut;
  final String voicePath;
  final double voiceVolume;

  /// Longest fade that can be chosen, in seconds.
  static const double maxFade = 3;

  bool get hasVoice => voicePath.isNotEmpty;

  /// True when only the defaults are set.
  bool get isDefault =>
      songStart == 0 &&
      songVolume == 1 &&
      originalVolume == 0 &&
      fadeIn == 0 &&
      fadeOut == 0 &&
      !hasVoice;

  /// True when the song alone cannot simply be copied under the picture: something has to
  /// be mixed (a start point, a volume, a fade, the original sound or a voiceover).
  bool get needsMix => !isDefault;

  AudioEdits copyWith({
    double? songStart,
    double? songVolume,
    double? originalVolume,
    double? fadeIn,
    double? fadeOut,
    String? voicePath,
    double? voiceVolume,
  }) => AudioEdits(
    songStart: (songStart ?? this.songStart).clamp(0.0, 3600.0).toDouble(),
    songVolume: (songVolume ?? this.songVolume).clamp(0.0, 1.0).toDouble(),
    originalVolume: (originalVolume ?? this.originalVolume)
        .clamp(0.0, 1.0)
        .toDouble(),
    fadeIn: (fadeIn ?? this.fadeIn).clamp(0.0, maxFade).toDouble(),
    fadeOut: (fadeOut ?? this.fadeOut).clamp(0.0, maxFade).toDouble(),
    voicePath: voicePath ?? this.voicePath,
    voiceVolume: (voiceVolume ?? this.voiceVolume).clamp(0.0, 1.0).toDouble(),
  );

  /// The same without the voiceover.
  AudioEdits withoutVoice() => AudioEdits(
    songStart: songStart,
    songVolume: songVolume,
    originalVolume: originalVolume,
    fadeIn: fadeIn,
    fadeOut: fadeOut,
  );

  @override
  bool operator ==(Object other) =>
      other is AudioEdits &&
      other.songStart == songStart &&
      other.songVolume == songVolume &&
      other.originalVolume == originalVolume &&
      other.fadeIn == fadeIn &&
      other.fadeOut == fadeOut &&
      other.voicePath == voicePath &&
      other.voiceVolume == voiceVolume;

  @override
  int get hashCode => Object.hash(
    songStart,
    songVolume,
    originalVolume,
    fadeIn,
    fadeOut,
    voicePath,
    voiceVolume,
  );
}

/// Where the song must be (seconds into the song) while the video is at [videoSec].
///
/// The clip starts at [trimStart] in the video and plays at [speed]; the song starts at
/// [songStart]. A song shorter than the clip starts again from [songStart] ([songLength] 0 =
/// unknown, never wraps). This is what the editor and the preview follow, and it is exactly
/// how the sound is laid down when the clip is saved.
double songPositionFor({
  required double videoSec,
  double trimStart = 0,
  double songStart = 0,
  double speed = 1,
  double songLength = 0,
}) {
  final s = speed <= 0 ? 1.0 : speed;
  final clip = (videoSec - trimStart) / s;
  final into = clip < 0 ? 0.0 : clip;
  if (songLength > 0 && songStart + into >= songLength) {
    final span = songLength - songStart;
    if (span <= 0.05) return songStart;
    return songStart + (into % span);
  }
  return songStart + into;
}

/// The song is this far off (seconds) from where it should be: past [tolerance] it is moved.
bool songIsOff(double actual, double wanted, {double tolerance = 0.2}) =>
    (actual - wanted).abs() > tolerance;

/// The clip's speeds offered in the editor.
const List<double> kClipSpeeds = [0.5, 0.75, 1, 1.5, 2];

/// "0.5x", "1x", "1.5x".
String speedLabel(double s) {
  final t = s == s.roundToDouble() ? s.toStringAsFixed(0) : '$s';
  return '${t}x';
}
