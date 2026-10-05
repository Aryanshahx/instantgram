import 'package:flutter/material.dart';

import '../core/app_events.dart';
import '../core/story_images.dart';
import '../core/theme.dart';
import '../models/app_user.dart';
import '../models/story.dart';
import '../screens/story/story_composer.dart';
import '../screens/story/story_viewer.dart';
import '../services/story_service.dart';
import '../services/user_service.dart';
import 'avatar.dart';

class StoriesBar extends StatefulWidget {
  const StoriesBar({super.key});

  @override
  State<StoriesBar> createState() => _StoriesBarState();
}

class _StoriesBarState extends State<StoriesBar> {
  /// The last result, so the bar shows at once when Discover is opened again.
  static List<StoryGroup> _lastGroups = [];
  static AppUser? _lastMe;

  List<StoryGroup> _groups = _lastGroups;
  AppUser? _me = _lastMe;
  bool _uploading = false;

  String get _myUid => UserService.instance.myUid;

  @override
  void initState() {
    super.initState();
    _load();
    AppEvents.feedRefresh.addListener(_load);
  }

  @override
  void dispose() {
    AppEvents.feedRefresh.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        StoryService.instance.load(),
        UserService.instance.getUser(_myUid),
      ]);
      if (!mounted) return;
      _lastGroups = results[0] as List<StoryGroup>;
      _lastMe = results[1] as AppUser?;
      setState(() {
        _groups = _lastGroups;
        _me = _lastMe;
      });
      // load the first picture of the first few people now, so a tap opens instantly
      for (final g in _groups.take(5)) {
        if (g.stories.isNotEmpty) {
          warmStoryImage(context, g.stories.first.coverUrl);
        }
      }
    } catch (_) {
      // Stories are optional; the feed still works without them.
    }
  }

  StoryGroup? get _myGroup {
    for (final g in _groups) {
      if (g.authorId == _myUid) return g;
    }
    return null;
  }

  Future<void> _addStory() async {
    setState(() => _uploading = true);
    try {
      final done = await startStoryFlow(context);
      if (done) await _load();
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _open(int index) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => StoryViewer(groups: _groups, initialIndex: index),
          ),
        )
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final mine = _myGroup;
    final others = _groups.where((g) => g.authorId != _myUid).toList();

    return SizedBox(
      height: 108,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          _item(
            context,
            label: 'You',
            url: _me?.photoUrl ?? '',
            ring: mine != null,
            plus: true,
            loading: _uploading,
            onTap: mine != null ? () => _open(0) : _addStory,
            onPlus: _addStory,
          ),
          for (final g in others)
            _item(
              context,
              label: g.username,
              url: g.photoUrl,
              ring: true,
              onTap: () => _open(_groups.indexOf(g)),
            ),
        ],
      ),
    );
  }

  Widget _item(
    BuildContext context, {
    required String label,
    required String url,
    required bool ring,
    required VoidCallback onTap,
    bool plus = false,
    bool loading = false,
    VoidCallback? onPlus,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: SizedBox(
        width: 70,
        child: Column(
          children: [
            GestureDetector(
              onTap: onTap,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  UserAvatar(url: url, name: label, radius: 29, ring: ring),
                  if (loading)
                    const Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.all(6),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  if (plus)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: GestureDetector(
                        onTap: onPlus,
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppTheme.volt,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              width: 2,
                            ),
                          ),
                          child: const Icon(
                            Icons.add_rounded,
                            color: AppTheme.ink,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
