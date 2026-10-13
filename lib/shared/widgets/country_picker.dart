import 'package:flutter/material.dart';

import '../../core/constants/countries.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';

/// Bottom sheet with a search box and every country. Returns the code.
Future<String?> showCountryPicker(BuildContext context, {String? current}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _CountrySheet(current: current),
  );
}

class _CountrySheet extends StatefulWidget {
  const _CountrySheet({this.current});
  final String? current;

  @override
  State<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<_CountrySheet> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final list = searchCountries(_q);
    final h = MediaQuery.of(context).size.height;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          height: h * 0.75,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 10),
                child: Text(
                  'Choose country',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  key: const ValueKey('country-search'),
                  onChanged: (v) => setState(() => _q = v),
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: 'Search ${kCountries.length} countries',
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
                        child: Text(
                          'No country found',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      )
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final (code, name) = list[i];
                          final sel = code == widget.current;
                          return ListTile(
                            dense: true,
                            leading: Text(
                              flagOf(code),
                              style: const TextStyle(fontSize: 22),
                            ),
                            title: Text(
                              name,
                              style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            trailing: sel
                                ? const Icon(
                                    Icons.check_circle,
                                    color: AppColors.lime,
                                  )
                                : null,
                            onTap: () => Navigator.pop(context, code),
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
