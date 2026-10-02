import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../services/post_pager.dart';
import '../../services/post_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
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
  late final PostPager _explore =
      PostPager(PostService.instance.latestQuery, pageSize: 24);
  Timer? _debounce;

  String _query = '';
  bool _searching = false;
  Object? _searchError;
  List<AppUser> _results = [];

  @override
  void initState() {
    super.initState();
    _explore.loadMore();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 500) {
        _explore.loadMore();
      }
    });
  }

  @override
  void dispose() {
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
        _results = [];
        _searching = false;
        _searchError = null;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final users = await UserService.instance.searchUsers(q);
        if (!mounted || _query != q) return;
        setState(() {
          _results = users;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: SizedBox(
          height: 40,
          child: TextField(
            controller: _controller,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: 'Search people',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _controller.clear();
                        _onChanged('');
                      },
                    ),
              contentPadding: EdgeInsets.zero,
              filled: true,
              fillColor: context.softFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
      ),
      body: _query.isEmpty ? _exploreGrid() : _userResults(),
    );
  }

  Widget _userResults() {
    if (_searching && _results.isEmpty) return const CenteredLoader();
    if (_searchError != null) {
      return ErrorState(error: _searchError!, onRetry: () => _onChanged(_query));
    }
    if (_results.isEmpty) {
      return EmptyState(
        icon: Icons.person_search_outlined,
        title: 'No users found',
        subtitle: 'Nobody matches "$_query".',
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final u = _results[i];
        return ListTile(
          leading: UserAvatar(url: u.photoUrl, radius: 24),
          title: Text(u.username,
              style: const TextStyle(fontWeight: FontWeight.w700)),
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
            icon: Icons.explore_outlined,
            title: 'Nothing to explore yet',
            subtitle: 'Posts from everyone will show up here.',
          );
        }
        return RefreshIndicator(
          onRefresh: _explore.refresh,
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              PostGridSliver(posts: _explore.posts),
              if (_explore.loading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2.5)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
