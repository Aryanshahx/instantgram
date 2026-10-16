import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/post_grid.dart';
import '../../post/data/post_repository.dart';

/// Opens the page of one #hashtag.
void openHashtag(BuildContext context, String tag) {
  final t = PostRepository.normalizeTag(tag);
  if (t.isEmpty) return;
  Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => HashtagScreen(tag: t)));
}

/// v0.17: everything shared with one hashtag (clips and posts, newest
/// first). Opened by tapping a #tag in a caption or a comment.
class HashtagScreen extends StatefulWidget {
  const HashtagScreen({super.key, required this.tag});

  final String tag;

  /// Tests: list without Firestore.
  static Future<List<Post>> Function(String tag)? debugLoad;

  @override
  State<HashtagScreen> createState() => _HashtagScreenState();
}

enum _Show { all, clips, posts }

class _HashtagScreenState extends State<HashtagScreen> {
  List<Post>? _posts;
  bool _failed = false;
  _Show _show = _Show.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final f = HashtagScreen.debugLoad ?? PostRepository.instance.postsByTag;
      final list = await f(widget.tag);
      if (mounted) {
        setState(() {
          _posts = list;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  List<Post> get _shown {
    final all = _posts ?? const <Post>[];
    return switch (_show) {
      _Show.all => all,
      _Show.clips => all.where((p) => p.isClip).toList(),
      _Show.posts => all.where((p) => !p.isClip).toList(),
    };
  }

  Widget _chip(_Show v, String label) {
    final on = _show == v;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        key: ValueKey('tag-show-${v.name}'),
        label: Text(label),
        selected: on,
        showCheckmark: false,
        selectedColor: AppColors.lime,
        backgroundColor: AppColors.surface,
        labelStyle: TextStyle(
          color: on ? Colors.black : AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        side: BorderSide(color: on ? AppColors.lime : AppColors.border),
        onSelected: (_) => setState(() => _show = v),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final posts = _posts;
    final clips = posts?.where((p) => p.isClip).length ?? 0;
    final photos = (posts?.length ?? 0) - clips;
    return Scaffold(
      appBar: AppBar(title: Text('#${widget.tag}')),
      body: posts == null
          ? Center(
              child: _failed
                  ? TextButton(
                      key: const ValueKey('tag-retry'),
                      onPressed: () {
                        setState(() => _failed = false);
                        _load();
                      },
                      child: const Text("Couldn't load. Tap to try again"),
                    )
                  : const CircularProgressIndicator(),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                  child: Text(
                    posts.length == 1 ? '1 share' : '${posts.length} shares',
                    key: const ValueKey('tag-count'),
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                  child: Row(
                    children: [
                      _chip(_Show.all, 'All'),
                      _chip(_Show.clips, 'Clips $clips'),
                      _chip(_Show.posts, 'Posts $photos'),
                    ],
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    color: AppColors.lime,
                    onRefresh: _load,
                    child: PostGrid(
                      key: ValueKey('tag-grid-${_show.name}'),
                      posts: _shown,
                      onTap: (i) => openPost(
                        context,
                        _shown,
                        i,
                        source: ViewSource.explore,
                      ),
                      emptyIcon: Icons.tag,
                      emptyTitle: 'Nothing with #${widget.tag} yet',
                      emptySubtitle: 'Share a clip or post with this tag.',
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
