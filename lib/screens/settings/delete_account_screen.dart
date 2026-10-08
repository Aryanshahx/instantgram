import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_info.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/auth_service.dart';
import '../../services/user_service.dart';
import 'settings_widgets.dart';

/// The email that asks us to remove an account (pure, so the tests can read it).
Uri deleteRequestMailto({
  required String username,
  required String email,
  required String uid,
}) {
  final body = [
    'Hello,',
    '',
    'Please delete my $kAppName account and everything that goes with it.',
    '',
    'Username: @$username',
    'Email: $email',
    'Account id: $uid',
    '',
    'Thank you.',
  ].join('\n');
  return Uri(
    scheme: 'mailto',
    path: kSupportEmail,
    query: 'subject=${Uri.encodeComponent('Delete my $kAppName account')}'
        '&body=${Uri.encodeComponent(body)}',
  );
}

/// Settings > Account > Delete account.
///
/// The account is not wiped from inside the app: you send us the request by email and we
/// remove the account, its content, its messages and its details, then write back to say it
/// is done. That is the same address as in the Privacy Policy.
class DeleteAccountScreen extends StatelessWidget {
  const DeleteAccountScreen({super.key});

  Future<void> _send(BuildContext context) async {
    var username = '';
    var uid = '';
    try {
      final me = await UserService.instance.getUser(UserService.instance.myUid);
      username = me?.username ?? '';
      uid = me?.uid ?? '';
    } catch (_) {
      // not signed in, or the profile could not be read: the email still goes out
    }
    if (username.isEmpty) {
      username = AuthService.instance.currentUser?.displayName ?? '';
    }
    final email = AuthService.instance.currentUser?.email ?? '';
    final uri = deleteRequestMailto(
      username: username,
      email: email,
      uid: uid,
    );
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok || !context.mounted) return;
    } catch (_) {
      // no email app: show the address instead
    }
    if (!context.mounted) return;
    showToast(context, 'No email app found. Write to $kSupportEmail');
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(const ClipboardData(text: kSupportEmail));
    if (!context.mounted) return;
    showToast(context, 'Address copied: $kSupportEmail');
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Delete account',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Send us the request and we delete the account for you',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Tap the button below and an email opens, already filled in with your '
                'username and account id. Send it and we remove the account within 7 '
                'days, then reply to say it is done.',
                style: TextStyle(color: context.muted, height: 1.4),
              ),
              const SizedBox(height: 14),
              Text(
                'What is removed',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              for (final line in const [
                'Your profile and details (name, username, email, date of birth, country)',
                'Your posts, clips, moments and stories',
                'The photos, videos and sounds you uploaded',
                'Your comments, likes, saves and reposts',
                'Your chats and messages',
                'Your followers and following lists, blocks and notifications',
                'The sign-in itself, so the email and password stop working',
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Icon(Icons.circle, size: 6),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          line,
                          style: TextStyle(color: context.muted, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const ValueKey('deleteRequestButton'),
                  icon: const Icon(Icons.mail_outline_rounded),
                  label: const Text('Send the request by email'),
                  onPressed: () => _send(context),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('deleteCopyButton'),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text('Copy $kSupportEmail'),
                  onPressed: () => _copy(context),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Nothing is deleted while you wait, so you can keep using the app until '
                'we reply. Questions: $kSupportEmail',
                style: TextStyle(color: context.muted, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
