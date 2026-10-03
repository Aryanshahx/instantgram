import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/ui.dart';
import '../services/user_service.dart';

class FollowButton extends StatefulWidget {
  const FollowButton({
    super.key,
    required this.uid,
    this.onChanged,
    this.compact = false,
  });

  final String uid;
  final VoidCallback? onChanged;
  final bool compact;

  @override
  State<FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends State<FollowButton> {
  bool? _following;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await UserService.instance.isFollowing(widget.uid);
      if (mounted) setState(() => _following = v);
    } catch (_) {
      if (mounted) setState(() => _following = false);
    }
  }

  Future<void> _toggle() async {
    if (_busy || _following == null) return;
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
    return FilledButton(
      style: FilledButton.styleFrom(minimumSize: size),
      onPressed: _following == null ? null : _toggle,
      child: const Text('Follow'),
    );
  }
}
