import 'package:firebase_auth/firebase_auth.dart';

class UsernameTakenException implements Exception {
  const UsernameTakenException();
  @override
  String toString() => 'That username is already taken.';
}

class VideoLinkException implements Exception {
  const VideoLinkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns any error into a short, user-friendly message.
String friendlyError(Object e) {
  if (e is UsernameTakenException || e is VideoLinkException) {
    return e.toString();
  }
  if (e is FirebaseAuthException) {
    switch (e.code) {
      case 'invalid-email':
        return 'That email address is not valid.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'email-already-in-use':
        return 'An account already exists with that email.';
      case 'weak-password':
        return 'Password is too weak (use at least 6 characters).';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      case 'network-request-failed':
        return 'No internet connection.';
      case 'operation-not-allowed':
        return 'Email/password sign-in is not enabled in Firebase.';
    }
    return e.message ?? 'Authentication failed.';
  }
  if (e is FirebaseException) {
    final msg = (e.message ?? '').toLowerCase();
    switch (e.code) {
      case 'permission-denied':
        return 'Firestore blocked this request. Publish firebase/firestore.rules in the Firebase console (see FIREBASE_SETUP.md).';
      case 'failed-precondition':
        if (msg.contains('index')) {
          return 'A Firestore index is missing. Create the composite indexes '
              'listed in FIREBASE_SETUP.md, wait until they are "Enabled", then retry.';
        }
        return e.message ?? 'Database error.';
      case 'unavailable':
      case 'network-request-failed':
        return 'No internet connection.';
      case 'unauthorized':
      case 'unauthenticated':
        return 'Storage permission denied. Check your Storage rules.';
      case 'object-not-found':
        return 'File not found.';
      case 'bucket-not-found':
      case 'project-not-found':
        return 'Firebase Storage is not set up yet (needs the Blaze plan).';
      case 'quota-exceeded':
        return 'Storage quota exceeded.';
      case 'canceled':
        return 'Upload cancelled.';
    }
    return e.message ?? 'Something went wrong (${e.code}).';
  }
  return 'Something went wrong. Please try again.';
}
