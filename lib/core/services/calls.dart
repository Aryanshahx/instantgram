import 'package:flutter/material.dart';

/// Calls are switched off in this version.
class CallsOff implements Exception {
  const CallsOff();
  @override
  String toString() => 'Voice and video calls are coming soon.';
}

/// Voice + video calls.
///
/// v0.9.3: ZEGOCLOUD was removed (its Android plugins do not build with
/// the new Android tools). Calls are off until the new call service is
/// added. The call buttons in chats show "coming soon".
/// The methods stay the same, so the rest of the app does not change.
class Calls {
  Calls._();
  static final Calls instance = Calls._();

  /// Tests: kept so old tests still compile.
  static bool disabled = false;

  /// The app's navigator (call screens will open on it).
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  bool get ready => false;

  /// Before runApp.
  Future<void> prepare() async {}

  /// After login.
  Future<void> signIn({required String uid, required String username}) async {}

  /// Call accepted from a notification.
  void openAcceptedCall() {}

  /// Starts a voice / video call. Always throws [CallsOff] for now.
  Future<void> call({
    required String uid,
    required String username,
    required bool video,
  }) async {
    throw const CallsOff();
  }

  /// Before logging out.
  Future<void> signOut() async {}
}
