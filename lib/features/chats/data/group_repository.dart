import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/media_service.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../profile/data/user_repository.dart';
import 'channel_seen.dart';
import 'chat_repository.dart';

/// v0.0.2: groups (like WhatsApp groups, up to [maxGroup] people) and
/// channels (admins post, anyone can follow).
///
/// groups/{g_...} and channels/{ch_...}:
///   name, nameLower, description, photoUrl, photoKey, createdBy,
///   admins [uids], members [uids], memberInfo {uid: {username, photoUrl}},
///   lastMessage, lastSenderId, lastSenderName, createdAt, updatedAt,
///   seen / delivered / typing {uid: time} (groups only), pinned.
/// Messages: the same as chats ({id}/messages/{mid}).
class GroupRepository {
  GroupRepository._();
  static final GroupRepository instance = GroupRepository._();

  static const int maxGroup = 256;
  static const int maxChannel = 10000;
  static const int maxName = 60;
  static const int maxAbout = 300;
  static const int maxAdmins = 20;

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  ChatRepository get _chats => ChatRepository.instance;

  static const String _letters =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  /// "g_" / "ch_" + 20 random letters.
  static String newId(String prefix, [Random? random]) {
    final r = random ?? Random.secure();
    return prefix +
        String.fromCharCodes(
          List.generate(
            20,
            (_) => _letters.codeUnitAt(r.nextInt(_letters.length)),
          ),
        );
  }

  /// Name as shown and saved (spaces cleaned, max [maxName]).
  static String cleanName(String s) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > maxName ? t.substring(0, maxName) : t;
  }

  static String cleanAbout(String s) {
    final t = s.trim();
    return t.length > maxAbout ? t.substring(0, maxAbout) : t;
  }

  /// "alice added bob, carol and 2 others"
  static String namesText(List<String> names) {
    final n = names.where((s) => s.isNotEmpty).toList();
    if (n.isEmpty) return 'someone';
    if (n.length == 1) return n.first;
    if (n.length == 2) return '${n[0]} and ${n[1]}';
    if (n.length == 3) return '${n[0]}, ${n[1]} and ${n[2]}';
    return '${n[0]}, ${n[1]} and ${n.length - 2} others';
  }

  static Map<String, dynamic> _info(String username, String photoUrl) => {
    'username': username,
    'photoUrl': photoUrl,
  };

  Future<UploadedMedia?> _upload(File? photo) async {
    if (photo == null) return null;
    return MediaService.instance.upload(photo, kind: MediaKind.avatar);
  }

  /// Adds "alice added bob" to [batch] (+ the list text).
  void _system(
    WriteBatch batch,
    String chatId,
    UserProfile me,
    String text, {
    Map<String, dynamic> chat = const {},
    bool create = false,
  }) {
    final ref = _chats.ref(chatId);
    final t = text.length > 200 ? text.substring(0, 200) : text;
    final fields = <String, dynamic>{
      'lastMessage': t,
      'lastSenderId': me.uid,
      'lastSenderName': '',
      'updatedAt': FieldValue.serverTimestamp(),
      ...chat,
    };
    if (create) {
      batch.set(ref, fields);
    } else {
      batch.update(ref, fields);
    }
    batch.set(ref.collection('messages').doc(), {
      'kind': Message.system,
      'text': t,
      'senderId': me.uid,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // ------------------------------------------------------------- create

  /// New group with you as admin. Returns its id.
  Future<String> createGroup({
    required String name,
    required List<ChatPerson> members,
    String description = '',
    File? photo,
  }) async {
    final n = cleanName(name);
    if (n.isEmpty) throw const GroupProblem('Give the group a name.');
    final me = await UserRepository.instance.me();
    final people = {
      for (final p in members)
        if (p.uid != me.uid && !p.isGroup) p.uid: p,
    }.values.take(maxGroup - 1).toList();
    if (people.isEmpty) throw const GroupProblem('Add at least one person.');
    final up = await _upload(photo);
    final id = newId('g_');
    final batch = _db.batch();
    _system(
      batch,
      id,
      me,
      '${me.username} created the group "$n"',
      create: true,
      chat: {
        'name': n,
        'nameLower': n.toLowerCase(),
        'description': cleanAbout(description),
        'photoUrl': up?.url ?? '',
        'photoKey': up?.key ?? '',
        'createdBy': me.uid,
        'admins': [me.uid],
        'members': [me.uid, for (final p in people) p.uid],
        'memberInfo': {
          me.uid: _info(me.username, me.photoUrl),
          for (final p in people) p.uid: _info(p.username, p.photoUrl),
        },
        'createdAt': FieldValue.serverTimestamp(),
      },
    );
    await batch.commit();
    return id;
  }

  /// New channel with you as the only admin. Returns its id.
  Future<String> createChannel({
    required String name,
    String description = '',
    File? photo,
  }) async {
    final n = cleanName(name);
    if (n.isEmpty) throw const GroupProblem('Give the channel a name.');
    final me = await UserRepository.instance.me();
    final up = await _upload(photo);
    final id = newId('ch_');
    final batch = _db.batch();
    _system(
      batch,
      id,
      me,
      'Channel created',
      create: true,
      chat: {
        'name': n,
        'nameLower': n.toLowerCase(),
        'description': cleanAbout(description),
        'photoUrl': up?.url ?? '',
        'photoKey': up?.key ?? '',
        'createdBy': me.uid,
        'admins': [me.uid],
        'members': [me.uid],
        'memberInfo': {me.uid: _info(me.username, me.photoUrl)},
        'createdAt': FieldValue.serverTimestamp(),
      },
    );
    await batch.commit();
    await ChannelSeen.instance.mark(id);
    return id;
  }

  // ------------------------------------------------------------ members

  /// Admin adds people to a group.
  Future<void> addMembers(Chat g, List<ChatPerson> people) async {
    final me = await UserRepository.instance.me();
    final add = people
        .where((p) => !g.isMember(p.uid) && !p.isGroup && p.uid != me.uid)
        .toList();
    if (add.isEmpty) return;
    if (g.members.length + add.length > maxGroup) {
      throw const GroupProblem('A group can have up to $maxGroup people.');
    }
    final batch = _db.batch();
    _system(
      batch,
      g.id,
      me,
      '${me.username} added ${namesText([for (final p in add) p.username])}',
      chat: {
        'members': FieldValue.arrayUnion([for (final p in add) p.uid]),
        for (final p in add)
          'memberInfo.${p.uid}': _info(p.username, p.photoUrl),
      },
    );
    await batch.commit();
  }

  /// Admin removes someone from a group (or a follower from a channel).
  Future<void> removeMember(Chat g, String uid) async {
    final me = await UserRepository.instance.me();
    final fields = <String, dynamic>{
      'members': FieldValue.arrayRemove([uid]),
      'admins': FieldValue.arrayRemove([uid]),
      'memberInfo.$uid': FieldValue.delete(),
    };
    if (g.isChannel) {
      await _chats.ref(g.id).update(fields);
      return;
    }
    final batch = _db.batch();
    final who = g.usernameOf(uid);
    _system(
      batch,
      g.id,
      me,
      '${me.username} removed ${who.isEmpty ? 'someone' : who}',
      chat: fields,
    );
    await batch.commit();
  }

  /// Admin makes someone admin (or takes it back).
  Future<void> setAdmin(Chat g, String uid, bool admin) async {
    if (admin && g.admins.length >= maxAdmins) {
      throw const GroupProblem('Up to $maxAdmins admins.');
    }
    if (!admin && g.admins.length <= 1 && g.isAdmin(uid)) {
      throw const GroupProblem('There must be at least one admin.');
    }
    final fields = <String, dynamic>{
      'admins': admin
          ? FieldValue.arrayUnion([uid])
          : FieldValue.arrayRemove([uid]),
    };
    // channels: admins' names are needed for the info page
    if (admin && g.isChannel && g.usernameOf(uid).isEmpty) {
      final u = await UserRepository.instance.usersByIds([uid]);
      if (u.isNotEmpty) {
        fields['memberInfo.$uid'] = _info(u.first.username, u.first.photoUrl);
      }
    }
    await _chats.ref(g.id).update(fields);
  }

  /// Who becomes admin when the last admin leaves (oldest member first).
  static String? nextAdmin(Chat g, String leaving) {
    if (!g.isAdmin(leaving)) return null;
    if (g.admins.any((a) => a != leaving)) return null;
    for (final m in g.members) {
      if (m != leaving) return m;
    }
    return null;
  }

  /// You leave a group / unfollow a channel.
  Future<void> leave(Chat g) async {
    final me = await UserRepository.instance.me();
    if (g.isChannel) {
      if (g.isAdmin(me.uid) && g.admins.length <= 1) {
        throw const GroupProblem(
          'You are the only admin. Make someone else admin first.',
        );
      }
      await _chats.ref(g.id).update({
        'members': FieldValue.arrayRemove([me.uid]),
        if (g.isAdmin(me.uid)) 'admins': FieldValue.arrayRemove([me.uid]),
        if (g.isAdmin(me.uid)) 'memberInfo.${me.uid}': FieldValue.delete(),
      });
      return;
    }
    final next = nextAdmin(g, me.uid);
    final batch = _db.batch();
    _system(
      batch,
      g.id,
      me,
      '${me.username} left',
      chat: {
        'members': FieldValue.arrayRemove([me.uid]),
        'memberInfo.${me.uid}': FieldValue.delete(),
        'typing.${me.uid}': FieldValue.delete(),
        if (g.isAdmin(me.uid))
          'admins': next == null
              ? FieldValue.arrayRemove([me.uid])
              : [for (final a in g.admins) if (a != me.uid) a, next],
      },
    );
    await batch.commit();
  }

  /// Follow a channel.
  Future<void> join(Chat ch) async {
    if (ch.members.length >= maxChannel) {
      throw const GroupProblem('This channel is full.');
    }
    final me = _chats.myUid;
    await _chats.ref(ch.id).update({
      'members': FieldValue.arrayUnion([me]),
    });
    await ChannelSeen.instance.mark(ch.id);
  }

  // --------------------------------------------------------------- edit

  /// Admin changes name / about / photo.
  Future<void> edit(
    Chat g, {
    String? name,
    String? description,
    File? photo,
    bool removePhoto = false,
  }) async {
    final me = await UserRepository.instance.me();
    final fields = <String, dynamic>{};
    final notes = <String>[];
    if (name != null) {
      final n = cleanName(name);
      if (n.isEmpty) throw const GroupProblem('The name cannot be empty.');
      if (n != g.name) {
        fields['name'] = n;
        fields['nameLower'] = n.toLowerCase();
        notes.add('${me.username} changed the name to "$n"');
      }
    }
    if (description != null) {
      final d = cleanAbout(description);
      if (d != g.description) {
        fields['description'] = d;
        notes.add('${me.username} changed the description');
      }
    }
    String oldKey = '';
    if (photo != null || (removePhoto && g.photoUrl.isNotEmpty)) {
      final up = await _upload(photo);
      final snap = await _chats.ref(g.id).get();
      oldKey = '${snap.data()?['photoKey'] ?? ''}';
      fields['photoUrl'] = up?.url ?? '';
      fields['photoKey'] = up?.key ?? '';
      notes.add(
        photo != null
            ? '${me.username} changed the photo'
            : '${me.username} removed the photo',
      );
    }
    if (fields.isEmpty) return;
    if (g.isChannel) {
      await _chats.ref(g.id).update(fields);
    } else {
      final batch = _db.batch();
      _system(batch, g.id, me, notes.join(' · '), chat: fields);
      await batch.commit();
    }
    if (oldKey.isNotEmpty) MediaService.instance.delete(oldKey).ignore();
  }

  // ------------------------------------------------------------- search

  /// Channels whose name starts with [query] (empty = newest active).
  Future<List<Chat>> searchChannels(String query) async {
    final q = query.trim().toLowerCase();
    final col = _db.collection('channels');
    final snap = q.isEmpty
        ? await col.orderBy('updatedAt', descending: true).limit(30).get()
        : await col
              .where('nameLower', isGreaterThanOrEqualTo: q)
              .where('nameLower', isLessThan: '$q\uf8ff')
              .limit(30)
              .get();
    final list = snap.docs.map(Chat.fromDoc).toList();
    if (q.isNotEmpty) {
      list.sort((a, b) {
        final c = b.members.length.compareTo(a.members.length);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    }
    return list;
  }
}

/// A clear message for the person (shown as it is).
class GroupProblem implements Exception {
  const GroupProblem(this.message);
  final String message;
  @override
  String toString() => message;
}
