import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/services/content_filter.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/ig_text_field.dart';
import '../../../shared/widgets/user_tile.dart';
import '../../profile/data/user_repository.dart';

/// Search people to follow. Empty search = popular accounts.
class FindPeopleScreen extends StatefulWidget {
  const FindPeopleScreen({super.key});

  @override
  State<FindPeopleScreen> createState() => _FindPeopleScreenState();
}

class _FindPeopleScreenState extends State<FindPeopleScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  String _query = '';
  List<UserProfile> _results = const [];
  bool _loading = false;
  late final Future<List<UserProfile>> _popular = _loadPopular();

  Future<List<UserProfile>> _loadPopular() async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .orderBy('followersCount', descending: true)
        .limit(30)
        .get();
    return snap.docs.map(UserProfile.fromDoc).where(_ok).toList();
  }

  bool _ok(UserProfile u) =>
      u.uid != ContentFilter.instance.uid &&
      !ContentFilter.instance.isBlocked(u.uid);

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    final q = v.trim();
    setState(() {
      _query = q;
      _loading = q.isNotEmpty;
    });
    _debounce?.cancel();
    if (q.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final r = await UserRepository.instance.search(q);
        if (mounted && _query == q) {
          setState(() {
            _results = r.where(_ok).toList();
            _loading = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  Widget _list(List<UserProfile> users) => ListView.builder(
    itemCount: users.length,
    itemBuilder: (context, i) => UserTile(
      user: users[i],
      onTap: () => openProfile(context, users[i].uid),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Find people')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: IgTextField(
              hint: 'Search name or @username',
              icon: Icons.search,
              height: 44,
              controller: _ctrl,
              onChanged: _onChanged,
            ),
          ),
          Expanded(
            child: _query.isNotEmpty
                ? (_loading
                      ? const LoadingView()
                      : _results.isEmpty
                      ? const Center(
                          child: Text(
                            'Nobody found',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        )
                      : _list(_results))
                : FutureBuilder<List<UserProfile>>(
                    future: _popular,
                    builder: (context, snap) {
                      if (snap.hasError) return ErrorView(error: snap.error);
                      if (!snap.hasData) return const LoadingView();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.fromLTRB(18, 6, 18, 4),
                            child: Text(
                              'Popular',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          Expanded(child: _list(snap.data!)),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
