import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/api_client.dart';
import '../../../core/services/background_upload.dart';
import '../../../core/services/media_service.dart';
import '../../../core/services/uploader.dart';
import '../../../core/services/video_prep.dart';
import '../../../core/utils/errors.dart';
import '../../../shared/models/post.dart';
import '../../stories/data/highlight_repository.dart';
import '../../stories/data/story_repository.dart';
import 'post_repository.dart';

enum UploadStatus { waiting, preparing, uploading, saving, failed, done }

/// One photo / video of a queued post.
class QueuedMedia {
  QueuedMedia({
    required this.path,
    required this.isVideo,
    this.aspectRatio = 1,
    this.edits = const VideoEdits(),
    this.durationMs = 0,
    this.thumbPath,
  });

  final String path;
  final bool isVideo;
  final double aspectRatio;
  final VideoEdits edits;
  final int durationMs;
  final String? thumbPath;

  // ---- progress that survives an app restart
  bool hdDone = false;
  String? hdPath; // null = the original is uploaded
  bool lowDone = false;
  String? lowPath;
  UploadedMedia? main;
  UploadedMedia? thumb;
  UploadedMedia? low;

  /// v0.12: voice over file on the server.
  UploadedMedia? voice;
  PartState? mainPart;
  PartState? lowPart;
  bool published = false; // moments: one doc per item
  String momentId = '';

  Map<String, dynamic> toJson() => {
    'path': path,
    'isVideo': isVideo,
    'aspectRatio': aspectRatio,
    'edits': edits.toMap(),
    'durationMs': durationMs,
    'thumbPath': thumbPath,
    'hdDone': hdDone,
    'hdPath': hdPath,
    'lowDone': lowDone,
    'lowPath': lowPath,
    'main': _media(main),
    'thumb': _media(thumb),
    'low': _media(low),
    'voice': _media(voice),
    'mainPart': mainPart?.toJson(),
    'lowPart': lowPart?.toJson(),
    'published': published,
    'momentId': momentId,
  };

  /// What goes into the post: the uploaded voice (never the phone path).
  VideoEdits get publishEdits {
    final v = voice;
    return v == null ? edits.withoutVoice() : edits.withVoice(v.url, v.key);
  }

  static QueuedMedia fromJson(Map<String, dynamic> m) {
    final e = m['edits'];
    return QueuedMedia(
        path: m['path'] as String,
        isVideo: m['isVideo'] == true,
        aspectRatio: (m['aspectRatio'] as num?)?.toDouble() ?? 1,
        edits: e is Map
            ? VideoEdits.fromMap(Map<String, dynamic>.from(e))
            : const VideoEdits(),
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        thumbPath: m['thumbPath'] as String?,
      )
      ..hdDone = m['hdDone'] == true
      ..hdPath = m['hdPath'] as String?
      ..lowDone = m['lowDone'] == true
      ..lowPath = m['lowPath'] as String?
      ..main = _readMedia(m['main'])
      ..thumb = _readMedia(m['thumb'])
      ..low = _readMedia(m['low'])
      ..voice = _readMedia(m['voice'])
      ..mainPart = PartState.fromJson(m['mainPart'])
      ..lowPart = PartState.fromJson(m['lowPart'])
      ..published = m['published'] == true
      ..momentId = (m['momentId'] as String?) ?? '';
  }
}

Map<String, String>? _media(UploadedMedia? m) =>
    m == null ? null : {'url': m.url, 'key': m.key};

UploadedMedia? _readMedia(Object? v) {
  if (v is! Map) return null;
  final url = v['url'], key = v['key'];
  if (url is! String || key is! String || url.isEmpty) return null;
  return UploadedMedia(url: url, key: key);
}

/// A post / clip / moment waiting to be uploaded.
class UploadTask {
  UploadTask({
    required this.id,
    required this.kind,
    required this.items,
    this.caption = '',
    this.options = const PostOptions(),
    this.coverPath,
    this.audioPath,
    this.audioName = '',
    this.postId = '',
    this.replyTo,
  });

  static const String post = 'post';
  static const String clip = 'clip';
  static const String moment = 'moment';

  final String id;
  final String kind;
  final List<QueuedMedia> items;
  final String caption;
  final PostOptions options;
  final String? coverPath;
  final String? audioPath;
  final String audioName;
  String postId;

  /// v0.9: answers a comment; after sharing, a reply comment links to it.
  final ReplyRef? replyTo;
  bool replyDone = false;

  UploadedMedia? cover;
  UploadedMedia? audio;
  UploadStatus status = UploadStatus.waiting;
  double progress = 0;
  String error = '';
  int tries = 0;

  bool get isMoment => kind == moment;
  bool get active =>
      status == UploadStatus.preparing ||
      status == UploadStatus.uploading ||
      status == UploadStatus.saving;

  /// Short text for the banner / notification.
  String get label {
    final what = isMoment && options.highlightOnly
        ? 'highlight'
        : isMoment
        ? (items.length > 1 ? 'moments' : 'moment')
        : kind == clip
        ? 'clip'
        : 'post';
    final pct = '${(progress * 100).round()}%';
    return switch (status) {
      UploadStatus.waiting => 'Waiting to share your $what…',
      UploadStatus.preparing => 'Preparing your $what… $pct',
      UploadStatus.uploading => 'Sharing your $what… $pct',
      UploadStatus.saving => 'Almost done…',
      UploadStatus.failed => "Couldn't share your $what",
      UploadStatus.done => 'Shared ✓',
    };
  }

  /// First picture to show in the banner (photo or video cover).
  String? get previewPath {
    if (items.isEmpty) return null;
    final f = items.first;
    if (!f.isVideo) return f.path;
    return f.thumbPath ?? coverPath;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'items': items.map((i) => i.toJson()).toList(),
    'caption': caption,
    'options': {
      'audience': options.audience,
      'alsoMoment': options.alsoMoment,
      'hideLikes': options.hideLikes,
      'hideComments': options.hideComments,
      'hideReposts': options.hideReposts,
      'hideShares': options.hideShares,
      'profileOnly': options.profileOnly,
      'highlightId': options.highlightId,
      'highlightTitle': options.highlightTitle,
    },
    'coverPath': coverPath,
    'audioPath': audioPath,
    'audioName': audioName,
    'postId': postId,
    'replyTo': replyTo?.toMap(),
    'replyDone': replyDone,
    'cover': _media(cover),
    'audio': _media(audio),
    'status': status == UploadStatus.failed ? 'failed' : 'waiting',
    'error': error,
    'tries': tries,
  };

  static UploadTask? fromJson(Object? v) {
    if (v is! Map) return null;
    try {
      final m = Map<String, dynamic>.from(v);
      final o = Map<String, dynamic>.from((m['options'] as Map?) ?? const {});
      return UploadTask(
          id: m['id'] as String,
          kind: m['kind'] as String,
          items: [
            for (final i in (m['items'] as List))
              QueuedMedia.fromJson(Map<String, dynamic>.from(i as Map)),
          ],
          caption: (m['caption'] as String?) ?? '',
          options: PostOptions(
            audience: (o['audience'] as String?) ?? Audience.everyone,
            alsoMoment: o['alsoMoment'] == true,
            hideLikes: o['hideLikes'] == true,
            hideComments: o['hideComments'] == true,
            hideReposts: o['hideReposts'] == true,
            hideShares: o['hideShares'] == true,
            profileOnly: o['profileOnly'] == true,
            highlightId: (o['highlightId'] as String?) ?? '',
            highlightTitle: (o['highlightTitle'] as String?) ?? '',
          ),
          coverPath: m['coverPath'] as String?,
          audioPath: m['audioPath'] as String?,
          audioName: (m['audioName'] as String?) ?? '',
          postId: (m['postId'] as String?) ?? '',
          replyTo: ReplyRef.fromMap(m['replyTo']),
        )
        ..replyDone = m['replyDone'] == true
        ..cover = _readMedia(m['cover'])
        ..audio = _readMedia(m['audio'])
        ..status = m['status'] == 'failed'
            ? UploadStatus.failed
            : UploadStatus.waiting
        ..error = (m['error'] as String?) ?? ''
        ..tries = (m['tries'] as num?)?.toInt() ?? 0;
    } catch (e) {
      debugPrint('upload queue: bad saved task: $e');
      return null;
    }
  }
}

/// Uploads posts, clips and moments in the background (v0.8):
///  * you can use the app right after tapping Share; a small bar in
///    Discover shows the progress
///  * videos are made HD (1080p, 30 fps) + fast start on the phone first
///  * goes on when you leave the app (notification) and after a restart,
///    from where it stopped (finished parts are not uploaded again)
///  * a failed upload is tried again a few times by itself
class UploadQueue extends ChangeNotifier {
  UploadQueue._();
  static final UploadQueue instance = UploadQueue._();

  static const _prefsKey = 'upload_queue_v1';

  /// Tests replace the real work.
  @visibleForTesting
  static Future<void> Function(UploadTask task)? debugRunner;

  final List<UploadTask> _tasks = [];
  final StreamController<UploadTask> _finished =
      StreamController<UploadTask>.broadcast();
  bool _loaded = false;
  bool _working = false;
  final Map<String, Timer> _retryTimers = {};
  Timer? _saveTimer;

  List<UploadTask> get tasks => List.unmodifiable(_tasks);

  /// A task that finished (for "Shared" messages).
  Stream<UploadTask> get finished => _finished.stream;

  static String _newId() {
    final r = Random();
    return '${DateTime.now().microsecondsSinceEpoch}-${r.nextInt(1 << 30)}';
  }

  /// Loads saved tasks and goes on with them (app start).
  Future<void> start() async {
    if (!_loaded) {
      _loaded = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_prefsKey);
        if (raw != null && raw.isNotEmpty) {
          for (final t in (jsonDecode(raw) as List)) {
            final task = UploadTask.fromJson(t);
            if (task != null) _tasks.add(task);
          }
        }
      } catch (e) {
        debugPrint('upload queue load: $e');
      }
      if (_tasks.isNotEmpty) notifyListeners();
    }
    _kick();
  }

  /// Adds a post / clip / moment. Returns at once.
  UploadTask add({
    required String kind,
    required List<QueuedMedia> items,
    String caption = '',
    PostOptions options = const PostOptions(),
    String? coverPath,
    String? audioPath,
    String audioName = '',
    ReplyRef? replyTo,
  }) {
    if (items.isEmpty) throw ArgumentError('Nothing to share');
    final t = UploadTask(
      id: _newId(),
      kind: kind,
      items: items,
      caption: caption,
      options: options,
      coverPath: coverPath,
      audioPath: audioPath,
      audioName: audioName,
      replyTo: replyTo,
    );
    _tasks.add(t);
    _save(now: true);
    notifyListeners();
    _loaded = true;
    _kick();
    return t;
  }

  /// Tries a failed task again now.
  void retry(UploadTask t) {
    if (t.status != UploadStatus.failed) return;
    _retryTimers.remove(t.id)?.cancel();
    t.status = UploadStatus.waiting;
    t.error = '';
    t.tries = 0;
    notifyListeners();
    _kick();
  }

  /// Removes a task (and frees what was uploaded for it).
  Future<void> cancel(UploadTask t) async {
    if (t.active) return; // can't stop in the middle (yet)
    _retryTimers.remove(t.id)?.cancel();
    _tasks.remove(t);
    _save(now: true);
    notifyListeners();
    unawaited(_cleanup(t, deleteUploads: true));
  }

  void _kick() {
    if (_working) return;
    final next = _tasks.where((t) => t.status == UploadStatus.waiting);
    if (next.isEmpty) {
      unawaited(BackgroundUpload.stop());
      return;
    }
    unawaited(_work(next.first));
  }

  Future<void> _work(UploadTask t) async {
    _working = true;
    try {
      unawaited(BackgroundUpload.start(t.label));
      final runner = debugRunner ?? _run;
      await runner(t);
      t.status = UploadStatus.done;
      t.progress = 1;
      _tasks.remove(t);
      _save(now: true);
      notifyListeners();
      _finished.add(t);
      unawaited(_cleanup(t, deleteUploads: false));
    } catch (e) {
      debugPrint('upload failed: $e');
      t.status = UploadStatus.failed;
      t.error = friendlyError(e);
      t.tries++;
      _save(now: true);
      notifyListeners();
      // try again by itself after a pause (weak network)
      if (t.tries < 4 && !_permanent(e)) {
        final wait = [8, 25, 60][(t.tries - 1).clamp(0, 2)];
        _retryTimers[t.id]?.cancel();
        _retryTimers[t.id] = Timer(Duration(seconds: wait), () {
          _retryTimers.remove(t.id);
          if (t.status == UploadStatus.failed && _tasks.contains(t)) {
            t.status = UploadStatus.waiting;
            notifyListeners();
            _kick();
          }
        });
      }
    } finally {
      _working = false;
      _kick();
    }
  }

  bool _permanent(Object e) =>
      e is UploadRejected ||
      e is FileSystemException ||
      (e is ApiException && const [400, 413, 415].contains(e.statusCode));

  void _set(UploadTask t, UploadStatus s, double p) {
    t.status = s;
    t.progress = p.clamp(0.0, 1.0);
    notifyListeners();
    unawaited(BackgroundUpload.update(t.label));
  }

  // ------------------------------------------------------------ the work

  Future<void> _run(UploadTask t) async {
    for (final m in t.items) {
      if (!await File(m.path).exists() && m.main == null) {
        throw const FileSystemException(
          'A photo or video was deleted from the phone',
        );
      }
    }
    if (!t.isMoment && t.postId.isEmpty) {
      t.postId = PostRepository.instance.newPostId();
    }
    for (final m in t.items) {
      if (t.isMoment && m.momentId.isEmpty) {
        m.momentId = StoryRepository.instance.newId();
      }
    }
    _save(now: true);

    // ---- weights for the progress bar (bytes)
    final videos = [
      for (var k = 0; k < t.items.length; k++)
        if (t.items[k].isVideo) k,
    ];
    final needPrep = videos.any((k) => !t.items[k].hdDone);
    final prep = <int, double>{for (final k in videos) k: 0};
    final slots = <_Slot>[];
    final hd = <int, Future<File>>{};
    final low = <int, Future<File?>>{};

    Future<int> sizeOf(String? path) async {
      if (path == null) return 0;
      try {
        return await File(path).length();
      } catch (_) {
        return 0;
      }
    }

    for (var k = 0; k < t.items.length; k++) {
      final m = t.items[k];
      if (m.isVideo) {
        hd[k] = _hdFor(m, (v) {
          prep[k] = v;
        });
        if (!t.isMoment) {
          low[k] = hd[k]!.then((f) => _lowFor(m, f));
        }
      }
    }
    for (var k = 0; k < t.items.length; k++) {
      final m = t.items[k];
      final orig = await sizeOf(m.path);
      final secs = m.durationMs / 1000;
      final kind = t.isMoment
          ? MediaKind.story
          : (m.isVideo ? MediaKind.clip : MediaKind.post);
      // main file
      if (m.main == null) {
        final guess = m.isVideo && secs > 0
            ? min(orig, (secs * 6.4e6 / 8).round())
            : orig;
        slots.add(
          _Slot(guess, (p) async {
            final file = m.isVideo ? await hd[k]! : File(m.path);
            m.main = await MediaService.instance.upload(
              file,
              kind: kind,
              onProgress: p,
              resume: m.mainPart,
              onPartState: (s) {
                m.mainPart = s;
                _save();
              },
            );
            m.mainPart = null;
            _save(now: true);
          }),
        );
      }
      // video cover (optional)
      if (m.isVideo && m.thumbPath != null && m.thumb == null) {
        slots.add(
          _Slot(await sizeOf(m.thumbPath), (p) async {
            try {
              m.thumb = await MediaService.instance.upload(
                File(m.thumbPath!),
                kind: MediaKind.thumb,
                onProgress: p,
              );
              _save();
            } catch (e) {
              if (e is FileSystemException) return; // cover is optional
              rethrow;
            }
          }),
        );
      }
      // small copy for slow networks (optional)
      if (m.isVideo && !t.isMoment && m.low == null) {
        final guess = secs > 0 ? (secs * 1.2e6 / 8).round() : orig ~/ 6;
        slots.add(
          _Slot(guess, (p) async {
            final f = await low[k]!;
            if (f == null) return;
            try {
              m.low = await MediaService.instance.upload(
                f,
                kind: MediaKind.clip,
                onProgress: p,
                resume: m.lowPart,
                onPartState: (s) {
                  m.lowPart = s;
                  _save();
                },
              );
              m.lowPart = null;
              _save(now: true);
            } catch (e) {
              if (e is UploadRejected || e is FileSystemException) return;
              rethrow; // network: try again with the whole task
            }
          }),
        );
      }
    }
    if (t.coverPath != null && t.cover == null) {
      slots.add(
        _Slot(await sizeOf(t.coverPath), (p) async {
          try {
            t.cover = await MediaService.instance.upload(
              File(t.coverPath!),
              kind: MediaKind.thumb,
              onProgress: p,
            );
            _save();
          } on FileSystemException {
            // cover is optional
          }
        }),
      );
    }
    // v0.12: voice overs (posts and clips)
    if (!t.isMoment) {
      for (final m in t.items) {
        final vp = m.edits.voicePath;
        if (!m.isVideo || vp.isEmpty || m.voice != null) continue;
        if (!await File(vp).exists()) continue; // file gone: post without it
        slots.add(
          _Slot(await sizeOf(vp), (p) async {
            m.voice = await MediaService.instance.upload(
              File(vp),
              kind: MediaKind.audio,
              onProgress: p,
            );
            _save();
          }),
        );
      }
    }
    if (t.audioPath != null && t.audio == null) {
      slots.add(
        _Slot(await sizeOf(t.audioPath), (p) async {
          t.audio = await MediaService.instance.upload(
            File(t.audioPath!),
            kind: MediaKind.audio,
            onProgress: p,
          );
          _save();
        }),
      );
    }

    final upTotal = max(1, slots.fold<int>(0, (a, s) => a + s.weight));
    final prepShare = needPrep ? 0.3 : 0.0;
    void report() {
      final prepDone = prep.isEmpty
          ? 1.0
          : prep.values.fold<double>(0, (a, v) => a + v) / prep.length;
      final up =
          slots.fold<double>(0, (a, s) => a + s.weight * s.progress) / upTotal;
      final overall = prepShare * prepDone + (1 - prepShare) * up;
      final preparing = needPrep && prepDone < 1 && up < 0.02;
      _set(
        t,
        preparing ? UploadStatus.preparing : UploadStatus.uploading,
        overall * 0.98,
      );
    }

    final ticker = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => report(),
    );
    try {
      report();
      // 3 files at the same time (each big video also uses parallel parts)
      await Uploader.pool<void>(3, [
        for (final s in slots)
          () => s
              .run((v) {
                s.progress = v;
              })
              .then((_) => s.progress = 1),
      ]);
    } finally {
      ticker.cancel();
    }

    // ---- write the post / moments
    _set(t, UploadStatus.saving, 0.99);
    for (final m in t.items) {
      if (m.main == null) throw StateError('Upload did not finish');
    }
    if (t.isMoment && t.options.highlightOnly) {
      // v0.16: straight into a highlight (no moment for 24 hours)
      final now = DateTime.now();
      await HighlightRepository.instance.addUploaded(
        t.options.highlightId,
        t.options.highlightTitle,
        [
          for (final (i, m) in t.items.indexed)
            Story(
              id: m.momentId,
              authorId: '',
              authorUsername: '',
              authorPhotoUrl: '',
              mediaUrl: m.main!.url,
              mediaKey: m.main!.key,
              createdAt: now.add(Duration(milliseconds: i)),
              type: m.isVideo ? Story.video : Story.photo,
              durationMs: m.isVideo ? m.durationMs : 0,
              edits: m.isVideo ? m.edits.withoutVoice() : const VideoEdits(),
              audioUrl: t.audio?.url ?? '',
              audioKey: t.audio?.key ?? '',
              audioName: t.audio == null ? '' : t.audioName,
            ),
        ],
      );
      for (final m in t.items) {
        m.published = true;
      }
      _save(now: true);
    } else if (t.isMoment) {
      for (final m in t.items) {
        if (m.published) continue;
        await StoryRepository.instance.createUploaded(
          id: m.momentId,
          media: m.main!,
          isVideo: m.isVideo,
          edits: m.edits.withoutVoice(),
          durationMs: m.durationMs,
          audience: t.options.audience,
          audio: t.audio,
          audioName: t.audioName,
        );
        m.published = true;
        _save(now: true);
      }
    } else {
      await PostRepository.instance.publishPost(
        postId: t.postId,
        type: t.kind == UploadTask.clip ? Post.clip : Post.photo,
        caption: t.caption,
        cover: t.cover,
        audio: t.audio,
        audioName: t.audioName,
        options: t.options,
        replyTo: t.replyTo,
        media: [
          for (final m in t.items)
            MediaItem(
              url: m.main!.url,
              key: m.main!.key,
              aspectRatio: safeAspect(m.aspectRatio),
              isVideo: m.isVideo,
              thumbUrl: m.thumb?.url ?? '',
              thumbKey: m.thumb?.key ?? '',
              durationMs: m.isVideo ? m.durationMs : 0,
              edits: m.isVideo ? m.publishEdits : const VideoEdits(),
              lowUrl: m.low?.url ?? '',
              lowKey: m.low?.key ?? '',
            ),
        ],
      );
      // v0.9: answer to a comment -> reply comment that links to it
      final r = t.replyTo;
      if (r != null && !t.replyDone) {
        try {
          await PostRepository.instance.addLinkedReply(r, t.postId);
        } catch (e) {
          debugPrint('upload: reply comment failed: $e'); // post is shared
        }
        t.replyDone = true;
        _save(now: true);
      }
    }
  }

  Future<File> _hdFor(QueuedMedia m, ValueChanged<double> onProgress) async {
    if (m.main != null) {
      onProgress(1);
      return File(m.path);
    }
    if (m.hdDone) {
      final p = m.hdPath;
      if (p == null) {
        onProgress(1);
        return File(m.path);
      }
      if (await File(p).exists()) {
        onProgress(1);
        return File(p);
      }
    }
    final f = await VideoPrep.hd(File(m.path), onProgress: onProgress);
    m.hdPath = f.path == m.path ? null : f.path;
    m.hdDone = true;
    m.mainPart = null; // a new file -> a new upload
    _save(now: true);
    onProgress(1);
    return f;
  }

  Future<File?> _lowFor(QueuedMedia m, File hd) async {
    if (m.low != null) return null;
    if (m.lowDone) {
      final p = m.lowPath;
      if (p != null && await File(p).exists()) return File(p);
      if (p == null) return null;
    }
    final f = await VideoPrep.low(hd);
    m.lowPath = f?.path;
    m.lowDone = true;
    m.lowPart = null;
    _save(now: true);
    return f;
  }

  /// Deletes the files we made (HD / low copies). With [deleteUploads]
  /// also the files already on the server (task cancelled).
  Future<void> _cleanup(UploadTask t, {required bool deleteUploads}) async {
    for (final m in t.items) {
      // v0.12: our recorded voice over file
      final vp = m.edits.voicePath;
      if (vp.isNotEmpty && vp.contains('voiceover_')) {
        await File(vp).delete().then((_) {}, onError: (Object _) {});
      }
      for (final p in [m.hdPath, m.lowPath]) {
        if (p == null || p == m.path) continue;
        final f = File(p);
        if (await VideoPrep.isOurs(f)) {
          await f.delete().then((_) {}, onError: (Object _) {});
        }
      }
      if (deleteUploads) {
        for (final u in [m.main, m.thumb, m.low, m.voice]) {
          if (u != null) unawaited(MediaService.instance.delete(u.key));
        }
        // half-uploaded big files: free the parts on the server
        for (final st in [m.mainPart, m.lowPart]) {
          if (st == null) continue;
          unawaited(
            ApiClient.instance
                .post('/api/multipart', {
                  'action': 'abort',
                  'key': st.key,
                  'uploadId': st.uploadId,
                })
                .then<void>((_) {}, onError: (Object _) {}),
          );
        }
      }
    }
    if (deleteUploads) {
      for (final u in [t.cover, t.audio]) {
        if (u != null) unawaited(MediaService.instance.delete(u.key));
      }
    }
  }

  void _save({bool now = false}) {
    _saveTimer?.cancel();
    if (now) {
      unawaited(_write());
    } else {
      _saveTimer = Timer(const Duration(milliseconds: 800), _write);
    }
  }

  Future<void> _write() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keep = _tasks.where((t) => t.status != UploadStatus.done);
      if (keep.isEmpty) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(
          _prefsKey,
          jsonEncode(keep.map((t) => t.toJson()).toList()),
        );
      }
    } catch (e) {
      debugPrint('upload queue save: $e');
    }
  }

  @visibleForTesting
  Future<void> debugReset() async {
    for (final r in _retryTimers.values) {
      r.cancel();
    }
    _retryTimers.clear();
    _saveTimer?.cancel();
    _tasks.clear();
    _loaded = false;
    _working = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    notifyListeners();
  }
}

class _Slot {
  _Slot(this.weight, this.run);
  final int weight;
  final Future<void> Function(ValueChanged<double> onProgress) run;
  double progress = 0;
}
