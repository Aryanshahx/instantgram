import 'package:flutter/material.dart';

import '../../core/constants/languages.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';

/// Bottom sheet with a search box and 40 languages. Returns the code.
Future<String?> showLanguagePicker(BuildContext context, {String? current}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _LanguageSheet(current: current),
  );
}

class _LanguageSheet extends StatefulWidget {
  const _LanguageSheet({this.current});
  final String? current;

  @override
  State<_LanguageSheet> createState() => _LanguageSheetState();
}

class _LanguageSheetState extends State<_LanguageSheet> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = kLanguages
        .where((l) =>
            q.isEmpty ||
            l.name.toLowerCase().contains(q) ||
            l.native.toLowerCase().contains(q))
        .toList();
    final h = MediaQuery.of(context).size.height;
    return SafeArea(
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: h * 0.75,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 10),
                child: Text(
                  'Choose language',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  onChanged: (v) => setState(() => _q = v),
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: 'Search language',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: list.isEmpty
                    ? const Center(
                        child: Text('No language found',
                            style: TextStyle(color: AppColors.textSecondary)),
                      )
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final l = list[i];
                          final sel = l.code == widget.current;
                          return ListTile(
                            dense: true,
                            title: Text(
                              l.name,
                              style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: l.native == l.name
                                ? null
                                : Text(l.native,
                                    style: const TextStyle(
                                        color: AppColors.textSecondary)),
                            trailing: sel
                                ? const Icon(Icons.check_circle,
                                    color: AppColors.lime)
                                : null,
                            onTap: () => Navigator.pop(context, l.code),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
