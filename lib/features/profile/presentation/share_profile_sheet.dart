import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/profile_link.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/widgets/avatar.dart';
import 'qr_scan_screen.dart';

/// Share profile: QR code, copy link, share, save QR, scan a code.
Future<void> showShareProfileSheet(BuildContext context, UserProfile user) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ShareProfileSheet(user: user),
    );

class ShareProfileSheet extends StatefulWidget {
  const ShareProfileSheet({super.key, required this.user});
  final UserProfile user;

  @override
  State<ShareProfileSheet> createState() => _ShareProfileSheetState();
}

class _ShareProfileSheetState extends State<ShareProfileSheet> {
  final GlobalKey _card = GlobalKey();
  bool _saving = false;

  String get _link => profileLink(widget.user.username);

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _link));
    _snack('Profile link copied');
  }

  Future<void> _share() => SharePlus.instance.share(
    ShareParams(text: 'Follow @${widget.user.username} on InstantGram\n$_link'),
  );

  /// Saves the QR card as a picture in the gallery.
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final boundary =
          _card.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('not ready');
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('no image');
      if (!await Gal.hasAccess()) {
        final ok = await Gal.requestAccess();
        if (!ok) {
          _snack('Allow photo access to save the QR code');
          return;
        }
      }
      await Gal.putImageBytes(
        data.buffer.asUint8List(),
        name: 'instantgram_${widget.user.username}',
      );
      _snack('QR code saved to your gallery');
    } catch (e) {
      _snack(
        e is GalException
            ? 'Could not save: ${e.type.message}'
            : 'Could not save the QR code',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _scan() {
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(MaterialPageRoute<void>(builder: (_) => const QrScanScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              key: _card,
              child: QrCard(user: u, link: _link),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _Action(
                  key: const ValueKey('qr-copy'),
                  icon: Icons.link,
                  label: 'Copy link',
                  onTap: _copy,
                ),
                _Action(
                  key: const ValueKey('qr-share'),
                  icon: Icons.ios_share,
                  label: 'Share',
                  onTap: _share,
                ),
                _Action(
                  key: const ValueKey('qr-save'),
                  icon: Icons.download_rounded,
                  label: _saving ? 'Saving…' : 'Download',
                  onTap: _saving ? null : _save,
                ),
                _Action(
                  key: const ValueKey('qr-scan'),
                  icon: Icons.qr_code_scanner,
                  label: 'Scan',
                  onTap: _scan,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The QR card (also the picture saved to the gallery).
class QrCard extends StatelessWidget {
  const QrCard({super.key, required this.user, required this.link});
  final UserProfile user;
  final String link;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: BoxDecoration(
        gradient: AppColors.fabGradient,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: QrImageView(
              key: const ValueKey('profile-qr'),
              data: link,
              size: 200,
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Color(0xFF0C0D12),
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.circle,
                color: Color(0xFF0C0D12),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Avatar(url: user.photoUrl, name: user.displayName, size: 28),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '@${user.username}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    color: Color(0xFF0C0D12),
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'InstantGram',
            style: TextStyle(
              fontFamily: AppTheme.logoFontFamily,
              color: Color(0xFF0C0D12),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(icon, color: AppColors.lime, size: 22),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
