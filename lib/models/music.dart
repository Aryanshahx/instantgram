import '../core/media_url.dart';

/// A song for a post, a clip or a moment. Where it can come from:
///
/// * the phone: a file the user picks (`my:` ids; the phone turns it into a small AAC file,
///   which is uploaded to the media storage when the post is shared);
/// * Hit songs: 30 second previews from Apple (`it:` ids);
/// * Free music: Creative Commons tracks (`ov:` ids);
/// * `kMusicLibrary`: the app's old built-in loops. They are no longer offered, but posts that
///   were made with them keep playing.
class MusicTrack {
  const MusicTrack({
    required this.id,
    required this.title,
    required this.mood,
    required this.seconds,
    required this.bpm,
    this.artist = '',
    this.cover = '',
    this.previewUrl = '',
    this.localPath = '',
  });

  /// A song picked from the phone, already turned into a small AAC file at [path]. It is not
  /// uploaded yet (that happens when the post is shared; see `DeviceAudio.upload`).
  factory MusicTrack.device({
    required String path,
    required String title,
    int seconds = 0,
  }) => MusicTrack(
    id: kDeviceLocalId,
    title: title.trim().isEmpty ? 'My sound' : title.trim(),
    mood: 'My phone',
    seconds: seconds,
    bpm: 0,
    localPath: path,
  );

  /// A song from the phone after it was uploaded: `my:<storage key>`.
  factory MusicTrack.uploaded({required String key, required String title}) =>
      MusicTrack(
        id: '$kDevicePrefix$key',
        title: title.trim().isEmpty ? 'My sound' : title.trim(),
        mood: 'My phone',
        seconds: 0,
        bpm: 0,
      );

  /// A 30 second preview of a song from Apple (iTunes Search API). The app stores it as
  /// `it:<trackId>`. [previewUrl] is the address of the preview (it is looked up again by
  /// id when it is not known, for example for a post made by someone else).
  factory MusicTrack.apple({
    required String trackId,
    required String title,
    String artist = '',
    int seconds = 30,
    String cover = '',
    String previewUrl = '',
  }) => MusicTrack(
    id: '$kApplePrefix$trackId',
    title: title.isEmpty ? 'Song' : title,
    mood: 'Hit songs',
    seconds: seconds,
    bpm: 0,
    artist: artist,
    cover: cover,
    previewUrl: previewUrl,
  );

  /// A track from the free online catalogue (searched through the media service).
  /// [uuid] is the catalogue's own track id; the app stores it as `ov:<id>`.
  factory MusicTrack.online({
    required String uuid,
    required String title,
    String artist = '',
    int seconds = 0,
    int bpm = 0,
    String cover = '',
  }) => MusicTrack(
    id: '$kOnlinePrefix$uuid',
    title: title.isEmpty ? 'Online track' : title,
    mood: 'Free music',
    seconds: seconds,
    bpm: bpm,
    artist: artist,
    cover: cover,
  );

  final String id;
  final String title;
  final String mood;

  /// Length in seconds (a song plays again from the start for as long as the clip lasts).
  final int seconds;
  final int bpm;

  /// Name of the artist (online tracks only).
  final String artist;

  /// Small cover picture address (online tracks only).
  final String cover;

  /// Address of the 30 second preview (Apple tracks only; may be empty).
  final String previewUrl;

  /// Where the converted file of a song from the phone is (empty once it is uploaded).
  final String localPath;

  /// A track that is not one of the app's old built-in loops: its title is saved with the post.
  bool get remote => isApple || isOnline || isDevice;

  bool get isApple => id.startsWith(kApplePrefix);
  bool get isOnline => id.startsWith(kOnlinePrefix);

  /// A song from the phone (before or after the upload).
  bool get isDevice => id.startsWith(kDevicePrefix);

  /// A song from the phone that is still only on this phone.
  bool get isLocal => isDevice && localPath.isNotEmpty;

  /// Where an uploaded song from the phone can be streamed ('' for the others).
  String get uploadedUrl => isDevice && !isLocal && id != kDeviceLocalId
      ? resolveMediaUrl('m:${id.substring(kDevicePrefix.length)}')
      : '';

  /// The catalogue's id without the `ov:` / `it:` prefix.
  String get remoteId => remote ? id.substring(3) : '';

  String get asset => 'assets/music/$id.mp3';

  /// "Title" or "Title \u00b7 Artist", as shown under a username.
  String get label => artist.isEmpty ? title : '$title \u00b7 $artist';
}

const String kOnlinePrefix = 'ov:';
const String kApplePrefix = 'it:';
const String kDevicePrefix = 'my:';

/// The id of a song from the phone that has not been uploaded yet.
const String kDeviceLocalId = 'my:local';

/// The storage reference (`m:<key>`) of the audio file of a song from the phone, or '' for any
/// other id. Used to delete the file together with its post.
String deviceMusicRef(String musicId) =>
    musicId.startsWith(kDevicePrefix) && musicId != kDeviceLocalId
    ? 'm:${musicId.substring(kDevicePrefix.length)}'
    : '';

final Map<String, MusicTrack> _remembered = {};

/// Posts and moments only store the id, the title and the artist of an online track.
/// This keeps them so [musicById] can find the track later (labels, players).
void rememberMusic(String id, String title, String artist) {
  if (_remembered.containsKey(id)) return;
  if (id.startsWith(kOnlinePrefix)) {
    _remembered[id] = MusicTrack.online(
      uuid: id.substring(kOnlinePrefix.length),
      title: title,
      artist: artist,
    );
  } else if (id.startsWith(kDevicePrefix) && id != kDeviceLocalId) {
    _remembered[id] = MusicTrack.uploaded(
      key: id.substring(kDevicePrefix.length),
      title: title,
    );
  } else if (id.startsWith(kApplePrefix)) {
    _remembered[id] = MusicTrack.apple(
      trackId: id.substring(kApplePrefix.length),
      title: title,
      artist: artist,
    );
  }
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
