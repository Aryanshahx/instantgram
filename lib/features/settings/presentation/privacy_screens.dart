import 'package:flutter/material.dart';

import '../../../core/services/content_filter.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../profile/data/user_repository.dart';
import 'settings_widgets.dart';

void _snack(BuildContext context, String msg) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(msg)));

/// Settings → Account privacy.
class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  final _me = UserRepository.instance.watchUser(ContentFilter.instance.uid);
  final _requests = UserRepository.instance.followRequests();
  bool? _pending;

  Future<void> _set(bool on) async {
    setState(() => _pending = on);
    try {
      await UserRepository.instance.setPrivate(on);
      if (mounted) {
        _snack(
          context,
          on ? 'Your account is now private' : 'Your account is now public',
        );
      }
    } catch (e) {
      if (mounted) _snack(context, friendlyError(e));
    }
    if (mounted) setState(() => _pending = null);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserProfile?>(
      stream: _me,
      builder: (context, snap) {
        final isPrivate = _pending ?? snap.data?.isPrivate ?? false;
        return SettingsPage(
          title: 'Account privacy',
          children: [
            const SizedBox(height: 6),
            SettingsCard(
              children: [
                SettingsSwitch(
                  icon: Icons.lock_outline,
                  title: 'Private account',
                  value: isPrivate,
                  onChanged: snap.hasData && _pending == null ? _set : null,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(
                isPrivate
                    ? 'Only people you approve can see your posts, clips and '
                          'moments, and who you follow. Your current followers '
                          'stay.'
                    : 'Anyone on InstantGram can see your posts, clips and '
                          'moments, and can follow you without asking.',
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            const SettingsHeader('Followers'),
            SettingsCard(
              children: [
                StreamBuilder<List<UserProfile>>(
                  stream: _requests,
                  builder: (context, s) {
                    final n = s.data?.length ?? 0;
                    return SettingsTile(
                      icon: Icons.person_add_alt_1_outlined,
                      title: 'Follow requests',
                      subtitle: n == 0 ? 'No requests' : '$n waiting',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const FollowRequestsScreen(),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Approve / decline people who asked to follow you.
class FollowRequestsScreen extends StatefulWidget {
  const FollowRequestsScreen({super.key});

  @override
  State<FollowRequestsScreen> createState() => _FollowRequestsScreenState();
}

class _FollowRequestsScreenState extends State<FollowRequestsScreen> {
  final _stream = UserRepository.instance.followRequests();
  final Set<String> _busy = {};

  Future<void> _act(UserProfile u, bool approve) async {
    setState(() => _busy.add(u.uid));
    try {
      if (approve) {
        await UserRepository.instance.approveRequest(u.uid);
      } else {
        await UserRepository.instance.declineRequest(u.uid);
      }
    } catch (e) {
      if (mounted) _snack(context, friendlyError(e));
    }
    if (mounted) setState(() => _busy.remove(u.uid));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Follow requests')),
      body: StreamBuilder<List<UserProfile>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(error: snap.error);
          if (!snap.hasData) return const LoadingView();
          final list = snap.data!
              .where((u) => !ContentFilter.instance.isBlocked(u.uid))
              .toList();
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.person_add_alt_1_outlined,
              title: 'No follow requests',
              subtitle: 'When someone asks to follow you, it shows here.',
            );
          }
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (context, i) {
              final u = list[i];
              final busy = _busy.contains(u.uid);
              return ListTile(
                dense: true,
                onTap: () => openProfile(context, u.uid),
                leading: Avatar(url: u.photoUrl, name: u.displayName, size: 42),
                title: Text(
                  u.username,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  u.displayName,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                trailing: busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FilledButton(
                            key: ValueKey('approve-${u.uid}'),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.lime,
                              foregroundColor: Colors.black,
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                            ),
                            onPressed: () => _act(u, true),
                            child: const Text('Confirm'),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton(
                            key: ValueKey('decline-${u.uid}'),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                            onPressed: () => _act(u, false),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Settings → Blocked.
class BlockedScreen extends StatefulWidget {
  const BlockedScreen({super.key});

  @override
  State<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends State<BlockedScreen> {
  final _stream = UserRepository.instance.blockedUsers();

  Future<void> _unblock(UserProfile u) async {
    try {
      await UserRepository.instance.unblock(u.uid);
      if (mounted) _snack(context, 'Unblocked @${u.username}');
    } catch (e) {
      if (mounted) _snack(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked')),
      body: StreamBuilder<List<UserProfile>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(error: snap.error);
          if (!snap.hasData) return const LoadingView();
          final list = snap.data!;
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.block,
              title: 'No blocked accounts',
              subtitle:
                  "People you block can't see your profile or message "
                  'you. Block someone from the ⋯ menu on their profile.',
            );
          }
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (context, i) {
              final u = list[i];
              return ListTile(
                dense: true,
                leading: Avatar(url: u.photoUrl, name: u.displayName, size: 42),
                title: Text(
                  u.username,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  u.displayName,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                trailing: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _unblock(u),
                  child: const Text('Unblock'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
