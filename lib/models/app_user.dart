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
    this.photoPath = '',
    this.followersCount = 0,
    this.followingCount = 0,
    this.postsCount = 0,
  });

  final String uid;
  final String username;
  final String fullName;
  final String bio;
  final String photoUrl;
  final String photoPath;
  final int followersCount;
  final int followingCount;
  final int postsCount;

  factory AppUser.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    return AppUser(
      uid: d.id,
      username: _str(m['username']),
      fullName: _str(m['fullName']),
      bio: _str(m['bio']),
      photoUrl: _str(m['photoUrl']),
      photoPath: _str(m['photoPath']),
      followersCount: _int(m['followersCount']),
      followingCount: _int(m['followingCount']),
      postsCount: _int(m['postsCount']),
    );
  }
}
