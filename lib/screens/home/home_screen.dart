import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../services/auth_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      const _Placeholder(icon: Icons.home_outlined, label: 'Feed (coming next)'),
      const _Placeholder(icon: Icons.search, label: 'Search (coming soon)'),
      const _Placeholder(
          icon: Icons.add_box_outlined, label: 'New post (coming soon)'),
      const _Placeholder(
          icon: Icons.play_circle_outline, label: 'Reels (coming soon)'),
      const _ProfileTab(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Instantgram',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontStyle: FontStyle.italic,
            color: AppTheme.brand,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Log out',
            icon: const Icon(Icons.logout),
            onPressed: () => AuthService.instance.signOut(),
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(
              icon: Icon(Icons.add_box_outlined), label: 'Post'),
          NavigationDestination(
              icon: Icon(Icons.play_circle_outline), label: 'Reels'),
          NavigationDestination(
              icon: Icon(Icons.person_outline), label: 'Profile'),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: Colors.black26),
          const SizedBox(height: 12),
          Text(label, style: const TextStyle(color: Colors.black54)),
        ],
      ),
    );
  }
}

class _ProfileTab extends StatelessWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        final username = data?['username'] ?? user.displayName ?? '...';
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircleAvatar(
                radius: 44,
                backgroundColor: Color(0xFFEFEFEF),
                child: Icon(Icons.person, size: 48, color: Colors.black38),
              ),
              const SizedBox(height: 12),
              Text('@$username',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(user.email ?? '',
                  style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _Stat('Posts', data?['postsCount'] ?? 0),
                  _Stat('Followers', data?['followersCount'] ?? 0),
                  _Stat('Following', data?['followingCount'] ?? 0),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final Object value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        children: [
          Text('$value',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          Text(label, style: const TextStyle(color: Colors.black54)),
        ],
      ),
    );
  }
}
