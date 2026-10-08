import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/app_user.dart';
import '../services/user_service.dart';

/// Tests replace where the live profile comes from.
Stream<AppUser?> Function(String uid)? debugPresenceStream;

/// Rebuilds with someone's live profile (for "Active now"), and every [tick] so
/// "Active now" turns into "Active 4m ago" even when nothing new arrives.
class LivePresence extends StatefulWidget {
  const LivePresence({
    super.key,
    required this.uid,
    required this.builder,
    this.initial,
    this.tick = const Duration(seconds: 30),
  });

  final String uid;
  final AppUser? initial;
  final Duration tick;
  final Widget Function(BuildContext context, AppUser? user) builder;

  @override
  State<LivePresence> createState() => _LivePresenceState();
}

class _LivePresenceState extends State<LivePresence> {
  AppUser? _user;
  StreamSubscription<AppUser?>? _sub;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _user = widget.initial;
    _listen();
    _timer = Timer.periodic(widget.tick, (_) {
      if (mounted) setState(() {});
    });
  }

  void _listen() {
    _sub?.cancel();
    try {
      final s = (debugPresenceStream ?? UserService.instance.watchUser)(
        widget.uid,
      );
      _sub = s.listen((u) {
        if (u != null && mounted) setState(() => _user = u);
      }, onError: (_) {});
    } catch (_) {
      // no connection to the database (tests): the first value stays
    }
  }

  @override
  void didUpdateWidget(LivePresence old) {
    super.didUpdateWidget(old);
    if (old.uid != widget.uid) {
      _user = widget.initial;
      _listen();
    } else if (_user == null && widget.initial != null) {
      _user = widget.initial;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _user);
}
