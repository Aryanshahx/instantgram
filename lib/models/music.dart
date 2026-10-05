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
    this.artist = '',
    this.cover = '',
  });

  /// A track from the Epidemic Sound catalogue (searched through the media service).
  /// [uuid] is Epidemic's own track id; the app stores it as `es:<uuid>`.
  factory MusicTrack.epidemic({
    required String uuid,
    required String title,
    String artist = '',
    int seconds = 0,
    int bpm = 0,
    String cover = '',
  }) => MusicTrack(
    id: '$kEpidemicPrefix$uuid',
    title: title.isEmpty ? 'Epidemic Sound track' : title,
    mood: 'Epidemic Sound',
    seconds: seconds,
    bpm: bpm,
    artist: artist,
    cover: cover,
  );

  final String id;
  final String title;
  final String mood;

  /// Length of the loop in seconds (it repeats for as long as the clip lasts).
  final int seconds;
  final int bpm;

  /// Name of the artist (Epidemic Sound tracks only).
  final String artist;

  /// Small cover picture address (Epidemic Sound tracks only).
  final String cover;

  bool get remote => id.startsWith(kEpidemicPrefix);

  /// Epidemic's id without the `es:` prefix.
  String get remoteId => remote ? id.substring(kEpidemicPrefix.length) : '';

  String get asset => 'assets/music/$id.mp3';

  /// "Title" or "Title \u00b7 Artist", as shown under a username.
  String get label => artist.isEmpty ? title : '$title \u00b7 $artist';
}

const String kEpidemicPrefix = 'es:';

final Map<String, MusicTrack> _remembered = {};

/// Posts and moments only store the id, the title and the artist of an Epidemic Sound track.
/// This keeps them so [musicById] can find the track later (labels, players).
void rememberMusic(String id, String title, String artist) {
  if (!id.startsWith(kEpidemicPrefix) || _remembered.containsKey(id)) return;
  _remembered[id] = MusicTrack.epidemic(
    uuid: id.substring(kEpidemicPrefix.length),
    title: title,
    artist: artist,
  );
}

/// Fields that describe [t] inside a post or moment document.
Map<String, Object> musicDocFields(MusicTrack t) => {
  'musicId': t.id,
  if (t.remote) 'musicTitle': t.title,
  if (t.remote && t.artist.isNotEmpty) 'musicArtist': t.artist,
};

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
  return _remembered[id];
}
