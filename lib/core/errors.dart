import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UsernameTakenException implements Exception {
  const UsernameTakenException();
  @override
  String toString() => 'That username is already taken.';
}

/// The admin panel blocked this email address from making accounts.
class EmailBlockedException implements Exception {
  const EmailBlockedException();
  @override
  String toString() => 'This email address cannot be used for a new account.';
}

/// Someone younger than the minimum age tried to make an account.
class AgeException implements Exception {
  const AgeException();
  @override
  String toString() => 'You must be at least 13 years old to make an account.';
}

/// A username could not be turned into an email (unknown name, nothing linked yet).
class LoginLookupException implements Exception {
  const LoginLookupException(this.message);
  final String message;
  @override
  String toString() => message;
}

class MediaException implements Exception {
  const MediaException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Text that may not be posted (a blocked word). The message says what to change.
class ModerationException implements Exception {
  const ModerationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Too much too fast (spam protection). The message says when to try again.
class RateLimitException implements Exception {
  const RateLimitException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns any error into a short, user-friendly message.
String friendlyError(Object e) {
  if (e is UsernameTakenException ||
      e is EmailBlockedException ||
      e is AgeException ||
      e is MediaException ||
      e is ModerationException ||
      e is RateLimitException ||
      e is LoginLookupException) {
    return e.toString();
  }
  if (e is DioException) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    final detail = data is Map && data['detail'] is String
        ? data['detail'] as String
        : null;
    switch (e.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
        return 'Cannot reach the media service. Check your internet connection.';
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'The upload took too long. Try a shorter clip or a better connection.';
      default:
        break;
    }
    switch (status) {
      case 401:
        return 'Please log out and log in again.';
      case 403:
        return 'The upload was refused. Please try again.';
      case 413:
        return detail ?? 'That file is too large.';
      case 429:
        return detail ?? 'Too many uploads. Try again later.';
      case 500:
        return detail ?? 'The media service is not set up correctly yet.';
    }
    return detail ?? 'Upload failed${status == null ? '' : ' ($status)'}.';
  }
  if (e is FirebaseAuthException) {
    switch (e.code) {
      case 'invalid-email':
        return 'That email address is not valid.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email/username or password.';
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
      case 'unauthenticated':
        return 'Please log out and log in again.';
    }
    return e.message ?? 'Something went wrong (${e.code}).';
  }
  return 'Something went wrong. Please try again.';
}
