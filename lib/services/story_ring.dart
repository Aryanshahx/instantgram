import 'package:flutter/foundation.dart';

/// Who has a moment (story) that is still running. Every profile picture in the app asks this,
/// so the glowing ring shows up everywhere a person's picture does.
class StoryRing {
  StoryRing._();
  static final StoryRing instance = StoryRing._();

  final ValueNotifier<Set<String>> active = ValueNotifier(const {});

  void setAll(Iterable<String> uids) {
    final next = {...uids};
    if (!setEquals(next, active.value)) active.value = next;
  }

  void add(String uid) {
    if (uid.isEmpty || active.value.contains(uid)) return;
    active.value = {...active.value, uid};
  }
}
