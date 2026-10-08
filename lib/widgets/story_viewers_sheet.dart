import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/ui.dart';
import '../models/story_view.dart';
import '../services/story_views.dart';
import 'avatar.dart';
import 'like_button.dart' show kSuperHeartColor;

/// Opens the list of people who watched my moment [storyId].
Future<void> showStoryViewers(
  BuildContext context,
  String storyId, {
  String collection = 'stories',
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Theme.of(context).colorScheme.surface,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
  ),
  builder: (_) => FractionallySizedBox(
    heightFactor: 0.75,
    child: StoryViewersSheet(storyId: storyId, collection: collection),
  ),
);

/// Who watched, when (first and last time), how often (rewatches), a search box, and a bell
/// per person: "tell me when they watch my moments".
class StoryViewersSheet extends StatefulWidget {
  const StoryViewersSheet({
    super.key,
    required this.storyId,
    this.collection = 'stories',
    this.now,
  });

  final String storyId;
  final String collection;

  /// Tests: a fixed "now" for the time labels.
  final DateTime? now;

  @override
  State<StoryViewersSheet> createState() => _StoryViewersSheetState();
}

class _StoryViewersSheetState extends State<StoryViewersSheet> {
  final _search = TextEditingController();
  List<StoryView>? _all;
  Set<String> _alerts = {};
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait<Object>([
        StoryViews.instance.viewers(
          widget.storyId,
          collection: widget.collection,
        ),
        StoryViews.instance.alerts(),
      ]);
      if (!mounted) return;
      setState(() {
        _all = r[0] as List<StoryView>;
        _alerts = {...r[1] as List<String>};
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _toggleAlert(StoryView v) async {
    final on = !_alerts.contains(v.uid);
    setState(() => on ? _alerts.add(v.uid) : _alerts.remove(v.uid));
    try {
      await StoryViews.instance.setAlert(v.uid, on);
      if (mounted) {
        showToast(
          context,
          on
              ? 'You will be told when ${v.username} views your moments.'
              : 'No more alerts for ${v.username}.',
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => on ? _alerts.remove(v.uid) : _alerts.add(v.uid));
      showToast(context, 'Could not save. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final now = widget.now ?? DateTime.now();
    final shown = all == null ? null : StoryView.filter(all, _search.text);
    final rewatched = all?.where((v) => v.rewatched).length ?? 0;
    return Column(
      children: [
        const SizedBox(height: 10),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: context.muted.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Row(
            children: [
              const Icon(Icons.visibility_outlined, size: 22),
              const SizedBox(width: 8),
              Text(
                all == null
                    ? 'Viewers'
                    : '${all.length} ${all.length == 1 ? 'viewer' : 'viewers'}',
                key: const ValueKey('viewerCount'),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
              const Spacer(),
              if (rewatched > 0)
                Text(
                  '$rewatched rewatched',
                  style: TextStyle(color: context.muted, fontSize: 13),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            key: const ValueKey('viewerSearch'),
            controller: _search,
            decoration: InputDecoration(
              hintText: 'Search viewers',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        Expanded(
          child: _error != null
              ? const Center(child: Text('Could not load the viewers.'))
              : shown == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : shown.isEmpty
              ? Center(
                  child: Text(
                    all!.isEmpty ? 'No views yet.' : 'Nobody with that name.',
                    style: TextStyle(color: context.muted),
                  ),
                )
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) => _row(shown[i], now),
                ),
        ),
      ],
    );
  }

  Widget _row(StoryView v, DateTime now) {
    final when = v.rewatched
        ? 'First ${viewTimeLabel(v.first, now)} · last ${viewTimeLabel(v.last, now)}'
        : viewTimeLabel(v.last, now);
    final alert = _alerts.contains(v.uid);
    return ListTile(
      key: ValueKey('viewer_${v.uid}'),
      leading: UserAvatar(url: v.photoUrl, name: v.username, radius: 20),
      title: Text(
        v.username,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(when, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (v.liked)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(
                Icons.favorite_rounded,
                key: ValueKey('viewerLike_${v.uid}'),
                size: 20,
                color: v.superHeart
                    ? kSuperHeartColor
                    : const Color(0xFFFF3B5C),
              ),
            ),
          if (v.rewatched)
            Container(
              key: ValueKey('rewatch_${v.uid}'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.volt,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${v.count}×',
                style: const TextStyle(
                  color: AppTheme.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ),
          IconButton(
            key: ValueKey('viewerAlert_${v.uid}'),
            tooltip: alert ? 'Alerts on' : 'Tell me when they view',
            onPressed: () => _toggleAlert(v),
            icon: Icon(
              alert
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_none_rounded,
              color: alert ? AppTheme.volt : null,
            ),
          ),
        ],
      ),
    );
  }
}
