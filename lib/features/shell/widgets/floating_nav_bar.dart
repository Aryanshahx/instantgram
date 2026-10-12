import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/services/app_settings.dart';
import '../../../core/theme/app_colors.dart';

class NavItem {
  const NavItem(this.label, this.icon, this.activeIcon);
  final String label;
  final IconData icon;
  final IconData activeIcon;
}

/// Floating rounded nav bar + separate gradient "+" button (from the design).
class FloatingNavBar extends StatelessWidget {
  const FloatingNavBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    required this.onCreate,
  });

  final List<NavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    // Small phones (< 350dp): tighter spacing so labels still fit.
    final compact = MediaQuery.sizeOf(context).width < 350;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
          child: Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      height: 52,
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 4 : 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.navBar.withValues(alpha: 0.88),
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.07),
                        ),
                      ),
                      // Every item keeps the same widget, so the pill animates
                      // smoothly between tabs. Very small screens: scale down.
                      child: LayoutBuilder(
                        builder: (context, box) => FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minWidth: box.maxWidth),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                for (var i = 0; i < items.length; i++)
                                  _NavButton(
                                    key: ValueKey(items[i].label),
                                    item: items[i],
                                    compact: compact,
                                    selected: i == currentIndex,
                                    onTap: () => onTap(i),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: compact ? 6 : 8),
              _CreateButton(onTap: onCreate, size: compact ? 46 : 50),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final NavItem item;
  final bool compact;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final reduce =
        AppSettings.instance.reduceMotion.value ||
        MediaQuery.maybeDisableAnimationsOf(context) == true;
    final d = Duration(milliseconds: reduce ? 0 : 320);
    const curve = Curves.easeOutCubic;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: d,
          curve: curve,
          height: 40,
          padding: EdgeInsets.symmetric(
            horizontal: selected ? (compact ? 9 : 12) : (compact ? 4 : 6),
          ),
          decoration: BoxDecoration(
            color: selected ? AppColors.lime : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            boxShadow: selected && !reduce
                ? [
                    BoxShadow(
                      color: AppColors.lime.withValues(alpha: 0.28),
                      blurRadius: 12,
                    ),
                  ]
                : const [],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: d,
                switchInCurve: Curves.easeOutBack,
                transitionBuilder: (child, a) =>
                    ScaleTransition(scale: a, child: child),
                child: Icon(
                  selected ? item.activeIcon : item.icon,
                  key: ValueKey(selected),
                  size: 22,
                  color: selected ? Colors.black : const Color(0xFFB5B8BF),
                ),
              ),
              AnimatedSize(
                duration: d,
                curve: curve,
                alignment: Alignment.centerLeft,
                child: selected
                    ? TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: 1),
                        duration: d,
                        curve: curve,
                        builder: (context, t, child) => Opacity(
                          opacity: t,
                          child: Transform.translate(
                            offset: Offset((1 - t) * -6, 0),
                            child: child,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 5),
                          child: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            softWrap: false,
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                      )
                    : const SizedBox(height: 22),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateButton extends StatelessWidget {
  const _CreateButton({required this.onTap, this.size = 50});

  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Create',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: AppColors.fabGradient,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: AppColors.lime.withValues(alpha: 0.45),
                blurRadius: 20,
                spreadRadius: 1,
              ),
            ],
          ),
          child: const Icon(Icons.add, size: 28, color: Colors.black),
        ),
      ),
    );
  }
}
