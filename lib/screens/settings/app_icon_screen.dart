import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/app_icon_service.dart';

/// Settings > App icon: pick how InstantGram looks on the home screen.
class AppIconScreen extends StatefulWidget {
  const AppIconScreen({super.key});

  @override
  State<AppIconScreen> createState() => _AppIconScreenState();
}

class _AppIconScreenState extends State<AppIconScreen> {
  bool? _available;
  String _current = 'classic';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = AppIconService.instance;
    final ok = await s.available();
    final cur = ok ? await s.current() : 'classic';
    if (mounted) {
      setState(() {
        _available = ok;
        _current = cur;
      });
    }
  }

  Future<void> _pick(AppIconOption o) async {
    if (_busy || o.id == _current) return;
    setState(() => _busy = true);
    try {
      await AppIconService.instance.set(o.id);
      if (!mounted) return;
      setState(() => _current = o.id);
      showToast(
        context,
        'Icon changed to ${o.label}. Your home screen may take a few seconds.',
      );
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ok = _available;
    return Scaffold(
      appBar: AppBar(title: const Text('App icon')),
      body: ok == null
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  ok
                      ? 'Choose how InstantGram looks on your home screen.'
                      : 'Changing the icon needs the newest app build. '
                            'Install the latest APK and try again.',
                  style: TextStyle(color: context.muted),
                ),
                const SizedBox(height: 16),
                GridView.count(
                  crossAxisCount: MediaQuery.sizeOf(context).width > 600
                      ? 6
                      : 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.82,
                  children: [
                    for (final o in kAppIcons)
                      GestureDetector(
                        key: ValueKey('icon_${o.id}'),
                        onTap: ok ? () => _pick(o) : null,
                        child: Opacity(
                          opacity: ok ? 1 : 0.5,
                          child: Column(
                            children: [
                              Expanded(
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(26),
                                    border: Border.all(
                                      color: o.id == _current
                                          ? AppTheme.volt
                                          : Colors.transparent,
                                      width: 3,
                                    ),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(20),
                                    child: Image.asset(
                                      o.asset,
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, _, _) => const Icon(
                                        Icons.apps_rounded,
                                        size: 40,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (o.id == _current) ...[
                                    const Icon(
                                      Icons.check_circle_rounded,
                                      size: 15,
                                      color: AppTheme.volt,
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Flexible(
                                    child: Text(
                                      o.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}
