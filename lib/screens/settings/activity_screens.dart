import 'package:flutter/material.dart';

import '../../core/l10n.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/post.dart';
import '../../services/app_prefs.dart';
import '../../services/post_service.dart';
import '../../services/usage_tracker.dart';
import '../../widgets/post_grid.dart';
import '../../widgets/state_views.dart';
import 'settings_widgets.dart';

/// Settings > History: the posts and clips this phone watched, newest first.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Post>? _posts;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ids = [for (final e in AppPrefs.instance.history) e.postId];
      final posts = ids.isEmpty
          ? <Post>[]
          : await PostService.instance.postsByIds(ids.take(60).toList());
      if (mounted) {
        setState(() {
          _posts = posts;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _clear() async {
    final ok = await confirm(
      context,
      title: 'Clear history?',
      message: 'This only removes the list on this phone.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!ok) return;
    AppPrefs.instance.clearHistory();
    if (mounted) setState(() => _posts = []);
  }

  @override
  Widget build(BuildContext context) {
    final posts = _posts;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('History')),
        actions: [
          if (posts != null && posts.isNotEmpty)
            TextButton(
              key: const ValueKey('clearHistory'),
              onPressed: _clear,
              child: Text(context.tr('Clear history')),
            ),
        ],
      ),
      body: _error != null
          ? ErrorState(error: _error!, onRetry: _load)
          : posts == null
          ? const CenteredLoader()
          : posts.isEmpty
          ? EmptyState(
              icon: Icons.history_rounded,
              title: context.tr('Nothing here yet.'),
              subtitle: 'Posts and clips you open or watch show up here.',
            )
          : ContentWidth(
              maxWidth: 860,
              child: CustomScrollView(
                slivers: [
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                  PostGridSliver(posts: posts),
                  const SliverToBoxAdapter(child: SizedBox(height: 30)),
                ],
              ),
            ),
    );
  }
}

/// "1 h 05 min" / "12 min" / "40 s"
String formatUsage(int seconds) {
  if (seconds < 60) return '$seconds s';
  final m = seconds ~/ 60;
  if (m < 60) return '$m min';
  return '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min';
}

/// Settings > Manage time: today, the last 7 days and a daily limit.
class ManageTimeScreen extends StatefulWidget {
  const ManageTimeScreen({super.key});

  @override
  State<ManageTimeScreen> createState() => _ManageTimeScreenState();
}

class _ManageTimeScreenState extends State<ManageTimeScreen> {
  static const _limits = [0, 15, 30, 45, 60, 90, 120];

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = UsageTracker.instance.todaySeconds();
    final days = [
      for (var i = 6; i >= 0; i--) now.subtract(Duration(days: i)),
    ];
    final secs = [for (final d in days) AppPrefs.instance.usageSeconds(d)];
    final top = secs.fold<int>(60, (a, b) => b > a ? b : a);
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final limit = AppPrefs.instance.dailyLimitMinutes;
    return SettingsPage(
      title: context.tr('Manage time'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr('Today'),
                style: TextStyle(color: context.muted),
              ),
              Text(
                formatUsage(today),
                key: const ValueKey('usageToday'),
                style: const TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.2,
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 130,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < days.length; i++)
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              height: 6 + 84 * (secs[i] / top),
                              decoration: BoxDecoration(
                                color: i == days.length - 1
                                    ? AppTheme.volt
                                    : context.cardHigh,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              names[days[i].weekday - 1],
                              style: TextStyle(
                                color: context.muted,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SettingsHeading(context.tr('Daily limit')),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in _limits)
                ChoiceChip(
                  key: ValueKey('limit$m'),
                  label: Text(m == 0 ? context.tr('Off') : '$m min'),
                  selected: limit == m,
                  showCheckmark: false,
                  selectedColor: AppTheme.volt,
                  labelStyle: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: limit == m ? AppTheme.ink : null,
                  ),
                  onSelected: (_) {
                    AppPrefs.instance.dailyLimitMinutes = m;
                    // a new limit can be reminded about again today
                    AppPrefs.instance.limitShownDay = '';
                    setState(() {});
                  },
                ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Text(
            'You get a reminder once a day when the time in the app passes the limit. Only time with the app open is counted, on this phone.',
            style: TextStyle(fontSize: 13, height: 1.4),
          ),
        ),
      ],
    );
  }
}
