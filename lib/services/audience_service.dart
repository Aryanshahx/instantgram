import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/audience.dart';

/// My audience lists. Tests replace [backend].
class AudienceService {
  AudienceService._();
  static final AudienceService instance = AudienceService._();

  AudienceBackend? backend;

  AudienceBackend get _b => backend ??= _FirestoreAudiences();

  List<AudienceList>? _cache;

  Future<List<AudienceList>> lists({bool fresh = false}) async {
    final c = _cache;
    if (c != null && !fresh) return c;
    final l = await _b.load();
    l.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return _cache = l;
  }

  /// Creates (empty [list.id]) or updates a list; returns it with its id.
  Future<AudienceList> save(AudienceList list) async {
    final saved = await _b.save(list);
    final c = _cache;
    // not loaded yet: the next lists() reads everything
    if (c == null) return saved;
    final l = [...c]..removeWhere((x) => x.id == saved.id);
    l.add(saved);
    l.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _cache = l;
    return saved;
  }

  Future<void> delete(String id) async {
    await _b.delete(id);
    final c = _cache;
    if (c != null) _cache = [...c]..removeWhere((x) => x.id == id);
  }

  void forget() => _cache = null;
}

abstract class AudienceBackend {
  Future<List<AudienceList>> load();
  Future<AudienceList> save(AudienceList list);
  Future<void> delete(String id);
}

class _FirestoreAudiences implements AudienceBackend {
  CollectionReference<Map<String, dynamic>> get _col => FirebaseFirestore
      .instance
      .collection('users')
      .doc(FirebaseAuth.instance.currentUser!.uid)
      .collection('audiences');

  @override
  Future<List<AudienceList>> load() async {
    final snap = await _col.limit(AudienceList.maxLists).get();
    return [for (final d in snap.docs) AudienceList.fromMap(d.id, d.data())];
  }

  @override
  Future<AudienceList> save(AudienceList list) async {
    final ref = list.id.isEmpty ? _col.doc() : _col.doc(list.id);
    await ref.set(list.toMap());
    return AudienceList(
      id: ref.id,
      name: AudienceList.cleanName(list.name),
      members: list.members.take(AudienceList.maxMembers).toList(),
    );
  }

  @override
  Future<void> delete(String id) => _col.doc(id).delete();
}

/// Simple in-memory lists for tests.
class MemoryAudiences implements AudienceBackend {
  MemoryAudiences([List<AudienceList>? start]) : all = [...?start];
  final List<AudienceList> all;
  int _n = 0;

  @override
  Future<List<AudienceList>> load() async => [...all];

  @override
  Future<AudienceList> save(AudienceList list) async {
    final id = list.id.isEmpty ? 'l${++_n}' : list.id;
    final saved = AudienceList(
      id: id,
      name: AudienceList.cleanName(list.name),
      members: list.members,
    );
    all
      ..removeWhere((x) => x.id == id)
      ..add(saved);
    return saved;
  }

  @override
  Future<void> delete(String id) async => all.removeWhere((x) => x.id == id);
}
