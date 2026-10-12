import 'package:flutter/material.dart';

import '../../../core/services/app_settings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/post_grid.dart';
import '../../post/data/post_repository.dart';

/// Settings → History: posts and clips you opened (kept on this phone).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  int _tab = 0; // 0 all, 1 clips, 2 posts
  String _key = '';
  Future<List<Post>>? _future;

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text('This only clears history on this phone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Clear', style: TextStyle(color: AppColors.like)),
          ),
        ],
      ),
    );
    if (ok == true) await AppSettings.instance.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    final h = AppSettings.instance.history;
    return ValueListenableBuilder<List<HistoryEntry>>(
      valueListenable: h,
      builder: (context, entries, _) {
        final list = entries
            .where((e) => _tab == 0 || (_tab == 1 ? e.isClip : !e.isClip))
            .toList();
        final ids = [for (final e in list) e.postId];
        final key = ids.join(',');
        if (key != _key || _future == null) {
          _key = key;
          _future = ids.isEmpty
              ? Future.value(const <Post>[])
              : PostRepository.instance.byIds(ids);
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('History'),
            actions: [
              if (entries.isNotEmpty)
                TextButton(onPressed: _clear, child: const Text('Clear all')),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(
                  children: [
                    for (final (i, label) in const [
                      (0, 'All'),
                      (1, 'Clips'),
                      (2, 'Posts'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(label),
                          selected: _tab == i,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          selectedColor: AppColors.lime,
                          labelStyle: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: _tab == i ? Colors.black : null,
                          ),
                          onSelected: (_) => setState(() => _tab = i),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<List<Post>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.hasError) return ErrorView(error: snap.error);
                    if (!snap.hasData) return const LoadingView();
                    final posts = snap.data!;
                    return PostGrid(
                      posts: posts,
                      onTap: (i) => openPost(context, posts, i),
                      emptyIcon: Icons.history,
                      emptyTitle: 'No history yet',
                      emptySubtitle:
                          'Clips and posts you open will show up here.',
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
