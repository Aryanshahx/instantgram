import 'package:flutter/material.dart';

import '../../../core/config/app_info.dart';
import '../../../core/services/hyper_intelligence.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_widgets.dart';

/// v0.18: Settings -> Hyper Intelligence (InstantGram's safety system).
class HyperIntelligenceScreen extends StatelessWidget {
  const HyperIntelligenceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final hi = HyperIntelligence.instance;
    return ValueListenableBuilder<String>(
      valueListenable: hi.mode,
      builder: (context, mode, _) => SettingsPage(
        title: 'Hyper Intelligence',
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 6, 18, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_outlined, color: AppColors.lime, size: 28),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Hyper Intelligence keeps InstantGram safe. It checks new '
                    'posts, clips, moments and comments, blurs sensitive '
                    'content and stops strong abuse. Your chats are never '
                    'checked.\nVersion ${AppInfo.hiVersion}',
                    key: ValueKey('hi-version'),
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.35,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SettingsHeader('Sensitive content'),
          if (hi.minor)
            const Padding(
              key: ValueKey('hi-minor-note'),
              padding: EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Text(
                'You are under 18, so sensitive content is always hidden.',
                style: TextStyle(fontSize: 13, color: AppColors.lime),
              ),
            ),
          SettingsCard(
            children: [
              _Choice(
                key: const ValueKey('hi-mode-blur'),
                title: 'Blur',
                subtitle: 'Show it blurred: "Sensitive content · Tap to view"',
                selected: !hi.minor && mode == HyperIntelligence.blur,
                onTap: hi.minor
                    ? null
                    : () => hi.setMode(HyperIntelligence.blur),
              ),
              _Choice(
                key: const ValueKey('hi-mode-hide'),
                title: 'Hide',
                subtitle: "Don't show sensitive content at all",
                selected: hi.minor || mode == HyperIntelligence.hide,
                onTap: hi.minor
                    ? null
                    : () => hi.setMode(HyperIntelligence.hide),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: Text(
              'If Hyper Intelligence blurred your post by mistake, our team '
              'checks it and shows it normally again.',
              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => SettingsTile(
    icon: selected ? Icons.radio_button_checked : Icons.radio_button_off,
    title: title,
    subtitle: subtitle,
    trailing: const SizedBox.shrink(),
    onTap: onTap,
  );
}
