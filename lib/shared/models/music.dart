import 'package:cloud_firestore/cloud_firestore.dart';

/// A song people can put on posts, clips and moments (music/{id}).
/// source: 'library' (added by the admin), 'ai' (made with Google Lyria),
/// 'original' (music someone added from the phone).
class MusicTrack {
  const MusicTrack({
    required this.id,
    required this.source,
    required this.title,
    required this.url,
    this.artist = '',
    this.mood = '',
    this.durationMs = 0,
    this.ownerUid = '',
    this.uses = 0,
    this.hidden = false,
    this.lyrics = '',
    this.prompt = '',
    this.createdAt,
  });

  static const String library = 'library';
  static const String ai = 'ai';
  static const String original = 'original';

  final String id;
  final String source;
  final String title;
  final String artist;
  final String url;
  final String mood;
  final int durationMs;
  final String ownerUid;
  final int uses;
  final bool hidden;
  final String lyrics;
  final String prompt;
  final DateTime? createdAt;

  bool get isAi => source == ai;
  bool get isOriginal => source == original;

  /// "Song · Artist" (saved on posts as audioName).
  String get label => artist.isEmpty ? title : '$title · $artist';

  factory MusicTrack.fromMap(String id, Map<String, dynamic> m) {
    String s(Object? v) => v is String ? v : '';
    int i(Object? v) => v is num ? v.toInt() : 0;
    final c = m['createdAt'];
    return MusicTrack(
      id: id,
      source: s(m['source']),
      title: s(m['title']).isEmpty ? 'Song' : s(m['title']),
      artist: s(m['artist']),
      url: s(m['url']),
      mood: s(m['mood']),
      durationMs: i(m['durationMs']),
      ownerUid: s(m['ownerUid']),
      uses: i(m['uses']),
      hidden: m['hidden'] == true,
      lyrics: s(m['lyrics']),
      prompt: s(m['prompt']),
      createdAt: c is Timestamp
          ? c.toDate()
          : c is String
          ? DateTime.tryParse(c)
          : null,
    );
  }

  factory MusicTrack.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) =>
      MusicTrack.fromMap(d.id, d.data() ?? const <String, dynamic>{});
}

/// Library order: most used first, then newest (no ties: id last).
List<MusicTrack> sortTracks(Iterable<MusicTrack> all) {
  final list = all.where((t) => !t.hidden && t.url.isNotEmpty).toList();
  list.sort((a, b) {
    final u = b.uses.compareTo(a.uses);
    if (u != 0) return u;
    final at = a.createdAt?.millisecondsSinceEpoch ?? 0;
    final bt = b.createdAt?.millisecondsSinceEpoch ?? 0;
    final t = bt.compareTo(at);
    return t != 0 ? t : a.id.compareTo(b.id);
  });
  return list;
}

/// Search in name, artist and mood (all words must match).
List<MusicTrack> searchTracks(List<MusicTrack> all, String query) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return all;
  return all.where((t) {
    final hay = '${t.title} ${t.artist} ${t.mood}'.toLowerCase();
    return words.every(hay.contains);
  }).toList();
}

/// "1:05" (0 = '').
String trackTime(int ms) {
  if (ms <= 0) return '';
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
