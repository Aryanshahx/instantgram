import 'package:flutter/material.dart';

import '../core/app_events.dart';
import '../core/hashtags.dart';
import '../core/media_url.dart';
import '../core/theme.dart';
import '../models/music.dart';
import '../models/post.dart';
import '../services/post_service.dart';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "12 Sep 2026, 14:05"
String fullDate(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.day} ${_months[l.month - 1]} ${l.year}, ${two(l.hour)}:${two(l.minute)}';
}

/// 1234 -> "1.2K"
String compactCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}K'.replaceFirst(
      '.0K',
      'K',
    );
  }
  return '${(n / 1000000).toStringAsFixed(1)}M'.replaceFirst('.0M', 'M');
}

/// Everything about a post or a clip: title, views, likes, comments, date, length, quality,
/// audio. Opened by tapping the title on Clips.
Future<void> showPostDetails(BuildContext context, Post post) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => PostDetailsSheet(post: post),
  );
}

class PostDetailsSheet extends StatefulWidget {
  const PostDetailsSheet({super.key, required this.post, this.loader});
  final Post post;

  /// Loads the latest numbers (defaults to the database; tests pass their own).
  final Future<Post?> Function(String id)? loader;

  @override
  State<PostDetailsSheet> createState() => _PostDetailsSheetState();
}

class _PostDetailsSheetState extends State<PostDetailsSheet> {
  late Post _post = widget.post;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final load = widget.loader ?? PostService.instance.getPost;
      final fresh = await load(widget.post.id);
      if (mounted && fresh != null) setState(() => _post = fresh);
    } catch (_) {
      // the numbers that came with the post are shown
    }
  }

  String get _kind => _post.isPhotoClip
      ? 'Photo clip'
      : _post.isVideo
      ? 'Video clip'
      : _post.isCarousel
      ? 'Carousel (${_post.media.length} items)'
      : 'Photo post';

  @override
  Widget build(BuildContext context) {
    final p = _post;
    final tags = extractHashtags(p.caption);
    final track = musicById(p.musicId);
    final rows = <(IconData, String, String)>[
      (Icons.event_rounded, 'Posted', fullDate(p.createdAt)),
      (Icons.movie_creation_outlined, 'Type', _kind),
      if (p.isClip && p.videoDuration > 0)
        (Icons.timer_outlined, 'Length', formatDuration(p.videoDuration)),
      if (p.isVideo && p.videoWidth > 0 && p.videoHeight > 0)
        (
          Icons.aspect_ratio_rounded,
          'Quality',
          '${p.videoWidth} x ${p.videoHeight}',
        ),
      if (!p.isClip && p.imageWidth > 0 && p.imageHeight > 0)
        (
          Icons.aspect_ratio_rounded,
          'Size',
          '${p.imageWidth} x ${p.imageHeight}',
        ),
      (
        Icons.music_note_rounded,
        'Audio',
        track != null
            ? ((p.isVideo || p.media.any((m) => m.video))
                  ? '${track.label}${p.keepSound ? ' + original sound' : ''}'
                  : track.label)
            : (p.isVideo ? 'Original sound' : 'None'),
      ),
    ];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '@${p.authorUsername}',
                style: TextStyle(
                  color: context.muted,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              if (p.caption.isNotEmpty)
                HashtagText(
                  p.caption,
                  tagColor: context.accentInk,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                )
              else
                Text(
                  'No title',
                  style: TextStyle(color: context.muted, fontSize: 18),
                ),
              const SizedBox(height: 18),
              Row(
                children: [
                  _Stat(
                    key: const ValueKey('statViews'),
                    icon: Icons.visibility_rounded,
                    label: 'Views',
                    value: p.viewCount,
                  ),
                  const SizedBox(width: 10),
                  _Stat(
                    icon: Icons.favorite_rounded,
                    label: 'Likes',
                    value: p.likeCount,
                  ),
                  const SizedBox(width: 10),
                  _Stat(
                    icon: Icons.chat_bubble_rounded,
                    label: 'Comments',
                    value: p.commentCount,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _Stat(
                    key: const ValueKey('statShares'),
                    icon: Icons.ios_share_rounded,
                    label: 'Shares',
                    value: p.shareCount,
                  ),
                  const SizedBox(width: 10),
                  _Stat(
                    key: const ValueKey('statReposts'),
                    icon: Icons.repeat_rounded,
                    label: 'Reposts',
                    value: p.repostCount,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                    children: [
                      Icon(r.$1, size: 20, color: context.muted),
                      const SizedBox(width: 12),
                      Text(r.$2, style: TextStyle(color: context.muted)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          r.$3,
                          textAlign: TextAlign.end,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in tags)
                      ActionChip(
                        label: Text('#$t'),
                        onPressed: () {
                          Navigator.of(context).popUntil((r) => r.isFirst);
                          AppEvents.openSearch('#$t');
                        },
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: context.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.hairline.withValues(alpha: 0.7)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 20, color: context.accentInk),
            const SizedBox(height: 6),
            Text(
              compactCount(value),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            Text(label, style: TextStyle(color: context.muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
