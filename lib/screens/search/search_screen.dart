import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_events.dart';
import '../../core/theme.dart';
import '../../core/responsive.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../models/post.dart';
import '../../services/post_pager.dart';
import '../../services/post_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/pill_tabs.dart';
import '../../widgets/post_grid.dart';
import '../../widgets/state_views.dart';
import '../profile/profile_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  late final PostPager _explore = PostPager(
    PostService.instance.latestQuery,
    pageSize: 24,
  );
  Timer? _debounce;

  String _query = '';
  bool _searching = false;
  Object? _searchError;
  List<AppUser> _people = [];
  List<Post> _posts = [];
  List<String> _trending = [];

  /// 0 = Posts, 1 = Clips, 2 = People
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _explore.loadMore();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 500) {
        _explore.loadMore();
      }
    });
    AppEvents.searchRequest.addListener(_onRequest);
    _loadTrending();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onRequest());
  }

  Future<void> _loadTrending() async {
    try {
      final t = await PostService.instance.trending();
      if (mounted) setState(() => _trending = t);
    } catch (_) {
      // the chips are optional
    }
  }

  /// Something else in the app asked for a search (a tapped #hashtag).
  void _onRequest() {
    final q = AppEvents.searchRequest.value;
    if (q == null) return;
    AppEvents.searchRequest.value = null;
    _controller.text = q;
    _tab = 0;
    _onChanged(q);
  }

  @override
  void dispose() {
    AppEvents.searchRequest.removeListener(_onRequest);
    _debounce?.cancel();
    _controller.dispose();
    _scroll.dispose();
    _explore.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    setState(() => _query = q);
    if (q.isEmpty) {
      setState(() {
        _people = [];
        _posts = [];
        _searching = false;
        _searchError = null;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final tagOnly = q.startsWith('#');
        final results = await Future.wait<Object>([
          PostService.instance.searchPosts(q),
          tagOnly
              ? Future<List<AppUser>>.value(const [])
              : UserService.instance.searchUsers(q),
        ]);
        if (!mounted || _query != q) return;
        setState(() {
          _posts = results[0] as List<Post>;
          _people = results[1] as List<AppUser>;
          _searching = false;
          _searchError = null;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _searching = false;
          _searchError = e;
        });
      }
    });
  }

  void _useTag(String tag) {
    _controller.text = '#$tag';
    _tab = 0;
    _onChanged('#$tag');
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ContentWidth(
        maxWidth: 860,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 12),
              child: Text(
                'Explore',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.2,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                key: const ValueKey('exploreSearch'),
                controller: _controller,
                onChanged: _onChanged,
                textInputAction: TextInputAction.search,
                autocorrect: false,
                decoration: InputDecoration(
                  hintText: 'Search people, clips, posts or #tags',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            _controller.clear();
                            _onChanged('');
                          },
                        ),
                ),
              ),
            ),
            if (_query.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: PillTabs(
                  labels: const ['Posts', 'Clips', 'People'],
                  index: _tab,
                  onChanged: (i) => setState(() => _tab = i),
                ),
              ),
            Expanded(child: _query.isEmpty ? _exploreGrid() : _results()),
          ],
        ),
      ),
    );
  }

  Widget _results() {
    if (_searching && _posts.isEmpty && _people.isEmpty) {
      return const CenteredLoader();
    }
    if (_searchError != null) {
      return ErrorState(
        error: _searchError!,
        onRetry: () => _onChanged(_query),
      );
    }
    if (_tab == 2) return _peopleList();
    final clips = _tab == 1;
    final shown = [
      for (final p in _posts)
        if (p.isClip == clips) p,
    ];
    if (shown.isEmpty) {
      return EmptyState(
        icon: clips ? Icons.smart_display_outlined : Icons.photo_outlined,
        title: clips ? 'No clips found' : 'No posts found',
        subtitle:
            'Nothing matches "$_query". Try a #hashtag or a word from the title.',
      );
    }
    return CustomScrollView(
      key: ValueKey('results$_tab'),
      slivers: [
        PostGridSliver(posts: shown, inline: clips),
        const SliverToBoxAdapter(child: SizedBox(height: kNavSpace)),
      ],
    );
  }

  /// People: plain rows, no card behind them.
  Widget _peopleList() {
    if (_people.isEmpty) {
      return EmptyState(
        icon: Icons.person_search_rounded,
        title: 'No one found',
        subtitle: _query.startsWith('#')
            ? 'People are searched by username, not by #tag.'
            : 'Nobody matches "$_query".',
      );
    }
    return ListView.builder(
      key: const ValueKey('peopleResults'),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, kNavSpace),
      itemCount: _people.length,
      itemBuilder: (context, i) {
        final u = _people[i];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 2,
          ),
          leading: UserAvatar(url: u.photoUrl, name: u.username, radius: 25),
          title: Text(
            u.username,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          subtitle: u.fullName.isEmpty ? null : Text(u.fullName),
          onTap: () => openScreen(context, ProfileScreen(uid: u.uid)),
        );
      },
    );
  }

  Widget _exploreGrid() {
    return ListenableBuilder(
      listenable: _explore,
      builder: (context, _) {
        if (_explore.initialLoading) return const CenteredLoader();
        if (_explore.error != null && _explore.posts.isEmpty) {
          return ErrorState(error: _explore.error!, onRetry: _explore.retry);
        }
        if (_explore.isEmpty) {
          return const EmptyState(
            icon: Icons.explore_rounded,
            title: 'Nothing to explore yet',
            subtitle: 'Posts from everyone will show up here.',
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            _loadTrending();
            await _explore.refresh();
          },
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (_trending.isNotEmpty)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 46,
                    child: ListView(
                      key: const ValueKey('trendingTags'),
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (final t in _trending)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              label: Text('#$t'),
                              onPressed: () => _useTag(t),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              PostGridSliver(posts: _explore.posts, inline: true),
              if (_explore.loading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: kNavSpace)),
            ],
          ),
        );
      },
    );
  }
}
