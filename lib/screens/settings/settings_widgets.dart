import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// One row of a settings page.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppTheme.coral : null;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: (destructive ? AppTheme.coral : context.accentInk).withValues(
            alpha: 0.12,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 21, color: color ?? context.accentInk),
      ),
      title: Text(
        title,
        style: TextStyle(fontWeight: FontWeight.w700, color: color),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: TextStyle(color: context.muted)),
      trailing:
          trailing ??
          (onTap == null
              ? null
              : Icon(Icons.chevron_right_rounded, color: context.muted)),
    );
  }
}

/// A small heading between groups of rows.
class SettingsHeading extends StatelessWidget {
  const SettingsHeading(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: context.muted,
        fontSize: 12,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.8,
      ),
    ),
  );
}

/// A settings page: title bar and a scrolling body no wider than a phone-ish column.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.title,
    required this.children,
    this.actions,
  });

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: children,
          ),
        ),
      ),
    );
  }
}

/// Plain readable text page (policy, terms).
class TextPage extends StatelessWidget {
  const TextPage({super.key, required this.title, required this.sections});
  final String title;

  /// Pairs of heading and paragraph.
  final List<(String, String)> sections;

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: title,
      children: [
        for (final s in sections)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.$1,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(s.$2, style: const TextStyle(height: 1.45, fontSize: 14.5)),
              ],
            ),
          ),
      ],
    );
  }
}
