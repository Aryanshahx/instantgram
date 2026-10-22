import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/errors.dart';
import 'skeleton.dart';

export 'skeleton.dart'
    show
        SkeletonKind,
        Skeleton,
        SkeletonBox,
        Shimmer,
        ShimmerFill,
        LoadingSweep;

/// Loading place holder: grey shapes with a moving light (no circle).
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.padding = 40, this.kind, this.count});

  /// kept for old callers; only used by [kind] == null (small list)
  final double padding;
  final SkeletonKind? kind;
  final int? count;

  @override
  Widget build(BuildContext context) => Skeleton(
    kind: kind ?? SkeletonKind.list,
    count: count ?? (padding < 30 ? 2 : null),
  );
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error});
  final Object? error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off, color: AppColors.textSecondary, size: 36),
        const SizedBox(height: 12),
        Text(
          friendlyError(error),
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      ],
    ),
  );
}

/// Shows a dialog with a progress bar while [task] runs.
/// Returns true on success, false on error (error shown as snackbar).
Future<bool> runWithProgress(
  BuildContext context, {
  required String title,
  required Future<void> Function(ValueChanged<double> onProgress) task,
}) async {
  final progress = ValueNotifier<double>(0);
  final navigator = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (ctx, v, child) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: v <= 0 || v >= 1 ? null : v,
                  minHeight: 8,
                  backgroundColor: AppColors.border,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                v >= 1 ? 'Finishing…' : '${(v * 100).round()}%',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  try {
    await task((v) => progress.value = v);
    navigator.pop();
    return true;
  } catch (e) {
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    return false;
  } finally {
    progress.dispose();
  }
}
