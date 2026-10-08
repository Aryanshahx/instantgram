import 'highlight.dart';

/// One of my audience lists ("Close friends", "Family"...): moments can be shared to just
/// these people. Stored in `users/{me}/audiences/{id}`; only I can read it.
class AudienceList {
  const AudienceList({
    required this.id,
    required this.name,
    this.members = const [],
  });

  final String id;
  final String name;
  final List<String> members;

  static const int maxMembers = 500;
  static const int maxLists = 10;

  AudienceList copyWith({String? name, List<String>? members}) => AudienceList(
    id: id,
    name: name ?? this.name,
    members: members ?? this.members,
  );

  Map<String, dynamic> toMap() => {
    'name': cleanName(name),
    'members': members.take(maxMembers).toList(),
  };

  factory AudienceList.fromMap(String id, Map<String, dynamic> m) {
    final v = m['members'];
    return AudienceList(
      id: id,
      name: m['name'] is String && (m['name'] as String).isNotEmpty
          ? m['name'] as String
          : 'List',
      members: v is List ? [for (final x in v) '$x'] : const [],
    );
  }

  /// Trimmed, at most 30 characters, never empty.
  static String cleanName(String s) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) return 'List';
    return t.length > 30 ? t.substring(0, 30) : t;
  }

  /// Who may see a moment for this list: its people and me (no duplicates).
  List<String> audienceWith(String me) => {me, ...members}.toList();
}

/// Who a new moment is for: everyone, one list, or only a highlight on my profile (it then
/// never shows in the moments bar).
class StoryAudience {
  const StoryAudience.everyone() : list = null, highlight = null;
  const StoryAudience.only(AudienceList this.list) : highlight = null;
  const StoryAudience.highlightOnly(Highlight this.highlight) : list = null;

  final AudienceList? list;
  final Highlight? highlight;

  bool get isEveryone => list == null && highlight == null;
  String get label {
    final h = highlight;
    if (h != null) return 'highlight "${h.title}"';
    return list?.name ?? 'Everyone';
  }
}
