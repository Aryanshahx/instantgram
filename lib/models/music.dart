/// The app's own music library. Users pick from these; nothing is imported from the phone.
///
/// To add a track: put an mp3 in `assets/music/`, add a line here, and publish a new version.
/// (Old posts keep working: a post only stores the track's [id].)
class MusicTrack {
  const MusicTrack({
    required this.id,
    required this.title,
    required this.mood,
    required this.seconds,
    required this.bpm,
  });

  final String id;
  final String title;
  final String mood;

  /// Length of the loop in seconds (it repeats for as long as the clip lasts).
  final int seconds;
  final int bpm;

  String get asset => 'assets/music/$id.mp3';
}

const List<MusicTrack> kMusicLibrary = [
  MusicTrack(
    id: 'volt_rush',
    title: 'Volt Rush',
    mood: 'Energy',
    seconds: 31,
    bpm: 124,
  ),
  MusicTrack(
    id: 'sunny_side',
    title: 'Sunny Side',
    mood: 'Happy',
    seconds: 34,
    bpm: 112,
  ),
  MusicTrack(
    id: 'golden_hour',
    title: 'Golden Hour',
    mood: 'Warm',
    seconds: 31,
    bpm: 92,
  ),
  MusicTrack(
    id: 'lofi_sunday',
    title: 'Lo-Fi Sunday',
    mood: 'Chill',
    seconds: 31,
    bpm: 78,
  ),
  MusicTrack(
    id: 'neon_nights',
    title: 'Neon Nights',
    mood: 'Retro',
    seconds: 29,
    bpm: 100,
  ),
  MusicTrack(
    id: 'street_beat',
    title: 'Street Beat',
    mood: 'Urban',
    seconds: 30,
    bpm: 95,
  ),
  MusicTrack(id: 'pulse', title: 'Pulse', mood: 'Hype', seconds: 27, bpm: 140),
  MusicTrack(
    id: 'dreamscape',
    title: 'Dreamscape',
    mood: 'Calm',
    seconds: 27,
    bpm: 70,
  ),
];

/// The track with [id], or null (for example a track from a newer version of the app).
MusicTrack? musicById(String id) {
  for (final t in kMusicLibrary) {
    if (t.id == id) return t;
  }
  return null;
}
