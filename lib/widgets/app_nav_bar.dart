import 'package:flutter/material.dart';

import '../core/l10n.dart';

import '../core/theme.dart';
import 'glass.dart';

/// The thin floating bottom bar: five tabs and the round "+" button.
/// The selected tab shows its name; a red dot on Chats means unread messages.
class AppNavBar extends StatelessWidget {
  const AppNavBar({
    super.key,
    required this.index,
    required this.onSelect,
    required this.onCreate,
    this.chatDot = false,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onCreate;
  final bool chatDot;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Glass(
            radius: 22,
            blur: 22,
            opacity: 0.78,
            padding: const EdgeInsets.all(3),
            // If the screen is very narrow (or the text very large) the row shrinks to fit.
            child: LayoutBuilder(
              builder: (context, c) => FittedBox(
                fit: BoxFit.scaleDown,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: c.maxWidth),
                  child: IntrinsicWidth(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (final (i, t) in _tabs.indexed)
                          NavItem(
                            icon: t.icon,
                            activeIcon: t.activeIcon,
                            label: t.label,
                            selected: index == i,
                            dot: i == 3 && chatDot,
                            onTap: () => onSelect(i),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          key: const ValueKey('createButton'),
          onTap: onCreate,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: AppTheme.voltGradient,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.volt.withValues(alpha: 0.4),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: const Icon(Icons.add_rounded, size: 26, color: AppTheme.ink),
          ),
        ),
      ],
    );
  }
}

const _tabs = [
  _Tab(Icons.home_outlined, Icons.home_rounded, 'Discover'),
  _Tab(Icons.explore_outlined, Icons.explore_rounded, 'Explore'),
  _Tab(Icons.play_circle_outline_rounded, Icons.play_circle_rounded, 'Clips'),
  _Tab(Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, 'Chats'),
  _Tab(Icons.person_outline_rounded, Icons.person_rounded, 'Me'),
];

class _Tab {
  const _Tab(this.icon, this.activeIcon, this.label);
  final IconData icon;
  final IconData activeIcon;
  final String label;
}

class NavItem extends StatelessWidget {
  const NavItem({
    super.key,
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.dot = false,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// A small red dot on the icon (something new in this tab).
  final bool dot;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        height: 38,
        padding: EdgeInsets.symmetric(horizontal: selected ? 12 : 10),
        decoration: BoxDecoration(
          color: selected ? AppTheme.volt : Colors.transparent,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  selected ? activeIcon : icon,
                  size: 22,
                  color: selected
                      ? AppTheme.ink
                      : Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                if (dot && !selected)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      key: const ValueKey('chatDot'),
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF3B5C),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: selected
                  ? Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        context.tr(label),
                        style: const TextStyle(
                          color: AppTheme.ink,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
