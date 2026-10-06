import 'package:flutter/material.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../widgets/aurora_background.dart';
import '../../widgets/brand_logo.dart';
import 'signup_screen.dart';

/// Step 1 of making an account: choose the language. The choice is applied at once, so the
/// next screens already speak it.
class LanguageStepScreen extends StatefulWidget {
  const LanguageStepScreen({super.key});

  @override
  State<LanguageStepScreen> createState() => _LanguageStepScreenState();
}

class _LanguageStepScreenState extends State<LanguageStepScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = [
      for (final l in kLanguages)
        if (q.isEmpty ||
            l.name.toLowerCase().contains(q) ||
            l.english.toLowerCase().contains(q))
          l,
    ];
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(),
      body: AuroraBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ValueListenableBuilder<String>(
                valueListenable: Language.instance,
                builder: (context, code, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(26, 4, 26, 0),
                      child: BrandWordmark(size: 30),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(26, 18, 26, 4),
                      child: Text(
                        context.tr('Choose your language'),
                        key: const ValueKey('langStepTitle'),
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.2,
                          height: 1.05,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(26, 0, 26, 8),
                      child: Text(
                        context.tr('You can change it later in Settings.'),
                        style: TextStyle(color: context.muted, fontSize: 14),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                      child: TextField(
                        key: const ValueKey('languageSearch'),
                        onChanged: (v) => setState(() => _q = v),
                        decoration: InputDecoration(
                          hintText: context.tr('Search'),
                          prefixIcon: const Icon(Icons.search_rounded),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        children: [
                          for (final l in list)
                            ListTile(
                              key: ValueKey('language_${l.code}'),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              title: Text(
                                l.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(l.english),
                              trailing: code == l.code
                                  ? const Icon(
                                      Icons.check_circle_rounded,
                                      color: AppTheme.mint,
                                    )
                                  : const Icon(Icons.circle_outlined),
                              onTap: () => Language.instance.choose(l.code),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(26, 8, 26, 16),
                      child: FilledButton(
                        key: const ValueKey('langContinue'),
                        onPressed: () =>
                            openScreen(context, const SignupScreen()),
                        child: Text(context.tr('Continue')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
