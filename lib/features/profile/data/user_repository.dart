import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../shared/models/user_profile.dart';

class UserRepository {
  UserRepository._();
  static final UserRepository instance = UserRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  Stream<UserProfile?> watchUser(String uid) {
    return _db.collection('users').doc(uid).snapshots().map((snap) {
      final data = snap.data();
      if (!snap.exists || data == null) return null;
      return UserProfile.fromMap(uid, data);
    });
  }

  Future<void> updateProfile(
    String uid, {
    required String name,
    required String bio,
    required String website,
  }) {
    return _db.collection('users').doc(uid).update({
      'name': name.trim(),
      'bio': bio.trim(),
      'website': website.trim(),
    });
  }
}
