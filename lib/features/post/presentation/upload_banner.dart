import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../data/upload_queue.dart';

/// "Sharing your clip… 45%" bars at the top of Discover (v0.8).
/// Failed: tap to try again, X to remove.
class UploadBanner extends StatelessWidget {
  const UploadBanner({super.key, this.queue});

  /// Tests pass their own queue.
  final UploadQueue? queue;

  @override
  Widget build(BuildContext context) {
    final q = queue ?? UploadQueue.instance;
    return ListenableBuilder(
      listenable: q,
      builder: (context, _) {
        final tasks = q.tasks;
        if (tasks.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Column(
            children: [for (final t in tasks) _TaskRow(task: t, queue: q)],
          ),
        );
      },
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.queue});

  final UploadTask task;
  final UploadQueue queue;

  @override
  Widget build(BuildContext context) {
    final t = task;
    final failed = t.status == UploadStatus.failed;
    final preview = t.previewPath;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        key: ValueKey('upload-${t.id}'),
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: failed ? () => queue.retry(t) : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: preview != null
                            ? Image.file(
                                File(preview),
                                fit: BoxFit.cover,
                                cacheWidth: 120,
                                errorBuilder: (c, e, s) => const _NoPreview(),
                              )
                            : const _NoPreview(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            t.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          if (failed)
                            Text(
                              t.error.isEmpty
                                  ? 'Tap to try again'
                                  : '${t.error} · Tap to try again',
                              key: const ValueKey('upload-retry-text'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (failed) ...[
                      IconButton(
                        key: const ValueKey('upload-retry'),
                        tooltip: 'Try again',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => queue.retry(t),
                        icon: const Icon(Icons.refresh_rounded, size: 22),
                      ),
                      IconButton(
                        key: const ValueKey('upload-cancel'),
                        tooltip: 'Remove',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _confirmCancel(context),
                        icon: const Icon(Icons.close_rounded, size: 22),
                      ),
                    ] else
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.lime,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              LinearProgressIndicator(
                value: failed ? 0 : (t.progress <= 0 ? null : t.progress),
                minHeight: 3,
                backgroundColor: AppColors.border,
                color: failed ? Colors.redAccent : AppColors.lime,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Remove this upload?'),
        content: const Text('It will not be shared.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Keep'),
          ),
          TextButton(
            key: const ValueKey('upload-cancel-yes'),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await queue.cancel(task);
  }
}

class _NoPreview extends StatelessWidget {
  const _NoPreview();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: AppColors.border,
    child: Icon(Icons.movie_outlined, size: 20, color: AppColors.textSecondary),
  );
}
