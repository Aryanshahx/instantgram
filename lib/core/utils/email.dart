import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Builds a mailto: link (spaces stay %20, not "+").
Uri mailtoUri(String to, {String subject = '', String body = ''}) {
  String enc(String s) => Uri.encodeComponent(s);
  final q = <String>[
    if (subject.isNotEmpty) 'subject=${enc(subject)}',
    if (body.isNotEmpty) 'body=${enc(body)}',
  ].join('&');
  return Uri.parse('mailto:$to${q.isEmpty ? '' : '?$q'}');
}

/// Opens the email app. If there is none, copies the address + text
/// and tells the user.
Future<bool> openEmail(
  BuildContext context, {
  required String to,
  String subject = '',
  String body = '',
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  var ok = false;
  try {
    ok = await launchUrl(
      mailtoUri(to, subject: subject, body: body),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    ok = false;
  }
  if (!ok) {
    await Clipboard.setData(
      ClipboardData(text: 'To: $to\nSubject: $subject\n\n$body'),
    );
    messenger?.showSnackBar(
      SnackBar(
        content: Text('No email app found. Text copied — send it to $to'),
      ),
    );
  }
  return ok;
}

/// Opens a web link in the browser.
Future<bool> openLink(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
      return true;
    }
  } catch (_) {}
  messenger?.showSnackBar(SnackBar(content: Text('Could not open $url')));
  return false;
}
