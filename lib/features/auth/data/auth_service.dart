import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/account_family.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/saved_accounts.dart';
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

  /// Tests: fake server for the sign up email code.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(
    String path,
    Map<String, dynamic> body,
  )?
  debugApi;

  Future<Map<String, dynamic>> _api(
    String path,
    Map<String, dynamic> body, {
    bool auth = true,
  }) {
    final fake = debugApi;
    if (fake != null) return fake(path, body);
    return ApiClient.instance.post(path, body, auth: auth);
  }

  /// v0.0.1: emails a 6 digit code. Returns seconds until "Send again".
  Future<int> sendSignupCode(String email) async {
    try {
      final r = await _api('/api/u', {
        'action': 'otpSend',
        'email': email.trim(),
      }, auth: false);
      return (r['resendIn'] as num?)?.toInt() ?? 60;
    } on ApiException catch (e) {
      throw AuthFailure(e.message);
    }
  }

  /// v0.0.1: checks the code. Returns a token for [signUp].
  Future<String> verifySignupCode(String email, String code) async {
    try {
      final r = await _api('/api/u', {
        'action': 'otpVerify',
        'email': email.trim(),
        'code': code.trim(),
      }, auth: false);
      final t = r['otpToken'];
      if (t is! String || t.isEmpty) {
        throw const AuthFailure('Could not check the code. Try again.');
      }
      return t;
    } on ApiException catch (e) {
      throw AuthFailure(e.message);
    }
  }

  /// v0.0.1: before sending a code, the username must be free.
  Future<void> checkUsername(String username) async {
    final uname = username.trim().toLowerCase();
    if (!usernamePattern.hasMatch(uname)) {
      throw const AuthFailure(
        'Username: 3-30 chars, only letters, numbers, . and _',
      );
    }
    try {
      final taken = await _db.collection('usernames').doc(uname).get();
      if (taken.exists) throw const AuthFailure('That username is taken.');
    } on FirebaseException catch (e) {
      throw AuthFailure(e.message ?? 'Could not check username.');
    }
  }
  FirebaseFirestore get _db => FirebaseFirestore.instance;

  static final RegExp usernamePattern = RegExp(r'^[a-z0-9._]{3,30}$');

  Stream<User?> authStateChanges() => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  /// Log in with email OR username.
  /// v0.0.2: email -> "Choose account" (when the login has more than one);
  /// username -> straight to that account. [openUid] = open this account
  /// of the login (saved account chips).
  Future<void> signIn({
    required String identifier,
    required String password,
    String openUid = '',
  }) async {
    final id = identifier.trim();
    final family = AccountFamily.instance;
    family
      ..askAfterLogin = false
      ..wantUid = openUid;
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
        final uid = data['uid'];
        if (openUid.isEmpty && uid is String) family.wantUid = uid;
      }
      // set before logging in: the home screen reads it when it opens
      family.askAfterLogin = family.wantUid.isEmpty;
      final cred = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      await _remember(cred.user, email, password);
    } on FirebaseAuthException catch (e) {
      family.resetLogin();
      throw AuthFailure(_message(e));
    } on FirebaseException catch (e) {
      family.resetLogin();
      throw AuthFailure(e.message ?? 'Something went wrong. Try again.');
    } catch (_) {
      family.resetLogin();
      rethrow;
    }
  }

  /// v0.12: saves the login on this phone for Settings -> Accounts.
  Future<void> _remember(User? user, String email, String password) async {
    if (user == null) return;
    try {
      await SavedAccounts.instance.rememberLogin(
        uid: user.uid,
        email: email,
        password: password,
      );
    } catch (_) {}
  }

  /// v0.12: is this email + password right? Checked on a second Firebase
  /// app, so the account you are using now stays logged in.
  /// null = right, else the problem to show.
  Future<String?> checkPassword(String email, String password) async {
    try {
      FirebaseApp app;
      try {
        app = Firebase.app('acct_check');
      } catch (_) {
        app = await Firebase.initializeApp(
          name: 'acct_check',
          options: Firebase.app().options,
        );
      }
      final auth = FirebaseAuth.instanceFor(app: app);
      await auth.signInWithEmailAndPassword(email: email, password: password);
      await auth.signOut();
      return null;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'network-request-failed' ||
          e.code == 'too-many-requests') {
        return _message(e);
      }
      return 'Wrong password for $email.';
    } catch (_) {
      return null; // could not check: try the real login
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
    required String otpToken,
    String country = '',
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
    // v0.0.1: the email code was right -> server marks the email verified
    // (the database only takes new profiles with a checked email)
    try {
      await _api('/api/accounts', {
        'action': 'verifyEmail',
        'otpToken': otpToken,
      });
      await user.getIdToken(true);
    } catch (e) {
      try {
        await user.delete();
      } catch (_) {}
      throw AuthFailure(
        e is ApiException
            ? e.message
            : 'Could not check your email. Try again.',
      );
    }
    final profile = UserProfile(
      uid: user.uid,
      name: name.trim(),
      username: uname,
      email: email.trim(),
      language: language,
      country: country.toUpperCase(),
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
    await _remember(user, email.trim(), password);
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
