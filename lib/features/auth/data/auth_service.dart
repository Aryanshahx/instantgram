import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../shared/models/user_profile.dart';
import '../../profile/data/user_repository.dart';

/// Thrown with a user-friendly message.
class AuthFailure implements Exception {
  const AuthFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Firebase Auth + Firestore user documents.
///
/// Firestore layout:
///   users/{uid}            -> profile
///   usernames/{username}   -> { uid, email }  (keeps usernames unique)
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  FirebaseAuth get _auth => FirebaseAuth.instance;
  FirebaseFirestore get _db => FirebaseFirestore.instance;

  static final RegExp usernamePattern = RegExp(r'^[a-z0-9._]{3,30}$');

  Stream<User?> authStateChanges() => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  /// Log in with email OR username.
  Future<void> signIn({
    required String identifier,
    required String password,
  }) async {
    final id = identifier.trim();
    try {
      var email = id;
      if (!id.contains('@')) {
        final snap = await _db
            .collection('usernames')
            .doc(id.toLowerCase())
            .get();
        final data = snap.data();
        if (!snap.exists || data == null || data['email'] == null) {
          throw const AuthFailure('No account found with that username.');
        }
        email = data['email'] as String;
      }
      await _auth.signInWithEmailAndPassword(email: email, password: password);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_message(e));
    } on FirebaseException catch (e) {
      throw AuthFailure(e.message ?? 'Something went wrong. Try again.');
    }
  }

  /// Create account + profile document + reserve username.
  Future<void> signUp({
    required String name,
    required String username,
    required String email,
    required String password,
    required DateTime birthDate,
    required String language,
  }) async {
    if (ageOn(birthDate, DateTime.now()) < kMinAge) {
      throw const AuthFailure('You must be at least $kMinAge years old.');
    }
    final uname = username.trim().toLowerCase();
    if (!usernamePattern.hasMatch(uname)) {
      throw const AuthFailure(
        'Username: 3-30 chars, only letters, numbers, . and _',
      );
    }

    final unameRef = _db.collection('usernames').doc(uname);
    try {
      final taken = await unameRef.get();
      if (taken.exists) throw const AuthFailure('That username is taken.');
    } on FirebaseException catch (e) {
      throw AuthFailure(e.message ?? 'Could not check username.');
    }

    UserCredential cred;
    try {
      cred = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_message(e));
    }

    final user = cred.user!;
    final profile = UserProfile(
      uid: user.uid,
      name: name.trim(),
      username: uname,
      email: email.trim(),
      language: language,
    );

    try {
      await _db.runTransaction((tx) async {
        final snap = await tx.get(unameRef);
        if (snap.exists) throw const AuthFailure('That username is taken.');
        tx.set(unameRef, {'uid': user.uid, 'email': email.trim()});
        final userRef = _db.collection('users').doc(user.uid);
        tx.set(userRef, profile.toNewUserMap());
        // date of birth stays private (only you can read it)
        tx.set(userRef.collection('private').doc('info'), {
          'birthDate': formatBirthDate(birthDate),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
      await user.updateDisplayName(name.trim());
    } catch (e) {
      // Roll back the auth account so the user can try again.
      await user.delete();
      if (e is AuthFailure) rethrow;
      throw AuthFailure('Could not create your profile. ($e)');
    }
  }

  Future<void> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_message(e));
    }
  }

  Future<void> signOut() => _auth.signOut();

  String _message(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'That email address looks wrong.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect login details. Please try again.';
      case 'email-already-in-use':
        return 'An account already exists with this email.';
      case 'weak-password':
        return 'Password is too weak (min 6 characters).';
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again.';
      case 'network-request-failed':
        return 'No internet connection.';
      case 'operation-not-allowed':
        return 'Email/Password sign-in is not enabled in Firebase.';
      default:
        return e.message ?? 'Something went wrong. Try again.';
    }
  }
}
