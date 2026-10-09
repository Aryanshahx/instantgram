import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/app_prefs.dart';
import '../services/safety_service.dart';

/// Posts and moments opened with "Tap to view" (for as long as the app runs).
final Set<String> revealedSensitive = {};

/// Changes when something is revealed or the setting changes (open copies follow).
final ValueNotifier<int> sensitiveTick = ValueNotifier(0);

/// Whether [id] by [authorId] is blurred for me right now.
bool isBlurred(String id, String authorId, bool sensitive) {
  if (!sensitive) return false;
  final mine = authorId.isNotEmpty && authorId == SafetyService.instance.me;
  if (mine) return false;
  if (AppPrefs.instance.showSensitive) return false;
  return !revealedSensitive.contains(id);
}

void revealSensitive(String id) {
  revealedSensitive.add(id);
  sensitiveTick.value++;
}

/// Blurs a photo or clip the photo check flagged, with "Tap to view".
/// [compact]: small grid tiles get only an icon (a tap opens the post as usual).
class SensitiveGate extends StatelessWidget {
  const SensitiveGate({
    super.key,
    required this.id,
    required this.authorId,
    required this.sensitive,
    this.compact = false,
    this.child,
    this.builder,
  }) : assert(child != null || builder != null);

  final String id;
  final String authorId;
  final bool sensitive;
  final bool compact;
  final Widget? child;

  /// For clips: gets whether the media is visible (a blurred clip stays paused).
  final Widget Function(BuildContext context, bool shown)? builder;

  @override
  Widget build(BuildContext context) {
    if (!sensitive) return builder?.call(context, true) ?? child!;
    return ValueListenableBuilder<int>(
      valueListenable: sensitiveTick,
      builder: (context, _, _) {
        final blurred = isBlurred(id, authorId, sensitive);
        final media = builder?.call(context, !blurred) ?? child!;
        if (!blurred) return media;
        return Stack(
          fit: StackFit.passthrough,
          children: [
            ClipRect(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: compact ? 14 : 32,
                  sigmaY: compact ? 14 : 32,
                ),
                child: IgnorePointer(child: media),
              ),
            ),
            Positioned.fill(child: compact ? _small() : _cover(context)),
          ],
        );
      },
    );
  }

  Widget _small() => const IgnorePointer(
    child: ColoredBox(
      color: Color(0x33000000),
      child: Center(
        child: Icon(
          Icons.visibility_off_rounded,
          color: Colors.white,
          size: 26,
        ),
      ),
    ),
  );

  Widget _cover(BuildContext context) => GestureDetector(
    key: ValueKey('sensitive_$id'),
    behavior: HitTestBehavior.opaque,
    onTap: () => revealSensitive(id),
    child: ColoredBox(
      color: const Color(0x59000000),
      child: Center(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.visibility_off_rounded,
                color: Colors.white,
                size: 34,
              ),
              const SizedBox(height: 8),
              const Text(
                'Sensitive content',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'This may show nudity or sexual content.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white70),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                  child: Text(
                    'Tap to view',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
