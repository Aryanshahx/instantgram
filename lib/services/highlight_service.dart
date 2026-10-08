import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/highlight.dart';
import '../models/story.dart';
import 'media_server.dart';

/// Highlights on profiles. Only the owner writes; everyone signed in reads.
/// Tests replace [backend] and [deleteFiles].
class HighlightService {
  HighlightService._();
  static final HighlightService instance = HighlightService._();

  HighlightBackend? backend;
  HighlightBackend get _b => backend ??= _FirestoreHighlights();

  /// Removes stored files (tests record them instead).
  Future<void> Function(List<String> refs)? deleteFiles;

  Future<void> _deleteFiles(List<String> refs) async {
    if (refs.isEmpty) return;
    final f = deleteFiles;
    if (f != null) return f(refs);
    try {
      await MediaServer.instance.deleteRefs(refs);
    } catch (_) {
      // a left-over file is not worth an error
    }
  }

  List<Highlight>? _mine;

  /// Oldest first (new ones are added on the right, like on a shelf).
  Future<List<Highlight>> of(String uid) async {
    final l = await _b.load(uid);
    l.sort(
      (a, b) => (a.at ?? DateTime(2100)).compareTo(b.at ?? DateTime(2100)),
    );
    return l;
  }

  Future<List<Highlight>> mine({bool fresh = false}) async {
    final c = _mine;
    if (c != null && !fresh) return c;
    return _mine = await of(_b.me);
  }

  void _put(Highlight h) {
    final c = _mine;
    if (c == null) return;
    final i = c.indexWhere((x) => x.id == h.id);
    _mine = i < 0 ? [...c, h] : ([...c]..[i] = h);
  }

  /// A new highlight (may start empty: moments can be shared to it later).
  Future<Highlight> create(
    String title, {
    List<HighlightItem> items = const [],
  }) async {
    final all = await mine();
    if (all.length >= Highlight.maxHighlights) {
      throw StateError(
        'You can have up to ${Highlight.maxHighlights} highlights.',
      );
    }
    final h = await _b.create(
      Highlight(id: '', title: Highlight.cleanTitle(title), items: items),
    );
    _put(h);
    return h;
  }

  /// Puts a moment into a highlight (once; the newest last).
  Future<Highlight> addStory(Highlight h, Story s) async {
    if (h.items.any((i) => i.storyId == s.id && s.id.isNotEmpty)) return h;
    return add(h, HighlightItem.fromStory(s, id: _b.newId()));
  }

  Future<Highlight> add(Highlight h, HighlightItem item) async {
    if (h.items.length >= Highlight.maxItems) {
      throw StateError(
        'A highlight can hold up to ${Highlight.maxItems} moments.',
      );
    }
    final next = h.copyWith(items: [...h.items, item]);
    await _b.save(next);
    _put(next);
    return next;
  }

  /// Takes one moment out. Files that only the highlight used go too.
  Future<Highlight> remove(Highlight h, String itemId) async {
    final item = h.items.where((i) => i.id == itemId).firstOrNull;
    if (item == null) return h;
    final next = h.copyWith(
      items: [
        for (final i in h.items)
          if (i.id != itemId) i,
      ],
      coverRef: h.coverRef.isNotEmpty && item.refs.contains(h.coverRef)
          ? ''
          : null,
    );
    await _b.save(next);
    _put(next);
    if (item.own) await _deleteFiles(await _unused(item.refs));
    return next;
  }

  Future<Highlight> rename(Highlight h, String title) async {
    final next = h.copyWith(title: Highlight.cleanTitle(title));
    await _b.save(next);
    _put(next);
    return next;
  }

  Future<void> delete(Highlight h) async {
    await _b.delete(h.id);
    _mine = _mine?.where((x) => x.id != h.id).toList();
    final own = {
      for (final i in h.items)
        if (i.own) ...i.refs,
    };
    await _deleteFiles(await _unused(own));
  }

  /// Of [refs], the ones no other highlight of mine still uses.
  Future<List<String>> _unused(Set<String> refs) async {
    final used = await refsInUse();
    return [
      for (final r in refs)
        if (!used.contains(r)) r,
    ];
  }

  /// Every file my highlights use (a deleted moment keeps these).
  Future<Set<String>> refsInUse() async {
    final all = await mine(fresh: true);
    return {for (final h in all) ...h.refs};
  }

  void forget() => _mine = null;
}

abstract class HighlightBackend {
  String get me;
  String newId();
  Future<List<Highlight>> load(String uid);
  Future<Highlight> create(Highlight h);
  Future<void> save(Highlight h);
  Future<void> delete(String id);
}

class _FirestoreHighlights implements HighlightBackend {
  @override
  String get me => FirebaseAuth.instance.currentUser!.uid;

  CollectionReference<Map<String, dynamic>> _col(String uid) =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('highlights');

  @override
  String newId() => _col(me).doc().id;

  @override
  Future<List<Highlight>> load(String uid) async {
    final snap = await _col(uid).limit(Highlight.maxHighlights).get();
    return [for (final d in snap.docs) Highlight.fromMap(d.id, d.data())];
  }

  @override
  Future<Highlight> create(Highlight h) async {
    final ref = _col(me).doc();
    await ref.set({...h.toMap(), 'at': FieldValue.serverTimestamp()});
    return Highlight(
      id: ref.id,
      title: h.title,
      items: h.items,
      at: DateTime.now(),
    );
  }

  @override
  Future<void> save(Highlight h) => _col(me).doc(h.id).update(h.toMap());

  @override
  Future<void> delete(String id) => _col(me).doc(id).delete();
}

/// In-memory highlights for tests.
class MemoryHighlights implements HighlightBackend {
  MemoryHighlights({this.me = 'me', Map<String, List<Highlight>>? start})
    : data = start ?? {};
  @override
  final String me;
  final Map<String, List<Highlight>> data;
  int _n = 0;

  @override
  String newId() => 'x${++_n}';

  @override
  Future<List<Highlight>> load(String uid) async => [...?data[uid]];

  @override
  Future<Highlight> create(Highlight h) async {
    final made = Highlight(
      id: 'h${++_n}',
      title: h.title,
      items: h.items,
      at: DateTime(2026, 1, 1).add(Duration(minutes: _n)),
    );
    (data[me] ??= []).add(made);
    return made;
  }

  @override
  Future<void> save(Highlight h) async {
    final l = data[me] ?? [];
    final i = l.indexWhere((x) => x.id == h.id);
    if (i >= 0) {
      l[i] = Highlight(
        id: h.id,
        title: h.title,
        items: h.items,
        coverRef: h.coverRef,
        at: l[i].at,
      );
    }
  }

  @override
  Future<void> delete(String id) async =>
      data[me]?.removeWhere((x) => x.id == id);
}
