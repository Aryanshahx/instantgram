import 'package:cloud_firestore/cloud_firestore.dart';

/// One link on a profile (max [UserProfile.maxLinks]).
class ProfileLink {
  const ProfileLink({required this.title, required this.url});

  final String title;
  final String url;

  static const int maxTitle = 40;
  static const int maxUrl = 300;

  /// "example.com/page" (no https://, no trailing /).
  String get shortUrl => url
      .replaceFirst(RegExp(r'^https?://'), '')
      .replaceFirst(RegExp(r'^www\.'), '')
      .replaceFirst(RegExp(r'/$'), '');

  /// Title, or the address when there is no title.
  String get label => title.trim().isEmpty ? shortUrl : title.trim();

  /// Adds https:// when missing. '' when it is not a usable web address.
  static String fixUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return '';
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(u)) {
      u = 'https://$u';
    }
    final uri = Uri.tryParse(u);
    if (uri == null || uri.host.isEmpty || !uri.host.contains('.')) return '';
    if (u.length > maxUrl) return '';
    return u;
  }

  Map<String, String> toMap() => {'title': title.trim(), 'url': url};

  static ProfileLink? fromMap(Object? v) {
    if (v is! Map) return null;
    final url = v['url'];
    if (url is! String || url.isEmpty) return null;
    final t = v['title'];
    return ProfileLink(title: t is String ? t : '', url: url);
  }

  @override
  bool operator ==(Object other) =>
      other is ProfileLink && other.title == title && other.url == url;

  @override
  int get hashCode => Object.hash(title, url);
}

class UserProfile {
  const UserProfile({
    required this.uid,
    required this.name,
    required this.username,
    this.email = '',
    this.bio = '',
    this.website = '',
    this.photoUrl = '',
    this.photoKey = '',
    this.coverUrl = '',
    this.coverKey = '',
    this.postsCount = 0,
    this.followersCount = 0,
    this.followingCount = 0,
    this.language = '',
    this.isPrivate = false,
    this.country = '',
    this.links = const [],
    this.bioFont = '',
  });

  static const int maxLinks = 3;

  final String uid;
  final String name;
  final String username;
  final String email;
  final String bio;
  final String website;
  final String photoUrl;
  final String photoKey;
  final String coverUrl;
  final String coverKey;
  final int postsCount;
  final int followersCount;
  final int followingCount;

  /// Language code chosen at sign up ('' = not set).
  final String language;

  /// Private account: only approved followers see posts.
  final bool isPrivate;

  /// Country code chosen at sign up, e.g. 'IN' ('' = not set).
  final String country;

  /// Up to 3 links with a title (v0.7).
  final List<ProfileLink> links;

  /// v0.15: font of the bio ('' = normal), see BioFont.
  final String bioFont;

  /// Links to show: [links], or the old single website.
  List<ProfileLink> get allLinks => links.isNotEmpty
      ? links
      : website.isEmpty
      ? const []
      : [ProfileLink(title: '', url: website)];

  String get displayName => name.trim().isEmpty ? username : name;

  factory UserProfile.fromMap(String uid, Map<String, dynamic> map) {
    int n(Object? v) => v is num ? v.toInt() : 0;
    String s(Object? v) => v is String ? v : '';
    return UserProfile(
      uid: uid,
      name: s(map['name']),
      username: s(map['username']),
      email: s(map['email']),
      bio: s(map['bio']),
      website: s(map['website']),
      photoUrl: s(map['photoUrl']),
      photoKey: s(map['photoKey']),
      coverUrl: s(map['coverUrl']),
      coverKey: s(map['coverKey']),
      postsCount: n(map['postsCount']),
      followersCount: n(map['followersCount']),
      followingCount: n(map['followingCount']),
      language: s(map['language']),
      isPrivate: map['isPrivate'] == true,
      country: s(map['country']),
      links: map['links'] is List
          ? (map['links'] as List)
                .map(ProfileLink.fromMap)
                .whereType<ProfileLink>()
                .take(maxLinks)
                .toList()
          : const [],
      bioFont: s(map['bioFont']),
    );
  }

  factory UserProfile.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      UserProfile.fromMap(doc.id, doc.data() ?? const {});

  Map<String, dynamic> toNewUserMap() => {
    'uid': uid,
    'name': name,
    'username': username,
    'email': email,
    'bio': bio,
    'website': website,
    'photoUrl': photoUrl,
    'coverUrl': coverUrl,
    'postsCount': 0,
    'followersCount': 0,
    'followingCount': 0,
    if (language.isNotEmpty) 'language': language,
    if (country.isNotEmpty) 'country': country,
    'isPrivate': false,
    'createdAt': FieldValue.serverTimestamp(),
  };
}
