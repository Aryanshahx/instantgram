import 'package:cloud_firestore/cloud_firestore.dart';

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
  });

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
        'createdAt': FieldValue.serverTimestamp(),
      };
}
