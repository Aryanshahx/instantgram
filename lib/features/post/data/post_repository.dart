import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/api_client.dart';
import '../../../core/services/app_settings.dart';
import '../../../core/services/content_filter.dart';
import '../../../core/services/media_service.dart';
import '../../../core/utils/merge_streams.dart';
import '../../../shared/models/post.dart';
import '../../notifications/data/notification_repository.dart';
import '../../../shared/models/user_profile.dart';
import '../../profile/data/user_repository.dart';
import '../../stories/data/story_repository.dart';

class PostRepository {
  PostRepository._();
  static final PostRepository instance = PostRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _posts =>
      _db.collection('posts');
  String get _me => FirebaseAuth.instance.currentUser!.uid;

  List<Post> _map(QuerySnapshot<Map<String, dynamic>> s) =>
      s.docs.map(Post.fromDoc).toList();

  /// "#Sunset at #goa" -> ['sunset', 'goa']
  static List<String> extractTags(String text) {
    final tags = <String>{};
    for (final m in RegExp(
      r'#([\p{L}\p{M}\p{N}_]{1,50})',
      unicode: true,
    ).allMatches(text)) {
      tags.add(m.group(1)!.toLowerCase());
      if (tags.length >= 30) break;
    }
    return tags.toList();
  }

  /// Clips with a hashtag (newest first).
  Future<List<Post>> clipsByTag(String tag) async =>
      (await postsByTag(tag)).where((p) => p.isClip).toList();

  /// v0.17: clips AND posts with a hashtag (newest first) - hashtag page.
  Future<List<Post>> postsByTag(String tag, {int limit = 150}) async {
    final t = normalizeTag(tag);
    if (t.isEmpty) return [];
    // Single-field query -> no extra Firestore index needed.
    final s = await _posts.where('tags', arrayContains: t).limit(limit).get();
    final list = _map(s).where(_filter.canSeeInFeeds).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// "#Goa " -> "goa" (how tags are saved).
  static String normalizeTag(String tag) =>
      tag.trim().replaceFirst(RegExp(r'^#+'), '').trim().toLowerCase();

  // ---------------- Create / delete ----------------

  Map<String, dynamic> _base(UserProfile me, PostOptions o, String caption) => {
    'authorId': me.uid,
    'authorUsername': me.username,
    'authorPhotoUrl': me.photoUrl,
    'caption': caption.trim(),
    'tags': extractTags(caption),
    'likesCount': 0,
    'commentsCount': 0,
    'repostsCount': 0,
    'viewsCount': 0,
    'uniqueViews': 0,
    'sharesCount': 0,
    'savesCount': 0,
    'pinned': false,
    'audience': o.audience,
    'hideLikes': o.hideLikes,
    'hideComments': o.hideComments,
    'hideReposts': o.hideReposts,
    'hideShares': o.hideShares,
    if (o.profileOnly) 'profileOnly': true,
    'createdAt': FieldValue.serverTimestamp(),
  };

  /// Most items one post / clip may have (Firestore rules allow 200).
  static const int maxItems = 200;

  /// New post id (chosen before upload, so a retry never posts twice).
  String newPostId() => _posts.doc().id;

  /// Writes a post or clip whose files are already uploaded (v0.8: the
  /// upload queue uploads in the background, then calls this).
  /// Safe to call again with the same [postId] (no double post).
  Future<void> publishPost({
    required String postId,
    required String type,
    required List<MediaItem> media,
    required String caption,
    UploadedMedia? cover,
    UploadedMedia? audio,
    String audioName = '',
    PostOptions options = const PostOptions(),
    ReplyRef? replyTo,
  }) async {
    if (media.isEmpty) throw ArgumentError('Nothing to share');
    if (media.length > maxItems) {
      throw StateError('You can share up to $maxItems photos and videos');
    }
    final ref = _posts.doc(postId);
    final me = await UserRepository.instance.me();
    final first = media.first;
    // cover for grids: chosen cover, else the first item's image
    final coverUrl = cover?.url ?? first.coverUrl;
    final coverKey = cover?.key ?? (first.isVideo ? first.thumbKey : '');
    final batch = _db.batch();
    batch.set(ref, {
      ..._base(me, options, caption),
      'type': type,
      'mediaUrl': first.url,
      'mediaKey': first.key,
      'aspectRatio': first.aspectRatio,
      'media': media.map((m) => m.toMap()).toList(),
      'itemCount': media.length,
      if (coverUrl.isNotEmpty) 'thumbUrl': coverUrl,
      if (coverKey.isNotEmpty) 'thumbKey': coverKey,
      // older app versions read these for a clip's first video
      if (first.isVideo && first.durationMs > 0) 'durationMs': first.durationMs,
      if (first.isVideo) ...first.edits.toMap(),
      if (audio != null) ...{
        'audioUrl': audio.url,
        'audioKey': audio.key,
        'audioName': audioName,
      },
      // v0.9: made as an answer to a comment
      if (replyTo != null) 'replyTo': replyTo.toMap(),
    });
    batch.update(_db.collection('users').doc(me.uid), {
      'postsCount': FieldValue.increment(1),
    });
    if (options.alsoMoment) {
      StoryRepository.instance.addSharedToBatch(
        batch,
        me: me,
        url: first.url,
        isVideo: first.isVideo,
        postId: ref.id,
        audience: options.audience,
        edits: first.edits,
        durationMs: first.durationMs,
      );
    }
    try {
      await batch.commit();
    } catch (e) {
      // posted already (app closed right after the last try)?
      final done = await ref
          .get()
          .then((d) => d.exists && d.data()?['authorId'] == me.uid)
          .catchError((Object _) => false);
      if (!done) rethrow;
    }
  }

  Future<void> delete(Post post) async {
    final batch = _db.batch();
    batch.delete(_posts.doc(post.id));
    batch.update(_db.collection('users').doc(post.authorId), {
      'postsCount': FieldValue.increment(-1),
    });
    await batch.commit();
    for (final k in post.allKeys) {
      MediaService.instance.delete(k);
    }
  }

  /// Owner changes who can see it / which counts are hidden.
  Future<void> updateOptions(Post post, Map<String, dynamic> fields) =>
      _posts.doc(post.id).update(fields);

  Future<void> setPinned(Post post, bool pinned) =>
      _posts.doc(post.id).update({'pinned': pinned});

  // ---------------- Queries ----------------

  Stream<Post?> watch(String id) => _posts
      .doc(id)
      .snapshots()
      .map((s) => s.exists ? Post.fromDoc(s) : null)
      // hidden (blocked / private / audience) -> treated as "not found"
      .map((p) => p == null || _filter.canSee(p) ? p : null);

  ContentFilter get _filter => ContentFilter.instance;

  /// Posts from a list of authors (max 30).
  Stream<List<Post>> feed(List<String> authorIds) => _filter.feedPosts(
    _posts
        .where('authorId', whereIn: authorIds.take(30).toList())
        .orderBy('createdAt', descending: true)
        .limit(60)
        .snapshots()
        .map(_map),
  );

  /// Discover feed: posts from [authorIds] (me + following + famous).
  /// Firestore allows 30 ids per query, so we ask in groups of 30 and
  /// merge the answers (newest first). Comes from the offline cache first,
  /// so opening the app again shows the feed instantly.
  Stream<List<Post>> feedFor(
    List<String> authorIds, {
    int perChunk = 40,
    int max = 150,
  }) {
    final ids = authorIds.toSet().toList();
    if (ids.isEmpty) return Stream.value(const <Post>[]);
    final parts = <Stream<List<Post>>>[];
    for (var i = 0; i < ids.length; i += 30) {
      final chunk = ids.sublist(i, i + 30 > ids.length ? ids.length : i + 30);
      parts.add(
        _posts
            .where('authorId', whereIn: chunk)
            .orderBy('createdAt', descending: true)
            .limit(perChunk)
            .snapshots()
            .map(_map),
      );
    }
    return _filter.feedPosts(
      combineLatestList<List<Post>, List<Post>>(
        parts,
        (all) => mergeNewest(all, max: max),
      ),
    );
  }

  // ---------------- v0.13: pull to refresh (from the server) ----------------

  static const _server = GetOptions(source: Source.server);

  /// Gets the newest feed from the server (open lists update by themselves).
  Future<void> refreshFeed(List<String> authorIds, {int perChunk = 40}) async {
    final ids = authorIds.toSet().toList();
    await Future.wait([
      for (var i = 0; i < ids.length; i += 30)
        _posts
            .where(
              'authorId',
              whereIn: ids.sublist(
                i,
                i + 30 > ids.length ? ids.length : i + 30,
              ),
            )
            .orderBy('createdAt', descending: true)
            .limit(perChunk)
            .get(_server),
    ]);
  }

  Future<void> refreshRecent({String? type, int limit = 60}) async {
    Query<Map<String, dynamic>> q = _posts;
    if (type != null) q = q.where('type', isEqualTo: type);
    await q.orderBy('createdAt', descending: true).limit(limit).get(_server);
  }

  Future<void> refreshUser(String uid) async {
    await Future.wait([
      for (final type in [Post.photo, Post.clip])
        _posts
            .where('authorId', isEqualTo: uid)
            .where('type', isEqualTo: type)
            .orderBy('createdAt', descending: true)
            .limit(120)
            .get(_server),
      _db
          .collection('users')
          .doc(uid)
          .collection('reposts')
          .orderBy('createdAt', descending: true)
          .limit(300)
          .get(_server),
      _db.collection('users').doc(uid).get(_server),
    ]);
  }

  /// Latest posts from everyone. [type] = Post.photo / Post.clip / null (all)
  Stream<List<Post>> recent({String? type, int limit = 60}) {
    Query<Map<String, dynamic>> q = _posts;
    if (type != null) q = q.where('type', isEqualTo: type);
    return _filter.feedPosts(
      q
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map(_map),
    );
  }

  Stream<List<Post>> byUser(String uid, {required String type}) =>
      _filter.visiblePosts(
        _posts
            .where('authorId', isEqualTo: uid)
            .where('type', isEqualTo: type)
            .orderBy('createdAt', descending: true)
            .limit(120)
            .snapshots()
            .map((s) {
              final list = _map(s);
              list.sort((a, b) {
                if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
                return b.createdAt.compareTo(a.createdAt);
              });
              return list;
            }),
      );

  Future<List<Post>> allByUser(String uid) async {
    final s = await _posts.where('authorId', isEqualTo: uid).limit(500).get();
    return _map(s);
  }

  Future<List<Post>> byIds(List<String> ids) async {
    final out = <Post>[];
    for (var i = 0; i < ids.length; i += 30) {
      final chunk = ids.sublist(i, i + 30 > ids.length ? ids.length : i + 30);
      final s = await _posts.where(FieldPath.documentId, whereIn: chunk).get();
      out.addAll(_map(s));
    }
    final byId = {for (final p in out) p.id: p};
    return [
      for (final id in ids)
        if (byId[id] != null && _filter.canSee(byId[id]!)) byId[id]!,
    ];
  }

  Stream<List<String>> savedIds() => _db
      .collection('users')
      .doc(_me)
      .collection('saved')
      .orderBy('createdAt', descending: true)
      .limit(300)
      .snapshots()
      .map((s) => s.docs.map((d) => d.id).toList());

  Stream<List<String>> repostIds(String uid) => _db
      .collection('users')
      .doc(uid)
      .collection('reposts')
      .orderBy('createdAt', descending: true)
      .limit(300)
      .snapshots()
      .map((s) => s.docs.map((d) => d.id).toList());

  // ---------------- Likes ----------------

  Stream<bool> isLiked(String postId) => _posts
      .doc(postId)
      .collection('likes')
      .doc(_me)
      .snapshots()
      .map((s) => s.exists);

  Future<void> setLiked(Post post, bool like) async {
    final ref = _posts.doc(post.id);
    final batch = _db.batch();
    var pending = const Pending.none();
    if (like) {
      final me = await UserRepository.instance.meCached();
      batch.set(ref.collection('likes').doc(_me), {
        'createdAt': FieldValue.serverTimestamp(),
      });
      batch.update(ref, {'likesCount': FieldValue.increment(1)});
      pending = NotificationRepository.instance.addToBatch(
        batch,
        toUid: post.authorId,
        from: me,
        type: AppNotification.like,
        post: post,
      );
    } else {
      batch.delete(ref.collection('likes').doc(_me));
      batch.update(ref, {'likesCount': FieldValue.increment(-1)});
    }
    await batch.commit();
    pending.send();
  }

  // ---------------- Save / repost ----------------

  Stream<bool> isSaved(String postId) => _db
      .collection('users')
      .doc(_me)
      .collection('saved')
      .doc(postId)
      .snapshots()
      .map((s) => s.exists);

  /// Save / unsave (+ keeps savesCount in step for Analytics).
  Future<void> setSaved(Post post, bool save) async {
    final ref = _db
        .collection('users')
        .doc(_me)
        .collection('saved')
        .doc(post.id);
    final exists = (await ref.get()).exists;
    if (exists == save) return;
    final batch = _db.batch();
    if (save) {
      batch.set(ref, {'createdAt': FieldValue.serverTimestamp()});
    } else {
      batch.delete(ref);
    }
    batch.update(_posts.doc(post.id), {
      'savesCount': FieldValue.increment(save ? 1 : -1),
    });
    try {
      await batch.commit();
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied' && e.code != 'not-found') rethrow;
      // old rules / deleted post: still save it for you
      save
          ? await ref.set({'createdAt': FieldValue.serverTimestamp()})
          : await ref.delete();
    }
  }

  Stream<bool> isReposted(String postId) => _db
      .collection('users')
      .doc(_me)
      .collection('reposts')
      .doc(postId)
      .snapshots()
      .map((s) => s.exists);

  Future<void> setReposted(Post post, bool repost) async {
    final ref = _db
        .collection('users')
        .doc(_me)
        .collection('reposts')
        .doc(post.id);
    final batch = _db.batch();
    var pending = const Pending.none();
    if (repost) {
      final me = await UserRepository.instance.meCached();
      batch.set(ref, {'createdAt': FieldValue.serverTimestamp()});
      batch.update(_posts.doc(post.id), {
        'repostsCount': FieldValue.increment(1),
      });
      pending = NotificationRepository.instance.addToBatch(
        batch,
        toUid: post.authorId,
        from: me,
        type: AppNotification.repost,
        post: post,
      );
    } else {
      batch.delete(ref);
      batch.update(_posts.doc(post.id), {
        'repostsCount': FieldValue.increment(-1),
      });
    }
    await batch.commit();
    pending.send();
  }

  // ---------------- Comments ----------------

  Stream<List<Comment>> comments(String postId) => _posts
      .doc(postId)
      .collection('comments')
      .orderBy('createdAt')
      .limit(300)
      .snapshots()
      .map(
        (s) => s.docs
            .map(Comment.fromDoc)
            .where((c) => !_filter.isBlocked(c.authorId))
            .toList(),
      );

  /// Adds a comment (v0.8: text, photo or GIF; [replyTo] = reply).
  Future<void> addComment(
    Post post,
    String text, {
    Comment? replyTo,
    CommentPicture? picture,
    Post? linked,
  }) async {
    final t = text.trim();
    if (t.isEmpty && picture == null && linked == null) return;
    final me = await UserRepository.instance.meCached();
    final ref = _posts.doc(post.id);
    final batch = _db.batch();
    // replies always hang under the first comment (one level, like IG)
    final parentId = replyTo == null
        ? ''
        : (replyTo.isReply ? replyTo.parentId : replyTo.id);
    batch.set(ref.collection('comments').doc(), {
      'authorId': me.uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'text': t,
      'createdAt': FieldValue.serverTimestamp(),
      if (parentId.isNotEmpty) 'parentId': parentId,
      if (replyTo != null) 'replyToUsername': replyTo.authorUsername,
      ...?picture?.toMap(),
      if (linked != null) ...linkedFields(linked),
    });
    batch.update(ref, {'commentsCount': FieldValue.increment(1)});
    if (parentId.isNotEmpty) {
      batch.update(ref.collection('comments').doc(parentId), {
        'repliesCount': FieldValue.increment(1),
      });
    }
    final what = t.isNotEmpty
        ? t
        : picture != null
        ? (picture.isGif ? 'sent a GIF' : 'sent a photo')
        : 'answered with a ${linked!.isClip ? 'clip' : 'post'}';
    // v0.12: the person you answered gets "replied to your comment"
    // (instead of "commented" when they are also the post author)
    final replyTo0 = replyTo?.authorId ?? '';
    final pendings = <Pending>[
      if (replyTo0 != post.authorId)
        NotificationRepository.instance.addToBatch(
          batch,
          toUid: post.authorId,
          from: me,
          type: AppNotification.comment,
          post: post,
          text: what,
        ),
      if (replyTo0.isNotEmpty)
        NotificationRepository.instance.addToBatch(
          batch,
          toUid: replyTo0,
          from: me,
          type: AppNotification.reply,
          post: post,
          text: what,
        ),
    ];
    await batch.commit();
    for (final p in pendings) {
      p.send();
    }
  }

  /// Card fields of a post / clip linked in a comment (v0.9).
  static Map<String, dynamic> linkedFields(Post p) => {
    'refPostId': p.id,
    'refPostType': p.type,
    'refThumb': p.coverUrl,
    'refAuthor': p.authorUsername,
  };

  /// After a "reply with a new clip / post" is shared: adds the reply
  /// comment that links to it (v0.9). Does nothing when the post or the
  /// comment is gone.
  Future<void> addLinkedReply(ReplyRef r, String newPostId) async {
    final target = await _posts.doc(r.postId).get();
    final made = await _posts.doc(newPostId).get();
    if (!target.exists || !made.exists) return;
    final post = Post.fromDoc(target);
    final mine = Post.fromDoc(made);
    final thread = r.isComment
        ? await _posts
              .doc(r.postId)
              .collection('comments')
              .doc(r.threadId)
              .get()
        : null;
    if (thread == null || !thread.exists) {
      await addComment(post, '', linked: mine);
      return;
    }
    final replyTo = Comment(
      id: r.commentId,
      authorId: '',
      authorUsername: r.username,
      authorPhotoUrl: '',
      text: r.text,
      createdAt: DateTime.now(),
      parentId: r.parentId,
    );
    await addComment(post, '', replyTo: replyTo, linked: mine);
  }

  /// v0.11: the post owner pins one comment ('' = unpin).
  Future<void> pinComment(String postId, String commentId) =>
      _posts.doc(postId).update({'pinnedComment': commentId});

  Future<void> deleteComment(String postId, Comment c) async {
    final ref = _posts.doc(postId);
    final batch = _db.batch();
    batch.delete(ref.collection('comments').doc(c.id));
    batch.update(ref, {'commentsCount': FieldValue.increment(-1)});
    await batch.commit();
    if (c.isReply) {
      // the parent may be gone already: that's fine
      await ref
          .collection('comments')
          .doc(c.parentId)
          .update({'repliesCount': FieldValue.increment(-1)})
          .catchError((Object _) {});
    }
    if (c.imageKey.isNotEmpty) MediaService.instance.delete(c.imageKey);
  }

  /// Did I like this comment?
  Stream<bool> isCommentLiked(String postId, String commentId) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value(false);
    return _posts
        .doc(postId)
        .collection('comments')
        .doc(commentId)
        .collection('likes')
        .doc(uid)
        .snapshots()
        .map((d) => d.exists);
  }

  /// Like / unlike a comment (v0.8).
  Future<void> setCommentLiked(
    String postId,
    String commentId,
    bool like, {
    Comment? comment,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final c = _posts.doc(postId).collection('comments').doc(commentId);
    final likeRef = c.collection('likes').doc(uid);
    var added = false;
    await _db.runTransaction((tx) async {
      final had = (await tx.get(likeRef)).exists;
      added = false;
      if (had == like) return;
      added = like;
      if (like) {
        tx.set(likeRef, {'createdAt': FieldValue.serverTimestamp()});
      } else {
        tx.delete(likeRef);
      }
      tx.update(c, {'likesCount': FieldValue.increment(like ? 1 : -1)});
    });
    // v0.12: "liked your comment" (+ phone notification)
    final author = comment?.authorId ?? '';
    if (added && author.isNotEmpty && author != uid) {
      try {
        final me = await UserRepository.instance.meCached();
        await NotificationRepository.instance.addNow(
          toUid: author,
          from: me,
          type: AppNotification.commentLike,
          postId: postId,
          text: comment!.text,
        );
      } catch (e) {
        debugPrint('comment like notification: $e');
      }
    }
  }

  // ---------------- Views ----------------
  //
  // One view doc per account: posts/{pid}/views/{uid}.
  // viewsCount goes up only when that doc is created, and never for the
  // author. The doc keeps simple facts for the author's Analytics
  // (follower?, country, age range, language, where it was seen, watch time).

  final Set<String> _sessionViewed = {};
  final Map<String, int> _sentWatch = {};
  String? _ageGroup;

  /// Counts a view (once per account) + adds it to History.
  Future<void> addView(Post post, {String source = ViewSource.other}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (!_sessionViewed.add(post.id)) return; // once per app run
    AppSettings.instance.addHistory(post.id, isClip: post.isClip);
    if (post.authorId == uid) return; // your own views don't count
    final ref = _posts.doc(post.id).collection('views').doc(uid);
    try {
      var known = AppSettings.instance.hasViewed(post.id);
      if (!known) known = (await ref.get()).exists;
      if (known) {
        AppSettings.instance.markViewed(post.id);
        await ref.update({
          'count': FieldValue.increment(1),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return;
      }
      final batch = _db.batch();
      batch.set(ref, {
        ...await _viewerInfo(post.authorId),
        'source': ViewSource.normalize(source),
        'count': 1,
        'watchMs': 0,
        'completed': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      batch.update(_posts.doc(post.id), {
        'uniqueViews': FieldValue.increment(1),
      });
      await batch.commit();
      AppSettings.instance.markViewed(post.id);
      unawaited(_checkMilestone(post.id));
    } catch (e) {
      debugPrint('addView failed: $e');
    }
  }

  /// v0.12: after a new view, if the post passed 100 / 500 / 1K ... views,
  /// our server tells the author ("Your clip reached 1,000 views").
  Future<void> _checkMilestone(String postId) async {
    try {
      final d = (await _posts.doc(postId).get()).data() ?? const {};
      final views = (d['uniqueViews'] as num?)?.toInt() ?? 0;
      final done = (d['viewsMilestone'] as num?)?.toInt() ?? 0;
      if (!ViewMilestones.needsCheck(views, done)) return;
      await ApiClient.instance.post('/api/view-milestone', {'postId': postId});
    } catch (e) {
      debugPrint('view milestone: $e');
    }
  }

  /// Saves how long a video was watched (only goes up).
  Future<void> reportWatch(
    Post post, {
    required int watchMs,
    required bool completed,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || post.authorId == uid || watchMs <= 0) return;
    final ms = watchMs.clamp(0, 6 * 60 * 60 * 1000);
    final prev = _sentWatch[post.id] ?? 0;
    if (ms <= prev && !completed) return;
    _sentWatch[post.id] = ms > prev ? ms : prev;
    try {
      await _posts.doc(post.id).collection('views').doc(uid).update({
        'watchMs': ms > prev ? ms : prev,
        if (completed) 'completed': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // no view doc yet (offline) -> skip
    }
  }

  Future<Map<String, dynamic>> _viewerInfo(String authorId) async {
    var country = '', language = '';
    try {
      final me = await UserRepository.instance.meCached();
      country = me.country;
      language = me.language;
    } catch (_) {}
    if (_ageGroup == null) {
      try {
        final d = DateTime.tryParse(await UserRepository.instance.birthDate());
        _ageGroup = d == null ? '' : ageGroupOf(ageOn(d, DateTime.now()));
      } catch (_) {
        _ageGroup = '';
      }
    }
    return {
      'follower': _filter.isFollowing(authorId),
      if (country.isNotEmpty) 'country': country,
      if (language.isNotEmpty) 'language': language,
      if (_ageGroup!.isNotEmpty) 'ageGroup': _ageGroup,
    };
  }

  /// Author only: every view doc of one post (for Analytics).
  Future<List<Map<String, dynamic>>> viewDocs(String postId) async {
    final s = await _posts.doc(postId).collection('views').limit(5000).get();
    // '_id' = viewer uid (only used to count different people)
    return s.docs.map((d) => {...d.data(), '_id': d.id}).toList();
  }

  // ---------------- Shares ----------------

  /// +1 share (anyone can add one).
  Future<void> addShare(Post post) async {
    try {
      await _posts.doc(post.id).update({
        'sharesCount': FieldValue.increment(1),
      });
    } catch (_) {}
  }
}

/// Options picked on the share screen.
class PostOptions {
  const PostOptions({
    this.audience = Audience.everyone,
    this.alsoMoment = false,
    this.hideLikes = false,
    this.hideComments = false,
    this.hideReposts = false,
    this.hideShares = false,
    this.profileOnly = false,
    this.highlightId = '',
    this.highlightTitle = '',
  });

  final String audience;

  /// v0.16: post / clip only on your profile grid (not in feeds).
  final bool profileOnly;

  /// v0.16: moments straight into a highlight (no moment for 24 hours).
  /// [highlightId] is new or yours; [highlightTitle] names a new one.
  final String highlightId;
  final String highlightTitle;
  bool get highlightOnly => highlightId.isNotEmpty;
  final bool alsoMoment;
  final bool hideLikes;
  final bool hideComments;
  final bool hideReposts;
  final bool hideShares;
}

/// One edited photo ready to upload.
/// One photo or video to upload.
class PostUpload {
  const PostUpload({
    required this.file,
    required this.isVideo,
    required this.aspectRatio,
    this.edits = const VideoEdits(),
    this.durationMs = 0,
    this.thumb,
  });

  final File file;
  final bool isVideo;
  final double aspectRatio;
  final VideoEdits edits;
  final int durationMs;

  /// Video cover frame (already filtered).
  final File? thumb;
}

/// Where a view came from (for Analytics).
class ViewSource {
  ViewSource._();
  static const String feed = 'feed';
  static const String clips = 'clips';
  static const String profile = 'profile';
  static const String explore = 'explore';
  static const String other = 'other';

  static const List<String> all = [feed, clips, profile, explore, other];

  static String normalize(String s) => all.contains(s) ? s : other;

  static String label(String s) => switch (s) {
    feed => 'Discover',
    clips => 'Clips',
    profile => 'Profile',
    explore => 'Explore and search',
    _ => 'Other (shares, notifications)',
  };
}

/// Age -> age range used in Analytics.
String ageGroupOf(int age) {
  if (age < 13) return '';
  if (age < 18) return '13-17';
  if (age < 25) return '18-24';
  if (age < 35) return '25-34';
  if (age < 45) return '35-44';
  if (age < 55) return '45-54';
  return '55+';
}

const List<String> kAgeGroups = [
  '13-17',
  '18-24',
  '25-34',
  '35-44',
  '45-54',
  '55+',
];

/// Joins post lists: no duplicates, pinned order ignored, newest first.
List<Post> mergeNewest(List<List<Post>> lists, {int max = 150}) {
  final byId = <String, Post>{};
  for (final l in lists) {
    for (final p in l) {
      byId[p.id] = p;
    }
  }
  final out = byId.values.toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return out.length > max ? out.sublist(0, max) : out;
}

/// Photo or GIF sent with a comment (v0.8).
class CommentPicture {
  const CommentPicture.image({
    required this.url,
    required this.key,
    this.width = 0,
    this.height = 0,
  }) : isGif = false;

  const CommentPicture.gif({required this.url, this.width = 0, this.height = 0})
    : key = '',
      isGif = true;

  final String url;
  final String key;
  final int width;
  final int height;
  final bool isGif;

  Map<String, dynamic> toMap() => isGif
      ? {'gifUrl': url, 'gifW': width, 'gifH': height}
      : {'imageUrl': url, 'imageKey': key, 'imageW': width, 'imageH': height};
}
