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

  /// Email as typed, or the email behind a username (`@name` and capitals are fine).
  Future<String> resolveEmail(String identifier) async {
    final id = identifier.trim();
    if (id.contains('@') && !id.startsWith('@')) return id;
    final name = normalizeUsername(id);
    if (!usernameRegex.hasMatch(name)) {
      throw const LoginLookupException('Enter a valid email or username.');
    }
    final DocumentSnapshot<Map<String, dynamic>> doc;
    try {
      doc = await _db.collection('usernames').doc(name).get();
    } on FirebaseException catch (e) {
      if (e.code == 'unavailable') rethrow;
      throw const LoginLookupException(
        'Could not look up that username. Log in with your email instead.',
      );
    }
    if (!doc.exists) {
      throw const LoginLookupException('No account has that username.');
    }
    final email = doc.data()?['email'];
    if (email is String && email.contains('@')) return email;
    throw const LoginLookupException(
      'Log in once with your email, then your username works too.',
    );
  }

  Future<void> signIn({
    required String identifier,
    required String password,
  }) async {
    final email = await resolveEmail(identifier);
    await _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  /// Makes sure the signed-in user's username points at their email, so the username can be
  /// used to log in. Accounts made before v1.9.0 get this the first time they open the app.
  Future<void> linkLoginEmail() async {
    try {
      final user = _auth.currentUser;
      final email = user?.email;
      if (user == null || email == null || email.isEmpty) return;
      final me = await _db.collection('users').doc(user.uid).get();
      final name = me.data()?['username'];
      if (name is! String || name.isEmpty) return;
      final ref = _db.collection('usernames').doc(name);
      final snap = await ref.get();
      final data = snap.data();
      if (snap.exists && data?['uid'] != user.uid) return;
      if (data?['email'] == email) return;
      await ref.set({'uid': user.uid, 'email': email}, SetOptions(merge: true));
    } catch (_) {
      // best effort: logging in with the email always works
    }
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
        tx.set(nameRef, {'uid': user.uid, 'email': email.trim()});
        tx.set(_db.collection('users').doc(user.uid), {
          'uid': user.uid,
          'username': uname,
          'fullName': fullName.trim(),
          'email': email.trim(),
          'bio': '',
          'photoUrl': '',
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

  /// Sends the reset link to an email or to the email of a username. Returns the address it
  /// went to (hidden, like `a***@gmail.com`).
  Future<String> sendPasswordReset(String identifier) async {
    final email = await resolveEmail(identifier);
    await _auth.sendPasswordResetEmail(email: email.trim());
    return maskEmail(email);
  }

  static String normalizeUsername(String v) {
    var n = v.trim().toLowerCase();
    if (n.startsWith('@')) n = n.substring(1);
    return n;
  }

  /// `aryan@gmail.com` -> `a***@gmail.com`
  static String maskEmail(String email) {
    final e = email.trim();
    final at = e.indexOf('@');
    if (at <= 0) return e;
    return '${e.substring(0, 1)}***${e.substring(at)}';
  }

  Future<void> signOut() => _auth.signOut();
}
