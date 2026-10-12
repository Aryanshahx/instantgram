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
    this.coverUrl = '',
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
  final String coverUrl;
  final int postsCount;
  final int followersCount;
  final int followingCount;

  factory UserProfile.fromMap(String uid, Map<String, dynamic> map) {
    return UserProfile(
      uid: uid,
      name: (map['name'] ?? '') as String,
      username: (map['username'] ?? '') as String,
      email: (map['email'] ?? '') as String,
      bio: (map['bio'] ?? '') as String,
      website: (map['website'] ?? '') as String,
      photoUrl: (map['photoUrl'] ?? '') as String,
      coverUrl: (map['coverUrl'] ?? '') as String,
      postsCount: (map['postsCount'] ?? 0) as int,
      followersCount: (map['followersCount'] ?? 0) as int,
      followingCount: (map['followingCount'] ?? 0) as int,
    );
  }

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
