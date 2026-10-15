import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/errors.dart';
import '../../features/profile/data/user_repository.dart';

/// v0.12: small "Follow" button next to a username (clips).
/// Hidden on your own clips and when you already follow the person.
/// Private accounts: sends a follow request and shows "Requested".
class FollowChip extends StatefulWidget {
  const FollowChip({
    super.key,
    required this.targetUid,
    this.myUid,
    this.following,
    this.requested,
    this.onFollow,
    this.onUnfollow,
  });

  final String targetUid;

  /// Tests: who is logged in (default: the Firebase user).
  final String? myUid;
  final Stream<bool>? following;
  final Stream<bool>? requested;
  final Future<void> Function()? onFollow;
  final Future<void> Function()? onUnfollow;

  @override
  State<FollowChip> createState() => _FollowChipState();
}

class _FollowChipState extends State<FollowChip> {
  StreamSubscription<bool>? _fSub;
  StreamSubscription<bool>? _rSub;
  bool? _following;
  bool _requested = false;
  bool _busy = false;

  /// Tapped "Follow": hide right away (the server answer comes later).
  bool _done = false;
  String? _me;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant FollowChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetUid != widget.targetUid) {
      _cancel();
      _following = null;
      _requested = false;
      _done = false;
      _listen();
    }
  }

  void _listen() {
    _me = widget.myUid;
    if (_me == null) {
      try {
        _me = UserRepository.instance.myUid;
      } catch (_) {
        _me = null; // not logged in
      }
    }
    if (_me == null || _me == widget.targetUid || widget.targetUid.isEmpty) {
      return;
    }
    final f =
        widget.following ??
        UserRepository.instance.isFollowing(widget.targetUid);
    final r =
        widget.requested ??
        UserRepository.instance.hasRequested(widget.targetUid);
    _fSub = f.listen((v) {
      if (mounted) setState(() => _following = v);
    }, onError: (Object _) {});
    _rSub = r.listen((v) {
      if (mounted) setState(() => _requested = v);
    }, onError: (Object _) {});
  }

  void _cancel() {
    unawaited(_fSub?.cancel());
    unawaited(_rSub?.cancel());
    _fSub = null;
    _rSub = null;
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  Future<void> _follow() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _done = true;
    });
    try {
      final custom = widget.onFollow;
      if (custom != null) {
        await custom();
      } else {
        final user = await UserRepository.instance.getUser(widget.targetUid);
        if (user != null) await UserRepository.instance.follow(user);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _done = false);
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// v0.14: tap "Following" = unfollow right away (no pop-up at the bottom).
  Future<void> _unfollow() async {
    if (_busy) return;
    HapticFeedback.selectionClick();
    setState(() {
      _busy = true;
      _done = false;
      _following = false;
    });
    try {
      final custom = widget.onUnfollow;
      if (custom != null) {
        await custom();
      } else {
        final user = await UserRepository.instance.getUser(widget.targetUid);
        if (user != null) await UserRepository.instance.unfollow(user);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _following = true);
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // v0.13: people you follow show "Following" (was hidden)
    final hidden = _me == null || _me == widget.targetUid || _following == null;
    Widget child;
    if (hidden) {
      child = const SizedBox.shrink(key: ValueKey('follow-hidden'));
    } else if (_requested && _following != true) {
      child = _pill('Requested', key: const ValueKey('follow-requested'));
    } else if (_following == true || _done) {
      child = GestureDetector(
        key: const ValueKey('follow-following'),
        behavior: HitTestBehavior.opaque,
        onTap: _unfollow,
        child: _pill('Following', dim: true),
      );
    } else {
      child = GestureDetector(
        key: const ValueKey('follow-chip'),
        behavior: HitTestBehavior.opaque,
        onTap: _follow,
        child: _pill('Follow'),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: SizeTransition(sizeFactor: a, axis: Axis.horizontal, child: c),
      ),
      child: child,
    );
  }

  Widget _pill(String text, {Key? key, bool dim = false}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(left: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: dim ? Colors.white54 : Colors.white,
            width: 1.1,
          ),
          color: Colors.black26,
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
