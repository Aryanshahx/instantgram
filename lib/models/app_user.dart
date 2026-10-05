import 'package:cloud_firestore/cloud_firestore.dart';

int _int(Object? v) => v is num ? v.toInt() : 0;
String _str(Object? v) => v is String ? v : '';

class AppUser {
  const AppUser({
    required this.uid,
    required this.username,
    this.fullName = '',
    this.bio = '',
    this.photoUrl = '',
    this.bannerUrl = '',
    this.links = const [],
    this.linkNames = const [],
    this.followersCount = 0,
    this.followingCount = 0,
    this.postsCount = 0,
    this.isPrivate = false,
    this.language = '',
    this.birthDate,
  });

  final String uid;
  final String username;
  final String fullName;
  final String bio;
  final String photoUrl;

  /// Cover picture of the profile page (a stored reference like photoUrl; '' = none).
  final String bannerUrl;

  /// Web links shown on the profile (up to 3).
  final List<String> links;

  /// The name shown for each link (same order as [links]; '' = show the web address).
  final List<String> linkNames;

  /// The name to show for link number [i].
  String linkLabel(int i) =>
      i < linkNames.length && linkNames[i].trim().isNotEmpty
      ? linkNames[i].trim()
      : '';
  final int followersCount;
  final int followingCount;
  final int postsCount;

  /// Only followers see the posts; following needs the person's approval.
  final bool isPrivate;

  /// Language code chosen when the account was made ('' = not set).
  final String language;
  final DateTime? birthDate;

  factory AppUser.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    return AppUser(
      uid: d.id,
      username: _str(m['username']),
      fullName: _str(m['fullName']),
      bio: _str(m['bio']),
      photoUrl: _str(m['photoUrl']),
      bannerUrl: _str(m['bannerUrl']),
      links: m['links'] is List
          ? [
              for (final l in m['links'] as List)
                if (l is String) l.trim(),
            ]
          : const [],
      linkNames: m['linkNames'] is List
          ? [
              for (final l in m['linkNames'] as List)
                l is String ? l.trim() : '',
            ]
          : const [],
      followersCount: _int(m['followersCount']),
      followingCount: _int(m['followingCount']),
      postsCount: _int(m['postsCount']),
      isPrivate: m['isPrivate'] == true,
      language: _str(m['language']),
      birthDate: m['birthDate'] is Timestamp
          ? (m['birthDate'] as Timestamp).toDate()
          : null,
    );
  }
}
