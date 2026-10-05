import '../core/hashtags.dart';
import '../models/post.dart';

/// The posts of [pool] (newest first) that match [query]:
///  * `#sunset` finds posts with a hashtag that starts with "sunset"
///  * words find posts whose title/caption (or author name) contain every word
/// Posts whose title starts with the search, or that have the exact hashtag, come first.
List<Post> filterPosts(List<Post> pool, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final terms = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  final strong = <Post>[];
  final weak = <Post>[];
  for (final p in pool) {
    final caption = p.caption.toLowerCase();
    final tags = extractHashtags(p.caption);
    final author = p.authorUsername.toLowerCase();
    var all = true;
    var exact = false;
    for (final t in terms) {
      if (t.startsWith('#')) {
        final tag = t.substring(1);
        if (tag.isEmpty) continue;
        if (tags.contains(tag)) exact = true;
        if (!tags.any((x) => x.startsWith(tag))) all = false;
      } else if (!(caption.contains(t) || author.contains(t))) {
        all = false;
      }
    }
    if (!all) continue;
    if (exact || caption.startsWith(q)) {
      strong.add(p);
    } else {
      weak.add(p);
    }
  }
  return [...strong, ...weak];
}

/// The most used hashtags in [posts], most used first (ties: alphabetical).
List<String> trendingTags(List<Post> posts, {int limit = 12}) {
  final counts = <String, int>{};
  for (final p in posts) {
    for (final t in extractHashtags(p.caption)) {
      counts[t] = (counts[t] ?? 0) + 1;
    }
  }
  final tags = counts.keys.toList()
    ..sort((a, b) {
      final c = counts[b]!.compareTo(counts[a]!);
      return c != 0 ? c : a.compareTo(b);
    });
  return tags.take(limit).toList();
}
