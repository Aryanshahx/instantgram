import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/l10n.dart';
import '../../core/legal.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../widgets/avatar.dart';

/// Share profile: a QR code that points to the profile, the link, the username, and a Share
/// button.
class ShareProfileScreen extends StatelessWidget {
  const ShareProfileScreen({super.key, required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final link = profileLinkFor(user.username);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Share profile'))),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
                    decoration: BoxDecoration(
                      color: context.card,
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(color: context.hairline),
                    ),
                    child: Column(
                      children: [
                        UserAvatar(
                          url: user.photoUrl,
                          name: user.username,
                          radius: 34,
                          uid: user.uid,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '@${user.username}',
                          key: const ValueKey('shareUsername'),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                        if (user.fullName.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              user.fullName,
                              style: TextStyle(color: context.muted),
                            ),
                          ),
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: QrImageView(
                            key: const ValueKey('profileQr'),
                            data: link,
                            size: 220,
                            backgroundColor: Colors.white,
                            padding: EdgeInsets.zero,
                            eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: Colors.black,
                            ),
                            dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        InkWell(
                          key: const ValueKey('profileLink'),
                          borderRadius: BorderRadius.circular(14),
                          onTap: () async {
                            await Clipboard.setData(ClipboardData(text: link));
                            if (context.mounted) {
                              showToast(context, context.tr('Link copied'));
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    link,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: context.muted,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.copy_rounded,
                                  size: 16,
                                  color: context.muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('shareProfileSend'),
                      onPressed: () async {
                        // ignore: deprecated_member_use
                        await Share.share(profileShareText(user.username));
                      },
                      icon: const Icon(Icons.ios_share_rounded),
                      label: Text(context.tr('Share')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
