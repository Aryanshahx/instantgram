import 'package:flutter/material.dart';

import '../../../shared/widgets/empty_state.dart';

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: const Center(
        child: EmptyState(
          icon: Icons.notifications_none,
          title: 'No notifications yet',
          subtitle: 'Likes, comments and new followers will show up here.',
        ),
      ),
    );
  }
}
