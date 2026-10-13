import 'package:flutter/material.dart';

import '../../core/constants/countries.dart';
import '../../core/constants/languages.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/time_ago.dart';
import '../../shared/models/post.dart';
import '../../shared/widgets/post_grid.dart' show ClipCover;
import '../post/data/post_repository.dart';
import 'post_insights.dart';

/// Opens Analytics for one of your posts / clips.
Future<void> openPostInsights(BuildContext context, Post post) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => PostInsightsScreen(post: post)),
  );
}

/// Analytics for ONE post or clip: overview, engagement, audience.
class PostInsightsScreen extends StatefulWidget {
  const PostInsightsScreen({super.key, required this.post, this.loader});

  final Post post;

  /// For tests: returns the view docs.
  final Future<List<Map<String, dynamic>>> Function()? loader;

  @override
  State<PostInsightsScreen> createState() => _PostInsightsScreenState();
}

class _PostInsightsScreenState extends State<PostInsightsScreen> {
  late Post _post = widget.post;
  late Future<PostInsights> _future = _load();

  Future<PostInsights> _load() async {
    if (widget.loader == null) {
      try {
        final fresh = await PostRepository.instance.watch(_post.id).first;
        if (fresh != null) _post = fresh;
      } catch (_) {}
    }
    final docs = widget.loader != null
        ? await widget.loader!()
        : await PostRepository.instance.viewDocs(_post.id);
    return PostInsights.from(_post, docs);
  }

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f.catchError((_) => PostInsights.from(_post, const []));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_post.isClip ? 'Clip analytics' : 'Post analytics'),
      ),
      body: FutureBuilder<PostInsights>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return _Message(
              icon: Icons.cloud_off,
              text: 'Could not load analytics.\n${snap.error}',
              onRetry: _refresh,
            );
          }
          final data = snap.data;
          if (data == null) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.lime),
            );
          }
          return RefreshIndicator(
            color: AppColors.lime,
            onRefresh: _refresh,
            child: _Body(data: data),
          );
        },
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.data});
  final PostInsights data;

  @override
  Widget build(BuildContext context) {
    final d = data;
    final p = d.post!;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        // ---- header
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(width: 56, height: 70, child: ClipCover(post: p)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.caption.isEmpty
                        ? (p.isClip ? 'Clip' : 'Post')
                        : p.caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${fullDate(p.createdAt)}'
                    '${p.items.length > 1 ? ' · ${p.items.length} items' : ''}',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),

        ...insightsSections(d),
      ],
    );
  }
}

/// Overview + Engagement + Audience (used by post Analytics and the
/// Dashboard).
List<Widget> insightsSections(PostInsights d) {
  final pct = (d.engagementRate * 100);
  return [
    // ---- overview
    const _Title('Overview'),
    Row(
      children: [
        _Stat(
          'Views',
          compactCount(d.views),
          Icons.visibility_outlined,
          key: const ValueKey('ins-views'),
        ),
        const SizedBox(width: 8),
        _Stat(
          'Accounts reached',
          compactCount(d.reach),
          Icons.person_outline,
          key: const ValueKey('ins-reach'),
        ),
      ],
    ),
    const SizedBox(height: 8),
    Row(
      children: [
        _Stat(
          'Interactions',
          compactCount(d.interactions),
          Icons.touch_app_outlined,
        ),
        const SizedBox(width: 8),
        _Stat(
          'Engagement',
          d.reach == 0 ? '–' : '${pct.toStringAsFixed(pct < 10 ? 1 : 0)}%',
          Icons.trending_up,
        ),
      ],
    ),
    if (d.isAccount) ...[
      const SizedBox(height: 8),
      Row(
        children: [
          _Stat(
            'Posts counted',
            compactCount(d.postCount),
            Icons.grid_view_rounded,
          ),
          const SizedBox(width: 8),
          _Stat(
            'Per post',
            d.postCount == 0
                ? '–'
                : d.interactionsPerPost.toStringAsFixed(
                    d.interactionsPerPost < 10 ? 1 : 0,
                  ),
            Icons.insights,
          ),
        ],
      ),
    ],
    const SizedBox(height: 10),
    _Panel(
      title: d.hourly ? 'Views per hour' : 'Views per day',
      child: _Bars(d.timeline, hourly: d.hourly),
    ),

    // ---- engagement
    const SizedBox(height: 18),
    const _Title('Engagement'),
    _Panel(
      child: Column(
        children: [
          _Row(Icons.favorite_border, 'Likes', d.likes, d.interactions),
          _Row(
            Icons.mode_comment_outlined,
            'Comments',
            d.comments,
            d.interactions,
          ),
          _Row(Icons.send_outlined, 'Shares', d.shares, d.interactions),
          _Row(Icons.repeat, 'Reposts', d.reposts, d.interactions),
          _Row(Icons.bookmark_border, 'Saves', d.saves, d.interactions),
        ],
      ),
    ),
    if (d.hasVideo) ...[
      const SizedBox(height: 8),
      Row(
        children: [
          _Stat(
            'Avg. watch time',
            d.watchSamples == 0 ? '–' : _secsText(d.avgWatchMs),
            Icons.timer_outlined,
          ),
          const SizedBox(width: 8),
          _Stat(
            'Watched to the end',
            d.detailed == 0 ? '–' : '${(d.completionRate * 100).round()}%',
            Icons.check_circle_outline,
          ),
        ],
      ),
    ],

    // ---- audience
    const SizedBox(height: 18),
    const _Title('Audience'),
    if (d.detailed == 0)
      const _Panel(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text(
            'No audience data yet. It appears when other people view '
            'your posts and clips.',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      )
    else ...[
      _Panel(
        title: 'Followers vs. non-followers',
        child: _Split(
          d.followerViews,
          d.nonFollowerViews,
          'Followers',
          'Non-followers',
        ),
      ),
      const SizedBox(height: 8),
      _Panel(
        title: 'Top countries',
        child: d.countries.isEmpty
            ? const _Empty()
            : Column(
                children: [
                  for (final (code, n) in d.countries.take(6))
                    _Row(
                      null,
                      '${flagOf(code)}  '
                      '${countryName(code).isEmpty ? code : countryName(code)}',
                      n,
                      d.detailed,
                      percent: true,
                    ),
                ],
              ),
      ),
      const SizedBox(height: 8),
      _Panel(
        title: 'Age range',
        child: d.ages.isEmpty
            ? const _Empty()
            : Column(
                children: [
                  for (final (g, n) in d.ages)
                    _Row(null, g, n, d.detailed, percent: true),
                ],
              ),
      ),
      const SizedBox(height: 8),
      _Panel(
        title: 'Languages',
        child: d.languages.isEmpty
            ? const _Empty()
            : Column(
                children: [
                  for (final (code, n) in d.languages.take(5))
                    _Row(
                      null,
                      languageByCode(code)?.name ?? code,
                      n,
                      d.detailed,
                      percent: true,
                    ),
                ],
              ),
      ),
      const SizedBox(height: 8),
      _Panel(
        title: 'Where people saw it',
        child: Column(
          children: [
            for (final (s, n) in d.sources)
              _Row(null, ViewSource.label(s), n, d.detailed, percent: true),
          ],
        ),
      ),
    ],
    if (!d.isAccount && d.detailed < d.reach) ...[
      const SizedBox(height: 12),
      Text(
        'Audience details come from ${d.detailed} of ${d.reach} '
        'accounts reached.',
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
      ),
    ],
    const SizedBox(height: 12),
    const Text(
      'Only totals are shown. Your own views are not counted, and each '
      'account counts once in "Accounts reached".',
      style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
    ),
  ];
}

String _secsText(double ms) {
  final s = ms / 1000;
  if (s < 60) return '${s.toStringAsFixed(s < 10 ? 1 : 0)} s';
  final m = s ~/ 60;
  return '${m}m ${(s - m * 60).round()}s';
}

// ------------------------------------------------------------------ widgets

class _Title extends StatelessWidget {
  const _Title(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 2, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({this.title, required this.child});
  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Text(
            title!,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
        ],
        child,
      ],
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.icon, {super.key});
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.lime),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Label, bar and number.
class _Row extends StatelessWidget {
  const _Row(
    this.icon,
    this.label,
    this.value,
    this.total, {
    this.percent = false,
  });
  final IconData? icon;
  final String label;
  final int value;
  final int total;
  final bool percent;

  @override
  Widget build(BuildContext context) {
    final f = total <= 0 ? 0.0 : (value / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              Text(
                percent ? '${(f * 100).round()}%' : compactCount(value),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: f,
              minHeight: 5,
              color: AppColors.lime,
              backgroundColor: AppColors.surfaceHigh,
            ),
          ),
        ],
      ),
    );
  }
}

class _Split extends StatelessWidget {
  const _Split(this.a, this.b, this.la, this.lb);
  final int a, b;
  final String la, lb;

  @override
  Widget build(BuildContext context) {
    final t = a + b;
    final fa = t == 0 ? 0.5 : a / t;
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: Row(
              children: [
                Expanded(
                  flex: (fa * 1000).round().clamp(1, 999),
                  child: const ColoredBox(color: AppColors.lime),
                ),
                Expanded(
                  flex: ((1 - fa) * 1000).round().clamp(1, 999),
                  child: const ColoredBox(color: AppColors.mint),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _dot(AppColors.lime),
            Flexible(
              child: Text(
                ' $la ${(fa * 100).round()}%',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            const Spacer(),
            _dot(AppColors.mint),
            Flexible(
              child: Text(
                ' $lb ${((1 - fa) * 100).round()}%',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _dot(Color c) => Container(
    width: 9,
    height: 9,
    decoration: BoxDecoration(color: c, shape: BoxShape.circle),
  );
}

/// Simple bar chart.
class _Bars extends StatelessWidget {
  const _Bars(this.points, {required this.hourly});
  final List<(DateTime, int)> points;
  final bool hourly;

  @override
  Widget build(BuildContext context) {
    final max = points.fold<int>(0, (m, p) => p.$2 > m ? p.$2 : m);
    String lbl(DateTime t) => hourly
        ? '${t.hour.toString().padLeft(2, '0')}:00'
        : '${t.day}/${t.month}';
    return Column(
      children: [
        SizedBox(
          height: 90,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final p in points)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: Tooltip(
                      message: '${lbl(p.$1)} · ${p.$2}',
                      child: Container(
                        height: max == 0 ? 3 : 3 + 87 * p.$2 / max,
                        decoration: BoxDecoration(
                          gradient: p.$2 == 0
                              ? null
                              : const LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: [AppColors.mint, AppColors.lime],
                                ),
                          color: p.$2 == 0 ? AppColors.surfaceHigh : null,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              lbl(points.first.$1),
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              lbl(points.last.$1),
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => const Text(
    'Not enough data yet',
    style: TextStyle(color: AppColors.textSecondary),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.onRetry});
  final IconData icon;
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: AppColors.textSecondary),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}
