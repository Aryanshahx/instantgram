import 'config.dart';

/// Media references are stored in Firestore as `tg:<handle>` (file) or
/// `tgt:<handle>` (video thumbnail). The real address is built here, so moving
/// the media server only needs a new [kMediaServerUrl].
String get mediaBase => kMediaServerUrl.replaceAll(RegExp(r'/+$'), '');

bool get mediaServerConfigured => !kMediaServerUrl.contains('CHANGE-ME');

String resolveMediaUrl(String ref) {
  if (ref.startsWith('tg:')) return '$mediaBase/m/${ref.substring(3)}';
  if (ref.startsWith('tgt:')) return '$mediaBase/t/${ref.substring(4)}';
  return ref;
}

bool isMediaRef(String ref) => ref.startsWith('tg:') || ref.startsWith('tgt:');

/// 83 -> "1:23"
String formatDuration(int seconds) {
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
