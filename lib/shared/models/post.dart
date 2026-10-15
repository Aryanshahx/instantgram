import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

DateTime _date(Object? v) => v is Timestamp
    ? v.toDate()
    : v is DateTime
    ? v
    : DateTime.now();
int _int(Object? v) => v is num ? v.toInt() : 0;
String _str(Object? v) => v is String ? v : '';

List<double>? _matrix(Object? v) {
  if (v is! List || v.length != 20) return null;
  final out = <double>[];
  for (final x in v) {
    if (x is! num) return null;
    out.add(x.toDouble());
  }
  return out;
}

bool _bool(Object? v) => v == true;

/// Who can see a post / clip / moment.
class Audience {
  Audience._();
  static const String everyone = 'everyone';
  static const String followers = 'followers';
  static const String onlyMe = 'only_me';

  static const List<String> all = [everyone, followers, onlyMe];

  static String label(String a) => switch (a) {
    followers => 'Followers',
    onlyMe => 'Only me',
    _ => 'Everyone',
  };

  static String normalize(Object? v) =>
      v is String && all.contains(v) ? v : everyone;
}

/// v0.12: a removed part of a video (split + delete), source time in ms.
class VideoCut {
  const VideoCut(this.startMs, this.endMs);
  final int startMs;
  final int endMs;

  int get length => endMs - startMs;
  bool contains(int ms) => ms >= startMs && ms < endMs;

  Map<String, dynamic> toMap() => {'s': startMs, 'e': endMs};

  static VideoCut? fromMap(Object? v) {
    if (v is! Map) return null;
    final s = v['s'], e = v['e'];
    if (s is! num || e is! num || e <= s || s < 0) return null;
    return VideoCut(s.toInt(), e.toInt());
  }

  @override
  bool operator ==(Object other) =>
      other is VideoCut && other.startMs == startMs && other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);

  @override
  String toString() => 'VideoCut($startMs-$endMs)';
}

/// v0.12: text or sticker shown on a video for a time (source ms).
class VideoOverlay {
  const VideoOverlay({
    required this.kind,
    required this.text,
    this.color = 0xFFFFFFFF,
    this.size = 0.08,
    this.x = 0.5,
    this.y = 0.5,
    this.background = false,
    this.startMs = 0,
    this.endMs = 0,
  });

  static const String textKind = 'text';
  static const String stickerKind = 'sticker';

  /// [textKind] or [stickerKind].
  final String kind;
  final String text;

  /// ARGB colour (text).
  final int color;

  /// Font size as a part of the video width.
  final double size;

  /// Center position, 0..1 of the video.
  final double x;
  final double y;
  final bool background;

  /// Shown from [startMs] until [endMs] (0 = until the end).
  final int startMs;
  final int endMs;

  bool get isSticker => kind == stickerKind;
  bool visibleAt(int ms) => ms >= startMs && (endMs <= 0 || ms < endMs);

  VideoOverlay copyWith({
    String? text,
    int? color,
    double? size,
    double? x,
    double? y,
    bool? background,
    int? startMs,
    int? endMs,
  }) => VideoOverlay(
    kind: kind,
    text: text ?? this.text,
    color: color ?? this.color,
    size: size ?? this.size,
    x: x ?? this.x,
    y: y ?? this.y,
    background: background ?? this.background,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
  );

  Map<String, dynamic> toMap() => {
    'k': kind,
    't': text,
    'c': color,
    'z': double.parse(size.toStringAsFixed(4)),
    'x': double.parse(x.toStringAsFixed(4)),
    'y': double.parse(y.toStringAsFixed(4)),
    if (background) 'bg': true,
    if (startMs > 0) 's': startMs,
    if (endMs > 0) 'e': endMs,
  };

  static VideoOverlay? fromMap(Object? v) {
    if (v is! Map) return null;
    final t = v['t'];
    if (t is! String || t.isEmpty) return null;
    double d(Object? x, double def, double lo, double hi) =>
        x is num ? x.toDouble().clamp(lo, hi) : def;
    return VideoOverlay(
      kind: v['k'] == stickerKind ? stickerKind : textKind,
      text: t.length > 300 ? t.substring(0, 300) : t,
      color: v['c'] is num ? (v['c'] as num).toInt() : 0xFFFFFFFF,
      size: d(v['z'], 0.08, 0.02, 0.95),
      x: d(v['x'], 0.5, 0, 1),
      y: d(v['y'], 0.5, 0, 1),
      background: v['bg'] == true,
      startMs: v['s'] is num ? (v['s'] as num).toInt() : 0,
      endMs: v['e'] is num ? (v['e'] as num).toInt() : 0,
    );
  }
}

/// Edits for a video that are applied while playing
/// (the original file is uploaded unchanged).
class VideoEdits {
  const VideoEdits({
    this.trimStartMs = 0,
    this.trimEndMs = 0,
    this.filter,
    this.muted = false,
    this.cuts = const [],
    this.overlays = const [],
    this.voiceUrl = '',
    this.voiceKey = '',
    this.voicePath = '',
    this.voiceStartMs = 0,
    this.voiceDurMs = 0,
  });

  /// 0 = from the start.
  final int trimStartMs;

  /// 0 = to the end.
  final int trimEndMs;

  /// 4x5 color matrix (20 numbers) or null.
  final List<double>? filter;

  /// Original sound off.
  final bool muted;

  /// v0.12: removed parts (split + delete), sorted, source ms.
  final List<VideoCut> cuts;

  /// v0.12: texts and stickers with their times.
  final List<VideoOverlay> overlays;

  /// v0.12: voice over (uploaded file). Plays from [voiceStartMs] of the
  /// PLAYED video (after trim and cuts) for [voiceDurMs].
  final String voiceUrl;
  final String voiceKey;

  /// Recorded file on this phone (before upload; never in Firestore).
  final String voicePath;
  final int voiceStartMs;
  final int voiceDurMs;

  /// The player must watch the position (trim, cuts).
  bool get hasTrim => trimStartMs > 0 || trimEndMs > 0 || cuts.isNotEmpty;

  bool get hasVoice =>
      (voiceUrl.isNotEmpty || voicePath.isNotEmpty) && voiceDurMs > 0;

  /// Where to play the voice from (URL after upload, else the file).
  String get voiceSource => voiceUrl.isNotEmpty ? voiceUrl : voicePath;

  /// After the voice file is uploaded.
  VideoEdits withVoice(String url, String key) => VideoEdits(
    trimStartMs: trimStartMs,
    trimEndMs: trimEndMs,
    filter: filter,
    muted: muted,
    cuts: cuts,
    overlays: overlays,
    voiceUrl: url,
    voiceKey: key,
    voiceStartMs: voiceStartMs,
    voiceDurMs: voiceDurMs,
  );

  /// Moments: no voice over.
  VideoEdits withoutVoice() => VideoEdits(
    trimStartMs: trimStartMs,
    trimEndMs: trimEndMs,
    filter: filter,
    muted: muted,
    cuts: cuts,
    overlays: overlays,
  );

  Map<String, dynamic> toMap() => {
    if (trimStartMs > 0) 'trimStartMs': trimStartMs,
    if (trimEndMs > 0) 'trimEndMs': trimEndMs,
    if (filter != null) 'filter': filter,
    if (muted) 'muteAudio': true,
    if (cuts.isNotEmpty) 'cuts': [for (final c in cuts) c.toMap()],
    if (overlays.isNotEmpty) 'overlays': [for (final o in overlays) o.toMap()],
    if (voiceUrl.isNotEmpty) ...{'voiceUrl': voiceUrl, 'voiceKey': voiceKey},
    if (voicePath.isNotEmpty) 'voicePath': voicePath,
    if (hasVoice) ...{'voiceStartMs': voiceStartMs, 'voiceDurMs': voiceDurMs},
  };

  factory VideoEdits.fromMap(Map<String, dynamic> m) => VideoEdits(
    trimStartMs: _int(m['trimStartMs']),
    trimEndMs: _int(m['trimEndMs']),
    filter: _matrix(m['filter']),
    muted: _bool(m['muteAudio']),
    cuts: VideoTime.normalize(
      m['cuts'] is List
          ? (m['cuts'] as List).map(VideoCut.fromMap).whereType<VideoCut>()
          : const <VideoCut>[],
    ),
    overlays: m['overlays'] is List
        ? (m['overlays'] as List)
              .map(VideoOverlay.fromMap)
              .whereType<VideoOverlay>()
              .take(50)
              .toList()
        : const [],
    voiceUrl: _str(m['voiceUrl']),
    voiceKey: _str(m['voiceKey']),
    voicePath: _str(m['voicePath']),
    voiceStartMs: _int(m['voiceStartMs']),
    voiceDurMs: _int(m['voiceDurMs']),
  );
}

/// v0.12: time maths for trim + cuts (source time = position in the file,
/// played time = what the viewer sees after trim and cuts).
class VideoTime {
  VideoTime._();

  /// Sorted, merged, no empty parts.
  static List<VideoCut> normalize(Iterable<VideoCut> cuts) {
    final l = cuts.where((c) => c.endMs > c.startMs).toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final out = <VideoCut>[];
    for (final c in l) {
      if (out.isNotEmpty && c.startMs <= out.last.endMs) {
        final last = out.removeLast();
        out.add(VideoCut(last.startMs, max(last.endMs, c.endMs)));
      } else {
        out.add(c);
      }
    }
    return out;
  }

  /// Inside a removed part: where to jump to (else null).
  static int? skipTo(int pos, List<VideoCut> cuts) {
    for (final c in cuts) {
      if (c.contains(pos)) return c.endMs;
    }
    return null;
  }

  /// First playable moment at or after [start] (skips a cut at the start).
  static int firstPlayable(int start, List<VideoCut> cuts) {
    var p = start;
    for (final c in cuts) {
      if (c.contains(p)) p = c.endMs;
    }
    return p;
  }

  /// Last playable moment at or before [end] (a cut at the very end
  /// makes the video end earlier).
  static int playableEnd(int end, List<VideoCut> cuts) {
    var e = end;
    for (final c in cuts.reversed) {
      if (c.startMs < e && c.endMs >= e) e = c.startMs;
    }
    return e;
  }

  /// Length the viewer sees.
  static int playedMs(int start, int end, List<VideoCut> cuts) {
    if (end <= start) return 0;
    var removed = 0;
    for (final c in cuts) {
      final s = max(c.startMs, start), e = min(c.endMs, end);
      if (e > s) removed += e - s;
    }
    return max(0, end - start - removed);
  }

  /// Source position -> played time.
  static int playedAt(int pos, int start, List<VideoCut> cuts) =>
      playedMs(start, max(start, pos), cuts);

  /// Played time -> source position.
  static int sourceAt(int played, int start, List<VideoCut> cuts) {
    var src = start;
    var left = max(0, played);
    for (final c in cuts) {
      if (c.endMs <= src) continue;
      final gap = c.startMs - src;
      if (gap >= left) break;
      if (gap > 0) left -= gap;
      src = max(src, c.endMs);
    }
    return src + left;
  }
}

/// One photo or video inside a post or clip.
/// Old posts stored only photos here (no `type`).
class MediaItem {
  const MediaItem({
    required this.url,
    this.key = '',
    this.aspectRatio = 1,
    this.isVideo = false,
    this.thumbUrl = '',
    this.thumbKey = '',
    this.durationMs = 0,
    this.edits = const VideoEdits(),
    this.lowUrl = '',
    this.lowKey = '',
  });

  static const String photo = 'photo';
  static const String video = 'video';

  final String url;
  final String key;

  /// width / height (always a safe, finite number > 0).
  final double aspectRatio;
  final bool isVideo;

  /// Video cover image ('' = none).
  final String thumbUrl;
  final String thumbKey;

  /// Video length after trim (0 = unknown).
  final int durationMs;

  /// Video trim / filter / mute.
  final VideoEdits edits;

  /// Smaller copy of a video, played only when the full one buffers
  /// ('' = none, e.g. posts from before v0.7).
  final String lowUrl;
  final String lowKey;

  /// Image to show in grids / while a video loads.
  String get coverUrl => isVideo ? thumbUrl : url;

  Map<String, dynamic> toMap() => {
    'type': isVideo ? video : photo,
    'url': url,
    'key': key,
    'aspectRatio': aspectRatio,
    if (thumbUrl.isNotEmpty) 'thumbUrl': thumbUrl,
    if (thumbKey.isNotEmpty) 'thumbKey': thumbKey,
    if (durationMs > 0) 'durationMs': durationMs,
    if (isVideo && edits.toMap().isNotEmpty) 'edits': edits.toMap(),
    if (lowUrl.isNotEmpty) 'lowUrl': lowUrl,
    if (lowKey.isNotEmpty) 'lowKey': lowKey,
  };

  static MediaItem? fromMap(Object? v) {
    if (v is! Map) return null;
    final url = v['url'];
    if (url is! String || url.isEmpty) return null;
    final e = v['edits'];
    return MediaItem(
      url: url,
      key: _str(v['key']),
      aspectRatio: safeAspect(v['aspectRatio']),
      isVideo: v['type'] == video,
      thumbUrl: _str(v['thumbUrl']),
      thumbKey: _str(v['thumbKey']),
      durationMs: _int(v['durationMs']),
      lowUrl: _str(v['lowUrl']),
      lowKey: _str(v['lowKey']),
      edits: e is Map
          ? VideoEdits.fromMap(Map<String, dynamic>.from(e))
          : const VideoEdits(),
    );
  }
}

/// Any stored aspect ratio -> a finite number between 0.2 and 5 (1 if bad).
/// (NaN / infinity / 0 would crash the layout.)
double safeAspect(Object? v) {
  if (v is! num) return 1;
  final d = v.toDouble();
  if (d.isNaN || d.isInfinite || d <= 0) return 1;
  return d.clamp(0.2, 5.0);
}

/// A photo post or a clip (short video).
class Post {
  const Post({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    required this.authorPhotoUrl,
    required this.type,
    required this.mediaUrl,
    required this.mediaKey,
    required this.caption,
    required this.aspectRatio,
    required this.likesCount,
    required this.commentsCount,
    required this.repostsCount,
    required this.viewsCount,
    required this.pinned,
    required this.createdAt,
    this.media = const [],
    this.thumbUrl = '',
    this.thumbKey = '',
    this.edits = const VideoEdits(),
    this.audience = Audience.everyone,
    this.sharesCount = 0,
    this.hideLikes = false,
    this.hideComments = false,
    this.hideReposts = false,
    this.hideShares = false,
    this.durationMs = 0,
    this.audioUrl = '',
    this.audioKey = '',
    this.audioName = '',
    this.savesCount = 0,
    this.replyTo,
    this.pinnedComment = '',
  });

  static const String photo = 'photo';
  static const String clip = 'clip';

  final String id;
  final String authorId;
  final String authorUsername;
  final String authorPhotoUrl;
  final String type;
  final String mediaUrl;
  final String mediaKey;
  final String caption;

  /// width / height
  final double aspectRatio;
  final int likesCount;
  final int commentsCount;
  final int repostsCount;
  final int viewsCount;
  final bool pinned;
  final DateTime createdAt;

  /// All photos / videos (new posts). Use [items] to read them.
  final List<MediaItem> media;

  /// v0.11: id of the comment the owner pinned ('' = none).
  final String pinnedComment;

  /// Clip cover image ('' = none).
  final String thumbUrl;
  final String thumbKey;

  /// Clip trim / filter / mute.
  final VideoEdits edits;

  final String audience;
  final int sharesCount;
  final bool hideLikes;
  final bool hideComments;
  final bool hideReposts;
  final bool hideShares;

  /// Video length (old single-video clips).
  final int durationMs;

  /// Music picked in the editor ('' = none). Plays in a loop.
  final String audioUrl;
  final String audioKey;
  final String audioName;

  final int savesCount;

  /// v0.9: this post / clip answers a comment (sticker on it).
  final ReplyRef? replyTo;

  bool get isClip => type == clip;
  bool get hasMusic => audioUrl.isNotEmpty;

  /// Every photo / video, in order (works for old and new posts).
  List<MediaItem> get items {
    if (media.isNotEmpty) return media;
    if (isClip) {
      return [
        MediaItem(
          url: mediaUrl,
          key: mediaKey,
          aspectRatio: aspectRatio,
          isVideo: true,
          thumbUrl: thumbUrl,
          thumbKey: thumbKey,
          durationMs: durationMs,
          edits: edits,
        ),
      ];
    }
    return [MediaItem(url: mediaUrl, key: mediaKey, aspectRatio: aspectRatio)];
  }

  bool get isMulti => items.length > 1;
  bool get hasVideo => items.any((m) => m.isVideo);

  /// First item is a video (shows a play icon in grids).
  bool get startsWithVideo => items.isNotEmpty && items.first.isVideo;

  /// Image for grids, notifications and sharing ('' = none).
  String get coverUrl {
    if (thumbUrl.isNotEmpty) return thumbUrl;
    for (final m in items) {
      if (m.coverUrl.isNotEmpty) return m.coverUrl;
    }
    return '';
  }

  /// Every storage key used by this post (for delete).
  List<String> get allKeys => {
    if (mediaKey.isNotEmpty) mediaKey,
    for (final m in media) ...[
      if (m.key.isNotEmpty) m.key,
      if (m.thumbKey.isNotEmpty) m.thumbKey,
      if (m.lowKey.isNotEmpty) m.lowKey,
      if (m.edits.voiceKey.isNotEmpty) m.edits.voiceKey,
    ],
    if (thumbKey.isNotEmpty) thumbKey,
    if (audioKey.isNotEmpty) audioKey,
    if (edits.voiceKey.isNotEmpty) edits.voiceKey,
  }.toList();

  factory Post.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      Post.fromMap(doc.id, doc.data() ?? const <String, dynamic>{});

  factory Post.fromMap(String id, Map<String, dynamic> m) {
    final ar = m['aspectRatio'];
    final media = m['media'] is List
        ? (m['media'] as List)
              .map(MediaItem.fromMap)
              .whereType<MediaItem>()
              .toList()
        : const <MediaItem>[];
    return Post(
      id: id,
      authorId: _str(m['authorId']),
      authorUsername: _str(m['authorUsername']),
      authorPhotoUrl: _str(m['authorPhotoUrl']),
      type: _str(m['type']).isEmpty ? photo : _str(m['type']),
      mediaUrl: _str(m['mediaUrl']),
      mediaKey: _str(m['mediaKey']),
      caption: _str(m['caption']),
      aspectRatio: safeAspect(ar),
      likesCount: _int(m['likesCount']),
      commentsCount: _int(m['commentsCount']),
      repostsCount: _int(m['repostsCount']),
      // one view per account (v0.5.0+). The old 'viewsCount' was wrong
      // (it counted your own views and every app restart), so it isn't used.
      viewsCount: _int(m['uniqueViews']),
      pinned: m['pinned'] == true,
      createdAt: _date(m['createdAt']),
      media: media,
      thumbUrl: _str(m['thumbUrl']),
      thumbKey: _str(m['thumbKey']),
      edits: VideoEdits.fromMap(m),
      audience: Audience.normalize(m['audience']),
      sharesCount: _int(m['sharesCount']),
      hideLikes: _bool(m['hideLikes']),
      hideComments: _bool(m['hideComments']),
      hideReposts: _bool(m['hideReposts']),
      hideShares: _bool(m['hideShares']),
      durationMs: _int(m['durationMs']),
      audioUrl: _str(m['audioUrl']),
      audioKey: _str(m['audioKey']),
      audioName: _str(m['audioName']),
      savesCount: _int(m['savesCount']),
      replyTo: ReplyRef.fromMap(m['replyTo']),
      pinnedComment: _str(m['pinnedComment']),
    );
  }
}

/// v0.9: a post / clip made as an answer to a comment.
class ReplyRef {
  const ReplyRef({
    required this.postId,
    required this.commentId,
    required this.username,
    this.text = '',
    this.parentId = '',
    this.postAuthorId = '',
  });

  /// Post / clip the comment is under.
  final String postId;
  final String postAuthorId;

  /// The comment answered (+ its first comment when it is a reply).
  /// '' = answers the post / clip itself.
  final String commentId;
  final String parentId;

  /// Who wrote the comment, and what (short).
  final String username;
  final String text;

  /// Top comment the new reply hangs under.
  String get threadId => parentId.isNotEmpty ? parentId : commentId;

  bool get isComment => commentId.isNotEmpty;

  /// Sticker text on the new post / clip.
  String get label =>
      isComment ? "Reply to @$username's comment" : 'Reply to @$username';

  /// Answers the post / clip itself (not one comment).
  static ReplyRef toPost(Post post) => ReplyRef(
    postId: post.id,
    postAuthorId: post.authorId,
    commentId: '',
    username: post.authorUsername,
  );

  static ReplyRef fromComment(Post post, Comment c) => ReplyRef(
    postId: post.id,
    postAuthorId: post.authorId,
    commentId: c.id,
    parentId: c.parentId,
    username: c.authorUsername,
    text: c.text.length > 120 ? '${c.text.substring(0, 120)}…' : c.text,
  );

  Map<String, dynamic> toMap() => {
    'postId': postId,
    'postAuthorId': postAuthorId,
    'commentId': commentId,
    'parentId': parentId,
    'username': username,
    'text': text,
  };

  static ReplyRef? fromMap(Object? v) {
    if (v is! Map) return null;
    final postId = _str(v['postId']);
    final commentId = _str(v['commentId']);
    if (postId.isEmpty) return null;
    return ReplyRef(
      postId: postId,
      postAuthorId: _str(v['postAuthorId']),
      commentId: commentId,
      parentId: _str(v['parentId']),
      username: _str(v['username']),
      text: _str(v['text']),
    );
  }
}

class Comment {
  const Comment({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    required this.authorPhotoUrl,
    required this.text,
    required this.createdAt,
    this.parentId = '',
    this.replyToUsername = '',
    this.imageUrl = '',
    this.imageKey = '',
    this.imageW = 0,
    this.imageH = 0,
    this.gifUrl = '',
    this.gifW = 0,
    this.gifH = 0,
    this.likesCount = 0,
    this.repliesCount = 0,
    this.refPostId = '',
    this.refPostType = '',
    this.refThumb = '',
    this.refAuthor = '',
  });

  final String id;
  final String authorId;
  final String authorUsername;
  final String authorPhotoUrl;
  final String text;
  final DateTime createdAt;

  /// v0.8: reply to this comment id ('' = normal comment).
  final String parentId;

  /// Who the reply answers (shown as @name).
  final String replyToUsername;

  /// Photo / gallery GIF sent with the comment.
  final String imageUrl;
  final String imageKey;
  final int imageW;
  final int imageH;

  /// GIF from GIF search (GIPHY).
  final String gifUrl;
  final int gifW;
  final int gifH;

  final int likesCount;
  final int repliesCount;

  /// v0.9: answered with a post / clip (card in the comment).
  final String refPostId;
  final String refPostType;
  final String refThumb;
  final String refAuthor;

  bool get isReply => parentId.isNotEmpty;
  bool get hasRef => refPostId.isNotEmpty;

  /// Picture to show (photo or GIF), '' = text only.
  String get pictureUrl => gifUrl.isNotEmpty ? gifUrl : imageUrl;

  /// Width / height of the picture (1 when unknown).
  double get pictureAspect {
    final w = gifUrl.isNotEmpty ? gifW : imageW;
    final h = gifUrl.isNotEmpty ? gifH : imageH;
    if (w <= 0 || h <= 0) return 1;
    return (w / h).clamp(0.4, 2.5);
  }

  factory Comment.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      Comment.fromMap(doc.id, doc.data() ?? const <String, dynamic>{});

  factory Comment.fromMap(String id, Map<String, dynamic> m) => Comment(
    id: id,
    authorId: _str(m['authorId']),
    authorUsername: _str(m['authorUsername']),
    authorPhotoUrl: _str(m['authorPhotoUrl']),
    text: _str(m['text']),
    createdAt: _date(m['createdAt']),
    parentId: _str(m['parentId']),
    replyToUsername: _str(m['replyToUsername']),
    imageUrl: _str(m['imageUrl']),
    imageKey: _str(m['imageKey']),
    imageW: _int(m['imageW']),
    imageH: _int(m['imageH']),
    gifUrl: _str(m['gifUrl']),
    gifW: _int(m['gifW']),
    gifH: _int(m['gifH']),
    likesCount: _int(m['likesCount']),
    repliesCount: _int(m['repliesCount']),
    refPostId: _str(m['refPostId']),
    refPostType: _str(m['refPostType']),
    refThumb: _str(m['refThumb']),
    refAuthor: _str(m['refAuthor']),
  );
}

/// Comments in show order: each comment, then its replies (oldest first).
/// Replies whose comment was deleted are left out.
List<Comment> threadComments(List<Comment> all) {
  final top = <Comment>[];
  final replies = <String, List<Comment>>{};
  for (final c in all) {
    if (c.isReply) {
      (replies[c.parentId] ??= []).add(c);
    } else {
      top.add(c);
    }
  }
  final out = <Comment>[];
  for (final c in top) {
    out.add(c);
    out.addAll(replies[c.id] ?? const []);
  }
  return out;
}

class Story {
  const Story({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    required this.authorPhotoUrl,
    required this.mediaUrl,
    required this.mediaKey,
    required this.createdAt,
    this.type = photo,
    this.durationMs = 0,
    this.edits = const VideoEdits(),
    this.audience = Audience.everyone,
  });

  static const String photo = 'photo';
  static const String video = 'video';

  final String id;
  final String authorId;
  final String authorUsername;
  final String authorPhotoUrl;
  final String mediaUrl;
  final String mediaKey;
  final DateTime createdAt;
  final String type;

  /// Video length after trim (0 = unknown).
  final int durationMs;
  final VideoEdits edits;
  final String audience;

  bool get isVideo => type == video;

  /// v0.15: the copy of this moment kept inside a highlight.
  Map<String, dynamic> toHighlightItem() => {
    'id': id,
    'type': type,
    'mediaUrl': mediaUrl,
    if (durationMs > 0) 'durationMs': durationMs,
    'createdAt': Timestamp.fromDate(createdAt),
    if (isVideo) ...edits.toMap(),
  };

  factory Story.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      Story.fromMap(doc.id, doc.data() ?? const <String, dynamic>{});

  factory Story.fromMap(String id, Map<String, dynamic> m) {
    return Story(
      id: id,
      authorId: _str(m['authorId']),
      authorUsername: _str(m['authorUsername']),
      authorPhotoUrl: _str(m['authorPhotoUrl']),
      mediaUrl: _str(m['mediaUrl']),
      mediaKey: _str(m['mediaKey']),
      createdAt: _date(m['createdAt']),
      type: _str(m['type']) == video ? video : photo,
      durationMs: _int(m['durationMs']),
      edits: VideoEdits.fromMap(m),
      audience: Audience.normalize(m['audience']),
    );
  }
}

/// All active stories of one user.
class StoryGroup {
  StoryGroup(this.authorId, this.stories);
  final String authorId;
  final List<Story> stories;

  String get username => stories.first.authorUsername;
  String get photoUrl => stories.first.authorPhotoUrl;
}

/// v0.11: disappearing messages in a chat.
class Disappear {
  Disappear._();
  static const String off = 'off';
  static const String seen = 'seen';
  static const String day = '24h';
  static const String week = '7d';
  static const List<String> all = [off, seen, day, week];

  /// What "slide up and hold" turns on.
  static const String standard = day;

  static String normalize(Object? v) =>
      v is String && all.contains(v) ? v : off;

  static String label(String mode) => switch (mode) {
    seen => 'Once seen',
    day => '24 hours',
    week => '7 days',
    _ => 'Off',
  };

  /// For the "alice turned on ..." message.
  static String sentence(String mode) => switch (mode) {
    seen => 'turned on disappearing messages: they disappear once seen',
    day => 'turned on disappearing messages: 24 hours',
    week => 'turned on disappearing messages: 7 days',
    _ => 'turned off disappearing messages',
  };

  /// How long a message lives (null = forever / once seen).
  static Duration? lifetime(String mode) => switch (mode) {
    day => const Duration(hours: 24),
    week => const Duration(days: 7),
    _ => null,
  };
}

class Chat {
  const Chat({
    required this.id,
    required this.members,
    required this.memberInfo,
    required this.lastMessage,
    required this.lastSenderId,
    required this.updatedAt,
    this.pinnedId = '',
    this.pinnedText = '',
    this.seen = const {},
    this.delivered = const {},
    this.disappear = Disappear.off,
    this.typing = const {},
  });

  final String id;
  final List<String> members;
  final Map<String, dynamic> memberInfo;
  final String lastMessage;
  final String lastSenderId;
  final DateTime updatedAt;

  /// v0.9: pinned message (id + short text), '' = none.
  final String pinnedId;
  final String pinnedText;

  /// v0.10 ticks: uid -> when that person last saw / got the messages.
  final Map<String, DateTime> seen;
  final Map<String, DateTime> delivered;

  /// v0.11: disappearing messages (see [Disappear]).
  /// v0.13: no longer used (each person sets it for themselves).
  final String disappear;

  /// v0.13: uid -> when that person last typed.
  final Map<String, DateTime> typing;

  /// How long "typing…" shows after the last keystroke signal.
  static const Duration typingFor = Duration(seconds: 8);

  /// [uid] is typing right now ([now] = server time).
  bool isTyping(String uid, DateTime now) {
    final t = typing[uid];
    if (t == null) return false;
    final age = now.difference(t);
    // a phone clock a bit ahead can make it look like the future
    return age < typingFor && age > const Duration(seconds: -30);
  }

  DateTime? seenAt(String uid) => seen[uid];

  /// Seen also counts as delivered.
  DateTime? deliveredAt(String uid) {
    final d = delivered[uid];
    final s = seen[uid];
    if (d == null) return s;
    if (s == null) return d;
    return s.isAfter(d) ? s : d;
  }

  /// The last message is from the other person and you haven't seen it.
  bool unreadFor(String me) {
    if (lastSenderId.isEmpty || lastSenderId == me) return false;
    final s = seen[me];
    return s == null || s.isBefore(updatedAt);
  }

  static Map<String, DateTime> _times(Object? v) {
    if (v is! Map) return const {};
    return {
      for (final e in v.entries)
        if (e.key is String && e.value is Timestamp)
          e.key as String: (e.value as Timestamp).toDate(),
    };
  }

  String otherUid(String me) =>
      members.firstWhere((m) => m != me, orElse: () => me);

  Map<String, dynamic> _info(String uid) {
    final v = memberInfo[uid];
    return v is Map<String, dynamic> ? v : const {};
  }

  String usernameOf(String uid) => _str(_info(uid)['username']);
  String photoOf(String uid) => _str(_info(uid)['photoUrl']);

  factory Chat.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      Chat.fromMap(doc.id, doc.data() ?? const <String, dynamic>{});

  factory Chat.fromMap(String id, Map<String, dynamic> m) {
    final info = m['memberInfo'];
    final pin = m['pinned'];
    return Chat(
      id: id,
      members: List<String>.from((m['members'] as List?) ?? const []),
      memberInfo: info is Map<String, dynamic> ? info : const {},
      lastMessage: _str(m['lastMessage']),
      lastSenderId: _str(m['lastSenderId']),
      updatedAt: _date(m['updatedAt']),
      pinnedId: pin is Map ? _str(pin['id']) : '',
      pinnedText: pin is Map ? _str(pin['text']) : '',
      seen: _times(m['seen']),
      delivered: _times(m['delivered']),
      disappear: Disappear.normalize(m['disappear']),
      typing: _times(m['typing']),
    );
  }
}

/// Short version of a message you answer (shown above your reply).
class MessageQuote {
  const MessageQuote({
    required this.id,
    required this.senderId,
    required this.text,
  });
  final String id;
  final String senderId;
  final String text;

  Map<String, dynamic> toMap() => {
    'id': id,
    'senderId': senderId,
    'text': text,
  };

  static MessageQuote? fromMap(Object? v) {
    if (v is! Map) return null;
    final id = _str(v['id']);
    if (id.isEmpty) return null;
    return MessageQuote(
      id: id,
      senderId: _str(v['senderId']),
      text: _str(v['text']),
    );
  }
}

class Message {
  const Message({
    required this.id,
    required this.senderId,
    required this.text,
    required this.createdAt,
    this.kind = plain,
    this.postId = '',
    this.postType = '',
    this.postThumb = '',
    this.postAuthor = '',
    this.postCaption = '',
    this.mediaUrl = '',
    this.mediaKey = '',
    this.width = 0,
    this.height = 0,
    this.durationMs = 0,
    this.lat = 0,
    this.lng = 0,
    this.address = '',
    this.replyTo,
    this.reactions = const {},
    this.hiddenFor = const [],
    this.forwarded = false,
    this.pending = false,
    this.expireAt,
    this.vanish = false,
    this.callStatus = '',
    this.video = false,
    this.durationSec = 0,
  });

  // kinds (v0.9)
  static const String plain = 'text';
  static const String post = 'post';
  static const String image = 'image';
  static const String gif = 'gif';
  static const String voice = 'voice';
  static const String location = 'location';
  // v0.11
  static const String call = 'call';
  static const String system = 'system';

  final String id;
  final String senderId;

  /// Text, or the caption of a photo / GIF ('' allowed for media).
  final String text;
  final DateTime createdAt;
  final String kind;

  /// Shared post / clip.
  final String postId;
  final String postType;
  final String postThumb;
  final String postAuthor;
  final String postCaption;

  /// Photo / GIF / voice file.
  final String mediaUrl;
  final String mediaKey;
  final int width;
  final int height;
  final int durationMs;

  /// Location.
  final double lat;
  final double lng;
  final String address;

  /// The message this one answers.
  final MessageQuote? replyTo;

  /// uid -> emoji
  final Map<String, String> reactions;

  /// "Delete for you": people who don't see it any more.
  final List<String> hiddenFor;
  final bool forwarded;

  /// v0.10: still on this phone only (not on the server yet) = clock icon.
  final bool pending;

  /// v0.11 disappearing: gone after this time (24 h / 7 days) ...
  final DateTime? expireAt;

  /// ... or once the other person saw it.
  final bool vanish;

  /// v0.11 call log: ended / missed / declined / busy / failed.
  final String callStatus;
  final bool video;
  final int durationSec;

  bool get isCall => kind == call;
  bool get isSystem => kind == system;
  bool get disappears => vanish || expireAt != null;

  /// Time is over (24 h / 7 days).
  bool expiredAt(DateTime now) => expireAt != null && !now.isBefore(expireAt!);

  /// "Voice call · 2:31", "Missed video call" ...
  String get callLabel {
    final what = video ? 'video call' : 'voice call';
    switch (callStatus) {
      case 'missed':
      case 'busy':
        return 'Missed $what';
      case 'declined':
        return '${what[0].toUpperCase()}${what.substring(1)} declined';
      case 'failed':
        return 'Call failed';
      default:
        final m = durationSec ~/ 60;
        final sec = (durationSec % 60).toString().padLeft(2, '0');
        final cap = '${what[0].toUpperCase()}${what.substring(1)}';
        return durationSec > 0 ? '$cap · $m:$sec' : cap;
    }
  }

  bool get isSharedPost => postId.isNotEmpty;
  bool get isImage => kind == image;
  bool get isGif => kind == gif;
  bool get isVoice => kind == voice;
  bool get isLocation => kind == location;

  double get aspect {
    if (width <= 0 || height <= 0) return 1;
    return (width / height).clamp(0.5, 2.0);
  }

  /// Text for the chat list / reply quote.
  String get preview {
    switch (kind) {
      case image:
        return text.isNotEmpty ? '📷 $text' : '📷 Photo';
      case gif:
        return 'GIF';
      case voice:
        return '🎤 Voice message';
      case location:
        return '📍 ${address.isNotEmpty ? address : 'Location'}';
      case call:
        return '📞 $callLabel';
      default:
        return text;
    }
  }

  /// Google Maps link for a location message.
  Uri get mapsUri =>
      Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');

  bool hiddenForUid(String uid) => hiddenFor.contains(uid);

  /// Reactions grouped: emoji -> how many (most first).
  List<MapEntry<String, int>> get reactionCounts {
    final m = <String, int>{};
    for (final e in reactions.values) {
      m[e] = (m[e] ?? 0) + 1;
    }
    final l = m.entries.toList()..sort((a, b) => b.value - a.value);
    return l;
  }

  factory Message.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      Message.fromMap(
        doc.id,
        doc.data() ?? const <String, dynamic>{},
        pending: doc.metadata.hasPendingWrites,
      );

  factory Message.fromMap(
    String id,
    Map<String, dynamic> m, {
    bool pending = false,
  }) {
    final postId = _str(m['postId']);
    var kind = _str(m['kind']);
    if (kind.isEmpty) kind = postId.isNotEmpty ? post : plain;
    final r = m['reactions'];
    double d(Object? v) => v is num ? v.toDouble() : 0;
    return Message(
      id: id,
      senderId: _str(m['senderId']),
      text: _str(m['text']),
      createdAt: _date(m['createdAt']),
      kind: kind,
      postId: postId,
      postType: _str(m['postType']),
      postThumb: _str(m['postThumb']),
      postAuthor: _str(m['postAuthor']),
      postCaption: _str(m['postCaption']),
      mediaUrl: _str(m['mediaUrl']),
      mediaKey: _str(m['mediaKey']),
      width: _int(m['width']),
      height: _int(m['height']),
      durationMs: _int(m['durationMs']),
      lat: d(m['lat']),
      lng: d(m['lng']),
      address: _str(m['address']),
      replyTo: MessageQuote.fromMap(m['replyTo']),
      reactions: r is Map
          ? {
              for (final e in r.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String,
            }
          : const {},
      hiddenFor: m['hiddenFor'] is List
          ? List<String>.from((m['hiddenFor'] as List).whereType<String>())
          : const [],
      forwarded: _bool(m['forwarded']),
      pending: pending,
      expireAt: m['expireAt'] is Timestamp
          ? (m['expireAt'] as Timestamp).toDate()
          : null,
      vanish: _bool(m['vanish']),
      callStatus: _str(m['callStatus']),
      video: _bool(m['video']),
      durationSec: _int(m['durationSec']),
    );
  }
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.fromUid,
    required this.fromUsername,
    required this.fromPhotoUrl,
    required this.postId,
    required this.postThumb,
    required this.text,
    required this.read,
    required this.createdAt,
  });

  static const like = 'like';
  static const comment = 'comment';
  static const follow = 'follow';
  static const repost = 'repost';
  // v0.12
  static const reply = 'reply';
  static const commentLike = 'comment_like';
  static const unfollow = 'unfollow';

  /// Written by our server: text = the number of views reached.
  static const views = 'views';

  /// v0.13: message from the InstantGram team (admin website).
  static const notice = 'notice';

  final String id;
  final String type;
  final String fromUid;
  final String fromUsername;
  final String fromPhotoUrl;
  final String postId;
  final String postThumb;
  final String text;
  final bool read;
  final DateTime createdAt;

  factory AppNotification.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const <String, dynamic>{};
    return AppNotification(
      id: doc.id,
      type: _str(m['type']),
      fromUid: _str(m['fromUid']),
      fromUsername: _str(m['fromUsername']),
      fromPhotoUrl: _str(m['fromPhotoUrl']),
      postId: _str(m['postId']),
      postThumb: _str(m['postThumb']),
      text: _str(m['text']),
      read: m['read'] == true,
      createdAt: _date(m['createdAt']),
    );
  }
}

/// v0.12: "Your clip reached 1,000 views" steps (same as the server).
class ViewMilestones {
  ViewMilestones._();
  static const steps = [
    100,
    500,
    1000,
    5000,
    10000,
    50000,
    100000,
    500000,
    1000000,
    5000000,
    10000000,
  ];

  /// Highest step reached (0 = none).
  static int reached(int views) {
    var m = 0;
    for (final s in steps) {
      if (views >= s) m = s;
    }
    return m;
  }

  /// Ask the server? (a new step was passed and not announced yet)
  static bool needsCheck(int views, int announced) =>
      reached(views) > announced;
}
