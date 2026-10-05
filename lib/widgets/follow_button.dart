import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/ui.dart';
import '../services/safety_service.dart';
import '../services/user_service.dart';

class FollowButton extends StatefulWidget {
  const FollowButton({
    super.key,
    required this.uid,
    this.onChanged,
    this.compact = false,
    this.isPrivate,
  });

  final String uid;
  final VoidCallback? onChanged;
  final bool compact;

  /// Known when the person's profile is already loaded (saves a read); null = look it up.
  final bool? isPrivate;

  @override
  State<FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends State<FollowButton> {
  bool? _following;
  bool _busy = false;
  bool _requested = false;
  bool _private = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await UserService.instance.isFollowing(widget.uid);
      var priv = widget.isPrivate ?? false;
      var asked = false;
      if (!v) {
        if (widget.isPrivate == null) {
          priv = (await UserService.instance.getUser(widget.uid))?.isPrivate ??
              false;
        }
        if (priv) asked = await SafetyService.instance.hasRequested(widget.uid);
      }
      if (mounted) {
        setState(() {
          _following = v;
          _private = priv;
          _requested = asked;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _following = false);
    }
  }

  Future<void> _toggle() async {
    if (_busy || _following == null) return;
    if (_private && !_following!) {
      // a private account: ask (or take the request back)
      setState(() => _busy = true);
      try {
        if (_requested) {
          await SafetyService.instance.cancelRequest(widget.uid);
        } else {
          await SafetyService.instance.requestFollow(widget.uid);
        }
        if (mounted) setState(() => _requested = !_requested);
      } catch (e) {
        if (mounted) showToast(context, friendlyError(e));
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    final target = !_following!;
    setState(() {
      _busy = true;
      _following = target;
    });
    try {
      if (target) {
        await UserService.instance.follow(widget.uid);
      } else {
        await UserService.instance.unfollow(widget.uid);
      }
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) {
        setState(() => _following = !target);
        showToast(context, friendlyError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.uid == UserService.instance.myUid) {
      return const SizedBox.shrink();
    }
    final following = _following ?? false;
    final size = widget.compact
        ? const Size(96, 34)
        : const Size.fromHeight(40);

    if (following) {
      return OutlinedButton(
        style: OutlinedButton.styleFrom(minimumSize: size),
        onPressed: _toggle,
        child: const Text('Following'),
      );
    }
    if (_private && _requested) {
      return OutlinedButton(
        key: const ValueKey('requestedButton'),
        style: OutlinedButton.styleFrom(minimumSize: size),
        onPressed: _busy ? null : _toggle,
        child: const Text('Requested'),
      );
    }
    return FilledButton(
      style: FilledButton.styleFrom(minimumSize: size),
      onPressed: _following == null ? null : _toggle,
      child: Text(_private ? 'Request' : 'Follow'),
    );
  }
}
