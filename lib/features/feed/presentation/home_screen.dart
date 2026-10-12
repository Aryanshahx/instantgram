import 'package:flutter/material.dart';

import '../../../shared/data/mock_data.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/widgets/ig_logo.dart';
import '../../notifications/presentation/notifications_screen.dart';
import '../../post/presentation/create_sheet.dart';
import '../../profile/data/user_repository.dart';
import 'widgets/post_card.dart';
import 'widgets/story_bar.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserProfile?>(
      stream: UserRepository.instance.watchUser(uid),
      builder: (context, snap) => HomeFeedView(me: snap.data),
    );
  }
}

class HomeFeedView extends StatelessWidget {
  const HomeFeedView({super.key, this.me});

  final UserProfile? me;

  @override
  Widget build(BuildContext context) {
    final feed = MockData.feed;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          floating: true,
          snap: true,
          toolbarHeight: 72,
          centerTitle: true,
          title: const IgLogo(size: 32),
          actions: [
            IconButton(
              tooltip: 'Notifications',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NotificationsScreen()),
              ),
              icon: const Icon(Icons.notifications_none, size: 28),
            ),
            const SizedBox(width: 8),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: StoryBar(
              myAvatarUrl: me?.photoUrl ?? '',
              myName: me?.name ?? '',
              stories: MockData.stories,
              onAddStory: () => showCreateSheet(context),
            ),
          ),
        ),
        SliverList.builder(
          itemCount: feed.length,
          itemBuilder: (context, i) => PostCard(post: feed[i]),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 110)),
      ],
    );
  }
}
