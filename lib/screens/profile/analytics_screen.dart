import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/media_url.dart';
import '../../core/theme.dart';
import '../../widgets/pill_tabs.dart';
import '../../widgets/post_details_sheet.dart';
import '../../widgets/state_views.dart';
import '../../models/post.dart';
import '../../services/analytics_service.dart';
import '../reels/reels_screen.dart';

/// Numbers of one account: Overview, Reach, Engagement and Audience.
///
/// Opened from the Me screen. Everything is counted from what the app already stores, so
/// these numbers start with this version; older posts have what was counted since then.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key, this.uid, this.postId});

  /// Whose numbers (null = the signed-in account).
  final String? uid;

  /// Set to see the numbers of that one post or clip only.
  final String? postId;

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  static const List<int> _ranges = [7, 30, 90];
  int _days = 7;
  int _tab = 0;
  Future<Insights>? _future;

  @override
  void initState() {
    super.initState();
    _future = AnalyticsService.instance.load(_days, uid: widget.uid);
  }

  void _reload() {
    setState(() {
      _future = AnalyticsService.instance.load(
        _days,
        uid: widget.uid,
        postId: widget.postId,
      );
    });
  }

  void _pickRange(int days) {
    if (days == _days) return;
    setState(() => _days = days);
    _reload();
  }

  Future<void> _openPost(Post post) async {
    if (post.isClip) {
      openClips(context, post);
      return;
    }
    showPostDetails(context, post);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.postId == null ? 'Analytics' : 'Post analytics'),
      ),
      body: FutureBuilder<Insights>(
        key: const ValueKey('analyticsBody'),
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorState(error: snap.error!, onRetry: _reload);
          }
          if (!snap.hasData) return const CenteredLoader();
          final data = snap.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              PillTabs(
                labels: const ['7 days', '30 days', '90 days'],
                index: _ranges.indexOf(_days),
                onChanged: (i) => _pickRange(_ranges[i]),
              ),
              const SizedBox(height: 12),
              PillTabs(
                labels: const ['Overview', 'Reach', 'Engagement', 'Audience'],
                index: _tab,
                onChanged: (i) => setState(() => _tab = i),
              ),
              const SizedBox(height: 14),
              if (data.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 60),
                  child: EmptyState(
                    icon: Icons.insights_rounded,
                    title: 'No numbers yet',
                    subtitle:
                        'Publish a post or a clip. Views, likes, comments and who '
                        'watched show up here as they happen.',
                  ),
                )
              else ...[
                if (_tab == 0) ..._overview(data),
                if (_tab == 1) ..._reach(data),
                if (_tab == 2) ..._engagement(data),
                if (_tab == 3) ..._audience(data),
              ],
            ],
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------- the four tabs

  List<Widget> _overview(Insights d) => [
    _Grid(children: [
      _BigNumber(
        key: const ValueKey('statViews'),
        label: 'Views',
        value: _fmt(d.views),
        hint: 'in the last ${d.days} days',
      ),
      _BigNumber(
        key: const ValueKey('statReach'),
        label: 'Accounts reached',
        value: _fmt(d.reach),
        hint: 'everybody counted once',
      ),
      _BigNumber(
        key: const ValueKey('statEngagement'),
        label: 'Engagement',
        value: _fmt(d.engagement),
        hint: 'likes, comments, shares, reposts',
      ),
      _BigNumber(
        key: const ValueKey('statFollowers'),
        label: 'New followers',
        value: '+${_fmt(d.followersGained)}',
        hint: 'now ${_fmt(d.followersNow)}',
      ),
    ]),
    const SizedBox(height: 12),
    _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Head('Views per day'),
          const SizedBox(height: 10),
          _Chart(values: d.dailyViews, days: d.days),
        ],
      ),
    ),
    const SizedBox(height: 12),
    _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Head('This period'),
          const SizedBox(height: 8),
          _Line('Posts published', '${d.postsPublished}'),
          _Line('Engagement rate', _pct(d.engagementRate)),
          _Line('Reach of your followers', _pct(d.reachRate)),
          _Line('Average views per post', d.avgViews.toStringAsFixed(1)),
        ],
      ),
    ),
    if (d.topByViews.isNotEmpty) ...[
      const SizedBox(height: 12),
      _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Head('Best performers'),
            const SizedBox(height: 6),
            for (final p in d.topByViews)
              _PostRow(
                insight: p,
                onTap: () => _openPost(p.post),
                trailing: '${_fmt(p.views)} views',
              ),
          ],
        ),
      ),
    ],
  ];

  List<Widget> _reach(Insights d) => [
    _Grid(children: [
      _BigNumber(
        key: const ValueKey('reachAccounts'),
        label: 'Accounts reached',
        value: _fmt(d.reach),
        hint: 'of ${_fmt(d.followersNow)} followers',
      ),
      _BigNumber(
        key: const ValueKey('reachViews'),
        label: 'Views',
        value: _fmt(d.views),
        hint: '${d.avgViews.toStringAsFixed(1)} per post',
      ),
      _BigNumber(
        label: 'Followers reached',
        value: _fmt(d.followersReached),
        hint: 'already follow you',
      ),
      _BigNumber(
        label: 'New people',
        value: _fmt(d.nonFollowersReached),
        hint: 'do not follow you yet',
      ),
    ]),
    const SizedBox(height: 12),
    _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Head('Who you reached'),
          const SizedBox(height: 10),
          _Split(
            left: d.followersReached,
            right: d.nonFollowersReached,
            leftLabel: 'Followers',
            rightLabel: 'Others',
          ),
          const SizedBox(height: 8),
          _Line('Reach rate', _pct(d.reachRate)),
          _Line(
            'Repeated views',
            _fmt(d.views - d.reach < 0 ? 0 : d.views - d.reach),
          ),
        ],
      ),
    ),
    const SizedBox(height: 12),
    _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Head('Most reached'),
          const SizedBox(height: 6),
          for (final p in d.topByReach)
            _PostRow(
              insight: p,
              onTap: () => _openPost(p.post),
              trailing: '${_fmt(p.reach)} reached',
            ),
        ],
      ),
    ),
  ];

  List<Widget> _engagement(Insights d) => [
    _Grid(children: [
      _BigNumber(
        key: const ValueKey('engLikes'),
        label: 'Likes',
        value: _fmt(d.likes),
        hint: '${d.avgLikes.toStringAsFixed(1)} per post',
      ),
      _BigNumber(
        key: const ValueKey('engComments'),
        label: 'Comments',
        value: _fmt(d.comments),
        hint: '${d.avgComments.toStringAsFixed(1)} per post',
      ),
      _BigNumber(label: 'Shares', value: _fmt(d.shares), hint: 'sent on'),
      _BigNumber(label: 'Reposts', value: _fmt(d.reposts), hint: 'shared again'),
    ]),
    const SizedBox(height: 12),
    _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Head('How people react'),
          const SizedBox(height: 10),
          _BarRow(
            label: 'Likes',
            value: d.likes,
            of: d.engagement == 0 ? 1 : d.engagement,
          ),
          _BarRow(
            label: 'Comments',
            value: d.comments,
            of: d.engagement == 0 ? 1 : d.engagement,
          ),
          _BarRow(
            label: 'Shares',
            value: d.shares,
            of: d.engagement == 0 ? 1 : d.engagement,
          ),
          _BarRow(
            label: 'Reposts',
            value: d.reposts,
            of: d.engagement == 0 ? 1 : d.engagement,
          ),
          const SizedBox(height: 10),
          _Line('Engagement rate', _pct(d.engagementRate)),
        ],
      ),
    ),
    const SizedBox(height: 12),
    _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Head('Most engaging'),
          const SizedBox(height: 6),
          for (final p in d.topByEngagement)
            _PostRow(
              insight: p,
              onTap: () => _openPost(p.post),
              trailing: '${_fmt(p.engagement)} reactions',
            ),
        ],
      ),
    ),
  ];

  List<Widget> _audience(Insights d) => [
    _Grid(children: [
      _BigNumber(
        key: const ValueKey('audFollowers'),
        label: 'Followers',
        value: _fmt(d.followersNow),
        hint: 'in total',
      ),
      _BigNumber(
        label: 'New followers',
        value: '+${_fmt(d.followersGained)}',
        hint: 'in the last ${d.days} days',
      ),
      _BigNumber(
        label: 'Followers reached',
        value: _fmt(d.followersReached),
        hint: 'saw something of yours',
      ),
      _BigNumber(
        label: 'Others reached',
        value: _fmt(d.nonFollowersReached),
        hint: 'found you without following',
      ),
    ]),
    const SizedBox(height: 12),
    if (d.countries.isNotEmpty)
      _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Head('Where they are'),
            const SizedBox(height: 10),
            for (final e in d.countries.entries)
              _BarRow(
                label: e.key,
                value: e.value,
                of: d.reach == 0 ? 1 : d.reach,
                showNumber: true,
              ),
          ],
        ),
      ),
    if (d.countries.isNotEmpty) const SizedBox(height: 12),
    if (d.languages.isNotEmpty)
      _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Head('Language'),
            const SizedBox(height: 10),
            for (final e in d.languages.entries)
              _BarRow(
                label: e.key,
                value: e.value,
                of: d.reach == 0 ? 1 : d.reach,
                showNumber: true,
              ),
          ],
        ),
      ),
    if (d.countries.isEmpty && d.languages.isEmpty)
      _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Head('Where they are'),
            const SizedBox(height: 6),
            Text(
              'Countries and languages appear once people with a country set watch '
              'your posts.',
              style: TextStyle(color: context.muted, fontSize: 13),
            ),
          ],
        ),
      ),
  ];
}

// ------------------------------------------------------------------- small parts

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
    decoration: BoxDecoration(
      color: context.card,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: context.hairline),
    ),
    child: child,
  );
}

class _Head extends StatelessWidget {
  const _Head(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
  );
}

class _Grid extends StatelessWidget {
  const _Grid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final columns = width > 620 ? 4 : 2;
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: columns,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.25,
      children: children,
    );
  }
}

class _BigNumber extends StatelessWidget {
  const _BigNumber({
    super.key,
    required this.label,
    required this.value,
    required this.hint,
  });

  final String label;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) => _Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          hint,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: context.muted, fontSize: 11.5),
        ),
      ],
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(child: Text(label, style: TextStyle(color: context.muted))),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
      ],
    ),
  );
}

class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.value,
    required this.of,
    this.showNumber = false,
  });

  final String label;
  final int value;
  final int of;
  final bool showNumber;

  @override
  Widget build(BuildContext context) {
    final part = of <= 0 ? 0.0 : (value / of).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                showNumber ? '$value' : _pct(part),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: context.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: part,
              minHeight: 8,
              backgroundColor: context.softFill,
              color: AppTheme.volt,
            ),
          ),
        ],
      ),
    );
  }
}

/// Followers on the left, everybody else on the right.
class _Split extends StatelessWidget {
  const _Split({
    required this.left,
    required this.right,
    required this.leftLabel,
    required this.rightLabel,
  });

  final int left;
  final int right;
  final String leftLabel;
  final String rightLabel;

  @override
  Widget build(BuildContext context) {
    final total = left + right;
    final leftPart = total == 0 ? 0.5 : left / total;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              flex: (leftPart * 100).round().clamp(1, 99),
              child: Container(
                height: 10,
                decoration: const BoxDecoration(
                  color: AppTheme.volt,
                  borderRadius: BorderRadius.horizontal(
                    left: Radius.circular(6),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: ((1 - leftPart) * 100).round().clamp(1, 99),
              child: Container(
                height: 10,
                decoration: BoxDecoration(
                  color: AppTheme.violet.withValues(alpha: 0.55),
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(6),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.circle, size: 9, color: AppTheme.volt),
            const SizedBox(width: 5),
            Text('$leftLabel $left'),
            const SizedBox(width: 14),
            Icon(
              Icons.circle,
              size: 9,
              color: AppTheme.violet.withValues(alpha: 0.55),
            ),
            const SizedBox(width: 5),
            Text('$rightLabel $right'),
          ],
        ),
      ],
    );
  }
}

/// The little views-per-day chart: one bar per day, no package needed.
class _Chart extends StatelessWidget {
  const _Chart({required this.values, required this.days});

  final List<int> values;
  final int days;

  @override
  Widget build(BuildContext context) {
    final empty = values.isEmpty;
    final top = empty ? 1 : values.reduce((a, b) => a > b ? a : b);
    return SizedBox(
      height: 92,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final v in values)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: FractionallySizedBox(
                  heightFactor: top == 0 ? 0.02 : (v / top).clamp(0.02, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: v == 0 ? context.softFill : AppTheme.volt,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PostRow extends StatelessWidget {
  const _PostRow({
    required this.insight,
    required this.onTap,
    required this.trailing,
  });

  final PostInsight insight;
  final VoidCallback onTap;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final post = insight.post;
    final thumb = resolveMediaUrl(post.thumbRef);
    // The card behind it has a colour, so the row needs its own Material: without it
    // the tap ripple is painted under the card and never shows.
    return Material(
      color: Colors.transparent,
      child: ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: thumb.isEmpty
            ? Container(
                width: 46,
                height: 46,
                color: context.softFill,
                child: Icon(
                  post.isClip ? Icons.play_arrow_rounded : Icons.image_rounded,
                  color: context.muted,
                ),
              )
            : CachedNetworkImage(
                imageUrl: thumb,
                width: 46,
                height: 46,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => Container(
                  width: 46,
                  height: 46,
                  color: context.softFill,
                ),
              ),
      ),
      title: Text(
        post.caption.isEmpty
            ? (post.isClip ? 'Clip' : 'Post')
            : post.caption,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
      subtitle: Text(
        '${_fmt(insight.views)} views  ·  ${_fmt(insight.likes)} likes  ·  '
        '${_fmt(insight.comments)} comments',
        style: TextStyle(color: context.muted, fontSize: 12),
      ),
      trailing: Text(
        trailing,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
      ),
      ),
    );
  }
}

/// 1 234 -> "1.2k".
String _fmt(int n) {
  if (n < 0) return '0';
  if (n < 1000) return '$n';
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

String _pct(double part) => '${(part * 100).toStringAsFixed(1)}%';
