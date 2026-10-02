import 'package:flutter/foundation.dart';

/// Tiny global event bus: bump [feedRefresh] to make feed/stories/reels reload.
class AppEvents {
  static final ValueNotifier<int> feedRefresh = ValueNotifier<int>(0);
  static void refreshFeed() => feedRefresh.value++;
}
