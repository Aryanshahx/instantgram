import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/errors.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Stream<User?> get authChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;
  String get uid => _auth.currentUser!.uid;

  static final RegExp usernameRegex = RegExp(r'^[a-z0-9._]{3,20}$');

  Future<bool> isUsernameAvailable(String username) async {
    final doc = await _db.collection('usernames').doc(username).get();
    return !doc.exists;
  }

  Future<void> signIn({required String email, required String password}) async {
    await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<void> signUp({
    required String email,
    required String password,
    required String username,
    String fullName = '',
  }) async {
    final uname = username.trim().toLowerCase();

    if (!await isUsernameAvailable(uname)) {
      throw const UsernameTakenException();
    }

    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = cred.user!;

    try {
      // Claim the username + create profile atomically (guards against races).
      await _db.runTransaction((tx) async {
        final nameRef = _db.collection('usernames').doc(uname);
        final snap = await tx.get(nameRef);
        if (snap.exists) throw const UsernameTakenException();
        tx.set(nameRef, {'uid': user.uid});
        tx.set(_db.collection('users').doc(user.uid), {
          'uid': user.uid,
          'username': uname,
          'fullName': fullName.trim(),
          'email': email.trim(),
          'bio': '',
          'photoUrl': '',
          'photoPath': '',
          'followersCount': 0,
          'followingCount': 0,
          'postsCount': 0,
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
      await user.updateDisplayName(uname);
    } catch (e) {
      // Roll back the auth account so the user can retry.
      await user.delete();
      rethrow;
    }
  }

  Future<void> sendPasswordReset(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());

  Future<void> signOut() => _auth.signOut();
}
