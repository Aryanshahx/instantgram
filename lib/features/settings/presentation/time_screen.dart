import 'package:flutter/material.dart';

import '../../../core/services/app_settings.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_widgets.dart';

/// "1h 05m" / "12m" / "0m"
String formatMinutes(int seconds) {
  final m = seconds ~/ 60;
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
}

const List<int> kLimitChoices = [0, 15, 30, 45, 60, 90, 120, 180];

/// Settings → Manage time.
class TimeScreen extends StatelessWidget {
  const TimeScreen({super.key, this.now});

  /// For tests.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([s.usage, s.dailyLimitMinutes]),
      builder: (context, _) {
        final today = now ?? DateTime.now();
        final days = [
          for (var i = 6; i >= 0; i--)
            DateTime(today.year, today.month, today.day - i),
        ];
        final secs = [for (final d in days) s.secondsOn(d)];
        final total = secs.fold<int>(0, (a, b) => a + b);
        final avg = total ~/ 7;
        final maxS = secs.fold<int>(1, (a, b) => b > a ? b : a);
        final limit = s.dailyLimitMinutes.value;
        const names = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

        return SettingsPage(
          title: 'Manage time',
          children: [
            const SizedBox(height: 10),
            Center(
              child: Text(
                formatMinutes(secs.last),
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const Center(
              child: Text(
                'Today on this phone',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: 18),
            SettingsCard(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                  child: SizedBox(
                    height: 130,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var i = 0; i < 7; i++)
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Flexible(
                                  child: FractionallySizedBox(
                                    heightFactor: (secs[i] / maxS).clamp(
                                      0.03,
                                      1.0,
                                    ),
                                    child: Container(
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                      ),
                                      decoration: BoxDecoration(
                                        gradient: i == 6
                                            ? AppColors.fabGradient
                                            : null,
                                        color: i == 6 ? null : AppColors.border,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  names[days[i].weekday - 1],
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: i == 6
                                        ? AppColors.lime
                                        : AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Row(
                    children: [
                      Text(
                        'Daily average ${formatMinutes(avg)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      Text(
                        '7 days ${formatMinutes(total)}',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SettingsHeader('Daily reminder'),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                "We'll remind you to take a break once you reach this time "
                'in a day.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in kLimitChoices)
                    ChoiceChip(
                      key: ValueKey('limit-$m'),
                      label: Text(m == 0 ? 'Off' : formatMinutes(m * 60)),
                      selected: limit == m,
                      showCheckmark: false,
                      selectedColor: AppColors.lime,
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: limit == m ? Colors.black : null,
                      ),
                      onSelected: (_) => s.setDailyLimit(m),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
