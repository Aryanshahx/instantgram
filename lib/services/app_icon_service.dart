import 'package:flutter/services.dart';

/// One of the launcher icons (all built into the app).
class AppIconOption {
  const AppIconOption(this.id, this.label);
  final String id;
  final String label;

  /// The picture shown in the picker.
  String get asset => 'assets/app_icons/$id.png';
}

const List<AppIconOption> kAppIcons = [
  AppIconOption('classic', 'Classic'),
  AppIconOption('midnight', 'Midnight'),
  AppIconOption('sunset', 'Sunset'),
  AppIconOption('ocean', 'Ocean'),
  AppIconOption('mono', 'Mono'),
  AppIconOption('gold', 'Gold'),
];

/// Changes the app's icon on the home screen (Android activity aliases, see
/// tools/patch_app_icons.py). Tests swap [channel].
class AppIconService {
  AppIconService._();
  static final AppIconService instance = AppIconService._();

  MethodChannel channel = const MethodChannel('instantgram/app_icon');

  /// False on builds without the icons (or not on Android).
  Future<bool> available() async {
    try {
      return await channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<String> current() async {
    try {
      final id = await channel.invokeMethod<String>('get');
      return kAppIcons.any((i) => i.id == id) ? id! : 'classic';
    } catch (_) {
      return 'classic';
    }
  }

  Future<void> set(String id) async {
    if (!kAppIcons.any((i) => i.id == id)) throw ArgumentError(id);
    await channel.invokeMethod<String>('set', {'id': id});
  }

  /// Puts my own picture on the home screen as an InstantGram shortcut ([png] = the
  /// adaptive picture, see custom_icon.dart). Android only lets apps change their real
  /// icon to pictures built into the app, so this is a pinned shortcut. Returns 'pinned'
  /// (the phone asks to add it), 'updated' (the shortcut already there got the new
  /// picture) or 'unsupported'.
  Future<String> pinCustom(
    Uint8List png, {
    String label = 'InstantGram',
  }) async {
    try {
      return await channel.invokeMethod<String>('pinCustom', {
            'png': png,
            'label': label,
          }) ??
          'unsupported';
    } on MissingPluginException {
      return 'unsupported';
    }
  }
}
