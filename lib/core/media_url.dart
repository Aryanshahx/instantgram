import 'config.dart';

/// Media references are stored in Firestore as `m:<key>` (a file in your Tigris
/// bucket). The real address is built here, so changing the public address (for example to
/// your own domain) only needs a new [kMediaPublicUrl].
String _trim(String s) => s.replaceAll(RegExp(r'/+$'), '');

String get mediaApiBase => _trim(kMediaApiUrl);
String get mediaPublicBase => _trim(kMediaPublicUrl);

bool get mediaServerConfigured =>
    !kMediaApiUrl.contains('CHANGE-ME') &&
    !kMediaPublicUrl.contains('CHANGE-ME');

/// Turns a stored reference into a URL that can be loaded. Plain http(s) links are returned
/// as they are. References to the removed Telegram storage (`tg:` / `tgt:`) have no address.
String resolveMediaUrl(String ref) {
  if (ref.isEmpty) return '';
  if (ref.startsWith('m:')) return '$mediaPublicBase/${ref.substring(2)}';
  if (ref.startsWith('tg:') || ref.startsWith('tgt:')) return '';
  return ref;
}

bool isMediaRef(String ref) => ref.startsWith('m:');

/// Files that lived in the removed Telegram storage and can never be shown again.
bool isRemovedStorageRef(String ref) =>
    ref.startsWith('tg:') || ref.startsWith('tgt:');

/// 83 -> "1:23"
String formatDuration(int seconds) {
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
