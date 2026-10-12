import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../shared/models/post.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../data/report_repository.dart';

/// Report a post / clip: pick a reason -> edit the ready message -> send.
Future<void> showReportSheet(BuildContext context, Post post) {
  final messenger = ScaffoldMessenger.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _ReportSheet(post: post, messenger: messenger),
    ),
  );
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.post, required this.messenger});
  final Post post;
  final ScaffoldMessengerState messenger;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final _msg = TextEditingController();
  ReportReason? _reason;
  bool _sending = false;

  String get _item => widget.post.isClip ? 'clip' : 'post';

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  void _pick(ReportReason r) {
    setState(() {
      _reason = r;
      _msg.text = r.message(_item);
    });
  }

  Future<void> _send() async {
    final r = _reason;
    if (r == null) return;
    if (_msg.text.trim().isEmpty) {
      widget.messenger.showSnackBar(
        const SnackBar(content: Text('Please write a short message')),
      );
      return;
    }
    setState(() => _sending = true);
    String result;
    try {
      await ReportRepository.instance.report(widget.post, r.title, _msg.text);
      result = "Thanks for reporting. We'll review this $_item.";
    } on AlreadyReportedException {
      result = 'You already reported this $_item.';
    } catch (e) {
      result = friendlyError(e);
    }
    if (!mounted) return;
    Navigator.pop(context);
    widget.messenger.showSnackBar(SnackBar(content: Text(result)));
  }

  @override
  Widget build(BuildContext context) {
    final r = _reason;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: r == null ? _reasons() : _message(r),
      ),
    );
  }

  Widget _reasons() => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 2),
            child: Text(
              'Report $_item',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Why are you reporting this? Your report is private.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ),
          for (final reason in kReportReasons)
            ListTile(
              dense: true,
              leading: Icon(reason.icon, size: 22),
              title: Text(reason.title, style: const TextStyle(fontSize: 15)),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => _pick(reason),
            ),
        ],
      );

  Widget _message(ReportReason r) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  visualDensity: VisualDensity.compact,
                  onPressed: _sending ? null : () => setState(() => _reason = null),
                  icon: const Icon(Icons.arrow_back, size: 20),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    r.title,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Message (you can change it):',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _msg,
              autofocus: r.template.isEmpty,
              maxLines: 4,
              minLines: 3,
              maxLength: 500,
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Tell us what is wrong',
                filled: true,
                fillColor: AppColors.surface,
                contentPadding: const EdgeInsets.all(14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.lime),
                ),
              ),
            ),
            const SizedBox(height: 8),
            IgPrimaryButton(
              label: 'Send report',
              icon: Icons.flag_outlined,
              height: 44,
              loading: _sending,
              onPressed: _send,
            ),
          ],
        ),
      );
}
