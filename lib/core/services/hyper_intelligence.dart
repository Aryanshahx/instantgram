import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/editor/video_frames.dart';
import '../../features/profile/data/user_repository.dart';
import '../../shared/models/post.dart';
import 'api_client.dart';
import 'content_filter.dart';

/// v0.18: **Hyper Intelligence**, InstantGram's safety system.
///
///  * every new post, clip, moment and comment is checked by the server
///    (OpenAI moderation) right after it is shared
///  * sensitive content is blurred: "Sensitive content · Tap to view"
///  * "hidden" content is only shown to its owner
///  * under 18 (date of birth) or Settings -> "Hide": sensitive content is
///    not shown at all
///  * chats are never checked
class HyperIntelligence {
  HyperIntelligence._();
  static final HyperIntelligence instance = HyperIntelligence._();

  static const String blur = 'blur';
  static const String hide = 'hide';
  static const _kMode = 'hi_sensitive_mode';

  /// Changes when something is revealed or a setting changes.
  final ValueNotifier<int> version = ValueNotifier(0);

  /// Settings -> Hyper Intelligence -> Sensitive content (blur / hide).
  final ValueNotifier<String> mode = ValueNotifier(blur);

  bool _minor = false;
  final Set<String> _revealed = {};

  /// Under 18: sensitive content is always hidden.
  bool get minor => _minor;

  String get _me => ContentFilter.instance.uid;

  void _changed() {
    version.value++;
    ContentFilter.instance.refresh();
  }

  /// Reads the setting + date of birth (main screen start).
  Future<void> start() async {
    try {
      final p = await SharedPreferences.getInstance();
      mode.value = p.getString(_kMode) == hide ? hide : blur;
    } catch (_) {}
    try {
      final d = DateTime.tryParse(await UserRepository.instance.birthDate());
      _minor = d != null && ageOn(d, DateTime.now()) < 18;
    } catch (_) {}
    _changed();
  }

  Future<void> setMode(String m) async {
    mode.value = m == hide ? hide : blur;
    _changed();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kMode, mode.value);
    } catch (_) {}
  }

  @visibleForTesting
  void debugSet({bool minor = false, String m = blur}) {
    _minor = minor;
    mode.value = m;
    _revealed.clear();
    _changed();
  }

  // ------------------------------------------------------------ decisions

  bool _hides(String authorId, bool sensitive, bool hidden) {
    if (authorId == _me) return false;
    if (hidden) return true;
    return sensitive && (_minor || mode.value == hide);
  }

  /// Not shown at all (hidden by Hyper Intelligence, or sensitive for a
  /// person under 18 / with "Hide").
  bool hides(Post p) => _hides(p.authorId, p.sensitive, p.modHidden);
  bool hidesStory(Story s) => _hides(s.authorId, s.sensitive, s.modHidden);
  bool hidesComment(Comment c) => _hides(c.authorId, c.sensitive, c.hidden);

  /// Shown blurred until "Tap to view".
  bool blurs(Post p) =>
      p.sensitive && p.authorId != _me && !_revealed.contains(p.id);
  bool blursStory(Story s) =>
      s.sensitive && s.authorId != _me && !_revealed.contains('m_${s.id}');
  bool blursComment(Comment c) =>
      c.sensitive && c.authorId != _me && !_revealed.contains('c_${c.id}');

  void reveal(Post p) {
    if (_revealed.add(p.id)) version.value++;
  }

  void revealStory(Story s) {
    if (_revealed.add('m_${s.id}')) version.value++;
  }

  void revealComment(Comment c) {
    if (_revealed.add('c_${c.id}')) version.value++;
  }

  // ------------------------------------------------------------ checks

  /// Tests replace the server call.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
  debugPost;

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) =>
      (debugPost ?? (b) => ApiClient.instance.post('/api/hi', b))(body);

  /// Asks the server to check something just shared. Never throws: when
  /// it fails the item stays "pending" and the server tries again later.
  Future<String> _check(Map<String, dynamic> body) async {
    for (var i = 0; i < 2; i++) {
      try {
        final r = await _post({'action': 'check', ...body});
        return (r['state'] as String?) ?? '';
      } catch (e) {
        debugPrint('Hyper Intelligence check: $e');
        // 4xx = will never work (deleted, not yours): don't try again
        if (e is ApiException && e.statusCode >= 400 && e.statusCode < 500) {
          return '';
        }
        await Future<void>.delayed(retryWait * (i + 1));
      }
    }
    return '';
  }

  /// Wait before trying again (tests make it short).
  @visibleForTesting
  static Duration retryWait = const Duration(seconds: 3);

  Future<String> checkPost(String postId, {List<String> frames = const []}) =>
      _check({
        'kind': 'post',
        'id': postId,
        if (frames.isNotEmpty) 'frames': frames,
      });

  Future<String> checkMoment(String id, {List<String> frames = const []}) =>
      _check({
        'kind': 'moment',
        'id': id,
        if (frames.isNotEmpty) 'frames': frames,
      });

  Future<String> checkComment(String postId, String commentId) =>
      _check({'kind': 'comment', 'id': commentId, 'postId': postId});

  /// When the 3 pictures of a video are taken (25 / 50 / 75 % of the
  /// part that is shown).
  static List<int> frameTimes(int startMs, int endMs) {
    final len = endMs - startMs;
    if (len <= 0) return [startMs < 0 ? 0 : startMs];
    return [
      for (final f in const [0.25, 0.5, 0.75]) startMs + (len * f).round(),
    ];
  }

  /// Grabber (tests replace it).
  @visibleForTesting
  static Future<Uint8List?> Function(String path, int ms)? debugFrame;

  /// 3 small pictures of a local video as "data:image/jpeg;base64,...".
  /// Empty when the phone can't make them (the server then checks the
  /// cover only).
  Future<List<String>> framesOf(
    String path, {
    required int durationMs,
    VideoEdits edits = const VideoEdits(),
  }) async {
    final end = edits.trimEndMs > 0 ? edits.trimEndMs : durationMs;
    final out = <String>[];
    for (final ms in frameTimes(edits.trimStartMs, end)) {
      try {
        final b =
            await (debugFrame ??
                    (p, t) => VideoFrames.bytes(
                      p,
                      t,
                      maxHeight: 360,
                      quality: 70,
                    ))(path, ms)
                .timeout(const Duration(seconds: 8));
        if (b != null && b.isNotEmpty && b.length < 450000) {
          out.add('data:image/jpeg;base64,${base64Encode(b)}');
        }
      } catch (_) {
        // no picture for this moment of the video
      }
    }
    return out;
  }
}
